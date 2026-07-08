// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Cloud-cost estimation model — turns measured in-process memory footprints
// and query throughput into an estimated annual $ cost per backend, so the
// recommendation report can say "expect $X/year" alongside the latency
// winner.
//
// Per CLAUDE.md §3.5: "No hard-coded building assumptions. Rules are data,
// not code." The pricing table is a data structure, not branching code.
//
// The model is deliberately simple and disclosed (CLAUDE.md §6 honesty):
//   annual_cost = storage_cost + query_cost
//   storage_cost = (memory_bytes / TB) * storage_price_per_tb_year
//   query_cost   = estimated_queries_per_year * price_per_million_queries
//
// This is NOT a real cloud billing calculator — it's a relative cost
// comparison tool. Absolute numbers are approximate (±2×, same as
// latencies); relative rankings are reliable. The pricing constants are
// sourced from public cloud pricing pages (AWS/Azure/GCP, mid-2026) and
// labeled with their source. They are data: change the table, not the code.

const std = @import("std");
const report = @import("report.zig");
const metrics = @import("../ecs/systems/metrics_system.zig");

// ---------------------------------------------------------------------------
// Pricing data — public cloud rates, mid-2026. Disclosed, not researched
// to the cent. These are the rates a small-to-medium deployment would pay
// for managed storage + serverless query execution. A real deployment would
// substitute its own vendor's actual pricing.
// ---------------------------------------------------------------------------

pub const PricingTier = struct {
    /// Annual cost per terabyte of storage (USD). Sourced from AWS EBS
    /// gp3 (~$0.08/GB-month = ~$960/TB-year) and Azure Managed Disk
    /// Premium SSD (~$0.135/GB-month = ~$1,620/TB-year). We use a
    /// midpoint representative rate.
    storage_price_per_tb_year: f64,

    /// Cost per million query operations (USD). Sourced from AWS Athena
    /// ($5/TB-scanned) and Azure Data Explorer (~$0.044/GB-scanned).
    /// Normalized to a per-million-query rate assuming average scan size.
    price_per_million_queries: f64,
};

/// Default pricing tier — representative public-cloud rates, mid-2026.
/// Not a specific vendor's exact bill — a disclosed, substitutable default.
pub const DEFAULT_PRICING = PricingTier{
    .storage_price_per_tb_year = 1200.0,
    .price_per_million_queries = 5.0,
};

// ---------------------------------------------------------------------------
// Workload assumptions — how many queries per year this building is
// expected to run. This is the one input the cost model needs that the
// benchmark doesn't measure directly (it measures per-query latency, not
// query frequency). The caller provides it; this module provides a
// reasonable default derived from a BMS operational pattern.
// ---------------------------------------------------------------------------

pub const WorkloadAssumptions = struct {
    /// Estimated total queries per year across all query patterns. A
    /// hospital-scale BMS typically runs:
    ///   - latest_* queries: ~1/sec = ~31.5M/year (3 patterns)
    ///   - aggregation queries: ~1/min = ~525K/year (5 patterns)
    ///   - historical rollups: ~1/hour = ~17.5K/year (2 patterns)
    ///   - anomaly/threshold: ~1/min = ~525K/year (2 patterns)
    /// Total: ~32.5M queries/year. Rounded to 30M as a conservative default.
    queries_per_year: u64 = 30_000_000,
};

pub const DEFAULT_WORKLOAD = WorkloadAssumptions{};

// ---------------------------------------------------------------------------
// Cost estimate for a single backend
// ---------------------------------------------------------------------------

pub const CostEstimate = struct {
    backend: []const u8,
    storage_bytes: usize,
    storage_tb: f64,
    storage_cost_year: f64,
    queries_per_year: u64,
    query_cost_year: f64,
    total_cost_year: f64,
};

/// Bytes per terabyte (binary, not decimal — matches how memory is measured).
const BYTES_PER_TB: f64 = 1024.0 * 1024.0 * 1024.0 * 1024.0;

/// Estimate annual cloud cost for a single backend given its measured
/// memory footprint and a workload assumption.
pub fn estimateCost(
    backend_name: []const u8,
    memory_bytes: usize,
    workload: WorkloadAssumptions,
    pricing: PricingTier,
) CostEstimate {
    const storage_tb = @as(f64, @floatFromInt(memory_bytes)) / BYTES_PER_TB;
    const storage_cost = storage_tb * pricing.storage_price_per_tb_year;
    const queries_millions = @as(f64, @floatFromInt(workload.queries_per_year)) / 1_000_000.0;
    const query_cost = queries_millions * pricing.price_per_million_queries;
    return .{
        .backend = backend_name,
        .storage_bytes = memory_bytes,
        .storage_tb = storage_tb,
        .storage_cost_year = storage_cost,
        .queries_per_year = workload.queries_per_year,
        .query_cost_year = query_cost,
        .total_cost_year = storage_cost + query_cost,
    };
}

