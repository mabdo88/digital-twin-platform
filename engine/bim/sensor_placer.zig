// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Sensor placer — Phase 4.3.
//
// Attaches virtual sensors to building elements using a DATA-DRIVEN rule set
// (CLAUDE.md §3.5). Rules are values, not code — the placer never branches on
// element type; it just looks up the matching rule and applies it.
//
// Defaults come from spec §7.3:
//   Space        -> Temp + Humidity + Occupancy   at density 1.0 / 100m²
//   FlowSegment  -> Flow + Temperature            at density 2.0 / 100m²
//   Beam         -> Structural                    at density 0.5 / 100m²
//
// Phase 5 will override these per building-type profile (Office, Hospital, …).
// Because rules are just `[]const PlacementRule`, a profile is just a
// different slice — no code change in the placer.
//
// One open call we're making explicit:
//   ZoneMetadata.area_m2 is currently always 0 (IfcQuantitySet extraction is
//   deferred — see components.zig + 4.5's IFC_SUPPORT.md). When area is 0 we
//   fall back to `PlacementConfig.default_unknown_area_m2` (defaults to
//   100 m²) so density 1.0 yields exactly 1 sensor per matching zone instead
//   of zero. This keeps the math meaningful today and stays correct the
//   instant real areas land.

const std = @import("std");
const Allocator = std.mem.Allocator;
const components = @import("components.zig");

pub const BuildingElement = components.BuildingElement;
pub const ZoneMetadata = components.ZoneMetadata;
pub const ElementType = components.ElementType;
pub const SensorType = components.SensorType;
pub const SensorMetadata = components.SensorMetadata;
pub const ZoneLocation = components.ZoneLocation;
pub const Vec3 = components.Vec3;

/// One placement rule — declarative. The placer evaluates every element
/// against this set; the first rule whose `element_type` matches wins.
/// (No rule chaining — we keep one rule per element type to avoid the
/// ordering games that come with priority systems. Profiles override
/// wholesale, not by layering.)
pub const PlacementRule = struct {
    element_type: ElementType,
    /// Sensor kinds to spawn per replication slot. With density 2.0 / 100m²
    /// on a 100 m² space, count_per_type = 2 → 2 × len(sensor_types) total
    /// sensors are emitted for that element.
    sensor_types: []const SensorType,
    /// Spawn density in sensors-per-type per 100 m² of effective area.
    density_per_100m2: f32,
    /// Sampling frequency stamped onto every sensor this rule produces.
    frequency_hz: f32,
};

/// Spec §7.3 defaults. Profiles in Phase 5 are just different slices of this
/// same shape — the placer reads `rules`, never this constant directly.
pub const DEFAULT_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy },
        .density_per_100m2 = 1.0,
        .frequency_hz = 0.1,
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
        .density_per_100m2 = 2.0,
        .frequency_hz = 1.0,
    },
    .{
        .element_type = .beam,
        .sensor_types = &.{ .structural },
        .density_per_100m2 = 0.5,
        .frequency_hz = 10.0,
    },
    // NOT in the original spec §7.3 list (space/flow_segment/beam only) —
    // added after validating against the real Revit exports in assets/IFC/:
    // one of them (2KHRJ17-HASC-SD-710-EV) has zero spaces/walls/beams but
    // 187 IfcFlowTerminal/IfcBuildingElementProxy/IfcAlarm/etc. instances
    // (see components.zig's ElementType.equipment doc comment) — without
    // this rule that file places exactly 0 sensors despite being a real,
    // fully-populated building. Energy + vibration is a generic pair for
    // monitoring MEP/electrical equipment (draw + mechanical wear); Phase
    // 5 building-type profiles are expected to override this wholesale.
    .{
        .element_type = .equipment,
        .sensor_types = &.{ .energy, .vibration },
        .density_per_100m2 = 1.0,
        .frequency_hz = 1.0,
    },
};

pub const PlacementConfig = struct {
    rules: []const PlacementRule = &DEFAULT_RULES,
    /// Effective area used when the matching ZoneMetadata.area_m2 is 0 (the
    /// only value we extract today) or when the element isn't itself a zone
    /// (beams, flow segments). Picked so density 1.0 yields exactly 1 sensor
    /// per element by default — change this once IfcQuantitySet lands.
    default_unknown_area_m2: f64 = 100.0,
};

/// Result of one placement pass. Arena-owned; one `deinit()` frees both
/// component slices.
pub const Placement = struct {
    arena: std.heap.ArenaAllocator,
    sensors: []SensorMetadata,
    locations: []ZoneLocation,

    pub fn deinit(self: *Placement) void {
        self.arena.deinit();
    }
};

