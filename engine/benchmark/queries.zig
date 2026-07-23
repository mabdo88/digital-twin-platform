// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Benchmark query functions — pure functions over World(T) queries.
//
// Per CLAUDE.md §3.1: these functions accept any World(T) via `anytype` and
// never branch on the concrete backend type. The same function compiles and
// runs unchanged whether T is AoSStorage, SoAStorage, or any future backend.
//
// This file is the canonical home for the 12 query patterns across 5
// families (real-time, aggregation, historical, spatial, anomaly).
// query_avg_window is the first: an aggregation query that computes the
// average value of a specific sensor over a trailing time window.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");

pub const QueryFamily = enum {
    real_time,
    aggregation,
    historical,
    spatial,
    anomaly,
};

/// Family of a query, at the enum level. Single source of truth — must stay
/// consistent with `QUERY_PATTERNS` below (which carries the same mapping
/// keyed by display name for the reports). `real_time` is the only family
/// whose data need fits within a tiny live cache (the latest reading[s]);
/// every other family needs more history than a real-time buffer holds,
/// which is what the compound recommendation (report.zig) splits on.
pub fn familyOf(q: QueryName) QueryFamily {
    return switch (q) {
        .latest_single, .latest_zone, .latest_by_type => .real_time,
        .avg_window, .avg_zone_type, .floor_stats => .aggregation,
        .hourly_rollup, .daily_zone_rollup => .historical,
        .spatial_radius, .zone_hierarchy => .spatial,
        .anomalies, .threshold_breach => .anomaly,
    };
}

/// One value per query pattern this file implements — was previously
/// mirrored in bim/profiles.zig (kept separate "so profiles.zig has no
/// dependency on the benchmark layer"), back when query relevance was a
/// building-profile concern. Now that relevance is a per-sensor-type fact
/// (synthetic/generator.zig's SensorProfile.relevant_queries) rather than a
/// building-type guess, there's no more reason for two copies of this
/// enum to exist — this is the one.
pub const QueryName = enum {
    avg_window,
    avg_zone_type,
    floor_stats,
    hourly_rollup,
    daily_zone_rollup,
    spatial_radius,
    zone_hierarchy,
    anomalies,
    threshold_breach,
    latest_single,
    latest_zone,
    latest_by_type,
};

/// How much a given query matters for whatever it's attached to (a sensor
/// type's profile, or main.zig's derived building-level mix — see
/// synthetic/generator.zig's SensorProfile.relevant_queries doc comment).
/// `weight` is relative call frequency, not normalized to 1.0. `hot` marks
/// queries that hit live/recent data vs. `cold` (historical/reporting).
pub const QueryWeight = struct {
    query: QueryName,
    weight: f32,
    hot: bool,
};

pub const QueryPattern = struct {
    name: []const u8,
    family: QueryFamily,
    description: []const u8,
};

/// Three-component position used by spatial queries.
/// Derived deterministically from sensor_id so all backends agree.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

/// A sensor entity ID — the unit returned by spatial queries.
pub const EntityId = u32;

/// Aggregated statistics for floor-level queries (Q6).
pub const Stats = struct {
    min: f32,
    max: f32,
    avg: f32,
};

/// Hourly aggregate for Q7 (historical rollup).
pub const HourlyAggregate = struct {
    /// Epoch-ms of the hour bucket start.
    hour_bucket: i64,
    avg: f32,
    min: f32,
    max: f32,
    count: u32,
};

/// Daily aggregate for Q8 (historical rollup).
pub const DailyAggregate = struct {
    /// Epoch-ms of the day bucket start.
    day_bucket: i64,
    avg: f32,
    min: f32,
    max: f32,
    count: u32,
};

pub const QUERY_PATTERNS = [_]QueryPattern{
    .{ .name = "query_avg_window", .family = .aggregation, .description = "Average value for a sensor over trailing hours" },
    .{ .name = "query_latest_single", .family = .real_time, .description = "Latest reading for a single sensor" },
    .{ .name = "query_latest_zone", .family = .real_time, .description = "Latest reading per sensor in a zone" },
    .{ .name = "query_latest_by_type", .family = .real_time, .description = "Latest reading per sensor of a given type" },
    .{ .name = "query_avg_zone_type", .family = .aggregation, .description = "Average value for sensors of a type in a zone over trailing hours" },
    .{ .name = "query_floor_stats", .family = .aggregation, .description = "Min/max/avg stats for sensors of a type on a floor over trailing hours" },
    .{ .name = "query_hourly_rollup", .family = .historical, .description = "Hourly avg/min/max/count rollup for a sensor over trailing days" },
    .{ .name = "query_daily_zone_rollup", .family = .historical, .description = "Daily avg/min/max/count rollup for sensors of a type in a zone over 1 year" },
    .{ .name = "query_spatial_radius", .family = .spatial, .description = "Sensor IDs whose registered position falls within radius_m of center" },
    .{ .name = "query_zone_hierarchy", .family = .spatial, .description = "All sensor IDs reachable from zone_id within depth levels of the hierarchy" },
    .{ .name = "query_anomalies", .family = .anomaly, .description = "Readings of a given sensor_type whose value deviates by more than N std-devs from that type's mean" },
    .{ .name = "query_threshold_breach", .family = .anomaly, .description = "First sustained run of >= min_duration_ms where sensor's value exceeds threshold" },
};

/// Q11 result: a single anomalous reading + its z-score (how many std-devs
/// from the mean). z is signed (positive = above mean, negative = below).
pub const AnomalyResult = struct {
    reading: sb.SensorReading,
    z_score: f32,
};

/// Q12 result: a sustained threshold breach for one sensor.
/// `duration_ms = end_ts - start_ts` is recorded for convenience.
pub const BreachEvent = struct {
    sensor_id: u32,
    start_ts: i64,
    end_ts: i64,
    duration_ms: i64,
    peak_value: f32,
};

/// Average value for a specific sensor over the trailing `hours` window
/// ending at the most recent reading's timestamp for that sensor.
///
/// Returns 0.0 when the sensor has no readings.
///
/// Pure: calls only world.rangeByTime and world.getLatestBySensor — no
/// backend-specific code, no branching on backend type.
pub fn query_avg_window(world: anytype, sensor_id: u32, hours: u32) !f32 {
    const latest = world.getLatestBySensor(sensor_id) orelse return 0.0;

    const ms_per_hour: i64 = 60 * 60 * 1000;
    const window_ms: i64 = @as(i64, hours) * ms_per_hour;
    const start_time: i64 = latest.timestamp - window_ms;

    const results = try world.rangeByTime(.{
        .sensor_id = sensor_id,
        .start_time = start_time,
        .end_time = latest.timestamp,
    });
    defer world.allocator.free(results);

    if (results.len == 0) return 0.0;

    var sum: f64 = 0;
    for (results) |r| sum += @as(f64, r.value);
    return @as(f32, @floatCast(sum / @as(f64, @floatFromInt(results.len))));
}

