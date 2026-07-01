# Backend Implementation Audit

_Reviewed Jun 28 2026 against benchmark results (3 scale tiers, 100 iterations each)._
_Hierarchical re-verified 2026-06-28: tree-exploitation fix confirmed in code + benchmark, see update below._
_Hierarchical revised again 2026-06-29: zone/floor grouping was coupled to dataset.zig's synthetic sensor_id arithmetic, which never matched a real building's actual zone assignment — see update below._
_World(T) query layer revised 2026-06-30: iterateAll() and zone/floor-scoped queries were redoing full-dataset work on every call, equally across all six backends — not a backend-correctness issue, see update below._
_All backends gained pruneOlderThan (real per-type eviction) 2026-07-01, part of the storage-redesign-plan.md rework; two more query bugs found and fixed the same day, see update below._

## Verdict per backend

| Backend | Status | Notes |
|---|---|---|
| AoS | ✅ Correct | Worst-case reference baseline only — not a deployment option |
| SoA | ✅ Correct | Parallel column layout genuinely different from AoS |
| TimeSeries | ✅ Correct | Binary search on sorted log works correctly |
| Columnar | ✅ Fixed | Delta compression now implemented and used — see update below |
| Hierarchical | ✅ Fixed | Tree exploited via real registerZone/registerFloor topology, not sensor_id arithmetic — see update below |
| RingBuffer | ✅ Correct | High memory by design (pre-allocated per sensor) |

---

## Columnar — delta compression now implemented (fixed 2026-06-28)

`ensureCompressed()` now does real work: once `ensureSorted()` has run, it zigzag-encodes each timestamp's delta from its predecessor and LEB128-varint-packs the result into `ts_deltas`. Consecutive sensor-stream timestamps differ by small, repeatable deltas, so each entry typically costs 1-3 bytes instead of the raw column's 8.

- `ts_deltas` is genuinely built and used: `rangeByTime`'s unfiltered path calls `ensureCompressed()` before searching, so the compressed column can never silently go stale relative to a live query — it's kept in sync continuously, not built once and forgotten.
- `memoryUsed()` reports the compressed footprint (`ts_deltas.items.len`) for the timestamp column whenever compression is current, falling back to the raw column's size only while dirty (so it never *under*-reports). The raw `timestamps` array is intentionally kept resident as the decompressed working set queries read from — the same tradeoff a real columnar engine makes by caching a hot block's decompressed form rather than re-decoding on every scan.
- Correctness is proven by a dedicated round-trip test (`decodeTimestamps` reconstructs the exact original values, including out-of-order/irregular input) and an invalidation test (new inserts flip `ts_compressed` back to false; the next `rangeByTime` call re-syncs it).
- The memory win is proven directly: a 2000-reading regularly-sampled dataset test asserts `ts_deltas.items.len < N * 4` bytes and that `memoryUsed()` after compression is strictly less than before.

---

## Hierarchical — tree is now exploited (fixed)

All four original complaints are resolved in the current code:

1. ~~`iterateAll` ignores the tree~~ — still flattens for full-scan iteration (correct: that's what "all" means), but is now backed by a lazily-rebuilt `sorted_cache` so repeated calls don't re-walk + re-sort every time.
2. ~~`getLatestBySensor` scans linearly~~ — fixed. Each leaf node carries a `latest: ?SensorReading` maintained incrementally on `insert`, same pattern RingBuffer already used. Now O(1).
3. ~~Zone mapping made every sensor land on floor 0~~ — fixed. `SENSORS_PER_ZONE=5` / `SENSORS_PER_FLOOR=10` in `hierarchical_storage.zig` now match `engine/benchmark/dataset.zig`'s actual topology (duplicated intentionally, since storage backends sit below the benchmark layer — see the file's header comment for why).
4. ~~Zone/floor queries call `iterateAll`~~ — fixed for the case that matters. `StorageBackend` gained a new interface method, `sensorIdsByGroup(group_id, divisor) ![]u32`, implemented by every backend (linear scan for AoS/SoA/TimeSeries/Columnar/RingBuffer, real subtree walk for Hierarchical). `queries.zig`'s `query_zone_hierarchy` calls it at depth 0/1 instead of `iterateAll`.

**Benchmark proof** (Large scale, `query_zone_hierarchy`): Hierarchical median 48.5µs vs TimeSeries 2087µs / Columnar 1876µs — a ~40-60x win, confirming the subtree walk is actually being exercised, not just present.

