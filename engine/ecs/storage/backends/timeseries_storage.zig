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
