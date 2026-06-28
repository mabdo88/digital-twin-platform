// Zig 0.16.0 (tested against 0.17.0-dev)
//
// World(T) — the generic ECS World parameterised over a storage backend.
//
// Per CLAUDE.md §5: the World is parameterised at compile time with a storage
// backend. The same query compiles and runs against any backend. No World-
// level code branches on the concrete backend type (CLAUDE.md §3.1).
//
// Usage:
//   var world_aos = try World(AoSStorage).init(allocator);
//   var world_soa = try World(SoAStorage).init(allocator);
//   try world_aos.insert(reading);
//   const latest = world_aos.getLatestBySensor(1);

const std = @import("std");
const sb = @import("storage/storage_backend.zig");

pub fn World(comptime Backend: type) type {
    // Compile-time contract: Backend must implement the full interface.
    sb.assertImplements(Backend);

    return struct {
        backend: Backend,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .backend = try Backend.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }

        pub fn insert(self: *Self, reading: sb.SensorReading) !void {
            return self.backend.insert(reading);
        }

        pub fn count(self: *const Self) usize {
            return self.backend.count();
        }

        pub fn memoryUsed(self: *const Self) usize {
            return self.backend.memoryUsed();
        }

        pub fn iterateAll(self: *const Self) ![]const sb.SensorReading {
            return self.backend.iterateAll(self.allocator);
        }

        pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?sb.SensorReading {
            return self.backend.getLatestBySensor(sensor_id);
        }

        pub fn rangeByTime(self: *const Self, q: sb.RangeQuery) ![]const sb.SensorReading {
            return self.backend.rangeByTime(self.allocator, q);
        }

        pub fn sensorIdsByGroup(self: *const Self, group_id: u32, divisor: u32) ![]u32 {
            return self.backend.sensorIdsByGroup(self.allocator, group_id, divisor);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — instantiate World(T) for both baseline backends and verify the
// same queries produce identical results.
// ---------------------------------------------------------------------------

const aos = @import("storage/backends/aos_storage.zig");
const soa = @import("storage/backends/soa_storage.zig");
const columnar = @import("storage/backends/columnar_storage.zig");
const query_system = @import("systems/query_system.zig");

fn insertTestData(world: anytype) !void {
    const readings = [_]sb.SensorReading{
        .{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature },
        .{ .sensor_id = 1, .timestamp = 300, .value = 30.0, .sensor_type = .temperature },
        .{ .sensor_id = 1, .timestamp = 200, .value = 20.0, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 150, .value = 15.0, .sensor_type = .humidity },
        .{ .sensor_id = 2, .timestamp = 250, .value = 25.0, .sensor_type = .humidity },
    };
    for (readings) |r| try world.insert(r);
}

test "World(AoS) instantiates and basic operations work" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    try insertTestData(&world);
    try std.testing.expectEqual(@as(usize, 5), world.count());

    const latest = world.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);
}

test "World(SoA) instantiates and basic operations work" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    try insertTestData(&world);
    try std.testing.expectEqual(@as(usize, 5), world.count());

    const latest = world.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);
}

test "World(Columnar) instantiates and basic operations work" {
    var world = try World(columnar).init(std.testing.allocator);
    defer world.deinit();

    try insertTestData(&world);
    try std.testing.expectEqual(@as(usize, 5), world.count());

    const latest = world.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);
}

test "World(AoS) and World(SoA) produce identical query results" {
    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();

    try insertTestData(&world_aos);
    try insertTestData(&world_soa);

    // count
    try std.testing.expectEqual(world_aos.count(), world_soa.count());

    // getLatestBySensor
    const latest_aos = world_aos.getLatestBySensor(1).?;
    const latest_soa = world_soa.getLatestBySensor(1).?;
    try std.testing.expectEqual(latest_aos.timestamp, latest_soa.timestamp);
    try std.testing.expectEqual(latest_aos.value, latest_soa.value);

    // rangeByTime
    const range_aos = try world_aos.rangeByTime(.{ .start_time = 100, .end_time = 200 });
    defer world_aos.allocator.free(range_aos);
    const range_soa = try world_soa.rangeByTime(.{ .start_time = 100, .end_time = 200 });
    defer world_soa.allocator.free(range_soa);

    try std.testing.expectEqual(range_aos.len, range_soa.len);
    for (0..range_aos.len) |i| {
        try std.testing.expectEqual(range_aos[i].sensor_id, range_soa[i].sensor_id);
        try std.testing.expectEqual(range_aos[i].timestamp, range_soa[i].timestamp);
        try std.testing.expectEqual(range_aos[i].value, range_soa[i].value);
    }

    // iterateAll
    const all_aos = try world_aos.iterateAll();
    defer world_aos.allocator.free(all_aos);
    const all_soa = try world_soa.iterateAll();
    defer world_soa.allocator.free(all_soa);

    try std.testing.expectEqual(all_aos.len, all_soa.len);
    for (0..all_aos.len) |i| {
        try std.testing.expectEqual(all_aos[i].sensor_id, all_soa[i].sensor_id);
        try std.testing.expectEqual(all_aos[i].timestamp, all_soa[i].timestamp);
        try std.testing.expectEqual(all_aos[i].value, all_soa[i].value);
    }
}

test "query_system functions work unchanged on World(AoS)" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    try insertTestData(&world);

    try std.testing.expectEqual(@as(usize, 5), query_system.totalCount(&world));

    const avg = try query_system.averageValue(&world);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), avg, 0.01);

    const avg_range = try query_system.averageValueInRange(&world, .{ .start_time = 100, .end_time = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), avg_range, 0.01);
}

test "query_system functions work unchanged on World(SoA)" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();
    try insertTestData(&world);

    try std.testing.expectEqual(@as(usize, 5), query_system.totalCount(&world));

    const avg = try query_system.averageValue(&world);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), avg, 0.01);

    const avg_range = try query_system.averageValueInRange(&world, .{ .start_time = 100, .end_time = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), avg_range, 0.01);
}

test "query_system functions work unchanged on World(Columnar)" {
    var world = try World(columnar).init(std.testing.allocator);
    defer world.deinit();
    try insertTestData(&world);

    try std.testing.expectEqual(@as(usize, 5), query_system.totalCount(&world));

    const avg = try query_system.averageValue(&world);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), avg, 0.01);

    const avg_range = try query_system.averageValueInRange(&world, .{ .start_time = 100, .end_time = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), avg_range, 0.01);
}

test "World(AoS) memoryUsed reports nonzero after insert" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 0), world.memoryUsed());
    try insertTestData(&world);
    try std.testing.expect(world.memoryUsed() > 0);
}

test "World(Columnar) memoryUsed reports nonzero after insert" {
    var world = try World(columnar).init(std.testing.allocator);
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 0), world.memoryUsed());
    try insertTestData(&world);
    try std.testing.expect(world.memoryUsed() > 0);
}