`query_avg_zone_type` / `query_floor_stats` are only modestly faster on Hierarchical (these aggregate per-reading values within a zone, not just list sensor IDs, so the `sensorIdsByGroup` shortcut helps less there) — that's expected and not a defect.

A new test, `"Hierarchical: tree structure creates correct zone hierarchy"`, exercises the subtree-walk fast path directly and asserts it returns exactly the sensors in the target zone/floor, nothing from sibling subtrees.

---

## Hierarchical (and the whole zone/floor query family) — real registration replaces synthetic arithmetic (2026-06-29)

Point 3 above ("zone mapping ... fixed") turned out to be the wrong fix. `SENSORS_PER_ZONE=5` / `SENSORS_PER_FLOOR=10` matched `dataset.zig`'s own made-up benchmark fixture by construction — but a real building's zones (from `sensor_placer.place()`'s `ZoneLocation`) hold a *variable* number of sensors with *arbitrary* ids (the source IFC entity id), never a fixed-width block. Pointing the old code at a real IFC-derived dataset wouldn't have crashed — it would have silently grouped "zone 3" as whichever 5 sequential sensor_ids happened to land there, with zero relationship to any real space in the building. Same problem in `queries.zig`'s `query_avg_zone_type`, `query_floor_stats`, `query_latest_zone`, `query_daily_zone_rollup`, which inlined `sensor_id / SENSORS_PER_ZONE` directly instead of going through `sensorIdsByGroup` at all.

Fixed by replacing the divisor-based `sensorIdsByGroup(group_id, divisor)` with explicit topology registration: `registerZone(sensor_id, zone_id)` / `registerFloor(zone_id, floor_id)` (mirroring `ZoneLocation`/`ZoneMetadata.floor_level` from the real BIM pipeline) plus `sensorIdsByZone`/`sensorIdsByFloor`/`floorOfZone` lookups — no arithmetic relationship between sensor_id and zone_id assumed anywhere. The five flat backends share one `ZoneIndex` helper (`engine/ecs/storage/zone_index.zig`) so the bookkeeping isn't copy-pasted five times; Hierarchical's tree now keys nodes by the real registered zone_id/floor_id (with two "unassigned" catch-all branches for sensors/zones inserted before registration) instead of `sensor_id / N`.

`dataset.zig`'s `insertDataset` is the one place the old fixed-width convention is still allowed to live — it now calls `registerZone`/`registerFloor` explicitly using that same convention, exactly the way a real pipeline calls them from real placement data. Every golden-result test that depended on the synthetic topology kept its expected values unchanged, since `insertDataset` reproduces the same grouping it always implied — it's just explicit now instead of buried in every backend and query.

---

## World(T) query layer — redundant full-dataset work eliminated (2026-06-30)

Two compounding performance defects, both above the backend level — every backend was equally affected, and all six already produced *correct* answers before this fix. This wasn't a correctness bug; it was "correct but needlessly slow at benchmark scale," surfaced by a real hospital-scale run (`LargeHospitalComplex.ifc`, 72M synthetic readings) that took 18+ minutes without finishing a single backend's query phase.

1. **`iterateAll()` re-materialized the entire dataset on every call.** Every backend's `iterateAll()` allocates a fresh copy of every reading (TimeSeries/Hierarchical via `@memcpy`, Columnar/SoA by rebuilding row-by-row from columns, RingBuffer by walking every sensor's ring buffer). `query_avg_zone_type`, `query_daily_zone_rollup`, and `query_anomalies` all call it; at hospital scale (7 sensor types, up to 25 real-sensor samples per type) that was 500+ calls per backend, each re-copying ~1.7GB. Fixed by caching `iterateAll()`'s result at the generic `World(T)` wrapper (`engine/ecs/world.zig`), invalidated on the next `insert()`. Zero backend-specific code — every backend benefits identically. Backends' own `iterateAll()` keeps its original owned-copy contract for direct callers (e.g. backend unit tests); only `World.iterateAll()`'s contract changed (borrowed snapshot, not an owned copy).

2. **Zone/floor-scoped queries tested membership by hash-probing every single reading.** `query_avg_zone_type` and `query_daily_zone_rollup` built a small zone-membership set (a handful of sensor ids) then scanned all 72M readings calling `members.contains(r.sensor_id)` on each one — ~144M hash lookups per call, ~200 calls per query type at hospital scale. The zone data itself was always correct (`sensorIdsByZone` returns exactly the right sensors); the access pattern was the problem — walking the whole dataset row-by-row instead of going sensor-by-sensor through the much smaller zone membership. Fixed with a second `World(T)`-level cache: `sensor_id -> indices into the cached iterateAll() snapshot`, also invalidated on insert. `query_avg_zone_type`/`query_floor_stats`/`query_daily_zone_rollup` were rewritten to fetch each zone/floor member's own readings directly (`World.readingsForSensor`) instead of scanning everything. The now-unused `zoneMembership`/`floorMembership` helpers were deleted, not left as dead code.

