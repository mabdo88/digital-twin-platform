# Sensor Placement Strategy Overhaul — Research-Backed Plan

## 1. Research Summary

### 1.1 buildingSMART Repositories Reviewed

| Repository | What It Contains | Relevance to Sensor Placement |
|-----------|-----------------|-------------------------------|
| **Sample-Test-Files** | Official IFC test files (IFC2x3, IFC4, IFC4x3) | Confirmed: **zero IfcSensor entities** in any sample file. Sensors are implicit, not modeled in IFC. |
| **IFC4.x-IF** (Implementers Forum) | ~200+ real-world IFC files (bridges, rails, roads, buildings) | Infrastructure-focused. No IfcSensor entities. Confirms sensors are application-level, not schema-level. |
| **IFC5-development** | Next-gen IFC examples (`.ifcx`), Domestic Hot Water MEP example | MEP elements (IfcFlowSegment, IfcFlowMovingDevice, IfcPipeSegment) are modeled, but **no IfcSensor**. Sensors must be virtually placed. |
| **bSDD** (buildingSMART Data Dictionary) | Classification API and vocabulary | Provides component classification (e.g., "IfcSensor" class exists in bSDD with predefined types: TEMPERATURE, HUMIDITY, FLOW, etc.) but **no placement guidance**. |
| **ifc-gherkin-rules** | IFC validation rules (Gherkin/Behave format) | Rules cover geometry, spatial structure, properties, units — **no sensor-specific validation rules exist**. Confirms sensor placement is not standardized by IFC. |
| **IFC4** (schema docs) | IfcSensor entity definition | IfcSensor is a subtype of IfcDistributionControlElement. Predefined types: TEMPERATURE, HUMIDITY, PRESSURE, FLOW, etc. But schema defines **what** a sensor is, not **where** to place one. |

### 1.2 Real IFC Files Analyzed

| File | Source | Key Findings |
|------|--------|-------------|
| `bs-Hvac.ifc` | buildingSMART | IfcFlowSegment, IfcFlowFitting, IfcDuctSegment — no sensors |
| `bs-Plumbing.ifc` | buildingSMART | IfcPipeSegment, IfcFlowFitting — no sensors |
| `bs-Structural.ifc` | buildingSMART | IfcBeam, IfcColumn, IfcSlab — no sensors |
| `bs-Architecture.ifc` | buildingSMART | IfcSpace, IfcWall, IfcSlab — no sensors |
| `AC20-FZK-Haus.ifc` | buildingSMART | IfcSpace, IfcWall, IfcSlab, IfcBeam — no sensors |
| `Ifc2x3_Duplex_MEP.ifc` | buildingSMART | IfcFlowSegment, IfcFlowTerminal, IfcFlowFitting — no sensors |
| `Ifc4_Revit_MEP.ifc` | buildingSMART | IfcFlowSegment, IfcFlowTerminal, IfcFlowController — no sensors |
| `2KHRJ17-HASC-SD-710-EV.ifc` | Real Revit export | 0 spaces/walls/beams, 187 equipment (100 IfcBuildingElementProxy, 33 IfcAlarm, 22 IfcElectricAppliance) — no sensors |
| `2KHRJ17-CUN-TD-712-EL-MOD.ifc` | Real Revit export | Electrical equipment, alarms — no sensors |
| `Domestic Hot Water (IFC5)` | buildingSMART IFC5-dev | IfcFlowSegment, IfcPipeSegment, IfcFlowMovingDevice — no sensors |
| `LargeHospitalComplex.ifc` | Synthetic (generated) | 5 buildings × 8 storeys × 49 elements = ~1,960 spatial entities |

**Conclusion**: Real IFC files **never** contain explicit `IfcSensor` entities. Sensors are always virtually placed by the digital twin application. The IFC schema defines `IfcSensor` as a concept but provides **no placement guidance**. Placement strategy must be derived from BMS industry practices.

### 1.3 Industry Standards & Best Practices Researched

