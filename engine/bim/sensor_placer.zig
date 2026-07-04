// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Sensor placer — Phase 4.3.
//
// Attaches virtual sensors to building elements using a DATA-DRIVEN rule set
// (CLAUDE.md §3.5). Rules are values, not code — the placer never branches on
// element type; it just looks up the matching rule and applies it.
//
// Placement rules map granular IFC element types to sensor types:
//   Space                  -> Temp + Humidity + Occupancy + CO2 + AirQuality
//   FlowSegment            -> (none — sensors go on equipment, not ducts)
//   Beam                   -> Structural
//   FlowTerminal           -> Flow + Temperature
//   FlowController         -> Flow
//   FlowMovingDevice       -> Vibration + Flow
//   FlowStorageDevice      -> Flow
//   EnergyConversionDevice -> Energy + Vibration + Flow
//   ElectricAppliance      -> Energy
//   (passive types: flow_fitting, distribution_control_element,
//    building_element_proxy, alarm, cable_segment -> no sensors)
//
// Density per sensor type comes from synthetic/generator.zig's profileFor,
// not from the rule — a rule can list multiple sensor_types, and each gets
// its own density. Equipment-typed elements use a fixed 1 sensor per type
// (density is area-based and doesn't apply to individual equipment items).
//
// max_per_type caps prevent any single sensor type from dominating on
// buildings with hundreds of spaces or equipment. max_total_sensors is a
// hard ceiling to prevent OutOfMemory on extremely large IFC files.

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

/// Default placement rules — granular per IFC element type.
/// Space: comfort + IAQ sensors (temperature, humidity, occupancy, CO2,
/// air_quality) — ASHRAE 62.1 and WELL Building Standard require IAQ
/// monitoring in occupied spaces.
/// Beam: structural health monitoring (strain gauge equivalent).
/// Equipment types: sensors matched to equipment function —
///   flow_terminal (diffusers/fixtures): flow + temperature
///   flow_controller (dampers/valves/VAV): flow
///   flow_moving_device (pumps/fans): vibration + flow
///   flow_storage_device (tanks): flow
///   energy_conversion_device (boilers/chillers): energy + vibration + flow
///   electric_appliance: energy
/// Passive types (flow_fitting, distribution_control_element,
/// building_element_proxy, alarm, cable_segment) get no sensors.
pub const DEFAULT_RULES = [_]PlacementRule{
    .{
        .element_type = .space,
        .sensor_types = &.{ .temperature, .humidity, .occupancy, .co2, .air_quality },
    },
    .{
        .element_type = .beam,
        .sensor_types = &.{.structural},
    },
    .{
        .element_type = .flow_terminal,
        .sensor_types = &.{ .flow, .temperature },
    },
    .{
        .element_type = .flow_controller,
        .sensor_types = &.{.flow},
    },
    .{
        .element_type = .flow_moving_device,
        .sensor_types = &.{ .vibration, .flow },
    },
    .{
        .element_type = .flow_storage_device,
        .sensor_types = &.{.flow},
    },
    .{
        .element_type = .energy_conversion_device,
        .sensor_types = &.{ .energy, .vibration, .flow },
    },
    .{
        .element_type = .electric_appliance,
        .sensor_types = &.{.energy},
    },
};

/// Set of equipment element types that get EquipmentMetadata but no sensors.
/// Used by isEquipmentType() in resolveHierarchy (ifc_parser.zig) and by
/// tests that count equipment.
pub const EQUIPMENT_TYPES = [_]ElementType{
    .flow_terminal,
    .flow_fitting,
    .flow_controller,
    .flow_moving_device,
    .flow_storage_device,
    .energy_conversion_device,
    .distribution_control_element,
    .building_element_proxy,
    .electric_appliance,
    .alarm,
    .cable_segment,
};

/// Returns true if the ElementType is one of the granular equipment types
/// (used by ifc_parser.zig to decide whether to emit EquipmentMetadata).
pub fn isEquipmentType(et: ElementType) bool {
    inline for (EQUIPMENT_TYPES) |t| if (et == t) return true;
    return false;
}

