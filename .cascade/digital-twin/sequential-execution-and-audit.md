# Sequential Backend Execution + Full-Scale Audit

> Agreed and implemented 2026-07-05. **Status: implemented, verified at
> hospital scale.** Extends (does not replace) `live-simulation-plan.md`;
> supersedes only its "one backend at a time / interleaved" execution
> detail.

## Problem

The live day-zero simulation's interleaved design (one shared day loop
feeding all 5 backends simultaneously) fixed the 5x-redundant generation
but kept every backend's full multi-year history resident in RAM at once:
~4 full-retention copies ≈ 12-14GB at hospital scale (1520 sensors,
7.3 simulated years) — more than a 16GB machine holds. Every
hospital-scale run died around the year-1/year-2 checkpoints.

## Solution: sequential passes + on-disk replay cache

Backends run one at a time, each through the FULL 2682-day timeline, so
peak memory is ONE backend's history plus one day's chunk (~3.5-4GB
baseline, ~7GB transient at the final checkpoint) — while generation
still happens exactly once:

1. **Backend 1 (TimeSeries)** consumes the live `synthetic.Stream`. Each
   day's post-validation (accepted) readings are simultaneously spilled
   to `<out-dir>/replay-cache.tmp` — length-prefixed frames: 16-byte
   header (u64 raw generated count, u64 accepted count) + raw
   `SensorReading` structs via `sliceAsBytes` (same-process ABI, never
   persisted beyond the run).
2. **Backends 2-5** replay that file day-by-day (`ReplayCursor`,
   positional reads). Byte-identical input by construction.
3. Each backend's `World` is created, simulated through all 13
   checkpoints, measured, and **freed** before the next backend starts.
4. `main.zig` deletes the replay file after the simulation (warning, not
   error, on failure).

