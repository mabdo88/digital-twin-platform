// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Query system — pure functions over World(T) queries.
//
// Per CLAUDE.md §3.1: systems are pure functions over World queries. A system
// does not own state. These functions accept any World(T) via `anytype` and
// never branch on the concrete backend type. The same function compiles and
// runs unchanged whether T is AoSStorage, SoAStorage, or any future backend.

const std = @import("std");
const sb = @import("../storage/storage_backend.zig");

/// Total number of readings stored.
pub fn totalCount(world: anytype) usize {
    return world.count();
}

/// Memory consumed by the backend's internal data structures.
pub fn memoryUsage(world: anytype) usize {
    return world.memoryUsed();
}

/// Most recent reading for a sensor, or null if none exists.
pub fn latestReading(world: anytype, sensor_id: u32) ?sb.SensorReading {
    return world.getLatestBySensor(sensor_id);
}

/// All readings in insertion order. Caller must free via world.allocator.
pub fn allReadings(world: anytype) ![]const sb.SensorReading {
    return world.iterateAll();
}

/// Readings in [start_time, end_time] sorted by timestamp asc, then sensor_id.
/// Caller must free via world.allocator.
pub fn readingsInRange(world: anytype, q: sb.RangeQuery) ![]const sb.SensorReading {
    return world.rangeByTime(q);
}

/// Average value across all readings. Returns 0.0 when empty.
pub fn averageValue(world: anytype) !f32 {
    const all = try world.iterateAll();
    defer world.allocator.free(all);
    if (all.len == 0) return 0.0;
    var sum: f32 = 0;
    for (all) |r| sum += r.value;
    return sum / @as(f32, @floatFromInt(all.len));
}

/// Average value for readings in a time range. Returns 0.0 when empty.
pub fn averageValueInRange(world: anytype, q: sb.RangeQuery) !f32 {
    const results = try world.rangeByTime(q);
    defer world.allocator.free(results);
    if (results.len == 0) return 0.0;
    var sum: f32 = 0;
    for (results) |r| sum += r.value;
    return sum / @as(f32, @floatFromInt(results.len));
}

/// Count of readings for a specific sensor in a time range.
pub fn countForSensorInRange(world: anytype, sensor_id: u32, q: sb.RangeQuery) !usize {
    const results = try world.rangeByTime(.{
        .sensor_id = sensor_id,
        .start_time = q.start_time,
        .end_time = q.end_time,
    });
    defer world.allocator.free(results);
    return results.len;
}