| Standard/Practice | Source | Key Insight |
|-------------------|--------|-------------|
| **ASHRAE 62.1** (Ventilation for Acceptable IAQ) | ASHRAE | Requires CO2 monitoring in densely occupied spaces (demand-controlled ventilation) |
| **WELL Building Standard** | IWBI | Requires air quality monitoring (CO2, PM2.5, VOCs) in all occupied spaces; 3-year data retention |
| **BACnet/KNX practice** | Industry | One thermostat per zone (IfcSpace); CO2 sensors in meeting rooms, classrooms, densely occupied areas |
| **AMI/smart metering** | IEC 62056 / OpenADR | 15-minute interval energy metering; one meter per circuit/load, not per piece of equipment |
| **Structural Health Monitoring (SHM)** | ISHMII, FIB | Strain gauges on critical structural elements (beams, columns, base slabs); 1-15 min sampling for static monitoring |
| **Condition monitoring (vibration)** | ISO 10816, ISO 20816 | Vibration sensors on rotating equipment only (pumps, fans, motors, compressors); NOT on static equipment, alarms, or fittings |
| **HVAC flow monitoring** | ASHRAE 111 | Flow sensors on main ducts/pipes and equipment inlets/outlets, NOT on every branch segment |

---

## 2. Problems with Current Placement Strategy

### 2.1 Missing Sensor Types
- **CO2** (`SensorType.co2`) — defined in `storage_backend.zig`, profiled in `generator.zig`, but **never placed** by any rule in `sensor_placer.zig`
- **Air quality** (`SensorType.air_quality`) — same: defined, profiled, but **never placed**

### 2.2 Equipment Bucket Too Coarse
The `ElementType.equipment` bucket lumps together fundamentally different equipment:
- **Rotating equipment** (pumps, fans) — needs vibration + flow monitoring
- **HVAC terminals** (AHUs, FCUs) — needs flow + temperature monitoring
- **Electrical equipment** (meters, panels) — needs energy monitoring only
- **Alarms** (fire/smoke detectors) — ARE sensors themselves; placing virtual sensors on them is nonsensical
- **Fittings** (duct elbows, pipe tees) — don't need individual monitoring
- **Building element proxies** (generic BIM objects) — context-dependent

Current rule gives ALL equipment `energy + vibration`, which means:
- Fire alarms get vibration sensors (meaningless)
- Duct fittings get energy meters (meaningless)
- Pumps don't get flow sensors (missing critical data)

### 2.3 Flow Segment Over-Placement
Current: `flow_segment → flow + temperature` with density 1.5/100m² for flow.
With default area 100m²: `round(100 * 1.5 / 100) = 2` flow sensors per segment.
A large building with 160 flow segments → 320 flow sensors + 160 temperature sensors = 480 sensors just for ducts.
Real BMS: flow sensors go on **main** ducts and equipment inlets/outlets, not every branch.
**Fix**: Remove the `flow_segment` rule entirely. Flow + temperature sensors
are placed on equipment (`flow_moving_device`, `flow_terminal`, `flow_controller`)
which represent the actual monitoring points — equipment inlets/outlets.

### 2.4 OOM Risk from Total Sensor Count
For `LargeHospitalComplex.ifc` (5 buildings × 8 storeys):
- 480 spaces × 3 sensors = 1,440 (current)
- 160 flow segments × 3 sensors = 480
- 80 beams × 1 sensor = 80
- 600 equipment × 2 sensors = 1,200
- **Total: ~3,200 sensors** (current, with only 4 sensor types placed)

The real OOM risk is in **data volume** from total sensor count × retention × frequency.

---

## 3. Proposed Refined Placement Strategy

### 3.1 New ElementType Sub-Types

Add granular equipment sub-types to `ElementType` in `components.zig`:

