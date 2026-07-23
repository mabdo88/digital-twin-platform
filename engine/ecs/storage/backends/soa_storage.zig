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
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

allocator: std.mem.Allocator,
sensor_ids: std.ArrayList(u32),
timestamps: std.ArrayList(i64),
values: std.ArrayList(f32),
sensor_types: std.ArrayList(SensorType),
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .sensor_ids = .empty,
        .timestamps = .empty,
        .values = .empty,
        .sensor_types = .empty,
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.sensor_ids.deinit(self.allocator);
    self.timestamps.deinit(self.allocator);
    self.values.deinit(self.allocator);
    self.sensor_types.deinit(self.allocator);
    self.zone_index.deinit();
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
        self.sensor_types.capacity * @sizeOf(SensorType) +
        self.zone_index.memoryUsed();
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
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    for (self.sensor_ids.items) |sid| try seen.put(sid, {});
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);
    var it = seen.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Removes every reading of `sensor_type` older than `cutoff_timestamp` via
/// an in-place stable compaction across all four parallel arrays (readings
/// of other types, and this backend's zone/floor topology, are untouched).
/// See storage_backend.zig's pruneOlderThan contract.
/// SoA has no fixed-capacity concept — see aos_storage.zig's
/// setRetentionHint for why this is a no-op.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    var write: usize = 0;
    for (self.sensor_ids.items, 0..) |sid, i| {
        const ts = self.timestamps.items[i];
        const st = self.sensor_types.items[i];
        if (st == sensor_type and ts < cutoff_timestamp) continue;
        self.sensor_ids.items[write] = sid;
        self.timestamps.items[write] = ts;
        self.values.items[write] = self.values.items[i];
        self.sensor_types.items[write] = st;
        write += 1;
    }
    self.sensor_ids.shrinkRetainingCapacity(write);
    self.timestamps.shrinkRetainingCapacity(write);
    self.values.shrinkRetainingCapacity(write);
    self.sensor_types.shrinkRetainingCapacity(write);
}

// ---------------------------------------------------------------------------
// Tests — this file had none until 2026-07-20. pruneOlderThan's compaction
// is the one place unique to SoA's structure that a naive AoS-style fix
// could get wrong: it must advance FOUR parallel arrays in lockstep. A bug
// that shrinks or writes one array out of sync with the others wouldn't
// change row counts — it would silently reassign a surviving row's value or
// sensor_type to the wrong sensor_id/timestamp.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pruneOlderThan: compaction keeps all four parallel arrays in lockstep — surviving rows keep their original value" {
    const allocator = testing.allocator;
    var backend = try Self.init(allocator);
    defer backend.deinit();

    // Each reading's value is a fingerprint of its own (sensor_id,
    // timestamp) pair — if the arrays ever desync during compaction, a
    // surviving row's value won't match its own sensor_id/timestamp anymore
    // and the assertion below catches it directly, rather than just
    // checking counts.
    const fingerprint = struct {
        fn f(sensor_id: u32, ts: i64) f32 {
            return @floatFromInt(sensor_id * 1000 + @as(u32, @intCast(ts)));
        }
    }.f;

    var t: i64 = 1;
    while (t <= 5) : (t += 1) {
        try backend.insert(.{ .sensor_id = 1, .timestamp = t, .value = fingerprint(1, t), .sensor_type = .temperature });
        try backend.insert(.{ .sensor_id = 2, .timestamp = t, .value = fingerprint(2, t), .sensor_type = .humidity });
    }
    try testing.expectEqual(@as(usize, 10), backend.count());

    // Prune temperature (sensor 1) readings older than ts=4 — removes
    // ts=1,2,3 for sensor 1 only. Humidity (sensor 2) is untouched.
    try backend.pruneOlderThan(.temperature, 4);
    try testing.expectEqual(@as(usize, 7), backend.count());

    const survivors = try backend.iterateAll(allocator);
    defer allocator.free(survivors);
    try testing.expectEqual(@as(usize, 7), survivors.len);
    for (survivors) |r| {
        try testing.expectEqual(fingerprint(r.sensor_id, r.timestamp), r.value);
        if (r.sensor_type == .temperature) try testing.expect(r.timestamp >= 4);
    }
}

// ---------------------------------------------------------------------------