**Correctness proof:** no backend file was touched by either fix — both live entirely in `engine/ecs/world.zig` and `engine/benchmark/queries.zig`, the generic layer every backend already routes through. The existing golden-equivalence tests prove the rewrite is output-identical to the original: `query_avg_zone_type`/`query_floor_stats: all six backends agree on same seeded dataset`, `query_daily_zone_rollup: five supported backends agree on same seeded dataset` (RingBuffer correctly excluded — no historical data), plus each query's nonexistent-zone/no-matching-type/empty-world edge cases — all still passing unchanged. Two new tests cover the caches directly: reuse across repeated calls without an intervening insert (same underlying slice/index), and invalidation on insert (new data picked up, not silently dropped or duplicated).

**Benchmark proof (small-scale smoke run, `AC20-FZK-Haus.ifc`):** `query_avg_zone_type`/`query_daily_zone_rollup` medians dropped from ~3.4-4.8ms to ~300-700µs; total run time fell from 3.4s to 0.9s. The win is far larger at benchmark scale, where the eliminated work was O(dataset size) per call rather than O(zone size) — a typical hospital zone has on the order of 10-15 sensors against 72M total readings.

---

## Sampling bias, anomaly recomputation, and the synthetic-data/profile rework (2026-06-30)

Same session, three more rounds of fixes on top of the `World(T)` caching work above, all still generic (no backend file touched).

**Sampling bias.** Every type-scoped query was timing the *same single sensor* across all 25 iterations — an artificially cache-hot, unrealistic access pattern that also meant `query_anomalies` recomputed one sensor's mean/stddev 25 times over. Fixed with a `Sampler` that cycles through up to 25 distinct real sensors of that type per query (repeating from the start if fewer than 25 exist), feeding the same unmodified `metrics.timeQuery`. Extended to all 12 query patterns, not just the type-scoped ones.

**Anomaly stat caching.** `query_anomalies` was recomputing mean/stddev over a sensor type's full reading set on every single call. Added two more `World(T)`-level caches — `statsForType(sensor_type)` (cached mean/stddev) and `readingsForType(sensor_type)` (cached per-type index) — invalidated together with the existing caches on `insert()`. Deliberately did **not** cache the anomaly *selection* itself (which readings exceed N stddev) — caching the final answer would make every backend report near-identical trivial-lookup latency and defeat the point of the benchmark. Also scoped the stat warmup to only the types whose query mix actually includes `anomalies` (it was unconditionally warming every placed type regardless of whether anomalies was even in that type's relevant-query list).

**Synthetic data generation redesign.** All 9 sensor types previously shared one identical sine-wave-plus-Gaussian-noise generative model regardless of real-world sensor behavior (occupancy treated as continuous, vibration as continuous, energy as continuous, structural sampled 600-6000x faster than real Structural Health Monitoring practice). Replaced with a per-type canonical table (`engine/synthetic/generator.zig`) sourced from web research: AMI/smart-meter 15-min sampling intervals, SHM static-monitoring 1-15min intervals (high-Hz reserved for dynamic event capture, not continuous streaming), PIR occupancy as binary/event-driven, vibration as periodic burst capture rather than continuous high-Hz. Four generative shapes now exist — `diurnal_continuous`, `binary_event` (Markov dwell time), `stepwise_discrete` (quantized level holds), `bursty_impulsive` (rare spike events) — dispatched per sensor via `switch (profile.shape)`.

**`bim/profiles.zig` removed entirely.** The building-type-profile system (`--type hospital|office|...`) guessed density, query mix, and retention per building archetype rather than deriving them from what was actually parsed/placed. Per explicit direction ("the density here is not a real thing... query mix is not a thing anymore... retention is from sensortype now... remove it, it is useless"): density and retention now live solely in each sensor type's canonical profile (`synthetic.profileFor`); query mix is derived per run as the union of `relevant_queries` across every sensor type actually placed (`main.zig`'s `deriveQueryMix()`); the `--type` CLI flag is gone, and the run label is derived from the IFC filename instead. `QueryName`/`QueryWeight` moved to `benchmark/queries.zig` as their natural home.

