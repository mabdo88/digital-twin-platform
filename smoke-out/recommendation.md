# Digital Twin — Storage Recommendation

- Source IFC: `assets\IFC\Building-Architecture.ifc`
- Run label: `Building-Architecture`
- Elements: 19 | Zones: 3 | Equipment: 5 | Sensors placed: 16

## Sensors placed, by type

Density, sampling rate, and retention all come from each type's own canonical characteristics (synthetic/generator.zig) — not a building-type guess.

| Sensor type | Count | Retention |
|---|---:|---:|
| temperature | 2 | 90 days |
| humidity | 2 | 90 days |
| occupancy | 2 | 365 days |
| vibration | 5 | 30 days |
| energy | 5 | 1825 days |

> Honesty headline: relative rankings are reliable; absolute numbers are approximate (CLAUDE.md §6).

## Recommendation

Recommendations are **compound** — split into two independently-won tracks, because no single backend should serve both a tiny live cache's workload and a full-history store's workload:

1. **Real-time track** (`latest_single`, `latest_zone`, `latest_by_type`) — all backends compete; the count-capped real-time cache (RingBuffer, 10 readings/sensor) legitimately wins here.
2. **Historical track** (aggregation, historical rollups, spatial, anomaly) — only full-retention backends compete; the real-time cache is excluded because it evicts data these queries need.

Score = weighted average of (this backend's median / the per-query winner's median) across that track's query mix. **1.00 = won every weighted query; higher is worse.** Coverage below 100% means the backend has no data for one or more weighted queries.

### Real-time track

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.338 | 100% |
| TimeSeries | 1.370 | 100% |
| Hierarchical | 2.802 | 100% |
| RingBuffer | 3.523 | 100% |
| Lake | 24064.467 | 100% |

**Real-time winner: Columnar**

### Historical track

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.511 | 100% |
| TimeSeries | 1.831 | 100% |
| Lake | 16.669 | 100% |
| Hierarchical | 1050.110 | 100% |

**Historical winner: Columnar**

**Deployment combo: Columnar (live) + Columnar (historical)**

## Recommendation by Sensor Type

Same scoring rule as above, but scoped to one sensor type at a time. For each of the 5 sensor types actually placed in this building, each of that type's canonical type-scoped queries is measured once against a real placed sensor of that exact type, over its full independently-generated dataset. Scores only the query patterns in that type's own canonical relevant_queries that take a sensor type as an argument (`latest_by_type`, `avg_zone_type`, `floor_stats`, `daily_zone_rollup`, `anomalies` — whichever are relevant for this specific type). A type's winner can differ from the building-wide winner above if that type's relevant queries behave differently.

**temperature** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.000 | 100% |
| Columnar | 1.261 | 100% |
| Hierarchical | 1.402 | 100% |
| TimeSeries | 2.174 | 100% |

**humidity** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.000 | 100% |
| Columnar | 1.062 | 100% |
| TimeSeries | 1.109 | 100% |
| Hierarchical | 1.292 | 100% |

**occupancy** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.000 | 100% |
| Hierarchical | 1.169 | 100% |
| TimeSeries | 1.238 | 100% |
| Columnar | 1.284 | 100% |

**energy** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.027 | 100% |
| Columnar | 2.371 | 100% |
| TimeSeries | 2.507 | 100% |
| Hierarchical | 2.530 | 100% |

**vibration** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.158 | 100% |
| Columnar | 1.371 | 100% |
| TimeSeries | 1.393 | 100% |
| Hierarchical | 1.470 | 100% |

## Per-query latency (this building's actual query mix)

