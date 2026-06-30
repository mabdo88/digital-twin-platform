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
    .{ .name = "query_spatial_radius", .family = .spatial, .description = "Sensor IDs whose derived position falls within radius_m of center" },
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
// own readings directly via world.readingsForSensor — an index lookup, not
// a scan of every reading in the world checking membership one by one.
// ---------------------------------------------------------------------------

/// Q5: Average value for all sensors of a given `sensor_type` in a `zone_id`
/// over the trailing `hours` window ending at the most recent reading's
/// timestamp among those matching sensors.
///
/// Zone membership comes from real registration (World.registerZone), not
/// sensor_id arithmetic — see zoneMembership's doc comment.
/// Returns 0.0 when no matching readings exist.
///
/// Pure: calls only world.iterateAll/sensorIdsByZone — no backend-specific
/// code, no branching on backend type.
pub fn query_avg_zone_type(world: anytype, zone_id: u32, sensor_type: sb.SensorType, hours: u32) !f32 {
    const member_ids = try world.sensorIdsByZone(zone_id);
    defer world.allocator.free(member_ids);

    // Fetch each member's own readings once (world.readingsForSensor — an
    // index lookup, not a full-dataset scan) and collect the type-matching
    // ones while tracking the latest timestamp among them.
    var matching: std.ArrayList(sb.SensorReading) = .empty;
    defer matching.deinit(world.allocator);

    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        const readings = try world.readingsForSensor(sid);
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;
            try matching.append(world.allocator, r);
            if (latest_ts == null or r.timestamp > latest_ts.?) {
                latest_ts = r.timestamp;
            }
        }
    }

    const end_time = latest_ts orelse return 0.0;

    const ms_per_hour: i64 = 60 * 60 * 1000;
    const window_ms: i64 = @as(i64, hours) * ms_per_hour;
    const start_time: i64 = end_time - window_ms;

    var sum: f64 = 0;
    var count: usize = 0;
    for (matching.items) |r| {
        if (r.timestamp < start_time or r.timestamp > end_time) continue;
        sum += @as(f64, r.value);
        count += 1;
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
/// Pure: calls only world.iterateAll/sensorIdsByFloor — no backend-specific
/// code, no branching on backend type.
pub fn query_floor_stats(world: anytype, floor_id: u32, sensor_type: sb.SensorType, hours: u32) !Stats {
    const member_ids = try world.sensorIdsByFloor(floor_id);
    defer world.allocator.free(member_ids);

    // Fetch each member's own readings once (world.readingsForSensor — an
    // index lookup, not a full-dataset scan) and collect the type-matching
    // ones while tracking the latest timestamp among them.
    var matching: std.ArrayList(sb.SensorReading) = .empty;
    defer matching.deinit(world.allocator);

    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        const readings = try world.readingsForSensor(sid);
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;
            try matching.append(world.allocator, r);
            if (latest_ts == null or r.timestamp > latest_ts.?) {
                latest_ts = r.timestamp;
            }
        }
    }

    const end_time = latest_ts orelse return .{ .min = 0.0, .max = 0.0, .avg = 0.0 };

    const ms_per_hour: i64 = 60 * 60 * 1000;
    const window_ms: i64 = @as(i64, hours) * ms_per_hour;
    const start_time: i64 = end_time - window_ms;

    var min_val: f32 = std.math.floatMax(f32);
    var max_val: f32 = -std.math.floatMax(f32);
    var sum: f64 = 0;
    var count: usize = 0;
    for (matching.items) |r| {
        if (r.timestamp < start_time or r.timestamp > end_time) continue;
        if (r.value < min_val) min_val = r.value;
        if (r.value > max_val) max_val = r.value;
        sum += @as(f64, r.value);
        count += 1;
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
/// Pure: calls only world.iterateAll — no backend-specific code, no branching
/// on backend type.
pub fn query_daily_zone_rollup(world: anytype, zone_id: u32, sensor_type: sb.SensorType) ![]DailyAggregate {
    const ms_per_hour: i64 = 60 * 60 * 1000;
    const ms_per_day: i64 = 24 * ms_per_hour;
    const year_days: i64 = 365;

    var result: std.ArrayList(DailyAggregate) = .empty;
    defer result.deinit(world.allocator);

    const member_ids = try world.sensorIdsByZone(zone_id);
    defer world.allocator.free(member_ids);

    // Fetch each member's own readings once (world.readingsForSensor — an
    // index lookup, not a full-dataset scan) and collect the type-matching
    // ones while tracking the latest timestamp among them.
    var matching: std.ArrayList(sb.SensorReading) = .empty;
    defer matching.deinit(world.allocator);

    var latest_ts: ?i64 = null;
    for (member_ids) |sid| {
        const readings = try world.readingsForSensor(sid);
        defer world.allocator.free(readings);
        for (readings) |r| {
            if (r.sensor_type != sensor_type) continue;
            try matching.append(world.allocator, r);
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

    for (matching.items) |r| {
        if (r.timestamp < start_time or r.timestamp > end_time) continue;

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
// Both queries derive spatial metadata entirely from component data already
// present in SensorReading:
//
//   position(sensor_id):
//     x = @as(f32, sensor_id % 10) * 5.0          -- 0..45 m along X axis
//     y = @as(f32, sensor_id / 10) * 3.0          -- floor height (3 m/floor)
//     z = 0.0                                      -- single corridor
//     (Q9 only — still a synthetic placeholder derived from sensor_id, not
//     real placement position. Unlike zone/floor, this hasn't been wired
//     to ZoneLocation.position yet; a real building's spatial queries
//     would need that the same way Q10's zone/floor queries now need
//     real registerZone/registerFloor data instead of arithmetic.)
//
//   zone hierarchy (Q10): real registered topology, not arithmetic —
//     depth 0  = sensor leaf   (sensors registered to exactly zone_id)
//     depth 1  = floor         (every zone sharing zone_id's registered floor)
//     depth 2+ = building root (all sensors)
//
// No backend-specific code; Q9 calls only world.iterateAll(), Q10 calls
// world.sensorIdsByZone/sensorIdsByFloor/floorOfZone. HierarchicalStorage
// wins Q10 because its tree index lets it collect subtree leaves without
// scanning the full dataset.
// ---------------------------------------------------------------------------

/// Derive a deterministic 3-D position from a sensor_id.
/// Pure function — same output for the same sensor_id on every backend.
///
///   x = (sensor_id % 10) * 5.0 m   (position along a corridor)
///   y = (sensor_id / 10) * 3.0 m   (floor height, 3 m per floor)
///   z = 0.0 m                       (single corridor depth)
pub fn sensorPosition(sensor_id: u32) Vec3 {
    return .{
        .x = @as(f32, @floatFromInt(sensor_id % 10)) * 5.0,
        .y = @as(f32, @floatFromInt(sensor_id / 10)) * 3.0,
        .z = 0.0,
    };
}

fn vec3DistSq(a: Vec3, b: Vec3) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz;
}

/// Q9: Return all unique sensor IDs whose derived position (ZoneLocation.position
/// encoded as sensorPosition(sensor_id)) falls within `radius_m` of `center`.
///
/// Only sensors that have at least one reading in the world are considered.
/// Results are sorted by sensor_id ascending.
/// Caller owns the returned slice (free with world.allocator).
///
/// Pure: calls only world.iterateAll() — no backend-specific code.
pub fn query_spatial_radius(world: anytype, center: Vec3, radius_m: f32) ![]EntityId {
    // world.iterateAll() is cached/borrowed at the World level — do not free.
    const all = try world.iterateAll();

    const radius_sq = radius_m * radius_m;

    var seen = std.AutoHashMap(EntityId, void).init(world.allocator);
    defer seen.deinit();

    for (all) |r| {
        if (seen.contains(r.sensor_id)) continue;
        const pos = sensorPosition(r.sensor_id);
        if (vec3DistSq(pos, center) <= radius_sq) {
            try seen.put(r.sensor_id, {});
        }
    }

    var result: std.ArrayList(EntityId) = .empty;
    defer result.deinit(world.allocator);

    var it = seen.keyIterator();
    while (it.next()) |k| {
        try result.append(world.allocator, k.*);
    }

    std.mem.sort(EntityId, result.items, {}, struct {
        fn lt(_: void, lhs: EntityId, rhs: EntityId) bool {
            return lhs < rhs;
        }
    }.lt);

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
            // world.iterateAll() is cached/borrowed at the World level — do not free.
            const all = try world.iterateAll();

            var seen = std.AutoHashMap(EntityId, void).init(world.allocator);
            defer seen.deinit();
            for (all) |r| try seen.put(r.sensor_id, {});

            var result: std.ArrayList(EntityId) = .empty;
            defer result.deinit(world.allocator);
            var it = seen.keyIterator();
            while (it.next()) |k| try result.append(world.allocator, k.*);

            std.mem.sort(EntityId, result.items, {}, struct {
                fn lt(_: void, lhs: EntityId, rhs: EntityId) bool {
                    return lhs < rhs;
                }
            }.lt);
            return try result.toOwnedSlice(world.allocator);
        },
    }
}

// ---------------------------------------------------------------------------
// Anomaly query family (Q11–Q12)
//
// Both queries scan the world for statistical outliers. Pure functions over
// world.iterateAll() — backend-agnostic, deterministic given the same data.
// Tie-breaking and ordering rules are documented per-query so all backends
// produce byte-identical output for the golden equivalence tests.
// ---------------------------------------------------------------------------

/// Q11: All readings of `sensor_type` whose value deviates from that type's
/// mean by more than `std_dev_threshold` standard deviations (z-score).
///
/// Mean and std-dev are computed over the SAME pass — every reading of the
/// requested type contributes, then a second pass selects outliers. Welford
/// would be lower-allocation but a two-pass mean/variance is fine at scale
/// here and easier to reason about.
///
/// Returns an empty slice when fewer than 2 matching readings exist (variance
/// is undefined for n<2). Results are sorted by (sensor_id asc, timestamp asc).
/// Caller owns the slice (free with world.allocator).
///
/// Pure: calls only world.statsForType/readingsForType — no backend-specific code.
pub fn query_anomalies(world: anytype, sensor_type: sb.SensorType, std_dev_threshold: f32) ![]AnomalyResult {
    // Mean/std-dev are cached at the World level (world.statsForType) — the
    // data doesn't change within a benchmark run, so computing them is
    // genuinely redundant work past the first call.
    const stats = try world.statsForType(sensor_type);
    if (stats.count < 2) return &.{};

    // Only this type's own readings (world.readingsForType — an index
    // lookup, not a scan of the whole dataset checking sensor_type per
    // row). The selection pass below is NOT cached and still runs in full
    // on every call — see statsForType's and readingsForType's doc
    // comments for why that distinction matters.
    const type_readings = try world.readingsForType(sensor_type);
    defer world.allocator.free(type_readings);

    var result: std.ArrayList(AnomalyResult) = .empty;
    defer result.deinit(world.allocator);

    if (stats.std_dev == 0.0) {
        // All values identical — no reading is anomalous at any threshold.
        return try result.toOwnedSlice(world.allocator);
    }

    for (type_readings) |r| {
        const z: f64 = (@as(f64, r.value) - stats.mean) / stats.std_dev;
        if (@abs(z) > @as(f64, std_dev_threshold)) {
            try result.append(world.allocator, .{
                .reading = r,
                .z_score = @as(f32, @floatCast(z)),
            });
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

/// Q12: First sustained run for `sensor_id` where every reading's value
/// exceeds `threshold` for at least `min_duration_ms` (end_ts - start_ts).
///
/// A "run" is a maximal sequence of timestamp-adjacent readings whose value
/// is above the threshold. The first run that meets the duration requirement
/// is returned (earliest start_ts). Equal-timestamp readings break by value.
///
/// Returns null when no qualifying run exists. Pure: calls only
/// world.readingsForSensor — an index lookup bounded by this one sensor's
/// own reading count, not world.rangeByTime(minInt, maxInt), which used to
/// degrade to a full-dataset scan (the (minInt, maxInt) bounds don't narrow
/// anything, so every backend's binary search collapsed to "the whole
/// array" and the sensor_id filter ran against every reading in the world).
pub fn query_threshold_breach(world: anytype, sensor_id: u32, threshold: f32, min_duration_ms: i64) !?BreachEvent {
    const readings = try world.readingsForSensor(sensor_id);
    defer world.allocator.free(readings);

    if (readings.len == 0) return null;

    // readingsForSensor (unlike rangeByTime) makes no ordering guarantee —
    // sort explicitly. Cheap: bounded by this sensor's own reading count,
    // not the dataset.
    const sorted: []sb.SensorReading = @constCast(readings);
    std.mem.sort(sb.SensorReading, sorted, {}, struct {
        fn lt(_: void, a: sb.SensorReading, b: sb.SensorReading) bool {
            return a.timestamp < b.timestamp;
        }
    }.lt);

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
/// Pure: calls only world.iterateAll — no backend-specific code.
pub fn query_latest_by_type(world: anytype, sensor_type: sb.SensorType) ![]const sb.SensorReading {
    // world.iterateAll() is cached/borrowed at the World level — do not free.
    const all = try world.iterateAll();

    var result: std.ArrayList(sb.SensorReading) = .empty;
    defer result.deinit(world.allocator);

    for (all) |r| {
        if (r.sensor_type != sensor_type) continue;

        var found = false;
        for (result.items) |*existing| {
            if (existing.sensor_id == r.sensor_id) {
                if (r.timestamp > existing.timestamp) {
                    existing.* = r;
                }
                found = true;
                break;
            }
        }
        if (!found) {
            try result.append(world.allocator, r);
        }
    }

    std.mem.sort(sb.SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: sb.SensorReading, rhs: sb.SensorReading) bool {
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return try result.toOwnedSlice(world.allocator);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence test
//
// This is the TEMPLATE for every future backend-equivalence test:
//   1. Seed a deterministic PRNG with a fixed seed.
//   2. Generate the SAME synthetic dataset once.
//   3. Insert it into World(AoS) and World(SoA) independently.
//   4. Run the query on both worlds.
//   5. Assert results agree within a documented float tolerance.
//
// The tolerance is 1e-5 (absolute). This is generous for f32 summation of
// a few hundred values — the real goal is catching logic divergences
// between backends, not numerical noise from different iteration orders.
// ---------------------------------------------------------------------------

const aos = @import("../ecs/storage/backends/aos_storage.zig");
const soa = @import("../ecs/storage/backends/soa_storage.zig");
const timeseries = @import("../ecs/storage/backends/timeseries_storage.zig");
const columnar = @import("../ecs/storage/backends/columnar_storage.zig");
const hierarchical = @import("../ecs/storage/backends/hierarchical_storage.zig");
const ringbuffer = @import("../ecs/storage/backends/ringbuffer_storage.zig");
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

test "query_avg_window: AoS, SoA, TimeSeries, Columnar, and Hierarchical agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    // Test several sensors and window sizes
    const test_cases = [_]struct { sensor: u32, hours: u32 }{
        .{ .sensor = 0, .hours = 1 },
        .{ .sensor = 0, .hours = 6 },
        .{ .sensor = 0, .hours = 24 },
        .{ .sensor = 0, .hours = 50 },
        .{ .sensor = 3, .hours = 1 },
        .{ .sensor = 3, .hours = 12 },
        .{ .sensor = 3, .hours = 50 },
        .{ .sensor = 9, .hours = 1 },
        .{ .sensor = 9, .hours = 24 },
        .{ .sensor = 9, .hours = 50 },
    };

    // Tolerance: 1e-5 absolute. All backends iterate the same sorted
    // result set and sum f32s in the same order, so they should agree
    // to within float rounding noise. 1e-5 is generous for ~50 values.
    const tolerance: f32 = 1e-5;

    for (test_cases) |tc| {
        const avg_aos = try query_avg_window(&world_aos, tc.sensor, tc.hours);
        const avg_soa = try query_avg_window(&world_soa, tc.sensor, tc.hours);
        const avg_ts = try query_avg_window(&world_ts, tc.sensor, tc.hours);
        const avg_col = try query_avg_window(&world_col, tc.sensor, tc.hours);
        const avg_hier = try query_avg_window(&world_hier, tc.sensor, tc.hours);
        const avg_rb = try query_avg_window(&world_rb, tc.sensor, tc.hours);

        try std.testing.expectApproxEqAbs(avg_aos, avg_soa, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_ts, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_col, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_hier, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_rb, tolerance);
    }
}

test "query_avg_window: returns 0.0 for nonexistent sensor" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_avg_window(&world, 999, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result);
}

test "query_avg_window: returns 0.0 for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_avg_window(&world, 0, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result);
}

test "query_avg_window: single reading returns that reading's value" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    try world.insert(.{
        .sensor_id = 5,
        .timestamp = 1_000_000,
        .value = 42.0,
        .sensor_type = .temperature,
    });

    const result = try query_avg_window(&world, 5, 24);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), result, 1e-5);
}

test "query_latest_single: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    for (0..NUM_SENSORS) |s| {
        const sensor: u32 = @intCast(s);
        const r_aos = try query_latest_single(&world_aos, sensor);
        const r_soa = try query_latest_single(&world_soa, sensor);
        const r_ts = try query_latest_single(&world_ts, sensor);
        const r_col = try query_latest_single(&world_col, sensor);
        const r_hier = try query_latest_single(&world_hier, sensor);
        const r_rb = try query_latest_single(&world_rb, sensor);

        const ref = r_aos;
        const others = [_]?sb.SensorReading{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            if (ref) |r| {
                try std.testing.expect(o != null);
                try std.testing.expectEqual(r.sensor_id, o.?.sensor_id);
                try std.testing.expectEqual(r.timestamp, o.?.timestamp);
                try std.testing.expectApproxEqAbs(r.value, o.?.value, 1e-5);
            } else {
                try std.testing.expect(o == null);
            }
        }
    }
}

