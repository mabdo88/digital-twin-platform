// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Report writers — Markdown (human-readable), JSON (machine-readable), and
// HTML (interactive dashboard). All three render the same RunRow data
// produced by runner.zig; adding a query or backend there requires no
// changes here.

const std = @import("std");
const metrics = @import("../ecs/systems/metrics_system.zig");
const fixtures = @import("dataset.zig");
const queries = @import("queries.zig");

/// One latency-table row, decoupled from how it's rendered.
pub const RunRow = struct {
    scale: []const u8,
    query: []const u8,
    backend: []const u8,
    memory_bytes: usize,
    stats: metrics.LatencyStats,
};

/// Maps a queries.QueryName to the exact query-name string runner.zig's
/// query_specs use.
fn queryNameStr(qn: queries.QueryName) []const u8 {
    return switch (qn) {
        .avg_window => "query_avg_window",
        .avg_zone_type => "query_avg_zone_type",
        .floor_stats => "query_floor_stats",
        .hourly_rollup => "query_hourly_rollup",
        .daily_zone_rollup => "query_daily_zone_rollup",
        .spatial_radius => "query_spatial_radius",
        .zone_hierarchy => "query_zone_hierarchy",
        .anomalies => "query_anomalies",
        .threshold_breach => "query_threshold_breach",
        .latest_single => "query_latest_single",
        .latest_zone => "query_latest_zone",
        .latest_by_type => "query_latest_by_type",
    };
}

/// One backend's standing in a profile-weighted recommendation.
pub const BackendScore = struct {
    backend: []const u8,
    /// Weighted average of (this backend's median / the per-query winner's
    /// median) across every query in the profile's mix that this backend
    /// has data for. 1.0 = won every weighted query; higher is worse.
    score: f64,
    /// Fraction of the profile's total query weight this backend actually
    /// has data for (1.0 = has data for every weighted query). A backend
    /// with a low score but partial coverage is winning by omission, not
    /// speed — see CLAUDE.md's "honest headline" (§6).
    coverage: f64,
};

/// One track of a compound recommendation — scoped to one query family
/// group (real-time vs. everything else) and possibly to a restricted set of
/// eligible backends. Caller frees `scores`.
pub const TrackRecommendation = struct {
    scores: []BackendScore, // sorted ascending by score (best first)
    winner: []const u8,
};

/// A building (or per-type) recommendation split into two independently-won
/// tracks, because no single backend should be forced to serve both a tiny
/// live cache's workload and a full-history store's workload:
/// - `realtime`: the `real_time` query family (latest_*), scored across ALL
///   backends — the tiny real-time cache legitimately competes here.
/// - `historical`: every other family (aggregation/historical/spatial/
///   anomaly), scored across ONLY the full-retention backends. A count-
///   capped cache is excluded outright rather than being allowed to "win"
///   by timing a query against the handful of readings it kept.
/// The real deployment answer is the pair: "<realtime.winner> for live
/// queries + <historical.winner> for everything else." Caller frees both
/// `.scores` slices.
pub const CompoundRecommendation = struct {
    realtime: TrackRecommendation,
    historical: TrackRecommendation,
};

/// How much each unit of *uncovered* query weight counts against a backend
/// in `scoreBackends`'s score (1.0 = as good as tying the per-query
/// winner; higher is worse). Set above the this/winner ratios functioning
/// backends realistically reach (~1-3x) so a coverage gap reliably outweighs
/// mere slowness: a backend that can't answer a weighted query at all (it
/// evicted that type's data, or doesn't support that rollup) should rank
/// below one that answers it slowly. Not researched — a deliberate,
/// disclosed policy choice (CLAUDE.md §6 honesty).
const UNCOVERED_QUERY_PENALTY: f64 = 4.0;

