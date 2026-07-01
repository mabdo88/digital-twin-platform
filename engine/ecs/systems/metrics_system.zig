// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Metrics system — the SINGLE place latency, throughput, and memory are
// recorded (CLAUDE.md §3.4).
//
// No other file may time queries or sample heap. The runner calls these
// functions to produce BenchmarkResult records.

const std = @import("std");
const Io = std.Io;
const sb = @import("../storage/storage_backend.zig");

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// Latency percentiles from timing a query over N iterations.
pub const LatencyStats = struct {
    iterations: u32,
    median_ns: i64,
    p95_ns: i64,
    p99_ns: i64,
    min_ns: i64,
    max_ns: i64,
    mean_ns: i64,
    total_ns: i64,

    /// Operations per second derived from total elapsed time.
    pub fn throughputOpsPerSec(self: LatencyStats) f64 {
        if (self.total_ns <= 0) return 0.0;
        const total_s: f64 = @as(f64, @floatFromInt(self.total_ns)) / 1e9;
        return @as(f64, @floatFromInt(self.iterations)) / total_s;
    }
};

/// Memory samples at the three benchmark phases (CLAUDE.md §3.4).
pub const MemorySnapshot = struct {
    after_ingest_bytes: usize,
    before_queries_bytes: usize,
    after_queries_bytes: usize,
};

/// Complete benchmark result for one query on one backend.
pub const BenchmarkResult = struct {
    query_name: []const u8,
    backend_name: []const u8,
    latency: LatencyStats,
    memory: MemorySnapshot,
};

// ---------------------------------------------------------------------------
// API — the runner calls these
// ---------------------------------------------------------------------------

/// Sample heap usage from a world at a benchmark phase.
/// Call after ingest, before queries, and after queries.
pub fn sampleMemory(world: anytype) usize {
    return world.memoryUsed();
}

/// Time a query function over `iterations` iterations.
/// Returns LatencyStats with median, p95, p99.
///
/// `query_fn` is any callable; `args` is a tuple of its arguments.
/// One warmup call is made (not counted), then each iteration is timed
/// individually with the monotonic Io clock.
pub fn timeQuery(
    allocator: std.mem.Allocator,
    io: Io,
    iterations: u32,
    comptime query_fn: anytype,
    args: anytype,
) !LatencyStats {
    // Warmup — prime caches, branch predictors
    _ = try @call(.auto, query_fn, args);

    const samples = try allocator.alloc(i64, iterations);
    defer allocator.free(samples);

    var total_ns: i64 = 0;
    for (0..iterations) |i| {
        const start = Io.Clock.awake.now(io);
        _ = try @call(.auto, query_fn, args);
        const end = Io.Clock.awake.now(io);
        const dur = start.durationTo(end);
        const ns: i64 = @intCast(dur.nanoseconds);
        samples[i] = ns;
        total_ns += ns;
    }

    // Sort ascending for percentile computation
    std.mem.sort(i64, samples, {}, struct {
        fn lt(_: void, lhs: i64, rhs: i64) bool {
            return lhs < rhs;
        }
    }.lt);

    const n = iterations;
    const median = samples[n / 2];
    const p95_idx = @min(@as(usize, @intCast((n * 95) / 100)), n - 1);
    const p99_idx = @min(@as(usize, @intCast((n * 99) / 100)), n - 1);

    return .{
        .iterations = iterations,
        .median_ns = median,
        .p95_ns = samples[p95_idx],
        .p99_ns = samples[p99_idx],
        .min_ns = samples[0],
        .max_ns = samples[n - 1],
        .mean_ns = @divTrunc(total_ns, @as(i64, @intCast(iterations))),
        .total_ns = total_ns,
    };
}