test "query_latest_single: returns null for nonexistent sensor" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_latest_single(&world, 999);
    try std.testing.expect(result == null);
}

test "query_latest_single: returns null for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_latest_single(&world, 0);
    try std.testing.expect(result == null);
}

test "query_latest_zone: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    const zone_cases = [_]u32{ 0, 1 };

    for (zone_cases) |zone_id| {
        const r_aos = try query_latest_zone(&world_aos, zone_id);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_latest_zone(&world_soa, zone_id);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_latest_zone(&world_ts, zone_id);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_latest_zone(&world_col, zone_id);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_latest_zone(&world_hier, zone_id);
        defer world_hier.allocator.free(r_hier);
        const r_rb = try query_latest_zone(&world_rb, zone_id);
        defer world_rb.allocator.free(r_rb);

        const ref = r_aos;
        const others = [_][]const sb.SensorReading{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i].sensor_id, o[i].sensor_id);
                try std.testing.expectEqual(ref[i].timestamp, o[i].timestamp);
                try std.testing.expectApproxEqAbs(ref[i].value, o[i].value, 1e-5);
            }
        }
    }
}

test "query_latest_zone: returns empty for nonexistent zone" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_latest_zone(&world, 999);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_latest_zone: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_latest_zone(&world, 0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_latest_by_type: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    const type_cases = [_]sb.SensorType{ .temperature, .humidity, .co2, .occupancy, .energy };

    for (type_cases) |st| {
        const r_aos = try query_latest_by_type(&world_aos, st);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_latest_by_type(&world_soa, st);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_latest_by_type(&world_ts, st);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_latest_by_type(&world_col, st);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_latest_by_type(&world_hier, st);
        defer world_hier.allocator.free(r_hier);
        const r_rb = try query_latest_by_type(&world_rb, st);
        defer world_rb.allocator.free(r_rb);

        const ref = r_aos;
        const others = [_][]const sb.SensorReading{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i].sensor_id, o[i].sensor_id);
                try std.testing.expectEqual(ref[i].timestamp, o[i].timestamp);
                try std.testing.expectApproxEqAbs(ref[i].value, o[i].value, 1e-5);
            }
        }
    }
}