**Verification.** Full test suite green (794 tests, 7 binaries) after each stage. Smoke-tested against `AC20-FZK-Haus.ifc` (no `--type` flag, genuinely differentiated per-type winners) and the equipment-only `2KHRJ17-HASC-SD-710-EV-MOD-00001.ifc` edge case (zero spaces/walls/beams). Hospital-scale run (`LargeHospitalComplex.ifc`) dropped from 72,288,000 synthetic readings / 2-3 hours non-terminating to 91,280 readings / 20.5s end-to-end, since per-type frequencies now reflect real sampling rates instead of one shared high-frequency model.

**Open finding, not yet fixed:** `recommendBackend()` (`engine/benchmark/report.zig`) scores each backend as `weighted_sum / covered_weight` — i.e. only over the queries it actually has data for. RingBuffer's fixed 1000-reading-per-sensor eviction means it often has 50-83% coverage per sensor type at hospital scale, but missing coverage is disclosed (a separate "Coverage" column) and not penalized in the score itself. A backend that has silently evicted most of a type's history can still rank well on the data it kept. Flagged to the user 2026-06-30, fix not yet authorized/implemented.

---

## Query recheck and real eviction across all backends (2026-07-01)

First two implementation steps of the full storage/benchmark redesign — see `storage-redesign-plan.md` for the complete plan and what's still pending.

**Two more real query bugs found, both invisible at the old 1h toy-dataset scale.** `query_latest_by_type` scanned the entire world (`iterateAll()`, every sensor type, not just the requested one) and deduped "already seen this sensor" via a linear scan of the growing result list — O(readings × distinct sensors of that type) instead of O(readings). `query_spatial_radius` and `query_zone_hierarchy` (depth≥2) both scanned every reading in the world just to dedupe distinct sensor IDs, recomputing a sensor's (unchanging) position once per reading instead of once per sensor. Both fixed: `query_latest_by_type` now uses the existing `readingsForType` plus a hash map; the other two use a new cached `World.allSensorIds()` (same invalidate-on-insert pattern as `cached_all`/`sensor_index`/`type_index`), dropping both from O(total readings) to O(distinct sensors). The other 9 query patterns were already correct — single-pass, properly scoped — and needed no changes.

**Real per-type eviction added to every backend, not just RingBuffer.** New `StorageBackend` interface method: `pruneOlderThan(sensor_type, cutoff_timestamp) !void`, implemented by all 6 backends. AoS/SoA/TimeSeries/Columnar/Hierarchical compact in place with no allocation, each respecting its own invariants — TimeSeries/Columnar preserve sort order, and Columnar correctly invalidates its delta-compressed timestamp column (`ts_compressed = false`) since removing rows invalidates every delta after the first removed one (deltas are relative to the *previous* row). RingBuffer needed a genuinely different approach: its circular buffer means physical slot order and logical (oldest-to-newest) order only coincide when there's been no wraparound, so the same naive sequential in-place compaction the flat backends use can silently overwrite an unread entry. It uses a small scratch allocation bounded by one sensor's own capacity (never the whole dataset) to walk logical order safely — this is why the interface method is fallible (`!void`) rather than `void`, matching `insert`'s existing convention rather than special-casing one backend's signature. `World(T)` invalidates every cache (`cached_all`, `sensor_index`, `type_stats`, `type_index`, `all_sensor_ids`) on prune exactly like it already does on insert.

**Verification.** 8 new regression tests (one per backend, two for Hierarchical, one for RingBuffer specifically forcing a wrapped buffer so physical/logical order diverges) — all passing. Full suite green throughout (`zig build test` exit 0 after every change).

---

## RingBuffer per-type capacity and the new Lake backend (2026-07-01, same day)

Two more steps of the same redesign, same session.

