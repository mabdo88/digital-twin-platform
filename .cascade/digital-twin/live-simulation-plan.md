# Live Day-Zero Simulation Plan

> Agreed 2026-07-02. **Status: implemented.**
> Supersedes the bulk-preload + live-tail methodology from `storage-redesign-plan.md`.
>
> **Partially superseded in turn (2026-07-05/06)** by
> `sequential-execution-and-audit.md`: backends no longer share one
> interleaved day loop — they run sequentially over an on-disk replay cache
> (one backend's history in RAM at a time), and each sensor type's
> generation is capped at its own retention-derived horizon
> (`Stream.capHorizons`). The checkpoint/growth-curve/eviction methodology
> below is unchanged; only the execution order and generation extent are.

## Problem

The previous methodology generated all sensor data upfront in a single
`generate()` call (retention-driven history) plus a short "live tail"
(second `generate()` call), then bulk-ingested everything into each backend
before running queries. This had three problems:

1. **No growth curve.** Queries were measured only at one point in the
   building's lifecycle — after all data was loaded. There was no way to
   see how latency changes as the building accumulates data from day 1
   to steady state.

2. **No eviction observation.** Pruning/eviction happened implicitly during
   ingest (RingBuffer's capacity eviction) or not at all (full-retention
   backends never pruned). The benchmark couldn't measure the cost of
   active retention management.

3. **Unrealistic ingest pattern.** Real buildings start empty and accumulate
   data over time. Bulk-ingesting 2 years of readings in one shot doesn't
   reflect how a storage backend behaves under real operational load.

## Solution: Live Day-Zero Simulation

The building starts at **simulated day zero** with empty backends. A
`synthetic.Stream` generates readings **chunk-by-chunk** (1 simulated day
per chunk), ingesting each day's readings into every backend before
advancing to the next day. At log-spaced **checkpoints** (day 1, 7, 30,
90, ...), the simulation pauses to:

1. **Prune** data older than each sensor type's retention window.
2. **Benchmark** all queries in the building's mix via `metrics.timeQuery`.
3. **Record** a `GrowthPoint` (latency + memory + reading count) for the
   growth curve.
4. **Validate** cross-backend result consistency via `QueryDigest`.

### Key components

| Component | Location | Purpose |
|---|---|---|
| `SensorState` + `tickOnce` | `synthetic/generator.zig` | Per-sensor PRNG + stateful tick generation |
| `Stream` | `synthetic/generator.zig` | Manages all sensors' states, generates chunks |
| `deriveSimDays` | `benchmark/simulation.zig` | Total sim days = max retention + margin |
| `deriveCheckpoints` | `benchmark/simulation.zig` | Log-spaced checkpoint schedule |
| `PrunePolicy` | `benchmark/simulation.zig` | 10% slack prune interval, min 1 chunk |
| `QueryDigest` | `benchmark/simulation.zig` | Cross-backend result fingerprint |
| `simulateBackend` | `benchmark/simulation.zig` | Per-backend sim loop (stream → ingest → prune → query) |
| `timeMutation` | `ecs/systems/metrics_system.zig` | Single-shot timing for non-idempotent ops |
| `writeGrowthSection` | `benchmark/report.zig` | Growth curve table in `recommendation.md` |
| `writeSimSection` | `benchmark/report.zig` | Sim summary (compression, eviction) in `recommendation.md` |
| `writeSimJson` | `benchmark/report.zig` | Machine-readable `simulation.json` |

### Constants

- `SIM_START_MS = 1_700_000_000_000` (day zero, Unix epoch ms)
- `CHUNK_MS = 86_400_000` (1 simulated day)
- `PRUNE_SLACK = 0.10` (prune when data exceeds 110% of retention)
- Seed: `42` (fixed for determinism)

### Sim duration

`deriveSimDays(sensor_types)` = `max(retention_days(t) for t in types) +
max(30, retention_days * 0.05)` — the longest retention window plus a
proportional margin (minimum 30 days) so the simulation runs long enough
to observe steady-state eviction.

### Checkpoint schedule

`deriveCheckpoints(sim_days)` returns checkpoints at days 1, 7, 30, 90,
and `sim_days` (steady state). This log-spaced ladder covers the key
regimes: near-empty (day 1), first week, first month, first quarter, and
retention-full steady state.

### Pruning

`pruneIntervalMs(retention_ms)` = `max(CHUNK_MS, retention_ms * PRUNE_SLACK)`.
Pruning happens at most once per chunk (never finer than daily). For a
90-day retention, prune runs every 9 simulated days. `shouldPrune(now,
last_prune, retention)` gates the prune call.

### Growth curve

Each `GrowthPoint` records: checkpoint label, sim day, backend name,
query name, median latency (ns), memory (bytes), live bytes, and reading
count. The growth curve shows whether a backend's query latency is
constant (O(1) access) or grows with data volume — the key question for
long-running building operations.

### Cross-backend validation

`QueryDigest` folds query results into a compact fingerprint (count,
sensor_id sum, value sum). The first backend to run at a checkpoint
records its digest; subsequent backends validate against it. A mismatch
raises `error.CrossBackendMismatch`, failing the run immediately.

## What was removed

- `benchProfile` function in `main.zig` (bulk ingest + query)
- `SIMULATED_NOW_MS`, `LIVE_TAIL_MS`, `RINGBUFFER_CAP`, `ONE_HOUR_MS`
  constants from `main.zig`
- `runOne`, `queryName`, `isHistorical`, `isTypeScoped`, `hasQuery`,
  `filterTypeScoped` helper functions from `main.zig` (moved to
  `simulation.zig`)
- `ZoneFloor`, `SampleArgs`, `TypeSample` struct definitions from
  `main.zig` (moved to `simulation.zig`)
- `final_binary_state` hashmap + dual `generate()` calls in `main.zig`

## What was preserved

- `synthetic.generate()` — still used by the internal multi-scale
  regression suite (`runner.zig` / `dataset.zig`)
- Compound recommendations (`report.recommendCompound`)
- RingBuffer cap of 10 readings/sensor via `setRetentionHint`
- All 12 query patterns and their `q1_wrapper`..`q12_wrapper` adapters
- Cost model, schematic SVG output, per-type recommendations