test "query_latest_by_type: returns empty for type with no sensors" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_latest_by_type(&world, .vibration);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_latest_by_type: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_latest_by_type(&world, .temperature);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q5 (query_avg_zone_type)
// ---------------------------------------------------------------------------

test "query_avg_zone_type: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    // Zone 0 = sensors 0–4, Zone 1 = sensors 5–9
    // Zone 0 has temperature (0,1,2) and humidity (3,4)
    // Zone 1 has co2 (5,6), occupancy (7,8), energy (9)
    const test_cases = [_]struct { zone: u32, st: sb.SensorType, hours: u32 }{
        .{ .zone = 0, .st = .temperature, .hours = 1 },
        .{ .zone = 0, .st = .temperature, .hours = 24 },
        .{ .zone = 0, .st = .temperature, .hours = 50 },
        .{ .zone = 0, .st = .humidity, .hours = 1 },
        .{ .zone = 0, .st = .humidity, .hours = 50 },
        .{ .zone = 1, .st = .co2, .hours = 12 },
        .{ .zone = 1, .st = .co2, .hours = 50 },
        .{ .zone = 1, .st = .occupancy, .hours = 24 },
        .{ .zone = 1, .st = .energy, .hours = 1 },
        .{ .zone = 1, .st = .energy, .hours = 50 },
    };

    const tolerance: f32 = 1e-5;

    for (test_cases) |tc| {
        const avg_aos = try query_avg_zone_type(&world_aos, tc.zone, tc.st, tc.hours);
        const avg_soa = try query_avg_zone_type(&world_soa, tc.zone, tc.st, tc.hours);
        const avg_ts = try query_avg_zone_type(&world_ts, tc.zone, tc.st, tc.hours);
        const avg_col = try query_avg_zone_type(&world_col, tc.zone, tc.st, tc.hours);
        const avg_hier = try query_avg_zone_type(&world_hier, tc.zone, tc.st, tc.hours);
        const avg_rb = try query_avg_zone_type(&world_rb, tc.zone, tc.st, tc.hours);

        try std.testing.expectApproxEqAbs(avg_aos, avg_soa, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_ts, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_col, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_hier, tolerance);
        try std.testing.expectApproxEqAbs(avg_aos, avg_rb, tolerance);
    }
}

