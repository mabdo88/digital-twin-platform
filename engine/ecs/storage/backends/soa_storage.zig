// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Struct-of-Arrays backend — the data-oriented baseline.
//
// Each field of SensorReading is stored in its own parallel ArrayList.
// Iteration order: insertion order (NOT sorted).
// This layout is cache-friendly for bulk field queries (e.g. "average
// value across all sensors") because scanning the values array touches
// only 4-byte f32s with no stride padding. It is also SIMD-exploitable
// for homogeneous field operations.

const std = @import("std");
const sb = @import("../storage_backend.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

allocator: std.mem.Allocator,
sensor_ids: std.ArrayList(u32),
timestamps: std.ArrayList(i64),
values: std.ArrayList(f32),
sensor_types: std.ArrayList(SensorType),

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .sensor_ids = .empty,
        .timestamps = .empty,
        .values = .empty,
        .sensor_types = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.sensor_ids.deinit(self.allocator);
    self.timestamps.deinit(self.allocator);
    self.values.deinit(self.allocator);
    self.sensor_types.deinit(self.allocator);
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    try self.sensor_ids.append(self.allocator, reading.sensor_id);
    try self.timestamps.append(self.allocator, reading.timestamp);
    try self.values.append(self.allocator, reading.value);
    try self.sensor_types.append(self.allocator, reading.sensor_type);
}

pub fn count(self: *const Self) usize {
    return self.sensor_ids.items.len;
}

pub fn memoryUsed(self: *const Self) usize {
    return self.sensor_ids.capacity * @sizeOf(u32) +
        self.timestamps.capacity * @sizeOf(i64) +
        self.values.capacity * @sizeOf(f32) +
        self.sensor_types.capacity * @sizeOf(SensorType);
}

/// Iteration order: insertion order.
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const n = self.sensor_ids.items.len;
    const result = try allocator.alloc(SensorReading, n);
    for (0..n) |i| {
        result[i] = .{
            .sensor_id = self.sensor_ids.items[i],
            .timestamp = self.timestamps.items[i],
            .value = self.values.items[i],
            .sensor_type = self.sensor_types.items[i],
        };
    }
    return result;
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    var best_idx: ?usize = null;
    var best_ts: i64 = std.math.minInt(i64);

    for (self.sensor_ids.items, 0..) |sid, i| {
        if (sid != sensor_id) continue;
        if (best_idx == null or self.timestamps.items[i] > best_ts) {
            best_idx = i;
            best_ts = self.timestamps.items[i];
        }
    }

    if (best_idx) |idx| {
        return .{
            .sensor_id = self.sensor_ids.items[idx],
            .timestamp = self.timestamps.items[idx],
            .value = self.values.items[idx],
            .sensor_type = self.sensor_types.items[idx],
        };
    }
    return null;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    const n = self.sensor_ids.items.len;
    for (0..n) |i| {
        const ts = self.timestamps.items[i];
        if (ts < q.start_time or ts > q.end_time) continue;
        if (q.sensor_id) |sid| {
            if (self.sensor_ids.items[i] != sid) continue;
        }
        try result.append(allocator, .{
            .sensor_id = self.sensor_ids.items[i],
            .timestamp = ts,
            .value = self.values.items[i],
            .sensor_type = self.sensor_types.items[i],
        });
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    const owned = try result.toOwnedSlice(allocator);
    return owned;
}

/// No grouping structure to exploit — but unlike AoS, this only has to
/// touch the sensor_ids column (4 bytes/row), not the full 20-byte struct,
/// since group membership depends on sensor_id alone.
pub fn sensorIdsByGroup(self: *const Self, allocator: std.mem.Allocator, group_id: u32, divisor: u32) ![]u32 {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (self.sensor_ids.items) |sid| {
        if (sid / divisor != group_id) continue;
        try seen.put(sid, {});
    }

    var result = try allocator.alloc(u32, seen.count());
    var i: usize = 0;
    var it = seen.keyIterator();
    while (it.next()) |k| {
        result[i] = k.*;
        i += 1;
    }
    std.mem.sort(u32, result, {}, std.sort.asc(u32));
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SoA: assertImplements" {
    sb.assertImplements(Self);
}

test "SoA: insert N readings and read them back" {
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
    for (0..N) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i % 10)), all[i].sensor_id);
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), all[i].value);
        try std.testing.expectEqual(SensorType.temperature, all[i].sensor_type);
    }
}

test "SoA: getLatestBySensor" {
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

test "SoA: rangeByTime filters and sorts" {
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
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[0].timestamp);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[1].timestamp);
    try std.testing.expectEqual(@as(u32, 2), result[2].sensor_id);
    try std.testing.expectEqual(@as(i64, 30), result[2].timestamp);
    try std.testing.expectEqual(@as(u32, 3), result[3].sensor_id);
    try std.testing.expectEqual(@as(i64, 50), result[3].timestamp);
}

test "SoA: rangeByTime with sensor filter" {
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

test "SoA: empty backend" {
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

test "AoS and SoA produce identical results" {
    var aos = try @import("aos_storage.zig").init(std.testing.allocator);
    defer aos.deinit();
    var soa = try Self.init(std.testing.allocator);
    defer soa.deinit();

    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try aos.insert(r);
        try soa.insert(r);
    }

    try std.testing.expectEqual(aos.count(), soa.count());

    const aos_all = try aos.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(aos_all);
    const soa_all = try soa.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(soa_all);

    try std.testing.expectEqual(aos_all.len, soa_all.len);
    for (0..aos_all.len) |i| {
        try std.testing.expectEqual(aos_all[i].sensor_id, soa_all[i].sensor_id);
        try std.testing.expectEqual(aos_all[i].timestamp, soa_all[i].timestamp);
        try std.testing.expectEqual(aos_all[i].value, soa_all[i].value);
        try std.testing.expectEqual(aos_all[i].sensor_type, soa_all[i].sensor_type);
    }

    const aos_rng = try aos.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(aos_rng);
    const soa_rng = try soa.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(soa_rng);

    try std.testing.expectEqual(aos_rng.len, soa_rng.len);
    for (0..aos_rng.len) |i| {
        try std.testing.expectEqual(aos_rng[i].sensor_id, soa_rng[i].sensor_id);
        try std.testing.expectEqual(aos_rng[i].timestamp, soa_rng[i].timestamp);
    }
}