| Query | Backend | Median µs | p95 µs | Memory (KB) |
|---|---|---:|---:|---:|
| query_latest_single | TimeSeries | 0.3 | 0.3 | 24606.3 |
| query_latest_zone | TimeSeries | 43.4 | 43.4 | 24606.3 |
| query_avg_window | TimeSeries | 118.7 | 118.7 | 24606.3 |
| query_avg_zone_type | TimeSeries | 15091.9 | 15091.9 | 24606.3 |
| query_hourly_rollup | TimeSeries | 609.1 | 609.1 | 24606.3 |
| query_daily_zone_rollup | TimeSeries | 24799.0 | 24799.0 | 24606.3 |
| query_threshold_breach | TimeSeries | 6789.4 | 6789.4 | 24606.3 |
| query_anomalies | TimeSeries | 54055.9 | 54055.9 | 24606.3 |
| query_latest_single | TimeSeries | 0.2 | 0.2 | 24606.3 |
| query_latest_zone | TimeSeries | 45.1 | 45.1 | 24606.3 |
| query_avg_window | TimeSeries | 131.9 | 131.9 | 24606.3 |
| query_avg_zone_type | TimeSeries | 22779.5 | 22779.5 | 24606.3 |
| query_daily_zone_rollup | TimeSeries | 27692.6 | 27692.6 | 24606.3 |
| query_threshold_breach | TimeSeries | 11893.3 | 11893.3 | 24606.3 |
| query_latest_single | TimeSeries | 0.3 | 0.3 | 24606.3 |
| query_latest_zone | TimeSeries | 51.6 | 51.6 | 24606.3 |
| query_avg_zone_type | TimeSeries | 18423.4 | 18423.4 | 24606.3 |
| query_daily_zone_rollup | TimeSeries | 28013.3 | 28013.3 | 24606.3 |
| query_zone_hierarchy | TimeSeries | 13.0 | 13.0 | 24606.3 |
| query_spatial_radius | TimeSeries | 0.6 | 0.6 | 24606.3 |
| query_latest_single | TimeSeries | 0.3 | 0.3 | 24606.3 |
| query_avg_zone_type | TimeSeries | 17049.9 | 17049.9 | 24606.3 |
| query_hourly_rollup | TimeSeries | 714.7 | 714.7 | 24606.3 |
| query_daily_zone_rollup | TimeSeries | 27374.6 | 27374.6 | 24606.3 |
| query_anomalies | TimeSeries | 47234.5 | 47234.5 | 24606.3 |
| query_threshold_breach | TimeSeries | 6572.0 | 6572.0 | 24606.3 |
| query_latest_single | TimeSeries | 0.3 | 0.3 | 24606.3 |
| query_anomalies | TimeSeries | 74511.3 | 74511.3 | 24606.3 |
| query_threshold_breach | TimeSeries | 6261.6 | 6261.6 | 24606.3 |
| query_avg_zone_type | TimeSeries | 18063.5 | 18063.5 | 24606.3 |
| query_spatial_radius | TimeSeries | 0.8 | 0.8 | 24606.3 |
| query_latest_single | Columnar | 0.3 | 0.3 | 20178.5 |
| query_latest_zone | Columnar | 52.5 | 52.5 | 20178.5 |
| query_avg_window | Columnar | 137.2 | 137.2 | 11442.0 |
| query_avg_zone_type | Columnar | 16407.3 | 16407.3 | 11442.0 |
| query_hourly_rollup | Columnar | 666.1 | 666.1 | 11442.0 |
| query_daily_zone_rollup | Columnar | 28194.6 | 28194.6 | 11442.0 |
| query_threshold_breach | Columnar | 6285.5 | 6285.5 | 11442.0 |
| query_anomalies | Columnar | 55036.9 | 55036.9 | 11442.0 |
| query_latest_single | Columnar | 0.3 | 0.3 | 11442.0 |
| query_latest_zone | Columnar | 47.9 | 47.9 | 11442.0 |
| query_avg_window | Columnar | 136.1 | 136.1 | 11442.0 |
| query_avg_zone_type | Columnar | 17264.7 | 17264.7 | 11442.0 |
| query_daily_zone_rollup | Columnar | 34460.9 | 34460.9 | 11442.0 |
| query_threshold_breach | Columnar | 6811.9 | 6811.9 | 11442.0 |
| query_latest_single | Columnar | 0.3 | 0.3 | 11442.0 |
| query_latest_zone | Columnar | 48.2 | 48.2 | 11442.0 |
| query_avg_zone_type | Columnar | 23652.4 | 23652.4 | 11442.0 |
| query_daily_zone_rollup | Columnar | 28659.3 | 28659.3 | 11442.0 |
| query_zone_hierarchy | Columnar | 12.2 | 12.2 | 11442.0 |
| query_spatial_radius | Columnar | 0.6 | 0.6 | 11442.0 |
| query_latest_single | Columnar | 0.3 | 0.3 | 11442.0 |
| query_avg_zone_type | Columnar | 18370.0 | 18370.0 | 11442.0 |
| query_hourly_rollup | Columnar | 715.4 | 715.4 | 11442.0 |
| query_daily_zone_rollup | Columnar | 26366.3 | 26366.3 | 11442.0 |
| query_anomalies | Columnar | 48800.5 | 48800.5 | 11442.0 |
| query_threshold_breach | Columnar | 6511.7 | 6511.7 | 11442.0 |
| query_latest_single | Columnar | 0.3 | 0.3 | 11442.0 |
| query_anomalies | Columnar | 48044.5 | 48044.5 | 11442.0 |
| query_threshold_breach | Columnar | 5726.6 | 5726.6 | 11442.0 |
| query_avg_zone_type | Columnar | 18961.3 | 18961.3 | 11442.0 |
| query_spatial_radius | Columnar | 0.8 | 0.8 | 11442.0 |
| query_latest_single | Hierarchical | 0.8 | 0.8 | 57297.9 |
| query_latest_zone | Hierarchical | 68.5 | 68.5 | 57297.9 |
| query_avg_window | Hierarchical | 518.3 | 518.3 | 57297.9 |
| query_avg_zone_type | Hierarchical | 21654.7 | 21654.7 | 57297.9 |
| query_hourly_rollup | Hierarchical | 1416.3 | 1416.3 | 57297.9 |
| query_daily_zone_rollup | Hierarchical | 37056.6 | 37056.6 | 57297.9 |
| query_threshold_breach | Hierarchical | 7522.7 | 7522.7 | 57297.9 |
| query_anomalies | Hierarchical | 61950.7 | 61950.7 | 57297.9 |
| query_latest_single | Hierarchical | 0.6 | 0.6 | 57297.9 |
| query_latest_zone | Hierarchical | 49.4 | 49.4 | 57297.9 |
| query_avg_window | Hierarchical | 341.4 | 341.4 | 57297.9 |
| query_avg_zone_type | Hierarchical | 22978.7 | 22978.7 | 57297.9 |
| query_daily_zone_rollup | Hierarchical | 33593.8 | 33593.8 | 57297.9 |
| query_threshold_breach | Hierarchical | 6891.7 | 6891.7 | 57297.9 |
| query_latest_single | Hierarchical | 0.6 | 0.6 | 57297.9 |
| query_latest_zone | Hierarchical | 48.8 | 48.8 | 57297.9 |
| query_avg_zone_type | Hierarchical | 17552.5 | 17552.5 | 57297.9 |
| query_daily_zone_rollup | Hierarchical | 32583.4 | 32583.4 | 57297.9 |
| query_zone_hierarchy | Hierarchical | 12.8 | 12.8 | 57297.9 |
| query_spatial_radius | Hierarchical | 0.7 | 0.7 | 57297.9 |
| query_latest_single | Hierarchical | 0.6 | 0.6 | 57297.9 |
| query_avg_zone_type | Hierarchical | 20023.2 | 20023.2 | 57297.9 |
| query_hourly_rollup | Hierarchical | 1331.3 | 1331.3 | 57297.9 |
| query_daily_zone_rollup | Hierarchical | 34945.2 | 34945.2 | 57297.9 |
| query_anomalies | Hierarchical | 68326.0 | 68326.0 | 57297.9 |
| query_threshold_breach | Hierarchical | 14181.3 | 14181.3 | 57297.9 |
| query_latest_single | Hierarchical | 0.8 | 0.8 | 57297.9 |
| query_anomalies | Hierarchical | 52640.1 | 52640.1 | 57297.9 |
| query_threshold_breach | Hierarchical | 6492.2 | 6492.2 | 57297.9 |
| query_avg_zone_type | Hierarchical | 17509.5 | 17509.5 | 57297.9 |
| query_spatial_radius | Hierarchical | 8963.0 | 8963.0 | 57297.9 |
| query_latest_single | RingBuffer | 0.6 | 0.6 | 6.3 |
| query_latest_zone | RingBuffer | 45.8 | 45.8 | 6.3 |
| query_avg_window | RingBuffer | 35.7 | 35.7 | 6.3 |
| query_avg_zone_type | RingBuffer | 114.0 | 114.0 | 6.3 |
| query_threshold_breach | RingBuffer | 19.3 | 19.3 | 6.3 |
| query_anomalies | RingBuffer | 53.5 | 53.5 | 6.3 |
| query_latest_single | RingBuffer | 0.5 | 0.5 | 6.3 |
| query_latest_zone | RingBuffer | 62.7 | 62.7 | 6.3 |
| query_avg_window | RingBuffer | 90.1 | 90.1 | 6.3 |
| query_avg_zone_type | RingBuffer | 148.2 | 148.2 | 6.3 |
| query_threshold_breach | RingBuffer | 27.2 | 27.2 | 6.3 |
| query_latest_single | RingBuffer | 1.0 | 1.0 | 6.3 |
| query_latest_zone | RingBuffer | 93.5 | 93.5 | 6.3 |
| query_avg_zone_type | RingBuffer | 165.8 | 165.8 | 6.3 |
| query_zone_hierarchy | RingBuffer | 14.5 | 14.5 | 6.3 |
| query_spatial_radius | RingBuffer | 1.0 | 1.0 | 6.3 |
| query_latest_single | RingBuffer | 0.9 | 0.9 | 6.3 |
| query_avg_zone_type | RingBuffer | 143.4 | 143.4 | 6.3 |
| query_anomalies | RingBuffer | 57.1 | 57.1 | 6.3 |
| query_threshold_breach | RingBuffer | 21.3 | 21.3 | 6.3 |
| query_latest_single | RingBuffer | 0.9 | 0.9 | 6.3 |
| query_anomalies | RingBuffer | 63.5 | 63.5 | 6.3 |
| query_threshold_breach | RingBuffer | 21.5 | 21.5 | 6.3 |
| query_avg_zone_type | RingBuffer | 116.0 | 116.0 | 6.3 |
| query_spatial_radius | RingBuffer | 0.7 | 0.7 | 6.3 |
| query_latest_single | Lake | 6982.1 | 6982.1 | 24606.3 |
| query_latest_zone | Lake | 38448.1 | 38448.1 | 24606.3 |
| query_avg_window | Lake | 15283.8 | 15283.8 | 24606.3 |
| query_avg_zone_type | Lake | 18533.9 | 18533.9 | 24606.3 |
| query_hourly_rollup | Lake | 15129.4 | 15129.4 | 24606.3 |
| query_daily_zone_rollup | Lake | 29932.9 | 29932.9 | 24606.3 |
| query_threshold_breach | Lake | 6892.8 | 6892.8 | 24606.3 |
| query_anomalies | Lake | 17365.3 | 17365.3 | 24606.3 |
| query_latest_single | Lake | 6350.0 | 6350.0 | 24606.3 |
| query_latest_zone | Lake | 37329.0 | 37329.0 | 24606.3 |
| query_avg_window | Lake | 15758.7 | 15758.7 | 24606.3 |
| query_avg_zone_type | Lake | 17016.4 | 17016.4 | 24606.3 |
| query_daily_zone_rollup | Lake | 30732.4 | 30732.4 | 24606.3 |
| query_threshold_breach | Lake | 6964.9 | 6964.9 | 24606.3 |
| query_latest_single | Lake | 6611.9 | 6611.9 | 24606.3 |
| query_latest_zone | Lake | 34473.5 | 34473.5 | 24606.3 |
| query_avg_zone_type | Lake | 15666.7 | 15666.7 | 24606.3 |
| query_daily_zone_rollup | Lake | 30135.4 | 30135.4 | 24606.3 |
| query_zone_hierarchy | Lake | 12.8 | 12.8 | 24606.3 |
| query_spatial_radius | Lake | 0.6 | 0.6 | 24606.3 |
| query_latest_single | Lake | 6751.1 | 6751.1 | 24606.3 |
| query_avg_zone_type | Lake | 14670.2 | 14670.2 | 24606.3 |
| query_hourly_rollup | Lake | 12837.3 | 12837.3 | 24606.3 |
| query_daily_zone_rollup | Lake | 27875.1 | 27875.1 | 24606.3 |
| query_anomalies | Lake | 15037.5 | 15037.5 | 24606.3 |
| query_threshold_breach | Lake | 6798.0 | 6798.0 | 24606.3 |
| query_latest_single | Lake | 8137.2 | 8137.2 | 24606.3 |
| query_anomalies | Lake | 15286.5 | 15286.5 | 24606.3 |
| query_threshold_breach | Lake | 6158.5 | 6158.5 | 24606.3 |
| query_avg_zone_type | Lake | 14041.1 | 14041.1 | 24606.3 |
| query_spatial_radius | Lake | 0.6 | 0.6 | 24606.3 |

See `schematic.svg` in this directory for a floor-by-floor map of placed sensors.