The replay file is a **generation cache**, not a storage backend: every
backend still ingests into RAM and is queried in RAM; file I/O happens
between timed sections, never inside `metrics.timeQuery`/`timeMutation`
(CLAUDE.md §6 untouched). `SimStats.wall_ns` remains ingest_ns+prune_ns —
the symmetric per-backend figure (the generating pass would otherwise
carry generation+spill cost the replaying passes don't).

Key components: `ReplayWriter` / `ReplayCursor` / `DaySource` (tagged
union: generate-and-spill vs replay) in `benchmark/simulation.zig`;
`REPLAY_FILE_NAME` exported for main.zig's cleanup.

## First-ever full hospital-scale completion (2026-07-05)

`LargeHospitalComplex.ifc`: 1520 sensors, 9 types, 2682 simulated days,
**839,416,595 readings generated once**, replayed to 4 more backends —
**completed in 34.4 min** on a 16GB machine (previously: never finished).

- Replay integrity: all 5 backends byte-identical on generated /
  ingested / evicted (839,416,595 / 839,357,687 / 687,087,762) and on
  every checkpoint's live count.
- Per-pass wall: TimeSeries 479s (carries generation), Columnar 334s,
  Hierarchical 885s (per-leaf insert overhead), RingBuffer 29s, Lake
  ~fast. Memory never exceeded ~7GB (final-checkpoint World-cache
  transient; ~4GB baseline).
- Verdict for this hospital: **Hierarchical (live) + Hierarchical
  (historical)** — historical score 1.03 vs TimeSeries 1533. Per-query
  winners honestly differentiated: Hierarchical 8/10 (per-sensor probes
  by 218-5874x, zone rollup by 261x), **Lake wins query_anomalies**
  (1.03x over Columnar — the Parquet-style cold scan's designed niche),
  TimeSeries takes latest_single. Contrast the AC20-FZK-Haus house run
  (winners spread Hierarchical 6 / Columnar 3 / TimeSeries 1): different
  building, different answer — the tool's core premise, now demonstrated
  with real measurements at both scales.

## Final audit (2026-07-05) — results + backends + queries

**Clean:** growth curves structurally coherent (rollup grows until its
365-day window fills then plateaus ~2.1s; anomalies constant post-week-1
per its fixed 7-day window; latest_* flat O(1); TimeSeries avg_window
constant because it scans a constant ~2 day-partitions regardless of
total size). Live-count dips between checkpoints are the 10% prune-slack
oscillation, by design. Lake's smallest storage footprint (1.0GB vs
Columnar 1.4GB) is legitimate — it models S3+Parquet (delta+varint
timestamps, dictionary sensor-IDs, sensor_type elided into the partition
key, decode-on-scan, nothing decompressed resident).

**Real finding — fixed 2026-07-06:** `query_spatial_radius` ran against
fake geometry — `queries.sensorPosition(sensor_id)` derived positions
from id arithmetic (x = id%10*5m corridor grid), NOT the real
`ZoneLocation.position` parsed from the IFC. Fixed the same shape as the
old zone/floor arithmetic: positions are now registered topology.
`World.registerPosition`/`positionOf` (world.zig) hold a sensor_id ->
position map at the World level — NOT a new StorageBackend method,
because no backend models a spatial index (a radius query is a full
sensor scan + distance check on every backend alike, and in a real
deployment positions live in an asset/metadata registry beside the
historian, not inside the time-series engine). The live sim registers
real parsed `ZoneLocation.position`; `dataset.zig`'s fixture registers
the old corridor-grid formula as its own synthetic convention (the one
sanctioned home for fixture topology). Sensors with no registered
position never match — mirrors a registry with a missing entry. Q9
latency rose from ~1.5µs to ~2.5-4.7µs on the house run (hashmap lookups
replacing free arithmetic — honest, uniform across backends). New test
in queries.zig covers boundary-inclusive membership and the
missing-position case.

**Cosmetic — fixed 2026-07-06:**
- RingBuffer's SimStats showed "0 evicted" — pruneOlderThan is a real no-op
  for it (per storage_backend.zig, no fixed-capacity backend needs prune to
  evict), so real eviction — the ring overwrite inside `insert` — never
  showed up. Adding an eviction-count method would violate CLAUDE.md 3.2's
  "no backend-specific public surface," so `SimStats.evicted` is now derived
  generically at run end as `ingested - world.count()` for every backend
  (works for prune-based eviction too, computed once instead of accumulated
  per-prune-delta). Verified on the house run: RingBuffer now reports
  23,351,280 evicted (of 23,351,670 ingested, 390 resident) instead of 0.
- Stale comment in queries.zig's spatial section ("Q9 calls only
  world.iterateAll()") corrected to allSensorIds(), matching the actual
  query-layer rewrite.
- Columnar's memoryUsed() doc comment now discloses that the raw
  sensor_ids/timestamps/values columns stay fully resident and are what
  rangeByTime/iterateAll actually scan — the reported figure is a
  storage-cost proxy (what a real column store would persist), not this
  benchmark's actual RAM, which is closer to TimeSeries's. Left the
  measurement itself unchanged (changing it would alter recommendations
  based on a redefinition, not a bug fix) — this was a documentation gap,
  not an incorrect number for its stated purpose.

**Still stale:**
- `backend-audit.md`'s Lake entry still says "flat, unindexed,
  uncompressed" — the backend was upgraded to the Parquet model (see its
  own dated addendum section, already added).

## Also fixed earlier the same day (commit 2bc372f, branch
## live-sim-benchmark-overhaul)

