# Backend Implementation Audit

_Reviewed Jun 28 2026 against benchmark results (3 scale tiers, 100 iterations each)._

## Verdict per backend

| Backend | Status | Notes |
|---|---|---|
| AoS | ✅ Correct | Worst-case reference baseline only — not a deployment option |
| SoA | ✅ Correct | Parallel column layout genuinely different from AoS |
| TimeSeries | ✅ Correct | Binary search on sorted log works correctly |
| Columnar | ✅ Mostly correct | See note below |
| Hierarchical | ⚠️ Tree built but never exploited | See note below |
| RingBuffer | ✅ Correct | High memory by design (pre-allocated per sensor) |

---

## Columnar — delta compression declared but unused

`ts_deltas` and `ts_compressed` fields exist and are tracked, but `ensureCompressed()` is never called and `ts_deltas` is never populated. The backend operates as sorted SoA with binary-search range queries. Correctness is unaffected — it just doesn't deliver the compression benefit it implies.

**Action (optional):** Either implement `ensureCompressed` and use `ts_deltas` for `rangeByTime`, or remove the dead fields to keep the code honest.

---

## Hierarchical — tree is built but never exploited

**Root cause of consistent slowness in benchmark results.**

The tree (Building → Floor → Room → Sensor) is correctly constructed via `ensureSensorPath`. However:

1. `iterateAll` ignores the tree — it flattens all leaf nodes and sorts. Same O(n log n) as AoS plus tree-traversal overhead.
2. `getLatestBySensor` scans leaf node readings linearly — no cached latest (unlike RingBuffer's O(1) `latest` field).
3. All benchmark sensors are IDs 0–99. The zone mapping is `floor = sensor_id / 100`, `room = sensor_id / 10`. With IDs 0–99, **every sensor lands on floor 0** — the tree is almost flat and provides zero pruning.
4. All zone/floor queries call `world.iterateAll()` — they never call a subtree traversal. The hierarchy provides no benefit to any current query.

**Result:** Hierarchical benchmarks as a slower AoS — tree overhead with none of the payoff.

**Fix required to make Hierarchical meaningful:**

- Add `iterateSubtree(zone_id: u32) ![]SensorReading` or similar to the backend (or as an interface extension).
- Zone queries (`query_avg_zone_type`, `query_floor_stats`, `query_zone_hierarchy`) should call the subtree method instead of `iterateAll` when the backend supports it.
- Alternatively, cache `latest` per sensor on insert (one-liner, same as RingBuffer) to at least fix `getLatestBySensor`.
- Adjust zone mapping so sensors 0–99 span multiple floors (e.g. `floor = sensor_id / 10`) to actually exercise tree pruning at benchmark scale.

Until this is fixed, **Hierarchical results in the benchmark are not representative** — they show the cost of maintaining a tree without any of the benefit.
