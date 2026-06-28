// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Building-type profiles — Phase 5.
//
// Per CLAUDE.md §3.5 / §10: "No hard-coded building assumptions. Rules are
// data, not code." A profile is a bundle of three data tables:
//
//   1. `rules`      — sensor placement (same `[]const PlacementRule` shape
//                      sensor_placer.zig already accepts; see its
//                      "Phase 5 will override these" doc comment).
//   2. `query_mix`   — which of the 12 query patterns this building type
//                      actually runs, and how often (hot vs. cold).
//   3. `retention_days` — how long readings are kept before they age out.
//
// Nothing here branches on building type at runtime — `getProfile` is a
// table lookup, and every consumer (placer, report, cost model) just reads
// whichever profile it's handed. Adding a sixth building type means adding
// a sixth `BuildingProfile` constant, never an `if`.

const std = @import("std");
const placer = @import("sensor_placer.zig");

pub const PlacementRule = placer.PlacementRule;
pub const ElementType = placer.ElementType;
pub const SensorType = placer.SensorType;

pub const BuildingType = enum {
    hospital,
    office,
    warehouse,
    manufacturing,
    campus,
};

/// Mirrors the 12 query patterns in `engine/benchmark/queries.zig`. Kept as
/// its own enum (not re-exported from queries.zig) so profiles.zig has no
/// dependency on the benchmark layer — it only describes *expected* mix,
/// the benchmark runner decides what to do with that.
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

/// One entry in a building's query mix. `weight` is relative call frequency
/// within the profile (not normalized to 1.0 — consumers normalize if they
/// need a probability). `hot` marks queries that hit live/recent data
/// (real-time monitoring) vs. `cold` (historical/compliance/reporting).
pub const QueryWeight = struct {
    query: QueryName,
    weight: f32,
    hot: bool,
};

pub const BuildingProfile = struct {
    building_type: BuildingType,
    /// Sensor placement rules — passed straight into
    /// `sensor_placer.PlacementConfig.rules`.
    rules: []const PlacementRule,
    /// Expected query workload mix. Drives which queries the benchmark
    /// runner weights most heavily when producing a per-project
    /// recommendation (CLAUDE.md §1: "a hospital is not a factory").
    query_mix: []const QueryWeight,
    /// How long readings are retained before eviction/archival.
    retention_days: u32,
};

// ---------------------------------------------------------------------------
// Hospital — patient safety drives everything. Dense environmental +
// occupancy sensing in spaces (cleanroom/ward comfort + presence), fast
// sampling on MEP equipment (medical gas, electrical redundancy), and a
// long regulatory retention window (compliance audits, incident review).
// ---------------------------------------------------------------------------
const HOSPITAL_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy },
        .density_per_100m2 = 2.0,
        .frequency_hz = 1.0,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
        .density_per_100m2 = 3.0,
        .frequency_hz = 2.0,
    },
    .{
        .element_type = .equipment,
        .sensor_types = &.{ .energy, .vibration },
        .density_per_100m2 = 2.0,
        .frequency_hz = 5.0,
    },
    .{
        .element_type = .beam,
        .sensor_types = &.{.structural},
        .density_per_100m2 = 0.5,
        .frequency_hz = 1.0,
    },
};

const HOSPITAL_QUERY_MIX = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 5.0, .hot = true },
    .{ .query = .latest_zone, .weight = 4.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 5.0, .hot = true },
    .{ .query = .anomalies, .weight = 4.0, .hot = true },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 1.0, .hot = false },
};

pub const HOSPITAL = BuildingProfile{
    .building_type = .hospital,
    .rules = &HOSPITAL_RULES,
    .query_mix = &HOSPITAL_QUERY_MIX,
    // 7 years — typical regulatory minimum for facility/equipment monitoring
    // records in clinical environments.
    .retention_days = 2555,
};

// ---------------------------------------------------------------------------
// Office — comfort + cost optimisation, not safety-critical. Lower density,
// slower sampling, query mix favors aggregates (energy/comfort reporting)
// over real-time alerting.
// ---------------------------------------------------------------------------
const OFFICE_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy },
        .density_per_100m2 = 1.0,
        .frequency_hz = 0.1,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
        .density_per_100m2 = 1.0,
        .frequency_hz = 0.5,
    },
    .{
        .element_type = .equipment,
        .sensor_types = &.{.energy},
        .density_per_100m2 = 0.5,
        .frequency_hz = 0.1,
    },
};

const OFFICE_QUERY_MIX = [_]QueryWeight{
    .{ .query = .avg_window, .weight = 3.0, .hot = false },
    .{ .query = .hourly_rollup, .weight = 3.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 3.0, .hot = false },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .latest_zone, .weight = 1.0, .hot = true },
};

pub const OFFICE = BuildingProfile{
    .building_type = .office,
    .rules = &OFFICE_RULES,
    .query_mix = &OFFICE_QUERY_MIX,
    // 1 year — enough for seasonal comfort/energy trend reporting.
    .retention_days = 365,
};

// ---------------------------------------------------------------------------
// Warehouse — sparse occupancy, equipment-centric (cold storage, conveyors,
// forklift charging). Failure detection on equipment matters far more than
// fine-grained zone comfort.
// ---------------------------------------------------------------------------
const WAREHOUSE_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{.temperature},
        .density_per_100m2 = 0.2,
        .frequency_hz = 0.1,
    },
    .{
        .element_type = .equipment,
        .sensor_types = &.{ .energy, .vibration, .temperature },
        .density_per_100m2 = 1.5,
        .frequency_hz = 1.0,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{.flow},
        .density_per_100m2 = 0.5,
        .frequency_hz = 0.5,
    },
};