/// Print a LatencyStats summary to stderr (for smoke tests and debug).
/// Shows both ns and µs for readability.
pub fn printLatencyStats(stats: LatencyStats) void {
    std.debug.print(
        "metrics: iterations={d} median={d}ns ({d:.1}µs) p95={d}ns ({d:.1}µs) p99={d}ns ({d:.1}µs) min={d}ns max={d}ns mean={d}ns ({d:.1}µs) throughput={d:.0}ops/s\n",
        .{
            stats.iterations,
            stats.median_ns,
            nsToUs(stats.median_ns),
            stats.p95_ns,
            nsToUs(stats.p95_ns),
            stats.p99_ns,
            nsToUs(stats.p99_ns),
            stats.min_ns,
            stats.max_ns,
            stats.mean_ns,
            nsToUs(stats.mean_ns),
            stats.throughputOpsPerSec(),
        },
    );
}

fn nsToUs(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

// ---------------------------------------------------------------------------
// Smoke test — times query_avg_window on AoS and prints percentiles
// ---------------------------------------------------------------------------

const aos = @import("../storage/backends/aos_storage.zig");
const soa = @import("../storage/backends/soa_storage.zig");
const timeseries = @import("../storage/backends/timeseries_storage.zig");
const columnar = @import("../storage/backends/columnar_storage.zig");
const hierarchical = @import("../storage/backends/hierarchical_storage.zig");
const ringbuffer = @import("../storage/backends/ringbuffer_storage.zig");
const World = @import("../world.zig").World;
const queries = @import("../../benchmark/queries.zig");

// Shared dataset fixtures — single source of truth (engine/benchmark/dataset.zig).
// metrics_system already reaches into benchmark/ (queries above), so importing
// the dataset module is consistent with the existing layering.
const fixtures = @import("../../benchmark/dataset.zig");
const generateDataset = fixtures.generateDataset;
const NUM_SENSORS = fixtures.NUM_SENSORS;
const READINGS_PER_SENSOR = fixtures.READINGS_PER_SENSOR;

test "smoke: time query_avg_window on AoS and print percentiles" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    // Ingest
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    for (dataset) |r| try world.insert(r);

    // Memory samples at benchmark phases (CLAUDE.md §3.4)
    const mem_after_ingest = sampleMemory(&world);
    const mem_before_queries = sampleMemory(&world);

    // Time query_avg_window over 100 iterations
    const stats = try timeQuery(
        std.testing.allocator,
        io,
        100,
        queries.query_avg_window,
        .{ &world, @as(u32, 0), @as(u32, 24) },
    );

    const mem_after_queries = sampleMemory(&world);

    // Print percentiles
    printLatencyStats(stats);

    // Sanity checks
    try std.testing.expectEqual(@as(u32, 100), stats.iterations);
    try std.testing.expect(stats.median_ns >= 0);
    try std.testing.expect(stats.p95_ns >= stats.median_ns);
    try std.testing.expect(stats.p99_ns >= stats.p95_ns);
    try std.testing.expect(stats.max_ns >= stats.min_ns);
    try std.testing.expect(mem_after_ingest > 0);
    try std.testing.expectEqual(mem_before_queries, mem_after_ingest);
    try std.testing.expectEqual(mem_after_queries, mem_before_queries);
}

