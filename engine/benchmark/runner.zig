// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Benchmark runner — wires all six storage backends into a comptime list,
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
};

/// Subset of deployment backends that support historical rollup queries
/// (Q7/Q8). RingBuffer is excluded: it evicts old data so historical
/// rollups would return incomplete results.
pub const supported_backends = [_]BackendEntry{
    .{ .name = "TimeSeries", .T = timeseries },
    .{ .name = "Columnar", .T = columnar },
    .{ .name = "Hierarchical", .T = hierarchical },
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

pub fn q11_wrapper(world: anytype, sensor_type: sb.SensorType, std_dev_threshold: f32) !void {
    const result = try queries.query_anomalies(world, sensor_type, std_dev_threshold);
    world.allocator.free(result);
}

pub fn q12_wrapper(world: anytype, sensor_id: u32, threshold: f32, min_duration_ms: i64) !void {
    _ = try queries.query_threshold_breach(world, sensor_id, threshold, min_duration_ms);
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

test "equivalence: getLatestBySensor across all six backends" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    for (0..NUM_SENSORS) |s| {
        const sensor: u32 = @intCast(s);
        var results: [backends.len]?sb.SensorReading = undefined;

        inline for (0..backends.len) |i| {
            const b = backends[i];
            var world = try World(b.T).init(std.testing.allocator);
            defer world.deinit();
            try insertDataset(&world, dataset);
            results[i] = world.getLatestBySensor(sensor);
        }

        const ref = results[0];
        for (1..results.len) |i| {
            if (ref) |r| {
                try std.testing.expect(results[i] != null);
                try std.testing.expectEqual(r.timestamp, results[i].?.timestamp);
                try std.testing.expectEqual(r.sensor_id, results[i].?.sensor_id);
                try std.testing.expectApproxEqAbs(r.value, results[i].?.value, 1e-5);
            } else {
                try std.testing.expect(results[i] == null);
            }
        }
    }
}

test "equivalence: getLatestBySensor agrees on null across all six backends (nonexistent sensor, and empty world)" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    inline for (backends) |b| {
        var populated = try World(b.T).init(std.testing.allocator);
        defer populated.deinit();
        try insertDataset(&populated, dataset);
        try std.testing.expect(populated.getLatestBySensor(999) == null);

        var empty = try World(b.T).init(std.testing.allocator);
        defer empty.deinit();
        try std.testing.expect(empty.getLatestBySensor(0) == null);
    }
}

test "equivalence: rangeByTime across all six backends" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    const test_cases = [_]struct { sensor: ?u32, start: i64, end: i64 }{
        .{ .sensor = null, .start = BASE_TIMESTAMP, .end = BASE_TIMESTAMP + 10 * MS_PER_HOUR },
        .{ .sensor = 0, .start = BASE_TIMESTAMP, .end = BASE_TIMESTAMP + 24 * MS_PER_HOUR },
        .{ .sensor = 5, .start = BASE_TIMESTAMP, .end = BASE_TIMESTAMP + 50 * MS_PER_HOUR },
        .{ .sensor = null, .start = BASE_TIMESTAMP + 20 * MS_PER_HOUR, .end = BASE_TIMESTAMP + 30 * MS_PER_HOUR },
        // Edge case: exact single-instant range (start == end == a real
        // reading's timestamp). Never exercised before — boundary-inclusive
        // logic differs in shape per backend (binary search bounds vs.
        // linear <= / >= filters) so this is the case most likely to
        // diverge by an off-by-one.
        .{ .sensor = 0, .start = BASE_TIMESTAMP, .end = BASE_TIMESTAMP },
        // Edge case: inverted range (start > end). No documented contract
        // forbids this input; every backend's filter is `ts < start or ts
        // > end`, which is unsatisfiable for any ts when start > end, so
        // this should come back empty everywhere without special-casing.
        .{ .sensor = null, .start = BASE_TIMESTAMP + 10 * MS_PER_HOUR, .end = BASE_TIMESTAMP },
    };

    for (test_cases) |tc| {
        var lengths: [backends.len]usize = undefined;
        var first_vals: [backends.len]f32 = undefined;
        var last_vals: [backends.len]f32 = undefined;
        var sums: [backends.len]f64 = undefined;

        inline for (0..backends.len) |i| {
            const b = backends[i];
            var world = try World(b.T).init(std.testing.allocator);
            defer world.deinit();
            try insertDataset(&world, dataset);
            const result = try world.rangeByTime(.{
                .sensor_id = tc.sensor,
                .start_time = tc.start,
                .end_time = tc.end,
            });
            defer std.testing.allocator.free(result);

            lengths[i] = result.len;
            if (result.len > 0) {
                first_vals[i] = result[0].value;
                last_vals[i] = result[result.len - 1].value;
                var sum: f64 = 0;
                for (result) |r| sum += @as(f64, r.value);
                sums[i] = sum;
            }
        }

        for (1..backends.len) |i| {
            try std.testing.expectEqual(lengths[0], lengths[i]);
            if (lengths[0] > 0) {
                try std.testing.expectApproxEqAbs(first_vals[0], first_vals[i], 1e-5);
                try std.testing.expectApproxEqAbs(last_vals[0], last_vals[i], 1e-5);
                try std.testing.expectApproxEqAbs(sums[0], sums[i], 1e-3);
            }
        }
    }
}

