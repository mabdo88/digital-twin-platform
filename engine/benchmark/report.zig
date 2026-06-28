// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Report writers — Markdown (human-readable), JSON (machine-readable), and
// HTML (interactive dashboard). All three render the same RunRow data
// produced by runner.zig; adding a query or backend there requires no
// changes here.

const std = @import("std");
const metrics = @import("../ecs/systems/metrics_system.zig");
const fixtures = @import("dataset.zig");

/// One latency-table row, decoupled from how it's rendered.
pub const RunRow = struct {
    scale: []const u8,
    query: []const u8,
    backend: []const u8,
    memory_bytes: usize,
    stats: metrics.LatencyStats,
};

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
                try html.print(allocator, "        <div style=\"color:var(--text-dim);font-family:monospace;font-size:11px;text-align:right\">{s}</div>\n", .{ if (is_winner) "★ winner" else "" });
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
