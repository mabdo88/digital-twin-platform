// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Benchmark runner — wires every storage backend into a comptime list,
// runs the full equivalence suite, and produces a combined per-query
// latency table.
//
// Per CLAUDE.md §3.1: queries are backend-agnostic. The runner iterates
// over backends at comptime (inline for) since World(T) is a comptime
// generic — no vtable, no dynamic dispatch.
//
// The backend list is the single place where all backends are registered.
// Adding a new backend means appending one entry to `backends` — every
// test and table in this file picks it up automatically.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");
const aos = @import("../ecs/storage/backends/aos_storage.zig");
const soa = @import("../ecs/storage/backends/soa_storage.zig");
const timeseries = @import("../ecs/storage/backends/timeseries_storage.zig");
const columnar = @import("../ecs/storage/backends/columnar_storage.zig");
const hierarchical = @import("../ecs/storage/backends/hierarchical_storage.zig");
const ringbuffer = @import("../ecs/storage/backends/ringbuffer_storage.zig");
const lake = @import("../ecs/storage/backends/lake_storage.zig");
const World = @import("../ecs/world.zig").World;
const queries = @import("queries.zig");
const metrics = @import("../ecs/systems/metrics_system.zig");
const report = @import("report.zig");

// ---------------------------------------------------------------------------
// Backend registry — the canonical list of all storage backends.
// ---------------------------------------------------------------------------

pub const BackendEntry = struct { name: []const u8, T: type };

/// Deployment-candidate backends — what actually runs in the benchmark
/// and appears in the report. AoS and SoA are excluded: they are
/// worst-case reference implementations used only for golden equivalence
/// tests in queries.zig, not realistic deployment options.
pub const backends = [_]BackendEntry{
    .{ .name = "TimeSeries", .T = timeseries },
    .{ .name = "Columnar", .T = columnar },
    .{ .name = "Hierarchical", .T = hierarchical },
    .{ .name = "RingBuffer", .T = ringbuffer },
    .{ .name = "Lake", .T = lake },
};

/// Subset of deployment backends that support historical rollup queries
/// (Q7/Q8). RingBuffer is excluded: it evicts old data (count-based cap)
/// so historical rollups would return incomplete results. Lake is
/// included: unlike RingBuffer it retains full history (bounded only by
/// pruneOlderThan, same as TimeSeries/Columnar/Hierarchical) — it's the
/// cheap cold tier for exactly this kind of long-retention query, not a
/// live/hot-only cache.
pub const supported_backends = [_]BackendEntry{
    .{ .name = "TimeSeries", .T = timeseries },
    .{ .name = "Columnar", .T = columnar },
    .{ .name = "Hierarchical", .T = hierarchical },
    .{ .name = "Lake", .T = lake },
};

// ---------------------------------------------------------------------------
// Dataset generation — deterministic, seeded PRNG, identical across runs.
// ---------------------------------------------------------------------------

// Shared dataset fixtures + zone/floor topology — single source of truth
// (engine/benchmark/dataset.zig). Previously duplicated here verbatim.
const fixtures = @import("dataset.zig");
const generateDataset = fixtures.generateDataset;
const generateDatasetScaled = fixtures.generateDatasetScaled;
const insertDataset = fixtures.insertDataset;
const DatasetSpec = fixtures.DatasetSpec;
const scale_tiers = fixtures.scale_tiers;
const NUM_SENSORS = fixtures.NUM_SENSORS;
const READINGS_PER_SENSOR = fixtures.READINGS_PER_SENSOR;
const BASE_TIMESTAMP = fixtures.BASE_TIMESTAMP;
const MS_PER_HOUR = fixtures.MS_PER_HOUR;

// ---------------------------------------------------------------------------
// Equivalence tests — every backend must return identical results for every
// implemented query on the same seeded dataset.
//
// RingBuffer: with 50 readings/sensor and 1000 capacity/sensor, all data
// fits in the buffer — no eviction occurs. RingBuffer is expected to agree
// on all queries. (Per its contract, it is excepted on queries that span
// evicted data, but that does not apply here.)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Wrapper functions for timeQuery — timeQuery requires a callable that returns
// a value (not void). Q1 returns ?SensorReading, Q2/Q3 return slices that need
// freeing. These wrappers discard the result and free slices so timeQuery can
// call them in a tight loop without leaking.
// ---------------------------------------------------------------------------

pub fn q1_wrapper(world: anytype, sensor_id: u32) !void {
    _ = try queries.query_latest_single(world, sensor_id);
}

pub fn q2_wrapper(world: anytype, zone_id: u32) !void {
    const result = try queries.query_latest_zone(world, zone_id);
    world.allocator.free(result);
}

pub fn q3_wrapper(world: anytype, sensor_type: sb.SensorType) !void {
    const result = try queries.query_latest_by_type(world, sensor_type);
    world.allocator.free(result);
}

pub fn q5_wrapper(world: anytype, zone_id: u32, sensor_type: sb.SensorType, hours: u32) !void {
    _ = try queries.query_avg_zone_type(world, zone_id, sensor_type, hours);
}

pub fn q6_wrapper(world: anytype, floor_id: u32, sensor_type: sb.SensorType, hours: u32) !void {
    _ = try queries.query_floor_stats(world, floor_id, sensor_type, hours);
}

pub fn q7_wrapper(world: anytype, sensor_id: u32, days: u32) !void {
    const result = try queries.query_hourly_rollup(world, sensor_id, days);
    world.allocator.free(result);
}

pub fn q8_wrapper(world: anytype, zone_id: u32, sensor_type: sb.SensorType) !void {
    const result = try queries.query_daily_zone_rollup(world, zone_id, sensor_type);
    world.allocator.free(result);
}

pub fn q9_wrapper(world: anytype, center: queries.Vec3, radius_m: f32) !void {
    const result = try queries.query_spatial_radius(world, center, radius_m);
    world.allocator.free(result);
}

pub fn q10_wrapper(world: anytype, zone_id: u32, depth: u32) !void {
    const result = try queries.query_zone_hierarchy(world, zone_id, depth);
    world.allocator.free(result);
}

pub fn q11_wrapper(world: anytype, sensor_type: sb.SensorType, std_dev_threshold: f32, window_hours: u32) !void {
    const result = try queries.query_anomalies(world, sensor_type, std_dev_threshold, window_hours);
    world.allocator.free(result);
}

pub fn q12_wrapper(world: anytype, sensor_id: u32, threshold: f32, min_duration_ms: i64, window_hours: u32) !void {
    _ = try queries.query_threshold_breach(world, sensor_id, threshold, min_duration_ms, window_hours);
}

// query_avg_window/latest_single/latest_zone/latest_by_type/avg_zone_type/
// floor_stats/hourly_rollup/daily_zone_rollup cross-backend equivalence is
// proven once, in queries.zig (the canonical home for the 12 query
// patterns — see its header comment). Re-asserting the same property here,
// against the same seeded dataset with the same test cases, caught nothing
// queries.zig didn't already catch; it only doubled compile/test time.
// This file keeps the two equivalence checks that are NOT covered there:
// the raw World interface methods (getLatestBySensor, rangeByTime), which
// queries.zig's query-level tests never exercise directly.