test "query_avg_zone_type: returns 0.0 for nonexistent zone" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_avg_zone_type(&world, 999, .temperature, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result);
}

test "query_avg_zone_type: returns 0.0 for type with no sensors in zone" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    // Zone 0 has temperature and humidity, not co2
    const result = try query_avg_zone_type(&world, 0, .co2, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result);
}

test "query_avg_zone_type: returns 0.0 for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_avg_zone_type(&world, 0, .temperature, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q6 (query_floor_stats)
// ---------------------------------------------------------------------------

test "query_floor_stats: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    // Floor 0 = sensors 0–9 (all 10 sensors with SENSORS_PER_FLOOR=10)
    // Floor 1 = no sensors (only 10 sensors total)
    const test_cases = [_]struct { floor: u32, st: sb.SensorType, hours: u32 }{
        .{ .floor = 0, .st = .temperature, .hours = 1 },
        .{ .floor = 0, .st = .temperature, .hours = 24 },
        .{ .floor = 0, .st = .temperature, .hours = 50 },
        .{ .floor = 0, .st = .humidity, .hours = 12 },
        .{ .floor = 0, .st = .co2, .hours = 50 },
        .{ .floor = 0, .st = .occupancy, .hours = 1 },
        .{ .floor = 0, .st = .energy, .hours = 50 },
    };

    const tolerance: f32 = 1e-5;

    for (test_cases) |tc| {
        const s_aos = try query_floor_stats(&world_aos, tc.floor, tc.st, tc.hours);
        const s_soa = try query_floor_stats(&world_soa, tc.floor, tc.st, tc.hours);
        const s_ts = try query_floor_stats(&world_ts, tc.floor, tc.st, tc.hours);
        const s_col = try query_floor_stats(&world_col, tc.floor, tc.st, tc.hours);
        const s_hier = try query_floor_stats(&world_hier, tc.floor, tc.st, tc.hours);
        const s_rb = try query_floor_stats(&world_rb, tc.floor, tc.st, tc.hours);

        const others = [_]Stats{ s_soa, s_ts, s_col, s_hier, s_rb };
        for (others) |o| {
            try std.testing.expectApproxEqAbs(s_aos.min, o.min, tolerance);
            try std.testing.expectApproxEqAbs(s_aos.max, o.max, tolerance);
            try std.testing.expectApproxEqAbs(s_aos.avg, o.avg, tolerance);
        }
    }
}