test "equivalence: inverted rangeByTime (start > end) returns empty on every backend" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    inline for (backends) |b| {
        var world = try World(b.T).init(std.testing.allocator);
        defer world.deinit();
        try insertDataset(&world, dataset);

        const result = try world.rangeByTime(.{
            .start_time = BASE_TIMESTAMP + 30 * MS_PER_HOUR,
            .end_time = BASE_TIMESTAMP,
        });
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }
}

// ---------------------------------------------------------------------------
// Latency table — data-driven (Task 3.6).
//
// Every query is described once in `query_specs`. The runner loops every spec
// across every backend with a single nested `inline for` — there is no
// per-query or per-backend special-casing, and the only thing a spec needs to
// know is whether it is a historical rollup (RingBuffer-unsupported).
//
// Adding a query: append one entry to `query_specs`.
// Adding a backend: append one entry to `backends` (top of file).
// Neither requires touching the loop.
// ---------------------------------------------------------------------------

/// One row of the latency table. `func` is normalised to a callable taking
/// (world, args...) and returning `!void` (slice-returning queries are wrapped
/// above to free their result). `historical` selects supported_backends.
const query_specs = .{
    .{ .name = "query_avg_window", .func = queries.query_avg_window, .args = .{ @as(u32, 0), @as(u32, 24) }, .historical = false },
    .{ .name = "query_latest_single", .func = q1_wrapper, .args = .{@as(u32, 0)}, .historical = false },
    .{ .name = "query_latest_zone", .func = q2_wrapper, .args = .{@as(u32, 0)}, .historical = false },
    .{ .name = "query_latest_by_type", .func = q3_wrapper, .args = .{sb.SensorType.temperature}, .historical = false },
    .{ .name = "query_avg_zone_type", .func = q5_wrapper, .args = .{ @as(u32, 0), sb.SensorType.temperature, @as(u32, 24) }, .historical = false },
    .{ .name = "query_floor_stats", .func = q6_wrapper, .args = .{ @as(u32, 0), sb.SensorType.temperature, @as(u32, 24) }, .historical = false },
    .{ .name = "query_spatial_radius", .func = q9_wrapper, .args = .{ queries.Vec3{ .x = 22.5, .y = 0.0, .z = 0.0 }, @as(f32, 25.0) }, .historical = false },
    .{ .name = "query_zone_hierarchy", .func = q10_wrapper, .args = .{ @as(u32, 0), @as(u32, 1) }, .historical = false },
    .{ .name = "query_anomalies", .func = q11_wrapper, .args = .{ sb.SensorType.temperature, @as(f32, 1.0) }, .historical = false },
    .{ .name = "query_threshold_breach", .func = q12_wrapper, .args = .{ @as(u32, 0), @as(f32, 9.5), @as(i64, 60 * 60 * 1000) }, .historical = false },
    .{ .name = "query_hourly_rollup", .func = q7_wrapper, .args = .{ @as(u32, 0), @as(u32, 2) }, .historical = true },
    .{ .name = "query_daily_zone_rollup", .func = q8_wrapper, .args = .{ @as(u32, 0), sb.SensorType.temperature }, .historical = true },
};

