// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Shared benchmark dataset fixtures — the SINGLE definition of the synthetic
// dataset, its zone/floor topology, and the deterministic seeded generator.
//
// Before this module existed, generateDataset(), sensorTypeFor(), and the
// topology constants were duplicated verbatim across queries.zig, runner.zig,
// and metrics_system.zig — the cross-backend equivalence guarantee silently
// depended on three hand-synced copies staying identical. They now live here.
//
// The zone/floor topology constants are part of the data MODEL convention
// (how sensor_id maps to zone/floor), so the production query functions in
// queries.zig import them from here too — there is one source of truth.
//
// Phase 6's real synthetic generator (engine/synthetic/) will grow into this
// seam: keep the public shape (generateDataset returning an owned slice) so
// callers don't change when the generation model becomes richer.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");

// ---------------------------------------------------------------------------
// Topology — how the synthetic sensor grid maps onto zones and floors.
// Used by both the generator and the production zone/floor queries.
// ---------------------------------------------------------------------------

pub const NUM_SENSORS: u32 = 10;
pub const READINGS_PER_SENSOR: u32 = 50;
pub const BASE_TIMESTAMP: i64 = 1_000_000;
pub const MS_PER_HOUR: i64 = 60 * 60 * 1000;
pub const SENSORS_PER_ZONE: u32 = 5;
pub const ZONES_PER_FLOOR: u32 = 2;
pub const SENSORS_PER_FLOOR: u32 = SENSORS_PER_ZONE * ZONES_PER_FLOOR;

/// Fixed PRNG seed — recorded here so every run is reproducible.
pub const SEED: u64 = 42;

/// Map sensor_id to a sensor type deterministically.
/// Chosen so there are multiple sensors per type and multiple types per zone,
/// which exercises the zone/type/floor filters in the aggregation queries.
/// Used by the default 10-sensor dataset and its equivalence tests.
pub fn sensorTypeFor(sensor_id: u32) sb.SensorType {
    return switch (sensor_id) {
        0, 1, 2 => .temperature,
        3, 4 => .humidity,
        5, 6 => .co2,
        7, 8 => .occupancy,
        else => .energy,
    };
}

/// Even-distribution type mapping for scaled datasets. Uses modulo so every
/// type gets roughly equal representation regardless of sensor count.
pub fn sensorTypeForScaled(sensor_id: u32) sb.SensorType {
    return switch (sensor_id % 5) {
        0 => .temperature,
        1 => .humidity,
        2 => .co2,
        3 => .occupancy,
        else => .energy,
    };
}

// ---------------------------------------------------------------------------
// Scale tiers — multiple dataset sizes to show scaling impact across backends.
// Iterations decrease for larger datasets to keep total runtime reasonable.
// ---------------------------------------------------------------------------

pub const DatasetSpec = struct {
    name: []const u8,
    num_sensors: u32,
    readings_per_sensor: u32,
    iterations: u32,
};

pub const scale_tiers = [_]DatasetSpec{
    .{ .name = "Small", .num_sensors = 10, .readings_per_sensor = 50, .iterations = 25 },
    .{ .name = "Medium", .num_sensors = 50, .readings_per_sensor = 200, .iterations = 25 },
    .{ .name = "Large", .num_sensors = 100, .readings_per_sensor = 500, .iterations = 25 },
};

// ---------------------------------------------------------------------------
// Generation — deterministic from SEED. Same input always produces the same
// stream (CLAUDE.md §3.4). Identical insertion order across backends is what
// makes the golden-result equivalence tests meaningful.
// ---------------------------------------------------------------------------

/// Generate the standard synthetic dataset: NUM_SENSORS sensors, each with
/// READINGS_PER_SENSOR readings at 1-hour intervals starting at BASE_TIMESTAMP.
/// Returns a slice owned by the caller (free with `allocator`).
pub fn generateDataset(allocator: std.mem.Allocator) ![]sb.SensorReading {
    var prng = std.Random.DefaultPrng.init(SEED);
    const rand = prng.random();

    const total = NUM_SENSORS * READINGS_PER_SENSOR;
    const readings = try allocator.alloc(sb.SensorReading, total);

    var idx: usize = 0;
    var sensor: u32 = 0;
    while (sensor < NUM_SENSORS) : (sensor += 1) {
        var reading: u32 = 0;
        while (reading < READINGS_PER_SENSOR) : (reading += 1) {
            const ts = BASE_TIMESTAMP + @as(i64, reading) * MS_PER_HOUR;
            const val: f32 = @floatCast(10.0 + 5.0 * rand.float(f32) + @as(f32, @floatFromInt(sensor)));
            readings[idx] = .{
                .sensor_id = sensor,
                .timestamp = ts,
                .value = val,
                .sensor_type = sensorTypeFor(sensor),
            };
            idx += 1;
        }
    }

    return readings;
}

/// Generate a scaled dataset with arbitrary sensor and reading counts.
/// Uses `sensorTypeForScaled` for even type distribution across large sensor
/// counts. Same deterministic seed as the default dataset.
pub fn generateDatasetScaled(
    allocator: std.mem.Allocator,
    num_sensors: u32,
    readings_per_sensor: u32,
) ![]sb.SensorReading {
    var prng = std.Random.DefaultPrng.init(SEED);
    const rand = prng.random();

    const total = num_sensors * readings_per_sensor;
    const readings = try allocator.alloc(sb.SensorReading, total);

    var idx: usize = 0;
    var sensor: u32 = 0;
    while (sensor < num_sensors) : (sensor += 1) {
        var reading: u32 = 0;
        while (reading < readings_per_sensor) : (reading += 1) {
            const ts = BASE_TIMESTAMP + @as(i64, reading) * MS_PER_HOUR;
            const val: f32 = @floatCast(10.0 + 5.0 * rand.float(f32) + @as(f32, @floatFromInt(sensor)));
            readings[idx] = .{
                .sensor_id = sensor,
                .timestamp = ts,
                .value = val,
                .sensor_type = sensorTypeForScaled(sensor),
            };
            idx += 1;
        }
    }

    return readings;
}

/// Insert a dataset into a world in slice order. Both equivalence partners
/// must receive readings in the same order — deterministic insertion is
/// critical for golden-result comparison.
pub fn insertDataset(world: anytype, readings: []const sb.SensorReading) !void {
    for (readings) |r| try world.insert(r);
}

// ---------------------------------------------------------------------------
// Tests — the generator is deterministic and self-consistent.
// ---------------------------------------------------------------------------

test "generateDataset is deterministic for a fixed seed" {
    const a = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |ra, rb| {
        try std.testing.expectEqual(ra.sensor_id, rb.sensor_id);
        try std.testing.expectEqual(ra.timestamp, rb.timestamp);
        try std.testing.expectEqual(ra.value, rb.value);
        try std.testing.expectEqual(ra.sensor_type, rb.sensor_type);
    }
}

test "generateDataset has the expected shape" {
    const ds = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(ds);

    try std.testing.expectEqual(@as(usize, NUM_SENSORS * READINGS_PER_SENSOR), ds.len);
    // First reading: sensor 0, base timestamp, temperature.
    try std.testing.expectEqual(@as(u32, 0), ds[0].sensor_id);
    try std.testing.expectEqual(BASE_TIMESTAMP, ds[0].timestamp);
    try std.testing.expectEqual(sb.SensorType.temperature, ds[0].sensor_type);
}