test "query_floor_stats: returns zeros for nonexistent floor" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_floor_stats(&world, 999, .temperature, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result.min);
    try std.testing.expectEqual(@as(f32, 0.0), result.max);
    try std.testing.expectEqual(@as(f32, 0.0), result.avg);
}

test "query_floor_stats: returns zeros for type with no sensors on floor" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    // Floor 0 has temperature, humidity, co2, occupancy, energy — but not vibration
    const result = try query_floor_stats(&world, 0, .vibration, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result.min);
    try std.testing.expectEqual(@as(f32, 0.0), result.max);
    try std.testing.expectEqual(@as(f32, 0.0), result.avg);
}

test "query_floor_stats: returns zeros for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_floor_stats(&world, 0, .temperature, 24);
    try std.testing.expectEqual(@as(f32, 0.0), result.min);
    try std.testing.expectEqual(@as(f32, 0.0), result.max);
    try std.testing.expectEqual(@as(f32, 0.0), result.avg);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q7 (query_hourly_rollup)
//
// RingBuffer is excluded: historical rollup queries span evicted data.
// Only the five full-retention backends are compared.
// ---------------------------------------------------------------------------

test "query_hourly_rollup: five supported backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);

    // 50 readings/sensor at 1-hour intervals → up to 50 hour buckets.
    // days=1 → 24h window, days=2 → 48h window.
    const test_cases = [_]struct { sensor: u32, days: u32 }{
        .{ .sensor = 0, .days = 1 },
        .{ .sensor = 0, .days = 2 },
        .{ .sensor = 3, .days = 1 },
        .{ .sensor = 9, .days = 2 },
    };

    for (test_cases) |tc| {
        const r_aos = try query_hourly_rollup(&world_aos, tc.sensor, tc.days);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_hourly_rollup(&world_soa, tc.sensor, tc.days);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_hourly_rollup(&world_ts, tc.sensor, tc.days);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_hourly_rollup(&world_col, tc.sensor, tc.days);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_hourly_rollup(&world_hier, tc.sensor, tc.days);
        defer world_hier.allocator.free(r_hier);

        const ref = r_aos;
        const others = [_][]HourlyAggregate{ r_soa, r_ts, r_col, r_hier };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i].hour_bucket, o[i].hour_bucket);
                try std.testing.expectApproxEqAbs(ref[i].avg, o[i].avg, 1e-5);
                try std.testing.expectApproxEqAbs(ref[i].min, o[i].min, 1e-5);
                try std.testing.expectApproxEqAbs(ref[i].max, o[i].max, 1e-5);
                try std.testing.expectEqual(ref[i].count, o[i].count);
            }
        }
    }
}

test "query_hourly_rollup: returns empty for nonexistent sensor" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_hourly_rollup(&world, 999, 1);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_hourly_rollup: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_hourly_rollup(&world, 0, 1);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q8 (query_daily_zone_rollup)
// ---------------------------------------------------------------------------

