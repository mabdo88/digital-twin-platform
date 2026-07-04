# Digital Twin — Storage Recommendation

- Source IFC: `assets\IFC\AC20-FZK-Haus.ifc`
- Run label: `AC20-FZK-Haus`
- Elements: 33 | Zones: 9 | Equipment: 0 | Sensors placed: 39

## Sensors placed, by type

Density, sampling rate, and retention all come from each type's own canonical characteristics (synthetic/generator.zig) — not a building-type guess.

| Sensor type | Count | Retention |
|---|---:|---:|
| temperature | 7 | 397 days |
| humidity | 7 | 397 days |
| occupancy | 7 | 90 days |
| co2 | 7 | 397 days |
| structural | 4 | 2555 days |
| air_quality | 7 | 397 days |

> Honesty headline: relative rankings are reliable; absolute numbers are approximate (CLAUDE.md §6).

## Recommendation

Recommendations are **compound** — split into two independently-won tracks, because no single backend should serve both a tiny live cache's workload and a full-history store's workload:

1. **Real-time track** (`latest_single`, `latest_zone`, `latest_by_type`) — all backends compete; the count-capped real-time cache (RingBuffer, 10 readings/sensor) legitimately wins here.
2. **Historical track** (aggregation, historical rollups, spatial, anomaly) — only full-retention backends compete; the real-time cache is excluded because it evicts data these queries need.

Score = weighted average of (this backend's median / the per-query winner's median) across that track's query mix. **1.00 = won every weighted query; higher is worse.** Coverage below 100% means the backend has no data for one or more weighted queries.

### Real-time track

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.220 | 100% |
| Hierarchical | 1.227 | 100% |
| RingBuffer | 1.304 | 100% |
| TimeSeries | 2.145 | 100% |
| Lake | 62449.355 | 100% |

**Real-time winner: Columnar**

### Historical track

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.117 | 100% |
| TimeSeries | 1.279 | 100% |
| Hierarchical | 4.571 | 100% |
| Lake | 89.770 | 100% |

**Historical winner: Columnar**

**Deployment combo: Columnar (live) + Columnar (historical)**

## Recommendation by Sensor Type

Same scoring rule as above, but scoped to one sensor type at a time. For each of the 6 sensor types actually placed in this building, each of that type's canonical type-scoped queries is measured once against a real placed sensor of that exact type, over its full independently-generated dataset. Scores only the query patterns in that type's own canonical relevant_queries that take a sensor type as an argument (`latest_by_type`, `avg_zone_type`, `floor_stats`, `daily_zone_rollup`, `anomalies` — whichever are relevant for this specific type). A type's winner can differ from the building-wide winner above if that type's relevant queries behave differently.

**structural** — historical: **Columnar**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.044 | 100% |
| Lake | 1.145 | 100% |
| TimeSeries | 1.207 | 100% |
| Hierarchical | 1.211 | 100% |

**temperature** — historical: **Columnar**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.000 | 100% |
| Lake | 1.148 | 100% |
| Hierarchical | 1.161 | 100% |
| TimeSeries | 1.315 | 100% |

**humidity** — historical: **Lake**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Lake | 1.000 | 100% |
| Columnar | 1.020 | 100% |
| Hierarchical | 1.111 | 100% |
| TimeSeries | 1.173 | 100% |

**occupancy** — historical: **Columnar**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.000 | 100% |
| Lake | 1.141 | 100% |
| TimeSeries | 1.241 | 100% |
| Hierarchical | 1.269 | 100% |

**co2** — historical: **Columnar**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.015 | 100% |
| Lake | 1.064 | 100% |
| Hierarchical | 1.160 | 100% |
| TimeSeries | 1.300 | 100% |

**air_quality** — historical: **Columnar**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Columnar | 1.000 | 100% |
| Hierarchical | 1.135 | 100% |
| Lake | 1.163 | 100% |
| TimeSeries | 1.203 | 100% |

## Per-query latency (this building's actual query mix)

