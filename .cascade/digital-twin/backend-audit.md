# Backend Implementation Audit

_Reviewed Jun 28 2026 against benchmark results (3 scale tiers, 100 iterations each)._
_Hierarchical re-verified 2026-06-28: tree-exploitation fix confirmed in code + benchmark, see update below._
_Hierarchical revised again 2026-06-29: zone/floor grouping was coupled to dataset.zig's synthetic sensor_id arithmetic, which never matched a real building's actual zone assignment — see update below._

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
