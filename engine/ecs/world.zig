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

        pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
            return self.backend.registerZone(sensor_id, zone_id);
        }

        pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
            return self.backend.registerFloor(zone_id, floor_id);
        }

        pub fn sensorIdsByZone(self: *const Self, zone_id: u32) ![]u32 {
            return self.backend.sensorIdsByZone(self.allocator, zone_id);
        }

        pub fn sensorIdsByFloor(self: *const Self, floor_id: u32) ![]u32 {
            return self.backend.sensorIdsByFloor(self.allocator, floor_id);
        }

        pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
            return self.backend.floorOfZone(zone_id);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — instantiate World(T) for both baseline backends and verify the
// same queries produce identical results.
// ---------------------------------------------------------------------------

const aos = @import("storage/backends/aos_storage.zig");
const soa = @import("storage/backends/soa_storage.zig");
const timeseries = @import("storage/backends/timeseries_storage.zig");
const columnar = @import("storage/backends/columnar_storage.zig");
const hierarchical = @import("storage/backends/hierarchical_storage.zig");
const ringbuffer = @import("storage/backends/ringbuffer_storage.zig");
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

// World(T) is a pure pass-through (every method is one line calling the
// same-named backend method) — it has no branching of its own to cover per
// backend. One instantiation smoke test is enough to prove the generic
// wires up correctly; per-backend correctness is the backends' own test
// files' job, and cross-backend agreement on the full seeded benchmark
// dataset is runner.zig's "equivalence" suite, which covers all six
// backends rather than just two.
test "World(T) instantiates and wires through to the backend" {
    var world = try World(hierarchical).init(std.testing.allocator);
    defer world.deinit();

    try insertTestData(&world);
    try std.testing.expectEqual(@as(usize, 5), world.count());

    const latest = world.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);
}

test "query_system functions work on World(T)" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    try insertTestData(&world);

    try std.testing.expectEqual(@as(usize, 5), query_system.totalCount(&world));

    const avg = try query_system.averageValue(&world);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), avg, 0.01);

    const avg_range = try query_system.averageValueInRange(&world, .{ .start_time = 100, .end_time = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), avg_range, 0.01);
}

// Closes a real gap: before this, only AoS and Columnar had any assertion
// that memoryUsed() is nonzero after insert — SoA, TimeSeries, Hierarchical,
// and RingBuffer had zero coverage of this despite memoryUsed() feeding
// directly into every benchmark report and the (future) cost model.
//
// NOTE: "zero bytes when empty" is NOT a cross-backend invariant — it was
// an unstated assumption baked into the two pre-existing tests this one
// replaces, true only because AoS/Columnar happen to allocate lazily.
// Hierarchical pre-allocates a root tree node in init() (224 bytes before
// any insert), which is real, intentional overhead, not a bug. The only
// property every backend's contract actually promises is that memoryUsed()
// reflects what's stored — so the universal check is growth, not a zero
// floor.
test "World(T) memoryUsed strictly grows after insert, for all six backends" {
    const all_backends = .{ aos, soa, timeseries, columnar, hierarchical, ringbuffer };
    inline for (all_backends) |Backend| {
        var world = try World(Backend).init(std.testing.allocator);
        defer world.deinit();
        const before = world.memoryUsed();
        try insertTestData(&world);
        try std.testing.expect(world.memoryUsed() > before);
    }
}
