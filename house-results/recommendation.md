# Digital Twin — Storage Recommendation

- Source IFC: `assets/IFC/AC20-FZK-Haus.ifc`
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
| Hierarchical | 1.000 | 100% |
| Columnar | 1.323 | 100% |
| RingBuffer | 1.323 | 100% |
| TimeSeries | 1.485 | 100% |
| Lake | 1.646 | 100% |

**Real-time winner: Hierarchical**

### Historical track

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 79.427 | 100% |
| TimeSeries | 100.438 | 100% |
| Lake | 175.067 | 100% |

**Historical winner: Hierarchical**

**Deployment combo: Hierarchical (live) + Hierarchical (historical)**

## Recommendation by Sensor Type

Same scoring rule as above, but scoped to one sensor type at a time. For each of the 6 sensor types actually placed in this building, each of that type's canonical type-scoped queries is measured once against a real placed sensor of that exact type, over its full independently-generated dataset. Scores only the query patterns in that type's own canonical relevant_queries that take a sensor type as an argument (`latest_by_type`, `avg_zone_type`, `floor_stats`, `daily_zone_rollup`, `anomalies` — whichever are relevant for this specific type). A type's winner can differ from the building-wide winner above if that type's relevant queries behave differently.

**structural** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 26.265 | 100% |
| TimeSeries | 40.440 | 100% |
| Lake | 61.510 | 100% |

**temperature** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 41.506 | 100% |
| TimeSeries | 65.107 | 100% |
| Lake | 162.773 | 100% |

**humidity** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 50.147 | 100% |
| TimeSeries | 86.500 | 100% |
| Lake | 125.425 | 100% |

**occupancy** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 66.263 | 100% |
| TimeSeries | 108.759 | 100% |
| Lake | 196.748 | 100% |

**co2** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 44.580 | 100% |
| TimeSeries | 71.179 | 100% |
| Lake | 110.776 | 100% |

**air_quality** — historical: **Hierarchical**

Historical:

| Backend | Score | Coverage |
|---|---:|---:|
| Hierarchical | 1.000 | 100% |
| Columnar | 42.783 | 100% |
| TimeSeries | 71.712 | 100% |
| Lake | 113.741 | 100% |

## Per-query latency (this building's actual query mix)