/// Place sensors on every matching element. Pure function of the inputs:
/// the same building + rules always produce byte-identical components
/// (sensor_ids are assigned in element-iteration order, which is `ifc_id`
/// ascending because that's what the parser sorts on).
pub fn place(
    backing_allocator: Allocator,
    building_elements: []const BuildingElement,
    zones: []const ZoneMetadata,
    config: PlacementConfig,
) !Placement {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const ar = arena.allocator();

    // zone_id -> area_m2 lookup so we don't do a linear scan per element.
    var area_of: std.AutoHashMapUnmanaged(u32, f64) = .empty;
    for (zones) |z| try area_of.put(ar, z.zone_id, z.area_m2);

    var sensors: std.ArrayList(SensorMetadata) = .empty;
    defer sensors.deinit(ar);
    var locations: std.ArrayList(ZoneLocation) = .empty;
    defer locations.deinit(ar);

    var next_id: u32 = 0;

    for (building_elements) |elem| {
        const rule = findRule(config.rules, elem.element_type) orelse continue;

        // Effective area: real zone area if known, else fallback.
        const raw_area: f64 = area_of.get(elem.ifc_id) orelse 0;
        const eff_area: f64 = if (raw_area > 0) raw_area else config.default_unknown_area_m2;

        // Sensors per type. Round to nearest, clamped to at least 1 — every
        // rule-matching element gets at least one sensor of each kind, even
        // for tiny areas / low densities. Without this clamp, a 10 m² space
        // at density 0.5 would emit zero structural sensors, which silently
        // hides whole element classes from the benchmark.
        const fcount: f64 = eff_area * @as(f64, rule.density_per_100m2) / 100.0;
        const rounded: u32 = @intFromFloat(@round(fcount));
        const count_per_type: u32 = @max(@as(u32, 1), rounded);

        // Containing zone for ZoneLocation:
        //   - if elem IS a zone (storey/space), zone_id = elem.ifc_id
        //   - else use elem.parent_id when it points at a known zone
        //   - else 0 (no zone)
        const containing_zone: u32 = blk: {
            if (elem.element_type == .storey or elem.element_type == .space) break :blk elem.ifc_id;
            if (elem.parent_id) |pid| if (area_of.contains(pid)) break :blk pid;
            break :blk 0;
        };

        for (rule.sensor_types) |st| {
            var n: u32 = 0;
            while (n < count_per_type) : (n += 1) {
                const sid = next_id;
                next_id += 1;
                try sensors.append(ar, .{
                    .sensor_id = sid,
                    .sensor_type = st,
                    .frequency_hz = rule.frequency_hz,
                    .element_id = elem.ifc_id,
                });
                try locations.append(ar, .{
                    .sensor_id = sid,
                    .zone_id = containing_zone,
                    .position = elem.position,
                });
            }
        }
    }

    return .{
        .arena = arena,
        .sensors = try sensors.toOwnedSlice(ar),
        .locations = try locations.toOwnedSlice(ar),
    };
}

