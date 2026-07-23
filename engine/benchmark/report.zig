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
const sb = @import("../ecs/storage/storage_backend.zig");

/// One latency-table row, decoupled from how it's rendered.
pub const RunRow = struct {
    scale: []const u8,
    query: []const u8,
    backend: []const u8,
    memory_bytes: usize,
    stats: metrics.LatencyStats,
};

/// Maps a queries.QueryName to the exact query-name string runner.zig's
/// query_specs use. Exported so runner.zig's `run` can build RunRow.query
/// values without a second hand-maintained copy of this switch.
pub fn queryNameStr(qn: queries.QueryName) []const u8 {
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

/// Auto-scaled human-readable duration — µs below 1000µs, ms below
/// 100_000µs (100ms), s otherwise. Used everywhere a raw query latency is
/// displayed; never applied to scores/coverage/ratios (those stay as
/// plain numbers). See docs/superpowers/specs/2026-07-06-recommendation-
/// report-readability-design.md.
pub const ScaledDuration = struct { value: f64, unit: []const u8 };

pub fn scaleMicros(us: f64) ScaledDuration {
    if (us < 1000.0) return .{ .value = us, .unit = "µs" };
    if (us < 100_000.0) return .{ .value = us / 1000.0, .unit = "ms" };
    return .{ .value = us / 1_000_000.0, .unit = "s" };
}

/// Escapes the 5 XML predefined entities so untrusted text — IFC zone/room
/// names, source file paths, none of it validated or under this platform's
/// control — can't break the structure of generated markup it's embedded
/// in (a bare `&` or `<` from a vendor-exported name is enough to produce
/// invalid SVG/HTML). The same five entities are valid in both XML and
/// HTML, so this one helper covers schematic.zig's SVG output and this
/// file's HTML report. Caller frees the returned slice.
pub fn escapeXml(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "escapeXml: escapes the 5 XML predefined entities, leaves other text untouched" {
    const allocator = std.testing.allocator;
    const escaped = try escapeXml(allocator, "M&E Room <Lab> \"East\" O'Brien");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("M&amp;E Room &lt;Lab&gt; &quot;East&quot; O&apos;Brien", escaped);
}

test "escapeXml: text with nothing to escape is returned unchanged" {
    const allocator = std.testing.allocator;
    const escaped = try escapeXml(allocator, "Room 204");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Room 204", escaped);
}

/// Format nanoseconds as scaled microseconds (same scaling logic as latencies).
fn formatNs(ns: i64) ScaledDuration {
    const us = @as(f64, @floatFromInt(ns)) / 1000.0;
    return scaleMicros(us);
}

/// Display label for a query family in the report tables (hyphenated, unlike
/// the enum tag).
fn familyLabel(f: queries.QueryFamily) []const u8 {
    return switch (f) {
        .real_time => "real-time",
        .aggregation => "aggregation",
        .historical => "historical",
        .spatial => "spatial",
        .anomaly => "anomaly",
    };
}

/// Returns `query_results` sorted by family (real-time first, following enum
/// order) then query name. Caller frees.
fn sortedRankings(allocator: std.mem.Allocator, query_results: []const QueryRanking) ![]QueryRanking {
    const sorted = try allocator.dupe(QueryRanking, query_results);
    std.mem.sort(QueryRanking, sorted, {}, struct {
        fn lt(_: void, lhs: QueryRanking, rhs: QueryRanking) bool {
            const lf = @intFromEnum(lhs.family);
            const rf = @intFromEnum(rhs.family);
            if (lf != rf) return lf < rf;
            return std.mem.lessThan(u8, lhs.query_name, rhs.query_name);
        }
    }.lt);
    return sorted;
}

/// Write the per-query dashboard: for each query this building runs, the
/// fastest eligible backend, its latency, the runner-up margin, and the
/// winner's amortized cost per million queries. Grouped by family
/// (real-time first), then query name. Backend eligibility is already
/// applied by perQueryResults — see its doc comment.
pub fn writePerQueryMarkdown(
    md: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    query_results: []const QueryRanking,
) !void {
    try md.print(allocator, "## Per-query dashboard\n\n", .{});
    if (query_results.len == 0) {
        try md.print(allocator, "No per-query results available.\n\n", .{});
        return;
    }

    const sorted = try sortedRankings(allocator, query_results);
    defer allocator.free(sorted);

    try md.print(allocator, "The ground truth behind the verdict above: for every query pattern this building runs, " ++
        "the fastest backend at steady state. Non-real-time queries only admit full-retention backends — the " ++
        "count-capped real-time cache scanned a fraction of the data, an incomparable measurement. Cost/M is the " ++
        "winner's total annual cost (storage + query) amortized per million queries.\n\n", .{});
    try md.print(allocator, "| Family | Query | Winner | Latency | Runner-up | Speedup | Cost/M queries |\n", .{});
    try md.print(allocator, "|---|---|---|---:|---|---:|---:|\n", .{});

    for (sorted) |qr| {
        if (qr.results.len == 0) continue;

        const winner = qr.results[0];
        const winner_us = @as(f64, @floatFromInt(winner.median_ns)) / 1000.0;
        try md.print(allocator, "| {s} | {s} | **{s}** | ", .{ familyLabel(qr.family), qr.query_name, winner.backend });
        try writeScaledUs(md, allocator, winner_us, true);

        if (qr.results.len > 1) {
            const runner = qr.results[1];
            const speedup = if (winner.median_ns > 0)
                @as(f64, @floatFromInt(runner.median_ns)) / @as(f64, @floatFromInt(winner.median_ns))
            else
                0.0;
            try md.print(allocator, " | {s} | {d:.2}× | ${d:.4} |\n", .{ runner.backend, speedup, winner.cost_per_query * 1_000_000.0 });
        } else {
            try md.print(allocator, " | — | — | ${d:.4} |\n", .{winner.cost_per_query * 1_000_000.0});
        }
    }
    try md.print(allocator, "\n", .{});
}

/// Writes a raw microsecond value to `w`. `scaled = false` preserves the
/// exact legacy "N.N" plain-µs formatting (used by the zig build bench
/// regression suite, which must stay byte-identical); `scaled = true` runs
/// it through scaleMicros first (used by the per-building recommendation
/// report). µs values keep 1 decimal; ms/s values use 2.
pub fn writeScaledUs(w: *std.ArrayList(u8), allocator: std.mem.Allocator, us: f64, scaled: bool) !void {
    if (!scaled) {
        try w.print(allocator, "{d:.1}", .{us});
        return;
    }
    const d = scaleMicros(us);
    if (std.mem.eql(u8, d.unit, "µs")) {
        try w.print(allocator, "{d:.1}{s}", .{ d.value, d.unit });
    } else {
        try w.print(allocator, "{d:.2}{s}", .{ d.value, d.unit });
    }
}

/// One sensor type's own TrackWinners (see below), scoped to that type's
/// type-scoped queries. Moved here (from main.zig) so both the markdown
/// assembly in main.zig and writeBuildingHtmlReport below can share one
/// definition.
pub const TypeTrackWinners = struct {
    sensor_type: sb.SensorType,
    winners: TrackWinners,
};

/// One row of the "Sensors placed, by type" table — plain data, no
/// dependency on synthetic/generator.zig's SensorProfile so this file's
/// import graph stays as-is.
pub const SensorTypeCount = struct {
    name: []const u8,
    count: u32,
    retention_days: u32,
};

/// One row of the cost-estimate table — mirrors cost_model.CostEstimate's
/// printed fields without importing cost_model.zig here (cost_model.zig
/// already imports report.zig for RunRow, so importing it back would be a
/// circular dependency; main.zig maps cost_model.CostEstimate values into
/// this type instead).
pub const CostRow = struct {
    backend: []const u8,
    storage_gb: f64,
    storage_cost_year: f64,
    query_cost_year: f64,
    total_cost_year: f64,
};

/// One backend's result for a single query — latency percentiles and the
/// backend's amortized cost per single query execution (USD; total annual
/// cost / queries per year, so storage footprint differentiates backends).
pub const QueryBackendResult = struct {
    backend: []const u8,
    median_ns: i64,
    p95_ns: i64,
    p99_ns: i64,
    cost_per_query: f64,
};

/// All eligible backends' results for one query, sorted by median latency
/// ascending — `results[0]` is the winner. `family` uses the same
/// queries.familyOf classification `pickTrackWinners` splits on.
pub const QueryRanking = struct {
    query_name: []const u8,
    results: []QueryBackendResult,
    family: queries.QueryFamily,
};

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

/// Every distinct `RunRow.backend` across `rows`, first-seen order, deduped —
/// scale-independent, for callers that need the full backend roster the
/// regression suite actually benchmarked. Caller frees with `allocator`.
///
/// Exists so the report header/chip/color-legend can't drift from a
/// hardcoded backend list again: `writeHtmlReport`'s `backend_names` used
/// to be a fixed 4-entry array that silently excluded any backend added to
/// runner.zig's registry afterward (missed "Lake" for a while — it rendered
/// with the "unknown backend" gray fallback and was omitted from the
/// subtitle/chip counts and text, even though its rows were in the table).
pub fn uniqueBackends(allocator: std.mem.Allocator, rows: []const RunRow) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (rows) |r| {
        var seen = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, r.backend)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(allocator, r.backend);
    }
    return names.toOwnedSlice(allocator);
}