// ---------------------------------------------------------------------------
// Aggregation query family (Q5–Q6)
//
// Zone/floor membership comes from real registration data
// (World.registerZone/registerFloor), never from sensor_id arithmetic
// (CLAUDE.md §3.5: zone assignment is data the caller registered, not a
// property derivable from the id). Both queries below fetch member sensor
// IDs via world.sensorIdsByZone/sensorIdsByFloor, then pull each member's
// own readings directly via world.rangeByTime (native per-sensor, windowed
// lookup) — not a scan of every reading in the world checking membership
// one by one.
// ---------------------------------------------------------------------------

/// Q5: Average value for all sensors of a given `sensor_type` in a `zone_id`
/// over the trailing `hours` window ending at the most recent reading's
/// timestamp among those matching sensors.
///
/// Zone membership comes from real registration (World.registerZone), not
/// sensor_id arithmetic — see zoneMembership's doc comment.
/// Returns 0.0 when no matching readings exist.
///
/// Pure: calls only world.sensorIdsByZone/getLatestBySensor/rangeByTime —
/// no backend-specific code, no branching on backend type.
pub fn query_avg_zone_type(world: anytype, zone_id: u32, sensor_type: sb.SensorType, hours: u32) !f32 {
    const member_ids = try world.sensorIdsByZone(zone_id);
    defer world.allocator.free(member_ids);

    // Find the latest timestamp among matching sensors via getLatestBySensor
    // (O(1) per sensor) — avoids fetching all readings just to find the end
    // of the time window.
    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        if (world.getLatestBySensor(sid)) |r| {
            if (r.sensor_type != sensor_type) continue;
            if (latest_ts == null or r.timestamp > latest_ts.?) {
                latest_ts = r.timestamp;
            }
        }
    }

    const end_time = latest_ts orelse return 0.0;

    const ms_per_hour: i64 = 60 * 60 * 1000;
    const window_ms: i64 = @as(i64, hours) * ms_per_hour;
    const start_time: i64 = end_time - window_ms;

    // Use rangeByTime per sensor — pushes the time filter into the backend's
    // index (binary search / granule index / sorted leaves) instead of
    // materializing all readings and filtering in application code.
    var sum: f64 = 0;
    var count: usize = 0;
    for (member_ids) |sid| {
        const readings = try world.rangeByTime(.{
            .sensor_id = sid,
            .start_time = start_time,
            .end_time = end_time,
        });
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;
            sum += @as(f64, r.value);
            count += 1;
        }
    }

    if (count == 0) return 0.0;
    return @as(f32, @floatCast(sum / @as(f64, @floatFromInt(count))));
}

/// Q6: Min/max/avg stats for all sensors of a given `sensor_type` on a
/// `floor_id` over the trailing `hours` window ending at the most recent
/// reading's timestamp among those matching sensors.
///
/// Floor membership comes from real registration (World.registerFloor),
/// not sensor_id arithmetic — see floorMembership's doc comment.
/// Returns Stats{ 0, 0, 0 } when no matching readings exist.
///
/// Pure: calls only world.sensorIdsByFloor/getLatestBySensor/rangeByTime —
/// no backend-specific code, no branching on backend type.
pub fn query_floor_stats(world: anytype, floor_id: u32, sensor_type: sb.SensorType, hours: u32) !Stats {
    const member_ids = try world.sensorIdsByFloor(floor_id);
    defer world.allocator.free(member_ids);

    // Find the latest timestamp among matching sensors via getLatestBySensor
    // (O(1) per sensor).
    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        if (world.getLatestBySensor(sid)) |r| {
            if (r.sensor_type != sensor_type) continue;
            if (latest_ts == null or r.timestamp > latest_ts.?) {
                latest_ts = r.timestamp;
            }
        }
    }

    const end_time = latest_ts orelse return .{ .min = 0.0, .max = 0.0, .avg = 0.0 };

    const ms_per_hour: i64 = 60 * 60 * 1000;
    const window_ms: i64 = @as(i64, hours) * ms_per_hour;
    const start_time: i64 = end_time - window_ms;

    // Use rangeByTime per sensor — pushes the time filter into the backend's
    // index instead of materializing all readings.
    var min_val: f32 = std.math.floatMax(f32);
    var max_val: f32 = -std.math.floatMax(f32);
    var sum: f64 = 0;
    var count: usize = 0;
    for (member_ids) |sid| {
        const readings = try world.rangeByTime(.{
            .sensor_id = sid,
            .start_time = start_time,
            .end_time = end_time,
        });
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;
            if (r.value < min_val) min_val = r.value;
            if (r.value > max_val) max_val = r.value;
            sum += @as(f64, r.value);
            count += 1;
        }
    }

    if (count == 0) return .{ .min = 0.0, .max = 0.0, .avg = 0.0 };
    return .{
        .min = min_val,
        .max = max_val,
        .avg = @as(f32, @floatCast(sum / @as(f64, @floatFromInt(count)))),
    };
}

// ---------------------------------------------------------------------------
// Historical query family (Q7–Q8)
//
// These rollup queries dominate cost because they scan large time ranges and
// aggregate per-bucket statistics. They are pure functions over the World
// interface — the cost is attributed to the storage layout, not the query.
//
// RingBuffer does not support these queries (historical data is evicted).
// The runner and golden tests exclude RingBuffer for Q7/Q8.
// ---------------------------------------------------------------------------

/// Per-bucket accumulator used internally by rollup queries.
const BucketAcc = struct {
    sum: f64,
    min: f32,
    max: f32,
    count: u32,
};