| Query | Backend | Median µs | p95 µs | Memory (KB) |
|---|---|---:|---:|---:|
| query_latest_single | TimeSeries | 0.7 | 0.7 | 124569.7 |
| query_avg_zone_type | TimeSeries | 79395.5 | 79395.5 | 124569.7 |
| query_daily_zone_rollup | TimeSeries | 97800.8 | 97800.8 | 124569.7 |
| query_anomalies | TimeSeries | 2589785.3 | 2589785.3 | 124569.7 |
| query_threshold_breach | TimeSeries | 85269.4 | 85269.4 | 124569.7 |
| query_spatial_radius | TimeSeries | 25.4 | 25.4 | 124569.7 |
| query_latest_single | TimeSeries | 0.6 | 0.6 | 124569.7 |
| query_latest_zone | TimeSeries | 38.5 | 38.5 | 124569.7 |
| query_avg_window | TimeSeries | 120.1 | 120.1 | 124569.7 |
| query_avg_zone_type | TimeSeries | 73477.6 | 73477.6 | 124569.7 |
| query_hourly_rollup | TimeSeries | 504.1 | 504.1 | 124569.7 |
| query_daily_zone_rollup | TimeSeries | 101067.5 | 101067.5 | 124569.7 |
| query_threshold_breach | TimeSeries | 91154.0 | 91154.0 | 124569.7 |
| query_anomalies | TimeSeries | 2648533.5 | 2648533.5 | 124569.7 |
| query_latest_single | TimeSeries | 0.7 | 0.7 | 124569.7 |
| query_latest_zone | TimeSeries | 47.4 | 47.4 | 124569.7 |
| query_avg_window | TimeSeries | 150.1 | 150.1 | 124569.7 |
| query_avg_zone_type | TimeSeries | 71292.2 | 71292.2 | 124569.7 |
| query_daily_zone_rollup | TimeSeries | 100840.7 | 100840.7 | 124569.7 |
| query_threshold_breach | TimeSeries | 82850.9 | 82850.9 | 124569.7 |
| query_latest_single | TimeSeries | 0.7 | 0.7 | 124569.7 |
| query_latest_zone | TimeSeries | 43.7 | 43.7 | 124569.7 |
| query_avg_zone_type | TimeSeries | 78859.9 | 78859.9 | 124569.7 |
| query_daily_zone_rollup | TimeSeries | 99562.6 | 99562.6 | 124569.7 |
| query_zone_hierarchy | TimeSeries | 10.9 | 10.9 | 124569.7 |
| query_spatial_radius | TimeSeries | 24.7 | 24.7 | 124569.7 |
| query_latest_single | TimeSeries | 0.6 | 0.6 | 124569.7 |
| query_latest_zone | TimeSeries | 47.2 | 47.2 | 124569.7 |
| query_avg_window | TimeSeries | 120.7 | 120.7 | 124569.7 |
| query_avg_zone_type | TimeSeries | 76315.1 | 76315.1 | 124569.7 |
| query_threshold_breach | TimeSeries | 81830.9 | 81830.9 | 124569.7 |
| query_anomalies | TimeSeries | 2661905.5 | 2661905.5 | 124569.7 |
| query_latest_single | TimeSeries | 1.1 | 1.1 | 124569.7 |
| query_latest_zone | TimeSeries | 54.8 | 54.8 | 124569.7 |
| query_avg_window | TimeSeries | 229.1 | 229.1 | 124569.7 |
| query_avg_zone_type | TimeSeries | 81099.4 | 81099.4 | 124569.7 |
| query_threshold_breach | TimeSeries | 99303.5 | 99303.5 | 124569.7 |
| query_anomalies | TimeSeries | 2527820.3 | 2527820.3 | 124569.7 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_avg_zone_type | Columnar | 69876.9 | 69876.9 | 55973.3 |
| query_daily_zone_rollup | Columnar | 92301.9 | 92301.9 | 55973.3 |
| query_anomalies | Columnar | 2189763.8 | 2189763.8 | 55973.3 |
| query_threshold_breach | Columnar | 84029.8 | 84029.8 | 55973.3 |
| query_spatial_radius | Columnar | 25.9 | 25.9 | 55973.3 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_latest_zone | Columnar | 45.7 | 45.7 | 55973.3 |
| query_avg_window | Columnar | 126.2 | 126.2 | 55973.3 |
| query_avg_zone_type | Columnar | 74579.0 | 74579.0 | 55973.3 |
| query_hourly_rollup | Columnar | 586.3 | 586.3 | 55973.3 |
| query_daily_zone_rollup | Columnar | 91128.0 | 91128.0 | 55973.3 |
| query_threshold_breach | Columnar | 83491.3 | 83491.3 | 55973.3 |
| query_anomalies | Columnar | 2294254.9 | 2294254.9 | 55973.3 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_latest_zone | Columnar | 43.5 | 43.5 | 55973.3 |
| query_avg_window | Columnar | 132.6 | 132.6 | 55973.3 |
| query_avg_zone_type | Columnar | 71065.2 | 71065.2 | 55973.3 |
| query_daily_zone_rollup | Columnar | 93620.2 | 93620.2 | 55973.3 |
| query_threshold_breach | Columnar | 81921.4 | 81921.4 | 55973.3 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_latest_zone | Columnar | 36.5 | 36.5 | 55973.3 |
| query_avg_zone_type | Columnar | 78336.3 | 78336.3 | 55973.3 |
| query_daily_zone_rollup | Columnar | 97523.4 | 97523.4 | 55973.3 |
| query_zone_hierarchy | Columnar | 12.3 | 12.3 | 55973.3 |
| query_spatial_radius | Columnar | 27.8 | 27.8 | 55973.3 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_latest_zone | Columnar | 58.5 | 58.5 | 55973.3 |
| query_avg_window | Columnar | 130.5 | 130.5 | 55973.3 |
| query_avg_zone_type | Columnar | 75857.2 | 75857.2 | 55973.3 |
| query_threshold_breach | Columnar | 78510.1 | 78510.1 | 55973.3 |
| query_anomalies | Columnar | 2245388.4 | 2245388.4 | 55973.3 |
| query_latest_single | Columnar | 0.5 | 0.5 | 55973.3 |
| query_latest_zone | Columnar | 43.4 | 43.4 | 55973.3 |
| query_avg_window | Columnar | 128.8 | 128.8 | 55973.3 |
| query_avg_zone_type | Columnar | 74574.4 | 74574.4 | 55973.3 |
| query_threshold_breach | Columnar | 94365.9 | 94365.9 | 55973.3 |
| query_anomalies | Columnar | 2308387.0 | 2308387.0 | 55973.3 |
| query_latest_single | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_avg_zone_type | Hierarchical | 82973.8 | 82973.8 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 101023.7 | 101023.7 | 265572.6 |
| query_anomalies | Hierarchical | 2658626.6 | 2658626.6 | 265572.6 |
| query_threshold_breach | Hierarchical | 96103.5 | 96103.5 | 265572.6 |
| query_spatial_radius | Hierarchical | 29.6 | 29.6 | 265572.6 |
| query_latest_single | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_latest_zone | Hierarchical | 60.4 | 60.4 | 265572.6 |
| query_avg_window | Hierarchical | 2448.0 | 2448.0 | 265572.6 |
| query_avg_zone_type | Hierarchical | 110993.9 | 110993.9 | 265572.6 |
| query_hourly_rollup | Hierarchical | 5160.0 | 5160.0 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 95424.4 | 95424.4 | 265572.6 |
| query_threshold_breach | Hierarchical | 94922.1 | 94922.1 | 265572.6 |
| query_anomalies | Hierarchical | 2707716.8 | 2707716.8 | 265572.6 |
| query_latest_single | Hierarchical | 1.0 | 1.0 | 265572.6 |
| query_latest_zone | Hierarchical | 71.2 | 71.2 | 265572.6 |
| query_avg_window | Hierarchical | 4194.0 | 4194.0 | 265572.6 |
| query_avg_zone_type | Hierarchical | 86674.0 | 86674.0 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 112887.4 | 112887.4 | 265572.6 |
| query_threshold_breach | Hierarchical | 89565.7 | 89565.7 | 265572.6 |
| query_latest_single | Hierarchical | 0.5 | 0.5 | 265572.6 |
| query_latest_zone | Hierarchical | 37.3 | 37.3 | 265572.6 |
| query_avg_zone_type | Hierarchical | 74311.6 | 74311.6 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 92758.7 | 92758.7 | 265572.6 |
| query_zone_hierarchy | Hierarchical | 12.8 | 12.8 | 265572.6 |
| query_spatial_radius | Hierarchical | 28.7 | 28.7 | 265572.6 |
| query_latest_single | Hierarchical | 0.5 | 0.5 | 265572.6 |
| query_latest_zone | Hierarchical | 53.5 | 53.5 | 265572.6 |
| query_avg_window | Hierarchical | 2571.0 | 2571.0 | 265572.6 |
| query_avg_zone_type | Hierarchical | 99778.7 | 99778.7 | 265572.6 |
| query_threshold_breach | Hierarchical | 88466.3 | 88466.3 | 265572.6 |
| query_anomalies | Hierarchical | 2768868.6 | 2768868.6 | 265572.6 |
| query_latest_single | Hierarchical | 0.5 | 0.5 | 265572.6 |
| query_latest_zone | Hierarchical | 43.9 | 43.9 | 265572.6 |
| query_avg_window | Hierarchical | 2594.4 | 2594.4 | 265572.6 |
| query_avg_zone_type | Hierarchical | 80897.7 | 80897.7 | 265572.6 |
| query_threshold_breach | Hierarchical | 102215.0 | 102215.0 | 265572.6 |
| query_anomalies | Hierarchical | 2709996.9 | 2709996.9 | 265572.6 |
| query_latest_single | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 56.5 | 56.5 | 14.1 |
| query_anomalies | RingBuffer | 66.8 | 66.8 | 14.1 |
| query_threshold_breach | RingBuffer | 19.7 | 19.7 | 14.1 |
| query_spatial_radius | RingBuffer | 28.2 | 28.2 | 14.1 |
| query_latest_single | RingBuffer | 0.6 | 0.6 | 14.1 |
| query_latest_zone | RingBuffer | 53.1 | 53.1 | 14.1 |
| query_avg_window | RingBuffer | 35.7 | 35.7 | 14.1 |
| query_avg_zone_type | RingBuffer | 56.2 | 56.2 | 14.1 |
| query_threshold_breach | RingBuffer | 20.0 | 20.0 | 14.1 |
| query_anomalies | RingBuffer | 94.5 | 94.5 | 14.1 |
| query_latest_single | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_latest_zone | RingBuffer | 44.0 | 44.0 | 14.1 |
| query_avg_window | RingBuffer | 35.2 | 35.2 | 14.1 |
| query_avg_zone_type | RingBuffer | 56.3 | 56.3 | 14.1 |
| query_threshold_breach | RingBuffer | 19.3 | 19.3 | 14.1 |
| query_latest_single | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_latest_zone | RingBuffer | 57.7 | 57.7 | 14.1 |
| query_avg_zone_type | RingBuffer | 56.1 | 56.1 | 14.1 |
| query_zone_hierarchy | RingBuffer | 12.4 | 12.4 | 14.1 |
| query_spatial_radius | RingBuffer | 42.5 | 42.5 | 14.1 |
| query_latest_single | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_latest_zone | RingBuffer | 41.9 | 41.9 | 14.1 |
| query_avg_window | RingBuffer | 33.1 | 33.1 | 14.1 |
| query_avg_zone_type | RingBuffer | 54.8 | 54.8 | 14.1 |
| query_threshold_breach | RingBuffer | 18.7 | 18.7 | 14.1 |
| query_anomalies | RingBuffer | 59.4 | 59.4 | 14.1 |
| query_latest_single | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_latest_zone | RingBuffer | 49.7 | 49.7 | 14.1 |
| query_avg_window | RingBuffer | 38.4 | 38.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 55.5 | 55.5 | 14.1 |
| query_threshold_breach | RingBuffer | 18.6 | 18.6 | 14.1 |
| query_anomalies | RingBuffer | 68.3 | 68.3 | 14.1 |
| query_latest_single | Lake | 30289.1 | 30289.1 | 124569.7 |
| query_avg_zone_type | Lake | 75999.8 | 75999.8 | 124569.7 |
| query_daily_zone_rollup | Lake | 113780.7 | 113780.7 | 124569.7 |
| query_anomalies | Lake | 2757788.6 | 2757788.6 | 124569.7 |
| query_threshold_breach | Lake | 84511.0 | 84511.0 | 124569.7 |
| query_spatial_radius | Lake | 24.2 | 24.2 | 124569.7 |
| query_latest_single | Lake | 25654.2 | 25654.2 | 124569.7 |
| query_latest_zone | Lake | 30802.9 | 30802.9 | 124569.7 |
| query_avg_window | Lake | 58693.9 | 58693.9 | 124569.7 |
| query_avg_zone_type | Lake | 94694.3 | 94694.3 | 124569.7 |
| query_hourly_rollup | Lake | 51693.6 | 51693.6 | 124569.7 |
| query_daily_zone_rollup | Lake | 138269.3 | 138269.3 | 124569.7 |
| query_threshold_breach | Lake | 106907.5 | 106907.5 | 124569.7 |
| query_anomalies | Lake | 2729625.7 | 2729625.7 | 124569.7 |
| query_latest_single | Lake | 33386.8 | 33386.8 | 124569.7 |
| query_latest_zone | Lake | 27956.8 | 27956.8 | 124569.7 |
| query_avg_window | Lake | 56798.5 | 56798.5 | 124569.7 |
| query_avg_zone_type | Lake | 79950.8 | 79950.8 | 124569.7 |
| query_daily_zone_rollup | Lake | 101696.5 | 101696.5 | 124569.7 |
| query_threshold_breach | Lake | 90160.9 | 90160.9 | 124569.7 |
| query_latest_single | Lake | 36494.1 | 36494.1 | 124569.7 |
| query_latest_zone | Lake | 35702.6 | 35702.6 | 124569.7 |
| query_avg_zone_type | Lake | 84740.8 | 84740.8 | 124569.7 |
| query_daily_zone_rollup | Lake | 125254.3 | 125254.3 | 124569.7 |
| query_zone_hierarchy | Lake | 13.5 | 13.5 | 124569.7 |
| query_spatial_radius | Lake | 29.7 | 29.7 | 124569.7 |
| query_latest_single | Lake | 31441.7 | 31441.7 | 124569.7 |
| query_latest_zone | Lake | 28749.3 | 28749.3 | 124569.7 |
| query_avg_window | Lake | 63371.9 | 63371.9 | 124569.7 |
| query_avg_zone_type | Lake | 93714.7 | 93714.7 | 124569.7 |
| query_threshold_breach | Lake | 77086.0 | 77086.0 | 124569.7 |
| query_anomalies | Lake | 2808494.6 | 2808494.6 | 124569.7 |
| query_latest_single | Lake | 48151.2 | 48151.2 | 124569.7 |
| query_latest_zone | Lake | 32856.2 | 32856.2 | 124569.7 |
| query_avg_window | Lake | 67872.6 | 67872.6 | 124569.7 |
| query_avg_zone_type | Lake | 83389.7 | 83389.7 | 124569.7 |
| query_threshold_breach | Lake | 99513.4 | 99513.4 | 124569.7 |
| query_anomalies | Lake | 2752453.8 | 2752453.8 | 124569.7 |