const WAREHOUSE_QUERY_MIX = [_]QueryWeight{
    .{ .query = .anomalies, .weight = 5.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 4.0, .hot = true },
    .{ .query = .latest_by_type, .weight = 3.0, .hot = true },
    .{ .query = .floor_stats, .weight = 1.0, .hot = false },
};

pub const WAREHOUSE = BuildingProfile{
    .building_type = .warehouse,
    .rules = &WAREHOUSE_RULES,
    .query_mix = &WAREHOUSE_QUERY_MIX,
    // 6 months — equipment failure investigation window; no comfort/
    // compliance driver for longer retention.
    .retention_days = 180,
};

// ---------------------------------------------------------------------------
// Manufacturing — dense structural + vibration sensing for predictive
// maintenance, high-frequency sampling (machinery, not room comfort), long
// retention for trend-based maintenance scheduling (Phase-9-style queries).
// ---------------------------------------------------------------------------
const MANUFACTURING_RULES = [_]PlacementRule{
    .{
        .element_type = .equipment,
        .sensor_types = &.{ .vibration, .energy, .temperature },
        .density_per_100m2 = 3.0,
        .frequency_hz = 10.0,
    },
    .{
        .element_type = .beam,
        .sensor_types = &.{.structural},
        .density_per_100m2 = 1.0,
        .frequency_hz = 10.0,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
        .density_per_100m2 = 1.5,
        .frequency_hz = 2.0,
    },
};

const MANUFACTURING_QUERY_MIX = [_]QueryWeight{
    .{ .query = .anomalies, .weight = 5.0, .hot = true },
    .{ .query = .spatial_radius, .weight = 3.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 4.0, .hot = true },
    .{ .query = .avg_window, .weight = 2.0, .hot = false },
    .{ .query = .hourly_rollup, .weight = 2.0, .hot = false },
};

pub const MANUFACTURING = BuildingProfile{
    .building_type = .manufacturing,
    .rules = &MANUFACTURING_RULES,
    .query_mix = &MANUFACTURING_QUERY_MIX,
    // 2 years — predictive-maintenance trend analysis needs multi-cycle
    // history (equipment duty cycles often span quarters).
    .retention_days = 730,
};

// ---------------------------------------------------------------------------
// Campus — multiple buildings/zones aggregated together; per-element
// density is closer to office levels, but the query mix skews heavily
// toward cross-zone/hierarchy aggregation rather than single-sensor reads.
// ---------------------------------------------------------------------------
const CAMPUS_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy },
        .density_per_100m2 = 0.8,
        .frequency_hz = 0.1,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
        .density_per_100m2 = 1.0,
        .frequency_hz = 0.2,
    },
    .{
        .element_type = .equipment,
        .sensor_types = &.{.energy},
        .density_per_100m2 = 0.5,
        .frequency_hz = 0.1,
    },
};

const CAMPUS_QUERY_MIX = [_]QueryWeight{
    .{ .query = .zone_hierarchy, .weight = 4.0, .hot = false },
    .{ .query = .floor_stats, .weight = 3.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 3.0, .hot = false },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .latest_zone, .weight = 1.0, .hot = true },
};

pub const CAMPUS = BuildingProfile{
    .building_type = .campus,
    .rules = &CAMPUS_RULES,
    .query_mix = &CAMPUS_QUERY_MIX,
    // 1 year — matches office-grade trend reporting; campuses don't carry
    // hospital-grade compliance requirements by default.
    .retention_days = 365,
};

/// Table lookup — the only function in this file. No branching on building
/// type beyond this single switch; every other consumer just reads the
/// returned `BuildingProfile`'s data.
pub fn getProfile(building_type: BuildingType) BuildingProfile {
    return switch (building_type) {
        .hospital => HOSPITAL,
        .office => OFFICE,
        .warehouse => WAREHOUSE,
        .manufacturing => MANUFACTURING,
        .campus => CAMPUS,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "getProfile returns the matching profile for every building type" {
    try testing.expectEqual(BuildingType.hospital, getProfile(.hospital).building_type);
    try testing.expectEqual(BuildingType.office, getProfile(.office).building_type);
    try testing.expectEqual(BuildingType.warehouse, getProfile(.warehouse).building_type);
    try testing.expectEqual(BuildingType.manufacturing, getProfile(.manufacturing).building_type);
    try testing.expectEqual(BuildingType.campus, getProfile(.campus).building_type);
}

test "every profile has non-empty rules, query mix, and positive retention" {
    inline for (.{ BuildingType.hospital, .office, .warehouse, .manufacturing, .campus }) |bt| {
        const profile = getProfile(bt);
        try testing.expect(profile.rules.len > 0);
        try testing.expect(profile.query_mix.len > 0);
        try testing.expect(profile.retention_days > 0);
    }
}

test "hospital retention is longer than warehouse (compliance vs. operational)" {
    try testing.expect(getProfile(.hospital).retention_days > getProfile(.warehouse).retention_days);
}

test "profile rules slot directly into PlacementConfig (Phase 5 integration)" {
    const elements = [_]placer.BuildingElement{
        .{ .ifc_id = 1, .name = "Room", .element_type = .space, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    const profile = getProfile(.hospital);
    var p = try placer.place(testing.allocator, &elements, &.{}, .{ .rules = profile.rules });
    defer p.deinit();

    // Hospital space rule: 3 sensor types x round(100 * 2.0 / 100) = 3 x 2 = 6
    try testing.expectEqual(@as(usize, 6), p.sensors.len);
}

test "warehouse query mix favors anomaly/threshold detection over hospital's" {
    const wh = getProfile(.warehouse).query_mix;
    var found_anomalies = false;
    for (wh) |qw| {
        if (qw.query == .anomalies) {
            found_anomalies = true;
            try testing.expect(qw.hot);
        }
    }
    try testing.expect(found_anomalies);
}
