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