fn printRow(scale_label: []const u8, query_name: []const u8, backend_name: []const u8, stats: metrics.LatencyStats) void {
    std.debug.print("{s:<8} {s:<24} {s:<15} {d:>12} {d:>10.1} {d:>12} {d:>10.1} {d:>12} {d:>10.1} {d:>12} {d:>10.1} {d:>12.0}ops/s\n", .{
        scale_label,
        query_name,
        backend_name,
        stats.median_ns,
        @as(f64, @floatFromInt(stats.median_ns)) / 1000.0,
        stats.p95_ns,
        @as(f64, @floatFromInt(stats.p95_ns)) / 1000.0,
        stats.p99_ns,
        @as(f64, @floatFromInt(stats.p99_ns)) / 1000.0,
        stats.mean_ns,
        @as(f64, @floatFromInt(stats.mean_ns)) / 1000.0,
        stats.throughputOpsPerSec(),
    });
}

/// Time one (query, backend) pair on a freshly-ingested world and append its row.
/// `spec` and `b` are comptime so World(b.T) and spec.func resolve statically.
fn benchOne(
    comptime spec: anytype,
    comptime b: BackendEntry,
    allocator: std.mem.Allocator,
    io: std.Io,
    iterations: u32,
    readings: []const sb.SensorReading,
    scale_label: []const u8,
    rows: *std.ArrayList(report.RunRow),
) !void {
    var world = try World(b.T).init(allocator);
    defer world.deinit();
    try insertDataset(&world, readings);

    const stats = try metrics.timeQuery(
        allocator,
        io,
        iterations,
        spec.func,
        .{&world} ++ spec.args,
    );

    const row = report.RunRow{
        .scale = scale_label,
        .query = spec.name,
        .backend = b.name,
        .memory_bytes = world.memoryUsed(),
        .stats = stats,
    };
    try rows.append(allocator, row);
    printRow(scale_label, spec.name, b.name, stats);
}

pub const RunConfig = struct {
    /// If non-null, also write `latency.md` and `latency.json` under this
    /// directory (created if missing). Pass null for stdout-only.
    output_dir: ?[]const u8 = null,
};

/// Run the full latency suite: every query in `query_specs` across every
/// backend, printing a combined matrix and optionally persisting it to
/// Markdown + JSON. Callable outside a test so the Phase 7 report generator
/// can drive it directly (Task 3.6 / 3.7).
pub fn run(allocator: std.mem.Allocator, io: std.Io, config: RunConfig) !void {
    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(allocator);

    std.debug.print("\n=== Multi-Scale Benchmark Suite ===\n", .{});
    std.debug.print("Seed: {d} | Scale tiers: {d}\n\n", .{ fixtures.SEED, scale_tiers.len });

    for (scale_tiers) |ds| {
        const readings = try generateDatasetScaled(allocator, ds.num_sensors, ds.readings_per_sensor);
        defer allocator.free(readings);

        const total = ds.num_sensors * ds.readings_per_sensor;
        std.debug.print("--- Scale: {s} ({d} sensors × {d} readings = {d} total, {d} iterations) ---\n", .{
            ds.name, ds.num_sensors, ds.readings_per_sensor, total, ds.iterations,
        });
        std.debug.print("{s:<8} {s:<24} {s:<15} {s:>12} {s:>10} {s:>12} {s:>10} {s:>12} {s:>10} {s:>12} {s:>10} {s:>14}\n", .{
            "Scale", "Query", "Backend", "median_ns", "med_us", "p95_ns", "p95_us", "p99_ns", "p99_us", "mean_ns", "mean_us", "throughput",
        });
        std.debug.print("{s:->155}\n", .{""});

        inline for (query_specs) |spec| {
            if (spec.historical) {
                inline for (supported_backends) |b| {
                    try benchOne(spec, b, allocator, io, ds.iterations, readings, ds.name, &rows);
                }
            } else {
                inline for (backends) |b| {
                    try benchOne(spec, b, allocator, io, ds.iterations, readings, ds.name, &rows);
                }
            }
        }

        std.debug.print("{s:->155}\n", .{""});
    }

    std.debug.print("=== end suite ===\n", .{});

    if (config.output_dir) |dir_path| {
        try report.writeReports(allocator, io, dir_path, rows.items);
    }
}

test "latency table: data-driven run across all queries and backends" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try run(std.testing.allocator, threaded.io(), .{
        .output_dir = "benchmark-results",
    });
}
