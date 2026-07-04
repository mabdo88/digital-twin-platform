// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Time-series backend — time-partitioned append-only log.
//
// Models InfluxDB-style behaviour: data is organised into time-partitioned
// shards (one per sensor_type per day). Writes are fast (append to the
// correct shard). Time-window reads use binary search within the relevant
// shards. Retention is O(partitions_dropped) — entire expired shards are
// dropped, never row-by-row compaction (matching InfluxDB's shard-drop
// retention mechanism, not a row-level DELETE).
//
// Internal layout:
//   - `partitions`: AutoHashMap(PartitionKey, Partition) where the key is
//     (sensor_type, day_index). Each partition is a sorted ArrayList of
//     SensorReading. Insert appends in time order (maintaining sorted order
//     when the stream is time-ordered); out-of-order inserts mark the
//     partition unsorted and it is lazily sorted on query.
//   - `latest_by_sensor`: O(1) latest-reading cache, maintained incrementally
//     on insert and rebuilt lazily after pruning.
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

const PARTITION_MS: i64 = 86_400_000; // 1 day in milliseconds

const PartitionKey = struct {
    sensor_type: SensorType,
    day_index: i64,
};

const Partition = struct {
    readings: std.ArrayList(SensorReading),
    sorted: bool,
};

allocator: std.mem.Allocator,
partitions: std.AutoHashMap(PartitionKey, Partition),
total_count: usize,
latest_by_sensor: std.AutoHashMap(u32, SensorReading),
latest_dirty: bool,
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .partitions = std.AutoHashMap(PartitionKey, Partition).init(allocator),
        .total_count = 0,
        .latest_by_sensor = std.AutoHashMap(u32, SensorReading).init(allocator),
        .latest_dirty = false,
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.readings.deinit(self.allocator);
    }
    self.partitions.deinit();
    self.latest_by_sensor.deinit();
    self.zone_index.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    const key = PartitionKey{
        .sensor_type = reading.sensor_type,
        .day_index = @divFloor(reading.timestamp, PARTITION_MS),
    };
    const gop = try self.partitions.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .readings = .empty, .sorted = true };
    }
    const part = gop.value_ptr;

    // If sorted and new reading extends order, append keeps it sorted.
    if (part.sorted and part.readings.items.len > 0) {
        const last = part.readings.items[part.readings.items.len - 1];
        if (reading.timestamp > last.timestamp or
            (reading.timestamp == last.timestamp and reading.sensor_id >= last.sensor_id))
        {
            try part.readings.append(self.allocator, reading);
            self.total_count += 1;
            self.updateLatest(reading);
            return;
        }
    }
    try part.readings.append(self.allocator, reading);
    part.sorted = false;
    self.total_count += 1;
    self.updateLatest(reading);
}

pub fn count(self: *const Self) usize {
    return self.total_count;
}

pub fn memoryUsed(self: *const Self) usize {
    var total: usize = self.partitions.capacity() * (@sizeOf(PartitionKey) + @sizeOf(Partition));
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        total += entry.value_ptr.readings.capacity * @sizeOf(SensorReading);
    }
    total += self.latest_by_sensor.capacity() * (@sizeOf(u32) + @sizeOf(SensorReading));
    return total + self.zone_index.memoryUsed();
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, self.total_count);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const part = entry.value_ptr;
        if (!part.sorted) self_mut.sortPartition(part);
        try result.appendSlice(allocator, part.readings.items);
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return result.toOwnedSlice(allocator);
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    return self_mut.latest_by_sensor.get(sensor_id);
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Scans only partitions overlapping the query time range, using binary
/// search within each partition.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    if (q.start_time > q.end_time) return &.{};

    const start_day = @divFloor(q.start_time, PARTITION_MS);
    const end_day = @divFloor(q.end_time, PARTITION_MS);

    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.day_index < start_day or key.day_index > end_day) continue;

        const part = entry.value_ptr;
        if (!part.sorted) self_mut.sortPartition(part);

        const items = part.readings.items;
        if (items.len == 0) continue;

        const lo = std.sort.lowerBound(SensorReading, items, q.start_time, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);
        const hi = std.sort.upperBound(SensorReading, items, q.end_time, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);

        for (items[lo..hi]) |r| {
            if (q.sensor_id) |sid| {
                if (r.sensor_id != sid) continue;
            }
            try result.append(allocator, r);
        }
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return result.toOwnedSlice(allocator);
}

/// Zone/floor topology bookkeeping delegates to the shared ZoneIndex — see
/// storage_backend.zig's doc comment for the contract.
pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
    return self.zone_index.registerZone(sensor_id, zone_id);
}

pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
    return self.zone_index.registerFloor(zone_id, floor_id);
}

pub fn sensorIdsByZone(self: *const Self, allocator: std.mem.Allocator, zone_id: u32) ![]u32 {
    return self.zone_index.sensorIdsByZone(allocator, zone_id);
}