```zig
pub const ElementType = enum {
    project, site, building, storey, space,
    wall, slab, beam, flow_segment,
    // NEW: Equipment sub-types (replacing single `equipment`)
    flow_moving_device,    // IfcFlowMovingDevice (pumps, fans, compressors)
    flow_terminal,         // IfcFlowTerminal (AHUs, FCUs, diffusers)
    flow_controller,       // IfcFlowController (dampers, valves)
    flow_fitting,          // IfcFlowFitting (duct elbows, pipe tees)
    flow_storage_device,   // IfcFlowStorageDevice (tanks, reservoirs)
    energy_conversion_device, // IfcEnergyConversionDevice (boilers, chillers, heat exchangers)
    alarm,                 // IfcAlarm (fire/smoke/security detectors)
    electric_appliance,    // IfcElectricAppliance (meters, panels, breakers)
    distribution_control_element, // IfcDistributionControlElement (BMS controllers, sensors)
    building_element_proxy, // IfcBuildingElementProxy (generic)
    cable_segment,         // IfcCableSegment, IfcCableCarrierSegment
    other,
};
```

### 3.2 Updated IFC Parser Mapping

`ifc_parser.zig` — map each IFC type to its granular ElementType:

| IFC Entity | Current ElementType | New ElementType |
|-----------|-------------------|----------------|
| IfcFlowMovingDevice | equipment | flow_moving_device |
| IfcFlowTerminal | equipment | flow_terminal |
| IfcFlowController | equipment | flow_controller |
| IfcFlowFitting | equipment | flow_fitting |
| IfcFlowStorageDevice | equipment | flow_storage_device |
| IfcEnergyConversionDevice | equipment | energy_conversion_device |
| IfcAlarm | equipment | alarm |
| IfcElectricAppliance | equipment | electric_appliance |
| IfcDistributionControlElement | equipment | distribution_control_element |
| IfcBuildingElementProxy | equipment | building_element_proxy |
| IfcCableCarrierSegment | equipment | cable_segment |
| IfcCableSegment | equipment | cable_segment |

### 3.3 New Placement Rules

```zig
pub const DEFAULT_RULES = [_]PlacementRule{
    // Zone-level comfort & IAQ sensors — placed on every IfcSpace.
    // Known limitation: ASHRAE 62.1 requires CO2 in "densely occupied
    // spaces" and WELL requires air quality in "occupied spaces" —
    // storage rooms, electrical rooms, and corridors are not occupied
    // in the IAQ sense. Without IfcSpace occupancy classification
    // (not available in IFC4), we cannot filter. This is a known
    // over-placement on non-occupied spaces.
    .{ .element_type = .space, .max_per_type = 3,
       .sensor_types = &.{ .temperature, .humidity, .occupancy, .co2, .air_quality } },

    // NO flow_segment rule — flow/temperature sensors go on equipment
    // (flow_moving_device, flow_terminal, flow_controller), not on every
    // duct/pipe segment. Real BMS monitors at equipment inlets/outlets,
    // not at every branch segment (ASHRAE 111).

    // Structural health monitoring — beams only
    .{ .element_type = .beam,
       .sensor_types = &.{.structural} },

    // Rotating equipment — vibration + flow + temperature (condition monitoring)
    .{ .element_type = .flow_moving_device,
       .sensor_types = &.{ .vibration, .flow, .temperature } },

    // HVAC terminals — flow + temperature (airflow/temp at AHU/FCU)
    .{ .element_type = .flow_terminal,
       .sensor_types = &.{ .flow, .temperature } },

    // Flow controllers — flow (airflow/fluid flow through VAV boxes,
    // dampers, valves — NOT position, which is a control signal not a
    // sensor reading)
    .{ .element_type = .flow_controller,
       .sensor_types = &.{.flow} },

    // Energy conversion devices — energy only (boilers, chillers, heat
    // exchangers). Vibration excluded: heat exchangers have no rotating
    // parts, and ISO 10816 restricts vibration to rotating equipment.
    // Boilers/chillers DO have internal rotating components, but we
    // cannot distinguish them from heat exchangers within this IFC type.
    .{ .element_type = .energy_conversion_device,
       .sensor_types = &.{.energy} },

    // Electrical appliances — energy only (meters, panels)
    .{ .element_type = .electric_appliance,
       .sensor_types = &.{.energy} },

    // Flow storage devices — temperature (tanks)
    .{ .element_type = .flow_storage_device,
       .sensor_types = &.{.temperature} },

    // Building element proxies — NO RULE (skipped). These are generic
    // BIM objects (furniture, signs, non-MEP elements). Placing sensors
    // on them is the same blind catch-all problem as the original
    // `equipment` bucket. The real Revit file has 100 IfcBuildingElementProxy
    // instances — placing energy+vibration on all would add 200 sensors
    // on unknown objects. If a proxy IS equipment, it should be classified
    // as such in the IFC file, not guessed at placement time.

    // Distribution control elements — no virtual sensors (these ARE controllers/sensors)
    // alarm, flow_fitting, cable_segment, distribution_control_element,
    // building_element_proxy → NO RULE (skipped)
};
```