See `schematic.svg` in this directory for a floor-by-floor map of placed sensors.
## Cost estimate (cloud-equivalent)

Pricing: **$1200/TB-year** (storage) + **$5.00/M queries** (compute). Workload: **30000000 queries/year**. Sources: public cloud pricing pages, mid-2026 — disclosed defaults, not vendor-specific bills. Absolute numbers are approximate (±2×); relative rankings are reliable (CLAUDE.md §6).

### Per-backend annual cost

| Backend | Storage (GB) | Storage $/yr | Query $/yr | **Total $/yr** |
|---|---:|---:|---:|---:|
| RingBuffer | 0.0 | $0 | $150 | **$150** |
| Columnar | 0.1 | $0 | $150 | **$150** |
| TimeSeries | 0.1 | $0 | $150 | **$150** |
| Lake | 0.1 | $0 | $150 | **$150** |
| Hierarchical | 0.3 | $0 | $150 | **$150** |

### Naive vs optimised

| Strategy | Annual cost |
|---|---:|
| Naive (all 5 backends simultaneously) | $751/yr |
| **Optimised** (Columnar + Columnar) | **$150/yr** |

**Savings: $601/yr (80%)** by running only the recommended backends instead of all of them.


## Latency vs Building Age (Growth Curve)

Each row is one query's median latency at one checkpoint in the building's simulated lifetime — from day 1 (near-empty) to steady state (retention-full, actively evicting). This shows whether a backend's query latency is constant (O(1) access) or grows with data volume.

