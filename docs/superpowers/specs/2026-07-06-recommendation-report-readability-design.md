# Recommendation report readability — design

## Problem

`dt --bim ... --out <dir>` writes `recommendation.md` (plus `simulation.json` and
`schematic.svg`). The markdown is hard to decipher:

- The actual answer (deployment combo) is buried around line 50, after sensor
  counts and before a wall of supporting tables.
- Scores are printed to 3 decimals; latency values are raw microseconds even
  when that means numbers like `582859.8` or `724152.8`.
- The "Latency vs Building Age (Growth Curve)" table has one row per
  (checkpoint × backend × query) — ~280 rows for a small 32-sensor office
  building, and grows with every additional sensor type or backend.
- There's no HTML view of a per-building run — `zig build bench`'s regression
  suite gets `benchmark.html`, but `dt --bim` does not (this was a deliberate
  scope boundary per CLAUDE.md's "Report format" open decision, being revised
  here for this specific path only).

## Scope

Per-building path only: `engine/main.zig`'s `writeRecommendationReport` and new/
existing functions in `engine/benchmark/report.zig`.

**Explicitly out of scope:** `report.writeReports` / `report.writeHtmlReport`
(the `zig build bench` regression-suite path). Confirmed
`writeGrowthSection`/`writeSimSection` are only called from `main.zig`, not
from `writeReports` — this work is fully isolated from the regression suite's
`latency.md`/`latency.json`/`benchmark.html`.

`simulation.json`'s machine-readable shape is unchanged — this is purely a
human-readable-output concern.

## `recommendation.md` restructuring

New section order:

1. **Header** — building, sensor counts (unchanged).
2. **Verdict** (new) — plain-language deployment combo ("Use X for live
   queries, Y for everything else"), a one-line reason drawn from the actual
   score gap (e.g. "Y wins historical queries by Nx — a decisive margin"),
   and a caveat line when the real-time track's top two scores are within a
   noise-sensitive margin (see "Noise caveat" below).
3. **Sensors placed, by type** — unchanged (small table).
4. **Recommendation detail** — the existing real-time/historical score
   tables, reformatted: scores to 2 decimals, coverage as whole-percent
   (already is).
5. **Recommendation by sensor type** — same content, wording already
   tightened this session (placed-count vs scored-count fix).
6. **`<details>` Per-query latency + per-query winner** — same tables as
   today, wrapped in a collapsed `<details><summary>` block, values passed
   through the new unit auto-scaler.
7. **Cost estimate** — unchanged (already short).
8. **`<details>` Growth curve** — same full per-checkpoint data as today
   (no row reduction — every checkpoint × backend × query row is kept),
   wrapped in a collapsed `<details>` block.
9. **`<details>` Simulation summary** — compression/eviction/data-quality
   tables, wrapped in a collapsed `<details>` block.

### Noise caveat rule

If the real-time track's winner and runner-up scores are within a fixed
15% relative difference (a deliberate, disclosed policy constant, same spirit
as `UNCOVERED_QUERY_PENALTY` — not a researched value), the verdict
prints a caveat: "`<winner>` and `<runner-up>` are within noise of each other
on this run — the live-query race is close; treat as a near-tie." This is
motivated by the empirical finding this session: three consecutive runs of
the same 32-sensor office building (identical seed, identical code) produced
three different real-time-track orderings between RingBuffer and
Hierarchical, while the historical track's much larger margin (30–100×) held
stable across all three runs. The historical track is not given this
treatment because its margins in every observed case are an order of
magnitude larger than plausible timing noise.

### Unit auto-scaling

New helper in `report.zig`, used by every markdown/HTML writer that prints a
latency value:

```zig
const ScaledDuration = struct { value: f64, unit: []const u8 };
fn scaleMicros(us: f64) ScaledDuration
```

Rules: `< 1000µs` stays `µs` (1 decimal); `< 100_000µs` (100ms) becomes `ms`
(2 decimals); otherwise `s` (2 decimals) — corrected during Task 1's
implementation from an initial `1_000_000µs` draft, which contradicted this
doc's own worked example (`582859.8µs → 0.58s`, which needs the cutover
below 1 second to actually reach the `s` branch). Scores/coverage are not
passed through this — only raw latency values.

## HTML dashboard (new)

New function `writeBuildingHtmlReport` in `report.zig`, called from
`writeRecommendationReport` alongside the existing `writeFile` for
`recommendation.md`, writing `recommendation.html` into the same output
directory.

- Mirrors the same 9-section order as the markdown, including the verdict
  card at the top.
- Same `<details>` collapse convention as the markdown for the three heavy
  sections (per-query latency, growth curve, simulation summary) — one
  mental model across both formats.
- Score tables (real-time/historical, building-level and per-type) get a
  proportional CSS width bar next to each score, in addition to the numeric
  value — plain HTML/CSS only, no JS, no charting library. Consistent with
  this codebase's existing hand-rolled-static-asset approach
  (`benchmark/schematic.zig`'s SVG generation).
- Self-contained single file (inline `<style>`, no external requests) —
  matches the "headless, no external dependencies" spirit of the whole
  platform even though this is a browser-viewed artifact, not the tool
  itself.

## Testing / definition of done

- `zig build` and `zig build test` pass.
- Manually run `dt --bim` against at least one placed-multi-type building
  (the office fixture used this session) and visually confirm: verdict
  appears first, collapsed sections start collapsed, units are scaled
  sensibly, HTML renders without errors in a browser.
- No change to `simulation.json`'s shape — spot-check it's still valid JSON
  with the same keys as before.
- Regression suite (`zig build bench`) output (`latency.md`, `latency.json`,
  `benchmark.html`) must be byte-for-byte unaffected, since none of its
  writer functions are touched.
