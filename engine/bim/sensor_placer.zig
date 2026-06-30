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
const synthetic = @import("../synthetic/generator.zig");

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
/// ordering games that come with priority systems.)
///
/// No density_per_100m2 or frequency_hz here — both are sensor-hardware
/// facts, not placement decisions, and belong to the sensor TYPE, not to
/// whichever rule happens to place it (a rule can list multiple
/// sensor_types, and a single density/frequency shared across all of them
/// was the actual bug: it forced e.g. temperature/humidity/occupancy on
/// the same space to share one frequency, and energy/structural density
/// to be guessed per building profile with no grounding — see
/// synthetic/generator.zig's header comment). Both come from
/// synthetic/generator.zig's profileFor, the single canonical source, per
/// individual sensor_type.
pub const PlacementRule = struct {
    element_type: ElementType,
    /// Sensor kinds to spawn on every matching element.
    sensor_types: []const SensorType,
};

/// Spec §7.3 defaults — the only rule set; there is no per-building-type
/// override anymore (see PlacementRule's doc comment for why density
/// moved out of here).
pub const DEFAULT_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy },
    },
    .{
        .element_type = .flow_segment,
        .sensor_types = &.{ .flow, .temperature },
    },
    .{
        .element_type = .beam,
        .sensor_types = &.{.structural},
    },
    // NOT in the original spec §7.3 list (space/flow_segment/beam only) —
    // added after validating against the real Revit exports in assets/IFC/:
    // one of them (2KHRJ17-HASC-SD-710-EV) has zero spaces/walls/beams but
    // 187 IfcFlowTerminal/IfcBuildingElementProxy/IfcAlarm/etc. instances
    // (see components.zig's ElementType.equipment doc comment) — without
    // this rule that file places exactly 0 sensors despite being a real,
    // fully-populated building. Energy + vibration is a generic pair for
    // monitoring MEP/electrical equipment (draw + mechanical wear).
    .{
        .element_type = .equipment,
        .sensor_types = &.{ .energy, .vibration },
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
            // Sensors for this specific type. Round to nearest, clamped to
            // at least 1 — every rule-matching element gets at least one
            // sensor of each kind it's rated for, even at tiny areas / low
            // densities. Without this clamp, a 10 m² space at density 0.5
            // would emit zero structural sensors, which silently hides
            // whole element classes from the benchmark. Density comes from
            // the TYPE (synthetic.profileFor), not the rule — see
            // PlacementRule's doc comment for why a single density shared
            // across a rule's sensor_types was the bug.
            const density = synthetic.profileFor(st).density_per_100m2;
            const fcount: f64 = eff_area * @as(f64, density) / 100.0;
            const rounded: u32 = @intFromFloat(@round(fcount));
            const count_per_type: u32 = @max(@as(u32, 1), rounded);

            var n: u32 = 0;
            while (n < count_per_type) : (n += 1) {
                const sid = next_id;
                next_id += 1;
                try sensors.append(ar, .{
                    .sensor_id = sid,
                    .sensor_type = st,
                    .frequency_hz = synthetic.profileFor(st).frequency_hz,
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

test "DEFAULT_RULES match spec §7.3 (types only — density/frequency are sensor-type facts now, not rule fields)" {
    const space_rule = findRule(&DEFAULT_RULES, .space).?;
    try testing.expectEqual(@as(usize, 3), space_rule.sensor_types.len);
    try testing.expectEqual(SensorType.temperature, space_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.humidity, space_rule.sensor_types[1]);
    try testing.expectEqual(SensorType.occupancy, space_rule.sensor_types[2]);

    const flow_rule = findRule(&DEFAULT_RULES, .flow_segment).?;
    try testing.expectEqual(@as(usize, 2), flow_rule.sensor_types.len);

    const beam_rule = findRule(&DEFAULT_RULES, .beam).?;
    try testing.expectEqual(@as(usize, 1), beam_rule.sensor_types.len);

    // Equipment is an addition beyond the original §7.3 list (see its
    // DEFAULT_RULES entry's doc comment) — verify it's present and shaped
    // as documented rather than just assuming the literal spec set.
    const equipment_rule = findRule(&DEFAULT_RULES, .equipment).?;
    try testing.expectEqual(@as(usize, 2), equipment_rule.sensor_types.len);
    try testing.expectEqual(SensorType.energy, equipment_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.vibration, equipment_rule.sensor_types[1]);

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

    // With default 100 m² fallback and DEFAULT_RULES — density now comes
    // per individual sensor type (synthetic.profileFor), not shared across
    // a rule's whole sensor_types list, so flow_segment's two types
    // (flow, temperature) no longer share one number:
    //   Space: temperature(1.0)=1, humidity(1.0)=1, occupancy(1.0)=1   = 3
    //   FlowSegment: flow(1.5)=round(1.5)=2, temperature(1.0)=1        = 3
    //   Beam: structural(0.5)=max(1,round(0.5))=1                     = 1
    //                                                                  = 7
    try testing.expectEqual(@as(usize, 7), p.sensors.len);
    try testing.expectEqual(@as(usize, 7), p.locations.len);

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
    try testing.expectEqual(@as(usize, 4), storey_sensors);
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

test "custom rules slice fully overrides defaults" {
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "W", .element_type = .wall, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    // Hypothetical "structural-monitoring" rule set that places vibration
    // sensors on walls instead of the default empty.
    const custom_rules = [_]PlacementRule{
        .{ .element_type = .wall, .sensor_types = &.{.vibration} },
    };
    var p = try place(testing.allocator, &elements, &.{}, .{ .rules = &custom_rules });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.sensors.len);
    try testing.expectEqual(SensorType.vibration, p.sensors[0].sensor_type);
    // frequency_hz comes from the canonical per-type table now, not the
    // rule — confirms place() actually wires it through, not just that the
    // field happens to be present.
    try testing.expectEqual(synthetic.profileFor(.vibration).frequency_hz, p.sensors[0].frequency_hz);
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