streamUntil min-heap (O(log n)/tick); ReleaseFast forced for dt/dtb;
deriveQueryMix deduped by query pattern; query_anomalies one-fetch +
group-by (daily_zone_rollup deliberately kept per-member — the one-fetch
form was tried and measured 8x worse; sensor scope, not window width,
decides the realistic plan); Hierarchical mergeAllLeaves heap merge
(43.5s -> 0.7s); per-query winner table with full-retention eligibility
(RingBuffer can't fake-win historical queries); ingest_system.zig
(out-of-bounds rejection at ingest, failure injection enabled, per-type
data-quality report); curated test suite rebuilt from scratch.

## Step 4 implemented (2026-07-06): per-type generation horizon capping

Each sensor type now stops generating at its OWN
`simDaysForRetention(retention_days)` horizon instead of ticking for the
whole building's longest-retention span. `Stream.capHorizons`
(generator.zig) takes caller-supplied per-type day counts (0 = no cap)
and sets a `horizon_end` on each SensorState; `nextChunk`/`streamUntil`
never tick a sensor past it. The longest placed type's horizon equals
`total_days`, so it is never actually capped.

Correctness hinges on two facts, both verified:
1. **Every benchmark query anchors its window to the data's own newest
   reading** (getLatestBySensor / newest-among-members), never to
   absolute sim-now — so a frozen type's steady-state window measures
   identically at any later checkpoint.
2. **The prune watermark freezes with the horizon**
   (`watermark = min(elapsed, horizon)` in simulation.zig's prune loop,
   type skipped once the freeze-watermark prune has run) — otherwise
   sim-time-advancing cutoffs would evict a frozen type's ENTIRE dataset
   and late checkpoints would measure empty backends.

House-run verification: every frozen type holds exactly its full
steady-state window at day 2682 (temperature/humidity/co2/air_quality =
800,352 readings = 397d x 288/day x 7 sensors, precisely; occupancy
6,085 in its 90d window; structural uncapped at 1.47M). Generated
dropped 23.35M -> 5.0M (4.7x), byte-identical across all 5 backends;
wall time 29s -> 7.9s (~4x). Same deployment combo (Hierarchical +
Hierarchical), rankings unchanged. Determinism: capping is per-sensor
(private PRNGs), so pre-horizon output is byte-identical to an uncapped
run — covered by two new generator tests.

**Disclosed side effect (calibration interaction, decision open):**
temperature's `drift_rate_ppm = 1.6` was calibrated so drift crosses
physical bounds only near day ~2682 — but a capped temperature sensor
now stops aging at day ~417, so drift never crosses and ingest
rejections went from ~2k to 0 (the data-quality table reads 0.000%
everywhere). The sim no longer models a 7-year-old short-retention
sensor at all. Options: accept (that data would never be queried
anyway), or recalibrate each type's drift to manifest within its own
horizon. Not silently changed — surfaced for a decision.

## Hospital-scale rerun with Step 4 (2026-07-06)

`LargeHospitalComplex.ifc`, full run: **8.0 min** (was 34.4 min, 4.3x).
162,902,753 readings generated once (was 839.4M, 5.2x less), replayed to
4 backends — every backend byte-identical on generated/ingested/evicted
and on every checkpoint's live count. Per-pass wall: TimeSeries 180s
(was 479), Columnar 110s (was 334), Hierarchical 50s (was 885 — heap
merge + smaller dataset compounding), RingBuffer 7.6s (was 29), Lake
129s. Memory ~3.7GB baseline, ~7.5GB transient at steady-state
checkpoints. Prune calls 938 -> 24 (frozen types stop pruning, by
design). The capping is visible in the log: 311k readings/day at day
400 -> 23k at day 500 (the 397-day types froze) -> 11.5k from day ~770
(structural only).

Verdict unchanged: **Hierarchical (live) + Hierarchical (historical)**,
same as pre-Step-4 — the capping did not distort the recommendation.
Winner-table deltas are all in coin-flip territory: spatial_radius and
anomalies now go to Columnar over Lake at 1.00-1.04x (spatial's cost is
now dominated by uniform real-position lookups — the point of the fix;
anomalies was already a 1.03x near-tie in Lake's favor last run).
RingBuffer's evicted stat reads 162,887,553 (= ingested − 15,200 live)
— the eviction fix confirmed at scale.

## Still open

- Final-checkpoint World-cache transient (~2x dataset footprint from
  readingsForType's cached_all + type_index) — optimization candidate,
  not a blocker.
- Drift-vs-horizon calibration decision (see Step 4 side effect above).