/// Q7: Hourly rollup for a specific sensor over the trailing `days` days
/// ending at the most recent reading's timestamp for that sensor.
///
/// Each reading is assigned to an hour bucket via floor(timestamp / ms_per_hour).
/// Returns one HourlyAggregate per non-empty hour bucket, sorted by hour_bucket
/// ascending. Caller owns the returned slice (free with world.allocator).
///
/// Returns an empty slice when the sensor has no readings.
///
/// Pure: calls only world.getLatestBySensor and world.rangeByTime — no
/// backend-specific code, no branching on backend type.
pub fn query_hourly_rollup(world: anytype, sensor_id: u32, days: u32) ![]HourlyAggregate {
    const ms_per_hour: i64 = 60 * 60 * 1000;
    const ms_per_day: i64 = 24 * ms_per_hour;

    var result: std.ArrayList(HourlyAggregate) = .empty;
    defer result.deinit(world.allocator);

    const latest = world.getLatestBySensor(sensor_id) orelse
        return try result.toOwnedSlice(world.allocator);

    const window_ms: i64 = @as(i64, days) * ms_per_day;
    const start_time: i64 = latest.timestamp - window_ms;

    const readings = try world.rangeByTime(.{
        .sensor_id = sensor_id,
        .start_time = start_time,
        .end_time = latest.timestamp,
    });
    defer world.allocator.free(readings);

    if (readings.len == 0) return try result.toOwnedSlice(world.allocator);

    var buckets = std.AutoHashMap(i64, BucketAcc).init(world.allocator);
    defer buckets.deinit();

    for (readings) |r| {
        const bucket = @divFloor(r.timestamp, ms_per_hour) * ms_per_hour;
        const gop = try buckets.getOrPut(bucket);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .sum = @as(f64, r.value),
                .min = r.value,
                .max = r.value,
                .count = 1,
            };
        } else {
            gop.value_ptr.sum += @as(f64, r.value);
            if (r.value < gop.value_ptr.min) gop.value_ptr.min = r.value;
            if (r.value > gop.value_ptr.max) gop.value_ptr.max = r.value;
            gop.value_ptr.count += 1;
        }
    }

    var it = buckets.iterator();
    while (it.next()) |entry| {
        try result.append(world.allocator, .{
            .hour_bucket = entry.key_ptr.*,
            .avg = @as(f32, @floatCast(entry.value_ptr.sum / @as(f64, @floatFromInt(entry.value_ptr.count)))),
            .min = entry.value_ptr.min,
            .max = entry.value_ptr.max,
            .count = entry.value_ptr.count,
        });
    }

    std.mem.sort(HourlyAggregate, result.items, {}, struct {
        fn lt(_: void, lhs: HourlyAggregate, rhs: HourlyAggregate) bool {
            return lhs.hour_bucket < rhs.hour_bucket;
        }
    }.lt);

    return try result.toOwnedSlice(world.allocator);
}

/// Q8: Daily rollup for all sensors of a given `sensor_type` in a `zone_id`
/// over the trailing 1 year (365 days) ending at the most recent reading's
/// timestamp among those matching sensors.
///
/// Each reading is assigned to a day bucket via floor(timestamp / ms_per_day).
/// Returns one DailyAggregate per non-empty day bucket, sorted by day_bucket
/// ascending. Caller owns the returned slice (free with world.allocator).
///
/// Returns an empty slice when no matching readings exist.
///
/// Fetched PER ZONE MEMBER (rangeByTime with a sensor filter), like
/// query_avg_zone_type/query_floor_stats — deliberately NOT one unfiltered
/// window fetch. This query is zone-scoped: a zone holds ~10-15 sensors out
/// of the whole building, so the realistic engine plan is per-series index
/// probes for exactly those members, the same way a real TSDB executes
/// `WHERE zone_id = X AND type = Y` via its series index. A one-shot
/// unfiltered fetch was tried (2026-07-04) and measured WORSE at scale on
/// every backend: it materialized the entire building's 365-day window
/// (~57M readings, ~1.3GB, plus a full sort inside rangeByTime) to keep one
/// zone's ~1% of it — 13.5-16.4s/call at hospital-scale month 6 vs ~1.8s
/// for the per-member form, and it spiked peak memory. The one-fetch form
/// is right for FLEET-WIDE queries (see query_anomalies — type-scoped,
/// ~200 sensors, most of the data volume); sensor scope, not time-window
/// width, is what determines the realistic execution shape.
///
/// Pure: calls only world.sensorIdsByZone/getLatestBySensor/rangeByTime —
/// no backend-specific code, no branching on backend type.
pub fn query_daily_zone_rollup(world: anytype, zone_id: u32, sensor_type: sb.SensorType) ![]DailyAggregate {
    const ms_per_hour: i64 = 60 * 60 * 1000;
    const ms_per_day: i64 = 24 * ms_per_hour;
    const year_days: i64 = 365;

    var result: std.ArrayList(DailyAggregate) = .empty;
    defer result.deinit(world.allocator);

    const member_ids = try world.sensorIdsByZone(zone_id);
    defer world.allocator.free(member_ids);

    // Find the latest timestamp among matching sensors via getLatestBySensor.
    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        if (world.getLatestBySensor(sid)) |r| {
            if (r.sensor_type != sensor_type) continue;
            if (latest_ts == null or r.timestamp > latest_ts.?) {
                latest_ts = r.timestamp;
            }
        }
    }

    if (latest_ts == null) return try result.toOwnedSlice(world.allocator);

    const end_time = latest_ts.?;
    const start_time: i64 = end_time - year_days * ms_per_day;

    var buckets = std.AutoHashMap(i64, BucketAcc).init(world.allocator);
    defer buckets.deinit();

    for (member_ids) |sid| {
        const readings = try world.rangeByTime(.{
            .sensor_id = sid,
            .start_time = start_time,
            .end_time = end_time,
        });
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;

            const bucket = @divFloor(r.timestamp, ms_per_day) * ms_per_day;
            const gop = try buckets.getOrPut(bucket);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .sum = @as(f64, r.value),
                    .min = r.value,
                    .max = r.value,
                    .count = 1,
                };
            } else {
                gop.value_ptr.sum += @as(f64, r.value);
                if (r.value < gop.value_ptr.min) gop.value_ptr.min = r.value;
                if (r.value > gop.value_ptr.max) gop.value_ptr.max = r.value;
                gop.value_ptr.count += 1;
            }
        }
    }

    var it = buckets.iterator();
    while (it.next()) |entry| {
        try result.append(world.allocator, .{
            .day_bucket = entry.key_ptr.*,
            .avg = @as(f32, @floatCast(entry.value_ptr.sum / @as(f64, @floatFromInt(entry.value_ptr.count)))),
            .min = entry.value_ptr.min,
            .max = entry.value_ptr.max,
            .count = entry.value_ptr.count,
        });
    }

    std.mem.sort(DailyAggregate, result.items, {}, struct {
        fn lt(_: void, lhs: DailyAggregate, rhs: DailyAggregate) bool {
            return lhs.day_bucket < rhs.day_bucket;
        }
    }.lt);

    return try result.toOwnedSlice(world.allocator);
}