| Query | Backend | Median µs | p95 µs | Memory (KB) |
|---|---|---:|---:|---:|
| query_latest_single | TimeSeries | 0.1 | 0.1 | 131367.0 |
| query_avg_zone_type | TimeSeries | 94.0 | 94.0 | 131367.0 |
| query_daily_zone_rollup | TimeSeries | 23864.2 | 23864.2 | 131367.0 |
| query_anomalies | TimeSeries | 1018.1 | 1018.1 | 131367.0 |
| query_threshold_breach | TimeSeries | 112.3 | 112.3 | 131367.0 |
| query_spatial_radius | TimeSeries | 1.5 | 1.5 | 131367.0 |
| query_latest_single | TimeSeries | 0.1 | 0.1 | 131367.0 |
| query_latest_zone | TimeSeries | 0.8 | 0.8 | 131367.0 |
| query_avg_window | TimeSeries | 91.8 | 91.8 | 131367.0 |
| query_avg_zone_type | TimeSeries | 90.0 | 90.0 | 131367.0 |
| query_hourly_rollup | TimeSeries | 125.7 | 125.7 | 131367.0 |
| query_daily_zone_rollup | TimeSeries | 23028.9 | 23028.9 | 131367.0 |
| query_threshold_breach | TimeSeries | 119.4 | 119.4 | 131367.0 |
| query_anomalies | TimeSeries | 1034.2 | 1034.2 | 131367.0 |
| query_latest_single | TimeSeries | 0.1 | 0.1 | 131367.0 |
| query_latest_zone | TimeSeries | 1.6 | 1.6 | 131367.0 |
| query_avg_window | TimeSeries | 99.8 | 99.8 | 131367.0 |
| query_avg_zone_type | TimeSeries | 89.2 | 89.2 | 131367.0 |
| query_daily_zone_rollup | TimeSeries | 23095.7 | 23095.7 | 131367.0 |
| query_threshold_breach | TimeSeries | 119.3 | 119.3 | 131367.0 |
| query_latest_single | TimeSeries | 0.2 | 0.2 | 131367.0 |
| query_latest_zone | TimeSeries | 0.9 | 0.9 | 131367.0 |
| query_avg_zone_type | TimeSeries | 91.7 | 91.7 | 131367.0 |
| query_daily_zone_rollup | TimeSeries | 23443.9 | 23443.9 | 131367.0 |
| query_zone_hierarchy | TimeSeries | 1.9 | 1.9 | 131367.0 |
| query_spatial_radius | TimeSeries | 1.5 | 1.5 | 131367.0 |
| query_latest_single | TimeSeries | 0.1 | 0.1 | 131367.0 |
| query_latest_zone | TimeSeries | 1.0 | 1.0 | 131367.0 |
| query_avg_window | TimeSeries | 96.8 | 96.8 | 131367.0 |
| query_avg_zone_type | TimeSeries | 90.9 | 90.9 | 131367.0 |
| query_threshold_breach | TimeSeries | 111.3 | 111.3 | 131367.0 |
| query_anomalies | TimeSeries | 1012.5 | 1012.5 | 131367.0 |
| query_latest_single | TimeSeries | 0.0 | 0.0 | 131367.0 |
| query_latest_zone | TimeSeries | 0.6 | 0.6 | 131367.0 |
| query_avg_window | TimeSeries | 90.6 | 90.6 | 131367.0 |
| query_avg_zone_type | TimeSeries | 90.1 | 90.1 | 131367.0 |
| query_threshold_breach | TimeSeries | 111.2 | 111.2 | 131367.0 |
| query_anomalies | TimeSeries | 1320.5 | 1320.5 | 131367.0 |
| query_latest_single | Columnar | 0.1 | 0.1 | 30500.2 |
| query_avg_zone_type | Columnar | 55.6 | 55.6 | 30500.2 |
| query_daily_zone_rollup | Columnar | 17571.7 | 17571.7 | 30500.2 |
| query_anomalies | Columnar | 1106.7 | 1106.7 | 30500.2 |
| query_threshold_breach | Columnar | 134.6 | 134.6 | 30500.2 |
| query_spatial_radius | Columnar | 1.5 | 1.5 | 30500.2 |
| query_latest_single | Columnar | 0.0 | 0.0 | 30500.2 |
| query_latest_zone | Columnar | 0.9 | 0.9 | 30500.2 |
| query_avg_window | Columnar | 55.7 | 55.7 | 30500.2 |
| query_avg_zone_type | Columnar | 59.3 | 59.3 | 30500.2 |
| query_hourly_rollup | Columnar | 120.4 | 120.4 | 30500.2 |
| query_daily_zone_rollup | Columnar | 16830.0 | 16830.0 | 30500.2 |
| query_threshold_breach | Columnar | 109.1 | 109.1 | 30500.2 |
| query_anomalies | Columnar | 930.3 | 930.3 | 30500.2 |
| query_latest_single | Columnar | 0.1 | 0.1 | 30500.2 |
| query_latest_zone | Columnar | 0.8 | 0.8 | 30500.2 |
| query_avg_window | Columnar | 52.8 | 52.8 | 30500.2 |
| query_avg_zone_type | Columnar | 52.4 | 52.4 | 30500.2 |
| query_daily_zone_rollup | Columnar | 17728.0 | 17728.0 | 30500.2 |
| query_threshold_breach | Columnar | 112.9 | 112.9 | 30500.2 |
| query_latest_single | Columnar | 0.0 | 0.0 | 30500.2 |
| query_latest_zone | Columnar | 0.6 | 0.6 | 30500.2 |
| query_avg_zone_type | Columnar | 55.9 | 55.9 | 30500.2 |
| query_daily_zone_rollup | Columnar | 17422.1 | 17422.1 | 30500.2 |
| query_zone_hierarchy | Columnar | 1.5 | 1.5 | 30500.2 |
| query_spatial_radius | Columnar | 1.2 | 1.2 | 30500.2 |
| query_latest_single | Columnar | 0.1 | 0.1 | 30500.2 |
| query_latest_zone | Columnar | 0.7 | 0.7 | 30500.2 |
| query_avg_window | Columnar | 59.5 | 59.5 | 30500.2 |
| query_avg_zone_type | Columnar | 55.6 | 55.6 | 30500.2 |
| query_threshold_breach | Columnar | 108.7 | 108.7 | 30500.2 |
| query_anomalies | Columnar | 964.0 | 964.0 | 30500.2 |
| query_latest_single | Columnar | 0.1 | 0.1 | 30500.2 |
| query_latest_zone | Columnar | 0.5 | 0.5 | 30500.2 |
| query_avg_window | Columnar | 54.4 | 54.4 | 30500.2 |
| query_avg_zone_type | Columnar | 54.2 | 54.2 | 30500.2 |
| query_threshold_breach | Columnar | 108.0 | 108.0 | 30500.2 |
| query_anomalies | Columnar | 1344.6 | 1344.6 | 30500.2 |
| query_latest_single | Hierarchical | 0.0 | 0.0 | 265572.6 |
| query_avg_zone_type | Hierarchical | 1.0 | 1.0 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 1901.2 | 1901.2 | 265572.6 |
| query_anomalies | Hierarchical | 86.6 | 86.6 | 265572.6 |
| query_threshold_breach | Hierarchical | 0.8 | 0.8 | 265572.6 |
| query_spatial_radius | Hierarchical | 1.2 | 1.2 | 265572.6 |
| query_latest_single | Hierarchical | 0.1 | 0.1 | 265572.6 |
| query_latest_zone | Hierarchical | 0.3 | 0.3 | 265572.6 |
| query_avg_window | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_avg_zone_type | Hierarchical | 0.7 | 0.7 | 265572.6 |
| query_hourly_rollup | Hierarchical | 11.6 | 11.6 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 1869.2 | 1869.2 | 265572.6 |
| query_threshold_breach | Hierarchical | 0.8 | 0.8 | 265572.6 |
| query_anomalies | Hierarchical | 83.1 | 83.1 | 265572.6 |
| query_latest_single | Hierarchical | 0.0 | 0.0 | 265572.6 |
| query_latest_zone | Hierarchical | 0.3 | 0.3 | 265572.6 |
| query_avg_window | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_avg_zone_type | Hierarchical | 0.7 | 0.7 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 2831.8 | 2831.8 | 265572.6 |
| query_threshold_breach | Hierarchical | 0.9 | 0.9 | 265572.6 |
| query_latest_single | Hierarchical | 0.1 | 0.1 | 265572.6 |
| query_latest_zone | Hierarchical | 0.4 | 0.4 | 265572.6 |
| query_avg_zone_type | Hierarchical | 0.8 | 0.8 | 265572.6 |
| query_daily_zone_rollup | Hierarchical | 1826.7 | 1826.7 | 265572.6 |
| query_zone_hierarchy | Hierarchical | 1.2 | 1.2 | 265572.6 |
| query_spatial_radius | Hierarchical | 1.2 | 1.2 | 265572.6 |
| query_latest_single | Hierarchical | 0.0 | 0.0 | 265572.6 |
| query_latest_zone | Hierarchical | 0.3 | 0.3 | 265572.6 |
| query_avg_window | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_avg_zone_type | Hierarchical | 0.7 | 0.7 | 265572.6 |
| query_threshold_breach | Hierarchical | 0.7 | 0.7 | 265572.6 |
| query_anomalies | Hierarchical | 82.1 | 82.1 | 265572.6 |
| query_latest_single | Hierarchical | 0.1 | 0.1 | 265572.6 |
| query_latest_zone | Hierarchical | 0.3 | 0.3 | 265572.6 |
| query_avg_window | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_avg_zone_type | Hierarchical | 0.7 | 0.7 | 265572.6 |
| query_threshold_breach | Hierarchical | 0.6 | 0.6 | 265572.6 |
| query_anomalies | Hierarchical | 81.3 | 81.3 | 265572.6 |
| query_latest_single | RingBuffer | 0.1 | 0.1 | 14.1 |
| query_avg_zone_type | RingBuffer | 1.7 | 1.7 | 14.1 |
| query_anomalies | RingBuffer | 4.3 | 4.3 | 14.1 |
| query_threshold_breach | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_spatial_radius | RingBuffer | 1.2 | 1.2 | 14.1 |
| query_latest_single | RingBuffer | 0.1 | 0.1 | 14.1 |
| query_latest_zone | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_window | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_threshold_breach | RingBuffer | 0.3 | 0.3 | 14.1 |
| query_anomalies | RingBuffer | 3.4 | 3.4 | 14.1 |
| query_latest_single | RingBuffer | 0.0 | 0.0 | 14.1 |
| query_latest_zone | RingBuffer | 0.6 | 0.6 | 14.1 |
| query_avg_window | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_threshold_breach | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_latest_single | RingBuffer | 0.0 | 0.0 | 14.1 |
| query_latest_zone | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 0.6 | 0.6 | 14.1 |
| query_zone_hierarchy | RingBuffer | 0.8 | 0.8 | 14.1 |
| query_spatial_radius | RingBuffer | 1.0 | 1.0 | 14.1 |
| query_latest_single | RingBuffer | 0.1 | 0.1 | 14.1 |
| query_latest_zone | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_window | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_avg_zone_type | RingBuffer | 0.9 | 0.9 | 14.1 |
| query_threshold_breach | RingBuffer | 0.4 | 0.4 | 14.1 |
| query_anomalies | RingBuffer | 3.2 | 3.2 | 14.1 |
| query_latest_single | RingBuffer | 0.1 | 0.1 | 14.1 |
| query_latest_zone | RingBuffer | 0.5 | 0.5 | 14.1 |
| query_avg_window | RingBuffer | 0.3 | 0.3 | 14.1 |
| query_avg_zone_type | RingBuffer | 0.6 | 0.6 | 14.1 |
| query_threshold_breach | RingBuffer | 0.3 | 0.3 | 14.1 |
| query_anomalies | RingBuffer | 3.3 | 3.3 | 14.1 |
| query_latest_single | Lake | 0.1 | 0.1 | 34735.7 |
| query_avg_zone_type | Lake | 139.3 | 139.3 | 34735.7 |
| query_daily_zone_rollup | Lake | 24991.3 | 24991.3 | 34735.7 |
| query_anomalies | Lake | 3089.7 | 3089.7 | 34735.7 |
| query_threshold_breach | Lake | 210.0 | 210.0 | 34735.7 |
| query_spatial_radius | Lake | 1.9 | 1.9 | 34735.7 |
| query_latest_single | Lake | 0.1 | 0.1 | 34735.7 |
| query_latest_zone | Lake | 0.9 | 0.9 | 34735.7 |
| query_avg_window | Lake | 145.6 | 145.6 | 34735.7 |
| query_avg_zone_type | Lake | 145.9 | 145.9 | 34735.7 |
| query_hourly_rollup | Lake | 205.1 | 205.1 | 34735.7 |
| query_daily_zone_rollup | Lake | 25275.3 | 25275.3 | 34735.7 |
| query_threshold_breach | Lake | 185.0 | 185.0 | 34735.7 |
| query_anomalies | Lake | 1745.3 | 1745.3 | 34735.7 |
| query_latest_single | Lake | 0.0 | 0.0 | 34735.7 |
| query_latest_zone | Lake | 1.0 | 1.0 | 34735.7 |
| query_avg_window | Lake | 139.4 | 139.4 | 34735.7 |
| query_avg_zone_type | Lake | 139.2 | 139.2 | 34735.7 |
| query_daily_zone_rollup | Lake | 24354.9 | 24354.9 | 34735.7 |
| query_threshold_breach | Lake | 190.3 | 190.3 | 34735.7 |
| query_latest_single | Lake | 0.1 | 0.1 | 34735.7 |
| query_latest_zone | Lake | 0.7 | 0.7 | 34735.7 |
| query_avg_zone_type | Lake | 140.2 | 140.2 | 34735.7 |
| query_daily_zone_rollup | Lake | 25268.4 | 25268.4 | 34735.7 |
| query_zone_hierarchy | Lake | 1.6 | 1.6 | 34735.7 |
| query_spatial_radius | Lake | 1.2 | 1.2 | 34735.7 |
| query_latest_single | Lake | 0.1 | 0.1 | 34735.7 |
| query_latest_zone | Lake | 0.7 | 0.7 | 34735.7 |
| query_avg_window | Lake | 149.4 | 149.4 | 34735.7 |
| query_avg_zone_type | Lake | 159.4 | 159.4 | 34735.7 |
| query_threshold_breach | Lake | 267.9 | 267.9 | 34735.7 |
| query_anomalies | Lake | 1833.9 | 1833.9 | 34735.7 |
| query_latest_single | Lake | 0.0 | 0.0 | 34735.7 |
| query_latest_zone | Lake | 0.7 | 0.7 | 34735.7 |
| query_avg_window | Lake | 145.4 | 145.4 | 34735.7 |
| query_avg_zone_type | Lake | 147.9 | 147.9 | 34735.7 |
| query_threshold_breach | Lake | 211.9 | 211.9 | 34735.7 |
| query_anomalies | Lake | 1852.4 | 1852.4 | 34735.7 |