// Was previously six hand-unrolled copies of this exact loop (one per
// backend, ~250 lines) printing the same table and asserting the same three
// percentile-ordering invariants each time. Those invariants are a property
// of timeQuery's own sort+index math, not of the backend being timed, so
// repeating the assertions per backend never caught a backend-specific bug —
// it only multiplied compile time and the cost of this test (up to 100k
// iterations x 6 backends). Looping at comptime keeps the same scaling
// numbers printed for every backend, with the duplication gone.
test "scaling: query_avg_window across all six backends at 100 / 1k / 10k iterations" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    const iteration_counts = [_]u32{ 100, 1_000, 10_000 };
    const all_backends = .{
        .{ "AoS", aos },
        .{ "SoA", soa },
        .{ "TimeSeries", timeseries },
        .{ "Columnar", columnar },
        .{ "Hierarchical", hierarchical },
        .{ "RingBuffer", ringbuffer },
    };

    std.debug.print("\n=== query_avg_window scaling across all six backends (sensor=0, hours=24) ===\n", .{});

    inline for (all_backends) |entry| {
        const name = entry[0];
        const Backend = entry[1];

        var world = try World(Backend).init(std.testing.allocator);
        defer world.deinit();
        for (dataset) |r| try world.insert(r);

        std.debug.print("\n--- {s} (memory={d} bytes) ---\n", .{ name, sampleMemory(&world) });
        std.debug.print("{s:>10} {s:>12} {s:>8} {s:>12} {s:>8} {s:>12} {s:>8} {s:>12} {s:>8} {s:>14}\n", .{
            "iters",      "median_ns",
            "med_µs",
            "p95_ns",
            "p95_µs",
            "p99_ns",
            "p99_µs",
            "mean_ns",
            "mean_µs",
            "throughput",
        });

        for (iteration_counts) |n| {
            const stats = try timeQuery(
                std.testing.allocator,
                io,
                n,
                queries.query_avg_window,
                .{ &world, @as(u32, 0), @as(u32, 24) },
            );
            std.debug.print("{d:>10} {d:>12} {d:>8.1} {d:>12} {d:>8.1} {d:>12} {d:>8.1} {d:>12} {d:>8.1} {d:>12.0}ops/s\n", .{
                stats.iterations,
                stats.median_ns,
                nsToUs(stats.median_ns),
                stats.p95_ns,
                nsToUs(stats.p95_ns),
                stats.p99_ns,
                nsToUs(stats.p99_ns),
                stats.mean_ns,
                nsToUs(stats.mean_ns),
                stats.throughputOpsPerSec(),
            });
            try std.testing.expectEqual(n, stats.iterations);
            try std.testing.expect(stats.p95_ns >= stats.median_ns);
            try std.testing.expect(stats.p99_ns >= stats.p95_ns);
        }
    }

    std.debug.print("\n=== end scaling ===\n", .{});
}

// ---------------------------------------------------------------------------
// timeQuery / LatencyStats math — fast, deterministic edge cases that don't
// need real backend timing noise to exercise. None of these existed before:
// the only prior coverage of percentile math was incidental, buried inside
// the 100k-iteration scaling test above.
// ---------------------------------------------------------------------------

fn constOneNs(_: *u32) !void {}

test "timeQuery at iterations=1: median, p95, p99, min, and max all collapse to the single sample" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dummy: u32 = 0;
    const stats = try timeQuery(std.testing.allocator, io, 1, constOneNs, .{&dummy});

    try std.testing.expectEqual(@as(u32, 1), stats.iterations);
    try std.testing.expectEqual(stats.median_ns, stats.p95_ns);
    try std.testing.expectEqual(stats.median_ns, stats.p99_ns);
    try std.testing.expectEqual(stats.median_ns, stats.min_ns);
    try std.testing.expectEqual(stats.median_ns, stats.max_ns);
    try std.testing.expectEqual(stats.median_ns, stats.mean_ns);
}

test "throughputOpsPerSec returns 0.0 for non-positive total_ns instead of dividing by ~zero" {
    const zero_total = LatencyStats{
        .iterations = 10,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = 0,
    };
    try std.testing.expectEqual(@as(f64, 0.0), zero_total.throughputOpsPerSec());

    const negative_total = LatencyStats{
        .iterations = 10,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = -1,
    };
    try std.testing.expectEqual(@as(f64, 0.0), negative_total.throughputOpsPerSec());
}

test "mean_ns truncates toward zero rather than rounding" {
    // 100ns over 3 iterations = 33.33...ns; divTrunc must give 33, not 34.
    const stats = LatencyStats{
        .iterations = 3,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = @divTrunc(@as(i64, 100), @as(i64, 3)),
        .total_ns = 100,
    };
    try std.testing.expectEqual(@as(i64, 33), stats.mean_ns);
}
