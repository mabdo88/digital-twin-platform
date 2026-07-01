# Storage/Benchmark Redesign Plan (agreed 2026-06-30)

> **Status: IN PROGRESS as of 2026-07-01.** Six of eleven implementation steps are
> done and verified (see "Implementation progress" below); the rest of this
> document is still the target, not yet built. Check `git log` and the current
> source before assuming any specific piece is done. Treat this as a status doc
> per CLAUDE.md §9 — read it before touching `synthetic/generator.zig`,
> `ecs/storage/*`, `benchmark/queries.zig`, or `main.zig`'s orchestration.

## Implementation progress (2026-07-01)

**Done, verified, tests passing:**

1. **Query recheck against real-scale assumptions** — all 12 query patterns in
   `benchmark/queries.zig` reviewed. Found and fixed two real bugs, both
   invisible at the old 1h toy-dataset scale and both would have been severe
   once real per-sensor-type volumes exist:
   - `query_latest_by_type` scanned the *entire world* (`iterateAll()`, every
     sensor type) instead of just the requested type, and deduped "have I seen
     this sensor" via a linear scan of the growing result list — O(readings ×
     distinct sensors) instead of O(readings). Fixed: now uses the existing
     `readingsForType` (type-scoped) plus a hash map.
   - `query_spatial_radius` and `query_zone_hierarchy` (depth≥2) both scanned
     every reading in the world to dedupe distinct sensor IDs, recomputing a
     sensor's (unchanging) position once per reading instead of once per
     sensor. Fixed: added a new cached `World.allSensorIds()` (same
     invalidate-on-insert pattern as the existing caches), so both queries are
     now O(distinct sensors) instead of O(total readings).
   - The other 9 query patterns were already correct (single-pass, properly
     scoped) and needed no changes.
2. **Real per-type eviction across every backend** — added
   `pruneOlderThan(sensor_type, cutoff_timestamp) !void` to the
   `StorageBackend` interface, implemented in all 6 backends (AoS, SoA,
   TimeSeries, Columnar, Hierarchical, RingBuffer). Each respects that
   backend's own invariants: TimeSeries/Columnar preserve sort order and
   correctly invalidate Columnar's delta-compressed timestamp column (deltas
   are relative to the previous row, so removing rows invalidates every delta
   after the first removed one — `ts_compressed` is reset to force a rebuild).
   RingBuffer needed a different approach: its circular buffer means physical
   slot order and logical (oldest-to-newest) order only coincide when there's
   been no wraparound, so a naive in-place sequential compaction (like the
   flat backends use) can silently overwrite an entry before it's read. It
   uses a small scratch allocation bounded by that one sensor's own capacity
   (not the whole dataset) to walk logical order safely — this is why the
   interface method is fallible (`!void`) rather than `void`, matching
   `insert`'s existing convention. `World(T)` invalidates every cache
   (cached_all, sensor_index, type_stats, type_index, all_sensor_ids) on
   prune exactly like it does on insert. 8 new regression tests (one or two
   per backend), including a RingBuffer wraparound case that specifically
   forces physical/logical order to diverge — all passing, full suite green.
3. **RingBuffer's per-type-configurable capacity** — added
   `setRetentionHint(sensor_type, max_readings) !void` to the `StorageBackend`
   interface. Non-RingBuffer backends implement it as a no-op (they have no
   fixed-capacity concept). RingBuffer stores per-type capacity hints in a
   hashmap, consulted only when allocating a NEW sensor's buffer (first
   insert for that sensor_id) — a hint set after some sensors of a type
   already exist doesn't resize them, by design (the caller sets every hint
   before ingestion begins). Also fixed a real correctness bug found while
   implementing this: `capacity_per_sensor` was a single backend-wide field
   used for wraparound math even on an *existing* sensor's buffer — once
   different types can have different capacities, that math must use each
   sensor's own `buffer.len`, not a shared constant. Fixed in `insert`,
   `memoryUsed`, and `pruneOlderThan`. 2 new regression tests.
4. **Lake backend** — the cheapest possible cold tier: a flat, unindexed,
   uncompressed array (`ecs/storage/backends/lake_storage.zig`), structurally
   similar to AoS/SoA but framed and registered as a real deployment
   candidate (unlike AoS/SoA, which stay reference-only baselines). Full
   `StorageBackend` interface, own unit tests, a golden-equivalence test
   against TimeSeries, and wired into `runner.zig`'s `backends` /
   `supported_backends` registries — the single registration point every
   test/table already reads from, so Lake was automatically picked up by the
   dynamic cross-backend equivalence tests in `runner.zig` with no further
   duplication needed. End-to-end smoke-tested: `dt.exe` against a real IFC
   file runs Lake alongside the other 4 deployment backends and reports it
   in the winner comparison.

