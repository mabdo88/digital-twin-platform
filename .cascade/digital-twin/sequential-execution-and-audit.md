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

**Real finding, NOT yet fixed:** `query_spatial_radius` runs against
fake geometry — `queries.sensorPosition(sensor_id)` derives positions
from id arithmetic (x = id%10*5m corridor grid), NOT the real
`ZoneLocation.position` parsed from the IFC (already available in
`placement.locations`). Relative backend rankings remain meaningful
(same fake positions for all backends), but the query answers nothing
about the real building. Same class of defect as the old `sensor_id/5`
zone arithmetic already fixed for zones/floors; the fix is the same
shape (wire real positions through). The code's own comment discloses
this.

**Cosmetic, NOT yet fixed:**
- RingBuffer's SimStats shows "0 evicted in 938 prunes" — its real
  eviction (ring overwrites, ~839M) is invisible; only pruneOlderThan
  removals are counted and those are always no-ops for a 10-slot buffer
  of fresh readings.
- Stale comment in queries.zig's spatial section: "Q9 calls only
  world.iterateAll()" — it uses allSensorIds() since the query-layer
  rewrite.
- `backend-audit.md`'s Lake entry still says "flat, unindexed,
  uncompressed" — the backend was upgraded to the Parquet model.
- Columnar's memoryUsed() excludes its resident raw timestamp array
  (disclosed tradeoff) — fine as a storage-cost proxy, but its actual
  RAM is closer to TimeSeries's.

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

## Still open

- Step 4 of the perf plan: cap each sensor type's generation horizon at
  its own retention+margin (wall-clock optimization for the multi-year
  tail; data-driven per profileFor, not a type branch).
- Wire query_spatial_radius to real ZoneLocation.position (finding
  above).
- Final-checkpoint World-cache transient (~2x dataset footprint from
  readingsForType's cached_all + type_index) — optimization candidate,
  not a blocker.