See `schematic.svg` in this directory for a floor-by-floor map of placed sensors.
## Cost estimate (cloud-equivalent)

Pricing: **$1200/TB-year** (storage) + **$5.00/M queries** (compute). Workload: **30000000 queries/year**. Sources: public cloud pricing pages, mid-2026 — disclosed defaults, not vendor-specific bills. Absolute numbers are approximate (±2×); relative rankings are reliable (CLAUDE.md §6).

### Per-backend annual cost

| Backend | Storage (GB) | Storage $/yr | Query $/yr | **Total $/yr** |
|---|---:|---:|---:|---:|
| RingBuffer | 0.0 | $0 | $150 | **$150** |
| Columnar | 0.0 | $0 | $150 | **$150** |
| Lake | 0.0 | $0 | $150 | **$150** |
| TimeSeries | 0.1 | $0 | $150 | **$150** |
| Hierarchical | 0.3 | $0 | $150 | **$150** |

### Naive vs optimised

| Strategy | Annual cost |
|---|---:|
| Naive (all 5 backends simultaneously) | $751/yr |
| **Optimised** (Hierarchical + Hierarchical) | **$151/yr** |

**Savings: $600/yr (80%)** by running only the recommended backends instead of all of them.


## Latency vs Building Age (Growth Curve)

Each row is one query's median latency at one checkpoint in the building's simulated lifetime — from day 1 (near-empty) to steady state (retention-full, actively evicting). This shows whether a backend's query latency is constant (O(1) access) or grows with data volume.

