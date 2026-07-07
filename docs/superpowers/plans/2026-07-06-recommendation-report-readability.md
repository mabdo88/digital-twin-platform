# Recommendation Report Readability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `dt --bim ...`'s `recommendation.md` readable (verdict-first, auto-scaled units, heavy tables collapsed) and add a mirrored, self-contained `recommendation.html` dashboard — without touching the `zig build bench` regression-suite path (`report.writeReports`/`writeHtmlReport`) or `simulation.json`'s shape.

**Architecture:** All new logic lives in `engine/benchmark/report.zig` (pure helpers + a new HTML writer) and `engine/main.zig` (assembly/ordering). `writeWinners` gains a `scaled_units: bool` parameter so both the regression suite (`false`, byte-identical output) and the per-building path (`true`) share one implementation. `writeGrowthSection` is building-path-only already, so it's changed unconditionally.

**Tech Stack:** Zig 0.16.0 (tested against 0.17.0-dev), no external dependencies, no JS in the new HTML output.

## Global Constraints

- Every step must leave the repo in a state where `zig build` succeeds.
- `zig build test` must pass after every task that touches tests.
- `report.writeReports` / `report.writeHtmlReport` (the regression-suite path) and `simulation.json`'s shape must be **byte-for-byte unaffected** by every task in this plan except where a task explicitly says otherwise (only Task 3 touches shared code, and only to add a bool parameter whose `false` value preserves current output exactly).
- No new global state, manager, or singleton (CLAUDE.md §3.1).
- Follow this repo's existing conventions exactly: `std.ArrayList(u8)` + `.print(allocator, fmt, args)` for building markdown/HTML text, `pub fn`/doc-comment style as seen in `report.zig`, `test "descriptive sentence" { ... }` blocks at the bottom of the file they test.
- Design reference: `docs/superpowers/specs/2026-07-06-recommendation-report-readability-design.md` (exact section order, the 15% noise-caveat threshold, and the `ScaledDuration` shape are already decided there — don't re-derive them).

---

### Task 1: `scaleMicros` / `writeScaledUs` helpers in `report.zig`

**Files:**
- Modify: `engine/benchmark/report.zig` (add near the top, after the `BackendScore`/`CompoundRecommendation` block, before `UNCOVERED_QUERY_PENALTY` — i.e. after line 78)
- Modify: `engine/benchmark_test.zig` (register `report.zig` so its tests actually run — it isn't imported by anything in the current test closure)
- Test: inline `test` blocks at the bottom of `engine/benchmark/report.zig`

**Interfaces:**
- Produces: `pub const ScaledDuration = struct { value: f64, unit: []const u8 }`, `pub fn scaleMicros(us: f64) ScaledDuration`, `pub fn writeScaledUs(w: *std.ArrayList(u8), allocator: std.mem.Allocator, us: f64, scaled: bool) !void` — used by Tasks 3, 4, 6, 7.

- [ ] **Step 1: Register `report.zig` in the test closure**

`engine/benchmark_test.zig` currently only imports `queries`, `runner`, `schematic`, `cost_model` — `report.zig` has zero test coverage today because nothing pulls it into the comptime closure `zig build test` walks. Edit the file to:

```zig
// Test entry point for the benchmark module family.
// Placed at engine/ level so queries.zig can import ../ecs/ without leaving
// the module path.

const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");
const schematic = @import("benchmark/schematic.zig");
const cost_model = @import("benchmark/cost_model.zig");
const report = @import("benchmark/report.zig");

comptime {
    _ = queries;
    _ = runner;
    _ = schematic;
    _ = cost_model;
    _ = report;
}
```

- [ ] **Step 2: Write the failing test**

Add at the bottom of `engine/benchmark/report.zig`:

```zig
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
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `scaleMicros` is not defined.

- [ ] **Step 4: Write the implementation**

Insert into `engine/benchmark/report.zig` right after the `CompoundRecommendation` struct (after line 78, before the `UNCOVERED_QUERY_PENALTY` comment block):

```zig
/// Auto-scaled human-readable duration — µs below 1000µs, ms below
/// 1_000_000µs, s otherwise. Used everywhere a raw query latency is
/// displayed; never applied to scores/coverage/ratios (those stay as
/// plain numbers). See docs/superpowers/specs/2026-07-06-recommendation-
/// report-readability-design.md.
pub const ScaledDuration = struct { value: f64, unit: []const u8 };

pub fn scaleMicros(us: f64) ScaledDuration {
    if (us < 1000.0) return .{ .value = us, .unit = "µs" };
    if (us < 1_000_000.0) return .{ .value = us / 1000.0, .unit = "ms" };
    return .{ .value = us / 1_000_000.0, .unit = "s" };
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add engine/benchmark/report.zig engine/benchmark_test.zig
git commit -m "Add scaleMicros/writeScaledUs unit auto-scaler to report.zig"
```

---

### Task 2: `isCloseRace` noise-caveat helper in `report.zig`

**Files:**
- Modify: `engine/benchmark/report.zig` (add right after `TrackRecommendation`/`CompoundRecommendation`, near where `scoreBackends`/`recommendCompound` are defined — after the `recommendCompound` function, i.e. after line 233)
- Test: inline `test` block at the bottom of `engine/benchmark/report.zig`

**Interfaces:**
- Consumes: `BackendScore` (Task-independent, already exists at `report.zig:42`).
- Produces: `pub const CLOSE_RACE_THRESHOLD: f64`, `pub fn isCloseRace(scores: []const BackendScore) bool` — used by Task 6 (markdown verdict) and Task 7 (HTML verdict).

- [ ] **Step 1: Write the failing test**

Add at the bottom of `engine/benchmark/report.zig`:

```zig
test "isCloseRace: within threshold is close, beyond it is not, fewer than 2 scores is never close" {
    const close = [_]BackendScore{
        .{ .backend = "A", .score = 1.000, .coverage = 1.0 },
        .{ .backend = "B", .score = 1.100, .coverage = 1.0 },
    };
    try std.testing.expect(isCloseRace(&close));

    const far = [_]BackendScore{
        .{ .backend = "A", .score = 1.000, .coverage = 1.0 },
        .{ .backend = "B", .score = 1.318, .coverage = 1.0 },
    };
    try std.testing.expect(!isCloseRace(&far));

    const single = [_]BackendScore{
        .{ .backend = "A", .score = 1.000, .coverage = 1.0 },
    };
    try std.testing.expect(!isCloseRace(&single));

    const empty = [_]BackendScore{};
    try std.testing.expect(!isCloseRace(&empty));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `isCloseRace` is not defined.

- [ ] **Step 3: Write the implementation**

Insert into `engine/benchmark/report.zig` right after `recommendCompound`'s closing brace (after line 233):

```zig
/// A track's top two backends count as a "close race" when within this
/// fraction of each other — a disclosed, deliberate policy constant (not
/// researched), same spirit as UNCOVERED_QUERY_PENALTY above. Motivated by
/// an observed case: three consecutive runs of the same 32-sensor office
/// building (identical seed, identical code) produced three different
/// real-time-track winners between two backends whose scores sat within
/// ~10% of each other on two of those three runs, while a >30x-margin
/// track never reordered across the same three runs.
pub const CLOSE_RACE_THRESHOLD: f64 = 0.15;

/// True when `scores` (sorted ascending — best first, the shape
/// TrackRecommendation.scores is already in) has a winner and runner-up
/// within CLOSE_RACE_THRESHOLD of each other. Fewer than 2 scores is never
/// a close race (nothing to compare against).
pub fn isCloseRace(scores: []const BackendScore) bool {
    if (scores.len < 2) return false;
    const winner = scores[0].score;
    const runner_up = scores[1].score;
    if (winner <= 0) return false;
    return (runner_up - winner) / winner <= CLOSE_RACE_THRESHOLD;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add engine/benchmark/report.zig
git commit -m "Add isCloseRace noise-caveat helper to report.zig"
```

---

### Task 3: `writeWinners` gains `scaled_units`, regression-suite output stays byte-identical

**Files:**
- Modify: `engine/benchmark/report.zig:578-645` (`writeWinners`) and `engine/benchmark/report.zig:298` (its call site inside `writeReports`)

**Interfaces:**
- Consumes: `writeScaledUs` (Task 1).
- Produces: `pub fn writeWinners(..., scaled_units: bool) !void` (signature gains a 6th parameter) — Task 6 will call this with `true`.

- [ ] **Step 1: Capture the current regression-suite output as a baseline**

Run: `zig build bench`
Then: `cp benchmark-results/latency.md /tmp/latency-before.md` (or, on Windows, `Copy-Item benchmark-results/latency.md $env:TEMP/latency-before.md`) — this file is the byte-for-byte baseline Step 5 diffs against.

- [ ] **Step 2: Change the signature and internal formatting**

In `engine/benchmark/report.zig`, replace:

```zig
pub fn writeWinners(
    w: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    historical_eligible: ?[]const []const u8,
) !void {
```

with:

```zig
pub fn writeWinners(
    w: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    historical_eligible: ?[]const []const u8,
    scaled_units: bool,
) !void {
```

Then replace the row-printing block near the end of the function:

```zig
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
```

with:

```zig
        if (best_idx) |bi| {
            const best = rows[bi];
            const best_us = @as(f64, @floatFromInt(best.stats.median_ns)) / 1000.0;

            try w.print(allocator, "| {s} | **{s}** | ", .{ r.query, best.backend });
            try writeScaledUs(w, allocator, best_us, scaled_units);

            if (second_idx) |si| {
                const second = rows[si];
                const second_us = @as(f64, @floatFromInt(second.stats.median_ns)) / 1000.0;
                const speedup = if (best.stats.median_ns > 0)
                    @as(f64, @floatFromInt(second.stats.median_ns)) /
                        @as(f64, @floatFromInt(best.stats.median_ns))
                else
                    0.0;
                try w.print(allocator, " | {s} | ", .{second.backend});
                try writeScaledUs(w, allocator, second_us, scaled_units);
                try w.print(allocator, " | {d:.2}× |\n", .{speedup});
            } else {
                try w.print(allocator, " | — | — | — |\n", .{});
            }
        }
```

- [ ] **Step 3: Fix the regression-suite call site to preserve exact output**

In `engine/benchmark/report.zig`, inside `writeReports` (around line 298), replace:

```zig
        try writeWinners(&md, allocator, rows, ds.name, null);
```

with:

```zig
        try writeWinners(&md, allocator, rows, ds.name, null, false);
```

- [ ] **Step 4: Build**

Run: `zig build`
Expected: succeeds (this also confirms no other caller of `writeWinners` was missed — a leftover 5-argument call site would be a compile error).

- [ ] **Step 5: Verify regression-suite output is unchanged**

Run: `zig build bench`
Then diff: `diff benchmark-results/latency.md /tmp/latency-before.md` (PowerShell: `Compare-Object (Get-Content benchmark-results/latency.md) (Get-Content $env:TEMP/latency-before.md)`)
Expected: no differences.

- [ ] **Step 6: Commit**

```bash
git add engine/benchmark/report.zig
git commit -m "Add scaled_units flag to writeWinners; regression-suite output unchanged"
```

---

### Task 4: `writeGrowthSection` uses auto-scaled units

**Files:**
- Modify: `engine/benchmark/report.zig:658-684` (`writeGrowthSection`)

**Interfaces:**
- Consumes: `writeScaledUs` (Task 1). This function is only called from `main.zig` (confirmed not shared with `writeReports`), so no dual-mode flag is needed — always scaled.

- [ ] **Step 1: Change the table header and row printing**

Replace:

```zig
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
```

with:

```zig
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
```

- [ ] **Step 2: Build**

Run: `zig build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add engine/benchmark/report.zig
git commit -m "Auto-scale growth-curve median latency units"
```

---

### Task 5: Move `TypeCompoundRecommendation` into `report.zig`; add `SensorTypeCount`/`CostRow`

**Files:**
- Modify: `engine/benchmark/report.zig` (add `sb` import + three new types)
- Modify: `engine/main.zig:289-297` (remove local type, use `report.TypeRecommendation` instead)

**Interfaces:**
- Produces: `pub const TypeRecommendation = struct { sensor_type: sb.SensorType, compound: CompoundRecommendation }`, `pub const SensorTypeCount = struct { name: []const u8, count: u32, retention_days: u32 }`, `pub const CostRow = struct { backend: []const u8, storage_gb: f64, storage_cost_year: f64, query_cost_year: f64, total_cost_year: f64 }` — all three consumed by Task 7's `writeBuildingHtmlReport`; `TypeRecommendation` also consumed by Task 6 (replaces `main.zig`'s local type everywhere it's used).

This is a mechanical, low-risk move — no behavior change, just relocating a type definition so both `main.zig` and the new HTML writer in `report.zig` can share it without a circular import (report.zig must not import `main.zig`).

- [ ] **Step 1: Add the import and three types to `report.zig`**

At the top of `engine/benchmark/report.zig`, after the existing imports (after line 11: `const queries = @import("queries.zig");`), add:

```zig
const sb = @import("../ecs/storage/storage_backend.zig");
```

Then, right after the `CompoundRecommendation` struct (after line 78, before whatever Task 2 inserted — if Task 2 already ran, insert these three types immediately before `CLOSE_RACE_THRESHOLD`; if Task 1 already ran, insert after `writeScaledUs`; order among these doesn't matter, just keep all four additions together in this general area):

```zig
/// One backend ranking scoped to a single sensor type — same shape as the
/// building-level CompoundRecommendation, filtered down to that type's own
/// type-scoped queries. Moved here (from main.zig) so both the markdown
/// assembly in main.zig and writeBuildingHtmlReport below can share one
/// definition.
pub const TypeRecommendation = struct {
    sensor_type: sb.SensorType,
    compound: CompoundRecommendation,
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
```

- [ ] **Step 2: Remove the local type from `main.zig` and update its one usage**

In `engine/main.zig`, replace:

```zig
/// One backend ranking scoped to a single sensor type — same shape as
/// the building-level `report.Recommendation`, just filtered down to that
/// type's own type-scoped queries (synthetic.profileFor(st).relevant_queries
/// filtered through filterTypeScoped).
const TypeCompoundRecommendation = struct {
    sensor_type: sb.SensorType,
    compound: report.CompoundRecommendation,
};
```

with nothing (delete these lines entirely).

Then find the one declaration site (search `TypeCompoundRecommendation` in `main.zig` — it should appear exactly once more, as a variable's type parameter):

```zig
    var type_recommendations: std.ArrayList(TypeCompoundRecommendation) = .empty;
```

replace with:

```zig
    var type_recommendations: std.ArrayList(report.TypeRecommendation) = .empty;
```

- [ ] **Step 3: Build**

Run: `zig build`
Expected: succeeds. If it fails with "unknown type TypeCompoundRecommendation", grep `main.zig` for any remaining reference you missed and repeat Step 2's replacement there too.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS (no test exercises this type directly, but confirms nothing else broke).

- [ ] **Step 5: Commit**

```bash
git add engine/benchmark/report.zig engine/main.zig
git commit -m "Move TypeCompoundRecommendation into report.zig as TypeRecommendation; add SensorTypeCount/CostRow"
```

---

### Task 6: Restructure `main.zig`'s `writeRecommendationReport` — verdict-first, collapsed detail, 2-decimal scores

**Files:**
- Modify: `engine/main.zig:519-697` (`writeRecommendationReport`)

**Interfaces:**
- Consumes: `report.isCloseRace` (Task 2), `report.writeScaledUs` (Task 1), `report.TypeRecommendation` (Task 5, already wired by Task 5's Step 2), `report.writeWinners(..., true)` (Task 3).
- Produces: no new public interface — this task only reorders/reformats existing markdown assembly. Task 8 will insert the HTML-writer call into this same function, after this task's changes land.

- [ ] **Step 1: Insert the Verdict section right after the header**

In `engine/main.zig`, find:

```zig
    try md.print(allocator, "# Digital Twin — Storage Recommendation\n\n", .{});
    try md.print(allocator, "- Source IFC: `{s}`\n", .{bim_path});
    try md.print(allocator, "- Run label: `{s}`\n", .{scale_label});
    try md.print(allocator, "- Elements: {d} | Zones: {d} | Equipment: {d} | Sensors placed: {d}\n\n", .{
        model.building_elements.len, model.zones.len, model.equipment.len, placement.sensors.len,
    });

    try md.print(allocator, "## Sensors placed, by type\n\n", .{});
```

and insert a new Verdict block between the header and the `## Sensors placed, by type` line:

```zig
    try md.print(allocator, "# Digital Twin — Storage Recommendation\n\n", .{});
    try md.print(allocator, "- Source IFC: `{s}`\n", .{bim_path});
    try md.print(allocator, "- Run label: `{s}`\n", .{scale_label});
    try md.print(allocator, "- Elements: {d} | Zones: {d} | Equipment: {d} | Sensors placed: {d}\n\n", .{
        model.building_elements.len, model.zones.len, model.equipment.len, placement.sensors.len,
    });

    try md.print(allocator, "## Verdict\n\n", .{});
    try md.print(allocator, "**Use `{s}` for live/latest-value queries.**\n\n", .{compound.realtime.winner});
    try md.print(allocator, "**Use `{s}` for everything else** (history, aggregates, anomalies).\n\n", .{compound.historical.winner});

    if (compound.historical.scores.len > 1) {
        try md.print(allocator, "`{s}` wins historical queries by **{d:.1}x** over the next-best backend " ++
            "(`{s}`) — a decisive, noise-proof margin.\n\n", .{
            compound.historical.winner,
            compound.historical.scores[1].score,
            compound.historical.scores[1].backend,
        });
    }

    if (compound.realtime.scores.len > 1) {
        if (report.isCloseRace(compound.realtime.scores)) {
            try md.print(allocator, "The live-query race is close: `{s}` vs `{s}` (within 15%) — treat this " ++
                "specific ranking as a near-tie, not a confident win; single-shot microsecond-scale timing is " ++
                "sensitive to run-to-run noise at this margin (CLAUDE.md §3.4).\n\n", .{
                compound.realtime.scores[0].backend,
                compound.realtime.scores[1].backend,
            });
        } else {
            try md.print(allocator, "`{s}` wins live queries by **{d:.1}x** over the next-best backend " ++
                "(`{s}`) — a clear margin.\n\n", .{
                compound.realtime.winner,
                compound.realtime.scores[1].score,
                compound.realtime.scores[1].backend,
            });
        }
    }

    try md.print(allocator, "## Sensors placed, by type\n\n", .{});
```

(Note: this duplicates the `## Sensors placed, by type` line — remove the original one immediately following in the file so it isn't printed twice. The net effect: Verdict section is inserted, `## Sensors placed, by type` line appears exactly once, now after the Verdict.)

- [ ] **Step 2: Change score decimals from 3 to 2**

The exact string `"| {s} | {d:.3} | {d:.0}% |\n"` appears 4 times in `writeRecommendationReport` (building-level real-time table, building-level historical table, per-type real-time table, per-type historical table). Replace all 4 occurrences with `"| {s} | {d:.2} | {d:.0}% |\n"` (use `replace_all` if using an editing tool — the surrounding `.print` calls are otherwise identical, only the format string changes).

- [ ] **Step 3: Wrap "Per-query latency" + "Per-query winner" in a collapsed `<details>` block, apply scaled units**

Replace:

```zig
    try md.print(allocator, "## Per-query latency (this building's actual query mix)\n\n", .{});
    try md.print(allocator, "| Query | Backend | Median µs | p95 µs | Memory (KB) |\n|---|---|---:|---:|---:|\n", .{});
    for (rows) |r| {
        try md.print(allocator, "| {s} | {s} | {d:.1} | {d:.1} | {d:.1} |\n", .{
            r.query,
            r.backend,
            @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0,
            @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0,
            @as(f64, @floatFromInt(r.memory_bytes)) / 1024.0,
        });
    }

    // Explicit per-query winner — the direct answer to "which backend for
    // this query behavior": for each query pattern this building actually
    // runs, the single fastest backend at steady state, not left for the
    // reader to eyeball out of the raw latency table above. Same grouping
    // logic the internal regression-suite report already uses
    // (report.writeReports), reused rather than reimplemented. Non-real-time
    // queries only admit full-retention backends — same eligibility rule the
    // compound recommendation applies, so a count-capped cache that scanned
    // 200x less data can't be presented as a "winner" (see writeWinners's
    // doc comment).
    try md.print(allocator, "\n### Per-query winner (lowest median)\n\n", .{});
    try md.print(allocator, "For queries outside the real-time family, only full-retention backends compete " ++
        "(same rule as the recommendation tracks above) — the real-time cache holds a fraction " ++
        "of the data those queries need, so its latency on them is not comparable.\n\n", .{});
    try md.print(allocator, "| Query | Winner | Median µs | Runner-up | Median µs | Speedup |\n", .{});
    try md.print(allocator, "|---|---|---:|---|---:|---:|\n", .{});
    try report.writeWinners(&md, allocator, rows, scale_label, &full_retention_names);

    try md.print(allocator, "\nSee `schematic.svg` in this directory for a floor-by-floor map of placed sensors.\n", .{});
```

with:

```zig
    try md.print(allocator, "<details>\n<summary><strong>Per-query latency detail</strong> (all backends × this building's actual query mix)</summary>\n\n", .{});
    try md.print(allocator, "## Per-query latency (this building's actual query mix)\n\n", .{});
    try md.print(allocator, "| Query | Backend | Median | p95 | Memory (KB) |\n|---|---|---:|---:|---:|\n", .{});
    for (rows) |r| {
        try md.print(allocator, "| {s} | {s} | ", .{ r.query, r.backend });
        try report.writeScaledUs(&md, allocator, @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0, true);
        try md.print(allocator, " | ", .{});
        try report.writeScaledUs(&md, allocator, @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0, true);
        try md.print(allocator, " | {d:.1} |\n", .{
            @as(f64, @floatFromInt(r.memory_bytes)) / 1024.0,
        });
    }

    // Explicit per-query winner — the direct answer to "which backend for
    // this query behavior": for each query pattern this building actually
    // runs, the single fastest backend at steady state, not left for the
    // reader to eyeball out of the raw latency table above. Same grouping
    // logic the internal regression-suite report already uses
    // (report.writeReports), reused rather than reimplemented. Non-real-time
    // queries only admit full-retention backends — same eligibility rule the
    // compound recommendation applies, so a count-capped cache that scanned
    // 200x less data can't be presented as a "winner" (see writeWinners's
    // doc comment).
    try md.print(allocator, "\n### Per-query winner (lowest median)\n\n", .{});
    try md.print(allocator, "For queries outside the real-time family, only full-retention backends compete " ++
        "(same rule as the recommendation tracks above) — the real-time cache holds a fraction " ++
        "of the data those queries need, so its latency on them is not comparable.\n\n", .{});
    try md.print(allocator, "| Query | Winner | Median | Runner-up | Median | Speedup |\n", .{});
    try md.print(allocator, "|---|---|---:|---|---:|---:|\n", .{});
    try report.writeWinners(&md, allocator, rows, scale_label, &full_retention_names, true);
    try md.print(allocator, "\n</details>\n\n", .{});

    try md.print(allocator, "See `schematic.svg` in this directory for a floor-by-floor map of placed sensors.\n\n", .{});
```

- [ ] **Step 4: Wrap the growth curve and simulation summary in collapsed `<details>` blocks**

Replace:

```zig
    try report.writeGrowthSection(&md, allocator, growth);
    try report.writeSimSection(&md, allocator, sim_stats, type_volumes, type_quality);
```

with:

```zig
    try md.print(allocator, "<details>\n<summary><strong>Growth curve detail</strong> (latency at every checkpoint from day 1 to steady state)</summary>\n\n", .{});
    try report.writeGrowthSection(&md, allocator, growth);
    try md.print(allocator, "\n</details>\n\n", .{});

    try md.print(allocator, "<details>\n<summary><strong>Simulation summary</strong> (compression, eviction, and data-quality stats)</summary>\n\n", .{});
    try report.writeSimSection(&md, allocator, sim_stats, type_volumes, type_quality);
    try md.print(allocator, "\n</details>\n\n", .{});
```

- [ ] **Step 5: Build**

Run: `zig build`
Expected: succeeds.

- [ ] **Step 6: Manual check**

Run: `./zig-out/bin/dt --bim "assets/IFC/HAC-New Office - Furniture_detached.ifc" --out benchmark-results-check`
Open `benchmark-results-check/recommendation.md` and confirm: Verdict appears right after the header (before "Sensors placed, by type"), scores show 2 decimals, the three `<details>` blocks are present and each contains its original table content, units in the per-query and growth tables are auto-scaled (e.g. a ~580000µs value now reads as a fraction-of-a-second value, not six digits of µs).

- [ ] **Step 7: Clean up the manual-check output and commit**

```bash
rm -rf benchmark-results-check
git add engine/main.zig
git commit -m "Restructure recommendation.md: verdict-first, collapsed detail, scaled units, 2-decimal scores"
```

---

### Task 7: `writeBuildingHtmlReport` — new self-contained HTML dashboard in `report.zig`

**Files:**
- Modify: `engine/benchmark/report.zig` (add three new functions at the end of the file: `writeBuildingHtmlReport`, `writeScoreTableHtml`, `writeWinnersHtml`)

**Interfaces:**
- Consumes: `BackendScore`, `CompoundRecommendation`, `TypeRecommendation`, `SensorTypeCount`, `CostRow` (Task 5), `writeScaledUs`/`scaleMicros` (Task 1), `isCloseRace` (Task 2), `RunRow`, `queryNameFromStr`, `backendEligible` (all pre-existing in this file), `sim_mod.GrowthPoint`/`sim_mod.SimStats` (pre-existing `const sim_mod = @import("simulation.zig");` alias in this file).
- Produces: `pub fn writeBuildingHtmlReport(allocator, io, dir, bim_path, scale_label, sensor_type_counts, compound, type_recommendations, rows, full_retention_names, growth, sim_stats, cost_rows, naive_cost, optimised_cost) !void` — writes `recommendation.html`. Consumed by Task 8.

This intentionally duplicates `writeWinners`' winner/runner-up selection logic into a second, HTML-flavored `writeWinnersHtml` rather than sharing print statements between Markdown-pipe output and HTML-tag output — the two renderings differ enough (`| a | b |` vs `<td>a</td><td>b</td>`) that a shared-callback abstraction would cost more than the ~30 duplicated lines it removes.

- [ ] **Step 1: Add the three functions at the end of `engine/benchmark/report.zig`**

```zig
// ---------------------------------------------------------------------------
// Self-contained HTML dashboard for one per-building `dt --bim` run —
// mirrors recommendation.md's section order (verdict first, then supporting
// detail, heaviest tables collapsed behind <details>). Plain HTML/CSS only:
// no JS, no external requests, no charting library — same hand-rolled-
// static-asset spirit as schematic.zig's SVG output. Distinct from
// writeHtmlReport above (the zig build bench regression-suite dashboard);
// this function is never called from writeReports.
// ---------------------------------------------------------------------------

pub fn writeBuildingHtmlReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    bim_path: []const u8,
    scale_label: []const u8,
    sensor_type_counts: []const SensorTypeCount,
    compound: CompoundRecommendation,
    type_recommendations: []const TypeRecommendation,
    rows: []const RunRow,
    full_retention_names: []const []const u8,
    growth: []const sim_mod.GrowthPoint,
    sim_stats: []const sim_mod.SimStats,
    cost_rows: []const CostRow,
    naive_cost: f64,
    optimised_cost: f64,
) !void {
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);

    try html.print(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n", .{});
    try html.print(allocator, "<meta charset=\"UTF-8\" />\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />\n", .{});
    try html.print(allocator, "<title>{s} — Storage Recommendation</title>\n", .{scale_label});
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
    try html.print(allocator, "  footer {{ margin-top:40px; color:var(--text-dim); font-size:12px; text-align:center; }}\n", .{});
    try html.print(allocator, "</style>\n</head>\n<body>\n<div class=\"container\">\n", .{});

    try html.print(allocator, "<h1>{s}</h1>\n", .{scale_label});
    try html.print(allocator, "<div class=\"subtitle\">Source: {s}</div>\n", .{bim_path});

    try html.print(allocator, "<div class=\"verdict\">\n", .{});
    try html.print(allocator, "<p>Use <strong class=\"win\">{s}</strong> for live/latest-value queries.</p>\n", .{compound.realtime.winner});
    try html.print(allocator, "<p>Use <strong class=\"win\">{s}</strong> for everything else (history, aggregates, anomalies).</p>\n", .{compound.historical.winner});
    if (compound.historical.scores.len > 1) {
        try html.print(allocator, "<p>{s} wins historical queries by <strong>{d:.1}x</strong> over {s} — a decisive, noise-proof margin.</p>\n", .{
            compound.historical.winner, compound.historical.scores[1].score, compound.historical.scores[1].backend,
        });
    }
    if (compound.realtime.scores.len > 1) {
        if (isCloseRace(compound.realtime.scores)) {
            try html.print(allocator, "<p class=\"caveat\">The live-query race is close: {s} vs {s} (within 15%) — treat this ranking as a near-tie, not a confident win.</p>\n", .{
                compound.realtime.scores[0].backend, compound.realtime.scores[1].backend,
            });
        } else {
            try html.print(allocator, "<p>{s} wins live queries by <strong>{d:.1}x</strong> over {s} — a clear margin.</p>\n", .{
                compound.realtime.winner, compound.realtime.scores[1].score, compound.realtime.scores[1].backend,
            });
        }
    }
    try html.print(allocator, "</div>\n", .{});

    try html.print(allocator, "<h2>Sensors placed, by type</h2>\n<div class=\"scroll\"><table>\n", .{});
    try html.print(allocator, "<tr><th>Sensor type</th><th>Count</th><th>Retention</th></tr>\n", .{});
    for (sensor_type_counts) |stc| {
        try html.print(allocator, "<tr><td>{s}</td><td>{d}</td><td>{d} days</td></tr>\n", .{ stc.name, stc.count, stc.retention_days });
    }
    try html.print(allocator, "</table></div>\n", .{});

    try html.print(allocator, "<h2>Recommendation detail</h2>\n", .{});
    try writeScoreTableHtml(&html, allocator, "Real-time track", compound.realtime.scores);
    try writeScoreTableHtml(&html, allocator, "Historical track", compound.historical.scores);

    if (type_recommendations.len > 0) {
        try html.print(allocator, "<h2>Recommendation by sensor type</h2>\n", .{});
        for (type_recommendations) |tr| {
            try html.print(allocator, "<h3 style=\"font-size:15px;margin:16px 0 6px\">{s}</h3>\n", .{@tagName(tr.sensor_type)});
            if (tr.compound.realtime.scores.len > 0) try writeScoreTableHtml(&html, allocator, "Real-time", tr.compound.realtime.scores);
            if (tr.compound.historical.scores.len > 0) try writeScoreTableHtml(&html, allocator, "Historical", tr.compound.historical.scores);
        }
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
    try html.print(allocator, "</table></div>\n", .{});
    try html.print(allocator, "<h3 style=\"font-size:14px;margin:16px 0 6px\">Per-query winner (lowest median)</h3>\n", .{});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Query</th><th>Winner</th><th>Median</th><th>Runner-up</th><th>Median</th><th>Speedup</th></tr>\n", .{});
    try writeWinnersHtml(&html, allocator, rows, scale_label, full_retention_names);
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

    try html.print(allocator, "<footer>Digital Twin recommendation for {s} · relative rankings are reliable, absolute numbers are approximate (CLAUDE.md §6)</footer>\n", .{scale_label});
    try html.print(allocator, "</div>\n</body>\n</html>\n", .{});

    try dir.writeFile(io, .{ .sub_path = "recommendation.html", .data = html.items });
}

/// One score table (with a proportional bar meter per row, winner
/// highlighted) for the HTML dashboard. `scores` must be sorted ascending
/// by score (best first) — the shape TrackRecommendation.scores is already
/// in. Bar width is `best_score / this_score` (winner = 100%, since lower
/// scores are better).
fn writeScoreTableHtml(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    title: []const u8,
    scores: []const BackendScore,
) !void {
    if (scores.len == 0) return;
    try html.print(allocator, "<h3 style=\"font-size:14px;margin:14px 0 6px\">{s}</h3>\n", .{title});
    try html.print(allocator, "<div class=\"scroll\"><table>\n<tr><th>Backend</th><th>Score</th><th>Coverage</th><th></th></tr>\n", .{});
    const best = scores[0].score;
    for (scores, 0..) |s, i| {
        const bar_pct: f64 = if (s.score > 0) @min((best / s.score) * 100.0, 100.0) else 0.0;
        const winner_class: []const u8 = if (i == 0) " winner" else "";
        try html.print(allocator, "<tr><td>{s}</td><td>{d:.2}</td><td>{d:.0}%</td><td><div class=\"bar-track\"><div class=\"bar-fill{s}\" style=\"width:{d:.1}%\"></div></div></td></tr>\n", .{
            s.backend, s.score, s.coverage * 100, winner_class, bar_pct,
        });
    }
    try html.print(allocator, "</table></div>\n", .{});
}

/// HTML-table equivalent of writeWinners above — same winner/runner-up
/// selection logic and eligibility rule, rendered as <tr> rows instead of
/// Markdown pipes (kept separate rather than shared: the two output
/// formats differ enough per-cell that a shared row-renderer callback
/// would cost more than the duplication it removes).
fn writeWinnersHtml(
    html: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    rows: []const RunRow,
    scale: []const u8,
    historical_eligible: ?[]const []const u8,
) !void {
    const rowEligible = struct {
        fn check(eligible: ?[]const []const u8, query_name: []const u8, backend: []const u8) bool {
            const list = eligible orelse return true;
            const q = queryNameFromStr(query_name) orelse return true;
            if (queries.familyOf(q) == .real_time) return true;
            return backendEligible(list, backend);
        }
    }.check;
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
            if (!rowEligible(historical_eligible, candidate.query, candidate.backend)) continue;
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
            try html.print(allocator, "<tr><td>{s}</td><td><strong>{s}</strong></td><td>", .{ r.query, best.backend });
            try writeScaledUs(html, allocator, best_us, true);
            try html.print(allocator, "</td>", .{});
            if (second_idx) |si| {
                const second = rows[si];
                const second_us = @as(f64, @floatFromInt(second.stats.median_ns)) / 1000.0;
                const speedup = if (best.stats.median_ns > 0)
                    @as(f64, @floatFromInt(second.stats.median_ns)) / @as(f64, @floatFromInt(best.stats.median_ns))
                else
                    0.0;
                try html.print(allocator, "<td>{s}</td><td>", .{second.backend});
                try writeScaledUs(html, allocator, second_us, true);
                try html.print(allocator, "</td><td>{d:.2}×</td></tr>\n", .{speedup});
            } else {
                try html.print(allocator, "<td>—</td><td>—</td><td>—</td></tr>\n", .{});
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `zig build`
Expected: succeeds. `writeBuildingHtmlReport` isn't called yet (Task 8 wires it), so this only checks the new code compiles standalone — if it doesn't get dead-code-stripped by the compiler and any unused-parameter or type error surfaces, fix it here before moving on.

- [ ] **Step 3: Commit**

```bash
git add engine/benchmark/report.zig
git commit -m "Add writeBuildingHtmlReport: self-contained HTML dashboard for per-building runs"
```

---

### Task 8: Wire `main.zig` to compute cost rows and call `writeBuildingHtmlReport`

**Files:**
- Modify: `engine/main.zig` (inside `writeRecommendationReport`, around the existing `cost_model.writeCostSection` call and the final `dir.writeFile`/console-message lines)

**Interfaces:**
- Consumes: `report.writeBuildingHtmlReport` (Task 7), `report.SensorTypeCount`/`report.CostRow` (Task 5), `cost_model.estimateAll`/`naiveTotalCost`/`optimisedCost` (pre-existing in `cost_model.zig`).

- [ ] **Step 1: Build the `sensor_type_counts` slice**

Find the existing sensor-count computation in `writeRecommendationReport`:

```zig
    try md.print(allocator, "| Sensor type | Count | Retention |\n|---|---:|---:|\n", .{});
    const counts = countSensorsByType(placement.sensors);
    const all_types = [_]sb.SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    for (all_types) |t| {
        const c = counts[@intFromEnum(t)];
        if (c > 0) try md.print(allocator, "| {s} | {d} | {d} days |\n", .{ @tagName(t), c, synthetic.profileFor(t).retention_days });
    }
```

Immediately after this block (still before `\n> Honesty headline...`), add:

```zig
    var sensor_type_counts: std.ArrayList(report.SensorTypeCount) = .empty;
    defer sensor_type_counts.deinit(allocator);
    for (all_types) |t| {
        const c = counts[@intFromEnum(t)];
        if (c > 0) try sensor_type_counts.append(allocator, .{
            .name = @tagName(t),
            .count = c,
            .retention_days = synthetic.profileFor(t).retention_days,
        });
    }
```

- [ ] **Step 2: Compute cost rows and totals alongside the existing cost section**

Find:

```zig
    const realtime_query_fraction = 0.7;
    try cost_model.writeCostSection(
        &md,
        allocator,
        rows,
        &all_backend_names,
        compound.realtime.winner,
        compound.historical.winner,
        realtime_query_fraction,
        cost_model.DEFAULT_WORKLOAD,
        cost_model.DEFAULT_PRICING,
    );
```

Replace with (adds the raw-data computation the HTML writer needs, right before the existing markdown-writing call):

```zig
    const realtime_query_fraction = 0.7;

    const cost_estimates = try cost_model.estimateAll(allocator, rows, &all_backend_names, cost_model.DEFAULT_WORKLOAD, cost_model.DEFAULT_PRICING);
    defer allocator.free(cost_estimates);
    var cost_rows: std.ArrayList(report.CostRow) = .empty;
    defer cost_rows.deinit(allocator);
    for (cost_estimates) |e| {
        try cost_rows.append(allocator, .{
            .backend = e.backend,
            .storage_gb = e.storage_tb * 1024.0,
            .storage_cost_year = e.storage_cost_year,
            .query_cost_year = e.query_cost_year,
            .total_cost_year = e.total_cost_year,
        });
    }
    const naive_cost = cost_model.naiveTotalCost(rows, &all_backend_names, cost_model.DEFAULT_WORKLOAD, cost_model.DEFAULT_PRICING);
    const optimised_cost = cost_model.optimisedCost(rows, compound.realtime.winner, compound.historical.winner, realtime_query_fraction, cost_model.DEFAULT_WORKLOAD, cost_model.DEFAULT_PRICING);

    try cost_model.writeCostSection(
        &md,
        allocator,
        rows,
        &all_backend_names,
        compound.realtime.winner,
        compound.historical.winner,
        realtime_query_fraction,
        cost_model.DEFAULT_WORKLOAD,
        cost_model.DEFAULT_PRICING,
    );
```

- [ ] **Step 3: Write the HTML report alongside the markdown**

Find:

```zig
    try dir.writeFile(io, .{ .sub_path = "recommendation.md", .data = md.items });
    try report.writeSimJson(allocator, io, &dir, sim_stats, growth, type_volumes, type_quality);
}
```

Replace with:

```zig
    try dir.writeFile(io, .{ .sub_path = "recommendation.md", .data = md.items });
    try report.writeBuildingHtmlReport(
        allocator,
        io,
        &dir,
        bim_path,
        scale_label,
        sensor_type_counts.items,
        compound,
        type_recommendations,
        rows,
        &full_retention_names,
        growth,
        sim_stats,
        cost_rows.items,
        naive_cost,
        optimised_cost,
    );
    try report.writeSimJson(allocator, io, &dir, sim_stats, growth, type_volumes, type_quality);
}
```

- [ ] **Step 4: Update the console message in `main()`**

Find (in `main()`, not `writeRecommendationReport`):

```zig
    std.debug.print("  Wrote recommendation.md + simulation.json to {s}/\n", .{args.output_dir});
```

Replace with:

```zig
    std.debug.print("  Wrote recommendation.md + recommendation.html + simulation.json to {s}/\n", .{args.output_dir});
```

- [ ] **Step 5: Build**

Run: `zig build`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add engine/main.zig
git commit -m "Wire writeBuildingHtmlReport into the per-building report-writing path"
```

---

### Task 9: End-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Full test suite**

Run: `zig build test`
Expected: PASS (all existing tests plus Task 1/2's new `scaleMicros`/`isCloseRace` tests).

- [ ] **Step 2: Run the per-building path against the office fixture**

Run: `./zig-out/bin/dt --bim "assets/IFC/HAC-New Office - Furniture_detached.ifc" --out benchmark-results-office`

Confirm in the console output: the final line now reads "Wrote recommendation.md + recommendation.html + simulation.json to benchmark-results-office/".

- [ ] **Step 3: Inspect `recommendation.md`**

Open `benchmark-results-office/recommendation.md` and confirm, in order: header, **Verdict** (deployment combo + margin reasoning + noise caveat if applicable), Sensors placed by type, Recommendation detail (2-decimal scores), Recommendation by sensor type, a collapsed `<details>` for per-query latency/winner, Cost estimate, a collapsed `<details>` for the growth curve, a collapsed `<details>` for the simulation summary. Confirm no latency value is printed as a 6-digit microsecond number — everything past 1000µs should show `ms` or `s`.

- [ ] **Step 4: Inspect `recommendation.html`**

Open `benchmark-results-office/recommendation.html` in a browser (or view the raw file to confirm it's well-formed: one `<!DOCTYPE html>`, one `<html>`...`</html>` pair, no unclosed `<details>`/`<table>` tags). Confirm the verdict card renders at the top, score tables show bar meters with the winner row visually distinct, and the three heavy sections start collapsed.

- [ ] **Step 5: Confirm the regression suite is untouched**

Run: `zig build bench`
Then diff against Task 3's baseline: `diff benchmark-results/latency.md /tmp/latency-before.md`
Expected: no differences. Also open `benchmark-results/benchmark.html` and confirm it still renders the original multi-scale tabbed layout (unchanged).

- [ ] **Step 6: Confirm `simulation.json`'s shape is unchanged**

Run: `git diff --stat` — `engine/benchmark/simulation.zig` should not appear in the diff (this plan never touches it), and `report.writeSimJson` (the function that writes `simulation.json`) should not appear in any task's diff either. Spot-check `benchmark-results-office/simulation.json` is valid JSON with any available JSON validator — expect no error.

- [ ] **Step 7: Clean up run artifacts**

```bash
rm -rf benchmark-results-office benchmark-results
```

(These are gitignored run outputs, not part of the commit — matches this session's earlier cleanup pass.)

- [ ] **Step 8: Final review**

Run: `git status`
Expected: clean working tree (everything already committed task-by-task in Tasks 1–8). If anything is still unstaged, review it with `git diff` before deciding whether to commit or discard.