// ---------------------------------------------------------------------------
// Spatial query family (Q9–Q10)
//
// Both queries read real registered topology, never sensor_id arithmetic:
//
//   positions (Q9): World.registerPosition — real parsed placement
//     (ZoneLocation.position from the IFC) on the live path, or the
//     fixture's own synthetic convention (dataset.zig) on the regression
//     path. World-level, not a StorageBackend method, because no backend
//     models a spatial index (see world.zig's `positions` field comment).
//
//   zone hierarchy (Q10): real registered topology, not arithmetic —
//     depth 0  = sensor leaf   (sensors registered to exactly zone_id)
//     depth 1  = floor         (every zone sharing zone_id's registered floor)
//     depth 2+ = building root (all sensors)
//
// No backend-specific code; Q9 calls only world.allSensorIds(), Q10 calls
// world.sensorIdsByZone/sensorIdsByFloor/floorOfZone. HierarchicalStorage
// wins Q10 because its tree index lets it collect subtree leaves without
// scanning the full dataset.
// ---------------------------------------------------------------------------

fn vec3DistSq(a: Vec3, b: Vec3) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz;
}

/// Q9: Return all unique sensor IDs whose registered position
/// (World.registerPosition, sourced from real placement data —
/// ZoneLocation.position — or a fixture's synthetic convention) falls
/// within `radius_m` of `center`. Sensors with no registered position
/// can't match, same as a real asset registry missing an entry.
///
/// Only sensors that have at least one reading in the world are considered.
/// Results are sorted by sensor_id ascending.
/// Caller owns the returned slice (free with world.allocator).
///
/// Pure: calls only world.allSensorIds()/positionOf() — no
/// backend-specific code, no sensor_id arithmetic.
pub fn query_spatial_radius(world: anytype, center: Vec3, radius_m: f32) ![]EntityId {
    // world.allSensorIds() delegates to the backend's topology index —
    // owned, caller frees. Position is per-sensor, not per-reading.
    const sensor_ids = try world.allSensorIds();
    defer world.allocator.free(sensor_ids);

    const radius_sq = radius_m * radius_m;

    var result: std.ArrayList(EntityId) = .empty;
    defer result.deinit(world.allocator);

    for (sensor_ids) |sid| {
        const p = world.positionOf(sid) orelse continue;
        const pos = Vec3{ .x = p.x, .y = p.y, .z = p.z };
        if (vec3DistSq(pos, center) <= radius_sq) {
            try result.append(world.allocator, sid);
        }
    }

    return try result.toOwnedSlice(world.allocator);
}

/// Q10: Return all unique sensor IDs reachable from `zone_id` within `depth`
/// levels of the zone hierarchy — real registered topology
/// (World.registerZone/registerFloor), not sensor_id arithmetic.
///
/// Hierarchy levels:
///   depth 0  — sensors registered to exactly zone_id
///   depth 1  — sensors on the same floor as zone_id (every zone that
///              shares zone_id's registered floor)
///   depth >= 2 — all sensors in the building
///
/// Only sensors that have at least one reading are returned.
/// Results are sorted by sensor_id ascending.
/// Caller owns the returned slice (free with world.allocator).
///
/// depth 0/1 call world.sensorIdsByZone/sensorIdsByFloor — a backend that
/// organises data by this exact grouping (e.g. a Floor/Zone tree) can
/// answer by walking straight to the matching subtree instead of scanning
/// every reading. depth 1 needs the floor zone_id itself belongs to
/// (world.floorOfZone) — if zone_id was never registered to a floor, there
/// is nothing to walk and this returns empty, not an error. depth >= 2
/// ("all sensors") still calls iterateAll(): touching the entire dataset
/// is inherent to that request, not something a subtree walk can shortcut.
pub fn query_zone_hierarchy(world: anytype, zone_id: u32, depth: u32) ![]EntityId {
    switch (depth) {
        0 => return world.sensorIdsByZone(zone_id),
        1 => {
            const floor_id = world.floorOfZone(zone_id) orelse return &.{};
            return world.sensorIdsByFloor(floor_id);
        },
        else => {
            // world.allSensorIds() is owned (caller frees) — dupe into a
            // new slice since this function's contract is that the caller
            // frees the result unconditionally regardless of depth.
            const sensor_ids = try world.allSensorIds();
            defer world.allocator.free(sensor_ids);
            return try world.allocator.dupe(EntityId, sensor_ids);
        },
    }
}

// ---------------------------------------------------------------------------
// Anomaly query family (Q11–Q12)
//
// Both queries scan for statistical/threshold outliers using only the
// native per-backend primitives (allSensorIds/getLatestBySensor/
// rangeByTime) — backend-agnostic, deterministic given the same data.
// Tie-breaking and ordering rules are documented per-query so all backends
// produce byte-identical output for the golden equivalence tests.
// ---------------------------------------------------------------------------

/// Default trailing baseline window for query_anomalies — 7 days. Long
/// enough to give every sensor type a real sample (even vibration's
/// hourly cadence yields ~168 points) without reaching back through a
/// type's entire multi-year retention. One named constant so
/// runner.zig/simulation.zig don't each hardcode their own copy.
pub const ANOMALY_WINDOW_HOURS: u32 = 24 * 7;

/// Default z-score threshold for query_anomalies's benchmark callers.
/// 1.0 sigma (the old value, from before per-hour-of-day baselining
/// existed) flags ~32% of pure Gaussian noise by construction — even with
/// the diurnal cycle correctly factored out via hourOfDay bucketing, a
/// flat 1.0 sigma cutoff still mostly returns ordinary noise, not outliers.
/// 2.5 sigma is the conventional statistical-outlier cutoff (~1% of a
/// normal distribution) — see the research cited in this query's redesign:
/// real anomaly/fault detection uses a threshold selective enough that
/// what it flags is actually worth a human's attention.
pub const ANOMALY_STD_DEV_THRESHOLD: f32 = 2.5;

const HOURS_PER_DAY: usize = 24;

/// Hour-of-day (0-23) a timestamp falls in, ignoring which day — the
/// bucket key query_anomalies baselines against. Pure epoch-ms arithmetic
/// (no timezone/OS calendar API per CLAUDE.md's cross-platform rule); the
/// synthetic generator's diurnal cycle and SIM_START_MS are themselves
/// defined against raw epoch time, so this needs no calendar concept
/// beyond "which of the 24 hourly buckets this ms value lands in."
fn hourOfDay(timestamp_ms: i64) usize {
    const ms_per_hour: i64 = 60 * 60 * 1000;
    return @intCast(@mod(@divFloor(timestamp_ms, ms_per_hour), HOURS_PER_DAY));
}