5. **generator.zig split into continuous vs. event-storage models** —
   `generate()`'s per-shape switch now decides not just HOW to compute a
   value but WHETHER to store it. `binary_event` (occupancy) only appends a
   reading when the value differs from the last EMITTED value (an event
   log, not periodic polling) — the first tick always emits, since a real
   system reports its initial state at startup. `bursty_impulsive`
   (vibration) only appends when `sampleBurstyImpulsive` reports
   `is_event == true` — non-event (baseline) samples still run through the
   RNG for determinism but are discarded immediately, never stored. This
   is the exact design the user corrected earlier in this session
   ("occupancy is stored event based... vibration... we only store
   anomalies"), now implemented as an authorized, agreed step.
   `diurnal_continuous`/`stepwise_discrete` (temperature/humidity/co2/
   air_quality/flow/structural/energy) are unchanged — full periodic
   readings every tick, since that's genuinely how BMS/AMI historians
   report.
6. **Retention values updated per research** — co2/air_quality: 365 -> 1095
   days (3yr, WELL Building Standard's documented minimum — a real
   regulatory number, correcting the earlier unresearched guess). flow: 90
   -> 365 days (1yr, a disclosed pragmatic choice per the user: genuinely
   ambiguous whether a given flow sensor is billing-relevant, "not
   important now, just make it 1yr"). The doc comment above `profileFor`
   now explicitly labels which retention values are research-grounded
   (energy, structural, co2/air_quality) vs. reasoned operational defaults
   (temperature/humidity, flow, occupancy, vibration), so a future reader
   never mistakes a default for a citation.

**Verification (steps 5-6).** Three existing tests had premises inverted by
the storage-model change and were rewritten, not just patched: the old
"binary_event... state has dwell time" test asserted most CONSECUTIVE
STORED readings share a value — the opposite is now true by construction
(every stored reading is a transition), so it now asserts consecutive
stored readings always DIFFER, with dwell time proven instead via gaps
between transition timestamps exceeding one tick period. The old
"bursty_impulsive... most readings stay near baseline" test asserted most
stored readings are near baseline — now every stored reading must exceed
the burst floor (it's an event log), with sparsity proven by comparing
count against total ticks evaluated. The 100k-sensor scale test's exact
`readings.len == num_sensors` assertion no longer holds now that
vibration's per-tick storage is genuinely probabilistic (~2%) — relaxed to
`0 < readings.len <= num_sensors`, since the test's real purpose (scale
without blowing up) doesn't depend on an exact count. Full suite green
throughout. End-to-end smoke-tested against the equipment-heavy HASC IFC
file: 364 sensors -> 1053 readings (a fraction of the old per-type-uniform
volume), vibration correctly sparse, Lake winning for both energy and
vibration in that run's per-type recommendation.

**Not yet started:** per-sensor unique full-volume generation (no
sampling/sharing across sibling sensors), the live tick simulator, retiring
the 25-iteration methodology, and the main.zig rewire that ties all of this
together into the real pipeline. See "Explicitly NOT yet done" at the
bottom — unchanged except items 1-4 above are now done, not planned.

## Why this exists

The tool previously benchmarked storage backends against a flat 1-hour toy
dataset, uniform in shape across all 9 sensor types, then declared a single
"winner." That's fundamentally incompatible with CLAUDE.md's core principle —
"measured answers specific to the project," not guessed ones — because a
1-hour dataset represents nothing about a real building's actual retention
reality (90 days for temperature, 7 years for structural, etc.), and every
backend-recommendation assumption baked into the old design (RingBuffer wins
"live," Hierarchical wins "spatial") was asserted, never measured. See
`backend-audit.md`'s 2026-06-30 entry for the performance/sampling-bias fixes
that preceded this redesign; this document describes what comes after those.

## The agreed design

### Two data products per sensor

1. **Bulk history** — generated once per sensor, **not shared across sibling
   sensors of the same type** (each placed sensor gets its own independently
   generated dataset — same canonical per-type shape/frequency, independent
   noise). Spans exactly `[now - retention_days, now]` at that type's real
   cadence. No bounded/representative sampling: every placed sensor (e.g. all
   3,200+ temperature sensors in a hospital-scale building) gets real data,
   because sharing one dataset across siblings degenerates aggregation and
   anomaly queries (identical values → zero variance; anomalies fire on every
   sensor of a type simultaneously or never).
2. **Live simulator** — a tick-based loop, run after history is ingested,
   emitting new readings into every backend as if the building were operating
   "now." No real wall-clock sleeping — ticks advance simulated time
   instantly. Concrete time-compression factor is **still undecided**, to be
   picked once real post-retention volumes are finalized (target: a full run
   in the tens-of-seconds range).

### Per-type storage model (not one uniform frequency-driven model)

- **Continuous-storage types** (temperature, humidity, co2, air_quality,
  flow, energy, structural): full periodic readings at canonical frequency,
  retained for exactly `retention_days`.
- **Event-storage types**:
  - **occupancy** — a reading is written only on state transition
    (occupied↔vacant), never a periodic poll of a binary value. Transition
    rate derives from the existing hour-of-day `occupancyLikelihood` curve in
    `generator.zig`, not a flat guessed rate.
  - **vibration** — the raw high-rate stream is **never bulk-generated as
    history**. History = only the anomaly events that stream would have
    produced over the retention window; non-anomalous raw samples are
    generated transiently for detection and discarded immediately.

### Retention values (evidence status labeled honestly — do not silently upgrade a default to "researched")

| Type | Retention | Basis |
|---|---|---|
| co2 / air_quality | 3yr (1095d) | WELL Building Standard minimum (real) |
| energy | 3-5yr | AMI data-sharing norms (real) |
| structural | 7yr | SHM/strain-gauge service-life norms (real) |
| flow | 1yr | Pragmatic choice, not researched — ambiguous whether billing-relevant (3yr) or operational (90d) |
| temperature / humidity | 90d | No industry standard found — operational default |
| occupancy | ~90d-ish | No standard found; privacy literature favors short retention |
| vibration (anomaly log only) | 30d | No standard found; low-impact, log is sparse regardless |

### Real eviction across ALL backends — a genuine interface change

Today only RingBuffer evicts (count-based, hardcoded `capacity_per_sensor =
1000` for every sensor type regardless of frequency — itself a latent bug,
since 1000 readings is a wildly different time-span for temperature vs.
vibration). The redesign requires:

1. A new `StorageBackend` interface method (e.g. `pruneOlderThan(cutoff_ts)`)
   implemented uniformly by **every** backend — AoS, SoA, TimeSeries,
   Columnar, Hierarchical, RingBuffer, and the new Lake backend (below).
2. RingBuffer's `capacity_per_sensor` becomes per-type-configurable, sized
   from `retention_days × that type's reading rate`, not a global constant.

Explicit user rationale: "why wait 5 years in real time to figure out we
chose the wrong backend because eviction never happened" — deliberate,
disclosed redesign, not scope creep.

### No backend-eligibility assumptions — the core principle

Every backend receives every sensor type's full data (history + live,
evicted to the same retention window). Every one of the 12 query patterns
(`benchmark/queries.zig`) races against every backend; the empirically
fastest is reported, per query, per sensor type, per building. No fixed leg,
no "RingBuffer wins live because it's the live tier," no "Hierarchical wins
spatial because it's a tree." If a different backend wins for a *specific*
parsed building, that's the reported answer.

### The 25-iteration/median/p95/p99 methodology is retired

**This directly supersedes CLAUDE.md §3.4** ("minimum 25 iterations... report
median/p95/p99"), by explicit, disclosed user decision — not a silent
deviation. The old rule existed to fake statistical spread over a tiny toy
dataset via resampling; once the dataset is real per-sensor volume, each
query is called once against the real data. **CLAUDE.md needs a follow-up
edit once this is implemented** to reflect the new methodology — this is
flagged here per CLAUDE.md §10's own instruction to surface open decisions
rather than quietly leave the doc stale.

### New backend: Lake

Cheapest possible cold tier — flat, unindexed, uncompressed array. Models
the real hot/warm/cold IoT storage-tiering pattern (RingBuffer=hot,
TimeSeries/Columnar=warm, Lake=cold), confirmed via research: a documented
reference architecture uses S3 for cold storage alongside a hot time-series
store. Eligible to win precisely when a query is infrequent/cold enough that
Columnar/TimeSeries's indexing overhead isn't worth paying for.

## Measured facts already established (verify freshness before trusting)

- `SensorReading` = **24 bytes** exactly (`@sizeOf`, not estimated) — 4B
  sensor_id + 8B timestamp + 4B value + 1B sensor_type, padded to 24 for
  i64's 8-byte alignment.
- At the hospital-scale placement already benchmarked (640 temp / 480
  humidity / 320 flow / 760 energy / 80 structural / 480 occupancy / 760
  vibration sensors), full retention-depth generation totals **~360M
  readings ≈ 8.6GB for one backend's copy**. `main.zig` already processes
  backends sequentially (`defer world.deinit()` per block), so peak memory
  is roughly one backend's data at a time, not all backends coexisting.
- The existing aggregation queries (`query_avg_window`, `query_avg_zone_type`,
  `query_floor_stats`, `query_hourly_rollup`, `query_daily_zone_rollup`)
  already do honest single-pass fetch/sum/divide with dynamically-sized
  hash-bucket outputs — verified by reading the implementations directly.
  They should work correctly against real-scale data without logic changes;
  only the data feeding them and the removal of the 25-iteration wrapper
  change.

## Explicitly NOT yet done

1. ~~Full recheck of the remaining 7 query patterns~~ — **done 2026-07-01**.
2. ~~The prune/evict interface method~~ — **done 2026-07-01**.
3. ~~RingBuffer's per-type-configurable capacity~~ — **done 2026-07-01**.
4. ~~The Lake backend~~ — **done 2026-07-01**.
5. ~~The generator.zig continuous/event-storage split~~ — **done 2026-07-01**.
6. ~~The researched retention values~~ — **done 2026-07-01**. All six items
   above are in "Implementation progress" above. Still not implemented:
   per-sensor unique full-volume generation, the live tick simulator,
   retiring the 25-iteration methodology, and the main.zig rewire.
7. Time-compression factor for the live simulator.
8. The CLAUDE.md §3.4 edit reflecting the retired 25-iteration rule.
