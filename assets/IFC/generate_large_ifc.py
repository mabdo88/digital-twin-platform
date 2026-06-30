"""
Generate a large, realistic IFC4 file for the digital-twin-platform benchmarking engine.

Produces: LargeHospitalComplex.ifc
Structure:
  - 1 IfcProject
  - 1 IfcSite
  - 3 IfcBuilding  (Block A, B, C)
    Each building:
      - 8 IfcBuildingStorey  (Ground + 7 upper floors)
      Each storey:
        - 12 IfcSpace
        - 8  IfcWall
        - 4  IfcSlab
        - 2  IfcBeam
        - 4  IfcFlowSegment    (ductwork / pipework)
        - 6  IfcFlowTerminal   (air handling units, fan coil units)
        - 4  IfcFlowController (dampers, valves)
        - 3  IfcFlowMovingDevice (pumps, fans)
        - 3  IfcAlarm
        - 3  IfcElectricAppliance

Total entities (rough):
  3 buildings × 8 storeys × (12+8+4+2+4+6+4+3+3+3) = 3×8×49 = 1 176 spatial entities
  + placements + property sets + relations → ~10 000+ STEP records
"""

import math
import uuid
import sys

# ---------------------------------------------------------------------------
# ID counter
# ---------------------------------------------------------------------------
_next_id = 200  # start after the header block (1..199 reserved for header)

def nid() -> int:
    global _next_id
    v = _next_id
    _next_id += 1
    return v

def guid() -> str:
    """22-char IFC compressed GUID (base64-like, deterministic via uuid4 hex)."""
    raw = uuid.uuid4().hex  # 32 hex chars
    # We don't need true IFC base64 compression — the parser accepts any string literal.
    return raw[:22]

# ---------------------------------------------------------------------------
# Line buffer
# ---------------------------------------------------------------------------
lines: list[str] = []

def emit(line: str):
    lines.append(line)

# ---------------------------------------------------------------------------
# Primitive helpers
# ---------------------------------------------------------------------------

def pt(x: float, y: float, z: float = 0.0) -> int:
    i = nid()
    emit(f"#{i}=IFCCARTESIANPOINT(({x:.3f},{y:.3f},{z:.3f}));")
    return i

def pt2d(x: float, y: float) -> int:
    i = nid()
    emit(f"#{i}=IFCCARTESIANPOINT(({x:.3f},{y:.3f}));")
    return i

DIR_Z = None  # populated in header
DIR_X = None

def dir3(x: float, y: float, z: float) -> int:
    i = nid()
    emit(f"#{i}=IFCDIRECTION(({x:.3f},{y:.3f},{z:.3f}));")
    return i

def axis2p3d(origin_id: int, z_id: int = None, x_id: int = None) -> int:
    i = nid()
    z_str = f"#{z_id}" if z_id else "$"
    x_str = f"#{x_id}" if x_id else "$"
    emit(f"#{i}=IFCAXIS2PLACEMENT3D(#{origin_id},{z_str},{x_str});")
    return i

def local_placement(parent_placement_id, axis_id: int) -> int:
    i = nid()
    parent = f"#{parent_placement_id}" if parent_placement_id else "$"
    emit(f"#{i}=IFCLOCALPLACEMENT({parent},#{axis_id});")
    return i

def owner_history_id() -> int:
    return _owner_history

# ---------------------------------------------------------------------------
# Spatial element emitters
# ---------------------------------------------------------------------------

def emit_space(name: str, placement_id: int, storey_placement_id: int) -> int:
    g = guid()
    i = nid()
    pl_origin = pt(0, 0, 0)
    pl_axis = axis2p3d(pl_origin)
    pl = local_placement(placement_id, pl_axis)
    emit(f"#{i}=IFCSPACE('{g}',#{owner_history_id()},'{name}',$,'Space',#{pl},$,'{name}',.ELEMENT.,.INTERNAL.,0.);")
    return i

