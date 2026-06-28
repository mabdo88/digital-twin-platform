// Zig 0.16.0 (tested against 0.17.0-dev)
//
// BIM-side ECS components — Phase 4.2.
//
// Per CLAUDE.md §3.3: parser output is converted into ECS components ONLY;
// there are no intermediate non-component data structures. These types are
// POD (no allocations inside them, no pointers to anything but arena-owned
// strings) so they can be moved between systems freely, copied into archetype
// storage later if needed, and serialised without ceremony.
//
// What lives here vs what lives in ifc_parser.zig:
//
//   ifc_parser.zig owns the LEX layer — Entity, ArgValue, the SPF reader.
//   Those are TRANSIENT, not components: they exist only during the parse
//   call and are dropped (or live behind ParsedModel's arena) once the
//   components below have been emitted.
//
//   This file owns the COMPONENT layer. Once you have a BuildingElement[]
//   plus a ZoneMetadata[], you no longer need the raw Entity map for any
//   downstream system (placement, queries, the report). The lexer types
//   are an implementation detail.

const std = @import("std");

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,
};

/// What kind of spatial element this is. Mirrors the supported subset of
/// IFC types (spec §7.1) plus `.other` as the explicit "we parsed it but
/// don't model it" tag.
pub const ElementType = enum {
    project,
    site,
    building,
    storey,
    space,
    wall,
    slab,
    beam,
    flow_segment,
    /// Generic MEP/electrical equipment family — IfcFlowTerminal,
    /// IfcFlowFitting, IfcFlowController, IfcFlowMovingDevice,
    /// IfcFlowStorageDevice, IfcEnergyConversionDevice,
    /// IfcDistributionControlElement, IfcBuildingElementProxy,
    /// IfcElectricAppliance, IfcAlarm, IfcCableCarrierSegment,
    /// IfcCableSegment. Added after validating against the two real Revit
    /// exports in assets/IFC/: one of them (2KHRJ17-HASC-SD-710-EV) has ZERO
    /// IfcSpace/IfcWall/IfcFlowSegment elements but hundreds of these types
    /// (100 IfcBuildingElementProxy, 33 IfcAlarm, 22 IfcElectricAppliance) —
    /// without this bucket that file's entire equipment inventory silently
    /// vanishes into `.other` and the sensor placer emits zero sensors on a
    /// real building. One coarse bucket (not one enum value per IFC type) to
    /// match this file's existing granularity (wall/slab/beam, not
    /// per-material variants).
    equipment,
    other,
};

/// What kind of zone this is — the subset of ElementType that participates
/// in zone-level queries (storey, space). Used to discriminate ZoneMetadata
/// rows from non-zone BuildingElement rows without re-parsing the type.
pub const ZoneType = enum {
    storey,
    space,
};

/// Every spatial entity that survives extraction becomes one of these.
/// Plain data: no pointers except into the owning ParsedModel arena.
pub const BuildingElement = struct {
    /// The original `#N` id from the IFC file. Stable identity across the
    /// pipeline; sensor placement, save/load, and report rows all reference it.
    ifc_id: u32,
    /// Human-readable name (IFC `Name` attribute). May be empty.
    name: []const u8,
    element_type: ElementType,
    /// Parent in the spatial hierarchy (from IfcRelAggregates or
    /// IfcRelContainedInSpatialStructure). `null` for roots — typically the
    /// IfcProject.
    parent_id: ?u32,
    /// World-space position resolved from the IfcLocalPlacement chain
    /// (sum of translations; rotations ignored, see ifc_parser.zig).
    position: Vec3,
};