test "query_daily_zone_rollup: five supported backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);

    // Zone 0 = sensors 0–4, Zone 1 = sensors 5–9
    // 50 readings/sensor at 1-hour intervals → ~2 day buckets per sensor
    const test_cases = [_]struct { zone: u32, st: sb.SensorType }{
        .{ .zone = 0, .st = .temperature },
        .{ .zone = 0, .st = .humidity },
        .{ .zone = 1, .st = .co2 },
        .{ .zone = 1, .st = .energy },
    };

    for (test_cases) |tc| {
        const r_aos = try query_daily_zone_rollup(&world_aos, tc.zone, tc.st);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_daily_zone_rollup(&world_soa, tc.zone, tc.st);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_daily_zone_rollup(&world_ts, tc.zone, tc.st);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_daily_zone_rollup(&world_col, tc.zone, tc.st);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_daily_zone_rollup(&world_hier, tc.zone, tc.st);
        defer world_hier.allocator.free(r_hier);

        const ref = r_aos;
        const others = [_][]DailyAggregate{ r_soa, r_ts, r_col, r_hier };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i].day_bucket, o[i].day_bucket);
                try std.testing.expectApproxEqAbs(ref[i].avg, o[i].avg, 1e-5);
                try std.testing.expectApproxEqAbs(ref[i].min, o[i].min, 1e-5);
                try std.testing.expectApproxEqAbs(ref[i].max, o[i].max, 1e-5);
                try std.testing.expectEqual(ref[i].count, o[i].count);
            }
        }
    }
}

test "query_daily_zone_rollup: returns empty for nonexistent zone" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_daily_zone_rollup(&world, 999, .temperature);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_daily_zone_rollup: returns empty for type with no sensors in zone" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    // Zone 0 has temperature and humidity, not co2
    const result = try query_daily_zone_rollup(&world, 0, .co2);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_daily_zone_rollup: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_daily_zone_rollup(&world, 0, .temperature);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q9 (query_spatial_radius)
//
// All six backends must return identical sensor ID sets for the same center
// and radius. The derived sensorPosition() is a pure function of sensor_id,
// so results are backend-independent.
// ---------------------------------------------------------------------------

test "query_spatial_radius: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    // Test several (center, radius) pairs across the synthetic sensor grid.
    // Sensors 0–9: x = (id%10)*5, y = (id/10)*3, z = 0.
    // All 10 sensors sit at y=0 (ids 0–9 → id/10 = 0), x = 0,5,10,15,20,25,30,35,40,45.
    const test_cases = [_]struct { center: Vec3, radius: f32 }{
        .{ .center = .{ .x = 0.0, .y = 0.0, .z = 0.0 }, .radius = 1.0 }, // only sensor 0
        .{ .center = .{ .x = 0.0, .y = 0.0, .z = 0.0 }, .radius = 6.0 }, // sensors 0 and 1
        .{ .center = .{ .x = 22.5, .y = 0.0, .z = 0.0 }, .radius = 5.0 }, // sensors 4 (x=20) and 5 (x=25)
        .{ .center = .{ .x = 22.5, .y = 0.0, .z = 0.0 }, .radius = 100.0 }, // all sensors
        .{ .center = .{ .x = 999.0, .y = 999.0, .z = 0.0 }, .radius = 1.0 }, // no sensors
    };

    for (test_cases) |tc| {
        const r_aos = try query_spatial_radius(&world_aos, tc.center, tc.radius);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_spatial_radius(&world_soa, tc.center, tc.radius);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_spatial_radius(&world_ts, tc.center, tc.radius);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_spatial_radius(&world_col, tc.center, tc.radius);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_spatial_radius(&world_hier, tc.center, tc.radius);
        defer world_hier.allocator.free(r_hier);
        const r_rb = try query_spatial_radius(&world_rb, tc.center, tc.radius);
        defer world_rb.allocator.free(r_rb);

        const ref = r_aos;
        const others = [_][]EntityId{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i], o[i]);
            }
        }
    }
}

test "query_spatial_radius: exact boundary sensor included" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    // Insert only sensor 0 (position x=0, y=0, z=0)
    try world.insert(.{ .sensor_id = 0, .timestamp = 1_000_000, .value = 20.0, .sensor_type = .temperature });

    // Center at origin, radius exactly 0.0 — sensor 0 is at distance 0, included.
    const result = try query_spatial_radius(&world, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, 0.0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(EntityId, 0), result[0]);
}

test "query_spatial_radius: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_spatial_radius(&world, .{ .x = 0.0, .y = 0.0, .z = 0.0 }, 100.0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_spatial_radius: returns empty when no sensor within radius" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_spatial_radius(&world, .{ .x = 999.0, .y = 999.0, .z = 0.0 }, 1.0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q10 (query_zone_hierarchy)
//
// All six backends must return identical sensor ID sets for the same
// (zone_id, depth). HierarchicalStorage is expected to be fastest because
// its tree index avoids scanning the full dataset.
// ---------------------------------------------------------------------------

test "query_zone_hierarchy: all six backends agree on same seeded dataset" {
    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, dataset);
    try insertDataset(&world_soa, dataset);
    try insertDataset(&world_ts, dataset);
    try insertDataset(&world_col, dataset);
    try insertDataset(&world_hier, dataset);
    try insertDataset(&world_rb, dataset);

    // SENSORS_PER_ZONE=5, ZONES_PER_FLOOR=2 → zone 0 = sensors 0–4,
    // zone 1 = sensors 5–9. Both zones on floor 0.
    const test_cases = [_]struct { zone: u32, depth: u32 }{
        .{ .zone = 0, .depth = 0 }, // sensors 0–4
        .{ .zone = 1, .depth = 0 }, // sensors 5–9
        .{ .zone = 0, .depth = 1 }, // floor 0 → sensors 0–9 (both zones)
        .{ .zone = 1, .depth = 1 }, // floor 0 → sensors 0–9 (same floor)
        .{ .zone = 0, .depth = 2 }, // building root → all sensors
        .{ .zone = 0, .depth = 9 }, // depth overflow → all sensors
    };

    for (test_cases) |tc| {
        const r_aos = try query_zone_hierarchy(&world_aos, tc.zone, tc.depth);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_zone_hierarchy(&world_soa, tc.zone, tc.depth);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_zone_hierarchy(&world_ts, tc.zone, tc.depth);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_zone_hierarchy(&world_col, tc.zone, tc.depth);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_zone_hierarchy(&world_hier, tc.zone, tc.depth);
        defer world_hier.allocator.free(r_hier);
        const r_rb = try query_zone_hierarchy(&world_rb, tc.zone, tc.depth);
        defer world_rb.allocator.free(r_rb);

        const ref = r_aos;
        const others = [_][]EntityId{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i], o[i]);
            }
        }
    }
}