/// True if a backend appears in any row (i.e. it was benchmarked).
fn backendInRows(rows: []const report.RunRow, backend_name: []const u8) bool {
    for (rows) |r| {
        if (std.mem.eql(u8, r.backend, backend_name)) return true;
    }
    return false;
}

/// Find the memory footprint for a given backend from RunRow results.
/// Each backend appears multiple times (once per query); we take the
/// maximum memory_bytes across all its rows, since memory is measured
/// after ingest and stays constant (the world isn't freed between queries
/// on the same backend).
fn maxMemoryForBackend(rows: []const report.RunRow, backend_name: []const u8) usize {
    var max_mem: usize = 0;
    for (rows) |r| {
        if (std.mem.eql(u8, r.backend, backend_name)) {
            if (r.memory_bytes > max_mem) max_mem = r.memory_bytes;
        }
    }
    return max_mem;
}

/// Estimate costs for all deployment backends in one call. Returns a slice
/// sorted by total_cost_year ascending (cheapest first). Caller frees.
pub fn estimateAll(
    allocator: std.mem.Allocator,
    rows: []const report.RunRow,
    backend_names: []const []const u8,
    workload: WorkloadAssumptions,
    pricing: PricingTier,
) ![]CostEstimate {
    var estimates: std.ArrayList(CostEstimate) = .empty;
    defer estimates.deinit(allocator);

    for (backend_names) |name| {
        if (!backendInRows(rows, name)) continue; // backend wasn't benchmarked
        const mem = maxMemoryForBackend(rows, name);
        try estimates.append(allocator, estimateCost(name, mem, workload, pricing));
    }

    // Sort by total_cost_year ascending (cheapest first)
    std.mem.sort(CostEstimate, estimates.items, {}, struct {
        fn lt(_: void, lhs: CostEstimate, rhs: CostEstimate) bool {
            return lhs.total_cost_year < rhs.total_cost_year;
        }
    }.lt);

    return estimates.toOwnedSlice(allocator);
}

/// The "naive" baseline: what would it cost to run EVERY backend
/// simultaneously (hot tier + warm tier + cold tier + cache)? This is the
/// naive-vs-optimised comparison — the optimised deployment picks the
/// compound recommendation's two winners; the naive approach just runs
/// everything.
pub fn naiveTotalCost(
    rows: []const report.RunRow,
    backend_names: []const []const u8,
    workload: WorkloadAssumptions,
    pricing: PricingTier,
) f64 {
    var total: f64 = 0.0;
    for (backend_names) |name| {
        if (!backendInRows(rows, name)) continue;
        const mem = maxMemoryForBackend(rows, name);
        const est = estimateCost(name, mem, workload, pricing);
        total += est.total_cost_year;
    }
    return total;
}

/// Optimised cost: just the two recommended winners (real-time + historical).
/// Query cost is split: real-time queries go to the real-time winner,
/// everything else to the historical winner. Storage cost is both winners'
/// memory.
pub fn optimisedCost(
    rows: []const report.RunRow,
    realtime_winner: []const u8,
    historical_winner: []const u8,
    realtime_query_fraction: f64,
    workload: WorkloadAssumptions,
    pricing: PricingTier,
) f64 {
    const rt_mem = maxMemoryForBackend(rows, realtime_winner);
    // Same backend deployed once serves both tracks — count its storage
    // once, not twice, when the real-time and historical winners coincide.
    const hist_mem: usize = if (std.mem.eql(u8, realtime_winner, historical_winner))
        0
    else
        maxMemoryForBackend(rows, historical_winner);

    const rt_storage_tb = @as(f64, @floatFromInt(rt_mem)) / BYTES_PER_TB;
    const hist_storage_tb = @as(f64, @floatFromInt(hist_mem)) / BYTES_PER_TB;
    const storage_cost = (rt_storage_tb + hist_storage_tb) * pricing.storage_price_per_tb_year;

    const total_queries_m = @as(f64, @floatFromInt(workload.queries_per_year)) / 1_000_000.0;
    const rt_query_cost = total_queries_m * realtime_query_fraction * pricing.price_per_million_queries;
    const hist_query_cost = total_queries_m * (1.0 - realtime_query_fraction) * pricing.price_per_million_queries;

    return storage_cost + rt_query_cost + hist_query_cost;
}

// ---------------------------------------------------------------------------
// Markdown rendering — emits a cost section for recommendation.md
// ---------------------------------------------------------------------------