| Checkpoint | Day | Backend | Query | Median µs | Live readings | Memory (MB) |
|---|---:|---|---|---:|---:|---:|
| day 1 | 1 | TimeSeries | query_latest_single | 1.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 184.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 257.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 311.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 37.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_spatial_radius | 34.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 45.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 128.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 180.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_hourly_rollup | 285.8 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 331.6 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 51.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 314.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 210.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 301.6 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 405.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 333.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 41.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 1.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 68.0 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 213.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 311.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_zone_hierarchy | 13.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_spatial_radius | 45.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 1.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 47.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 145.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 212.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 50.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 317.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 1.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 44.8 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 138.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 185.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 38.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 370.7 | 8713 | 0.3 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.7 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 364.0 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 788.7 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_anomalies | 2494.1 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 168.4 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_spatial_radius | 41.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_single | 1.4 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_zone | 73.7 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_window | 189.9 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 437.4 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_hourly_rollup | 760.6 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 1527.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 249.9 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_anomalies | 3455.3 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_zone | 47.1 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_window | 155.0 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 559.2 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 830.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 177.3 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.7 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_zone | 47.3 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 385.0 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 1067.9 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_zone_hierarchy | 18.1 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_spatial_radius | 60.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_single | 1.0 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_zone | 46.6 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_window | 231.2 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 410.1 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 159.2 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_anomalies | 2434.4 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_single | 1.0 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_latest_zone | 48.2 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_window | 174.5 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 416.1 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 159.8 | 60917 | 1.4 |
| week 1 | 7 | TimeSeries | query_anomalies | 2628.8 | 60917 | 1.4 |
| month 1 | 30 | TimeSeries | query_latest_single | 1.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 1398.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 3154.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 15217.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 1187.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_spatial_radius | 30.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 1.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 56.3 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 156.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 1340.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_hourly_rollup | 558.4 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 3270.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 1154.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 16065.4 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 59.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 169.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 1432.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 3298.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 1185.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 46.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 1309.3 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 3217.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_zone_hierarchy | 16.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_spatial_radius | 42.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 46.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 183.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 2021.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 1696.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 15224.4 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 47.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 157.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 1344.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 1131.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 14073.3 | 261188 | 7.1 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 3619.8 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 15607.1 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_anomalies | 73391.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 5404.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_spatial_radius | 45.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_single | 1.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_zone | 89.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_window | 213.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 5526.8 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_hourly_rollup | 815.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 10292.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 3749.0 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_anomalies | 61562.5 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_single | 1.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_zone | 76.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_window | 231.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 5828.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 10720.9 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 4078.4 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.8 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_zone | 50.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 3972.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 10044.4 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_zone_hierarchy | 14.1 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_spatial_radius | 38.9 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_single | 1.0 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_zone | 49.1 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_window | 168.3 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 3770.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 3821.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_anomalies | 51702.2 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.7 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_latest_zone | 43.5 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_window | 142.1 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 3381.9 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 3286.5 | 783641 | 24.0 |
| month 3 | 90 | TimeSeries | query_anomalies | 52295.5 | 783641 | 24.0 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.8 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 6159.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 17400.5 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_anomalies | 129738.4 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 7935.5 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_spatial_radius | 30.8 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.6 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_zone | 61.3 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_window | 147.4 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 7339.0 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_hourly_rollup | 608.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 17188.8 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 7972.3 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_anomalies | 112043.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.6 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_zone | 40.3 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_window | 127.9 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 5890.0 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 21910.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 7900.5 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.7 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_zone | 49.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 9531.2 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 21844.8 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_zone_hierarchy | 15.8 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_spatial_radius | 34.7 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_single | 1.4 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_zone | 116.0 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_window | 157.5 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 6837.4 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 8569.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_anomalies | 126203.6 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.7 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_latest_zone | 46.2 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_window | 142.2 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 5770.1 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 6899.0 | 1578597 | 54.1 |
| month 6 | 182 | TimeSeries | query_anomalies | 117969.1 | 1578597 | 54.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.7 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 12714.1 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 34105.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_anomalies | 404623.2 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 25747.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_spatial_radius | 42.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 1.0 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_zone | 91.7 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_window | 270.6 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 15571.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_hourly_rollup | 597.7 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 43677.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 19537.8 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_anomalies | 268475.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.7 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_zone | 45.0 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_window | 171.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 14167.3 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 35329.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 14728.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.6 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_zone | 45.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 12452.0 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 33368.9 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_zone_hierarchy | 12.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_spatial_radius | 27.8 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.7 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_zone | 51.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_window | 135.0 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 11805.5 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 15224.8 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_anomalies | 277376.2 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.8 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_latest_zone | 52.0 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_window | 169.8 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 14540.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 17882.4 | 3159715 | 81.1 |
| year 1 | 365 | TimeSeries | query_anomalies | 258193.2 | 3159715 | 81.1 |
| year 2 | 730 | TimeSeries | query_latest_single | 1.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 28374.9 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 42901.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_anomalies | 577918.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 29182.3 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_spatial_radius | 47.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_single | 1.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_zone | 83.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_window | 244.6 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 23999.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_hourly_rollup | 545.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 64044.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 28549.2 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_anomalies | 602880.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_zone | 45.8 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_window | 146.9 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 26934.4 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 41725.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 29890.4 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_single | 1.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_zone | 72.3 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 24864.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 41116.5 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_zone_hierarchy | 12.2 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_spatial_radius | 27.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_zone | 51.6 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_window | 146.8 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 28323.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 27990.3 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_anomalies | 582716.9 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_latest_zone | 45.1 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_window | 141.7 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 25397.3 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 28065.3 | 3627868 | 121.7 |
| year 2 | 730 | TimeSeries | query_anomalies | 573196.0 | 3627868 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.9 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 46489.9 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 64276.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_anomalies | 906796.9 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 41179.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_spatial_radius | 29.3 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 65.1 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_window | 140.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 33562.4 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_hourly_rollup | 524.1 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 62641.9 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 36132.9 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_anomalies | 947345.6 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 1.4 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 76.6 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_window | 211.0 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 45473.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 55441.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 43290.6 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 47.4 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 33272.2 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 59204.0 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_zone_hierarchy | 12.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_spatial_radius | 28.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 1.2 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 55.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_window | 147.4 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 37017.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 40406.3 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_anomalies | 939548.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.7 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 47.8 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_window | 147.1 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 37112.4 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 37018.6 | 3838073 | 121.7 |
| year 3 | 1095 | TimeSeries | query_anomalies | 894281.3 | 3838073 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.6 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 50280.2 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 86398.1 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_anomalies | 1299758.9 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 50543.2 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_spatial_radius | 26.6 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.6 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 56.7 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_window | 126.8 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 50196.3 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_hourly_rollup | 573.2 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 77449.9 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 57687.6 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_anomalies | 1233940.4 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.5 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 39.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_window | 122.1 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 59188.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 67964.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 47172.8 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.7 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 38.8 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 49892.8 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 68139.3 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_zone_hierarchy | 17.3 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_spatial_radius | 29.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.6 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 112.2 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_window | 162.8 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 61196.5 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 55646.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_anomalies | 1200014.2 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.5 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 40.7 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_window | 125.9 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 59768.9 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 55123.0 | 4048432 | 121.7 |
| year 4 | 1460 | TimeSeries | query_anomalies | 1172216.9 | 4048432 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 1.4 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 53285.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 79555.6 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1511752.1 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 59310.1 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_spatial_radius | 27.3 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.9 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 81.3 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_window | 173.4 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 61202.3 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_hourly_rollup | 593.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 84745.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 56794.9 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1570410.2 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.7 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 47.9 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_window | 153.7 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 57772.6 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 82480.5 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 82459.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 1.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 75.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 61377.9 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 76891.7 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_zone_hierarchy | 11.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_spatial_radius | 25.0 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.5 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 48.9 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_window | 127.6 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 59048.2 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 62898.8 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1590844.4 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.8 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 55.2 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_window | 218.6 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 63613.1 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 59267.7 | 4258844 | 121.7 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1461196.3 | 4258844 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.7 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 68843.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 92695.5 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_anomalies | 2330032.5 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 82241.0 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_spatial_radius | 26.4 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 53.0 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_window | 126.2 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 88787.0 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_hourly_rollup | 656.2 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 105144.1 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 77428.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_anomalies | 2292535.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.8 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 47.4 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_window | 149.8 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 74465.3 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 98507.9 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 72072.4 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 39.2 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 74668.7 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 100270.3 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_zone_hierarchy | 13.2 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_spatial_radius | 25.4 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 65.1 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_window | 141.7 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 76063.0 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 74827.6 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_anomalies | 2354821.2 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_single | 1.0 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 46.8 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_window | 147.7 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 71519.9 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 75897.3 | 4468874 | 121.7 |
| year 6 | 2190 | TimeSeries | query_anomalies | 2197483.0 | 4468874 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 78835.5 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 106419.2 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_anomalies | 2696268.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 83219.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_spatial_radius | 28.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 77.5 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_window | 157.0 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 78032.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_hourly_rollup | 535.0 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 100450.2 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 84161.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_anomalies | 2535486.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 47.4 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_window | 149.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 84562.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 102996.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 86571.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 47.9 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 79161.0 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 94031.2 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_zone_hierarchy | 11.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_spatial_radius | 28.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.9 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 55.4 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_window | 127.9 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 76793.4 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 84944.5 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_anomalies | 2677986.8 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.7 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 49.6 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_window | 174.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 75044.5 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 85933.3 | 4679292 | 121.7 |
| year 7 | 2555 | TimeSeries | query_anomalies | 2625795.1 | 4679292 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 79395.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 97800.8 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_anomalies | 2589785.3 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 85269.4 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_spatial_radius | 25.4 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.6 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_zone | 38.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_window | 120.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 73477.6 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_hourly_rollup | 504.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 101067.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 91154.0 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_anomalies | 2648533.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_zone | 47.4 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_window | 150.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 71292.2 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 100840.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 82850.9 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_zone | 43.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 78859.9 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 99562.6 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_zone_hierarchy | 10.9 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_spatial_radius | 24.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.6 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_zone | 47.2 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_window | 120.7 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 76315.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 81830.9 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_anomalies | 2661905.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_single | 1.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_latest_zone | 54.8 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_window | 229.1 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 81099.4 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 99303.5 | 4679221 | 121.7 |
| steady state | 2682 | TimeSeries | query_anomalies | 2527820.3 | 4679221 | 121.7 |
| day 1 | 1 | Columnar | query_latest_single | 0.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 236.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 373.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 419.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 152.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_spatial_radius | 64.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 54.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 207.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 227.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_hourly_rollup | 293.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 374.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 51.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 461.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 1.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 64.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 248.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 259.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 378.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 47.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 63.8 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 214.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 361.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_zone_hierarchy | 17.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_spatial_radius | 43.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 1.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 66.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 216.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 243.8 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 40.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 486.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 49.8 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 200.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 247.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 56.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 407.8 | 8713 | 0.1 |
| week 1 | 7 | Columnar | query_latest_single | 0.6 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 351.9 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 711.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_anomalies | 2148.8 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_threshold_breach | 135.7 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_spatial_radius | 25.4 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_single | 0.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_zone | 45.2 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_window | 126.1 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 332.4 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_hourly_rollup | 488.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 687.9 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_threshold_breach | 135.4 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_anomalies | 2113.2 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_single | 0.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_zone | 39.7 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_window | 119.9 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 331.0 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 690.0 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_threshold_breach | 133.6 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_single | 0.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_zone | 40.2 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 348.6 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 703.1 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_zone_hierarchy | 10.8 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_spatial_radius | 36.6 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_single | 0.4 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_zone | 39.2 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_window | 119.8 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 325.7 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_threshold_breach | 138.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_anomalies | 1984.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_single | 0.5 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_latest_zone | 38.3 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_window | 115.4 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_avg_zone_type | 319.8 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_threshold_breach | 128.2 | 60917 | 0.6 |
| week 1 | 7 | Columnar | query_anomalies | 2002.6 | 60917 | 0.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1372.8 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 3277.4 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_anomalies | 14767.2 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_threshold_breach | 1324.8 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_spatial_radius | 30.2 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_single | 0.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_zone | 117.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_window | 140.3 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1467.8 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_hourly_rollup | 581.2 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 3355.3 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_threshold_breach | 1179.7 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_anomalies | 13998.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_single | 0.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_zone | 43.1 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_window | 135.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1316.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 2976.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_threshold_breach | 1052.3 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_single | 0.9 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_zone | 43.8 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1355.9 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 2921.3 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_zone_hierarchy | 19.1 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_spatial_radius | 27.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_single | 0.8 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_zone | 42.4 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_window | 160.6 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1245.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_threshold_breach | 1062.2 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_anomalies | 12684.4 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_single | 0.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_latest_zone | 40.3 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_window | 123.1 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_avg_zone_type | 1661.2 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_threshold_breach | 1070.5 | 261188 | 3.2 |
| month 1 | 30 | Columnar | query_anomalies | 14334.3 | 261188 | 3.2 |
| month 3 | 90 | Columnar | query_latest_single | 1.0 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 4004.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 15420.4 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_anomalies | 63451.3 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_threshold_breach | 4378.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_spatial_radius | 31.9 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_single | 0.9 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_zone | 65.8 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_window | 158.4 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 4936.1 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_hourly_rollup | 980.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 8997.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_threshold_breach | 3644.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_anomalies | 55352.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_single | 0.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_zone | 46.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_window | 143.0 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 3907.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 9095.2 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_threshold_breach | 3699.9 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_single | 0.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_zone | 60.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 12399.4 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 8774.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_zone_hierarchy | 12.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_spatial_radius | 28.1 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_single | 0.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_zone | 44.2 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_window | 159.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 3434.0 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_threshold_breach | 3458.7 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_anomalies | 53577.5 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_single | 0.6 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_latest_zone | 47.2 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_window | 144.9 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_avg_zone_type | 5736.3 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_threshold_breach | 3654.8 | 783641 | 10.1 |
| month 3 | 90 | Columnar | query_anomalies | 50996.9 | 783641 | 10.1 |
| month 6 | 182 | Columnar | query_latest_single | 0.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 6719.8 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 18560.8 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_anomalies | 118505.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_threshold_breach | 6761.3 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_spatial_radius | 27.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_single | 0.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_zone | 55.0 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_window | 133.5 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 5496.8 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_hourly_rollup | 533.5 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 16038.2 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_threshold_breach | 6327.3 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_anomalies | 113178.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_single | 0.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_zone | 47.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_window | 141.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 6897.2 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 17806.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_threshold_breach | 7308.2 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_single | 0.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_zone | 46.9 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 6436.4 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 27767.5 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_zone_hierarchy | 18.7 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_spatial_radius | 42.3 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_single | 1.1 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_zone | 78.9 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_window | 220.1 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 6265.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_threshold_breach | 9277.9 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_anomalies | 113288.2 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_single | 0.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_latest_zone | 47.1 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_window | 169.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_avg_zone_type | 7082.5 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_threshold_breach | 7749.6 | 1578597 | 16.2 |
| month 6 | 182 | Columnar | query_anomalies | 123221.6 | 1578597 | 16.2 |
| year 1 | 365 | Columnar | query_latest_single | 0.7 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 13366.5 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 32598.5 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_anomalies | 403626.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_threshold_breach | 16950.5 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_spatial_radius | 34.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_single | 1.1 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_zone | 84.7 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_window | 159.1 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 14048.5 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_hourly_rollup | 689.8 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 33166.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_threshold_breach | 14010.5 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_anomalies | 275666.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_single | 0.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_zone | 46.7 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_window | 140.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 12735.4 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 36497.8 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_threshold_breach | 14326.2 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_single | 0.7 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_zone | 44.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 12089.1 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 34765.8 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_zone_hierarchy | 13.3 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_spatial_radius | 29.4 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_single | 0.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_zone | 55.2 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_window | 143.1 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 14001.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_threshold_breach | 15712.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_anomalies | 263830.3 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_single | 0.6 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_latest_zone | 46.9 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_window | 147.3 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_avg_zone_type | 17478.2 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_threshold_breach | 14995.7 | 3159715 | 36.1 |
| year 1 | 365 | Columnar | query_anomalies | 263096.3 | 3159715 | 36.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 30997.3 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 48911.3 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_anomalies | 604751.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 30799.0 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_spatial_radius | 31.8 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.6 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_zone | 65.1 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_window | 152.1 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 25313.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_hourly_rollup | 589.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 43906.2 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 28167.5 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_anomalies | 570459.1 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_single | 1.6 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_zone | 54.8 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_window | 164.3 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 25940.5 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 42883.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 26425.3 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.5 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_zone | 42.8 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 26004.6 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 45027.4 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_zone_hierarchy | 13.4 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_spatial_radius | 26.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.5 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_zone | 50.2 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_window | 125.8 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 23787.2 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 27843.3 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_anomalies | 588297.4 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.6 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_latest_zone | 62.2 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_window | 132.7 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 32901.0 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 35425.8 | 3627868 | 51.1 |
| year 2 | 730 | Columnar | query_anomalies | 514689.7 | 3627868 | 51.1 |
| year 3 | 1095 | Columnar | query_latest_single | 0.7 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 37448.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 55657.8 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_anomalies | 952687.4 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 38233.8 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_spatial_radius | 26.8 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.5 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 61.1 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_window | 129.9 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 41895.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_hourly_rollup | 858.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 61690.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 34929.7 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_anomalies | 884765.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 47.1 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_window | 156.9 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 38067.5 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 55294.2 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 41770.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 47.4 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 33838.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 57334.3 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_zone_hierarchy | 12.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_spatial_radius | 27.4 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.5 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 52.3 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_window | 130.9 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 40370.6 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 38551.9 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_anomalies | 900555.5 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.9 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 69.5 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_window | 217.0 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 40322.1 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 46351.7 | 3838073 | 51.4 |
| year 3 | 1095 | Columnar | query_anomalies | 946389.6 | 3838073 | 51.4 |
| year 4 | 1460 | Columnar | query_latest_single | 0.6 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 49147.6 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 80851.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_anomalies | 1304673.3 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_threshold_breach | 47893.0 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_spatial_radius | 25.2 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_single | 0.7 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_zone | 55.2 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_window | 138.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 51810.6 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_hourly_rollup | 568.4 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 73940.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_threshold_breach | 45969.8 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_anomalies | 1157266.2 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_single | 0.6 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_zone | 43.3 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_window | 132.5 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 56214.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 65629.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_threshold_breach | 59098.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_single | 0.5 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_zone | 39.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 61202.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 67401.3 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_zone_hierarchy | 11.0 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_spatial_radius | 24.7 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_single | 0.5 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_zone | 48.7 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_window | 119.8 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 53910.7 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_threshold_breach | 47576.1 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_anomalies | 1222115.4 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_single | 0.4 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_latest_zone | 36.5 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_window | 113.6 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 52335.9 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_threshold_breach | 50436.5 | 4048432 | 53.8 |
| year 4 | 1460 | Columnar | query_anomalies | 1169302.9 | 4048432 | 53.8 |
| year 5 | 1825 | Columnar | query_latest_single | 0.7 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 73406.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 79498.1 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_anomalies | 1464743.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_threshold_breach | 59904.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_spatial_radius | 26.2 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_single | 0.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_zone | 59.8 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_window | 123.8 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 57848.8 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_hourly_rollup | 568.5 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 80776.8 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_threshold_breach | 61694.8 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_anomalies | 1563495.0 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_single | 1.1 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_zone | 62.3 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_window | 185.7 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 59508.2 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 73879.0 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_threshold_breach | 55297.3 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_single | 0.5 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_zone | 38.9 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 58681.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 73529.0 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_zone_hierarchy | 18.3 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_spatial_radius | 30.4 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_single | 0.6 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_zone | 65.7 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_window | 145.2 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 69851.5 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_threshold_breach | 65375.9 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_anomalies | 1488757.7 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_single | 0.6 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_latest_zone | 47.3 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_window | 152.1 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 56709.1 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_threshold_breach | 59285.3 | 4258844 | 54.1 |
| year 5 | 1825 | Columnar | query_anomalies | 1505279.0 | 4258844 | 54.1 |
| year 6 | 2190 | Columnar | query_latest_single | 0.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 80021.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 103740.8 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_anomalies | 2342062.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_threshold_breach | 91002.0 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_spatial_radius | 36.8 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_single | 1.1 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_zone | 79.1 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_window | 184.5 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 96206.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_hourly_rollup | 620.4 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 115711.4 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_threshold_breach | 81155.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_anomalies | 2339519.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_single | 0.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_zone | 47.3 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_window | 139.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 75936.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 100636.8 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_threshold_breach | 78166.3 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_single | 0.5 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_zone | 38.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 76937.9 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 105733.5 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_zone_hierarchy | 11.4 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_spatial_radius | 25.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_single | 0.5 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_zone | 54.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_window | 121.7 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 70592.0 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_threshold_breach | 72990.0 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_anomalies | 2329761.0 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_single | 0.6 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_latest_zone | 46.3 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_window | 125.4 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 80704.5 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_threshold_breach | 79857.3 | 4468874 | 54.4 |
| year 6 | 2190 | Columnar | query_anomalies | 2324300.4 | 4468874 | 54.4 |
| year 7 | 2555 | Columnar | query_latest_single | 0.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 92966.6 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 113735.2 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_anomalies | 2197947.7 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_threshold_breach | 75210.1 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_spatial_radius | 27.3 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_single | 0.5 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_zone | 56.3 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_window | 118.8 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 78320.4 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_hourly_rollup | 496.1 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 117670.0 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_threshold_breach | 94165.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_anomalies | 2170947.6 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_single | 0.6 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_zone | 41.0 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_window | 126.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 72422.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 94782.7 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_threshold_breach | 88399.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_single | 0.5 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_zone | 39.3 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 76545.3 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 99265.4 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_zone_hierarchy | 12.1 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_spatial_radius | 27.4 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_single | 0.5 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_zone | 59.2 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_window | 135.8 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 73912.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_threshold_breach | 76809.1 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_anomalies | 2267008.2 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_single | 0.5 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_latest_zone | 62.0 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_window | 150.9 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 73835.6 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_threshold_breach | 83831.3 | 4679292 | 54.7 |
| year 7 | 2555 | Columnar | query_anomalies | 2241683.2 | 4679292 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 69876.9 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 92301.9 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_anomalies | 2189763.8 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_threshold_breach | 84029.8 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_spatial_radius | 25.9 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_zone | 45.7 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_window | 126.2 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 74579.0 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_hourly_rollup | 586.3 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 91128.0 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_threshold_breach | 83491.3 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_anomalies | 2294254.9 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_zone | 43.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_window | 132.6 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 71065.2 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 93620.2 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_threshold_breach | 81921.4 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_zone | 36.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 78336.3 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 97523.4 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_zone_hierarchy | 12.3 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_spatial_radius | 27.8 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_zone | 58.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_window | 130.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 75857.2 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_threshold_breach | 78510.1 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_anomalies | 2245388.4 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_single | 0.5 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_latest_zone | 43.4 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_window | 128.8 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_avg_zone_type | 74574.4 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_threshold_breach | 94365.9 | 4679221 | 54.7 |
| steady state | 2682 | Columnar | query_anomalies | 2308387.0 | 4679221 | 54.7 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 151.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 247.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 281.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 35.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_spatial_radius | 31.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 44.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 104.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 150.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_hourly_rollup | 237.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 231.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 34.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 275.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 52.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 96.2 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 177.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 260.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 34.9 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 44.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 193.9 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 318.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_zone_hierarchy | 12.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_spatial_radius | 26.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 39.9 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 124.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 189.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 39.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 346.4 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 41.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 106.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 197.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 36.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 519.6 | 8713 | 0.5 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 330.9 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 711.9 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 2169.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 161.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_spatial_radius | 27.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 46.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 104.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 361.7 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_hourly_rollup | 442.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 741.9 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 145.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 2355.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 40.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 120.7 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 343.2 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 733.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 146.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 49.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 356.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 756.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_zone_hierarchy | 11.9 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_spatial_radius | 41.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 43.7 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 101.4 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 414.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 153.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 2135.7 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 38.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 97.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 331.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 138.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 2059.0 | 60917 | 3.4 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1250.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 2636.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 12004.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 940.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_spatial_radius | 23.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 40.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 107.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1065.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_hourly_rollup | 415.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 2461.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 999.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 11952.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 34.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 109.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1119.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 2638.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 980.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 35.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1210.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 2783.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_zone_hierarchy | 15.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_spatial_radius | 25.2 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 36.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 113.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1220.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 1093.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 13673.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 40.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 125.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1370.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 1071.2 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 13728.0 | 261188 | 15.0 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.8 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3359.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 8355.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 45412.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 3244.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_spatial_radius | 24.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 44.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 175.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3053.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_hourly_rollup | 465.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 7150.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 3029.8 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 47690.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 37.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 169.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3503.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 8369.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 3345.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 40.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3316.8 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 8152.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_zone_hierarchy | 11.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_spatial_radius | 25.2 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 1.2 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 36.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 170.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3141.9 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 3114.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 43500.2 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 37.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 173.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 3358.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 4186.9 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 43084.5 | 783641 | 43.5 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 5109.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 14902.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 95597.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 6990.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_spatial_radius | 29.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 54.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 272.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 6167.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_hourly_rollup | 641.8 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 16352.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 6924.9 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 104945.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 34.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 227.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 5289.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 14449.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 6025.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 34.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 5223.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 16085.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_zone_hierarchy | 12.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_spatial_radius | 27.4 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 48.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 277.9 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 5582.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 7604.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 101709.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 38.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 266.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 5680.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 6840.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 115221.7 | 1578597 | 79.1 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 10910.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 33299.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 234817.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 13305.4 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_spatial_radius | 27.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.4 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 53.8 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 441.8 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 12270.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_hourly_rollup | 857.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 31058.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 13011.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 311873.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 1.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 70.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 872.8 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 19644.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 34913.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 13616.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 38.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 11087.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 32542.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_zone_hierarchy | 11.4 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_spatial_radius | 25.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 44.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 405.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 12082.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 17936.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 222241.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 37.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 411.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 11881.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 14231.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 225399.1 | 3159715 | 179.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 24869.0 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 40462.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 471906.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 25965.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_spatial_radius | 26.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 58.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 861.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 23154.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_hourly_rollup | 1135.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 38689.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 25367.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 466202.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 36.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 683.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 22720.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 42037.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 23087.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 34.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 23477.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 47709.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_zone_hierarchy | 11.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_spatial_radius | 25.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 45.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 914.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 21531.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 23369.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 502323.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 36.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 689.0 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 25707.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 38314.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 494735.4 | 3627868 | 186.4 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 34305.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 62806.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 742474.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 38122.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_spatial_radius | 27.2 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 57.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 1077.7 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 30103.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_hourly_rollup | 1258.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 54847.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 34736.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 743536.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 36.2 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 995.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 35418.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 48280.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 38552.2 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 38.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 30942.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 55116.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_zone_hierarchy | 12.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_spatial_radius | 27.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 50.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 1093.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 42964.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 33431.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 731826.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 34.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 958.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 34530.2 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 34160.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 740194.6 | 3838073 | 235.6 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 54849.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 67156.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 1105883.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 48451.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_spatial_radius | 23.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.4 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 47.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 1284.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 47090.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_hourly_rollup | 1824.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 60304.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 50718.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 975302.0 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 34.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 1183.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 46979.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 75313.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 45775.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 33.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 50836.1 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 63137.0 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_zone_hierarchy | 10.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_spatial_radius | 22.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.4 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 40.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 1290.1 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 51582.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 46575.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 1105289.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 44.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 1278.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 53438.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 53235.9 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 1017333.6 | 4048432 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 54000.8 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 64905.7 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 1317149.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 56859.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_spatial_radius | 28.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 1.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 56.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 1810.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 47862.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_hourly_rollup | 1831.2 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 75462.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 53923.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 1306879.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 36.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 1580.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 54452.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 80629.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 53447.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 34.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 52144.5 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 74249.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_zone_hierarchy | 10.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_spatial_radius | 24.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 43.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 1645.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 51825.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 53909.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 1336797.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 42.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 1808.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 56860.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 52698.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 1493695.4 | 4258844 | 245.1 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 77747.0 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 107531.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 2362200.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 80778.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_spatial_radius | 29.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 60.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 2427.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 69490.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_hourly_rollup | 2739.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 103466.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 73703.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 2277977.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 42.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 2266.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 72533.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 106021.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 79704.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 34.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 68465.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 101417.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_zone_hierarchy | 11.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_spatial_radius | 25.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 44.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 1993.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 81151.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 74095.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 2276390.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 38.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 2522.0 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 88564.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 75417.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 2350792.9 | 4468874 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.5 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 76764.0 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 105655.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 2212592.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 73872.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_spatial_radius | 24.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.4 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 48.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 2093.0 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 97691.0 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_hourly_rollup | 3026.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 101805.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 83086.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 2395935.5 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 44.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 2855.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 84284.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 112557.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 88079.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 42.4 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 72613.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 92279.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_zone_hierarchy | 15.2 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_spatial_radius | 25.4 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.9 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 66.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 2522.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 78646.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 88093.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 2296905.5 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.9 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 60.9 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 4064.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 98384.0 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 87581.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 2255234.8 | 4679292 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 82973.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 101023.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 2658626.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 96103.5 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_spatial_radius | 29.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 60.4 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 2448.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 110993.9 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_hourly_rollup | 5160.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 95424.4 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 94922.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 2707716.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 1.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 71.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 4194.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 86674.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 112887.4 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 89565.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.5 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 37.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 74311.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 92758.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_zone_hierarchy | 12.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_spatial_radius | 28.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.5 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 53.5 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 2571.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 99778.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 88466.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 2768868.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.5 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 43.9 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 2594.4 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 80897.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 102215.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 2709996.9 | 4679221 | 259.3 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 91.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 95.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 30.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_spatial_radius | 46.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.9 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 77.3 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 57.9 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 95.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 30.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 96.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 72.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 56.6 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 99.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 31.2 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.9 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 77.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 93.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_zone_hierarchy | 19.7 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_spatial_radius | 55.7 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 1.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 71.9 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 57.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 93.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 22.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 65.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 1.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 51.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 37.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 71.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 20.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 72.0 | 384 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 83.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 91.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 28.0 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_spatial_radius | 42.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 65.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 51.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 87.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 27.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 107.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 71.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 51.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 85.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 27.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 1.9 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 86.2 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 84.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_zone_hierarchy | 25.0 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_spatial_radius | 28.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 63.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 46.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 57.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 19.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 73.7 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 52.2 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 32.9 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 59.9 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 27.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 74.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 46.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 58.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 16.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_spatial_radius | 23.7 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 35.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 27.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 52.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 15.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 48.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 38.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 27.1 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 56.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 15.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 35.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 46.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_zone_hierarchy | 10.1 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_spatial_radius | 22.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 48.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 26.9 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 48.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 15.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 100.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 57.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 43.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 75.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 23.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 77.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 1.0 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 57.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 72.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 19.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_spatial_radius | 28.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 44.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 47.6 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 59.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 20.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 88.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 46.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 35.1 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 61.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 24.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 58.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 56.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_zone_hierarchy | 12.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_spatial_radius | 30.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 43.7 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 33.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 57.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 19.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 63.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 51.9 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 34.0 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 56.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 21.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 68.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 51.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 53.6 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 18.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_spatial_radius | 25.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 39.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 34.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 50.8 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 17.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 59.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 39.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 31.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 52.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 17.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 38.8 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 50.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_zone_hierarchy | 11.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_spatial_radius | 25.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.6 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 42.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 32.9 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 53.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 17.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 54.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 38.9 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 30.9 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 50.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 34.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 56.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 61.9 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 61.7 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 25.6 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_spatial_radius | 30.6 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 47.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 44.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 62.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 21.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 57.7 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.6 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 50.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 36.7 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 65.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 20.7 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 53.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 69.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_zone_hierarchy | 13.6 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_spatial_radius | 32.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 53.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 36.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 75.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 20.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 58.7 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 46.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 34.6 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 61.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 20.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 54.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 53.0 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 51.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 24.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_spatial_radius | 27.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 47.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 31.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 56.2 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 23.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 62.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 40.2 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 34.7 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 52.9 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 18.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 40.9 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 58.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_zone_hierarchy | 14.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_spatial_radius | 26.2 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 40.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 31.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 58.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 17.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 60.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 53.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 31.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 54.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 18.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 64.7 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 54.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 60.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 18.7 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_spatial_radius | 27.8 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 49.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 32.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 54.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 23.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 66.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 42.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 32.6 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 54.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 25.6 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 42.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 57.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_zone_hierarchy | 12.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_spatial_radius | 27.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 42.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 32.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 54.8 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 19.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 66.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 42.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 32.6 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 56.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 18.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 58.8 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 58.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 62.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 19.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_spatial_radius | 28.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 52.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 33.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 56.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 19.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 65.8 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 66.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 35.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 59.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 35.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 45.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 62.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_zone_hierarchy | 13.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_spatial_radius | 40.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 46.1 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 35.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 58.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 24.1 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 69.8 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 46.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 37.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 59.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 20.1 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 64.2 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 51.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 59.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 18.2 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_spatial_radius | 26.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 1.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 40.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 31.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 52.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 19.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 68.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 40.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 31.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 53.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 18.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 53.1 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 51.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_zone_hierarchy | 11.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_spatial_radius | 26.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 41.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 30.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 52.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 21.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 55.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 46.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 31.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 53.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 18.1 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 62.6 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 57.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 68.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 19.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_spatial_radius | 37.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 44.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 34.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 56.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 19.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 75.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 44.2 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 33.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 61.7 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 19.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 63.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 57.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_zone_hierarchy | 12.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_spatial_radius | 28.2 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 1.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 57.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 40.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 55.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 19.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 58.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 57.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 32.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 54.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 18.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 70.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 94.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 84.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 25.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_spatial_radius | 43.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 1.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 87.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 57.8 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 96.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 30.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 119.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 81.2 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 54.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 92.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 47.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 62.8 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 123.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_zone_hierarchy | 21.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_spatial_radius | 51.9 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 74.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 59.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 96.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 32.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 114.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.9 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 67.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 58.8 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 99.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 31.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 120.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 56.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 66.8 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 19.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_spatial_radius | 28.2 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.6 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 53.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 35.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 56.2 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 20.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 94.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 44.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 35.2 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 56.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 19.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 57.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 56.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_zone_hierarchy | 12.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_spatial_radius | 42.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 41.9 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 33.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 54.8 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 18.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 59.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 49.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 38.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 55.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 18.6 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 68.3 | 390 | 0.0 |
| day 1 | 1 | Lake | query_latest_single | 72.9 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 184.0 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 338.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_anomalies | 344.8 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_threshold_breach | 47.3 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_spatial_radius | 39.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_single | 56.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_zone | 98.8 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_window | 248.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 180.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_hourly_rollup | 392.8 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 271.4 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_threshold_breach | 38.8 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_anomalies | 313.3 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_single | 51.8 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_zone | 98.9 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_window | 234.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 183.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 276.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_threshold_breach | 38.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_single | 51.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_zone | 99.7 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 174.7 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 266.9 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_zone_hierarchy | 13.1 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_spatial_radius | 29.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_single | 56.1 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_zone | 99.1 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_window | 224.2 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 174.1 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_threshold_breach | 38.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_anomalies | 319.5 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_single | 52.0 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_latest_zone | 165.3 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_window | 232.3 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_avg_zone_type | 186.6 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_threshold_breach | 41.9 | 8713 | 0.3 |
| day 1 | 1 | Lake | query_anomalies | 323.1 | 8713 | 0.3 |
| week 1 | 7 | Lake | query_latest_single | 478.4 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 620.6 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 817.3 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_anomalies | 2450.7 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_threshold_breach | 162.4 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_spatial_radius | 36.7 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_single | 423.1 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_zone | 458.0 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_window | 910.4 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 406.1 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_hourly_rollup | 1801.0 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 882.2 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_threshold_breach | 171.3 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_anomalies | 2527.9 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_single | 434.7 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_zone | 452.3 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_window | 911.0 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 407.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 857.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_threshold_breach | 180.2 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_single | 575.7 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_zone | 839.3 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 421.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 872.0 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_zone_hierarchy | 21.1 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_spatial_radius | 54.5 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_single | 439.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_zone | 486.4 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_window | 935.5 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 418.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_threshold_breach | 5273.1 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_anomalies | 2775.9 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_single | 456.8 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_latest_zone | 494.2 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_window | 990.6 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 478.3 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_threshold_breach | 187.7 | 60917 | 1.4 |
| week 1 | 7 | Lake | query_anomalies | 2843.5 | 60917 | 1.4 |
| month 1 | 30 | Lake | query_latest_single | 1732.2 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 1415.1 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 3291.5 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_anomalies | 15352.5 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_threshold_breach | 1182.3 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_spatial_radius | 30.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_single | 1708.2 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_zone | 1738.8 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_window | 3487.5 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 1427.4 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_hourly_rollup | 3933.5 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 3163.8 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_threshold_breach | 1108.2 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_anomalies | 13596.1 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_single | 1544.0 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_zone | 1597.0 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_window | 3178.9 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 1194.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 2672.2 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_threshold_breach | 951.7 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_single | 1476.3 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_zone | 1526.0 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 1232.4 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 4383.2 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_zone_hierarchy | 22.8 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_spatial_radius | 40.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_single | 34814.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_zone | 2875.8 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_window | 5133.5 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 1849.8 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_threshold_breach | 1628.3 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_anomalies | 18941.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_single | 10579.4 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_latest_zone | 2138.6 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_window | 4472.3 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_avg_zone_type | 3908.3 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_threshold_breach | 1213.0 | 261188 | 7.1 |
| month 1 | 30 | Lake | query_anomalies | 18779.9 | 261188 | 7.1 |
| month 3 | 90 | Lake | query_latest_single | 4940.4 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 3903.0 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 12590.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_anomalies | 49688.4 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_threshold_breach | 3256.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_spatial_radius | 26.6 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_single | 4501.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_zone | 4515.4 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_window | 9348.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 3163.4 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_hourly_rollup | 9137.7 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 7471.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_threshold_breach | 3112.9 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_anomalies | 48805.3 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_single | 5115.3 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_zone | 5057.3 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_window | 9686.3 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 4064.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 9139.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_threshold_breach | 3481.8 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_single | 4872.8 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_zone | 5108.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 3778.8 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 8698.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_zone_hierarchy | 11.9 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_spatial_radius | 27.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_single | 5293.4 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_zone | 5297.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_window | 11511.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 6845.6 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_threshold_breach | 3749.8 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_anomalies | 51085.5 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_single | 4752.2 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_latest_zone | 4782.9 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_window | 9145.9 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_avg_zone_type | 3091.8 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_threshold_breach | 3044.3 | 783641 | 24.0 |
| month 3 | 90 | Lake | query_anomalies | 46797.1 | 783641 | 24.0 |
| month 6 | 182 | Lake | query_latest_single | 8977.5 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 5598.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 21345.6 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_anomalies | 139123.6 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_threshold_breach | 6818.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_spatial_radius | 27.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_single | 9637.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_zone | 9556.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_window | 18746.7 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 5443.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_hourly_rollup | 19722.6 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 15332.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_threshold_breach | 6225.3 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_anomalies | 118117.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_single | 10242.4 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_zone | 10809.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_window | 21589.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 6010.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 15819.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_threshold_breach | 6608.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_single | 9483.4 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_zone | 9546.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 5424.3 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 15838.4 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_zone_hierarchy | 11.2 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_spatial_radius | 25.8 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_single | 9233.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_zone | 9415.3 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_window | 19477.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 6262.7 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_threshold_breach | 8332.0 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_anomalies | 126117.2 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_single | 10380.5 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_latest_zone | 10495.4 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_window | 19134.7 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_avg_zone_type | 5752.3 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_threshold_breach | 6719.9 | 1578597 | 54.1 |
| month 6 | 182 | Lake | query_anomalies | 115133.9 | 1578597 | 54.1 |
| year 1 | 365 | Lake | query_latest_single | 20973.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 16486.3 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 35041.1 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_anomalies | 238360.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_threshold_breach | 14344.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_spatial_radius | 29.1 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_single | 20079.4 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_zone | 19669.9 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_window | 80871.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 18650.1 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_hourly_rollup | 56535.6 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 29610.3 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_threshold_breach | 13449.7 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_anomalies | 248820.1 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_single | 20798.8 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_zone | 21634.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_window | 37443.4 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 11093.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 28346.6 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_threshold_breach | 14549.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_single | 17772.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_zone | 19179.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 14394.6 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 37097.1 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_zone_hierarchy | 11.7 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_spatial_radius | 30.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_single | 20787.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_zone | 21628.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_window | 48988.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 12376.8 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_threshold_breach | 14465.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_anomalies | 227115.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_single | 17607.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_latest_zone | 23040.0 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_window | 42547.3 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_avg_zone_type | 11753.5 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_threshold_breach | 14862.2 | 3159715 | 81.1 |
| year 1 | 365 | Lake | query_anomalies | 238567.7 | 3159715 | 81.1 |
| year 2 | 730 | Lake | query_latest_single | 25661.5 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 25876.8 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 48543.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_anomalies | 674576.4 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_threshold_breach | 27499.4 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_spatial_radius | 28.2 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_single | 23233.4 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_zone | 23017.7 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_window | 49812.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 26436.3 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_hourly_rollup | 49650.8 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 49460.4 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_threshold_breach | 27444.9 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_anomalies | 535449.4 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_single | 22328.3 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_zone | 25000.0 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_window | 47942.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 31169.6 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 47217.0 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_threshold_breach | 25762.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_single | 20629.2 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_zone | 20891.5 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 35035.9 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 51550.6 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_zone_hierarchy | 12.2 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_spatial_radius | 27.2 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_single | 23926.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_zone | 25426.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_window | 48123.1 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 23322.3 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_threshold_breach | 28435.7 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_anomalies | 536266.6 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_single | 26486.0 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_latest_zone | 24308.3 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_window | 52603.8 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_avg_zone_type | 25585.6 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_threshold_breach | 26649.6 | 3627868 | 121.7 |
| year 2 | 730 | Lake | query_anomalies | 532425.4 | 3627868 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 26127.1 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 39960.3 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 52779.8 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_anomalies | 872682.5 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_threshold_breach | 47790.9 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_spatial_radius | 34.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 26500.0 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_zone | 24721.5 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_window | 44863.0 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 38285.6 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_hourly_rollup | 81891.6 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 77096.4 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_threshold_breach | 40438.8 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_anomalies | 840599.7 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 24520.7 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_zone | 27959.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_window | 54708.0 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 35149.8 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 51644.7 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_threshold_breach | 43248.7 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 25699.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_zone | 25684.3 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 41267.1 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 59974.8 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_zone_hierarchy | 12.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_spatial_radius | 27.4 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 21857.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_zone | 21092.7 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_window | 46566.9 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 37140.9 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_threshold_breach | 46328.3 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_anomalies | 861484.2 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_single | 29158.0 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_latest_zone | 26408.1 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_window | 90386.0 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_avg_zone_type | 66567.9 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_threshold_breach | 60557.3 | 3838073 | 121.7 |
| year 3 | 1095 | Lake | query_anomalies | 857172.1 | 3838073 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 27655.7 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 47525.7 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 65904.9 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_anomalies | 1102967.9 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_threshold_breach | 60490.7 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_spatial_radius | 30.9 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 28725.6 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_zone | 26740.4 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_window | 50274.5 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 46573.2 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_hourly_rollup | 49420.3 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 76977.6 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_threshold_breach | 52628.5 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_anomalies | 1202549.2 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 31151.5 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_zone | 29807.2 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_window | 53374.1 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 48943.4 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 64617.6 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_threshold_breach | 48407.0 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 22914.1 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_zone | 23187.6 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 61407.2 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 62087.3 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_zone_hierarchy | 10.3 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_spatial_radius | 23.0 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 21211.5 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_zone | 22312.4 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_window | 44689.5 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 52448.0 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_threshold_breach | 53791.4 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_anomalies | 1008296.0 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_single | 21726.3 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_latest_zone | 26722.2 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_window | 50610.4 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_avg_zone_type | 51628.1 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_threshold_breach | 44861.1 | 4048432 | 121.7 |
| year 4 | 1460 | Lake | query_anomalies | 1028919.5 | 4048432 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 23180.4 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 55826.2 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 66658.2 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_anomalies | 1364817.3 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_threshold_breach | 52457.6 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_spatial_radius | 25.4 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 23953.1 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_zone | 25450.2 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_window | 49208.1 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 50116.1 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_hourly_rollup | 55856.3 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 75647.3 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_threshold_breach | 77402.1 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_anomalies | 1454677.0 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 24631.5 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_zone | 27398.5 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_window | 58678.4 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 56728.6 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 68865.8 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_threshold_breach | 53789.9 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 24091.7 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_zone | 30317.0 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 62470.0 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 75599.6 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_zone_hierarchy | 11.9 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_spatial_radius | 26.6 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 25241.8 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_zone | 26295.8 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_window | 50225.7 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 64430.6 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_threshold_breach | 62497.3 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_anomalies | 1522877.7 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_single | 23711.5 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_latest_zone | 24945.5 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_window | 51426.8 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_avg_zone_type | 51626.5 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_threshold_breach | 71438.0 | 4258844 | 121.7 |
| year 5 | 1825 | Lake | query_anomalies | 1404685.3 | 4258844 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 30982.7 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 69071.6 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 103904.4 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_anomalies | 2156511.6 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_threshold_breach | 77906.7 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_spatial_radius | 30.3 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 31644.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_zone | 31398.9 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_window | 64934.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 71487.7 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_hourly_rollup | 66211.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 109417.2 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_threshold_breach | 79387.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_anomalies | 2181397.1 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 29733.6 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_zone | 32415.6 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_window | 54900.3 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 66329.3 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 120813.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_threshold_breach | 81403.9 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 38249.1 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_zone | 29886.6 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 73780.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 107351.5 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_zone_hierarchy | 20.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_spatial_radius | 31.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 33561.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_zone | 28204.2 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_window | 53109.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 70017.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_threshold_breach | 69674.8 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_anomalies | 1981800.1 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_single | 36870.1 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_latest_zone | 38041.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_window | 53371.0 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_avg_zone_type | 80105.3 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_threshold_breach | 65541.2 | 4468874 | 121.7 |
| year 6 | 2190 | Lake | query_anomalies | 2160494.4 | 4468874 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 31414.6 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 81864.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 110302.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_anomalies | 2494283.0 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_threshold_breach | 81660.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_spatial_radius | 25.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 30092.4 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_zone | 33350.4 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_window | 53987.7 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 78838.1 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_hourly_rollup | 58596.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 90397.4 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_threshold_breach | 74319.6 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_anomalies | 2557958.6 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 30774.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_zone | 33377.2 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_window | 55255.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 82231.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 98883.7 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_threshold_breach | 82112.0 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 29759.6 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_zone | 26272.7 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 80867.1 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 102824.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_zone_hierarchy | 12.3 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_spatial_radius | 27.4 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 26878.6 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_zone | 27046.2 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_window | 59222.2 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 74115.9 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_threshold_breach | 95120.8 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_anomalies | 2531983.1 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_single | 36267.9 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_latest_zone | 41270.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_window | 54803.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_avg_zone_type | 77414.4 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_threshold_breach | 89405.5 | 4679292 | 121.7 |
| year 7 | 2555 | Lake | query_anomalies | 2553503.9 | 4679292 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 30289.1 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 75999.8 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 113780.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_anomalies | 2757788.6 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_threshold_breach | 84511.0 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_spatial_radius | 24.2 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 25654.2 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_zone | 30802.9 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_window | 58693.9 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 94694.3 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_hourly_rollup | 51693.6 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 138269.3 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_threshold_breach | 106907.5 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_anomalies | 2729625.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 33386.8 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_zone | 27956.8 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_window | 56798.5 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 79950.8 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 101696.5 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_threshold_breach | 90160.9 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 36494.1 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_zone | 35702.6 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 84740.8 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 125254.3 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_zone_hierarchy | 13.5 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_spatial_radius | 29.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 31441.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_zone | 28749.3 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_window | 63371.9 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 93714.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_threshold_breach | 77086.0 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_anomalies | 2808494.6 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_single | 48151.2 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_latest_zone | 32856.2 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_window | 67872.6 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_avg_zone_type | 83389.7 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_threshold_breach | 99513.4 | 4679221 | 121.7 |
| steady state | 2682 | Lake | query_anomalies | 2752453.8 | 4679221 | 121.7 |