/// Richer metadata for entities that act as zones — IfcBuildingStorey and
/// IfcSpace. Storeys carry elevation; spaces inherit the storey elevation
/// they're contained in (resolved by the extractor) and may later carry
/// floor area when we wire up IfcQuantitySet (currently 0 — see §7.1).
pub const ZoneMetadata = struct {
    /// Same `#N` id as the matching BuildingElement.ifc_id — this is a
    /// "sidecar" component, not a separate identity.
    zone_id: u32,
    name: []const u8,
    zone_type: ZoneType,
    /// Storey elevation in meters (IfcBuildingStorey.Elevation, arg index 9).
    /// For an IfcSpace, this is the elevation of the storey that contains it,
    /// resolved during extraction so consumers don't need to re-walk parents.
    /// Zero when the value is unset in the source file.
    floor_level: f64,
    /// Floor area in m². Currently always 0 — IfcQuantitySet / IfcElementQuantity
    /// extraction is deferred (will be documented in IFC_SUPPORT.md / Task 4.5).
    area_m2: f64,
};

// ---------------------------------------------------------------------------
// Sensor components (Phase 4.3 — emitted by sensor_placer.zig)
//
// SensorType is the SAME enum every storage backend already uses for
// SensorReading.sensor_type. Re-export so the BIM layer doesn't drag a
// second taxonomy in.
// ---------------------------------------------------------------------------

pub const SensorType = @import("../ecs/storage/storage_backend.zig").SensorType;

/// What a sensor IS — type, sample rate, and which IFC element it's pinned to.
/// Parallel to SensorReading: a real reading at runtime gets `sensor_type`
/// copied from here. `sensor_id` is dense and monotonic across the placement
/// (0..total_sensors-1) so it can index directly into storage backends.
pub const SensorMetadata = struct {
    sensor_id: u32,
    sensor_type: SensorType,
    /// Reporting frequency in Hz (per spec §7.3 defaults: occupancy 0.1 Hz,
    /// flow/temp 1.0, structural 10.0).
    frequency_hz: f32,
    /// `ifc_id` of the BuildingElement this sensor is attached to.
    element_id: u32,
};

/// Where a sensor IS — zone it belongs to + world position. Mirrors the
/// query-layer shape: spatial queries (Q9/Q10) read `position` and
/// `zone_id`. Stored as a sidecar so non-spatial queries can stay narrow.
pub const ZoneLocation = struct {
    sensor_id: u32,
    /// `zone_id` (= IFC id) of the containing zone — the host element's
    /// `ifc_id` if it's itself a zone (storey/space), else the host's
    /// `parent_id` if that's a zone, else 0 (no zone).
    zone_id: u32,
    position: Vec3,
};

/// Sidecar metadata for `.equipment`-typed BuildingElements, sourced from
/// IfcRelDefinesByProperties -> IfcPropertySet -> IfcPropertySingleValue
/// (see ifc_parser.zig's resolveHierarchy). Fields default to "" when the
/// source file carries no matching property — every `.equipment` element
/// gets one of these, never a missing/optional record (same "always emit,
/// default gracefully" rule ZoneMetadata.area_m2 already follows).
///
/// `age_days` / `efficiency` are NOT extracted: neither real fixture in
/// assets/IFC/ carries an install-date or efficiency-rating property under
/// any vendor PropertySet (verified by grepping both files' actual
/// IfcPropertySingleValue names — Manufacturer/Family and Type/Type Name
/// /Family Name show up; nothing age- or efficiency-shaped does). Both
/// fields are kept as named, always-zero placeholders rather than omitted,
/// so the moment a real source format is identified the shape doesn't
/// change, only the value.
pub const EquipmentMetadata = struct {
    /// `ifc_id` of the BuildingElement this metadata describes.
    element_id: u32,
    /// From a property literally named "Manufacturer". "" if absent.
    manufacturer: []const u8,
    /// From "Family and Type", else "Type Name", else "Family Name" (first
    /// match wins, in that priority order) — the closest real-world
    /// equivalent to a "model" string in Revit's IFC export. "" if none of
    /// the three properties are present.
    model: []const u8,
    /// Not extracted — see doc comment above. Always 0.
    age_days: f64 = 0,
    /// Not extracted — see doc comment above. Always 0.
    efficiency: f64 = 0,
};