/// Q11: Readings of `sensor_type`, across every sensor of that type, whose
/// value deviates by more than `std_dev_threshold` standard deviations from
/// THAT SENSOR'S OWN mean **for that same hour-of-day**, computed over the
/// shared trailing `window_hours` ending at the newest reading among sensors
/// of the type — one fleet-wide "last N hours" window, the way a real
/// anomaly dashboard scopes it, rather than a separate window per sensor.
///
/// Baselining per-sensor, not blended across every sensor of the type
/// building-wide, matches how real anomaly detection is actually scoped: a
/// boiler-room temperature sensor and a patient-room one don't share one
/// mean.
///
/// Baselining per-HOUR-OF-DAY, not one flat mean/std-dev over the whole
/// window, matters because most sensor types (temperature, co2, energy,
/// structural — see generator.zig's SensorProfile.daily_amplitude) have a
/// real, deliberate daily cycle: a temperature sensor's ordinary 3pm peak
/// sits ~3 units above its 24h mean, versus ~0.3 units of actual sensor
/// noise. A flat window mean/std-dev conflates that expected swing with
/// noise, so an ordinary daily peak reads as a spurious ~1.4 sigma "anomaly"
/// every single day. This is the standard naive-z-score-on-seasonal-data
/// failure (flagging "December" as an anomaly because sales are high, when
/// December is exactly when they're supposed to be) — the fix is the
/// standard one: baseline each reading against its own time-of-day cohort
/// (here, same hour across the trailing window) instead of a flat average.
/// Only vibration's bursty_impulsive shape (tiny daily_amplitude, real
/// anomalies are the injected burst spikes) would have been fine either
/// way; every diurnal_continuous/stepwise_discrete type needs this.
///
/// Mean and std-dev for an (sensor, hour-of-day) pair are computed over the
/// SAME per-hour-bucket sample that is then scanned for outliers.
///
/// A reading contributes no result when its hour-of-day bucket has fewer
/// than 2 samples in the window, or when every sample in that bucket is
/// identical (std_dev == 0 — no reading in that bucket is anomalous at any
/// threshold). Results are sorted by (sensor_id asc, timestamp asc). Caller
/// owns the slice (free with world.allocator).
///
/// Pure: calls only world.allSensorIds/getLatestBySensor/rangeByTime — the
/// same native, backend-agnostic primitives query_spatial_radius and
/// query_avg_window already use, plus pure in-memory grouping/bucketing
/// over the one window slice fetched. No backend branches anywhere: every
/// backend serves the identical one-window fetch through its own layout,
/// and layouts win or lose on their own merits.
pub fn query_anomalies(world: anytype, sensor_type: sb.SensorType, std_dev_threshold: f32, window_hours: u32) ![]AnomalyResult {
    const sensor_ids = try world.allSensorIds();
    defer world.allocator.free(sensor_ids);

    const window_ms: i64 = @as(i64, window_hours) * 60 * 60 * 1000;

    var result: std.ArrayList(AnomalyResult) = .empty;
    defer result.deinit(world.allocator);

    // Window end = the newest reading among sensors of this type — the
    // shared "now" a real anomaly dashboard queries against ("last 7 days",
    // one wall-clock window for the whole fleet), not one window per
    // sensor. getLatestBySensor is O(1) per sensor on every backend.
    var end_ts: ?i64 = null;
    for (sensor_ids) |sid| {
        if (world.getLatestBySensor(sid)) |r| {
            if (r.sensor_type != sensor_type) continue;
            if (end_ts == null or r.timestamp > end_ts.?) end_ts = r.timestamp;
        }
    }
    const end_time = end_ts orelse return try result.toOwnedSlice(world.allocator);

    // ONE fetch of the whole trailing window, then group rows by sensor in
    // this layer — how a real application issues a fleet-wide anomaly query
    // (one `WHERE type = X AND time > now()-7d` query, one pass over the
    // window, GROUP BY sensor), and how a real engine executes one. The
    // previous formulation called rangeByTime once per sensor of the type —
    // the classic N+1 query anti-pattern no real application would write,
    // and on time-partitioned backends each of those N calls re-scanned the
    // entire multi-sensor window to keep one sensor's rows (~200 full-window
    // scans ≈ 440M row visits ≈ 1.5-2.9s per call at hospital scale).
    const window = try world.rangeByTime(.{
        .sensor_id = null,
        .start_time = end_time - window_ms,
        .end_time = end_time,
    });
    defer world.allocator.free(window);

    // Group by sensor: indices into `window`, per sensor_id. rangeByTime
    // returns (timestamp asc, sensor_id asc), so each group's indices stay
    // in timestamp order — same per-sensor iteration order the per-sensor
    // fetches produced.
    var groups = std.AutoHashMap(u32, std.ArrayList(u32)).init(world.allocator);
    defer {
        var git = groups.valueIterator();
        while (git.next()) |list| list.deinit(world.allocator);
        groups.deinit();
    }
    for (window, 0..) |r, i| {
        if (r.sensor_type != sensor_type) continue;
        const gop = try groups.getOrPut(r.sensor_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(world.allocator, @intCast(i));
    }

    // Per sensor: identical per-hour-of-day baselining math as before, just
    // over the grouped rows instead of a per-sensor fetch.
    var it = groups.iterator();
    while (it.next()) |entry| {
        const indices = entry.value_ptr.items;
        if (indices.len < 2) continue;

        var sums: [HOURS_PER_DAY]f64 = @splat(0);
        var counts: [HOURS_PER_DAY]usize = @splat(0);
        for (indices) |i| {
            const r = window[i];
            const h = hourOfDay(r.timestamp);
            sums[h] += r.value;
            counts[h] += 1;
        }

        var means: [HOURS_PER_DAY]f64 = @splat(0);
        for (0..HOURS_PER_DAY) |h| {
            if (counts[h] > 0) means[h] = sums[h] / @as(f64, @floatFromInt(counts[h]));
        }

        var sum_sq_devs: [HOURS_PER_DAY]f64 = @splat(0);
        for (indices) |i| {
            const r = window[i];
            const h = hourOfDay(r.timestamp);
            const d = @as(f64, r.value) - means[h];
            sum_sq_devs[h] += d * d;
        }

        var std_devs: [HOURS_PER_DAY]f64 = @splat(0);
        for (0..HOURS_PER_DAY) |h| {
            if (counts[h] > 0) std_devs[h] = @sqrt(sum_sq_devs[h] / @as(f64, @floatFromInt(counts[h])));
        }

        for (indices) |i| {
            const r = window[i];
            const h = hourOfDay(r.timestamp);
            if (counts[h] < 2 or std_devs[h] == 0.0) continue;

            const z: f64 = (@as(f64, r.value) - means[h]) / std_devs[h];
            if (@abs(z) > @as(f64, std_dev_threshold)) {
                try result.append(world.allocator, .{
                    .reading = r,
                    .z_score = @as(f32, @floatCast(z)),
                });
            }
        }
    }

    std.mem.sort(AnomalyResult, result.items, {}, struct {
        fn lt(_: void, lhs: AnomalyResult, rhs: AnomalyResult) bool {
            if (lhs.reading.sensor_id != rhs.reading.sensor_id) {
                return lhs.reading.sensor_id < rhs.reading.sensor_id;
            }
            return lhs.reading.timestamp < rhs.reading.timestamp;
        }
    }.lt);

    return try result.toOwnedSlice(world.allocator);
}

/// Default lookback window for query_threshold_breach — 48 hours. This
/// query is declared `hot: true` in every profile that carries it
/// (generator.zig's per-type query mixes) — it models a live BMS fault
/// alert ("is there a sustained over-threshold run happening now/recently"),
/// not a lifetime audit. A sensor's entire multi-year retained history
/// would answer a different question ("has this sensor EVER breached"),
/// which nothing in the query mix actually asks for.
pub const THRESHOLD_BREACH_WINDOW_HOURS: u32 = 48;

/// Q12: First sustained run for `sensor_id`, within its trailing
/// `window_hours` (ending at its own latest reading — same idiom as
/// query_avg_window/query_anomalies), where every reading's value exceeds
/// `threshold` for at least `min_duration_ms` (end_ts - start_ts).
///
/// A "run" is a maximal sequence of timestamp-adjacent readings whose value
/// is above the threshold. The first run within the window that meets the
/// duration requirement is returned (earliest start_ts). Equal-timestamp
/// readings break by value.
///
/// Returns null when no qualifying run exists in the window. Pure: calls
/// only world.getLatestBySensor/rangeByTime, bounded to this one sensor's
/// own readings in the recent window — not the unbounded
/// world.rangeByTime(minInt, ...) this used to do, which made every
/// backend's binary search collapse to "the whole array" for this sensor
/// and grow without bound as that sensor's retained history grew.
pub fn query_threshold_breach(world: anytype, sensor_id: u32, threshold: f32, min_duration_ms: i64, window_hours: u32) !?BreachEvent {
    // Use getLatestBySensor to bound the time range, then rangeByTime which
    // returns sorted results via the backend's index — no manual sort needed.
    const latest = world.getLatestBySensor(sensor_id) orelse return null;

    const window_ms: i64 = @as(i64, window_hours) * 60 * 60 * 1000;
    const readings = try world.rangeByTime(.{
        .sensor_id = sensor_id,
        .start_time = latest.timestamp - window_ms,
        .end_time = latest.timestamp,
    });
    defer world.allocator.free(readings);

    if (readings.len == 0) return null;

    // rangeByTime returns results sorted by timestamp ascending, ties broken
    // by sensor_id ascending — no explicit sort needed.

    var run_start_ts: ?i64 = null;
    var run_end_ts: i64 = 0;
    var run_peak: f32 = 0;

    for (readings) |r| {
        if (r.value > threshold) {
            if (run_start_ts == null) {
                run_start_ts = r.timestamp;
                run_end_ts = r.timestamp;
                run_peak = r.value;
            } else {
                run_end_ts = r.timestamp;
                if (r.value > run_peak) run_peak = r.value;
            }
        } else if (run_start_ts) |start| {
            const duration = run_end_ts - start;
            if (duration >= min_duration_ms) {
                return .{
                    .sensor_id = sensor_id,
                    .start_ts = start,
                    .end_ts = run_end_ts,
                    .duration_ms = duration,
                    .peak_value = run_peak,
                };
            }
            run_start_ts = null;
        }
    }

    if (run_start_ts) |start| {
        const duration = run_end_ts - start;
        if (duration >= min_duration_ms) {
            return .{
                .sensor_id = sensor_id,
                .start_ts = start,
                .end_ts = run_end_ts,
                .duration_ms = duration,
                .peak_value = run_peak,
            };
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// Real-time query family (Q1–Q3)
// ---------------------------------------------------------------------------

/// Q1: Latest reading for a single sensor.
/// Returns null if the sensor has no readings.
/// Pure: delegates to world.getLatestBySensor — no backend-specific code.
pub fn query_latest_single(world: anytype, sensor_id: u32) !?sb.SensorReading {
    return world.getLatestBySensor(sensor_id);
}

/// Q2: Latest reading per sensor in a zone.
/// Zone membership comes from real registration (World.registerZone), not
/// sensor_id arithmetic. Returns one reading per sensor in the zone,
/// sorted by sensor_id ascending (sensorIdsByZone's own contract).
/// Caller owns the returned slice (free with world.allocator).
/// Pure: calls only world.sensorIdsByZone/getLatestBySensor — no
/// backend-specific code.
pub fn query_latest_zone(world: anytype, zone_id: u32) ![]const sb.SensorReading {
    const member_ids = try world.sensorIdsByZone(zone_id);
    defer world.allocator.free(member_ids);

    var result: std.ArrayList(sb.SensorReading) = .empty;
    defer result.deinit(world.allocator);

    for (member_ids) |sid| {
        if (world.getLatestBySensor(sid)) |latest| {
            try result.append(world.allocator, latest);
        }
    }

    return try result.toOwnedSlice(world.allocator);
}

/// Q3: Latest reading per sensor of a given type.
/// Returns one reading per sensor matching sensor_type, sorted by sensor_id
/// ascending. Caller owns the returned slice (free with world.allocator).
///
/// Pure: calls only world.allSensorIds/getLatestBySensor — the same native
/// primitives query_spatial_radius/query_anomalies use. "Latest per sensor
/// of a type" only ever needs ONE reading per sensor, so materializing
/// every retained reading of that type first (the old
/// world.readingsForType path) did (retained readings of that type) times
/// more work than the answer needed — a real-time-family query (Q3 is
/// tagged real_time, same as Q1/Q2) shouldn't cost more the longer a
/// type's retention window is.
pub fn query_latest_by_type(world: anytype, sensor_type: sb.SensorType) ![]const sb.SensorReading {
    const sensor_ids = try world.allSensorIds();
    defer world.allocator.free(sensor_ids);

    var result: std.ArrayList(sb.SensorReading) = .empty;
    defer result.deinit(world.allocator);

    // allSensorIds() is already sorted ascending (query_spatial_radius
    // relies on the same guarantee without re-sorting), so filtering
    // in-place preserves sensor_id-ascending order — no sort needed.
    for (sensor_ids) |sid| {
        const latest = world.getLatestBySensor(sid) orelse continue;
        if (latest.sensor_type != sensor_type) continue;
        try result.append(world.allocator, latest);
    }

    return try result.toOwnedSlice(world.allocator);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests
//
// CLAUDE.md §3.2: "All backends must produce identical query results for
// the same input." Until 2026-07-20 this was NOT actually checked anywhere
// in the codebase — this comment block previously described a template and
// claimed (both here and in runner.zig) that 8 of the 12 query patterns'
// equivalence was "proven once, in queries.zig." Neither was true: the only
// test that existed (query_spatial_radius below) exercises a single backend
// (AoS) for a boundary/edge-case property, not cross-backend agreement, and
// runner.zig's own claimed equivalence checks didn't exist either. Rechecked
// against the live tree, not assumed from the comment — same lesson this
// project has hit before with backend-audit.md's stale claims.
//
// `allQueriesEquivalent` below closes the actual gap: one dataset, inserted
// into all 7 backends (the 5 deployment candidates plus AoS/SoA, the
// worst-case reference baselines), all 12 query patterns run against each,
// compared field-by-field against AoS as the reference. Aggregation fields
// (avg/z_score) use a float tolerance (1e-4, generous for f32 summation of
// a few hundred values); everything else (counts, ids, timestamps, sorted
// order) must match exactly. The shared dataset.zig fixture (50
// readings/sensor) sits well under RingBuffer's 1000/sensor default
// capacity, so no eviction occurs and RingBuffer is expected to agree on
// every query, including the historical-rollup patterns it's excluded from
// in real deployment (that exclusion is about incomplete data after real
// eviction, not a difference in query logic).
// ---------------------------------------------------------------------------

const aos = @import("../ecs/storage/backends/aos_storage.zig");
const soa = @import("../ecs/storage/backends/soa_storage.zig");
const timeseries = @import("../ecs/storage/backends/timeseries_storage.zig");
const columnar = @import("../ecs/storage/backends/columnar_storage.zig");
const hierarchical = @import("../ecs/storage/backends/hierarchical_storage.zig");
const ringbuffer = @import("../ecs/storage/backends/ringbuffer_storage.zig");
const lake = @import("../ecs/storage/backends/lake_storage.zig");
const World = @import("../ecs/world.zig").World;

// Shared dataset fixtures + zone/floor topology — the single source of truth.
// The production zone/floor queries above use these same constants, so they
// must come from one place rather than being redefined per file.
const fixtures = @import("dataset.zig");
const generateDataset = fixtures.generateDataset;
const insertDataset = fixtures.insertDataset;
pub const sensorTypeFor = fixtures.sensorTypeFor;
const NUM_SENSORS = fixtures.NUM_SENSORS;
const READINGS_PER_SENSOR = fixtures.READINGS_PER_SENSOR;
const BASE_TIMESTAMP = fixtures.BASE_TIMESTAMP;
const MS_PER_HOUR = fixtures.MS_PER_HOUR;
const SENSORS_PER_ZONE = fixtures.SENSORS_PER_ZONE;
const ZONES_PER_FLOOR = fixtures.ZONES_PER_FLOOR;
const SENSORS_PER_FLOOR = fixtures.SENSORS_PER_FLOOR;

test "query_spatial_radius: registered positions decide membership — boundary inclusive, unregistered sensors never match" {
    const allocator = std.testing.allocator;
    var world = try World(aos).init(allocator);
    defer world.deinit();

    // Four sensors, one reading each (a sensor must exist in the world's
    // topology to be a candidate at all).
    for ([_]u32{ 1, 2, 3, 4 }) |sid| {
        try world.insert(.{ .sensor_id = sid, .timestamp = 1000, .value = 20.0, .sensor_type = .temperature });
        try world.registerZone(sid, 0);
    }
    try world.registerPosition(1, .{ .x = 0.0, .y = 0.0, .z = 0.0 }); // at center
    try world.registerPosition(2, .{ .x = 3.0, .y = 4.0, .z = 0.0 }); // dist exactly 5 — boundary
    try world.registerPosition(3, .{ .x = 10.0, .y = 0.0, .z = 0.0 }); // dist 10 — outside
    // Sensor 4: reading exists but NO registered position — a real asset
    // registry with a missing entry; must never match, not match at (0,0,0).

    const result = try query_spatial_radius(&world, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, 5.0);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(EntityId, &.{ 1, 2 }, result);
}

/// Every query pattern's result for one backend, bundled so
/// `allQueriesEquivalent` can generate+insert the dataset once per backend,
/// run all 12 patterns in a single pass, and compare the whole bundle
/// against a reference. Slice fields are owned; free with `deinit`.
const AllQueryResults = struct {
    latest_single: ?sb.SensorReading,
    latest_zone: []const sb.SensorReading,
    latest_by_type: []const sb.SensorReading,
    avg_window: f32,
    avg_zone_type: f32,
    floor_stats: Stats,
    hourly_rollup: []HourlyAggregate,
    daily_zone_rollup: []DailyAggregate,
    spatial_radius: []EntityId,
    zone_hierarchy: []EntityId,
    anomalies: []AnomalyResult,
    threshold_breach: ?BreachEvent,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.latest_zone);
        allocator.free(self.latest_by_type);
        allocator.free(self.hourly_rollup);
        allocator.free(self.daily_zone_rollup);
        allocator.free(self.spatial_radius);
        allocator.free(self.zone_hierarchy);
        allocator.free(self.anomalies);
    }
};

/// Runs all 12 query patterns against a fresh World(B) seeded with the
/// shared dataset.zig fixture. Fixture args (sensor 0 / zone 0 / floor 0 /
/// origin) are valid for every backend because insertDataset's topology
/// convention places sensor 0 there regardless of backend type.
fn runAllQueries(comptime B: type, allocator: std.mem.Allocator, readings: []const sb.SensorReading) !AllQueryResults {
    var world = try World(B).init(allocator);
    defer world.deinit();
    try insertDataset(&world, readings);

    const sensor_id: u32 = 0;
    const zone_id: u32 = 0;
    const floor_id: u32 = 0;
    const sensor_type: sb.SensorType = .temperature;
    const position = Vec3{ .x = 0, .y = 0, .z = 0 };
    const one_hour_ms: i64 = 60 * 60 * 1000;

    return .{
        .latest_single = try query_latest_single(&world, sensor_id),
        .latest_zone = try query_latest_zone(&world, zone_id),
        .latest_by_type = try query_latest_by_type(&world, sensor_type),
        .avg_window = try query_avg_window(&world, sensor_id, 24),
        .avg_zone_type = try query_avg_zone_type(&world, zone_id, sensor_type, 24),
        .floor_stats = try query_floor_stats(&world, floor_id, sensor_type, 24),
        .hourly_rollup = try query_hourly_rollup(&world, sensor_id, 2),
        .daily_zone_rollup = try query_daily_zone_rollup(&world, zone_id, sensor_type),
        .spatial_radius = try query_spatial_radius(&world, position, 50.0),
        .zone_hierarchy = try query_zone_hierarchy(&world, zone_id, 2),
        .anomalies = try query_anomalies(&world, sensor_type, 2.5, 24),
        .threshold_breach = try query_threshold_breach(&world, sensor_id, 15.0, one_hour_ms, 24),
    };
}

const EQUIV_TOLERANCE: f32 = 1e-4;

fn expectStatsEqual(expected: Stats, got: Stats) !void {
    try std.testing.expectApproxEqAbs(expected.min, got.min, EQUIV_TOLERANCE);
    try std.testing.expectApproxEqAbs(expected.max, got.max, EQUIV_TOLERANCE);
    try std.testing.expectApproxEqAbs(expected.avg, got.avg, EQUIV_TOLERANCE);
}

fn expectReadingEqual(expected: sb.SensorReading, got: sb.SensorReading) !void {
    try std.testing.expectEqual(expected.sensor_id, got.sensor_id);
    try std.testing.expectEqual(expected.timestamp, got.timestamp);
    try std.testing.expectEqual(expected.sensor_type, got.sensor_type);
    try std.testing.expectApproxEqAbs(expected.value, got.value, EQUIV_TOLERANCE);
}

fn expectReadingSlicesEqual(expected: []const sb.SensorReading, got: []const sb.SensorReading) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try expectReadingEqual(e, g);
}

/// Compares every field of two AllQueryResults bundles for one backend
/// against the AoS reference. Any divergence here means that backend's
/// query logic (or the generic World(T) layer it routes through) disagrees
/// with the reference on real data — exactly the class of bug CLAUDE.md
/// §3.2 requires this suite to catch.
fn expectAllQueriesEqual(backend_name: []const u8, expected: AllQueryResults, got: AllQueryResults) !void {
    errdefer std.debug.print("query equivalence mismatch: backend={s}\n", .{backend_name});

    if (expected.latest_single) |e| {
        try expectReadingEqual(e, got.latest_single.?);
    } else {
        try std.testing.expect(got.latest_single == null);
    }
    try expectReadingSlicesEqual(expected.latest_zone, got.latest_zone);
    try expectReadingSlicesEqual(expected.latest_by_type, got.latest_by_type);
    try std.testing.expectApproxEqAbs(expected.avg_window, got.avg_window, EQUIV_TOLERANCE);
    try std.testing.expectApproxEqAbs(expected.avg_zone_type, got.avg_zone_type, EQUIV_TOLERANCE);
    try expectStatsEqual(expected.floor_stats, got.floor_stats);

    try std.testing.expectEqual(expected.hourly_rollup.len, got.hourly_rollup.len);
    for (expected.hourly_rollup, got.hourly_rollup) |e, g| {
        try std.testing.expectEqual(e.hour_bucket, g.hour_bucket);
        try std.testing.expectEqual(e.count, g.count);
        try std.testing.expectApproxEqAbs(e.avg, g.avg, EQUIV_TOLERANCE);
        try std.testing.expectApproxEqAbs(e.min, g.min, EQUIV_TOLERANCE);
        try std.testing.expectApproxEqAbs(e.max, g.max, EQUIV_TOLERANCE);
    }

    try std.testing.expectEqual(expected.daily_zone_rollup.len, got.daily_zone_rollup.len);
    for (expected.daily_zone_rollup, got.daily_zone_rollup) |e, g| {
        try std.testing.expectEqual(e.day_bucket, g.day_bucket);
        try std.testing.expectEqual(e.count, g.count);
        try std.testing.expectApproxEqAbs(e.avg, g.avg, EQUIV_TOLERANCE);
        try std.testing.expectApproxEqAbs(e.min, g.min, EQUIV_TOLERANCE);
        try std.testing.expectApproxEqAbs(e.max, g.max, EQUIV_TOLERANCE);
    }

    try std.testing.expectEqualSlices(EntityId, expected.spatial_radius, got.spatial_radius);
    try std.testing.expectEqualSlices(EntityId, expected.zone_hierarchy, got.zone_hierarchy);

    try std.testing.expectEqual(expected.anomalies.len, got.anomalies.len);
    for (expected.anomalies, got.anomalies) |e, g| {
        try expectReadingEqual(e.reading, g.reading);
        try std.testing.expectApproxEqAbs(e.z_score, g.z_score, EQUIV_TOLERANCE);
    }

    if (expected.threshold_breach) |e| {
        const g = got.threshold_breach.?;
        try std.testing.expectEqual(e.sensor_id, g.sensor_id);
        try std.testing.expectEqual(e.start_ts, g.start_ts);
        try std.testing.expectEqual(e.end_ts, g.end_ts);
        try std.testing.expectEqual(e.duration_ms, g.duration_ms);
        try std.testing.expectApproxEqAbs(e.peak_value, g.peak_value, EQUIV_TOLERANCE);
    } else {
        try std.testing.expect(got.threshold_breach == null);
    }
}

test "all 12 query patterns: every backend (AoS, SoA, TimeSeries, Columnar, Hierarchical, RingBuffer, Lake) agrees with the AoS reference on the same seeded dataset" {
    const allocator = std.testing.allocator;
    const readings = try generateDataset(allocator);
    defer allocator.free(readings);

    const expected = try runAllQueries(aos, allocator, readings);
    defer expected.deinit(allocator);

    const Candidate = struct { name: []const u8, T: type };
    const candidates = [_]Candidate{
        .{ .name = "SoA", .T = soa },
        .{ .name = "TimeSeries", .T = timeseries },
        .{ .name = "Columnar", .T = columnar },
        .{ .name = "Hierarchical", .T = hierarchical },
        .{ .name = "RingBuffer", .T = ringbuffer },
        .{ .name = "Lake", .T = lake },
    };

    inline for (candidates) |c| {
        const got = try runAllQueries(c.T, allocator, readings);
        defer got.deinit(allocator);
        try expectAllQueriesEqual(c.name, expected, got);
    }
}