test "query_zone_hierarchy: depth 0 returns only sensors in the requested zone" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    // Zone 0 = sensors 0–4 (sensor_id / SENSORS_PER_ZONE == 0)
    const result = try query_zone_hierarchy(&world, 0, 0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, SENSORS_PER_ZONE), result.len);
    for (0..SENSORS_PER_ZONE) |i| {
        try std.testing.expectEqual(@as(EntityId, @intCast(i)), result[i]);
    }
}

test "query_zone_hierarchy: depth 1 returns all sensors on the floor" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    // Zone 0 is on floor 0. Floor 0 contains zones 0 and 1 → sensors 0–9.
    const result = try query_zone_hierarchy(&world, 0, 1);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, NUM_SENSORS), result.len);
    for (0..NUM_SENSORS) |i| {
        try std.testing.expectEqual(@as(EntityId, @intCast(i)), result[i]);
    }
}

test "query_zone_hierarchy: depth 2 returns all sensors" {
    var world = try World(hierarchical).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_zone_hierarchy(&world, 0, 2);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, NUM_SENSORS), result.len);
}

test "query_zone_hierarchy: nonexistent zone returns empty" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const dataset = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(dataset);
    try insertDataset(&world, dataset);

    const result = try query_zone_hierarchy(&world, 999, 0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "query_zone_hierarchy: returns empty for empty world" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();

    const result = try query_zone_hierarchy(&world, 0, 0);
    defer world.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Golden-result equivalence tests for Q11 (query_anomalies) and Q12
// (query_threshold_breach). Anomaly queries are pure scans, so all six
// backends — including RingBuffer (no eviction at this dataset size) — agree.
// ---------------------------------------------------------------------------

test "query_anomalies: all six backends agree on same seeded dataset" {
    const ds = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(ds);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, ds);
    try insertDataset(&world_soa, ds);
    try insertDataset(&world_ts, ds);
    try insertDataset(&world_col, ds);
    try insertDataset(&world_hier, ds);
    try insertDataset(&world_rb, ds);

    const cases = [_]struct { st: sb.SensorType, sigma: f32 }{
        .{ .st = .temperature, .sigma = 1.0 },
        .{ .st = .temperature, .sigma = 2.0 },
        .{ .st = .humidity, .sigma = 0.5 },
        .{ .st = .co2, .sigma = 1.0 },
        .{ .st = .occupancy, .sigma = 0.8 },
        .{ .st = .vibration, .sigma = 1.0 },
    };

    for (cases) |tc| {
        const r_aos = try query_anomalies(&world_aos, tc.st, tc.sigma);
        defer world_aos.allocator.free(r_aos);
        const r_soa = try query_anomalies(&world_soa, tc.st, tc.sigma);
        defer world_soa.allocator.free(r_soa);
        const r_ts = try query_anomalies(&world_ts, tc.st, tc.sigma);
        defer world_ts.allocator.free(r_ts);
        const r_col = try query_anomalies(&world_col, tc.st, tc.sigma);
        defer world_col.allocator.free(r_col);
        const r_hier = try query_anomalies(&world_hier, tc.st, tc.sigma);
        defer world_hier.allocator.free(r_hier);
        const r_rb = try query_anomalies(&world_rb, tc.st, tc.sigma);
        defer world_rb.allocator.free(r_rb);

        const ref = r_aos;
        const others = [_][]AnomalyResult{ r_soa, r_ts, r_col, r_hier, r_rb };
        for (others) |o| {
            try std.testing.expectEqual(ref.len, o.len);
            for (0..ref.len) |i| {
                try std.testing.expectEqual(ref[i].reading.sensor_id, o[i].reading.sensor_id);
                try std.testing.expectEqual(ref[i].reading.timestamp, o[i].reading.timestamp);
                try std.testing.expectApproxEqAbs(ref[i].reading.value, o[i].reading.value, 1e-5);
                try std.testing.expectApproxEqAbs(ref[i].z_score, o[i].z_score, 1e-4);
            }
        }
    }
}