| Checkpoint | Day | Backend | Query | Median µs | Live readings | Memory (MB) |
|---|---:|---|---|---:|---:|---:|
| day 1 | 1 | TimeSeries | query_latest_single | 0.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 24.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 25.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 140.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 21.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_spatial_radius | 1.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 0.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 20.0 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 34.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_hourly_rollup | 238.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 142.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 107.8 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 270.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 2.3 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 96.6 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 50.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 45.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 26.2 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.0 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 0.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 18.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_daily_zone_rollup | 25.6 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_zone_hierarchy | 0.9 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_spatial_radius | 1.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 0.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 21.8 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 19.0 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 30.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 84.5 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_single | 0.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_latest_zone | 0.4 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_window | 20.7 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_avg_zone_type | 20.6 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_threshold_breach | 17.1 | 8713 | 0.3 |
| day 1 | 1 | TimeSeries | query_anomalies | 94.9 | 8713 | 0.3 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.1 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.6 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 140.3 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_anomalies | 647.6 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 36.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_spatial_radius | 1.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_zone | 0.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_window | 20.6 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.6 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_hourly_rollup | 45.9 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 150.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 36.2 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_anomalies | 652.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_zone | 0.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_window | 17.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.3 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 142.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 36.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.1 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_zone | 0.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.3 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_daily_zone_rollup | 141.9 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_zone_hierarchy | 0.9 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_spatial_radius | 0.9 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_zone | 0.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_window | 17.2 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 36.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_anomalies | 676.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_single | 0.0 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_latest_zone | 0.3 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_window | 17.4 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_avg_zone_type | 17.2 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_threshold_breach | 36.3 | 60917 | 1.7 |
| week 1 | 7 | TimeSeries | query_anomalies | 3728.4 | 60917 | 1.7 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 18.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 1341.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 666.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 38.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_spatial_radius | 1.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 0.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 17.9 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 18.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_hourly_rollup | 56.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 1684.4 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 43.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 612.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 0.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 17.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 17.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 1384.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 38.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 0.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 18.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_daily_zone_rollup | 1314.8 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_zone_hierarchy | 1.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_spatial_radius | 1.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.1 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 0.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 18.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 17.6 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 38.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 609.2 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_single | 0.0 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_latest_zone | 0.4 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_window | 17.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_avg_zone_type | 17.5 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_threshold_breach | 37.7 | 261188 | 7.1 |
| month 1 | 30 | TimeSeries | query_anomalies | 605.5 | 261188 | 7.1 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 31.5 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 4423.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_anomalies | 700.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 43.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_spatial_radius | 1.2 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_zone | 0.7 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_window | 22.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 20.6 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_hourly_rollup | 53.2 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 4700.9 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 48.5 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_anomalies | 612.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_zone | 0.6 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_window | 22.2 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 21.4 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 6944.3 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 62.3 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_zone | 0.8 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 23.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_daily_zone_rollup | 4604.2 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_zone_hierarchy | 1.2 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_spatial_radius | 1.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_zone | 0.8 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_window | 34.3 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 34.3 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 75.9 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_anomalies | 1081.1 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_single | 0.0 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_latest_zone | 0.7 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_window | 23.7 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_avg_zone_type | 22.4 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_threshold_breach | 44.9 | 783641 | 21.3 |
| month 3 | 90 | TimeSeries | query_anomalies | 729.9 | 783641 | 21.3 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 29.5 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 10723.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_anomalies | 690.6 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 50.8 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_spatial_radius | 1.3 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_zone | 0.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_window | 36.5 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 30.2 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_hourly_rollup | 64.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 11704.4 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 58.0 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_anomalies | 1114.9 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_zone | 1.0 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_window | 32.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 30.9 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 9373.5 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 207.4 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_zone | 0.8 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 44.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_daily_zone_rollup | 14706.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_zone_hierarchy | 2.5 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_spatial_radius | 2.0 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_zone | 1.2 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_window | 65.9 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 42.8 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 70.3 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_anomalies | 940.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_single | 0.1 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_latest_zone | 0.8 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_window | 42.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_avg_zone_type | 41.5 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_threshold_breach | 66.7 | 1578597 | 42.9 |
| month 6 | 182 | TimeSeries | query_anomalies | 936.0 | 1578597 | 42.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 44.8 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 20894.8 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_anomalies | 699.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 94.4 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_spatial_radius | 2.6 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_zone | 1.0 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_window | 60.4 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 62.6 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_hourly_rollup | 129.3 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 20164.3 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 66.6 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_anomalies | 684.6 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_zone | 0.8 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_window | 43.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 42.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 24332.8 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 74.0 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_zone | 0.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 48.4 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_daily_zone_rollup | 22181.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_zone_hierarchy | 1.5 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_spatial_radius | 1.1 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.2 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_zone | 0.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_window | 49.4 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 47.7 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 63.5 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_anomalies | 730.3 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_single | 0.0 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_latest_zone | 0.6 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_window | 53.9 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_avg_zone_type | 44.0 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_threshold_breach | 62.0 | 3159715 | 85.9 |
| year 1 | 365 | TimeSeries | query_anomalies | 713.7 | 3159715 | 85.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 53.6 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 24441.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_anomalies | 3326.2 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 106.6 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_spatial_radius | 2.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_zone | 0.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_window | 73.8 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 74.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_hourly_rollup | 127.6 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 25582.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 89.8 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_anomalies | 860.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_zone | 0.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_window | 51.2 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 50.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 32477.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 101.4 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_zone | 0.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 48.6 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_daily_zone_rollup | 24225.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_zone_hierarchy | 1.8 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_spatial_radius | 1.3 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_zone | 0.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_window | 53.5 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 51.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 73.5 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_anomalies | 854.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_single | 0.1 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_latest_zone | 0.5 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_window | 51.9 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_avg_zone_type | 51.4 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_threshold_breach | 95.7 | 3627868 | 98.9 |
| year 2 | 730 | TimeSeries | query_anomalies | 837.9 | 3627868 | 98.9 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 48.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 23067.7 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_anomalies | 876.6 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 71.0 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_spatial_radius | 1.5 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 0.9 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_window | 49.2 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 49.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_hourly_rollup | 117.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 22453.2 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 72.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_anomalies | 1604.0 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 0.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_window | 47.2 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 49.6 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 22144.3 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 73.6 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 0.9 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 50.6 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_daily_zone_rollup | 23319.3 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_zone_hierarchy | 1.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_spatial_radius | 1.2 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 0.6 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_window | 50.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 51.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 72.4 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_anomalies | 793.9 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_single | 0.1 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_latest_zone | 0.5 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_window | 49.4 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_avg_zone_type | 48.8 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_threshold_breach | 70.7 | 3838073 | 104.8 |
| year 3 | 1095 | TimeSeries | query_anomalies | 792.5 | 3838073 | 104.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 78.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 23494.2 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_anomalies | 995.6 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 100.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_spatial_radius | 1.5 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 0.9 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_window | 78.9 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 77.5 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_hourly_rollup | 113.0 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 24388.9 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 135.6 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_anomalies | 975.5 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 0.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_window | 83.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 83.0 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 23435.0 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 117.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 1.3 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 99.4 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_daily_zone_rollup | 22891.4 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_zone_hierarchy | 1.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_spatial_radius | 1.6 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 0.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_window | 87.9 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 90.3 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 117.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_anomalies | 1159.7 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_single | 0.1 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_latest_zone | 0.6 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_window | 98.7 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_avg_zone_type | 86.8 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_threshold_breach | 110.6 | 4048432 | 110.8 |
| year 4 | 1460 | TimeSeries | query_anomalies | 991.4 | 4048432 | 110.8 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 86.6 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 37743.6 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_anomalies | 2197.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 217.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_spatial_radius | 4.8 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 1.8 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_window | 180.9 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 177.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_hourly_rollup | 259.4 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 39275.3 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 165.9 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1904.3 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 1.4 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_window | 136.6 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 132.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 30706.4 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 134.7 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 1.0 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 99.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_daily_zone_rollup | 28720.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_zone_hierarchy | 2.8 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_spatial_radius | 3.5 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 1.4 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_window | 137.6 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 114.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 129.2 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1248.7 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_single | 0.1 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_latest_zone | 1.0 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_window | 101.0 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_avg_zone_type | 101.8 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_threshold_breach | 127.6 | 4258844 | 116.6 |
| year 5 | 1825 | TimeSeries | query_anomalies | 1248.7 | 4258844 | 116.6 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 85.8 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 22771.6 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_anomalies | 1386.0 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 108.6 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_spatial_radius | 1.7 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 1.0 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_window | 88.6 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 93.2 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_hourly_rollup | 138.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 26189.0 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 120.7 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_anomalies | 1055.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 1.0 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_window | 86.6 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 84.8 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 26116.3 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 114.3 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 0.9 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 87.2 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_daily_zone_rollup | 23869.9 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_zone_hierarchy | 1.6 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_spatial_radius | 1.2 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 0.9 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_window | 90.7 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 96.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 105.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_anomalies | 1411.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_single | 0.1 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_latest_zone | 0.9 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_window | 115.8 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_avg_zone_type | 130.9 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_threshold_breach | 171.4 | 4468874 | 122.4 |
| year 6 | 2190 | TimeSeries | query_anomalies | 1588.3 | 4468874 | 122.4 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 87.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 24032.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_anomalies | 1009.3 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 113.9 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_spatial_radius | 1.6 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 0.9 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_window | 90.5 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 90.0 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_hourly_rollup | 128.8 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 24185.4 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 123.8 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_anomalies | 1015.0 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 0.7 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_window | 133.8 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 94.5 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 22621.9 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 120.6 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 0.9 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 90.2 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_daily_zone_rollup | 22909.2 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_zone_hierarchy | 1.8 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_spatial_radius | 1.6 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.2 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 0.9 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_window | 91.3 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 91.0 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 112.3 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_anomalies | 1000.1 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_single | 0.0 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_latest_zone | 0.5 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_window | 87.5 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_avg_zone_type | 85.7 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_threshold_breach | 107.0 | 4679292 | 128.3 |
| year 7 | 2555 | TimeSeries | query_anomalies | 998.2 | 4679292 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 94.0 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 23864.2 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_anomalies | 1018.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 112.3 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_spatial_radius | 1.5 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_zone | 0.8 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_window | 91.8 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 90.0 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_hourly_rollup | 125.7 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 23028.9 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 119.4 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_anomalies | 1034.2 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_zone | 1.6 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_window | 99.8 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 89.2 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 23095.7 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 119.3 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.2 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_zone | 0.9 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 91.7 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_daily_zone_rollup | 23443.9 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_zone_hierarchy | 1.9 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_spatial_radius | 1.5 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_zone | 1.0 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_window | 96.8 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 90.9 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 111.3 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_anomalies | 1012.5 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_single | 0.0 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_latest_zone | 0.6 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_window | 90.6 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_avg_zone_type | 90.1 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_threshold_breach | 111.2 | 4679221 | 128.3 |
| steady state | 2682 | TimeSeries | query_anomalies | 1320.5 | 4679221 | 128.3 |
| day 1 | 1 | Columnar | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 35.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 39.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 164.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 35.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_spatial_radius | 1.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 0.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 35.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 35.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_hourly_rollup | 40.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 39.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 34.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 153.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 34.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 35.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 40.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 34.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 0.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 36.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_daily_zone_rollup | 37.9 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_zone_hierarchy | 1.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_spatial_radius | 1.2 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 0.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 35.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 35.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 34.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 152.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_latest_zone | 0.5 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_window | 34.7 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_avg_zone_type | 35.0 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_threshold_breach | 36.3 | 8713 | 0.1 |
| day 1 | 1 | Columnar | query_anomalies | 152.2 | 8713 | 0.1 |
| week 1 | 7 | Columnar | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 47.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 227.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_anomalies | 903.7 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_threshold_breach | 97.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_spatial_radius | 1.1 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_zone | 0.5 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_window | 46.2 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 46.2 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_hourly_rollup | 108.5 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 226.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_threshold_breach | 96.7 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_anomalies | 903.8 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_single | 0.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_zone | 0.6 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_window | 46.2 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 46.3 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 229.3 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_threshold_breach | 96.6 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_single | 0.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_zone | 0.4 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 46.3 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_daily_zone_rollup | 225.5 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_zone_hierarchy | 0.9 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_spatial_radius | 1.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_zone | 0.4 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_window | 46.0 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 49.9 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_threshold_breach | 98.7 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_anomalies | 976.7 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_latest_zone | 0.7 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_window | 46.3 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_avg_zone_type | 46.3 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_threshold_breach | 102.2 | 60917 | 0.4 |
| week 1 | 7 | Columnar | query_anomalies | 1967.7 | 60917 | 0.4 |
| month 1 | 30 | Columnar | query_latest_single | 0.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 110.4 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 2074.0 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_anomalies | 1093.3 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_threshold_breach | 87.9 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_spatial_radius | 1.4 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_zone | 0.7 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_window | 70.5 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 70.5 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_hourly_rollup | 101.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 1336.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_threshold_breach | 87.9 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_anomalies | 1713.2 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.0 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_zone | 0.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_window | 71.9 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 85.7 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 1433.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_threshold_breach | 93.4 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_zone | 0.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 70.8 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_daily_zone_rollup | 1397.3 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_zone_hierarchy | 1.3 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_spatial_radius | 1.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_zone | 0.5 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_window | 70.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 70.7 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_threshold_breach | 87.5 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_anomalies | 1382.0 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_single | 0.1 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_latest_zone | 0.6 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_window | 70.9 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_avg_zone_type | 70.8 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_threshold_breach | 87.5 | 261188 | 1.6 |
| month 1 | 30 | Columnar | query_anomalies | 1088.3 | 261188 | 1.6 |
| month 3 | 90 | Columnar | query_latest_single | 0.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 69.3 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 7387.4 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_anomalies | 1231.6 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_threshold_breach | 97.5 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_spatial_radius | 1.5 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_single | 0.0 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_zone | 0.9 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_window | 68.6 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 73.9 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_hourly_rollup | 105.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 6128.9 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_threshold_breach | 412.8 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_anomalies | 1676.2 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_single | 0.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_zone | 1.0 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_window | 78.4 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 69.8 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 4366.0 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_threshold_breach | 112.0 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_single | 0.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_zone | 0.7 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 69.3 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_daily_zone_rollup | 4406.9 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_zone_hierarchy | 1.5 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_spatial_radius | 1.3 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_single | 0.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_zone | 0.7 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_window | 70.1 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 68.8 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_threshold_breach | 91.7 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_anomalies | 1058.7 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_single | 0.0 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_latest_zone | 0.4 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_window | 68.6 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_avg_zone_type | 70.5 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_threshold_breach | 93.5 | 783641 | 5.0 |
| month 3 | 90 | Columnar | query_anomalies | 1085.2 | 783641 | 5.0 |
| month 6 | 182 | Columnar | query_latest_single | 0.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 90.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 13125.2 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_anomalies | 1062.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_threshold_breach | 76.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_spatial_radius | 1.2 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_single | 0.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_zone | 0.8 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_window | 59.0 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 61.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_hourly_rollup | 90.4 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 11909.2 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_threshold_breach | 84.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_anomalies | 1284.9 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_single | 0.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_zone | 0.8 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_window | 62.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 61.5 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 9268.3 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_threshold_breach | 86.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_single | 0.0 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_zone | 0.7 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 62.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_daily_zone_rollup | 9291.8 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_zone_hierarchy | 2.0 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_spatial_radius | 1.9 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_single | 0.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_zone | 0.9 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_window | 88.0 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 78.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_threshold_breach | 123.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_anomalies | 2842.2 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_single | 0.1 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_latest_zone | 0.9 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_window | 63.3 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_avg_zone_type | 66.9 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_threshold_breach | 78.6 | 1578597 | 9.7 |
| month 6 | 182 | Columnar | query_anomalies | 1184.2 | 1578597 | 9.7 |
| year 1 | 365 | Columnar | query_latest_single | 0.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 71.9 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 17649.6 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_anomalies | 1061.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_threshold_breach | 87.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_spatial_radius | 1.4 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_single | 0.1 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_zone | 0.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_window | 164.8 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 129.4 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_hourly_rollup | 207.2 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 16912.6 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_threshold_breach | 121.3 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_anomalies | 1267.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_single | 0.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_zone | 0.8 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_window | 70.4 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 69.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 19193.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_threshold_breach | 93.5 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_single | 0.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_zone | 0.8 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 74.5 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_daily_zone_rollup | 18365.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_zone_hierarchy | 1.4 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_spatial_radius | 1.2 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_single | 0.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_zone | 0.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_window | 76.2 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 75.1 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_threshold_breach | 94.0 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_anomalies | 1169.7 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_single | 0.1 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_latest_zone | 0.6 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_window | 73.5 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_avg_zone_type | 70.4 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_threshold_breach | 85.2 | 3159715 | 19.4 |
| year 1 | 365 | Columnar | query_anomalies | 1016.7 | 3159715 | 19.4 |
| year 2 | 730 | Columnar | query_latest_single | 0.0 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 59.7 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 17170.0 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_anomalies | 969.2 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 81.3 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_spatial_radius | 1.2 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_zone | 0.7 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_window | 59.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 59.0 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_hourly_rollup | 92.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 17597.3 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 87.9 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_anomalies | 2385.4 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.0 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_zone | 0.7 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_window | 68.9 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 63.3 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 17553.4 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 87.8 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_zone | 0.5 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 62.7 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_daily_zone_rollup | 18508.2 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_zone_hierarchy | 2.5 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_spatial_radius | 1.2 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_zone | 0.6 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_window | 65.0 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 62.5 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 84.8 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_anomalies | 1010.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_single | 0.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_latest_zone | 0.5 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_window | 61.7 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_avg_zone_type | 61.4 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_threshold_breach | 84.1 | 3627868 | 23.1 |
| year 2 | 730 | Columnar | query_anomalies | 999.0 | 3627868 | 23.1 |
| year 3 | 1095 | Columnar | query_latest_single | 0.2 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 96.8 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 32162.1 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_anomalies | 1174.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 85.2 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_spatial_radius | 1.5 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.1 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 0.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_window | 68.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 68.6 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_hourly_rollup | 100.7 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 19280.1 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 87.6 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_anomalies | 1832.3 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.1 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 0.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_window | 69.2 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 69.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 18477.4 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 85.3 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.0 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 0.6 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 67.3 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_daily_zone_rollup | 20116.9 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_zone_hierarchy | 1.7 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_spatial_radius | 1.2 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.1 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 0.8 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_window | 73.0 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 69.7 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 84.6 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_anomalies | 1047.0 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_single | 0.0 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_latest_zone | 0.7 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_window | 68.6 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_avg_zone_type | 68.7 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_threshold_breach | 88.0 | 3838073 | 24.4 |
| year 3 | 1095 | Columnar | query_anomalies | 1332.7 | 3838073 | 24.4 |
| year 4 | 1460 | Columnar | query_latest_single | 0.0 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 68.9 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 23832.8 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_anomalies | 998.2 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_threshold_breach | 79.5 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_spatial_radius | 1.3 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_single | 0.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_zone | 0.7 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_window | 63.3 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 63.5 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_hourly_rollup | 93.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 17432.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_threshold_breach | 79.8 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_anomalies | 1580.4 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_single | 0.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_zone | 0.7 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_window | 69.6 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 63.4 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 19584.3 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_threshold_breach | 86.9 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_single | 0.0 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_zone | 0.9 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 65.3 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_daily_zone_rollup | 17941.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_zone_hierarchy | 1.8 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_spatial_radius | 1.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_single | 0.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_zone | 0.8 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_window | 70.6 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 68.2 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_threshold_breach | 83.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_anomalies | 1037.7 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_single | 0.1 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_latest_zone | 0.6 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_window | 66.2 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_avg_zone_type | 66.2 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_threshold_breach | 82.2 | 4048432 | 25.7 |
| year 4 | 1460 | Columnar | query_anomalies | 1040.1 | 4048432 | 25.7 |
| year 5 | 1825 | Columnar | query_latest_single | 0.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 70.5 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 16964.7 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_anomalies | 934.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_threshold_breach | 80.9 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_spatial_radius | 1.2 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_single | 0.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_zone | 0.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_window | 65.9 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 66.1 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_hourly_rollup | 91.3 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 16988.7 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_threshold_breach | 83.5 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_anomalies | 935.3 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_single | 0.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_zone | 0.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_window | 65.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 65.8 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 16529.5 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_threshold_breach | 80.2 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_single | 0.1 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_zone | 0.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 64.7 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_daily_zone_rollup | 19365.4 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_zone_hierarchy | 1.4 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_spatial_radius | 1.1 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_single | 0.1 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_zone | 0.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_window | 67.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 64.7 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_threshold_breach | 77.6 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_anomalies | 892.8 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_single | 0.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_latest_zone | 0.5 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_window | 140.9 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_avg_zone_type | 66.0 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_threshold_breach | 126.2 | 4258844 | 27.0 |
| year 5 | 1825 | Columnar | query_anomalies | 1048.4 | 4258844 | 27.0 |
| year 6 | 2190 | Columnar | query_latest_single | 0.1 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 74.2 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 18732.2 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_anomalies | 1009.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_threshold_breach | 82.3 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_spatial_radius | 1.2 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_single | 0.1 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_zone | 0.6 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_window | 66.7 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 66.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_hourly_rollup | 97.8 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 19352.7 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_threshold_breach | 90.4 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_anomalies | 1068.7 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_single | 0.1 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_zone | 0.7 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_window | 69.8 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 70.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 18462.7 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_threshold_breach | 102.3 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_single | 0.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_zone | 0.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 164.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_daily_zone_rollup | 19542.3 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_zone_hierarchy | 1.4 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_spatial_radius | 1.1 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_single | 0.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_zone | 0.6 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_window | 70.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 75.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_threshold_breach | 82.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_anomalies | 1031.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_single | 0.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_latest_zone | 0.6 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_window | 67.0 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_avg_zone_type | 66.9 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_threshold_breach | 81.4 | 4468874 | 28.3 |
| year 6 | 2190 | Columnar | query_anomalies | 984.0 | 4468874 | 28.3 |
| year 7 | 2555 | Columnar | query_latest_single | 0.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 60.3 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 17656.2 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_anomalies | 1872.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_threshold_breach | 77.6 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_spatial_radius | 1.2 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_single | 0.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_zone | 0.8 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_window | 77.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 64.8 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_hourly_rollup | 93.5 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 18475.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_threshold_breach | 84.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_anomalies | 990.9 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_single | 0.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_zone | 0.7 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_window | 65.4 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 65.3 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 17435.5 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_threshold_breach | 77.6 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_single | 0.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_zone | 0.8 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 60.8 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_daily_zone_rollup | 17798.4 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_zone_hierarchy | 1.3 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_spatial_radius | 1.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_single | 0.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_zone | 1.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_window | 62.8 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 61.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_threshold_breach | 75.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_anomalies | 910.3 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_single | 0.1 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_latest_zone | 0.5 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_window | 61.3 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_avg_zone_type | 60.0 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_threshold_breach | 73.7 | 4679292 | 29.6 |
| year 7 | 2555 | Columnar | query_anomalies | 901.0 | 4679292 | 29.6 |
| steady state | 2682 | Columnar | query_latest_single | 0.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 55.6 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 17571.7 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_anomalies | 1106.7 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_threshold_breach | 134.6 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_spatial_radius | 1.5 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_single | 0.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_zone | 0.9 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_window | 55.7 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 59.3 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_hourly_rollup | 120.4 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 16830.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_threshold_breach | 109.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_anomalies | 930.3 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_single | 0.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_zone | 0.8 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_window | 52.8 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 52.4 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 17728.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_threshold_breach | 112.9 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_single | 0.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_zone | 0.6 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 55.9 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_daily_zone_rollup | 17422.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_zone_hierarchy | 1.5 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_spatial_radius | 1.2 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_single | 0.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_zone | 0.7 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_window | 59.5 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 55.6 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_threshold_breach | 108.7 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_anomalies | 964.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_single | 0.1 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_latest_zone | 0.5 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_window | 54.4 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_avg_zone_type | 54.2 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_threshold_breach | 108.0 | 4679221 | 29.8 |
| steady state | 2682 | Columnar | query_anomalies | 1344.6 | 4679221 | 29.8 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 3.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 13.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_spatial_radius | 1.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_hourly_rollup | 5.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 2.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 0.2 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 12.9 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 0.4 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 3.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_daily_zone_rollup | 2.7 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_zone_hierarchy | 0.8 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_spatial_radius | 1.0 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 0.2 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 12.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_single | 0.1 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_latest_zone | 0.3 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_window | 0.5 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_avg_zone_type | 0.6 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_threshold_breach | 0.2 | 8713 | 0.5 |
| day 1 | 1 | Hierarchical | query_anomalies | 12.6 | 8713 | 0.5 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 18.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 80.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_spatial_radius | 1.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.1 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 0.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_hourly_rollup | 9.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 18.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 80.7 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.0 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 0.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 18.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.0 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 0.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_daily_zone_rollup | 18.2 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_zone_hierarchy | 0.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_spatial_radius | 1.0 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.0 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 0.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 80.8 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_single | 0.0 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_latest_zone | 0.3 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_window | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_avg_zone_type | 0.6 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_threshold_breach | 0.5 | 60917 | 3.4 |
| week 1 | 7 | Hierarchical | query_anomalies | 80.7 | 60917 | 3.4 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 0.8 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 163.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 79.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 0.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_spatial_radius | 1.2 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 0.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_hourly_rollup | 11.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 178.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 0.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 78.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 0.2 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 160.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 0.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 0.3 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_daily_zone_rollup | 275.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_zone_hierarchy | 1.8 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_spatial_radius | 1.9 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 0.4 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 0.7 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 1.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 1.0 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 79.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_single | 0.1 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_latest_zone | 0.2 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_window | 0.5 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_avg_zone_type | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_threshold_breach | 0.6 | 261188 | 15.0 |
| month 1 | 30 | Hierarchical | query_anomalies | 91.8 | 261188 | 15.0 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.8 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 503.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 85.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_spatial_radius | 1.2 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 0.4 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 0.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_hourly_rollup | 11.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 457.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 0.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 86.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 0.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 463.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 0.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_daily_zone_rollup | 468.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_zone_hierarchy | 1.0 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_spatial_radius | 1.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 0.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 0.5 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 85.2 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_single | 0.1 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_latest_zone | 0.3 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_window | 0.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_avg_zone_type | 0.7 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_threshold_breach | 0.6 | 783641 | 43.5 |
| month 3 | 90 | Hierarchical | query_anomalies | 84.3 | 783641 | 43.5 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.8 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 1149.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 85.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 0.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_spatial_radius | 1.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 0.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_hourly_rollup | 12.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 1014.7 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 83.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 0.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 873.4 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 0.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_daily_zone_rollup | 910.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_zone_hierarchy | 1.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_spatial_radius | 1.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.1 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 0.2 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 82.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_single | 0.0 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_latest_zone | 0.3 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_window | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_avg_zone_type | 0.6 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_threshold_breach | 0.5 | 1578597 | 79.1 |
| month 6 | 182 | Hierarchical | query_anomalies | 82.3 | 1578597 | 79.1 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.8 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 1857.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 80.8 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 0.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_spatial_radius | 1.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 0.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_hourly_rollup | 12.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 2662.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 1.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 131.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 0.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 2005.9 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 0.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 0.3 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_daily_zone_rollup | 1746.4 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_zone_hierarchy | 1.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_spatial_radius | 1.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 0.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 0.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 0.7 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 79.0 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_single | 0.1 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_latest_zone | 0.2 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_window | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_avg_zone_type | 0.6 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_threshold_breach | 0.5 | 3159715 | 179.4 |
| year 1 | 365 | Hierarchical | query_anomalies | 78.4 | 3159715 | 179.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 2002.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 91.0 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 0.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_spatial_radius | 1.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 0.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 0.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_hourly_rollup | 13.4 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 2006.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 0.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 90.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 0.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 0.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 2949.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 0.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.0 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 0.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_daily_zone_rollup | 2046.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_zone_hierarchy | 1.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_spatial_radius | 1.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.0 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 0.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 0.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 0.8 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 90.9 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_single | 0.1 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_latest_zone | 0.3 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_window | 0.5 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_avg_zone_type | 0.6 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_threshold_breach | 0.7 | 3627868 | 186.4 |
| year 2 | 730 | Hierarchical | query_anomalies | 89.4 | 3627868 | 186.4 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 0.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 3407.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 101.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 0.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_spatial_radius | 1.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 0.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 0.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 0.7 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_hourly_rollup | 12.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 2411.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 0.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 90.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 0.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 0.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 0.7 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 2179.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 0.7 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 0.3 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 0.7 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_daily_zone_rollup | 3258.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_zone_hierarchy | 2.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_spatial_radius | 2.2 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 0.5 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 0.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 0.8 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 1.1 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 152.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_single | 0.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_latest_zone | 0.4 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_window | 0.6 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_avg_zone_type | 1.0 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_threshold_breach | 0.9 | 3838073 | 235.6 |
| year 3 | 1095 | Hierarchical | query_anomalies | 132.6 | 3838073 | 235.6 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 1.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 2139.4 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 83.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 0.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_spatial_radius | 1.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.1 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 0.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 0.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_hourly_rollup | 12.1 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 3109.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 0.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 84.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.0 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 0.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 0.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 2831.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 0.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.0 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 0.2 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_daily_zone_rollup | 2374.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_zone_hierarchy | 1.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_spatial_radius | 1.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.0 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 0.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 0.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 0.6 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 83.8 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_single | 0.1 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_latest_zone | 0.3 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_window | 0.5 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_avg_zone_type | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_threshold_breach | 0.7 | 4048432 | 245.1 |
| year 4 | 1460 | Hierarchical | query_anomalies | 82.4 | 4048432 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 1.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 2383.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 95.2 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 0.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_spatial_radius | 1.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 0.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 0.7 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 0.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_hourly_rollup | 13.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 2084.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 0.8 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 90.7 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 0.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 0.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 0.7 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 2464.8 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 1.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 0.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 1.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_daily_zone_rollup | 2120.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_zone_hierarchy | 1.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_spatial_radius | 1.4 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.1 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 0.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 0.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 0.8 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 0.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 92.9 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_single | 0.0 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_latest_zone | 0.3 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_window | 0.6 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_avg_zone_type | 0.7 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_threshold_breach | 0.8 | 4258844 | 245.1 |
| year 5 | 1825 | Hierarchical | query_anomalies | 119.1 | 4258844 | 245.1 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 1.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 2323.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 88.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 1.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_spatial_radius | 1.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 0.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 0.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 0.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_hourly_rollup | 22.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 3319.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 1.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 134.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 0.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 0.7 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 1.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 4420.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 0.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.0 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 0.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 1.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_daily_zone_rollup | 4459.6 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_zone_hierarchy | 2.3 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_spatial_radius | 2.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 0.4 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 0.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 1.1 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 1.0 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 200.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_single | 0.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_latest_zone | 0.8 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_window | 0.9 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_avg_zone_type | 1.2 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_threshold_breach | 1.5 | 4468874 | 259.3 |
| year 6 | 2190 | Hierarchical | query_anomalies | 159.4 | 4468874 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 1.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 2798.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 92.9 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 0.9 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_spatial_radius | 1.4 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 0.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 0.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_hourly_rollup | 13.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 2277.2 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 82.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 0.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 0.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 2722.2 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 1.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 0.5 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 1.0 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_daily_zone_rollup | 2263.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_zone_hierarchy | 1.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_spatial_radius | 1.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 0.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 0.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 0.8 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 82.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_single | 0.1 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_latest_zone | 0.3 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_window | 0.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_avg_zone_type | 0.7 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_threshold_breach | 0.6 | 4679292 | 259.3 |
| year 7 | 2555 | Hierarchical | query_anomalies | 84.6 | 4679292 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 1.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 1901.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 86.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 0.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_spatial_radius | 1.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 0.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 0.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_hourly_rollup | 11.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 1869.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 0.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 83.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 0.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 0.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 2831.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 0.9 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 0.4 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 0.8 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_daily_zone_rollup | 1826.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_zone_hierarchy | 1.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_spatial_radius | 1.2 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.0 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 0.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 0.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 0.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 82.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_single | 0.1 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_latest_zone | 0.3 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_window | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_avg_zone_type | 0.7 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_threshold_breach | 0.6 | 4679221 | 259.3 |
| steady state | 2682 | Hierarchical | query_anomalies | 81.3 | 4679221 | 259.3 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 1.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 5.2 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 0.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_spatial_radius | 1.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 0.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 0.7 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 3.8 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 0.7 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.0 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 0.6 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_zone_hierarchy | 0.9 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_spatial_radius | 1.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 0.5 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 0.6 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 3.7 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_single | 0.1 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_latest_zone | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_window | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_avg_zone_type | 0.6 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_threshold_breach | 0.4 | 384 | 0.0 |
| day 1 | 1 | RingBuffer | query_anomalies | 3.8 | 384 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 4.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 0.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 3.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 0.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 3.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| week 1 | 7 | RingBuffer | query_anomalies | 3.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.8 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 4.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_spatial_radius | 1.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 0.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 3.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 1 | 30 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 0.8 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 4.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_spatial_radius | 1.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 14.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_zone_hierarchy | 0.7 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_spatial_radius | 0.9 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 3 | 90 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 1.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 4.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 0.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_spatial_radius | 1.2 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 0.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 3.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_zone_hierarchy | 0.7 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| month 6 | 182 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.9 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 4.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_spatial_radius | 1.2 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 0.2 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 1 | 365 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 1.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 4.7 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 0.7 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_spatial_radius | 9.2 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 4.8 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_zone_hierarchy | 0.9 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 3.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 2 | 730 | RingBuffer | query_anomalies | 3.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 1.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 3.8 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 0.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_spatial_radius | 0.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 0.2 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 2.9 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 3 | 1095 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.7 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 3.8 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 2.7 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_zone_hierarchy | 0.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_spatial_radius | 0.8 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 0.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 2.6 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 4 | 1460 | RingBuffer | query_anomalies | 2.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 5.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 2.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 0.2 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_zone_hierarchy | 0.7 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_spatial_radius | 0.9 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 2.8 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 5 | 1825 | RingBuffer | query_anomalies | 3.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.8 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 3.7 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 2.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_zone_hierarchy | 0.7 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_spatial_radius | 0.9 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 3.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_avg_zone_type | 0.4 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_threshold_breach | 0.2 | 390 | 0.0 |
| year 6 | 2190 | RingBuffer | query_anomalies | 2.7 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.8 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 4.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_spatial_radius | 1.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 3.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| year 7 | 2555 | RingBuffer | query_anomalies | 3.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 1.7 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 4.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_spatial_radius | 1.2 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 3.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 0.6 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_zone_hierarchy | 0.8 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_spatial_radius | 1.0 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 0.9 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 0.4 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 3.2 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_single | 0.1 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_latest_zone | 0.5 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_window | 0.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_avg_zone_type | 0.6 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_threshold_breach | 0.3 | 390 | 0.0 |
| steady state | 2682 | RingBuffer | query_anomalies | 3.3 | 390 | 0.0 |
| day 1 | 1 | Lake | query_latest_single | 26.3 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.9 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 51.2 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_anomalies | 195.2 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_threshold_breach | 46.3 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_spatial_radius | 1.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_window | 48.6 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.2 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_hourly_rollup | 50.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 49.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_threshold_breach | 45.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_anomalies | 193.9 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_single | 0.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_window | 45.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.2 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 49.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_threshold_breach | 45.6 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_single | 0.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_daily_zone_rollup | 48.5 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_zone_hierarchy | 0.7 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_spatial_radius | 1.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_single | 0.1 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_window | 46.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.3 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_threshold_breach | 45.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_anomalies | 193.7 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_single | 0.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_latest_zone | 0.4 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_window | 45.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_avg_zone_type | 46.0 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_threshold_breach | 45.8 | 8713 | 0.1 |
| day 1 | 1 | Lake | query_anomalies | 196.8 | 8713 | 0.1 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 85.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 429.6 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_anomalies | 1379.6 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_threshold_breach | 126.3 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_spatial_radius | 1.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_zone | 0.6 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_window | 86.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 80.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_hourly_rollup | 137.5 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 341.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_threshold_breach | 127.0 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_anomalies | 1355.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_zone | 0.5 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_window | 79.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 79.7 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 339.9 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_threshold_breach | 125.2 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_zone | 0.4 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 79.7 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_daily_zone_rollup | 337.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_zone_hierarchy | 0.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_spatial_radius | 1.0 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_zone | 0.4 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_window | 79.5 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 81.0 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_threshold_breach | 124.9 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_anomalies | 1384.2 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_single | 0.1 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_latest_zone | 0.4 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_window | 81.8 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_avg_zone_type | 80.0 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_threshold_breach | 194.6 | 60917 | 0.4 |
| week 1 | 7 | Lake | query_anomalies | 1537.3 | 60917 | 0.4 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 80.3 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 1846.0 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_anomalies | 1503.4 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_threshold_breach | 125.5 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_spatial_radius | 1.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_zone | 0.6 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_window | 79.9 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 79.4 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_hourly_rollup | 136.4 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 1793.2 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_threshold_breach | 125.8 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_anomalies | 3259.4 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_zone | 0.8 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_window | 165.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 156.4 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 2410.2 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_threshold_breach | 126.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_zone | 0.7 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 85.8 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_daily_zone_rollup | 1845.9 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_zone_hierarchy | 1.2 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_spatial_radius | 1.0 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_zone | 0.6 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_window | 80.6 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 79.7 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_threshold_breach | 125.2 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_anomalies | 2434.9 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_single | 0.1 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_latest_zone | 0.7 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_window | 80.2 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_avg_zone_type | 80.5 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_threshold_breach | 124.8 | 261188 | 1.9 |
| month 1 | 30 | Lake | query_anomalies | 1526.3 | 261188 | 1.9 |
| month 3 | 90 | Lake | query_latest_single | 0.1 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 78.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 4815.2 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_anomalies | 1634.9 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_threshold_breach | 116.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_spatial_radius | 1.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_single | 0.1 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_zone | 0.6 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_window | 73.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 101.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_hourly_rollup | 137.2 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 5209.5 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_threshold_breach | 117.5 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_anomalies | 1710.6 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_single | 0.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_zone | 0.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_window | 118.9 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 79.3 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 5567.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_threshold_breach | 121.9 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_single | 0.1 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_zone | 0.5 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 82.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_daily_zone_rollup | 5505.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_zone_hierarchy | 1.3 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_spatial_radius | 1.0 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_single | 0.1 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_zone | 0.6 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_window | 82.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 80.9 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_threshold_breach | 124.2 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_anomalies | 1463.2 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_single | 0.1 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_latest_zone | 0.5 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_window | 81.7 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_avg_zone_type | 91.4 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_threshold_breach | 123.9 | 783641 | 5.6 |
| month 3 | 90 | Lake | query_anomalies | 1450.7 | 783641 | 5.6 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 89.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 11278.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_anomalies | 2035.5 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_threshold_breach | 138.8 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_spatial_radius | 1.4 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_zone | 0.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_window | 92.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 91.9 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_hourly_rollup | 152.5 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 11825.2 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_threshold_breach | 141.5 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_anomalies | 1548.8 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_zone | 0.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_window | 92.0 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 91.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 12625.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_threshold_breach | 141.3 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_zone | 0.8 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 94.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_daily_zone_rollup | 11674.4 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_zone_hierarchy | 1.3 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_spatial_radius | 1.2 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_zone | 0.7 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_window | 93.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 90.3 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_threshold_breach | 135.6 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_anomalies | 2465.0 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_single | 0.1 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_latest_zone | 0.9 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_window | 156.2 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_avg_zone_type | 131.4 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_threshold_breach | 227.5 | 1578597 | 11.3 |
| month 6 | 182 | Lake | query_anomalies | 1577.0 | 1578597 | 11.3 |
| year 1 | 365 | Lake | query_latest_single | 0.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 103.4 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 23313.6 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_anomalies | 1504.6 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_threshold_breach | 135.6 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_spatial_radius | 1.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_single | 0.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_zone | 0.6 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_window | 96.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 95.5 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_hourly_rollup | 141.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 23089.3 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_threshold_breach | 142.3 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_anomalies | 1592.2 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_single | 0.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_zone | 0.7 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_window | 106.5 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 128.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 22449.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_threshold_breach | 149.2 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_single | 0.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_zone | 0.7 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 103.9 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_daily_zone_rollup | 22224.5 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_zone_hierarchy | 1.3 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_spatial_radius | 1.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_single | 0.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_zone | 0.7 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_window | 100.8 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 104.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_threshold_breach | 134.9 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_anomalies | 1450.2 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_single | 0.1 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_latest_zone | 0.5 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_window | 96.3 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_avg_zone_type | 95.0 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_threshold_breach | 134.8 | 3159715 | 22.6 |
| year 1 | 365 | Lake | query_anomalies | 2543.2 | 3159715 | 22.6 |
| year 2 | 730 | Lake | query_latest_single | 0.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 101.4 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 25285.0 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_anomalies | 1632.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_threshold_breach | 153.0 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_spatial_radius | 1.2 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_single | 0.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_zone | 0.7 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_window | 107.5 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 106.5 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_hourly_rollup | 164.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 22765.2 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_threshold_breach | 150.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_anomalies | 1478.2 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_single | 0.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_zone | 0.5 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_window | 95.4 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 95.6 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 23126.8 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_threshold_breach | 148.4 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_single | 0.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_zone | 0.6 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 99.8 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_daily_zone_rollup | 22353.3 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_zone_hierarchy | 1.5 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_spatial_radius | 1.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_single | 0.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_zone | 0.7 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_window | 104.2 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 102.7 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_threshold_breach | 145.9 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_anomalies | 1537.5 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_single | 0.0 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_latest_zone | 0.6 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_window | 102.9 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_avg_zone_type | 102.1 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_threshold_breach | 145.8 | 3627868 | 25.9 |
| year 2 | 730 | Lake | query_anomalies | 2203.3 | 3627868 | 25.9 |
| year 3 | 1095 | Lake | query_latest_single | 0.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 97.2 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 24459.0 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_anomalies | 2228.6 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_threshold_breach | 152.8 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_spatial_radius | 1.3 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_single | 0.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_zone | 0.9 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_window | 135.3 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 127.3 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_hourly_rollup | 164.6 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 30090.4 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_threshold_breach | 270.8 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_anomalies | 1729.2 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_single | 0.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_zone | 1.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_window | 111.9 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 110.3 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 32451.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_threshold_breach | 185.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_single | 0.4 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_zone | 0.6 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 140.0 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_daily_zone_rollup | 28321.2 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_zone_hierarchy | 1.9 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_spatial_radius | 1.2 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_single | 0.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_zone | 0.9 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_window | 116.7 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 115.7 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_threshold_breach | 167.0 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_anomalies | 1756.3 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_single | 0.1 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_latest_zone | 0.5 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_window | 119.4 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_avg_zone_type | 115.2 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_threshold_breach | 164.9 | 3838073 | 27.4 |
| year 3 | 1095 | Lake | query_anomalies | 1778.5 | 3838073 | 27.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 127.3 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 23664.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_anomalies | 1630.2 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_threshold_breach | 166.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_spatial_radius | 1.1 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.1 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_zone | 0.6 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_window | 122.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 122.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_hourly_rollup | 178.7 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 25078.3 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_threshold_breach | 181.3 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_anomalies | 2331.5 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_zone | 1.2 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_window | 137.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 135.5 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 25675.3 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_threshold_breach | 262.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.1 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_zone | 1.3 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 145.2 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_daily_zone_rollup | 24529.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_zone_hierarchy | 2.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_spatial_radius | 1.8 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.1 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_zone | 1.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_window | 136.1 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 136.7 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_threshold_breach | 171.9 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_anomalies | 1643.6 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_single | 0.0 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_latest_zone | 0.5 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_window | 122.4 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_avg_zone_type | 122.5 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_threshold_breach | 163.9 | 4048432 | 29.4 |
| year 4 | 1460 | Lake | query_anomalies | 1559.9 | 4048432 | 29.4 |
| year 5 | 1825 | Lake | query_latest_single | 0.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 250.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 28818.9 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_anomalies | 2072.6 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_threshold_breach | 193.4 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_spatial_radius | 1.5 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_single | 0.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_zone | 0.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_window | 136.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 176.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_hourly_rollup | 195.3 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 28945.3 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_threshold_breach | 224.6 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_anomalies | 1820.5 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_single | 0.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_zone | 0.9 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_window | 143.2 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 142.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 28736.3 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_threshold_breach | 311.2 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_single | 0.0 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_zone | 1.4 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 145.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_daily_zone_rollup | 28028.9 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_zone_hierarchy | 1.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_spatial_radius | 1.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_single | 0.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_zone | 0.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_window | 142.6 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 152.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_threshold_breach | 190.0 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_anomalies | 1860.5 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_single | 0.1 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_latest_zone | 0.6 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_window | 142.0 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_avg_zone_type | 141.7 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_threshold_breach | 190.5 | 4258844 | 30.9 |
| year 5 | 1825 | Lake | query_anomalies | 3158.7 | 4258844 | 30.9 |
| year 6 | 2190 | Lake | query_latest_single | 0.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 138.4 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 24385.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_anomalies | 3590.7 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_threshold_breach | 191.0 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_spatial_radius | 1.7 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_single | 0.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_zone | 0.8 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_window | 138.6 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 138.5 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_hourly_rollup | 200.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 25106.4 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_threshold_breach | 186.0 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_anomalies | 1743.3 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_single | 0.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_zone | 0.9 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_window | 138.5 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 137.9 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 26511.4 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_threshold_breach | 187.9 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_single | 0.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_zone | 0.7 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 138.4 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_daily_zone_rollup | 23627.6 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_zone_hierarchy | 1.5 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_spatial_radius | 1.2 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_single | 0.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_zone | 0.8 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_window | 139.4 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 139.5 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_threshold_breach | 184.5 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_anomalies | 1742.3 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_single | 0.0 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_latest_zone | 0.7 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_window | 138.2 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_avg_zone_type | 142.7 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_threshold_breach | 237.1 | 4468874 | 32.4 |
| year 6 | 2190 | Lake | query_anomalies | 1803.7 | 4468874 | 32.4 |
| year 7 | 2555 | Lake | query_latest_single | 0.1 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 191.2 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 25367.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_anomalies | 1740.2 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_threshold_breach | 184.6 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_spatial_radius | 1.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_single | 0.0 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_zone | 0.8 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_window | 141.5 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 138.8 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_hourly_rollup | 198.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 25096.9 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_threshold_breach | 185.7 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_anomalies | 1760.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_single | 0.0 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_zone | 0.7 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_window | 139.4 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 139.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 24460.4 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_threshold_breach | 190.5 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_single | 0.0 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_zone | 0.9 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 147.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_daily_zone_rollup | 24088.6 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_zone_hierarchy | 1.5 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_spatial_radius | 1.1 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_single | 0.1 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_zone | 0.7 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_window | 139.6 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 141.6 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_threshold_breach | 208.8 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_anomalies | 1801.0 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_single | 0.0 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_latest_zone | 0.7 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_window | 139.3 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_avg_zone_type | 138.7 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_threshold_breach | 197.1 | 4679292 | 33.9 |
| year 7 | 2555 | Lake | query_anomalies | 1746.1 | 4679292 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.1 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 139.3 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 24991.3 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_anomalies | 3089.7 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_threshold_breach | 210.0 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_spatial_radius | 1.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.1 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_zone | 0.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_window | 145.6 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 145.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_hourly_rollup | 205.1 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 25275.3 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_threshold_breach | 185.0 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_anomalies | 1745.3 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.0 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_zone | 1.0 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_window | 139.4 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 139.2 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 24354.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_threshold_breach | 190.3 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.1 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_zone | 0.7 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 140.2 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_daily_zone_rollup | 25268.4 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_zone_hierarchy | 1.6 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_spatial_radius | 1.2 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.1 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_zone | 0.7 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_window | 149.4 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 159.4 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_threshold_breach | 267.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_anomalies | 1833.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_single | 0.0 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_latest_zone | 0.7 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_window | 145.4 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_avg_zone_type | 147.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_threshold_breach | 211.9 | 4679221 | 33.9 |
| steady state | 2682 | Lake | query_anomalies | 1852.4 | 4679221 | 33.9 |