**RingBuffer capacity is now per-sensor-type, not one global constant.** New `StorageBackend` interface method: `setRetentionHint(sensor_type, max_readings) !void` — a hint, not a command. Every backend except RingBuffer implements it as a no-op (they have no fixed-capacity concept — they hold everything inserted, bounded only by `pruneOlderThan`, same as Hierarchical's tree structurally exploiting `registerZone`/`registerFloor` while flat backends only bookkeep it). RingBuffer stores hints in a `sensor_type -> capacity` hashmap, consulted only when allocating a brand-new sensor's buffer; a hint set after some sensors of that type already exist does not resize them (documented contract: the caller sets every hint before ingestion begins).

**Real correctness bug found and fixed while implementing this.** `capacity_per_sensor` used to be a single backend-wide field, and `insert`/`memoryUsed`/`pruneOlderThan` all did wraparound arithmetic against it directly — including for *existing* sensors' buffers. That was silently correct only because every sensor always had the same capacity. Once different sensor types can have different capacities within the same backend instance, using the global field for an existing sensor's modulo math is wrong — it must use that specific sensor's own `buffer.len`. Fixed in all three call sites; the field itself was renamed `default_capacity_per_sensor` to make clear it's only the fallback for un-hinted types. 2 new regression tests, including one proving two different sensor types in the same backend instance get independently-sized, independently-evicting buffers.

**Lake backend added** (`engine/ecs/storage/backends/lake_storage.zig`) — the cheapest possible cold tier: flat, unindexed, uncompressed array. Research-grounded (see the 2026-06-30 entry above for the hot/warm/cold IoT tiering citations): unlike AoS/SoA (explicitly non-deployment reference baselines), Lake is a real deployment candidate, meant to win when a query is infrequent/cold enough that Columnar/TimeSeries's indexing overhead isn't worth paying for. Full interface implementation, own unit test suite, a golden-equivalence test against TimeSeries, and registered in `runner.zig`'s `backends`/`supported_backends` — the single canonical registration point every generic cross-backend test already reads from, so Lake was picked up automatically by `runner.zig`'s dynamic equivalence tests with no further duplication. (Note: `queries.zig`'s per-query equivalence tests are hand-scaffolded per backend, predating this session, and were NOT extended to Lake — that would be a large, low-value mechanical change; Lake's correctness is already proven by its own dedicated tests plus the dynamic runner.zig suite.)

**Verification.** Full suite green (`zig build test` exit 0). End-to-end smoke test: `dt.exe` against a real IFC file (`AC20-FZK-Haus.ifc`) runs Lake alongside TimeSeries/Columnar/Hierarchical/RingBuffer and reports it in the final winner comparison.

---

## generator.zig: continuous vs. event-storage split, retention values updated (2026-07-01, same day)

Two more steps of the redesign — this is the exact design correction the user made earlier in this session ("occupancy is stored event based a binary state... vibration is stored... we only store anomalies"), now implemented as an authorized, agreed step of `storage-redesign-plan.md`, not a repeat of the earlier unauthorized edit.

**`generate()`'s per-shape switch now decides WHETHER to store a value, not just how to compute it.** `binary_event` (occupancy) only appends a reading when the value differs from the last *emitted* value — an event log, not periodic polling. The first tick always emits (a real system reports its initial state at startup). `bursty_impulsive` (vibration) only appends when `sampleBurstyImpulsive` reports `is_event == true` (refactored to return a `BurstSample{value, is_event}` instead of a plain `f32`, so "is this an event" is tied directly to the generative branch that produced it, not a derived magnitude threshold that could disagree near the boundary) — non-event baseline samples still run through the RNG (determinism) but are discarded immediately, never stored. `diurnal_continuous`/`stepwise_discrete` (the other 7 types) are unchanged: full periodic readings every tick, matching how real BMS/AMI historians actually report.

**Retention values corrected with research from the same session:** co2/air_quality 365→1095 days (3yr, WELL Building Standard's documented minimum — a real regulatory number replacing an earlier unresearched guess); flow 90→365 days (1yr, a disclosed pragmatic choice, not researched — genuinely ambiguous whether a given flow sensor is billing-relevant). `profileFor`'s doc comment now explicitly separates which values are research-grounded (energy, structural, co2/air_quality) from reasoned defaults (temperature/humidity, flow, occupancy, vibration).

**Three tests had their premises inverted by the storage-model change and were rewritten, not patched.** The old "binary_event... state has dwell time" test asserted most *consecutive stored* readings share a value — backwards now, since every stored reading is by definition a transition; rewritten to assert consecutive stored readings always differ, with dwell time instead proven via gaps between transition timestamps exceeding one tick period. The old "bursty_impulsive... most readings stay near baseline" test asserted most stored readings are near baseline — also backwards; rewritten to assert every stored reading exceeds the burst floor, with sparsity proven by comparing count against total ticks evaluated. The 100k-sensor scale test's exact `readings.len == num_sensors` no longer holds since vibration's storage is now genuinely probabilistic (~2%/tick); relaxed to `0 < readings.len <= num_sensors` since the test's actual purpose (scale without blowing up) never depended on an exact count.

**Verification.** Full suite green throughout. End-to-end smoke test against the equipment-heavy HASC IFC file: 364 sensors → 1053 readings (a fraction of the old per-type-uniform volume), vibration correctly sparse, and — proving the empirical, no-assumptions principle this whole redesign exists for — Lake actually won the per-type recommendation for both energy and vibration in that run, not a backend anyone would have guessed upfront.
