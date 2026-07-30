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
        const is_equipment = components.isEquipment(elem.element_type);
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
// Tests — this file had none until 2026-07-20, despite owning all the
// data-driven placement-cap logic CLAUDE.md's "placement rules must be data"
// principle depends on (max_per_type, max_total_sensors,
// default_unknown_area_m2). A regression here would silently over- or
// under-place sensors with no test to catch it.
// ---------------------------------------------------------------------------

const testing = std.testing;
const zero_vec = Vec3{ .x = 0, .y = 0, .z = 0 };

test "place: max_per_type caps a single sensor type across many elements, never exceeds it" {
    const allocator = testing.allocator;

    // 50 spaces, each with a 500m2 zone (temperature density 1.0/100m2 ->
    // round(500*1.0/100) = 5 temperature sensors per space, 250 total) —
    // comfortably over a deliberately small cap of 12.
    var elements: [50]BuildingElement = undefined;
    var zones: [50]ZoneMetadata = undefined;
    for (0..50) |i| {
        const id: u32 = @intCast(i + 1);
        elements[i] = .{ .ifc_id = id, .name = "", .element_type = .space, .parent_id = null, .position = zero_vec };
        zones[i] = .{ .zone_id = id, .name = "", .zone_type = .space, .floor_level = 0, .area_m2 = 500 };
    }

    var placement = try place(allocator, &elements, &zones, .{ .max_per_type = 12, .max_total_sensors = 10_000 });
    defer placement.deinit();

    var temp_count: u32 = 0;
    for (placement.sensors) |s| {
        if (s.sensor_type == .temperature) temp_count += 1;
    }
    try testing.expectEqual(@as(u32, 12), temp_count);
}

test "place: max_total_sensors is a hard ceiling across all types combined, and stops placement outright" {
    const allocator = testing.allocator;

    // 20 spaces, each placing 5 sensor types (temperature, humidity,
    // occupancy, co2, air_quality) at a 100m2 default area -> 1 of each
    // per space, 5 per space, 100 total if uncapped. Cap at 7 total.
    var elements: [20]BuildingElement = undefined;
    for (0..20) |i| {
        elements[i] = .{ .ifc_id = @intCast(i + 1), .name = "", .element_type = .space, .parent_id = null, .position = zero_vec };
    }

    var placement = try place(allocator, &elements, &.{}, .{ .max_total_sensors = 7 });
    defer placement.deinit();

    try testing.expectEqual(@as(usize, 7), placement.sensors.len);
    try testing.expectEqual(@as(usize, 7), placement.locations.len);
}

test "place: unknown or zero-area zone falls back to default_unknown_area_m2; a known area is used directly" {
    const allocator = testing.allocator;

    // Element 1's zone has a real, large area (400m2 -> round(400*1/100)=4
    // temperature sensors). Element 2 has no matching ZoneMetadata at all
    // (area_of.get returns null) -> falls back to a custom
    // default_unknown_area_m2 of 300 -> round(300*1/100)=3.
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "", .element_type = .space, .parent_id = null, .position = zero_vec },
        .{ .ifc_id = 2, .name = "", .element_type = .space, .parent_id = null, .position = zero_vec },
    };
    const zones = [_]ZoneMetadata{
        .{ .zone_id = 1, .name = "", .zone_type = .space, .floor_level = 0, .area_m2 = 400 },
        // No entry for zone_id = 2 — its area is unknown.
    };

    var placement = try place(allocator, &elements, &zones, .{ .default_unknown_area_m2 = 300 });
    defer placement.deinit();

    var temp_by_element = [_]u32{ 0, 0 };
    for (placement.sensors) |s| {
        if (s.sensor_type == .temperature) temp_by_element[s.element_id - 1] += 1;
    }
    try testing.expectEqual(@as(u32, 4), temp_by_element[0]);
    try testing.expectEqual(@as(u32, 3), temp_by_element[1]);
}

test "place: equipment elements get exactly 1 sensor per rule type regardless of zone area — never area-scaled" {
    const allocator = testing.allocator;

    // flow_moving_device (pump) sitting in a zone with a huge area — if
    // equipment were mistakenly area-scaled like a space, this would place
    // far more than 1 of each rule sensor type (vibration, flow).
    const elements = [_]BuildingElement{
        .{ .ifc_id = 1, .name = "", .element_type = .space, .parent_id = null, .position = zero_vec },
        .{ .ifc_id = 2, .name = "", .element_type = .flow_moving_device, .parent_id = 1, .position = zero_vec },
    };
    const zones = [_]ZoneMetadata{
        .{ .zone_id = 1, .name = "", .zone_type = .space, .floor_level = 0, .area_m2 = 50_000 },
    };

    var placement = try place(allocator, &elements, &zones, .{});
    defer placement.deinit();

    var vibration_count: u32 = 0;
    var flow_count: u32 = 0;
    for (placement.sensors) |s| {
        if (s.element_id != 2) continue;
        if (s.sensor_type == .vibration) vibration_count += 1;
        if (s.sensor_type == .flow) flow_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), vibration_count);
    try testing.expectEqual(@as(u32, 1), flow_count);
}

test "place: containing_zone resolves to self for zone elements, to a known parent zone, or to 0 when unresolved" {
    const allocator = testing.allocator;

    const elements = [_]BuildingElement{
        // A space IS its own zone.
        .{ .ifc_id = 1, .name = "", .element_type = .space, .parent_id = null, .position = zero_vec },
        // A beam whose parent_id points at a known zone.
        .{ .ifc_id = 2, .name = "", .element_type = .beam, .parent_id = 1, .position = zero_vec },
        // A beam whose parent_id points at nothing registered as a zone.
        .{ .ifc_id = 3, .name = "", .element_type = .beam, .parent_id = 999, .position = zero_vec },
    };
    const zones = [_]ZoneMetadata{
        .{ .zone_id = 1, .name = "", .zone_type = .space, .floor_level = 0, .area_m2 = 100 },
    };

    var placement = try place(allocator, &elements, &zones, .{});
    defer placement.deinit();

    var zone_of_element = [_]?u32{ null, null, null };
    for (placement.locations) |loc| {
        // Sensors are appended in element-iteration order and locations
        // mirror sensors 1:1, so find each element's first sensor's location
        // via placement.sensors to map sensor_id -> element_id -> zone_id.
        for (placement.sensors) |s| {
            if (s.sensor_id != loc.sensor_id) continue;
            const idx = s.element_id - 1;
            if (zone_of_element[idx] == null) zone_of_element[idx] = loc.zone_id;
        }
    }
    try testing.expectEqual(@as(?u32, 1), zone_of_element[0]); // space -> self
    try testing.expectEqual(@as(?u32, 1), zone_of_element[1]); // beam -> known parent
    try testing.expectEqual(@as(?u32, 0), zone_of_element[2]); // beam -> unresolved parent
}

// ---------------------------------------------------------------------------