pub fn writeCostSection(
    w: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rows: []const report.RunRow,
    backend_names: []const []const u8,
    realtime_winner: []const u8,
    historical_winner: []const u8,
    realtime_query_fraction: f64,
    workload: WorkloadAssumptions,
    pricing: PricingTier,
) !void {
    const estimates = try estimateAll(allocator, rows, backend_names, workload, pricing);
    defer allocator.free(estimates);

    try w.print(allocator, "## Cost estimate (cloud-equivalent)\n\n", .{});
    try w.print(allocator, "Pricing: **${d:.0}/TB-year** (storage) + **${d:.2}/M queries** (compute). " ++
        "Workload: **{d} queries/year**. Sources: public cloud pricing pages, mid-2026 — " ++
        "disclosed defaults, not vendor-specific bills. Absolute numbers are approximate (±2×); " ++
        "relative rankings are reliable (CLAUDE.md §6).\n\n", .{
        pricing.storage_price_per_tb_year,
        pricing.price_per_million_queries,
        workload.queries_per_year,
    });

    try w.print(allocator, "### Per-backend annual cost\n\n", .{});
    try w.print(allocator, "| Backend | Storage (GB) | Storage $/yr | Query $/yr | **Total $/yr** |\n", .{});
    try w.print(allocator, "|---|---:|---:|---:|---:|\n", .{});
    for (estimates) |e| {
        try w.print(allocator, "| {s} | {d:.1} | ${d:.0} | ${d:.0} | **${d:.0}** |\n", .{
            e.backend,
            e.storage_tb * 1024.0, // TB → GB
            e.storage_cost_year,
            e.query_cost_year,
            e.total_cost_year,
        });
    }

    const naive = naiveTotalCost(rows, backend_names, workload, pricing);
    const optimised = optimisedCost(rows, realtime_winner, historical_winner, realtime_query_fraction, workload, pricing);
    const savings = naive - optimised;
    const savings_pct = if (naive > 0) (savings / naive) * 100.0 else 0.0;

    try w.print(allocator, "\n### Naive vs optimised\n\n", .{});
    try w.print(allocator, "| Strategy | Annual cost |\n|---|---:|\n", .{});
    try w.print(allocator, "| Naive (all {d} backends simultaneously) | ${d:.0}/yr |\n", .{
        backend_names.len, naive,
    });
    try w.print(allocator, "| **Optimised** ({s} + {s}) | **${d:.0}/yr** |\n", .{
        realtime_winner, historical_winner, optimised,
    });
    try w.print(allocator, "\n**Savings: ${d:.0}/yr ({d:.0}%)** by running only the recommended backends instead of all of them.\n\n", .{
        savings, savings_pct,
    });
}

test "optimisedCost: does not double-count storage when the same backend wins both tracks" {
    const zero_stats: metrics.LatencyStats = .{
        .iterations = 1,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = 0,
    };
    const one_tib: usize = 1024 * 1024 * 1024 * 1024;
    const rows = [_]report.RunRow{
        .{ .scale = "S", .query = "Q", .backend = "TimeSeries", .memory_bytes = one_tib, .stats = zero_stats },
    };

    const workload = WorkloadAssumptions{ .queries_per_year = 1_000_000 };
    const cost = optimisedCost(&rows, "TimeSeries", "TimeSeries", 0.5, workload, DEFAULT_PRICING);

    // 1 TiB storage counted ONCE ($1200) + 0.5M queries to each track ($2.50
    // each) = $1205, not $2405 (which double-billed the 1 TiB storage).
    try std.testing.expectApproxEqAbs(@as(f64, 1205.0), cost, 0.001);
}

test "optimisedCost: sums storage for two distinct winners" {
    const zero_stats: metrics.LatencyStats = .{
        .iterations = 1,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = 0,
    };
    const one_tib: usize = 1024 * 1024 * 1024 * 1024;
    const rows = [_]report.RunRow{
        .{ .scale = "S", .query = "Q", .backend = "RingBuffer", .memory_bytes = one_tib, .stats = zero_stats },
        .{ .scale = "S", .query = "Q", .backend = "Lake", .memory_bytes = one_tib, .stats = zero_stats },
    };

    const workload = WorkloadAssumptions{ .queries_per_year = 1_000_000 };
    const cost = optimisedCost(&rows, "RingBuffer", "Lake", 0.5, workload, DEFAULT_PRICING);

    // Two distinct backends, 1 TiB each, genuinely both deployed: $2400
    // storage + $5 query = $2405.
    try std.testing.expectApproxEqAbs(@as(f64, 2405.0), cost, 0.001);
}

// ---------------------------------------------------------------------------