/// Chart color palette for the HTML dashboard's per-backend bars, assigned
/// by a backend's position in `uniqueBackends` output rather than by name —
/// any number of backends up to this palette's length gets a real color;
/// beyond that (or for a name not in `roster`, which shouldn't happen when
/// `roster` itself came from the same rows) it falls back to gray.
pub const BACKEND_COLOR_PALETTE = [_][]const u8{
    "#f0b429", "#a78bfa", "#fb923c", "#f472b6", "#4ade80", "#4ea8de", "#f87171",
};

fn colorForBackend(roster: []const []const u8, name: []const u8) []const u8 {
    for (roster, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return BACKEND_COLOR_PALETTE[i % BACKEND_COLOR_PALETTE.len];
    }
    return "#999";
}

/// Compute per-query rankings for a given scale: for each unique query, the
/// eligible backends sorted fastest-first, each carrying its amortized
/// cost-per-query (from `backend_cost_per_query`, keyed by backend name).
/// Applies the SAME eligibility rule `writeWinners` uses: non-real-time
/// queries only admit `historical_eligible` backends — the count-capped
/// real-time cache scanned a fraction of the data those queries need, an
/// incomparable measurement (see writeWinners's doc comment).
/// Caller frees each ranking's `results` slice and the outer slice.
pub fn perQueryResults(
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    backend_cost_per_query: std.StringHashMap(f64),
    historical_eligible: ?[]const []const u8,
) ![]QueryRanking {
    var results: std.ArrayList(QueryRanking) = .empty;
    errdefer {
        for (results.items) |qr| allocator.free(qr.results);
        results.deinit(allocator);
    }

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

        // Unrecognized query names stay unfiltered — same fallback
        // findWinnerAndRunnerUp's rowEligible applies.
        const query_name = queryNameFromStr(r.query);
        const family: queries.QueryFamily = if (query_name) |q| queries.familyOf(q) else .aggregation;
        const restrict = query_name != null and family != .real_time;

        var backend_results: std.ArrayList(QueryBackendResult) = .empty;
        defer backend_results.deinit(allocator);

        for (rows) |cand| {
            if (!std.mem.eql(u8, cand.scale, scale)) continue;
            if (!std.mem.eql(u8, cand.query, r.query)) continue;
            if (restrict and !backendEligible(historical_eligible, cand.backend)) continue;
            var dup = false;
            for (backend_results.items) |br| {
                if (std.mem.eql(u8, br.backend, cand.backend)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try backend_results.append(allocator, .{
                .backend = cand.backend,
                .median_ns = cand.stats.median_ns,
                .p95_ns = cand.stats.p95_ns,
                .p99_ns = cand.stats.p99_ns,
                .cost_per_query = backend_cost_per_query.get(cand.backend) orelse 0.0,
            });
        }
        if (backend_results.items.len == 0) continue;

        std.mem.sort(QueryBackendResult, backend_results.items, {}, struct {
            fn lt(_: void, lhs: QueryBackendResult, rhs: QueryBackendResult) bool {
                return lhs.median_ns < rhs.median_ns;
            }
        }.lt);

        try results.append(allocator, .{
            .query_name = r.query,
            .results = try backend_results.toOwnedSlice(allocator),
            .family = family,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// The two-track deployment verdict: which backend wins the most real-time
/// (`latest_*`) queries, and which wins the most of everything else.
/// `*_wins`/`*_total` are how many of that family's queries were actually
/// counted (query_rankings entries with at least one eligible result), so
/// the verdict can say "wins 3 of 3" instead of a bare name. `winner` is
/// `"none"` when a track has zero queries to count.
///
/// Replaces the old scoreBackends/recommendCompound weighted-ratio model
/// (removed 2026-07-20 — the whole thing didn't hold up under scrutiny; see
/// backend-audit.md's 2026-07-20 entry for the full reasoning): every
/// backend already answers `latest_*` via an O(1) cached lookup, so that
/// track's weighted score mostly measured lookup-overhead noise rather than
/// a real architectural difference, and a single slow outlier query in the
/// historical mix could blow the weighted average up to 4+ digits with no
/// interpretable real-world meaning. Counting per-query wins directly off
/// `perQueryResults`' own already-computed winners is honest about what it
/// is — "who wins the most queries" — and can't be distorted by outliers or
/// arbitrary weight/penalty constants the way an averaged ratio can.
pub const TrackWinners = struct {
    realtime_winner: []const u8,
    realtime_wins: usize,
    realtime_total: usize,
    historical_winner: []const u8,
    historical_wins: usize,
    historical_total: usize,
};

/// Counts, for one family group (real-time vs everything else), how many
/// queries each backend won (`query_rankings[i].results[0].backend`), and
/// returns whichever backend won the most. Ties keep whichever backend was
/// first counted — deterministic because `query_rankings`' own order is
/// (both callers build it via `perQueryResults`, itself a deterministic
/// scan of `rows`).
fn trackWinner(allocator: std.mem.Allocator, query_rankings: []const QueryRanking, want_realtime: bool) !struct { winner: []const u8, wins: usize, total: usize } {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(allocator);
    var total: usize = 0;

    for (query_rankings) |qr| {
        if ((qr.family == .real_time) != want_realtime) continue;
        if (qr.results.len == 0) continue;
        total += 1;
        const winner_name = qr.results[0].backend;

        var found = false;
        for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, winner_name)) {
                counts.items[i] += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            try names.append(allocator, winner_name);
            try counts.append(allocator, 1);
        }
    }

    if (names.items.len == 0) return .{ .winner = "none", .wins = 0, .total = total };

    var best: usize = 0;
    for (counts.items, 0..) |c, i| {
        if (c > counts.items[best]) best = i;
    }
    return .{ .winner = names.items[best], .wins = counts.items[best], .total = total };
}

/// Derives `TrackWinners` from `perQueryResults`' output — see that
/// function's doc comment for the eligibility rule (non-real-time queries
/// already restricted to full-retention backends before this ever sees
/// them, so no separate eligibility list is needed here).
pub fn pickTrackWinners(allocator: std.mem.Allocator, query_rankings: []const QueryRanking) !TrackWinners {
    const rt = try trackWinner(allocator, query_rankings, true);
    const hist = try trackWinner(allocator, query_rankings, false);
    return .{
        .realtime_winner = rt.winner,
        .realtime_wins = rt.wins,
        .realtime_total = rt.total,
        .historical_winner = hist.winner,
        .historical_wins = hist.wins,
        .historical_total = hist.total,
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
    const backend_roster = try uniqueBackends(allocator, rows);
    defer allocator.free(backend_roster);
    try md.print(allocator, "- Backends: ", .{});
    for (backend_roster, 0..) |b, i| {
        try md.print(allocator, "{s}{s}", .{ b, if (i + 1 < backend_roster.len) ", " else "\n" });
    }
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
        // null eligibility: the internal regression fixture is small enough
        // that no backend evicts — every backend genuinely holds the full
        // dataset, so all comparisons here are apples-to-apples already.
        try writeWinners(&md, allocator, rows, ds.name, null, false);

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

    const backend_roster = try uniqueBackends(allocator, rows);
    defer allocator.free(backend_roster);

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
    try html.print(allocator, "<div class=\"subtitle\">{d} specialized backends · {d} scales · pick by workload, not by average</div>\n", .{ backend_roster.len, unique_scales.items.len });
    try html.print(allocator, "<div class=\"meta-row\">\n", .{});
    try html.print(allocator, "<span class=\"chip\"><strong>Iterations</strong>25 / measurement</span>\n", .{});
    try html.print(allocator, "<span class=\"chip\"><strong>Seed</strong>{d}</span>\n", .{fixtures.SEED});
    try html.print(allocator, "<span class=\"chip\"><strong>Backends</strong>{d} (", .{backend_roster.len});
    for (backend_roster, 0..) |b, i| {
        try html.print(allocator, "{s}{s}", .{ b, if (i + 1 < backend_roster.len) ", " else "" });
    }
    try html.print(allocator, ")</span>\n", .{});
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
                    const color = colorForBackend(backend_roster, r.backend);
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

/// QueryName for a display-name string (RunRow.query stores the display
/// name), or null for an unrecognized name. Reverse of queryNameStr.
fn queryNameFromStr(name: []const u8) ?queries.QueryName {
    inline for (std.enums.values(queries.QueryName)) |q| {
        if (std.mem.eql(u8, queryNameStr(q), name)) return q;
    }
    return null;
}

/// For each unique query within a given scale, find the backend with the
/// lowest median latency and the runner-up; emit a Markdown row. Used by
/// writeReports' internal regression-suite report (the per-building path's
/// recommendation.md gets the equivalent view from perQueryResults'
/// dashboard instead).
///
/// `historical_eligible`, when non-null, applies the SAME eligibility rule
/// `perQueryResults` already applies: for any query outside the `real_time`
/// family, only backends in that list compete for the winner/runner-up
/// slots. Without this, the count-capped real-time
/// cache (RingBuffer, 10 readings/sensor) showed up as the 171x "winner" of
/// query_anomalies in a real house run — it had scanned a ~200x smaller
/// dataset than every other backend, an incomparable measurement presented
/// as a win. Pass null only when every backend genuinely holds the full
/// dataset (e.g. the internal regression suite's small no-eviction fixture).
pub fn writeWinners(
    w: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    historical_eligible: ?[]const []const u8,
    scaled_units: bool,
) !void {
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

        const pair = findWinnerAndRunnerUp(rows, scale, r.query, historical_eligible) orelse continue;
        const best_us = @as(f64, @floatFromInt(pair.winner.stats.median_ns)) / 1000.0;

        try w.print(allocator, "| {s} | **{s}** | ", .{ r.query, pair.winner.backend });
        try writeScaledUs(w, allocator, best_us, scaled_units);

        if (pair.runner_up) |second| {
            const second_us = @as(f64, @floatFromInt(second.stats.median_ns)) / 1000.0;
            const speedup = if (pair.winner.stats.median_ns > 0)
                @as(f64, @floatFromInt(second.stats.median_ns)) /
                    @as(f64, @floatFromInt(pair.winner.stats.median_ns))
            else
                0.0;
            try w.print(allocator, " | {s} | ", .{second.backend});
            try writeScaledUs(w, allocator, second_us, scaled_units);
            try w.print(allocator, " | {d:.2}× |\n", .{speedup});
        } else {
            try w.print(allocator, " | — | — | — |\n", .{});
        }
    }
}

/// Result of scanning `rows` for one query's fastest backend (winner) and
/// second-fastest (runner-up) at `scale`, respecting the same eligibility
/// rule `perQueryResults` applies (non-real-time queries only admit
/// `historical_eligible` backends when it's non-null). Used by
/// writeWinners (the regression-suite Markdown report). Returns null when no
/// eligible backend has data for this query.
const WinnerPair = struct {
    winner: RunRow,
    runner_up: ?RunRow,
};

fn findWinnerAndRunnerUp(
    rows: []const RunRow,
    scale: []const u8,
    query: []const u8,
    historical_eligible: ?[]const []const u8,
) ?WinnerPair {
    const rowEligible = struct {
        fn check(eligible: ?[]const []const u8, query_name: []const u8, backend: []const u8) bool {
            const list = eligible orelse return true;
            const q = queryNameFromStr(query_name) orelse return true;
            if (queries.familyOf(q) == .real_time) return true;
            return backendEligible(list, backend);
        }
    }.check;

    var best_idx: ?usize = null;
    var second_idx: ?usize = null;
    for (rows, 0..) |candidate, i| {
        if (!std.mem.eql(u8, candidate.scale, scale)) continue;
        if (!std.mem.eql(u8, candidate.query, query)) continue;
        if (!rowEligible(historical_eligible, candidate.query, candidate.backend)) continue;
        if (best_idx == null or candidate.stats.median_ns < rows[best_idx.?].stats.median_ns) {
            second_idx = best_idx;
            best_idx = i;
        } else if (second_idx == null or candidate.stats.median_ns < rows[second_idx.?].stats.median_ns) {
            second_idx = i;
        }
    }

    const bi = best_idx orelse return null;
    return .{
        .winner = rows[bi],
        .runner_up = if (second_idx) |si| rows[si] else null,
    };
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

    try md.print(allocator, "| Checkpoint | Day | Backend | Query | Median | Live readings | Memory (MB) |\n", .{});
    try md.print(allocator, "|---|---:|---|---|---:|---:|---:|\n", .{});
    for (growth) |g| {
        try md.print(allocator, "| {s} | {d} | {s} | {s} | ", .{ g.label, g.sim_day, g.backend, g.query });
        try writeScaledUs(md, allocator, @as(f64, @floatFromInt(g.median_ns)) / 1000.0, true);
        try md.print(allocator, " | {d} | {d:.1} |\n", .{
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
    type_quality: []const sim_mod.TypeQuality,
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

    if (type_quality.len > 0) {
        try md.print(allocator, "\n### Ingest data quality by sensor type\n\n", .{});
        try md.print(allocator, "Readings rejected at ingest (ingest_system.shouldAccept) for being outside the " ++
            "sensor type's physical bounds — real gateway behavior for a physically-impossible value, not a " ++
            "backend-specific difference (identical across every backend, since rejection happens once per " ++
            "reading before any backend ever sees it).\n\n", .{});
        try md.print(allocator, "| Sensor type | Generated | Rejected | Rejection rate |\n|---|---:|---:|---:|\n", .{});
        for (type_quality) |tq| {
            const rate: f64 = if (tq.generated > 0)
                @as(f64, @floatFromInt(tq.rejected)) / @as(f64, @floatFromInt(tq.generated)) * 100.0
            else
                0.0;
            try md.print(allocator, "| {s} | {d} | {d} | {d:.3}% |\n", .{
                @tagName(tq.sensor_type), tq.generated, tq.rejected, rate,
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
    type_quality: []const sim_mod.TypeQuality,
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
    try json.print(allocator, "  ],\n", .{});

    // type_quality
    try json.print(allocator, "  \"type_quality\": [\n", .{});
    for (type_quality, 0..) |tq, i| {
        try json.print(allocator, "    {{\n", .{});
        try json.print(allocator, "      \"sensor_type\": \"{s}\",\n", .{@tagName(tq.sensor_type)});
        try json.print(allocator, "      \"generated\": {d},\n", .{tq.generated});
        try json.print(allocator, "      \"rejected\": {d}\n", .{tq.rejected});
        try json.print(allocator, "    }}{s}\n", .{if (i + 1 < type_quality.len) "," else ""});
    }
    try json.print(allocator, "  ]\n", .{});
    try json.print(allocator, "}}\n", .{});

    try dir.writeFile(io, .{ .sub_path = "simulation.json", .data = json.items });
}

test "scaleMicros: stays microseconds below 1000, switches to ms then s at each threshold" {
    const under = scaleMicros(43.2);
    try std.testing.expectApproxEqAbs(@as(f64, 43.2), under.value, 0.001);
    try std.testing.expectEqualStrings("µs", under.unit);

    const ms = scaleMicros(7437.7);
    try std.testing.expectApproxEqAbs(@as(f64, 7.4377), ms.value, 0.0001);
    try std.testing.expectEqualStrings("ms", ms.unit);

    const s = scaleMicros(582859.8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5828598), s.value, 0.0000001);
    try std.testing.expectEqualStrings("s", s.unit);

    // Boundary: exactly 1000µs is the first value that becomes ms, not µs.
    const boundary = scaleMicros(1000.0);
    try std.testing.expectEqualStrings("ms", boundary.unit);

    // Boundary: 100_000µs (100ms) is the ms/s threshold — corrected mid-implementation
    // from an originally-drafted 1_000_000; pin it against future drift.
    const just_under_s = scaleMicros(99_999.0);
    try std.testing.expectEqualStrings("ms", just_under_s.unit);

    const at_s = scaleMicros(100_000.0);
    try std.testing.expectEqualStrings("s", at_s.unit);
}

// This test exercises writeWinners directly (rather than through the full
// `zig build bench` -> runner.run -> writeReports path, covered end-to-end
// by runner.zig's own test) so it can pin the exact legacy "N.N" plain-µs
// Markdown format (scaled_units = false) writeReports depends on — any
// future change to writeScaledUs or this function's formatting can't
// silently drift the regression-suite output.
test "writeWinners: scaled_units=false reproduces the exact legacy plain-µs format" {
    const allocator = std.testing.allocator;
    const stats = struct {
        fn make(median_ns: i64) metrics.LatencyStats {
            return .{
                .iterations = 1,
                .median_ns = median_ns,
                .p95_ns = median_ns,
                .p99_ns = median_ns,
                .min_ns = median_ns,
                .max_ns = median_ns,
                .mean_ns = median_ns,
                .total_ns = median_ns,
            };
        }
    }.make;

    const rows = [_]RunRow{
        .{ .scale = "S", .query = "Q1", .backend = "A", .memory_bytes = 0, .stats = stats(1000) },
        .{ .scale = "S", .query = "Q1", .backend = "B", .memory_bytes = 0, .stats = stats(3000) },
        .{ .scale = "S", .query = "Q2", .backend = "C", .memory_bytes = 0, .stats = stats(500) },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try writeWinners(&buf, allocator, &rows, "S", null, false);

    try std.testing.expectEqualStrings(
        "| Q1 | **A** | 1.0 | B | 3.0 | 3.00× |\n" ++
            "| Q2 | **C** | 0.5 | — | — | — |\n",
        buf.items,
    );
}

test "uniqueBackends: dedups while preserving first-seen order, independent of scale" {
    const allocator = std.testing.allocator;
    const zero_stats: metrics.LatencyStats = .{
        .iterations = 0,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = 0,
    };
    const rows = [_]RunRow{
        .{ .scale = "S", .query = "Q1", .backend = "TimeSeries", .memory_bytes = 0, .stats = zero_stats },
        .{ .scale = "S", .query = "Q1", .backend = "Lake", .memory_bytes = 0, .stats = zero_stats },
        .{ .scale = "M", .query = "Q1", .backend = "TimeSeries", .memory_bytes = 0, .stats = zero_stats },
        .{ .scale = "S", .query = "Q2", .backend = "Columnar", .memory_bytes = 0, .stats = zero_stats },
    };

    const names = try uniqueBackends(allocator, &rows);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("TimeSeries", names[0]);
    try std.testing.expectEqualStrings("Lake", names[1]);
    try std.testing.expectEqualStrings("Columnar", names[2]);
}

test "colorForBackend: assigns a real color by position past the old 4-entry palette boundary" {
    // 5 backends — one more than the hardcoded 4-entry array this replaces
    // used to support; the 5th (Lake) always fell back to the "unknown" gray.
    const backends = [_][]const u8{ "TimeSeries", "Columnar", "Hierarchical", "RingBuffer", "Lake" };

    const lake_color = colorForBackend(&backends, "Lake");
    try std.testing.expect(!std.mem.eql(u8, lake_color, "#999"));
    try std.testing.expectEqualStrings(BACKEND_COLOR_PALETTE[4 % BACKEND_COLOR_PALETTE.len], lake_color);

    try std.testing.expectEqualStrings("#999", colorForBackend(&backends, "Unknown"));
}

test "pickTrackWinners: picks the backend that wins the most queries in each family, independently" {
    const allocator = std.testing.allocator;
    const one_result = struct {
        fn make(backend: []const u8) [1]QueryBackendResult {
            return .{.{ .backend = backend, .median_ns = 1, .p95_ns = 1, .p99_ns = 1, .cost_per_query = 0 }};
        }
    }.make;

    // Real-time: RingBuffer wins 2 of 3. Historical: Hierarchical wins 2 of
    // 3, TimeSeries 1 of 3 — the two tracks must resolve independently, not
    // share a single overall winner.
    var rt1 = one_result("RingBuffer");
    var rt2 = one_result("RingBuffer");
    var rt3 = one_result("Lake");
    var h1 = one_result("Hierarchical");
    var h2 = one_result("Hierarchical");
    var h3 = one_result("TimeSeries");
    const rankings = [_]QueryRanking{
        .{ .query_name = "query_latest_single", .results = &rt1, .family = .real_time },
        .{ .query_name = "query_latest_zone", .results = &rt2, .family = .real_time },
        .{ .query_name = "query_latest_by_type", .results = &rt3, .family = .real_time },
        .{ .query_name = "query_avg_window", .results = &h1, .family = .aggregation },
        .{ .query_name = "query_daily_zone_rollup", .results = &h2, .family = .historical },
        .{ .query_name = "query_hourly_rollup", .results = &h3, .family = .historical },
    };

    const tw = try pickTrackWinners(allocator, &rankings);
    try std.testing.expectEqualStrings("RingBuffer", tw.realtime_winner);
    try std.testing.expectEqual(@as(usize, 2), tw.realtime_wins);
    try std.testing.expectEqual(@as(usize, 3), tw.realtime_total);
    try std.testing.expectEqualStrings("Hierarchical", tw.historical_winner);
    try std.testing.expectEqual(@as(usize, 2), tw.historical_wins);
    try std.testing.expectEqual(@as(usize, 3), tw.historical_total);
}

test "pickTrackWinners: a family with zero eligible-result rankings reports \"none\", not a crash" {
    const allocator = std.testing.allocator;
    var only_result = [_]QueryBackendResult{.{ .backend = "Hierarchical", .median_ns = 1, .p95_ns = 1, .p99_ns = 1, .cost_per_query = 0 }};
    const rankings = [_]QueryRanking{
        .{ .query_name = "query_hourly_rollup", .results = &only_result, .family = .historical },
    };

    const tw = try pickTrackWinners(allocator, &rankings);
    try std.testing.expectEqualStrings("none", tw.realtime_winner);
    try std.testing.expectEqual(@as(usize, 0), tw.realtime_wins);
    try std.testing.expectEqual(@as(usize, 0), tw.realtime_total);
    try std.testing.expectEqualStrings("Hierarchical", tw.historical_winner);
}

// ---------------------------------------------------------------------------
// Self-contained HTML dashboard for one per-building `dt --bim` run —
// mirrors recommendation.md's section order (verdict first, then supporting
// detail, heaviest tables collapsed behind <details>). Hand-rolled HTML/CSS
// with one small inline vanilla-JS block (per-query dashboard sorting +
// family filtering — same self-contained-inline-script pattern as
// writeHtmlReport's scale tabs): no external requests, no charting library —
// same hand-rolled-static-asset spirit as schematic.zig's SVG output.
// Distinct from writeHtmlReport above (the zig build bench regression-suite
// dashboard); this function is never called from writeReports.
// ---------------------------------------------------------------------------

pub fn writeBuildingHtmlReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    bim_path: []const u8,
    scale_label: []const u8,
    sensor_type_counts: []const SensorTypeCount,
    track_winners: TrackWinners,
    type_track_winners: []const TypeTrackWinners,
    rows: []const RunRow,
    query_rankings: []const QueryRanking,
    growth: []const sim_mod.GrowthPoint,
    sim_stats: []const sim_mod.SimStats,
    cost_rows: []const CostRow,
    naive_cost: f64,
    optimised_cost: f64,
) !void {
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);

    // scale_label/bim_path are vendor-controlled (an IFC filename stem) —
    // escape once, reuse everywhere below, so a name containing &, <, >,
    // etc. can't break this generated HTML's structure.
    const escaped_scale_label = try escapeXml(allocator, scale_label);
    defer allocator.free(escaped_scale_label);
    const escaped_bim_path = try escapeXml(allocator, bim_path);
    defer allocator.free(escaped_bim_path);

    try html.print(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n", .{});
    try html.print(allocator, "<meta charset=\"UTF-8\" />\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />\n", .{});
    try html.print(allocator, "<title>{s} — Storage Recommendation</title>\n", .{escaped_scale_label});
    try html.print(allocator, "<style>\n", .{});
    try html.print(allocator, "  :root {{ --bg:#0f1419; --panel:#161c24; --panel-2:#1d2530; --border:#2a3441; --text:#e6edf3; --text-dim:#8b97a6; --accent:#4ea8de; --green:#4ade80; --gold:#f0b429; }}\n", .{});
    try html.print(allocator, "  * {{ box-sizing:border-box; margin:0; padding:0; }}\n", .{});
    try html.print(allocator, "  body {{ font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; background:var(--bg); color:var(--text); line-height:1.55; padding:32px 20px 80px; }}\n", .{});
    try html.print(allocator, "  .container {{ max-width:960px; margin:0 auto; }}\n", .{});
    try html.print(allocator, "  h1 {{ font-size:26px; font-weight:700; }}\n  h2 {{ font-size:18px; margin:28px 0 10px; }}\n", .{});
    try html.print(allocator, "  .subtitle {{ color:var(--text-dim); margin-top:6px; font-size:13px; word-break:break-all; }}\n", .{});
    try html.print(allocator, "  .verdict {{ background:var(--panel); border:1px solid var(--border); border-left:4px solid var(--accent); border-radius:8px; padding:20px 24px; margin:20px 0; }}\n", .{});
    try html.print(allocator, "  .verdict p {{ margin-top:8px; }}\n  .verdict strong.win {{ color:var(--green); }}\n", .{});
    try html.print(allocator, "  .caveat {{ color:var(--gold); }}\n", .{});
    try html.print(allocator, "  table {{ width:100%; border-collapse:collapse; font-size:13px; background:var(--panel); border:1px solid var(--border); border-radius:8px; overflow:hidden; }}\n", .{});
    try html.print(allocator, "  th, td {{ padding:8px 12px; text-align:left; border-bottom:1px solid var(--border); }}\n", .{});
    try html.print(allocator, "  th {{ background:var(--panel-2); color:var(--text-dim); font-weight:500; font-size:11px; text-transform:uppercase; }}\n", .{});
    try html.print(allocator, "  .bar-track {{ background:var(--panel-2); height:16px; border-radius:4px; overflow:hidden; min-width:120px; }}\n", .{});
    try html.print(allocator, "  .bar-fill {{ height:100%; background:var(--accent); }}\n", .{});
    try html.print(allocator, "  .bar-fill.winner {{ background:var(--green); }}\n", .{});
    try html.print(allocator, "  details {{ background:var(--panel); border:1px solid var(--border); border-radius:8px; padding:12px 16px; margin:16px 0; }}\n", .{});
    try html.print(allocator, "  summary {{ cursor:pointer; font-weight:600; padding:4px 0; }}\n", .{});
    try html.print(allocator, "  .scroll {{ overflow-x:auto; }}\n", .{});
    try html.print(allocator, "  .chips {{ margin:10px 0; display:flex; gap:8px; flex-wrap:wrap; }}\n", .{});
    try html.print(allocator, "  .chip {{ background:var(--panel-2); border:1px solid var(--border); color:var(--text-dim); border-radius:14px; padding:3px 12px; font-size:12px; cursor:pointer; }}\n", .{});
    try html.print(allocator, "  .chip.active {{ background:var(--accent); color:var(--bg); border-color:var(--accent); }}\n", .{});
    try html.print(allocator, "  th.sortable {{ cursor:pointer; user-select:none; }}\n", .{});
    try html.print(allocator, "  th.sortable:hover {{ color:var(--text); }}\n", .{});
    try html.print(allocator, "  th.sorted-asc::after {{ content:' \\25B4'; }}\n  th.sorted-desc::after {{ content:' \\25BE'; }}\n", .{});
    try html.print(allocator, "  footer {{ margin-top:40px; color:var(--text-dim); font-size:12px; text-align:center; }}\n", .{});
    try html.print(allocator, "</style>\n</head>\n<body>\n<div class=\"container\">\n", .{});

    try html.print(allocator, "<h1>{s}</h1>\n", .{escaped_scale_label});
    try html.print(allocator, "<div class=\"subtitle\">Source: {s}</div>\n", .{escaped_bim_path});

    try html.print(allocator, "<div class=\"verdict\">\n", .{});
    try html.print(allocator, "<p>Use <strong class=\"win\">{s}</strong> for live/latest-value queries — wins {d} of {d} real-time queries.</p>\n", .{
        track_winners.realtime_winner, track_winners.realtime_wins, track_winners.realtime_total,
    });
    try html.print(allocator, "<p>Use <strong class=\"win\">{s}</strong> for everything else (history, aggregates, anomalies) — wins {d} of {d} historical queries.</p>\n", .{
        track_winners.historical_winner, track_winners.historical_wins, track_winners.historical_total,
    });
    try html.print(allocator, "<p style=\"color:var(--text-dim);font-size:13px\">Each winner is whichever backend won the most queries in its family, from the per-query dashboard below — not a blended score.</p>\n", .{});
    try html.print(allocator, "</div>\n", .{});

    try html.print(allocator, "<h2>Sensors placed, by type</h2>\n<div class=\"scroll\"><table>\n", .{});
    try html.print(allocator, "<tr><th>Sensor type</th><th>Count</th><th>Retention</th></tr>\n", .{});
    for (sensor_type_counts) |stc| {
        try html.print(allocator, "<tr><td>{s}</td><td>{d}</td><td>{d} days</td></tr>\n", .{ stc.name, stc.count, stc.retention_days });
    }
    try html.print(allocator, "</table></div>\n", .{});

    if (query_rankings.len > 0) {
        const sorted_rankings = try sortedRankings(allocator, query_rankings);
        defer allocator.free(sorted_rankings);

        try html.print(allocator, "<h2>Per-query dashboard</h2>\n", .{});
        try html.print(allocator, "<p style=\"color:var(--text-dim);font-size:13px;margin-bottom:4px\">The fastest eligible backend for every query this building runs — the ground truth the verdict above is counted from. " ++
            "Non-real-time queries only admit full-retention backends. " ++
            "Cost/M is the winner's total annual cost amortized per million queries. " ++
            "Click a column header to sort; click a chip to filter by family.</p>\n", .{});
        try html.print(allocator, "<div class=\"chips\" id=\"pq-chips\"><span class=\"chip active\" data-family=\"all\">all</span>", .{});
        // One chip per family that actually appears (sorted_rankings is
        // family-ordered, so a family's rows are contiguous).
        var last_family: ?queries.QueryFamily = null;
        for (sorted_rankings) |qr| {
            if (last_family == qr.family) continue;
            last_family = qr.family;
            try html.print(allocator, "<span class=\"chip\" data-family=\"{s}\">{s}</span>", .{ familyLabel(qr.family), familyLabel(qr.family) });
        }
        try html.print(allocator, "</div>\n", .{});

        try html.print(allocator, "<div class=\"scroll\"><table id=\"pq-table\">\n<thead><tr>", .{});
        try html.print(allocator, "<th class=\"sortable\" data-col=\"0\">Family</th><th class=\"sortable\" data-col=\"1\">Query</th><th class=\"sortable\" data-col=\"2\">Winner</th>" ++
            "<th class=\"sortable\" data-col=\"3\" data-num=\"1\">Latency</th><th>Runner-up</th>" ++
            "<th class=\"sortable\" data-col=\"5\" data-num=\"1\">Speedup</th><th class=\"sortable\" data-col=\"6\" data-num=\"1\">Cost/M queries</th>", .{});
        try html.print(allocator, "</tr></thead>\n<tbody>\n", .{});
        for (sorted_rankings) |qr| {
            if (qr.results.len == 0) continue;
            const winner = qr.results[0];
            const winner_us = @as(f64, @floatFromInt(winner.median_ns)) / 1000.0;
            const cost_per_m = winner.cost_per_query * 1_000_000.0;
            try html.print(allocator, "<tr data-family=\"{s}\"><td>{s}</td><td>{s}</td><td><strong style=\"color:var(--green)\">{s}</strong></td>", .{
                familyLabel(qr.family), familyLabel(qr.family), qr.query_name, winner.backend,
            });
            try html.print(allocator, "<td data-v=\"{d}\">", .{winner.median_ns});
            try writeScaledUs(&html, allocator, winner_us, true);
            try html.print(allocator, "</td>", .{});
            if (qr.results.len > 1) {
                const runner = qr.results[1];
                const speedup = if (winner.median_ns > 0)
                    @as(f64, @floatFromInt(runner.median_ns)) / @as(f64, @floatFromInt(winner.median_ns))
                else
                    0.0;
                try html.print(allocator, "<td>{s}</td><td data-v=\"{d:.4}\">{d:.2}×</td>", .{ runner.backend, speedup, speedup });
            } else {
                try html.print(allocator, "<td>—</td><td data-v=\"0\">—</td>", .{});
            }
            try html.print(allocator, "<td data-v=\"{d:.6}\">${d:.4}</td></tr>\n", .{ cost_per_m, cost_per_m });
        }
        try html.print(allocator, "</tbody></table></div>\n", .{});
    }

    if (type_track_winners.len > 0) {
        try html.print(allocator, "<h2>Recommendation by sensor type</h2>\n", .{});
        try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Sensor type</th><th>Live</th><th>Historical</th></tr>\n", .{});
        for (type_track_winners) |ttw| {
            try html.print(allocator, "<tr><td>{s}</td><td>", .{@tagName(ttw.sensor_type)});
            if (ttw.winners.realtime_total > 0) {
                try html.print(allocator, "{s} ({d}/{d})", .{ ttw.winners.realtime_winner, ttw.winners.realtime_wins, ttw.winners.realtime_total });
            } else {
                try html.print(allocator, "—", .{});
            }
            try html.print(allocator, "</td><td>", .{});
            if (ttw.winners.historical_total > 0) {
                try html.print(allocator, "{s} ({d}/{d})", .{ ttw.winners.historical_winner, ttw.winners.historical_wins, ttw.winners.historical_total });
            } else {
                try html.print(allocator, "—", .{});
            }
            try html.print(allocator, "</td></tr>\n", .{});
        }
        try html.print(allocator, "</table></div>\n", .{});
    }

    try html.print(allocator, "<details>\n<summary>Per-query latency detail</summary>\n", .{});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Query</th><th>Backend</th><th>Median</th><th>p95</th><th>Memory (KB)</th></tr>\n", .{});
    for (rows) |r| {
        try html.print(allocator, "<tr><td>{s}</td><td>{s}</td><td>", .{ r.query, r.backend });
        try writeScaledUs(&html, allocator, @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0, true);
        try html.print(allocator, "</td><td>", .{});
        try writeScaledUs(&html, allocator, @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0, true);
        try html.print(allocator, "</td><td>{d:.1}</td></tr>\n", .{@as(f64, @floatFromInt(r.memory_bytes)) / 1024.0});
    }
    try html.print(allocator, "</table></div>\n</details>\n", .{});

    try html.print(allocator, "<h2>Cost estimate (cloud-equivalent)</h2>\n", .{});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Backend</th><th>Storage (GB)</th><th>Storage $/yr</th><th>Query $/yr</th><th>Total $/yr</th></tr>\n", .{});
    for (cost_rows) |c| {
        try html.print(allocator, "<tr><td>{s}</td><td>{d:.1}</td><td>${d:.0}</td><td>${d:.0}</td><td><strong>${d:.0}</strong></td></tr>\n", .{
            c.backend, c.storage_gb, c.storage_cost_year, c.query_cost_year, c.total_cost_year,
        });
    }
    try html.print(allocator, "</table></div>\n", .{});
    const savings = naive_cost - optimised_cost;
    const savings_pct: f64 = if (naive_cost > 0) (savings / naive_cost) * 100.0 else 0.0;
    try html.print(allocator, "<p style=\"margin-top:10px\">Naive (all backends): <strong>${d:.0}/yr</strong> vs Optimised: <strong class=\"win\">${d:.0}/yr</strong> — savings of ${d:.0}/yr ({d:.0}%).</p>\n", .{
        naive_cost, optimised_cost, savings, savings_pct,
    });

    try html.print(allocator, "<details>\n<summary>Growth curve detail (latency at every checkpoint from day 1 to steady state)</summary>\n", .{});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Checkpoint</th><th>Day</th><th>Backend</th><th>Query</th><th>Median</th><th>Live readings</th><th>Memory (MB)</th></tr>\n", .{});
    for (growth) |g| {
        try html.print(allocator, "<tr><td>{s}</td><td>{d}</td><td>{s}</td><td>{s}</td><td>", .{ g.label, g.sim_day, g.backend, g.query });
        try writeScaledUs(&html, allocator, @as(f64, @floatFromInt(g.median_ns)) / 1000.0, true);
        try html.print(allocator, "</td><td>{d}</td><td>{d:.1}</td></tr>\n", .{
            g.reading_count, @as(f64, @floatFromInt(g.memory_bytes)) / (1024.0 * 1024.0),
        });
    }
    try html.print(allocator, "</table></div>\n</details>\n", .{});

    try html.print(allocator, "<details>\n<summary>Simulation summary (compression, eviction, and data-quality stats)</summary>\n", .{});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Backend</th><th>Sim days</th><th>Wall time (s)</th><th>Compression</th><th>Generated</th><th>Evicted</th></tr>\n", .{});
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    for (sim_stats) |s| {
        const sim_days = @divTrunc(s.sim_ms, day_ms);
        const wall_s = @as(f64, @floatFromInt(s.wall_ns)) / 1e9;
        try html.print(allocator, "<tr><td>{s}</td><td>{d}</td><td>{d:.1}</td><td>{d:.0}×</td><td>{d}</td><td>{d}</td></tr>\n", .{
            s.backend, sim_days, wall_s, s.compressionRatio(), s.generated, s.evicted,
        });
    }
    try html.print(allocator, "</table></div>\n</details>\n", .{});

    try html.print(allocator, "<footer>Digital Twin recommendation for {s} · relative rankings are reliable, absolute numbers are approximate (CLAUDE.md §6)</footer>\n", .{escaped_scale_label});
    try html.print(allocator, "</div>\n", .{});

    // Per-query dashboard interactivity: column sorting + family-chip
    // filtering. Self-contained vanilla JS, no external requests — same
    // inline-script pattern as writeHtmlReport's scale tabs. Numeric columns
    // sort on each cell's data-v attribute (raw ns / ratio / $) so display
    // formatting (unit scaling, × suffix) never affects ordering.
    try html.print(allocator, "<script>\n", .{});
    try html.print(allocator, "(function() {{\n", .{});
    try html.print(allocator, "  const table = document.getElementById('pq-table');\n", .{});
    try html.print(allocator, "  if (!table) return;\n", .{});
    try html.print(allocator, "  const tbody = table.querySelector('tbody');\n", .{});
    try html.print(allocator, "  table.querySelectorAll('th.sortable').forEach(th => {{\n", .{});
    try html.print(allocator, "    th.addEventListener('click', () => {{\n", .{});
    try html.print(allocator, "      const col = parseInt(th.getAttribute('data-col'), 10);\n", .{});
    try html.print(allocator, "      const numeric = th.hasAttribute('data-num');\n", .{});
    try html.print(allocator, "      const asc = !th.classList.contains('sorted-asc');\n", .{});
    try html.print(allocator, "      table.querySelectorAll('th').forEach(h => h.classList.remove('sorted-asc', 'sorted-desc'));\n", .{});
    try html.print(allocator, "      th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');\n", .{});
    try html.print(allocator, "      const key = tr => {{\n", .{});
    try html.print(allocator, "        const cell = tr.children[col];\n", .{});
    try html.print(allocator, "        return numeric ? parseFloat(cell.getAttribute('data-v') || '0') : cell.textContent.trim();\n", .{});
    try html.print(allocator, "      }};\n", .{});
    try html.print(allocator, "      Array.from(tbody.rows)\n", .{});
    try html.print(allocator, "        .sort((a, b) => {{\n", .{});
    try html.print(allocator, "          const ka = key(a), kb = key(b);\n", .{});
    try html.print(allocator, "          const cmp = numeric ? ka - kb : String(ka).localeCompare(String(kb));\n", .{});
    try html.print(allocator, "          return asc ? cmp : -cmp;\n", .{});
    try html.print(allocator, "        }})\n", .{});
    try html.print(allocator, "        .forEach(tr => tbody.appendChild(tr));\n", .{});
    try html.print(allocator, "    }});\n", .{});
    try html.print(allocator, "  }});\n", .{});
    try html.print(allocator, "  document.querySelectorAll('#pq-chips .chip').forEach(chip => {{\n", .{});
    try html.print(allocator, "    chip.addEventListener('click', () => {{\n", .{});
    try html.print(allocator, "      document.querySelectorAll('#pq-chips .chip').forEach(c => c.classList.remove('active'));\n", .{});
    try html.print(allocator, "      chip.classList.add('active');\n", .{});
    try html.print(allocator, "      const fam = chip.getAttribute('data-family');\n", .{});
    try html.print(allocator, "      Array.from(tbody.rows).forEach(tr => {{\n", .{});
    try html.print(allocator, "        tr.style.display = (fam === 'all' || tr.getAttribute('data-family') === fam) ? '' : 'none';\n", .{});
    try html.print(allocator, "      }});\n", .{});
    try html.print(allocator, "    }});\n", .{});
    try html.print(allocator, "  }});\n", .{});
    try html.print(allocator, "}})();\n", .{});
    try html.print(allocator, "</script>\n</body>\n</html>\n", .{});

    try dir.writeFile(io, .{ .sub_path = "recommendation.html", .data = html.items });
}

