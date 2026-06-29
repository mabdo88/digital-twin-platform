// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Time-series backend — append-only log sorted by timestamp.
//
// Models InfluxDB-style behaviour: writes are fast (append + occasional
// rebalance), time-window reads are fast (binary search on the timestamp
// index to find the [start, end] slice, then linear scan within).
//
// Internal layout:
//   - `log`: ArrayList(SensorReading) kept sorted by (timestamp, sensor_id).
//     Insert appends then does an insertion-sort step to maintain order.
//     For bulk ingest (deterministic test data) a final sort is cheaper,
//     so `insert` appends and marks `sorted = false`; `rangeByTime` and
//     `getLatestBySensor` call `ensureSorted` lazily.
//   - No secondary per-sensor index: the sorted log + binary search on
//     timestamp is sufficient for the interface's query patterns and keeps
//     memory overhead minimal (matching InfluxDB's time-ordered LSM tree
//     philosophy at the abstraction level we model).
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).
// This differs from AoS/SoA (insertion order) but is valid per the
// interface contract — iterateAll does not guarantee insertion order.

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

allocator: std.mem.Allocator,
log: std.ArrayList(SensorReading),
sorted: bool,
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .log = .empty,
        .sorted = true,
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.log.deinit(self.allocator);
    self.zone_index.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    try self.log.append(self.allocator, reading);
    self.sorted = false;
}

pub fn count(self: *const Self) usize {
    return self.log.items.len;
}

pub fn memoryUsed(self: *const Self) usize {
    return self.log.capacity * @sizeOf(SensorReading) + self.zone_index.memoryUsed();
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();
    const result = try allocator.alloc(SensorReading, self.log.items.len);
    @memcpy(result, self.log.items);
    return result;
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();

    // Walk backwards from the end (highest timestamps) to find the
    // first reading for this sensor — O(n) worst case but early-exit
    // for recent data.
    var i: usize = self.log.items.len;
    while (i > 0) {
        i -= 1;
        const r = self.log.items[i];
        if (r.sensor_id == sensor_id) return r;
        // Once we've passed the sensor's data we can stop, but we don't
        // have a per-sensor index, so we scan. The sorted order means
        // the first match from the end is the latest.
    }
    return null;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Uses binary search on the sorted log to find the time-range boundaries,
/// then filters by sensor_id if specified.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();

    const items = self.log.items;
    if (items.len == 0) return &.{};
    // An inverted range (start > end) is unsatisfiable by definition — bail
    // out before the binary search, which otherwise computes lo > hi and
    // panics on `hi - lo` underflowing below.
    if (q.start_time > q.end_time) return &.{};

    // Binary search for the first index with timestamp >= q.start_time.
    const lo = std.sort.lowerBound(SensorReading, items, q.start_time, struct {
        fn cmp(ctx: i64, item: SensorReading) std.math.Order {
            return std.math.order(ctx, item.timestamp);
        }
    }.cmp);

    // Binary search for the first index with timestamp > q.end_time.
    const hi = std.sort.upperBound(SensorReading, items, q.end_time, struct {
        fn cmp(ctx: i64, item: SensorReading) std.math.Order {
            return std.math.order(ctx, item.timestamp);
        }
    }.cmp);

    // [lo, hi) is the slice of readings within the time range.
    // Filter by sensor_id if specified. Results are already sorted by
    // (timestamp, sensor_id) because the log is maintained in that order.
    if (q.sensor_id) |sid| {
        var result: std.ArrayList(SensorReading) = .empty;
        defer result.deinit(allocator);
        for (items[lo..hi]) |r| {
            if (r.sensor_id == sid) {
                try result.append(allocator, r);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    // No sensor filter — copy the slice directly (already sorted).
    const result = try allocator.alloc(SensorReading, hi - lo);
    @memcpy(result, items[lo..hi]);
    return result;
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

// ---------------------------------------------------------------------------
// Internal — sort maintenance
// ---------------------------------------------------------------------------

fn ensureSorted(self: *Self) void {
    if (self.sorted) return;
    std.mem.sort(SensorReading, self.log.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);
    self.sorted = true;
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
