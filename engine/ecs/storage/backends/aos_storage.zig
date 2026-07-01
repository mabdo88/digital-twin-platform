// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Array-of-Structs backend — the intuitive baseline.
//
// All readings are stored in a single contiguous ArrayList(SensorReading).
// Iteration order: insertion order (NOT sorted).
// This layout is cache-unfriendly for bulk field queries (e.g. "average
// value across all sensors") because each SensorReading fetches an entire
// 20-byte struct even when only one field is needed.

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

allocator: std.mem.Allocator,
readings: std.ArrayList(SensorReading),
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{ .allocator = allocator, .readings = .empty, .zone_index = ZoneIndex.init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.readings.deinit(self.allocator);
    self.zone_index.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    try self.readings.append(self.allocator, reading);
}

pub fn count(self: *const Self) usize {
    return self.readings.items.len;
}

pub fn memoryUsed(self: *const Self) usize {
    return self.readings.capacity * @sizeOf(SensorReading) + self.zone_index.memoryUsed();
}

/// Iteration order: insertion order.
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const result = try allocator.alloc(SensorReading, self.readings.items.len);
    @memcpy(result, self.readings.items);
    return result;
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    var best: ?SensorReading = null;
    for (self.readings.items) |r| {
        if (r.sensor_id != sensor_id) continue;
        if (best == null or r.timestamp > best.?.timestamp) {
            best = r;
        }
    }
    return best;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    for (self.readings.items) |r| {
        if (r.timestamp < q.start_time or r.timestamp > q.end_time) continue;
        if (q.sensor_id) |sid| {
            if (r.sensor_id != sid) continue;
        }
        try result.append(allocator, r);
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

/// Zone/floor topology bookkeeping delegates to the shared ZoneIndex — see
/// storage_backend.zig's doc comment for the contract and zone_index.zig's
/// header for why this is shared rather than copy-pasted per backend.
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

/// Removes every reading of `sensor_type` older than `cutoff_timestamp` via
/// an in-place stable compaction (readings of other types, and this
/// backend's zone/floor topology, are untouched). See storage_backend.zig's
/// pruneOlderThan contract.
pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    var write: usize = 0;
    for (self.readings.items) |r| {
        if (r.sensor_type == sensor_type and r.timestamp < cutoff_timestamp) continue;
        self.readings.items[write] = r;
        write += 1;
    }
    self.readings.shrinkRetainingCapacity(write);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AoS: assertImplements" {
    sb.assertImplements(Self);
}

test "AoS: insert N readings and read them back" {
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

test "AoS: getLatestBySensor" {
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

test "AoS: rangeByTime filters and sorts" {
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

test "AoS: rangeByTime with sensor filter" {
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

test "AoS: sensorIdsByZone/sensorIdsByFloor reflect real (non-arithmetic) registration" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Arbitrary, non-sequential ids — like a real building's IFC entity
    // ids, not a fixed-width sensor_id/N convention.
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

    // An unregistered zone/floor is empty, not an error.
    const empty = try backend.sensorIdsByZone(std.testing.allocator, 99);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "AoS: getLatestBySensor is deterministic across repeated calls when timestamps tie" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Two readings for the same sensor, same timestamp. The interface
    // contract (storage_backend.zig) explicitly allows any one of them to
    // win the tie — it does NOT require agreement with other backends —
    // but a single backend must keep answering the same way call after
    // call, not flip-flop.
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 20.0, .sensor_type = .temperature });

    const first = backend.getLatestBySensor(1).?;
    const second = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 100), first.timestamp);
    try std.testing.expectEqual(first.value, second.value);
}

test "AoS: empty backend" {
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

test "AoS: pruneOlderThan removes only the matching type older than cutoff" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 150, .value = 2.0, .sensor_type = .temperature });
    // Same age as the pruned temperature reading, but a different type —
    // must survive.
    try backend.insert(.{ .sensor_id = 2, .timestamp = 50, .value = 3.0, .sensor_type = .humidity });

    try backend.pruneOlderThan(.temperature, 100);

    try std.testing.expectEqual(@as(usize, 2), backend.count());
    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);

    var found_old_temp = false;
    var found_new_temp = false;
    var found_humidity = false;
    for (all) |r| {
        if (r.sensor_type == .temperature and r.timestamp == 50) found_old_temp = true;
        if (r.sensor_type == .temperature and r.timestamp == 150) found_new_temp = true;
        if (r.sensor_type == .humidity and r.timestamp == 50) found_humidity = true;
    }
    try std.testing.expect(!found_old_temp);
    try std.testing.expect(found_new_temp);
    try std.testing.expect(found_humidity);
}