pub fn sensorIdsByFloor(self: *const Self, allocator: std.mem.Allocator, floor_id: u32) ![]u32 {
    return self.zone_index.sensorIdsByFloor(allocator, floor_id);
}

pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
    return self.zone_index.floorOfZone(zone_id);
}

pub fn allSensorIds(self: *const Self, allocator: std.mem.Allocator) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    var it = self_mut.latest_by_sensor.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Drops entire time-partitions of `sensor_type` that are fully older than
/// `cutoff_timestamp` — O(partitions), not O(readings). Only the boundary
/// partition (straddling the cutoff) gets row-level compaction, bounded by
/// one day's data. Readings of other types and zone/floor topology are
/// untouched. See storage_backend.zig's pruneOlderThan contract.
/// TimeSeries has no fixed-capacity concept — see aos_storage.zig's
/// setRetentionHint for why this is a no-op.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    // Drop entire partitions fully older than cutoff — O(partitions),
    // not O(readings). Only the boundary partition (straddling the cutoff)
    // gets row-level compaction, and even that is bounded by one day's data.
    var to_drop: std.ArrayList(PartitionKey) = .empty;
    defer to_drop.deinit(self.allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.sensor_type != sensor_type) continue;

        const part_start = key.day_index * PARTITION_MS;
        const part_end = (key.day_index + 1) * PARTITION_MS;

        if (part_end <= cutoff_timestamp) {
            // Entire partition is older than cutoff — drop it.
            try to_drop.append(self.allocator, key);
            self.total_count -= entry.value_ptr.readings.items.len;
        } else if (part_start < cutoff_timestamp) {
            // Boundary partition — compact rows older than cutoff.
            const part = entry.value_ptr;
            if (!part.sorted) self.sortPartition(part);
            var write: usize = 0;
            for (part.readings.items) |r| {
                if (r.timestamp < cutoff_timestamp) continue;
                part.readings.items[write] = r;
                write += 1;
            }
            self.total_count -= part.readings.items.len - write;
            part.readings.shrinkRetainingCapacity(write);
        }
    }

    for (to_drop.items) |key| {
        if (self.partitions.fetchRemove(key)) |kv| {
            var part = kv.value;
            part.readings.deinit(self.allocator);
        }
    }

    // Either dropping partitions or compacting the boundary may have
    // removed a sensor's latest reading — force a lazy rebuild.
    self.latest_dirty = true;
}

// ---------------------------------------------------------------------------
// Internal — per-partition sort + latest-reading cache
// ---------------------------------------------------------------------------

fn sortPartition(_: *Self, part: *Partition) void {
    std.mem.sort(SensorReading, part.readings.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);
    part.sorted = true;
}

fn updateLatest(self: *Self, reading: SensorReading) void {
    if (self.latest_dirty) return;
    if (self.latest_by_sensor.get(reading.sensor_id)) |current| {
        if (reading.timestamp > current.timestamp) {
            self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
        }
    } else {
        self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
    }
}

fn rebuildLatest(self: *Self) void {
    self.latest_by_sensor.clearRetainingCapacity();
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.readings.items) |r| {
            if (self.latest_by_sensor.get(r.sensor_id)) |current| {
                if (r.timestamp > current.timestamp) {
                    self.latest_by_sensor.put(r.sensor_id, r) catch {};
                }
            } else {
                self.latest_by_sensor.put(r.sensor_id, r) catch {};
            }
        }
    }
    self.latest_dirty = false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TimeSeries: assertImplements" {
    sb.assertImplements(Self);
}

test "TimeSeries: insert N readings and read them back" {
    const N: usize = 100;
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    for (0..N) |i| {
        try backend.insert(.{
            .sensor_id = @intCast(i % 10),
            .timestamp = @intCast(i),
            .value = @floatFromInt(i),
            .sensor_type = .temperature,
        });
    }

    try std.testing.expectEqual(N, backend.count());

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);

    try std.testing.expectEqual(N, all.len);
    // iterateAll returns sorted by (timestamp, sensor_id) — verify ordering.
    for (0..N) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
    }
}

test "TimeSeries: getLatestBySensor" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 300, .value = 30.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 200, .value = 20.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 500, .value = 50.0, .sensor_type = .humidity });

    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);

    try std.testing.expect(backend.getLatestBySensor(999) == null);
}

test "TimeSeries: rangeByTime filters and sorts" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 3, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 30, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 4.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 5, .timestamp = 200, .value = 5.0, .sensor_type = .temperature });

    const result = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 100 });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    // Sorted by timestamp asc, then sensor_id asc
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[0].timestamp);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[1].timestamp);
    try std.testing.expectEqual(@as(u32, 2), result[2].sensor_id);
    try std.testing.expectEqual(@as(i64, 30), result[2].timestamp);
    try std.testing.expectEqual(@as(u32, 3), result[3].sensor_id);
    try std.testing.expectEqual(@as(i64, 50), result[3].timestamp);
}