### 3.4 Sensor Count Caps (OOM Mitigation)

Add a `max_sensors_per_element` field to `PlacementRule`:

```zig
pub const PlacementRule = struct {
    element_type: ElementType,
    sensor_types: []const SensorType,
    /// Hard cap: maximum sensors of each type on a single element.
    /// Default 1 — equipment gets exactly 1 of each sensor type, regardless
    /// of density math. Spaces can have more (large rooms may get 2-3 thermostats).
    max_per_type: u32 = 1,
};
```

- Space rule: `max_per_type = 3` — allows up to 3 temperature/humidity sensors
  in large spaces (zone control). In practice, CO2/occupancy/air_quality density
  is 0.5/100m² so they cap at 1 for typical rooms and 2-3 only for very large
  spaces (500m²+). This is acceptable — a large open office may have multiple
  CO2/occupancy sensors.
- All equipment rules: `max_per_type = 1` (one sensor per type per equipment).
  Note: for equipment, the density formula `eff_area * density / 100` is
  effectively bypassed — equipment has no floor area, so `default_unknown_area_m2`
  (100m²) is a meaningless proxy. `max_per_type = 1` ensures the formula result
  is always clamped to 1 regardless. This is intentional: equipment sensor count
  should be 1 per type, not area-scaled.

Add a global cap in `PlacementConfig`:

```zig
pub const PlacementConfig = struct {
    rules: []const PlacementRule = &DEFAULT_RULES,
    default_unknown_area_m2: f64 = 100.0,
    /// Hard stop: if total sensor count would exceed this, stop placing.
    /// Prevents OOM on extremely large buildings. Default 50,000.
    max_total_sensors: u32 = 50_000,
};
```

### 3.5 Density Adjustments in `generator.zig`

The density-based count calculation in `place()` currently does:
```
count = max(1, round(eff_area * density_per_100m2 / 100))
```

With `max_per_type` cap:
```
count = min(max_per_type, max(1, round(eff_area * density_per_100m2 / 100)))
```

This means:
- Space (100m², density 1.0): `min(3, max(1, round(1.0))) = 1` per sensor type
- Space (500m², density 1.0): `min(3, max(1, round(5.0))) = 3` per sensor type
- Equipment (100m², density 0.5): `min(1, max(1, round(0.5))) = 1` per sensor type

### 3.6 Expected Sensor Counts for LargeHospitalComplex.ifc

| Element Type | Count | Sensors/Element | Total Sensors |
|-------------|-------|----------------|--------------|
| Space | 480 | 5 (temp+hum+occ+co2+aq) | 2,400 |
| FlowSegment | 160 | 0 (NO RULE — removed) | 0 |
| Beam | 80 | 1 (structural) | 80 |
| FlowMovingDevice | 120 | 3 (vib+flow+temp) | 360 |
| FlowTerminal | 240 | 2 (flow+temp) | 480 |
| FlowController | 160 | 1 (flow) | 160 |
| EnergyConversionDevice | 0 | 1 (energy) | 0 |
| ElectricAppliance | 120 | 1 (energy) | 120 |
| FlowStorageDevice | 0 | 1 | 0 |
| BuildingElementProxy | 0 | 0 (NO RULE — skipped) | 0 |
| Alarm | 120 | 0 (skipped) | 0 |
| FlowFitting | 0 | 0 (skipped) | 0 |
| **Total** | | | **~3,600** |