/// True if `name` appears in `eligible`. Used to restrict a track to a
/// subset of backends (e.g. the historical track excludes the count-capped
/// real-time cache).
fn backendEligible(eligible: ?[]const []const u8, name: []const u8) bool {
    const list = eligible orelse return true; // null = every backend is eligible
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Core scorer behind both `recommendBackend` and `recommendCompound`. Ranks
/// every backend present in `rows` at `scale` over the weighted `query_mix`,
/// returning scores sorted ascending (best first; caller frees the slice).
/// When `eligible` is non-null, backends outside that set are excluded
/// entirely — not just from the ranking, but also from each query's
/// per-query winner, so an ineligible-but-artificially-fast backend can't
/// distort the eligible backends' ratios. `eligible == null` considers all.
fn scoreBackends(
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    query_mix: []const queries.QueryWeight,
    eligible: ?[]const []const u8,
) ![]BackendScore {
    if (query_mix.len == 0) return &[_]BackendScore{};

    var backend_names: std.ArrayList([]const u8) = .empty;
    defer backend_names.deinit(allocator);
    for (rows) |r| {
        if (!std.mem.eql(u8, r.scale, scale)) continue;
        if (!backendEligible(eligible, r.backend)) continue;
        var seen = false;
        for (backend_names.items) |b| {
            if (std.mem.eql(u8, b, r.backend)) {
                seen = true;
                break;
            }
        }
        if (!seen) try backend_names.append(allocator, r.backend);
    }

    var scores: std.ArrayList(BackendScore) = .empty;
    defer scores.deinit(allocator);

    for (backend_names.items) |backend| {
        var weighted_sum: f64 = 0;
        var covered_weight: f64 = 0;
        var total_weight: f64 = 0;

        for (query_mix) |qw| {
            total_weight += qw.weight;
            const qname = queryNameStr(qw.query);

            var winner_median: ?i64 = null;
            var this_median: ?i64 = null;
            for (rows) |r| {
                if (!std.mem.eql(u8, r.scale, scale)) continue;
                if (!std.mem.eql(u8, r.query, qname)) continue;
                if (!backendEligible(eligible, r.backend)) continue;
                if (winner_median == null or r.stats.median_ns < winner_median.?) {
                    winner_median = r.stats.median_ns;
                }
                if (std.mem.eql(u8, r.backend, backend)) {
                    this_median = r.stats.median_ns;
                }
            }

            if (this_median) |tm| {
                covered_weight += qw.weight;
                const wm = winner_median.?; // this_median set implies >=1 row, so winner_median is too
                const ratio: f64 = if (wm <= 0) 1.0 else @as(f64, @floatFromInt(tm)) / @as(f64, @floatFromInt(wm));
                weighted_sum += qw.weight * ratio;
            }
        }

        const coverage: f64 = if (total_weight > 0) covered_weight / total_weight else 0;
        // Penalize coverage gaps instead of silently scoring a backend only
        // over the queries it happens to cover. The denominator is the FULL
        // weighted mix, and each uncovered unit of weight is charged
        // UNCOVERED_QUERY_PENALTY rather than dropped from the average — so a
        // backend missing data for a weighted query can't win by omission. A
        // backend with zero coverage stays +inf (worst possible), so it never
        // edges out one that actually returns data.
        const uncovered_weight = total_weight - covered_weight;
        const score: f64 = if (covered_weight <= 0)
            std.math.inf(f64)
        else
            (weighted_sum + UNCOVERED_QUERY_PENALTY * uncovered_weight) / total_weight;

        try scores.append(allocator, .{ .backend = backend, .score = score, .coverage = coverage });
    }

    const owned = try scores.toOwnedSlice(allocator);
    std.mem.sort(BackendScore, owned, {}, struct {
        fn lt(_: void, a: BackendScore, b: BackendScore) bool {
            return a.score < b.score;
        }
    }.lt);
    return owned;
}

/// Split `query_mix` by query family and rank each track independently (see
/// `CompoundRecommendation`): the `real_time` family across all backends,
/// everything else across only `full_retention_backends`. `full_retention_
/// backends` is the set of backend names eligible for the historical track
/// (i.e. every deployment backend except the count-capped real-time cache);
/// pass it straight from `runner.supported_backends`' names. Caller frees
/// both returned `.scores` slices.
pub fn recommendCompound(
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    query_mix: []const queries.QueryWeight,
    full_retention_backends: []const []const u8,
) !CompoundRecommendation {
    var realtime_mix: std.ArrayList(queries.QueryWeight) = .empty;
    defer realtime_mix.deinit(allocator);
    var historical_mix: std.ArrayList(queries.QueryWeight) = .empty;
    defer historical_mix.deinit(allocator);

    for (query_mix) |qw| {
        if (queries.familyOf(qw.query) == .real_time) {
            try realtime_mix.append(allocator, qw);
        } else {
            try historical_mix.append(allocator, qw);
        }
    }

    const rt_scores = try scoreBackends(allocator, rows, scale, realtime_mix.items, null);
    errdefer allocator.free(rt_scores);
    const hist_scores = try scoreBackends(allocator, rows, scale, historical_mix.items, full_retention_backends);

    return .{
        .realtime = .{
            .scores = rt_scores,
            .winner = if (rt_scores.len > 0) rt_scores[0].backend else "none",
        },
        .historical = .{
            .scores = hist_scores,
            .winner = if (hist_scores.len > 0) hist_scores[0].backend else "none",
        },
    };
}

/// Write `latency.md`, `latency.json`, and `benchmark.html` under
/// `dir_path` (created if missing).
pub fn writeReports(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    rows: []const RunRow,
) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    // ---- Markdown ----
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(allocator);

    try md.print(allocator, "# Digital Twin — Multi-Scale Benchmark Results\n\n", .{});
    try md.print(allocator, "- Seed: `{d}`\n", .{fixtures.SEED});
    try md.print(allocator, "- Scale tiers: {d}\n", .{fixtures.scale_tiers.len});
    for (fixtures.scale_tiers) |ds| {
        const total = ds.num_sensors * ds.readings_per_sensor;
        try md.print(allocator, "  - **{s}**: {d} sensors × {d} readings = {d} total, {d} iterations\n", .{
            ds.name, ds.num_sensors, ds.readings_per_sensor, total, ds.iterations,
        });
    }
    try md.print(allocator, "- Backends: TimeSeries, Columnar, Hierarchical, RingBuffer\n", .{});
    try md.print(allocator, "- Historical rollups (Q7, Q8) exclude RingBuffer (evicts old data).\n\n", .{});

    try md.print(allocator, "> Honesty headline: **relative rankings are reliable; absolute numbers are approximate.**\n\n", .{});

    // Per-scale sections
    for (fixtures.scale_tiers) |ds| {
        try md.print(allocator, "## Scale: {s} ({d} sensors × {d} readings = {d} total)\n\n", .{
            ds.name, ds.num_sensors, ds.readings_per_sensor, ds.num_sensors * ds.readings_per_sensor,
        });
        try md.print(allocator, "| Query | Backend | median µs | p95 µs | p99 µs | mean µs | throughput (ops/s) | memory (KB) |\n", .{});
        try md.print(allocator, "|---|---|---:|---:|---:|---:|---:|---:|\n", .{});

        for (rows) |r| {
            if (!std.mem.eql(u8, r.scale, ds.name)) continue;
            try md.print(allocator, "| {s} | {s} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.0} | {d:.1} |\n", .{
                r.query,
                r.backend,
                @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0,
                @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0,
                @as(f64, @floatFromInt(r.stats.p99_ns)) / 1000.0,
                @as(f64, @floatFromInt(r.stats.mean_ns)) / 1000.0,
                r.stats.throughputOpsPerSec(),
                @as(f64, @floatFromInt(r.memory_bytes)) / 1024.0,
            });
        }

        try md.print(allocator, "\n### Per-query winner (lowest median)\n\n", .{});
        try md.print(allocator, "| Query | Winner | Median µs | Runner-up | Median µs | Speedup |\n", .{});
        try md.print(allocator, "|---|---|---:|---|---:|---:|\n", .{});
        try writeWinners(&md, allocator, rows, ds.name);

        try md.print(allocator, "\n", .{});
    }

    // No per-building-type recommendation section here — this internal
    // suite runs against dataset.zig's shared synthetic fixture, not a
    // real parsed building, so there's no real set of placed sensor types
    // to derive a query mix from. Real recommendations (main.zig) build
    // query_mix from whatever a real IFC actually contains; recommending
    // backends for five hypothetical, hand-picked "building types" against
    // the same generic dataset was exactly the guessing this whole
    // redesign removed.

    try dir.writeFile(io, .{ .sub_path = "latency.md", .data = md.items });

    // ---- JSON ----
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(allocator);

    try js.print(allocator, "{{\n", .{});
    try js.print(allocator, "  \"seed\": {d},\n", .{fixtures.SEED});
    try js.print(allocator, "  \"scale_tiers\": [\n", .{});
    for (fixtures.scale_tiers, 0..) |ds, i| {
        try js.print(allocator, "    {{\"name\": \"{s}\", \"sensors\": {d}, \"readings_per_sensor\": {d}, \"iterations\": {d}}}{s}\n", .{
            ds.name,                                            ds.num_sensors, ds.readings_per_sensor, ds.iterations,
            if (i + 1 == fixtures.scale_tiers.len) "" else ",",
        });
    }
    try js.print(allocator, "  ],\n", .{});
    try js.print(allocator, "  \"results\": [\n", .{});
    for (rows, 0..) |r, i| {
        try js.print(
            allocator,
            "    {{\"scale\": \"{s}\", \"query\": \"{s}\", \"backend\": \"{s}\", \"memory_bytes\": {d}, \"median_ns\": {d}, \"p95_ns\": {d}, \"p99_ns\": {d}, \"mean_ns\": {d}, \"min_ns\": {d}, \"max_ns\": {d}, \"throughput_ops_per_sec\": {d:.2}}}{s}\n",
            .{
                r.scale,                       r.query,
                r.backend,                     r.memory_bytes,
                r.stats.median_ns,             r.stats.p95_ns,
                r.stats.p99_ns,                r.stats.mean_ns,
                r.stats.min_ns,                r.stats.max_ns,
                r.stats.throughputOpsPerSec(), if (i + 1 == rows.len) "" else ",",
            },
        );
    }
    try js.print(allocator, "  ]\n}}\n", .{});

    try dir.writeFile(io, .{ .sub_path = "latency.json", .data = js.items });

    // ---- HTML ----
    try writeHtmlReport(allocator, io, &dir, rows);

    std.debug.print("\nWrote {s}/latency.md, {s}/latency.json, and {s}/benchmark.html\n", .{ dir_path, dir_path, dir_path });
}

