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

// ---------------------------------------------------------------------------
// run() — the zig build bench entry point. Generates each scale tier's
// dataset, benchmarks every deployment backend against every query pattern,
// and writes latency.md/latency.json/benchmark.html.
// ---------------------------------------------------------------------------

pub const Options = struct { output_dir: []const u8 };

/// Fixed query args for the internal regression fixture. Sensor 0 always
/// lands in zone 0 / floor 0 / position (0,0,0) under dataset.zig's
/// topology convention (insertDataset), regardless of scale tier, so these
/// stay valid across every DatasetSpec in scale_tiers.
const FIXTURE_SENSOR_ID: u32 = 0;
const FIXTURE_ZONE_ID: u32 = 0;
const FIXTURE_FLOOR_ID: u32 = 0;
const FIXTURE_SENSOR_TYPE: sb.SensorType = .temperature;
const FIXTURE_POSITION = queries.Vec3{ .x = 0, .y = 0, .z = 0 };
const FIXTURE_THRESHOLD_VALUE: f32 = 15.0;
const ONE_HOUR_MS: i64 = 60 * 60 * 1000;

/// timeQuery callable for one query pattern against one backend's World —
/// same dispatch shape as simulation.zig's runOne, but against the fixed
/// regression-fixture args above instead of a live sensor's real state.
fn QueryCaller(comptime W: type) type {
    return struct {
        world: *W,
        query: queries.QueryName,

        fn call(self: *@This()) !void {
            switch (self.query) {
                .avg_window => _ = try queries.query_avg_window(self.world, FIXTURE_SENSOR_ID, @as(u32, 24)),
                .latest_single => try q1_wrapper(self.world, FIXTURE_SENSOR_ID),
                .latest_zone => try q2_wrapper(self.world, FIXTURE_ZONE_ID),
                .latest_by_type => try q3_wrapper(self.world, FIXTURE_SENSOR_TYPE),
                .avg_zone_type => try q5_wrapper(self.world, FIXTURE_ZONE_ID, FIXTURE_SENSOR_TYPE, @as(u32, 24)),
                .floor_stats => try q6_wrapper(self.world, FIXTURE_FLOOR_ID, FIXTURE_SENSOR_TYPE, @as(u32, 24)),
                .hourly_rollup => try q7_wrapper(self.world, FIXTURE_SENSOR_ID, @as(u32, 2)),
                .daily_zone_rollup => try q8_wrapper(self.world, FIXTURE_ZONE_ID, FIXTURE_SENSOR_TYPE),
                .spatial_radius => try q9_wrapper(self.world, FIXTURE_POSITION, @as(f32, 50.0)),
                .zone_hierarchy => try q10_wrapper(self.world, FIXTURE_ZONE_ID, @as(u32, 2)),
                .anomalies => try q11_wrapper(self.world, FIXTURE_SENSOR_TYPE, queries.ANOMALY_STD_DEV_THRESHOLD, queries.ANOMALY_WINDOW_HOURS),
                .threshold_breach => try q12_wrapper(self.world, FIXTURE_SENSOR_ID, FIXTURE_THRESHOLD_VALUE, ONE_HOUR_MS, queries.THRESHOLD_BREACH_WINDOW_HOURS),
            }
        }
    };
}

/// Runs every query pattern against every deployment backend for one
/// dataset spec, returning one RunRow per (query, backend) pair. Caller
/// frees the returned slice with `allocator`.
pub fn collectRows(allocator: std.mem.Allocator, io: std.Io, spec: DatasetSpec) ![]report.RunRow {
    const readings = try generateDatasetScaled(allocator, spec.num_sensors, spec.readings_per_sensor);
    defer allocator.free(readings);

    var rows: std.ArrayList(report.RunRow) = .empty;
    errdefer rows.deinit(allocator);

    inline for (backends) |entry| {
        const W = World(entry.T);
        var world = try W.init(allocator);
        defer world.deinit();
        try insertDataset(&world, readings);

        const memory_bytes = world.memoryUsed();

        for (std.enums.values(queries.QueryName)) |q| {
            var caller = QueryCaller(W){ .world = &world, .query = q };
            const stats = try metrics.timeQuery(allocator, io, spec.iterations, QueryCaller(W).call, .{&caller});
            try rows.append(allocator, .{
                .scale = spec.name,
                .query = report.queryNameStr(q),
                .backend = entry.name,
                .memory_bytes = memory_bytes,
                .stats = stats,
            });
        }
    }

    return rows.toOwnedSlice(allocator);
}

/// The `zig build bench` entry point (called from bench_main.zig): runs
/// the full multi-scale regression suite — every scale tier × every
/// deployment backend × every query pattern — and writes latency.md,
/// latency.json, and benchmark.html under `options.output_dir`.
pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var all_rows: std.ArrayList(report.RunRow) = .empty;
    defer all_rows.deinit(allocator);

    for (scale_tiers) |spec| {
        const rows = try collectRows(allocator, io, spec);
        defer allocator.free(rows);
        try all_rows.appendSlice(allocator, rows);
    }

    try report.writeReports(allocator, io, options.output_dir, all_rows.items);
}

// Cross-backend equivalence for all 12 query patterns is proven in
// queries.zig ("all 12 query patterns" test — the canonical home for the
// query implementations, see its header comment). Rechecked 2026-07-20:
// this comment previously claimed equivalence was ALSO checked here for
// getLatestBySensor/rangeByTime — that test never existed; the claim was
// stale/aspirational, not a description of live code (same lesson as
// backend-audit.md's stale claims elsewhere in this project). The only test
// in this file is the smoke test below (report output shape), not an
// equivalence check.

test "run: writes latency.md, latency.json, and benchmark.html covering every scale tier and backend" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    const out_dir = "zig-cache-test-runner-run";
    defer cwd.deleteTree(io, out_dir) catch {};

    try run(allocator, io, .{ .output_dir = out_dir });

    var dir = try cwd.openDir(io, out_dir, .{});
    defer dir.close(io);

    const md = try dir.readFileAlloc(io, "latency.md", allocator, .limited(1024 * 1024));
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Seed: `42`") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "query_latest_single") != null);
    for (scale_tiers) |ds| {
        try std.testing.expect(std.mem.indexOf(u8, md, ds.name) != null);
    }

    // The "- Backends:" summary line must list every backend actually
    // benchmarked (all 5 in `backends`), not a stale hardcoded subset —
    // regression check for the bug where this line and the HTML dashboard's
    // header/chip/color-legend silently omitted "Lake" after it was added
    // to the registry.
    const backends_line_start = std.mem.indexOf(u8, md, "- Backends:").?;
    const backends_line_end = std.mem.indexOfPos(u8, md, backends_line_start, "\n").?;
    const backends_line = md[backends_line_start..backends_line_end];
    inline for (backends) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, backends_line, entry.name) != null);
    }

    const js = try dir.readFileAlloc(io, "latency.json", allocator, .limited(1024 * 1024));
    defer allocator.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"results\"") != null);

    const html = try dir.readFileAlloc(io, "benchmark.html", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(html);
    const chip_start = std.mem.indexOf(u8, html, "<strong>Backends</strong>").?;
    const chip_end = std.mem.indexOfPos(u8, html, chip_start, "</span>").?;
    const chip = html[chip_start..chip_end];
    inline for (backends) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, chip, entry.name) != null);
    }
}