Compare to current: ~3,200 sensors (4 sensor types only, sensors on every flow segment).
The new total is ~3,600 with **all 9 sensor types placed**, **zero sensors on flow segments**,
and **zero sensors on building element proxies**. Flow/temperature monitoring moved to
equipment level where it belongs.

### 3.7 Known Limitations (Acknowledged Over-Placement)

| Issue | Why | Mitigation |
|-------|-----|------------|
| CO2/air_quality on ALL spaces (including storage/electrical) | No IfcSpace occupancy classification in IFC4 | Acknowledged; would need property-set analysis to filter |
| Structural sensors on ALL beams | SHM literature says "critical" elements only | No criticality flag in IFC; max_per_type=1 limits to 1 per beam |
| Energy conversion devices get energy but not vibration | Can't distinguish boilers (rotating) from heat exchangers (static) | Conservative: energy-only avoids meaningless vibration on heat exchangers |

---

## 4. Implementation Plan

### Phase 1: ElementType Refactoring
1. **`components.zig`**: Replace `equipment` with 10 granular sub-types
2. **`ifc_parser.zig`**: Update `elementTypeFromName()` to map each IFC type to its granular ElementType
3. **`sensor_placer.zig`**: Update `DEFAULT_RULES` with new rules per sub-type
4. **`components.zig`**: Update `ZoneType` and `EquipmentMetadata` references

### Phase 2: Placement Caps
5. **`sensor_placer.zig`**: Add `max_per_type` to `PlacementRule`
6. **`sensor_placer.zig`**: Add `max_total_sensors` to `PlacementConfig`
7. **`sensor_placer.zig`**: Update `place()` to apply caps

### Phase 3: Missing Sensor Types
8. **`sensor_placer.zig`**: Add CO2 and air_quality to space rule (already covered in new rules above)

### Phase 4: Test Updates
9. Update existing tests in `sensor_placer.zig` to reflect new rules and element types
10. Add test for CO2/air_quality placement on spaces
11. Add test for granular equipment sub-type placement
12. Add test for `max_per_type` cap behavior
13. Add test for `max_total_sensors` hard stop

### Phase 5: Synthetic Generator Alignment
14. **`generate_large_ifc.py`**: No changes needed — already emits granular IFC types (IfcFlowTerminal, IfcFlowController, IfcFlowMovingDevice, IfcAlarm, IfcElectricAppliance) that the parser will now map to distinct ElementTypes

---

## 5. Research Citations

- **buildingSMART Sample-Test-Files**: `https://github.com/buildingSMART/Sample-Test-Files` — no IfcSensor in any file
- **buildingSMART IFC4.x-IF**: `https://github.com/buildingSMART/IFC4.x-IF` — infrastructure IFC files, no sensors
- **buildingSMART IFC5-development**: `https://github.com/buildingSMART/IFC5-development` — Domestic Hot Water example, no sensors
- **buildingSMART bSDD**: `https://github.com/buildingSMART/bSDD` — data dictionary, IfcSensor class exists but no placement guidance
- **buildingSMART ifc-gherkin-rules**: `https://github.com/buildingSMART/ifc-gherkin-rules` — validation rules, no sensor-specific rules
- **IFC4 schema**: IfcSensor subtype of IfcDistributionControlElement, PredefinedType enum includes TEMPERATURE/HUMIDITY/PRESSURE/FLOW/etc.
- **ASHRAE 62.1**: Ventilation for Acceptable IAQ — CO2 monitoring in densely occupied spaces
- **WELL Building Standard**: Air quality monitoring requirements, 3-year retention
- **ISO 10816/20816**: Vibration condition monitoring on rotating machinery
- **ASHRAE 111**: HVAC flow measurement on main ducts and equipment
- **IEC 62056**: AMI/smart metering 15-minute interval standard