## Simulation Summary

Per-backend wall-time cost of the live day-zero simulation (simulated time / wall time = compression ratio), data volume, and prune activity.

| Backend | Sim days | Wall time (s) | Compression | Generated | Evicted | Prune calls | Stream time (s) | Prune time (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| TimeSeries | 2682 | 16.1 | 14426644× | 23352775 | 18673554 | 552 | 5.1 | 0.1 |
| Columnar | 2682 | 14.7 | 15750039× | 23352775 | 18673554 | 552 | 4.2 | 0.1 |
| Hierarchical | 2682 | 38.6 | 6004980× | 23352775 | 18673554 | 552 | 3.7 | 29.1 |
| RingBuffer | 2682 | 3.0 | 76947113× | 23352775 | 0 | 552 | 3.0 | 0.0 |
| Lake | 2682 | 10.0 | 23106871× | 23352775 | 18673554 | 552 | 4.8 | 0.0 |

### Steady-state data volume by sensor type

| Sensor type | Readings | Bytes (MB) |
|---|---:|---:|
| structural | 1471680 | 33.7 |
| temperature | 800352 | 18.3 |
| humidity | 800352 | 18.3 |
| occupancy | 6133 | 0.1 |
| co2 | 800352 | 18.3 |
| air_quality | 800352 | 18.3 |