fn writeHtmlReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    rows: []const RunRow,
) !void {
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);

    // Collect unique queries and scales
    var unique_queries: std.ArrayList([]const u8) = .empty;
    defer unique_queries.deinit(allocator);
    var unique_scales: std.ArrayList([]const u8) = .empty;
    defer unique_scales.deinit(allocator);

    for (rows) |r| {
        var found = false;
        for (unique_queries.items) |q| {
            if (std.mem.eql(u8, q, r.query)) {
                found = true;
                break;
            }
        }
        if (!found) try unique_queries.append(allocator, r.query);

        found = false;
        for (unique_scales.items) |s| {
            if (std.mem.eql(u8, s, r.scale)) {
                found = true;
                break;
            }
        }
        if (!found) try unique_scales.append(allocator, r.scale);
    }

    const backend_names = [_][]const u8{ "TimeSeries", "Columnar", "Hierarchical", "RingBuffer" };
    const backend_colors = [_][]const u8{ "#f0b429", "#a78bfa", "#fb923c", "#f472b6" };

    try html.print(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n", .{});
    try html.print(allocator, "<meta charset=\"UTF-8\" />\n", .{});
    try html.print(allocator, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />\n", .{});
    try html.print(allocator, "<title>Digital Twin — Multi-Scale Backend Benchmark</title>\n", .{});
    try html.print(allocator, "<style>\n", .{});
    try html.print(allocator, "  :root {{\n    --bg: #0f1419; --panel: #161c24; --panel-2: #1d2530; --border: #2a3441;\n    --text: #e6edf3; --text-dim: #8b97a6; --accent: #4ea8de; --gold: #f0b429;\n    --green: #4ade80; --red: #f87171; --orange: #fb923c; --purple: #a78bfa;\n  }}\n", .{});
    try html.print(allocator, "  * {{ box-sizing: border-box; margin: 0; padding: 0; }}\n", .{});
    try html.print(allocator, "  body {{\n    font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif;\n    background: var(--bg); color: var(--text); line-height: 1.55; padding: 32px 20px 80px;\n  }}\n", .{});
    try html.print(allocator, "  .container {{ max-width: 1240px; margin: 0 auto; }}\n", .{});
    try html.print(allocator, "  header {{ margin-bottom: 32px; }}\n", .{});
    try html.print(allocator, "  h1 {{ font-size: 32px; font-weight: 700; letter-spacing: -0.02em; }}\n", .{});
    try html.print(allocator, "  h1 .accent {{ color: var(--accent); }}\n", .{});
    try html.print(allocator, "  .subtitle {{ color: var(--text-dim); margin-top: 6px; font-size: 14px; }}\n", .{});
    try html.print(allocator, "  .meta-row {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; }}\n", .{});
    try html.print(allocator, "  .chip {{ background: var(--panel); border: 1px solid var(--border); padding: 6px 12px; border-radius: 999px; font-size: 12px; color: var(--text-dim); }}\n", .{});
    try html.print(allocator, "  .honesty {{ background: linear-gradient(90deg, rgba(240,180,41,0.08), rgba(240,180,41,0.02)); border-left: 3px solid var(--gold); padding: 12px 16px; border-radius: 6px; font-size: 13px; color: var(--text); margin-top: 20px; }}\n", .{});
    try html.print(allocator, "  section {{ margin-bottom: 56px; }}\n", .{});
    try html.print(allocator, "  h2 {{ font-size: 20px; margin-bottom: 8px; font-weight: 600; display: flex; align-items: center; gap: 10px; }}\n", .{});
    try html.print(allocator, "  h2 .num {{ background: var(--accent); color: #0b1117; width: 26px; height: 26px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 700; }}\n", .{});
    try html.print(allocator, "  .scale-tabs {{ display: inline-flex; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 4px; margin-bottom: 16px; gap: 4px; }}\n", .{});
    try html.print(allocator, "  .scale-tab {{ background: transparent; color: var(--text-dim); border: none; padding: 8px 16px; border-radius: 5px; font-size: 13px; cursor: pointer; font-family: inherit; transition: all 0.15s; }}\n", .{});
    try html.print(allocator, "  .scale-tab.active {{ background: var(--accent); color: #0b1117; font-weight: 600; }}\n", .{});
    try html.print(allocator, "  .scroll-wrap {{ overflow-x: auto; background: var(--panel); border: 1px solid var(--border); border-radius: 10px; }}\n", .{});
    try html.print(allocator, "  table {{ width: 100%; border-collapse: collapse; font-size: 12px; }}\n", .{});
    try html.print(allocator, "  th, td {{ padding: 8px 12px; text-align: center; border-bottom: 1px solid var(--border); }}\n", .{});
    try html.print(allocator, "  th {{ color: var(--text-dim); font-weight: 500; font-size: 11px; background: var(--panel-2); }}\n", .{});
    try html.print(allocator, "  .bar-row {{ display: grid; grid-template-columns: 110px 1fr 70px; align-items: center; gap: 10px; font-size: 12px; margin-bottom: 7px; }}\n", .{});
    try html.print(allocator, "  .bar-label {{ color: var(--text); font-weight: 500; font-size: 11px; }}\n", .{});
    try html.print(allocator, "  .bar-track {{ background: var(--panel-2); height: 22px; border-radius: 4px; overflow: hidden; }}\n", .{});
    try html.print(allocator, "  .bar-fill {{ height: 100%; border-radius: 4px; display: flex; align-items: center; padding-left: 8px; color: #0b1117; font-weight: 600; font-size: 11px; min-width: fit-content; }}\n", .{});
    try html.print(allocator, "  .chart-block {{ background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 18px; margin-bottom: 12px; }}\n", .{});
    try html.print(allocator, "  .chart-title {{ font-size: 13px; color: var(--text-dim); margin-bottom: 12px; }}\n", .{});
    try html.print(allocator, "  .chart-title .qname {{ font-family: monospace; color: var(--text); }}\n", .{});
    try html.print(allocator, "  footer {{ margin-top: 50px; padding-top: 20px; border-top: 1px solid var(--border); color: var(--text-dim); font-size: 12px; text-align: center; }}\n", .{});
    try html.print(allocator, "</style>\n</head>\n<body>\n<div class=\"container\">\n", .{});

    // Header
    try html.print(allocator, "<header>\n", .{});
    try html.print(allocator, "<h1>Digital Twin <span class=\"accent\">Multi-Scale Benchmark</span></h1>\n", .{});
    try html.print(allocator, "<div class=\"subtitle\">{d} specialized backends · {d} scales · pick by workload, not by average</div>\n", .{ backend_names.len, unique_scales.items.len });
    try html.print(allocator, "<div class=\"meta-row\">\n", .{});
    try html.print(allocator, "<span class=\"chip\"><strong>Iterations</strong>25 / measurement</span>\n", .{});
    try html.print(allocator, "<span class=\"chip\"><strong>Seed</strong>{d}</span>\n", .{fixtures.SEED});
    try html.print(allocator, "<span class=\"chip\"><strong>Backends</strong>{d} (TimeSeries, Columnar, Hierarchical, RingBuffer)</span>\n", .{backend_names.len});
    try html.print(allocator, "<span class=\"chip\"><strong>Queries</strong>{d}</span>\n", .{unique_queries.items.len});
    try html.print(allocator, "<span class=\"chip\"><strong>Scales</strong>{d}</span>\n", .{unique_scales.items.len});
    try html.print(allocator, "</div>\n", .{});
    try html.print(allocator, "<div class=\"honesty\"><strong>⚠ Honesty headline:</strong> relative rankings are reliable; absolute numbers are approximate.</div>\n", .{});
    try html.print(allocator, "</header>\n", .{});

    // Section 1: Per-query latency by scale
    try html.print(allocator, "<section>\n", .{});
    try html.print(allocator, "<h2><span class=\"num\">1</span> Per-query latency by scale</h2>\n", .{});
    try html.print(allocator, "<div class=\"scale-tabs\">\n", .{});

    // Create scale tabs
    for (unique_scales.items, 0..) |scale, idx| {
        const active = if (idx == 0) "active" else "";
        try html.print(allocator, "  <button class=\"scale-tab {s}\" data-scale=\"{s}\">{s}</button>\n", .{ active, scale, scale });
    }
    try html.print(allocator, "</div>\n", .{});

    // Charts for each scale and query
    for (unique_scales.items) |scale| {
        const scale_hidden = if (!std.mem.eql(u8, scale, unique_scales.items[0])) "style=\"display:none\"" else "";
        try html.print(allocator, "<div class=\"scale-container\" data-scale=\"{s}\" {s}>\n", .{ scale, scale_hidden });

        for (unique_queries.items) |query| {
            // Find min and max for this query across all backends at this scale
            var min_val: f64 = 1e30;
            var max_val: f64 = 0;

            for (rows) |r| {
                if (std.mem.eql(u8, r.scale, scale) and std.mem.eql(u8, r.query, query)) {
                    const median_us = @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0;
                    min_val = @min(min_val, median_us);
                    max_val = @max(max_val, median_us);
                }
            }

            if (min_val > 1e30) continue;

            try html.print(allocator, "  <div class=\"chart-block\">\n", .{});
            try html.print(allocator, "    <div class=\"chart-title\"><span class=\"qname\">{s}</span></div>\n", .{query});
            try html.print(allocator, "    <div style=\"display:flex;flex-direction:column;gap:7px\">\n", .{});

            // Collect and sort results for this query/scale
            const QueryResult = struct { backend: []const u8, median_us: f64, color: []const u8 };
            var query_results: std.ArrayList(QueryResult) = .empty;
            defer query_results.deinit(allocator);

            for (rows) |r| {
                if (std.mem.eql(u8, r.scale, scale) and std.mem.eql(u8, r.query, query)) {
                    const median_us = @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0;
                    var color: []const u8 = "#999";
                    for (backend_names, backend_colors) |name, col| {
                        if (std.mem.eql(u8, r.backend, name)) {
                            color = col;
                            break;
                        }
                    }
                    try query_results.append(allocator, .{ .backend = r.backend, .median_us = median_us, .color = color });
                }
            }

            // Sort by latency
            std.mem.sort(
                QueryResult,
                query_results.items,
                {},
                struct {
                    fn compare(_: void, a: QueryResult, b: QueryResult) bool {
                        return a.median_us < b.median_us;
                    }
                }.compare,
            );

            // Draw bars
            for (query_results.items) |result| {
                const width_pct = if (max_val > 0) (result.median_us / max_val) * 100.0 else 0;
                const is_winner = std.mem.eql(u8, result.backend, query_results.items[0].backend);
                const winner_style = if (is_winner) "box-shadow: 0 0 0 1px var(--green);" else "";

                try html.print(allocator, "      <div class=\"bar-row\">\n", .{});
                try html.print(allocator, "        <div class=\"bar-label\" style=\"{s}\">{s}</div>\n", .{ if (is_winner) "color:var(--green)" else "", result.backend });
                try html.print(allocator, "        <div class=\"bar-track\">\n", .{});
                try html.print(allocator, "          <div class=\"bar-fill\" style=\"width:{d:.1}%;background:{s};{s}\">\n", .{ @max(width_pct, 10), result.color, winner_style });
                try html.print(allocator, "            {d:.2} µs\n", .{result.median_us});
                try html.print(allocator, "          </div>\n", .{});
                try html.print(allocator, "        </div>\n", .{});
                try html.print(allocator, "        <div style=\"color:var(--text-dim);font-family:monospace;font-size:11px;text-align:right\">{s}</div>\n", .{if (is_winner) "★ winner" else ""});
                try html.print(allocator, "      </div>\n", .{});
            }

            try html.print(allocator, "    </div>\n  </div>\n", .{});
        }
        try html.print(allocator, "</div>\n", .{});
    }

    try html.print(allocator, "</section>\n", .{});

    // Summary and footer
    try html.print(allocator, "<footer>\nMedian latencies in microseconds (µs). Lower is better.<br />\n", .{});
    try html.print(allocator, "Data: digital twin multi-scale benchmark · seed {d}\n", .{fixtures.SEED});
    try html.print(allocator, "</footer>\n", .{});

    try html.print(allocator, "</div>\n<script>\n", .{});
    try html.print(allocator, "document.querySelectorAll('.scale-tab').forEach(tab => {{\n", .{});
    try html.print(allocator, "  tab.addEventListener('click', function() {{\n", .{});
    try html.print(allocator, "    document.querySelectorAll('.scale-tab').forEach(t => t.classList.remove('active'));\n", .{});
    try html.print(allocator, "    this.classList.add('active');\n", .{});
    try html.print(allocator, "    const scale = this.getAttribute('data-scale');\n", .{});
    try html.print(allocator, "    document.querySelectorAll('.scale-container').forEach(c => {{\n", .{});
    try html.print(allocator, "      c.style.display = c.getAttribute('data-scale') === scale ? 'block' : 'none';\n", .{});
    try html.print(allocator, "    }});\n", .{});
    try html.print(allocator, "  }});\n", .{});
    try html.print(allocator, "}});\n", .{});
    try html.print(allocator, "</script>\n</body>\n</html>\n", .{});

    try dir.writeFile(io, .{ .sub_path = "benchmark.html", .data = html.items });
}

/// For each unique query within a given scale, find the backend with the
/// lowest median latency and the runner-up; emit a Markdown row.
fn writeWinners(w: *std.ArrayList(u8), allocator: std.mem.Allocator, rows: []const RunRow, scale: []const u8) !void {
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    for (rows) |r| {
        if (!std.mem.eql(u8, r.scale, scale)) continue;

        var already = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, r.query)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen.append(allocator, r.query);

        var best_idx: ?usize = null;
        var second_idx: ?usize = null;
        for (rows, 0..) |candidate, i| {
            if (!std.mem.eql(u8, candidate.scale, scale)) continue;
            if (!std.mem.eql(u8, candidate.query, r.query)) continue;
            if (best_idx == null or candidate.stats.median_ns < rows[best_idx.?].stats.median_ns) {
                second_idx = best_idx;
                best_idx = i;
            } else if (second_idx == null or candidate.stats.median_ns < rows[second_idx.?].stats.median_ns) {
                second_idx = i;
            }
        }

        if (best_idx) |bi| {
            const best = rows[bi];
            const best_us = @as(f64, @floatFromInt(best.stats.median_ns)) / 1000.0;

            if (second_idx) |si| {
                const second = rows[si];
                const second_us = @as(f64, @floatFromInt(second.stats.median_ns)) / 1000.0;
                const speedup = if (best.stats.median_ns > 0)
                    @as(f64, @floatFromInt(second.stats.median_ns)) /
                        @as(f64, @floatFromInt(best.stats.median_ns))
                else
                    0.0;
                try w.print(allocator, "| {s} | **{s}** | {d:.1} | {s} | {d:.1} | {d:.2}× |\n", .{
                    r.query, best.backend, best_us, second.backend, second_us, speedup,
                });
            } else {
                try w.print(allocator, "| {s} | **{s}** | {d:.1} | — | — | — |\n", .{
                    r.query, best.backend, best_us,
                });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — recommendCompound (compound recommendation scoring).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testRow(scale: []const u8, query: []const u8, backend: []const u8, median_ns: i64) RunRow {
    return .{
        .scale = scale,
        .query = query,
        .backend = backend,
        .memory_bytes = 0,
        .stats = .{
            .iterations = 25,
            .median_ns = median_ns,
            .p95_ns = median_ns,
            .p99_ns = median_ns,
            .min_ns = median_ns,
            .max_ns = median_ns,
            .mean_ns = median_ns,
            .total_ns = median_ns * 25,
        },
    };
}

test "recommendCompound: RingBuffer wins real-time track, excluded from historical track" {
    // Simulates the compound split: RingBuffer is fastest on latest_*
    // (real-time family) but is excluded from the historical track where
    // only full-retention backends compete.
    const mix = [_]queries.QueryWeight{
        .{ .query = .latest_single, .weight = 3.0, .hot = true },
        .{ .query = .latest_zone, .weight = 2.0, .hot = true },
        .{ .query = .daily_zone_rollup, .weight = 5.0, .hot = false },
        .{ .query = .avg_zone_type, .weight = 3.0, .hot = false },
        .{ .query = .anomalies, .weight = 4.0, .hot = true },
    };

    var rows: std.ArrayList(RunRow) = .empty;
    defer rows.deinit(testing.allocator);
    for (mix) |qw| {
        const qn = queryNameStr(qw.query);
        // RingBuffer: fastest on real-time, but also present for historical
        // queries (the point is that the compound split excludes it from
        // the historical track regardless of its row presence).
        try rows.append(testing.allocator, testRow("Small", qn, "RingBuffer", 5));
        try rows.append(testing.allocator, testRow("Small", qn, "TimeSeries", 50));
        try rows.append(testing.allocator, testRow("Small", qn, "Columnar", 80));
    }

    const full_retention = [_][]const u8{ "TimeSeries", "Columnar" };

    const compound = try recommendCompound(
        testing.allocator,
        rows.items,
        "Small",
        &mix,
        &full_retention,
    );
    defer testing.allocator.free(compound.realtime.scores);
    defer testing.allocator.free(compound.historical.scores);

    // Real-time track: all three backends compete; RingBuffer is fastest.
    try testing.expectEqualStrings("RingBuffer", compound.realtime.winner);
    try testing.expectEqual(@as(usize, 3), compound.realtime.scores.len);

    // Historical track: RingBuffer excluded; only TimeSeries and Columnar.
    try testing.expectEqual(@as(usize, 2), compound.historical.scores.len);
    for (compound.historical.scores) |s| {
        try testing.expect(!std.mem.eql(u8, s.backend, "RingBuffer"));
    }
    // TimeSeries (50) beats Columnar (80) on every historical query.
    try testing.expectEqualStrings("TimeSeries", compound.historical.winner);
}

// ---------------------------------------------------------------------------
// Growth curve + simulation JSON — latency vs building age, and machine-
// readable sim stats for downstream tooling.
// ---------------------------------------------------------------------------

const sim_mod = @import("simulation.zig");

/// Write a "Latency vs Building Age" section to the markdown report,
/// showing how each query's median latency grows as the building
/// accumulates data from day 1 to steady state.
pub fn writeGrowthSection(
    md: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    growth: []const sim_mod.GrowthPoint,
) !void {
    if (growth.len == 0) return;

    try md.print(allocator, "\n## Latency vs Building Age (Growth Curve)\n\n", .{});
    try md.print(allocator, "Each row is one query's median latency at one checkpoint in the " ++
        "building's simulated lifetime — from day 1 (near-empty) to steady state " ++
        "(retention-full, actively evicting). This shows whether a backend's query " ++
        "latency is constant (O(1) access) or grows with data volume.\n\n", .{});

    try md.print(allocator, "| Checkpoint | Day | Backend | Query | Median µs | Live readings | Memory (MB) |\n", .{});
    try md.print(allocator, "|---|---:|---|---|---:|---:|---:|\n", .{});
    for (growth) |g| {
        try md.print(allocator, "| {s} | {d} | {s} | {s} | {d:.1} | {d} | {d:.1} |\n", .{
            g.label,
            g.sim_day,
            g.backend,
            g.query,
            @as(f64, @floatFromInt(g.median_ns)) / 1000.0,
            g.reading_count,
            @as(f64, @floatFromInt(g.memory_bytes)) / (1024.0 * 1024.0),
        });
    }
}

/// Write a "Simulation Summary" section to the markdown report with
/// per-backend compression ratios, data volume, and prune statistics.
pub fn writeSimSection(
    md: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sim_stats: []const sim_mod.SimStats,
    type_volumes: []const sim_mod.TypeVolume,
) !void {
    if (sim_stats.len == 0) return;

    try md.print(allocator, "\n## Simulation Summary\n\n", .{});
    try md.print(allocator, "Per-backend wall-time cost of the live day-zero simulation " ++
        "(simulated time / wall time = compression ratio), data volume, and prune activity.\n\n", .{});

    try md.print(allocator, "| Backend | Sim days | Wall time (s) | Compression | Generated | Evicted | Prune calls | Stream time (s) | Prune time (s) |\n", .{});
    try md.print(allocator, "|---|---:|---:|---:|---:|---:|---:|---:|---:|\n", .{});
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    for (sim_stats) |s| {
        const sim_days = @divTrunc(s.sim_ms, day_ms);
        const wall_s = @as(f64, @floatFromInt(s.wall_ns)) / 1e9;
        const ingest_s = @as(f64, @floatFromInt(s.ingest_ns)) / 1e9;
        const prune_s = @as(f64, @floatFromInt(s.prune_ns)) / 1e9;
        try md.print(allocator, "| {s} | {d} | {d:.1} | {d:.0}× | {d} | {d} | {d} | {d:.1} | {d:.1} |\n", .{
            s.backend, sim_days, wall_s, s.compressionRatio(), s.generated, s.evicted, s.prune_calls, ingest_s, prune_s,
        });
    }

    if (type_volumes.len > 0) {
        try md.print(allocator, "\n### Steady-state data volume by sensor type\n\n", .{});
        try md.print(allocator, "| Sensor type | Readings | Bytes (MB) |\n|---|---:|---:|\n", .{});
        for (type_volumes) |tv| {
            try md.print(allocator, "| {s} | {d} | {d:.1} |\n", .{
                @tagName(tv.sensor_type),
                tv.reading_count,
                @as(f64, @floatFromInt(tv.bytes)) / (1024.0 * 1024.0),
            });
        }
    }
}

/// Write machine-readable simulation data as JSON to `simulation.json` in
/// the output directory. Contains per-backend sim stats, growth points,
/// and type volumes — everything an external tool needs to plot the growth
/// curve or compare backends' simulation efficiency.
pub fn writeSimJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    sim_stats: []const sim_mod.SimStats,
    growth: []const sim_mod.GrowthPoint,
    type_volumes: []const sim_mod.TypeVolume,
) !void {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);

    try json.print(allocator, "{{\n", .{});

    // sim_stats
    try json.print(allocator, "  \"sim_stats\": [\n", .{});
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    for (sim_stats, 0..) |s, i| {
        const sim_days = @divTrunc(s.sim_ms, day_ms);
        try json.print(allocator, "    {{\n", .{});
        try json.print(allocator, "      \"backend\": \"{s}\",\n", .{s.backend});
        try json.print(allocator, "      \"sim_days\": {d},\n", .{sim_days});
        try json.print(allocator, "      \"wall_ns\": {d},\n", .{s.wall_ns});
        try json.print(allocator, "      \"compression_ratio\": {d:.1},\n", .{s.compressionRatio()});
        try json.print(allocator, "      \"generated\": {d},\n", .{s.generated});
        try json.print(allocator, "      \"ingested\": {d},\n", .{s.ingested});
        try json.print(allocator, "      \"evicted\": {d},\n", .{s.evicted});
        try json.print(allocator, "      \"prune_calls\": {d},\n", .{s.prune_calls});
        try json.print(allocator, "      \"ingest_ns\": {d},\n", .{s.ingest_ns});
        try json.print(allocator, "      \"prune_ns\": {d}\n", .{s.prune_ns});
        try json.print(allocator, "    }}{s}\n", .{if (i + 1 < sim_stats.len) "," else ""});
    }
    try json.print(allocator, "  ],\n", .{});

    // growth_points
    try json.print(allocator, "  \"growth_points\": [\n", .{});
    for (growth, 0..) |g, i| {
        try json.print(allocator, "    {{\n", .{});
        try json.print(allocator, "      \"sim_day\": {d},\n", .{g.sim_day});
        try json.print(allocator, "      \"label\": \"{s}\",\n", .{g.label});
        try json.print(allocator, "      \"backend\": \"{s}\",\n", .{g.backend});
        try json.print(allocator, "      \"query\": \"{s}\",\n", .{g.query});
        try json.print(allocator, "      \"median_ns\": {d},\n", .{g.median_ns});
        try json.print(allocator, "      \"memory_bytes\": {d},\n", .{g.memory_bytes});
        try json.print(allocator, "      \"live_bytes\": {d},\n", .{g.live_bytes});
        try json.print(allocator, "      \"reading_count\": {d}\n", .{g.reading_count});
        try json.print(allocator, "    }}{s}\n", .{if (i + 1 < growth.len) "," else ""});
    }
    try json.print(allocator, "  ],\n", .{});

    // type_volumes
    try json.print(allocator, "  \"type_volumes\": [\n", .{});
    for (type_volumes, 0..) |tv, i| {
        try json.print(allocator, "    {{\n", .{});
        try json.print(allocator, "      \"sensor_type\": \"{s}\",\n", .{@tagName(tv.sensor_type)});
        try json.print(allocator, "      \"reading_count\": {d},\n", .{tv.reading_count});
        try json.print(allocator, "      \"bytes\": {d}\n", .{tv.bytes});
        try json.print(allocator, "    }}{s}\n", .{if (i + 1 < type_volumes.len) "," else ""});
    }
    try json.print(allocator, "  ]\n", .{});
    try json.print(allocator, "}}\n", .{});

    try dir.writeFile(io, .{ .sub_path = "simulation.json", .data = json.items });
}