fn findRule(rules: []const PlacementRule, etype: ElementType) ?PlacementRule {
    for (rules) |r| if (r.element_type == etype) return r;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ifc = @import("ifc_parser.zig");

test "DEFAULT_RULES match spec §7.3 (types, densities, frequencies)" {
    const space_rule = findRule(&DEFAULT_RULES, .space).?;
    try testing.expectEqual(@as(usize, 3), space_rule.sensor_types.len);
    try testing.expectEqual(SensorType.temperature, space_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.humidity, space_rule.sensor_types[1]);
    try testing.expectEqual(SensorType.occupancy, space_rule.sensor_types[2]);
    try testing.expectEqual(@as(f32, 1.0), space_rule.density_per_100m2);

    const flow_rule = findRule(&DEFAULT_RULES, .flow_segment).?;
    try testing.expectEqual(@as(f32, 2.0), flow_rule.density_per_100m2);
    try testing.expectEqual(@as(f32, 1.0), flow_rule.frequency_hz);

    const beam_rule = findRule(&DEFAULT_RULES, .beam).?;
    try testing.expectEqual(@as(f32, 0.5), beam_rule.density_per_100m2);
    try testing.expectEqual(@as(f32, 10.0), beam_rule.frequency_hz);

    // Equipment is an addition beyond the original §7.3 list (see its
    // DEFAULT_RULES entry's doc comment) — verify it's present and shaped
    // as documented rather than just assuming the literal spec set.
    const equipment_rule = findRule(&DEFAULT_RULES, .equipment).?;
    try testing.expectEqual(@as(usize, 2), equipment_rule.sensor_types.len);
    try testing.expectEqual(SensorType.energy, equipment_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.vibration, equipment_rule.sensor_types[1]);
    try testing.expectEqual(@as(f32, 1.0), equipment_rule.density_per_100m2);
    try testing.expectEqual(@as(f32, 1.0), equipment_rule.frequency_hz);

    // Walls/slabs are unsupported by default — no surprise placement.
    try testing.expect(findRule(&DEFAULT_RULES, .wall) == null);
    try testing.expect(findRule(&DEFAULT_RULES, .slab) == null);
}

test "places sensors on a parsed building (end-to-end through IFC parser)" {
    const src =
        \\HEADER;ENDSEC;
        \\DATA;
        \\#100 = IFCCARTESIANPOINT((10.0, 20.0, 0.0));
        \\#101 = IFCAXIS2PLACEMENT3D(#100,$,$);
        \\#102 = IFCLOCALPLACEMENT($, #101);
        \\
        \\#1 = IFCPROJECT('p',$,'Proj',$,$,$,$,$,$);
        \\#2 = IFCBUILDING('b',$,'B',$,$,#102,$,$,$,$,$);
        \\#3 = IFCBUILDINGSTOREY('s',$,'L1',$,$,#102,$,$,$,3.0);
        \\#4 = IFCSPACE('sp',$,'R1',$,$,#102,$,$,$,$,$);
        \\#5 = IFCFLOWSEGMENT('f',$,'Duct',$,$,#102,$,$,$);
        \\#6 = IFCBEAM('bm',$,'Beam1',$,$,#102,$,$,$);
        \\#7 = IFCRELAGGREGATES('a1',$,$,$,#1,(#2));
        \\#8 = IFCRELAGGREGATES('a2',$,$,$,#2,(#3));
        \\#9 = IFCRELCONTAINEDINSPATIALSTRUCTURE('c',$,$,$,(#4,#5,#6),#3);
        \\ENDSEC;
    ;
    var model = try ifc.parseSlice(testing.allocator, src);
    defer model.deinit();

    var p = try place(testing.allocator, model.building_elements, model.zones, .{});
    defer p.deinit();

    // With default 100 m² fallback and DEFAULT_RULES:
    //   Space (1.0/100m²)        -> 1 of each of 3 types = 3
    //   FlowSegment (2.0/100m²)  -> 2 of each of 2 types = 4
    //   Beam (0.5/100m²)         -> max(1, round(0.5)) = 1 of structural = 1
    //                                                                    = 8
    try testing.expectEqual(@as(usize, 8), p.sensors.len);
    try testing.expectEqual(@as(usize, 8), p.locations.len);

    // sensor_ids are dense and monotonic.
    for (p.sensors, 0..) |s, i| try testing.expectEqual(@as(u32, @intCast(i)), s.sensor_id);

    // Every sensor's position matches its host element's position. The IFC
    // fixture pins every element to (10, 20, 0) via #102 — easy to assert.
    for (p.locations) |loc| {
        try testing.expectApproxEqAbs(@as(f64, 10), loc.position.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 20), loc.position.y, 1e-9);
    }

    // The Space sensors live in zone_id=4 (the space itself).
    // The FlowSegment + Beam are contained in the storey, so their zone_id
    // is 3 (the containing storey, looked up via parent_id).
    var space_sensors: usize = 0;
    var storey_sensors: usize = 0;
    for (p.locations) |loc| {
        switch (loc.zone_id) {
            4 => space_sensors += 1,
            3 => storey_sensors += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), space_sensors);
    try testing.expectEqual(@as(usize, 5), storey_sensors);
}

test "density math: real area_m2 overrides the default fallback" {
    const elements = [_]BuildingElement{
        .{
            .ifc_id = 42,
            .name = "BigHall",
            .element_type = .space,
            .parent_id = null,
            .position = .{ .x = 0, .y = 0, .z = 0 },
        },
    };
    const zones = [_]ZoneMetadata{
        .{ .zone_id = 42, .name = "BigHall", .zone_type = .space, .floor_level = 0, .area_m2 = 300.0 },
    };

    var p = try place(testing.allocator, &elements, &zones, .{});
    defer p.deinit();

    // Space rule: 3 sensor types × round(300 * 1.0 / 100) = 3 × 3 = 9
    try testing.expectEqual(@as(usize, 9), p.sensors.len);
}

test "elements without a matching rule are skipped silently" {
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "W", .element_type = .wall, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
        .{ .ifc_id = 2, .name = "S", .element_type = .slab, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
        .{ .ifc_id = 3, .name = "P", .element_type = .project, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    var p = try place(testing.allocator, &elements, &.{}, .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.sensors.len);
}

test "custom rules slice fully overrides defaults (Phase 5 profile shape)" {
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "W", .element_type = .wall, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    // Hypothetical "structural-monitoring" profile that places vibration
    // sensors on walls instead of the default empty.
    const custom_rules = [_]PlacementRule{
        .{ .element_type = .wall, .sensor_types = &.{.vibration}, .density_per_100m2 = 1.0, .frequency_hz = 50.0 },
    };
    var p = try place(testing.allocator, &elements, &.{}, .{ .rules = &custom_rules });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.sensors.len);
    try testing.expectEqual(SensorType.vibration, p.sensors[0].sensor_type);
    try testing.expectEqual(@as(f32, 50.0), p.sensors[0].frequency_hz);
}

test "tiny area still gets one sensor per type (clamped, never silently zero)" {
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "Tiny", .element_type = .beam, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    // No matching zone => default_unknown_area_m2 = 100 m².
    // round(100 * 0.5 / 100) = round(0.5) = 0 in banker's rounding, but
    // we clamp to 1 so the beam still gets monitored.
    var p = try place(testing.allocator, &elements, &.{}, .{ .default_unknown_area_m2 = 10.0 });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.sensors.len);
    try testing.expectEqual(SensorType.structural, p.sensors[0].sensor_type);
}