def emit_wall(name: str, placement_id: int) -> int:
    g = guid()
    i = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{i}=IFCWALL('{g}',#{owner_history_id()},'{name}',$,'Wall',#{pl},$,$,$);")
    return i

def emit_slab(name: str, placement_id: int) -> int:
    g = guid()
    i = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{i}=IFCSLAB('{g}',#{owner_history_id()},'{name}',$,'Slab',#{pl},$,$,.FLOOR.);")
    return i

def emit_beam(name: str, placement_id: int) -> int:
    g = guid()
    i = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{i}=IFCBEAM('{g}',#{owner_history_id()},'{name}',$,'Beam',#{pl},$,$,$);")
    return i

def emit_flow_segment(name: str, placement_id: int) -> int:
    g = guid()
    i = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{i}=IFCFLOWSEGMENT('{g}',#{owner_history_id()},'{name}',$,'Duct',#{pl},$,$,$);")
    return i

def emit_flow_terminal(name: str, placement_id: int, model: str = "AHU-1200") -> int:
    g = guid()
    elem_id = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{elem_id}=IFCFLOWTERMINAL('{g}',#{owner_history_id()},'{name}',$,'Terminal',#{pl},$,$,$);")
    # Property set: Manufacturer + Family and Type
    mfr_pv = nid(); emit(f"#{mfr_pv}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Carrier'),$);")
    typ_pv = nid(); emit(f"#{typ_pv}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{model}'),$);")
    pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#{owner_history_id()},'Pset_DistributionElement',$,(#{mfr_pv},#{typ_pv}));")
    rel = nid(); emit(f"#{rel}=IFCRELDEFINESBYPROPERTIES('{guid()}',#{owner_history_id()},$,$,(#{elem_id}),#{pset});")
    return elem_id

def emit_flow_controller(name: str, placement_id: int, model: str = "VAV-Box") -> int:
    g = guid()
    elem_id = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{elem_id}=IFCFLOWCONTROLLER('{g}',#{owner_history_id()},'{name}',$,'Controller',#{pl},$,$,$);")
    mfr_pv = nid(); emit(f"#{mfr_pv}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Siemens'),$);")
    typ_pv = nid(); emit(f"#{typ_pv}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{model}'),$);")
    pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#{owner_history_id()},'Pset_DistributionElement',$,(#{mfr_pv},#{typ_pv}));")
    rel = nid(); emit(f"#{rel}=IFCRELDEFINESBYPROPERTIES('{guid()}',#{owner_history_id()},$,$,(#{elem_id}),#{pset});")
    return elem_id

def emit_flow_moving(name: str, placement_id: int, model: str = "Pump-1500") -> int:
    g = guid()
    elem_id = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{elem_id}=IFCFLOWMOVINGDEVICE('{g}',#{owner_history_id()},'{name}',$,'Pump',#{pl},$,$,$);")
    mfr_pv = nid(); emit(f"#{mfr_pv}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Grundfos'),$);")
    typ_pv = nid(); emit(f"#{typ_pv}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{model}'),$);")
    pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#{owner_history_id()},'Pset_DistributionElement',$,(#{mfr_pv},#{typ_pv}));")
    rel = nid(); emit(f"#{rel}=IFCRELDEFINESBYPROPERTIES('{guid()}',#{owner_history_id()},$,$,(#{elem_id}),#{pset});")
    return elem_id

def emit_alarm(name: str, placement_id: int) -> int:
    g = guid()
    elem_id = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{elem_id}=IFCALARM('{g}',#{owner_history_id()},'{name}',$,'Alarm',#{pl},$,$,$);")
    mfr_pv = nid(); emit(f"#{mfr_pv}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Honeywell'),$);")
    typ_pv = nid(); emit(f"#{typ_pv}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('F-200-FireAlarm'),$);")
    pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#{owner_history_id()},'Pset_AlarmCommon',$,(#{mfr_pv},#{typ_pv}));")
    rel = nid(); emit(f"#{rel}=IFCRELDEFINESBYPROPERTIES('{guid()}',#{owner_history_id()},$,$,(#{elem_id}),#{pset});")
    return elem_id

def emit_electric_appliance(name: str, placement_id: int) -> int:
    g = guid()
    elem_id = nid()
    ox = nid(); emit(f"#{ox}=IFCCARTESIANPOINT((0.,0.,0.));")
    ax = nid(); emit(f"#{ax}=IFCAXIS2PLACEMENT3D(#{ox},$,$);")
    pl = nid(); emit(f"#{pl}=IFCLOCALPLACEMENT(#{placement_id},#{ax});")
    emit(f"#{elem_id}=IFCELECTRICAPPLIANCE('{g}',#{owner_history_id()},'{name}',$,'Appliance',#{pl},$,$,$);")
    mfr_pv = nid(); emit(f"#{mfr_pv}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Schneider'),$);")
    typ_pv = nid(); emit(f"#{typ_pv}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('PowerMeter-PM5350'),$);")
    pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#{owner_history_id()},'Pset_ElectricApplianceCommon',$,(#{mfr_pv},#{typ_pv}));")
    rel = nid(); emit(f"#{rel}=IFCRELDEFINESBYPROPERTIES('{guid()}',#{owner_history_id()},$,$,(#{elem_id}),#{pset});")
    return elem_id

# ---------------------------------------------------------------------------
# Relation helpers
# ---------------------------------------------------------------------------

def rel_aggregates(parent_id: int, children: list[int]) -> int:
    i = nid()
    children_str = ",".join(f"#{c}" for c in children)
    emit(f"#{i}=IFCRELAGGREGATES('{guid()}',#{owner_history_id()},$,$,#{parent_id},({children_str}));")
    return i

def rel_contained(storey_id: int, elements: list[int]) -> int:
    i = nid()
    elements_str = ",".join(f"#{e}" for e in elements)
    emit(f"#{i}=IFCRELCONTAINEDINSPATIALSTRUCTURE('{guid()}',#{owner_history_id()},$,$,({elements_str}),#{storey_id});")
    return i

# ---------------------------------------------------------------------------
# Header block
# ---------------------------------------------------------------------------

HEADER = """\
ISO-10303-21;
HEADER;
FILE_DESCRIPTION(('ViewDefinition [CoordinationView_V2.0]'),'2;1');
FILE_NAME('LargeHospitalComplex.ifc','2026-06-29T12:00:00',(''),(''),(\'The EXPRESS Data Manager\'),'Generated for digital-twin-platform benchmark','');
FILE_SCHEMA(('IFC4'));
ENDSEC;

DATA;"""

# ---------------------------------------------------------------------------
# Fixed low-numbered header entities (1..199)
# ---------------------------------------------------------------------------

def emit_header_entities() -> int:
    """Emit owner/history/units block. Returns the owner_history entity id."""
    global _next_id
    _next_id = 1  # reset to fill in header

    emit("#1=IFCORGANIZATION($,'Hospital BIM Group',$,$,$);")
    emit("#2=IFCAPPLICATION(#1,'1.0','DigitalTwinGen','dt-gen');")
    emit("#3=IFCCARTESIANPOINT((0.,0.,0.));")
    emit("#4=IFCDIRECTION((0.,0.,1.));")
    emit("#5=IFCDIRECTION((1.,0.,0.));")
    emit("#6=IFCDIRECTION((0.,1.,0.));")
    emit("#7=IFCPERSON($,'BIM Manager',$,$,$,$,$,$);")
    emit("#8=IFCPERSONANDORGANIZATION(#7,#1,$);")
    emit("#9=IFCOWNERHISTORY(#8,#2,$,.ADDED.,1751200800,#8,#2,1751200800);")
    # SI units
    emit("#10=IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.);")
    emit("#11=IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.);")
    emit("#12=IFCSIUNIT(*,.VOLUMEUNIT.,$,.CUBIC_METRE.);")
    emit("#13=IFCSIUNIT(*,.PLANEANGLEUNIT.,$,.RADIAN.);")
    emit("#14=IFCSIUNIT(*,.TIMEUNIT.,$,.SECOND.);")
    emit("#15=IFCSIUNIT(*,.MASSUNIT.,.KILO.,.GRAM.);")
    emit("#16=IFCSIUNIT(*,.THERMODYNAMICTEMPERATUREUNIT.,$,.DEGREE_CELSIUS.);")
    emit("#17=IFCSIUNIT(*,.POWERUNIT.,$,.WATT.);")
    emit("#18=IFCSIUNIT(*,.FREQUENCYUNIT.,$,.HERTZ.);")
    emit("#19=IFCUNITASSIGNMENT((#10,#11,#12,#13,#14,#15,#16,#17,#18));")
    # Geometric context
    emit("#20=IFCAXIS2PLACEMENT3D(#3,#4,#5);")
    emit("#21=IFCDIRECTION((1.,0.));")
    emit("#22=IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,0.001,#20,#21);")
    emit("#23=IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Body','Model',*,*,*,*,#22,$,.MODEL_VIEW.,$);")
    emit("#24=IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Axis','Model',*,*,*,*,#22,$,.GRAPH_VIEW.,$);")
    emit("#25=IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Box','Model',*,*,*,*,#22,$,.MODEL_VIEW.,$);")

    _next_id = 200  # jump past reserved range
    return 9  # owner_history is #9

# ---------------------------------------------------------------------------
# Main generator
# ---------------------------------------------------------------------------

BUILDINGS = [
    {"name": "Block A - Inpatient Tower",    "offset_x": 0.0,    "offset_y": 0.0},
    {"name": "Block B - Outpatient Clinic",  "offset_x": 120.0,  "offset_y": 0.0},
    {"name": "Block C - Emergency & ICU",    "offset_x": 240.0,  "offset_y": 0.0},
    {"name": "Block D - Surgical Center",    "offset_x": 0.0,    "offset_y": 100.0},
    {"name": "Block E - Diagnostics",        "offset_x": 120.0,  "offset_y": 100.0},
]

FLOORS_PER_BUILDING = 8
FLOOR_HEIGHT = 4.2  # metres

SPACE_NAMES = [
    "Reception", "Corridor-A", "Corridor-B", "Nurse Station",
    "Patient Room 01", "Patient Room 02", "Patient Room 03", "Patient Room 04",
    "Treatment Room", "Staff Lounge", "Storage Room", "Electrical Room",
]

WALL_NAMES   = [f"Wall-{i+1:02d}" for i in range(8)]
SLAB_NAMES   = [f"Slab-{i+1:02d}" for i in range(4)]
BEAM_NAMES   = [f"Beam-{i+1:02d}" for i in range(2)]
DUCT_NAMES   = [f"Duct-{i+1:02d}" for i in range(4)]
TERMINAL_MODELS  = ["AHU-1200", "FCU-600", "AHU-800", "FCU-400", "AHU-2400", "FCU-1000"]
CONTROLLER_MODELS = ["VAV-Box-S", "VAV-Box-L", "Butterfly-Valve", "Gate-Valve"]
PUMP_MODELS  = ["Pump-2200", "CircPump-1500", "BoosterPump-900"]
ALARM_NAMES  = [f"Alarm-{i+1:02d}" for i in range(3)]
METER_NAMES  = [f"PowerMeter-{i+1:02d}" for i in range(3)]


def generate():
    global _owner_history

    emit(HEADER)
    _owner_history = emit_header_entities()

    # IfcProject
    proj_origin = nid(); emit(f"#{proj_origin}=IFCCARTESIANPOINT((0.,0.,0.));")
    proj_ax = nid(); emit(f"#{proj_ax}=IFCAXIS2PLACEMENT3D(#{proj_origin},#4,#5);")
    proj_pl = nid(); emit(f"#{proj_pl}=IFCLOCALPLACEMENT($,#{proj_ax});")
    proj_id = nid()
    emit(f"#{proj_id}=IFCPROJECT('{guid()}',#9,'CITY GENERAL HOSPITAL COMPLEX',$,$,'City General Hospital','Phase 1 BIM',(#22),#19);")

    # IfcSite
    site_origin = nid(); emit(f"#{site_origin}=IFCCARTESIANPOINT((0.,0.,0.));")
    site_ax = nid(); emit(f"#{site_ax}=IFCAXIS2PLACEMENT3D(#{site_origin},#4,#5);")
    site_pl = nid(); emit(f"#{site_pl}=IFCLOCALPLACEMENT($,#{site_ax});")
    site_id = nid()
    emit(f"#{site_id}=IFCSITE('{guid()}',#9,'Hospital Campus Site',$,$,#{site_pl},$,$,.COMPLEX.,$,$,0.,$,$);")
    rel_aggregates(proj_id, [site_id])

    building_ids = []

    for bldg in BUILDINGS:
        bx = bldg["offset_x"]
        by = bldg["offset_y"]
        bname = bldg["name"]

        bldg_origin = nid(); emit(f"#{bldg_origin}=IFCCARTESIANPOINT(({bx:.3f},{by:.3f},0.000));")
        bldg_ax = nid(); emit(f"#{bldg_ax}=IFCAXIS2PLACEMENT3D(#{bldg_origin},#4,#5);")
        bldg_pl = nid(); emit(f"#{bldg_pl}=IFCLOCALPLACEMENT(#{site_pl},#{bldg_ax});")
        bldg_id = nid()
        emit(f"#{bldg_id}=IFCBUILDING('{guid()}',#9,'{bname}',$,$,#{bldg_pl},$,'{bname}',.ELEMENT.,$,$,$);")
        building_ids.append(bldg_id)

        storey_ids = []

        for floor in range(FLOORS_PER_BUILDING):
            elevation = floor * FLOOR_HEIGHT
            floor_label = "Ground Floor" if floor == 0 else f"Level {floor:02d}"
            fname = f"{bname} - {floor_label}"

            storey_origin = nid(); emit(f"#{storey_origin}=IFCCARTESIANPOINT((0.,0.,{elevation:.3f}));")
            storey_ax = nid(); emit(f"#{storey_ax}=IFCAXIS2PLACEMENT3D(#{storey_origin},#4,#5);")
            storey_pl = nid(); emit(f"#{storey_pl}=IFCLOCALPLACEMENT(#{bldg_pl},#{storey_ax});")
            storey_id = nid()
            emit(f"#{storey_id}=IFCBUILDINGSTOREY('{guid()}',#9,'{fname}',$,'BuildingStorey',#{storey_pl},$,'{fname}',.ELEMENT.,{elevation:.3f});")
            storey_ids.append(storey_id)

            # Collect all contained elements for this storey
            contained_elements = []

            # Spaces
            space_ids = []
            for j, sname in enumerate(SPACE_NAMES):
                full_sname = f"{fname} - {sname}"
                sx = (j % 4) * 10.0
                sy = (j // 4) * 8.0
                sp_origin = nid(); emit(f"#{sp_origin}=IFCCARTESIANPOINT(({sx:.3f},{sy:.3f},0.000));")
                sp_ax = nid(); emit(f"#{sp_ax}=IFCAXIS2PLACEMENT3D(#{sp_origin},#4,#5);")
                sp_pl = nid(); emit(f"#{sp_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{sp_ax});")
                sp_id = nid()
                emit(f"#{sp_id}=IFCSPACE('{guid()}',#9,'{full_sname}',$,'Space',#{sp_pl},$,'{full_sname}',.ELEMENT.,.INTERNAL.,{elevation:.3f});")
                space_ids.append(sp_id)
                contained_elements.append(sp_id)

            # Walls
            for j, wname in enumerate(WALL_NAMES):
                wx = j * 5.0
                wy = 0.0
                w_origin = nid(); emit(f"#{w_origin}=IFCCARTESIANPOINT(({wx:.3f},{wy:.3f},0.000));")
                w_ax = nid(); emit(f"#{w_ax}=IFCAXIS2PLACEMENT3D(#{w_origin},#4,#5);")
                w_pl = nid(); emit(f"#{w_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{w_ax});")
                w_id = nid()
                emit(f"#{w_id}=IFCWALL('{guid()}',#9,'{fname} - {wname}',$,'Wall',#{w_pl},$,$,$);")
                contained_elements.append(w_id)

            # Slabs
            for j, slname in enumerate(SLAB_NAMES):
                s_origin = nid(); emit(f"#{s_origin}=IFCCARTESIANPOINT((0.,{j*5.:.3f},0.000));")
                s_ax = nid(); emit(f"#{s_ax}=IFCAXIS2PLACEMENT3D(#{s_origin},#4,#5);")
                s_pl = nid(); emit(f"#{s_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{s_ax});")
                s_id = nid()
                emit(f"#{s_id}=IFCSLAB('{guid()}',#9,'{fname} - {slname}',$,'Slab',#{s_pl},$,$,.FLOOR.);")
                contained_elements.append(s_id)

            # Beams
            for j, bname_b in enumerate(BEAM_NAMES):
                b_origin = nid(); emit(f"#{b_origin}=IFCCARTESIANPOINT(({j*12.:.3f},0.,0.));")
                b_ax = nid(); emit(f"#{b_ax}=IFCAXIS2PLACEMENT3D(#{b_origin},#4,#5);")
                b_pl = nid(); emit(f"#{b_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{b_ax});")
                b_id = nid()
                emit(f"#{b_id}=IFCBEAM('{guid()}',#9,'{fname} - {bname_b}',$,'Beam',#{b_pl},$,$,$);")
                contained_elements.append(b_id)

            # Flow segments (ducts)
            for j, dname in enumerate(DUCT_NAMES):
                d_origin = nid(); emit(f"#{d_origin}=IFCCARTESIANPOINT(({j*8.:.3f},0.,{FLOOR_HEIGHT-0.5:.3f}));")
                d_ax = nid(); emit(f"#{d_ax}=IFCAXIS2PLACEMENT3D(#{d_origin},#4,#5);")
                d_pl = nid(); emit(f"#{d_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{d_ax});")
                d_id = nid()
                emit(f"#{d_id}=IFCFLOWSEGMENT('{guid()}',#9,'{fname} - {dname}',$,'Duct',#{d_pl},$,$,$);")
                contained_elements.append(d_id)

            # Flow terminals (AHUs, FCUs)
            for j, (tname, tmodel) in enumerate(zip(
                [f"Terminal-{i+1:02d}" for i in range(6)],
                TERMINAL_MODELS
            )):
                t_origin = nid(); emit(f"#{t_origin}=IFCCARTESIANPOINT(({j*7.:.3f},5.,{FLOOR_HEIGHT-0.3:.3f}));")
                t_ax = nid(); emit(f"#{t_ax}=IFCAXIS2PLACEMENT3D(#{t_origin},#4,#5);")
                t_pl = nid(); emit(f"#{t_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{t_ax});")
                t_id = nid()
                emit(f"#{t_id}=IFCFLOWTERMINAL('{guid()}',#9,'{fname} - {tname}',$,'Terminal',#{t_pl},$,$,$);")
                mfr = nid(); emit(f"#{mfr}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Carrier'),$);")
                typ = nid(); emit(f"#{typ}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{tmodel}'),$);")
                pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#9,'Pset_DistributionElement',$,(#{mfr},#{typ}));")
                rel_p = nid(); emit(f"#{rel_p}=IFCRELDEFINESBYPROPERTIES('{guid()}',#9,$,$,(#{t_id}),#{pset});")
                contained_elements.append(t_id)

            # Flow controllers (dampers, valves)
            for j, (cname, cmodel) in enumerate(zip(
                [f"Controller-{i+1:02d}" for i in range(4)],
                CONTROLLER_MODELS
            )):
                c_origin = nid(); emit(f"#{c_origin}=IFCCARTESIANPOINT(({j*9.:.3f},12.,{FLOOR_HEIGHT-0.5:.3f}));")
                c_ax = nid(); emit(f"#{c_ax}=IFCAXIS2PLACEMENT3D(#{c_origin},#4,#5);")
                c_pl = nid(); emit(f"#{c_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{c_ax});")
                c_id = nid()
                emit(f"#{c_id}=IFCFLOWCONTROLLER('{guid()}',#9,'{fname} - {cname}',$,'Controller',#{c_pl},$,$,$);")
                mfr = nid(); emit(f"#{mfr}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Siemens'),$);")
                typ = nid(); emit(f"#{typ}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{cmodel}'),$);")
                pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#9,'Pset_DistributionElement',$,(#{mfr},#{typ}));")
                rel_p = nid(); emit(f"#{rel_p}=IFCRELDEFINESBYPROPERTIES('{guid()}',#9,$,$,(#{c_id}),#{pset});")
                contained_elements.append(c_id)

            # Flow moving devices (pumps, fans)
            for j, (pname, pmodel) in enumerate(zip(
                [f"Pump-{i+1:02d}" for i in range(3)],
                PUMP_MODELS
            )):
                p_origin = nid(); emit(f"#{p_origin}=IFCCARTESIANPOINT(({j*6.:.3f},20.,1.000));")
                p_ax = nid(); emit(f"#{p_ax}=IFCAXIS2PLACEMENT3D(#{p_origin},#4,#5);")
                p_pl = nid(); emit(f"#{p_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{p_ax});")
                p_id = nid()
                emit(f"#{p_id}=IFCFLOWMOVINGDEVICE('{guid()}',#9,'{fname} - {pname}',$,'Pump',#{p_pl},$,$,$);")
                mfr = nid(); emit(f"#{mfr}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Grundfos'),$);")
                typ = nid(); emit(f"#{typ}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('{pmodel}'),$);")
                pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#9,'Pset_DistributionElement',$,(#{mfr},#{typ}));")
                rel_p = nid(); emit(f"#{rel_p}=IFCRELDEFINESBYPROPERTIES('{guid()}',#9,$,$,(#{p_id}),#{pset});")
                contained_elements.append(p_id)

            # Alarms
            for j, aname in enumerate(ALARM_NAMES):
                a_origin = nid(); emit(f"#{a_origin}=IFCCARTESIANPOINT(({j*15.:.3f},30.,{FLOOR_HEIGHT-0.2:.3f}));")
                a_ax = nid(); emit(f"#{a_ax}=IFCAXIS2PLACEMENT3D(#{a_origin},#4,#5);")
                a_pl = nid(); emit(f"#{a_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{a_ax});")
                a_id = nid()
                emit(f"#{a_id}=IFCALARM('{guid()}',#9,'{fname} - {aname}',$,'Alarm',#{a_pl},$,$,$);")
                mfr = nid(); emit(f"#{mfr}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Honeywell'),$);")
                typ = nid(); emit(f"#{typ}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('F-200-FireAlarm'),$);")
                pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#9,'Pset_AlarmCommon',$,(#{mfr},#{typ}));")
                rel_p = nid(); emit(f"#{rel_p}=IFCRELDEFINESBYPROPERTIES('{guid()}',#9,$,$,(#{a_id}),#{pset});")
                contained_elements.append(a_id)

            # Electric appliances (power meters)
            for j, mname in enumerate(METER_NAMES):
                m_origin = nid(); emit(f"#{m_origin}=IFCCARTESIANPOINT(({j*20.:.3f},35.,1.200));")
                m_ax = nid(); emit(f"#{m_ax}=IFCAXIS2PLACEMENT3D(#{m_origin},#4,#5);")
                m_pl = nid(); emit(f"#{m_pl}=IFCLOCALPLACEMENT(#{storey_pl},#{m_ax});")
                m_id = nid()
                emit(f"#{m_id}=IFCELECTRICAPPLIANCE('{guid()}',#9,'{fname} - {mname}',$,'Appliance',#{m_pl},$,$,$);")
                mfr = nid(); emit(f"#{mfr}=IFCPROPERTYSINGLEVALUE('Manufacturer',$,IFCLABEL('Schneider'),$);")
                typ = nid(); emit(f"#{typ}=IFCPROPERTYSINGLEVALUE('Family and Type',$,IFCLABEL('PowerMeter-PM5350'),$);")
                pset = nid(); emit(f"#{pset}=IFCPROPERTYSET('{guid()}',#9,'Pset_ElectricApplianceCommon',$,(#{mfr},#{typ}));")
                rel_p = nid(); emit(f"#{rel_p}=IFCRELDEFINESBYPROPERTIES('{guid()}',#9,$,$,(#{m_id}),#{pset});")
                contained_elements.append(m_id)

            # Spaces aggregate into storey; everything else is "contained in"
            rel_aggregates(storey_id, space_ids)
            rel_contained(storey_id, [e for e in contained_elements if e not in space_ids])

        rel_aggregates(bldg_id, storey_ids)

    rel_aggregates(site_id, building_ids)

    emit("ENDSEC;")
    emit("END-ISO-10303-21;")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    generate()
    out_path = "LargeHospitalComplex.ifc"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    total_entities = _next_id - 1
    print(f"Generated {out_path}")
    print(f"Total STEP record IDs used: {total_entities}")
    print(f"Approx lines: {len(lines)}")