pub const PlacementConfig = struct {
    rules: []const PlacementRule = &DEFAULT_RULES,
    /// Effective area used when the matching ZoneMetadata.area_m2 is 0 (the
    /// only value we extract today) or when the element isn't itself a zone
    /// (beams, equipment). Picked so density 1.0 yields exactly 1 sensor
    /// per element by default — change this once IfcQuantitySet lands.
    default_unknown_area_m2: f64 = 100.0,
    /// Hard cap on sensors of any one type. Prevents a building with 500
    /// spaces from generating 500 temperature sensors (which at 397-day
    /// retention × 5-min interval = ~57M readings = ~1.3 GB just for
    /// temperature). Default 200 — generous for real buildings, prevents
    /// OOM on synthetic mega-structures.
    max_per_type: u32 = 200,
    /// Hard cap on total sensors across all types. Prevents OOM on
    /// extremely large IFC files with thousands of elements.
    max_total_sensors: u32 = 2000,
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

    // Track per-type counts for max_per_type enforcement.
    const num_sensor_types = @typeInfo(SensorType).@"enum".field_names.len;
    var type_counts: [num_sensor_types]u32 = undefined;
    @memset(&type_counts, 0);

    for (building_elements) |elem| {
        // Hard ceiling on total sensors.
        if (next_id >= config.max_total_sensors) break;

        const rule = findRule(config.rules, elem.element_type) orelse continue;

        // Effective area: real zone area if known, else fallback.
        // Equipment types (individual items, not area-based) get fixed
        // 1 sensor per type — density doesn't apply to a single pump.
        const is_equipment = isEquipmentType(elem.element_type);
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
            // Per-type cap: stop placing this sensor type if we've hit
            // the limit. This prevents 500 spaces from generating 500
            // temperature sensors (which would be ~1.3 GB at 397-day
            // retention). The cap is generous (200) so real buildings
            // are unaffected; it only bites on synthetic mega-structures.
            const ti = @intFromEnum(st);
            if (type_counts[ti] >= config.max_per_type) continue;

            // Sensor count for this type on this element:
            //   - equipment types: exactly 1 per type (a pump gets 1
            //     vibration sensor, not area-scaled)
            //   - zone/structural types: area × density / 100, clamped
            //     to at least 1
            const count_per_type: u32 = if (is_equipment) 1 else blk: {
                const density = synthetic.profileFor(st).density_per_100m2;
                const fcount: f64 = eff_area * @as(f64, density) / 100.0;
                const rounded: u32 = @intFromFloat(@round(fcount));
                break :blk @max(@as(u32, 1), rounded);
            };

            var n: u32 = 0;
            while (n < count_per_type and next_id < config.max_total_sensors and type_counts[ti] < config.max_per_type) : (n += 1) {
                const sid = next_id;
                next_id += 1;
                type_counts[ti] += 1;
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

test "DEFAULT_RULES: granular element types map to correct sensor types" {
    const space_rule = findRule(&DEFAULT_RULES, .space).?;
    try testing.expectEqual(@as(usize, 5), space_rule.sensor_types.len);
    try testing.expectEqual(SensorType.temperature, space_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.humidity, space_rule.sensor_types[1]);
    try testing.expectEqual(SensorType.occupancy, space_rule.sensor_types[2]);
    try testing.expectEqual(SensorType.co2, space_rule.sensor_types[3]);
    try testing.expectEqual(SensorType.air_quality, space_rule.sensor_types[4]);

    const beam_rule = findRule(&DEFAULT_RULES, .beam).?;
    try testing.expectEqual(@as(usize, 1), beam_rule.sensor_types.len);
    try testing.expectEqual(SensorType.structural, beam_rule.sensor_types[0]);

    const flow_terminal_rule = findRule(&DEFAULT_RULES, .flow_terminal).?;
    try testing.expectEqual(@as(usize, 2), flow_terminal_rule.sensor_types.len);
    try testing.expectEqual(SensorType.flow, flow_terminal_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.temperature, flow_terminal_rule.sensor_types[1]);

    const flow_moving_rule = findRule(&DEFAULT_RULES, .flow_moving_device).?;
    try testing.expectEqual(@as(usize, 2), flow_moving_rule.sensor_types.len);
    try testing.expectEqual(SensorType.vibration, flow_moving_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.flow, flow_moving_rule.sensor_types[1]);

    const energy_conv_rule = findRule(&DEFAULT_RULES, .energy_conversion_device).?;
    try testing.expectEqual(@as(usize, 3), energy_conv_rule.sensor_types.len);
    try testing.expectEqual(SensorType.energy, energy_conv_rule.sensor_types[0]);
    try testing.expectEqual(SensorType.vibration, energy_conv_rule.sensor_types[1]);
    try testing.expectEqual(SensorType.flow, energy_conv_rule.sensor_types[2]);

    // flow_segment no longer gets sensors (sensors go on equipment, not ducts).
    try testing.expect(findRule(&DEFAULT_RULES, .flow_segment) == null);
    // Passive equipment types get no sensors.
    try testing.expect(findRule(&DEFAULT_RULES, .flow_fitting) == null);
    try testing.expect(findRule(&DEFAULT_RULES, .alarm) == null);
    try testing.expect(findRule(&DEFAULT_RULES, .building_element_proxy) == null);
    // Walls/slabs are unsupported by default.
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
        \\#7 = IFCFLOWTERMINAL('ft',$,'Diffuser',$,$,#102,$,$,$);
        \\#8 = IFCFLOWMOVINGDEVICE('pmp',$,'Pump',$,$,#102,$,$,$);
        \\#20 = IFCRELAGGREGATES('a1',$,$,$,#1,(#2));
        \\#21 = IFCRELAGGREGATES('a2',$,$,$,#2,(#3));
        \\#22 = IFCRELCONTAINEDINSPATIALSTRUCTURE('c',$,$,$,(#4,#5,#6,#7,#8),#3);
        \\ENDSEC;
    ;
    var model = try ifc.parseSlice(testing.allocator, src);
    defer model.deinit();

    var p = try place(testing.allocator, model.building_elements, model.zones, .{});
    defer p.deinit();

    // With default 100 m² fallback and DEFAULT_RULES:
    //   Space: temp(1.0)=1, hum(1.0)=1, occ(1.0)=1, co2(0.5)=1, aq(0.5)=1 = 5
    //   FlowSegment: no rule (sensors go on equipment, not ducts)        = 0
    //   Beam: structural(0.5)=max(1,round(0.5))=1                        = 1
    //   FlowTerminal: equipment → 1 flow + 1 temperature                  = 2
    //   FlowMovingDevice: equipment → 1 vibration + 1 flow                = 2
    //                                                                     = 10
    try testing.expectEqual(@as(usize, 10), p.sensors.len);
    try testing.expectEqual(@as(usize, 10), p.locations.len);

    // sensor_ids are dense and monotonic.
    for (p.sensors, 0..) |s, i| try testing.expectEqual(@as(u32, @intCast(i)), s.sensor_id);

    // Every sensor's position matches its host element's position.
    for (p.locations) |loc| {
        try testing.expectApproxEqAbs(@as(f64, 10), loc.position.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 20), loc.position.y, 1e-9);
    }

    // Space sensors live in zone_id=4 (the space itself).
    // Beam + equipment are contained in the storey → zone_id=3.
    var space_sensors: usize = 0;
    var storey_sensors: usize = 0;
    for (p.locations) |loc| {
        switch (loc.zone_id) {
            4 => space_sensors += 1,
            3 => storey_sensors += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 5), space_sensors);
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

    // Space rule: 5 sensor types. Densities: temp=1.0, hum=1.0, occ=1.0,
    // co2=0.5, air_quality=0.5. At 300m²: temp=3, hum=3, occ=3, co2=2, aq=2 = 13
    try testing.expectEqual(@as(usize, 13), p.sensors.len);
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
    // No matching zone => default_unknown_area_m2 = 10 m².
    // round(10 * 0.5 / 100) = round(0.05) = 0, but we clamp to 1.
    var p = try place(testing.allocator, &elements, &.{}, .{ .default_unknown_area_m2 = 10.0 });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.sensors.len);
    try testing.expectEqual(SensorType.structural, p.sensors[0].sensor_type);
}

test "equipment types get exactly 1 sensor per type (not area-scaled)" {
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "Pump", .element_type = .flow_moving_device, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
        .{ .ifc_id = 2, .name = "Boiler", .element_type = .energy_conversion_device, .parent_id = null, .position = .{ .x = 0, .y = 0, .z = 0 } },
    };
    var p = try place(testing.allocator, &elements, &.{}, .{});
    defer p.deinit();
    // flow_moving_device: vibration + flow = 2
    // energy_conversion_device: energy + vibration + flow = 3
    try testing.expectEqual(@as(usize, 5), p.sensors.len);
}

