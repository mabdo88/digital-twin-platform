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

pub fn allSensorIds(self: *const Self, allocator: std.mem.Allocator) ![]u32 {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    for (self.readings.items) |r| try seen.put(r.sensor_id, {});
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);
    var it = seen.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Removes every reading of `sensor_type` older than `cutoff_timestamp` via
/// an in-place stable compaction (readings of other types, and this
/// backend's zone/floor topology, are untouched). See storage_backend.zig's
/// pruneOlderThan contract.
/// AoS has no fixed-capacity concept — it holds everything inserted,
/// bounded only by pruneOlderThan. No-op, per storage_backend.zig's
/// setRetentionHint contract.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

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
// Tests — this file had none until 2026-07-20. pruneOlderThan's in-place
// compaction (the same shape every flat backend uses) is the one piece of
// logic here complex enough for a regression to silently corrupt data: it
// must remove ONLY readings matching both `sensor_type` and the cutoff,
// leaving every other type's readings, and later readings of the pruned
// type, untouched.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pruneOlderThan: removes only matching-type readings older than cutoff; other types and newer same-type readings survive" {
    const allocator = testing.allocator;
    var backend = try Self.init(allocator);
    defer backend.deinit();

    // Interleaved: temperature at ts 1,2,3 and humidity at ts 1,2,3.
    var t: i64 = 1;
    while (t <= 3) : (t += 1) {
        try backend.insert(.{ .sensor_id = 1, .timestamp = t, .value = 0, .sensor_type = .temperature });
        try backend.insert(.{ .sensor_id = 2, .timestamp = t, .value = 0, .sensor_type = .humidity });
    }
    try testing.expectEqual(@as(usize, 6), backend.count());

    // Cutoff 3: removes temperature ts<3 (ts=1,2), keeps temperature ts=3
    // and every humidity reading regardless of timestamp.
    try backend.pruneOlderThan(.temperature, 3);

    try testing.expectEqual(@as(usize, 4), backend.count());
    var temp_count: usize = 0;
    var humidity_count: usize = 0;
    for (backend.readings.items) |r| {
        switch (r.sensor_type) {
            .temperature => {
                temp_count += 1;
                try testing.expectEqual(@as(i64, 3), r.timestamp);
            },
            .humidity => humidity_count += 1,
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 1), temp_count);
    try testing.expectEqual(@as(usize, 3), humidity_count);
}

// ---------------------------------------------------------------------------
