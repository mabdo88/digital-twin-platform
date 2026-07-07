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

/// Time a state-mutating operation (e.g. insert, pruneOlderThan) exactly
/// once. Unlike `timeQuery`, there is no warmup — mutations are not
/// idempotent, so calling them twice would double the work. Returns the
/// elapsed time in nanoseconds.
///
/// This is the sanctioned timing path for all non-query work in the
/// simulation (chunk ingest, prune passes), keeping "metrics_system is the
/// only timing path" (CLAUDE.md §3.4) true for mutations as well as queries.
pub fn timeMutation(
    io: Io,
    comptime mutation_fn: anytype,
    args: anytype,
) !i64 {
    const start = Io.Clock.awake.now(io);
    try @call(.auto, mutation_fn, args);
    const end = Io.Clock.awake.now(io);
    const dur = start.durationTo(end);
    return @intCast(dur.nanoseconds);
}

fn nsToUs(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

// ---------------------------------------------------------------------------
// Smoke test — times query_avg_window on AoS and prints percentiles
// ---------------------------------------------------------------------------

const aos = @import("../storage/backends/aos_storage.zig");
const World = @import("../world.zig").World;
const queries = @import("../../benchmark/queries.zig");

// Shared dataset fixtures — single source of truth (engine/benchmark/dataset.zig).
// metrics_system already reaches into benchmark/ (queries above), so importing
// the dataset module is consistent with the existing layering.
const fixtures = @import("../../benchmark/dataset.zig");
const generateDataset = fixtures.generateDataset;
const NUM_SENSORS = fixtures.NUM_SENSORS;
const READINGS_PER_SENSOR = fixtures.READINGS_PER_SENSOR;