test "TimeSeries: rangeByTime with sensor filter" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 20, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 30, .value = 3.0, .sensor_type = .temperature });

    const result = try backend.rangeByTime(std.testing.allocator, .{
        .sensor_id = 1,
        .start_time = 0,
        .end_time = 100,
    });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
}

test "TimeSeries: sensorIdsByZone/sensorIdsByFloor reflect real (non-arithmetic) registration" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 7, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.registerZone(7, 4291);
    try backend.registerZone(2, 4291);
    try backend.registerFloor(4291, 3);

    const zone = try backend.sensorIdsByZone(std.testing.allocator, 4291);
    defer std.testing.allocator.free(zone);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, zone);

    const floor = try backend.sensorIdsByFloor(std.testing.allocator, 3);
    defer std.testing.allocator.free(floor);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, floor);

    try std.testing.expectEqual(@as(?u32, 3), backend.floorOfZone(4291));

    const empty = try backend.sensorIdsByZone(std.testing.allocator, 99);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "TimeSeries: getLatestBySensor is deterministic across repeated calls when timestamps tie" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 20.0, .sensor_type = .temperature });

    const first = backend.getLatestBySensor(1).?;
    const second = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 100), first.timestamp);
    try std.testing.expectEqual(first.value, second.value);
}

test "TimeSeries: empty backend" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try std.testing.expectEqual(@as(usize, 0), backend.count());
    try std.testing.expect(backend.getLatestBySensor(0) == null);

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 0), all.len);

    const rng = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 100 });
    defer std.testing.allocator.free(rng);
    try std.testing.expectEqual(@as(usize, 0), rng.len);
}

test "TimeSeries: pruneOlderThan removes only the matching type older than cutoff, preserving sort order" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Inserted out of order, on purpose — pruning must not depend on the
    // log already being sorted, and rangeByTime after pruning must still
    // return correctly sorted results (ensureSorted still works post-prune).
    try backend.insert(.{ .sensor_id = 1, .timestamp = 150, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 50, .value = 3.0, .sensor_type = .humidity });

    try backend.pruneOlderThan(.temperature, 100);

    try std.testing.expectEqual(@as(usize, 2), backend.count());

    const rng = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 1000 });
    defer std.testing.allocator.free(rng);
    try std.testing.expectEqual(@as(usize, 2), rng.len);
    // Sorted ascending: humidity@50 then temperature@150.
    try std.testing.expectEqual(@as(i64, 50), rng[0].timestamp);
    try std.testing.expectEqual(SensorType.humidity, rng[0].sensor_type);
    try std.testing.expectEqual(@as(i64, 150), rng[1].timestamp);
    try std.testing.expectEqual(SensorType.temperature, rng[1].sensor_type);
}

test "TimeSeries: out-of-order inserts are sorted lazily" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 300, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 200, .value = 2.0, .sensor_type = .temperature });

    // getLatestBySensor triggers sort
    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(i64, 100), all[0].timestamp);
    try std.testing.expectEqual(@as(i64, 200), all[1].timestamp);
    try std.testing.expectEqual(@as(i64, 300), all[2].timestamp);
}

test "TimeSeries and AoS produce identical query results" {
    var ts = try Self.init(std.testing.allocator);
    defer ts.deinit();
    var aos = try @import("aos_storage.zig").init(std.testing.allocator);
    defer aos.deinit();

    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try ts.insert(r);
        try aos.insert(r);
    }

    try std.testing.expectEqual(aos.count(), ts.count());

    // rangeByTime — both must return same sorted results
    const ts_rng = try ts.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(ts_rng);
    const aos_rng = try aos.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(aos_rng);

    try std.testing.expectEqual(aos_rng.len, ts_rng.len);
    for (0..aos_rng.len) |i| {
        try std.testing.expectEqual(aos_rng[i].sensor_id, ts_rng[i].sensor_id);
        try std.testing.expectEqual(aos_rng[i].timestamp, ts_rng[i].timestamp);
        try std.testing.expectEqual(aos_rng[i].value, ts_rng[i].value);
    }

    // getLatestBySensor — both must agree
    for (0..6) |sid| {
        const ts_latest = ts.getLatestBySensor(@intCast(sid));
        const aos_latest = aos.getLatestBySensor(@intCast(sid));
        if (aos_latest) |a| {
            try std.testing.expect(ts_latest != null);
            try std.testing.expectEqual(a.timestamp, ts_latest.?.timestamp);
            try std.testing.expectEqual(a.sensor_id, ts_latest.?.sensor_id);
        } else {
            try std.testing.expect(ts_latest == null);
        }
    }
}