test "query_anomalies: returns empty when fewer than 2 readings of the type" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    try world.insert(.{ .sensor_id = 0, .timestamp = 1, .value = 100.0, .sensor_type = .temperature });
    const r = try query_anomalies(&world, .temperature, 1.0);
    defer world.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "query_anomalies: returns empty when all values are identical" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();
    try world.insert(.{ .sensor_id = 0, .timestamp = 1, .value = 42.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 0, .timestamp = 2, .value = 42.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 0, .timestamp = 3, .value = 42.0, .sensor_type = .temperature });
    const r = try query_anomalies(&world, .temperature, 0.1);
    defer world.allocator.free(r);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "query_anomalies: high-sigma threshold filters out modest deviations" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    var i: u32 = 0;
    while (i < 19) : (i += 1) {
        try world.insert(.{ .sensor_id = 1, .timestamp = @as(i64, i), .value = 10.0, .sensor_type = .temperature });
    }
    try world.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1000.0, .sensor_type = .temperature });

    const high = try query_anomalies(&world, .temperature, 2.0);
    defer world.allocator.free(high);
    try std.testing.expectEqual(@as(usize, 1), high.len);
    try std.testing.expectEqual(@as(f32, 1000.0), high[0].reading.value);

    const huge = try query_anomalies(&world, .temperature, 1000.0);
    defer world.allocator.free(huge);
    try std.testing.expectEqual(@as(usize, 0), huge.len);
}

test "query_threshold_breach: all six backends agree on same seeded dataset" {
    const ds = try generateDataset(std.testing.allocator);
    defer std.testing.allocator.free(ds);

    var world_aos = try World(aos).init(std.testing.allocator);
    defer world_aos.deinit();
    var world_soa = try World(soa).init(std.testing.allocator);
    defer world_soa.deinit();
    var world_ts = try World(timeseries).init(std.testing.allocator);
    defer world_ts.deinit();
    var world_col = try World(columnar).init(std.testing.allocator);
    defer world_col.deinit();
    var world_hier = try World(hierarchical).init(std.testing.allocator);
    defer world_hier.deinit();
    var world_rb = try World(ringbuffer).init(std.testing.allocator);
    defer world_rb.deinit();

    try insertDataset(&world_aos, ds);
    try insertDataset(&world_soa, ds);
    try insertDataset(&world_ts, ds);
    try insertDataset(&world_col, ds);
    try insertDataset(&world_hier, ds);
    try insertDataset(&world_rb, ds);

    const cases = [_]struct { sensor: u32, threshold: f32, min_dur_hours: i64 }{
        .{ .sensor = 0, .threshold = 9.5, .min_dur_hours = 1 },
        .{ .sensor = 0, .threshold = 9.5, .min_dur_hours = 24 },
        .{ .sensor = 5, .threshold = 14.5, .min_dur_hours = 10 },
        .{ .sensor = 9, .threshold = 100.0, .min_dur_hours = 1 },
    };

    for (cases) |tc| {
        const min_dur_ms = tc.min_dur_hours * 60 * 60 * 1000;
        const r_aos = try query_threshold_breach(&world_aos, tc.sensor, tc.threshold, min_dur_ms);
        const r_soa = try query_threshold_breach(&world_soa, tc.sensor, tc.threshold, min_dur_ms);
        const r_ts = try query_threshold_breach(&world_ts, tc.sensor, tc.threshold, min_dur_ms);
        const r_col = try query_threshold_breach(&world_col, tc.sensor, tc.threshold, min_dur_ms);
        const r_hier = try query_threshold_breach(&world_hier, tc.sensor, tc.threshold, min_dur_ms);
        const r_rb = try query_threshold_breach(&world_rb, tc.sensor, tc.threshold, min_dur_ms);

        const others = [_]?BreachEvent{ r_soa, r_ts, r_col, r_hier, r_rb };
        if (r_aos) |ref| {
            for (others) |o| {
                try std.testing.expect(o != null);
                try std.testing.expectEqual(ref.sensor_id, o.?.sensor_id);
                try std.testing.expectEqual(ref.start_ts, o.?.start_ts);
                try std.testing.expectEqual(ref.end_ts, o.?.end_ts);
                try std.testing.expectEqual(ref.duration_ms, o.?.duration_ms);
                try std.testing.expectApproxEqAbs(ref.peak_value, o.?.peak_value, 1e-5);
            }
        } else {
            for (others) |o| try std.testing.expect(o == null);
        }
    }
}

test "query_threshold_breach: returns null for sensor with no readings" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    const r = try query_threshold_breach(&world, 0, 0.0, 0);
    try std.testing.expect(r == null);
}

test "query_threshold_breach: returns the first sustained run, not later ones" {
    var world = try World(soa).init(std.testing.allocator);
    defer world.deinit();
    try world.insert(.{ .sensor_id = 7, .timestamp = 0, .value = 100.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 10, .value = 5.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 100, .value = 100.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 200, .value = 110.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 300, .value = 105.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 400, .value = 5.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 500, .value = 200.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 600, .value = 250.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 7, .timestamp = 700, .value = 5.0, .sensor_type = .temperature });

    const r = (try query_threshold_breach(&world, 7, 50.0, 150)).?;
    try std.testing.expectEqual(@as(i64, 100), r.start_ts);
    try std.testing.expectEqual(@as(i64, 300), r.end_ts);
    try std.testing.expectEqual(@as(i64, 200), r.duration_ms);
    try std.testing.expectEqual(@as(f32, 110.0), r.peak_value);
}

test "query_threshold_breach: returns null when no run meets min_duration_ms" {
    var world = try World(aos).init(std.testing.allocator);
    defer world.deinit();
    try world.insert(.{ .sensor_id = 3, .timestamp = 0, .value = 99.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 3, .timestamp = 10, .value = 99.0, .sensor_type = .temperature });
    try world.insert(.{ .sensor_id = 3, .timestamp = 20, .value = 1.0, .sensor_type = .temperature });
    const r = try query_threshold_breach(&world, 3, 50.0, 1000);
    try std.testing.expect(r == null);
}