test "max_per_type caps prevent sensor explosion on large buildings" {
    // 300 spaces would normally produce 300 temperature sensors —
    // max_per_type=50 should cap it.
    var elements: [300]BuildingElement = undefined;
    for (&elements, 0..) |*e, i| {
        e.* = .{
            .ifc_id = @intCast(i + 1),
            .name = "S",
            .element_type = .space,
            .parent_id = null,
            .position = .{ .x = 0, .y = 0, .z = 0 },
        };
    }
    var p = try place(testing.allocator, &elements, &.{}, .{ .max_per_type = 50 });
    defer p.deinit();

    // Count temperature sensors — should be capped at 50.
    var temp_count: usize = 0;
    for (p.sensors) |s| {
        if (s.sensor_type == .temperature) temp_count += 1;
    }
    try testing.expectEqual(@as(usize, 50), temp_count);
}

test "max_total_sensors hard cap stops placement" {
    var elements: [100]BuildingElement = undefined;
    for (&elements, 0..) |*e, i| {
        e.* = .{
            .ifc_id = @intCast(i + 1),
            .name = "S",
            .element_type = .space,
            .parent_id = null,
            .position = .{ .x = 0, .y = 0, .z = 0 },
        };
    }
    // 100 spaces × 5 types = 500 sensors normally; cap at 20.
    var p = try place(testing.allocator, &elements, &.{}, .{ .max_total_sensors = 20 });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 20), p.sensors.len);
}