## Simulation Summary

Per-backend wall-time cost of the live day-zero simulation (simulated time / wall time = compression ratio), data volume, and prune activity.

| Backend | Sim days | Wall time (s) | Compression | Generated | Evicted | Prune calls | Stream time (s) | Prune time (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| TimeSeries | 2682 | 264.0 | 877808× | 23352775 | 18673554 | 552 | 19.2 | 28.4 |
| Columnar | 2682 | 276.9 | 836841× | 23352775 | 18673554 | 552 | 20.7 | 44.9 |
| Hierarchical | 2682 | 325.5 | 711910× | 23352775 | 18673554 | 552 | 25.2 | 22.2 |
| RingBuffer | 2682 | 26.1 | 8863815× | 23352775 | 0 | 552 | 25.7 | 0.3 |
| Lake | 2682 | 263.8 | 878547× | 23352775 | 18673554 | 552 | 18.6 | 25.1 |

### Steady-state data volume by sensor type

| Sensor type | Readings | Bytes (MB) |
|---|---:|---:|
| structural | 1471680 | 33.7 |
| temperature | 800352 | 18.3 |
| humidity | 800352 | 18.3 |
| occupancy | 6133 | 0.1 |
| co2 | 800352 | 18.3 |
| air_quality | 800352 | 18.3 |
