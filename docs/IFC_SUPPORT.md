# IFC Support — What the Parser Reads, Skips, and Defaults

> Phase 4.5 deliverable. Describes the actual behavior of
> `engine/bim/ifc_parser.zig` (the hand-rolled SPF parser — see CLAUDE.md §10,
> "IFC wrapper: resolved"). This is a description of the code as it exists
> today, not a wishlist — if a claim here stops matching the parser, fix this
> file in the same change.

---

## 1. Scope

Per CLAUDE.md §3.3, the parser extracts the **minimal subset** needed to spawn
ECS entities for sensor placement and query optimization: hierarchy,
positions, types, and zone/equipment metadata. It does **not** reconstruct
geometry, materials, styling, or units — this is a headless benchmarking
platform, not a BIM viewer.

The parser is a two-phase, hand-rolled IFC SPF (STEP Physical File) reader —
not a wrapper around IfcOpenShell. That C-interop path was the original
open decision in CLAUDE.md §10; it was dropped in favor of this subset parser
once IfcOpenShell integration proved more friction than value for the fields
actually needed. Both real-world fixtures in `assets/IFC/` parse and place
sensors end-to-end with this parser (see §6).

---

## 2. Supported IFC entity types

| IFC type | Maps to `ElementType` | Notes |
|---|---|---|
| `IFCPROJECT` | `.project` | Root of the hierarchy, typically. |
| `IFCSITE` | `.site` | Parsed and kept in the entity map, but **not promoted to a hierarchy level** — see §4. |
| `IFCBUILDING` | `.building` | |
| `IFCBUILDINGSTOREY` | `.storey` | Also gets a `ZoneMetadata` row (§5). |
| `IFCSPACE` | `.space` | Also gets a `ZoneMetadata` row (§5). Sensor-eligible (§7). |
| `IFCWALL`, `IFCWALLSTANDARDCASE` | `.wall` | Hierarchy/position only — never a sensor host under `DEFAULT_RULES` (§7). |
| `IFCSLAB` | `.slab` | Same as wall: parsed, never a default sensor host. |
| `IFCBEAM` | `.beam` | Sensor-eligible (§7). |
| `IFCFLOWSEGMENT` | `.flow_segment` | Sensor-eligible (§7). |
| `IFCFLOWTERMINAL`, `IFCFLOWFITTING`, `IFCFLOWCONTROLLER`, `IFCFLOWMOVINGDEVICE`, `IFCFLOWSTORAGEDEVICE`, `IFCENERGYCONVERSIONDEVICE`, `IFCDISTRIBUTIONCONTROLELEMENT`, `IFCBUILDINGELEMENTPROXY`, `IFCELECTRICAPPLIANCE`, `IFCALARM`, `IFCCABLECARRIERSEGMENT`, `IFCCABLESEGMENT` | `.equipment` | One coarse bucket, not one enum value per IFC type (matches the existing wall/slab/beam granularity). Also gets an `EquipmentMetadata` row (§5). Sensor-eligible (§7). Added after real-file validation showed one fixture has **zero** `IFCSPACE`/`IFCWALL`/`IFCFLOWSEGMENT` entities but hundreds of these types — without this bucket, that file's entire equipment inventory silently vanished into `.other` and the sensor placer produced zero sensors on a real building. |
| *(everything else)* | `.other` | Lexed into the entity map (so relationship-graph references to it still resolve), but never promoted into `building_elements` proper, and ignored by the hierarchy/placement/equipment steps. This is the long tail: `IFCDOOR`, `IFCWINDOW`, `IFCCOLUMN`, `IFCROOF`, `IFCRAILING`, `IFCFURNISHINGELEMENT`, etc. — anything not in the rows above. |

## 3. Supported relationships

| IFC relationship | Used for |
|---|---|
| `IFCRELAGGREGATES` | Parent → children edges (e.g. building → storeys). |
| `IFCRELCONTAINEDINSPATIALSTRUCTURE` | Storey → contained elements (e.g. storey → spaces/walls/equipment). |
| `IFCLOCALPLACEMENT` / `IFCAXIS2PLACEMENT3D` / `IFCCARTESIANPOINT` | World-space position (§4). |
| `IFCRELDEFINESBYPROPERTIES` → `IFCPROPERTYSET` → `IFCPROPERTYSINGLEVALUE` | Equipment metadata (§5). |

Every other relationship type (`IFCRELVOIDSELEMENT`, `IFCRELCONNECTSPATHELEMENTS`,
`IFCRELASSOCIATESMATERIAL`, etc.) is lexed but not interpreted.

## 4. Position resolution

Positions are resolved by walking the `IFCLOCALPLACEMENT` chain for each
spatial element and **summing translations** from each link's
`IFCAXIS2PLACEMENT3D` → `IFCCARTESIANPOINT`. Two things are explicitly out of
scope, by design:

- **Rotation is ignored** (the `Axis`/`RefDirection` args on
  `IFCAXIS2PLACEMENT3D` are never read). Sensor-placement and spatial queries
  only need a point in space, not an orientation — supporting rotation would
  add matrix math without changing any query result.
- **`IFCSITE` is not promoted to a hierarchy level.** It's parsed (so
  placement chains that reference it still resolve) but doesn't appear as a
  parent in the building tree the way `IFCBUILDING`/`IFCBUILDINGSTOREY` do.

A broken or missing placement chain (missing entity, wrong type, no
`IFCCARTESIANPOINT` terminal, or a cycle — bounded at 64 hops) **degrades to
the world origin `{0,0,0}`**, never a crash or parse failure.

## 5. Metadata extraction

**Zones** (`ZoneMetadata`, one per `IFCBUILDINGSTOREY`/`IFCSPACE`):
- `floor_level` — read from `IFCBUILDINGSTOREY.Elevation` (arg index 9).
  `IFCSPACE` rows inherit their containing storey's elevation, resolved once
  at parse time. A space with no containing storey gets `floor_level = 0`,
  not a crash.
- `area_m2` — **always 0.** `IFCQUANTITYSET`/`IFCELEMENTQUANTITY` extraction
  is not implemented. (This is the gap that made Phase 5.2 — wiring profiles
  into placement scoring — wait on Phase 7's report layer instead of guessing
  at floor area.)

**Equipment** (`EquipmentMetadata`, one per `.equipment`-typed element, always
emitted even when every field below is empty — never optional/missing):
- `manufacturer` — from a property literally named `"Manufacturer"`. `""` if
  absent.
- `model` — first match, in priority order: `"Family and Type"`, else
  `"Type Name"`, else `"Family Name"`. `""` if none of the three are present.
- `age_days`, `efficiency` — **not extracted, always 0.** Neither real
  fixture in `assets/IFC/` carries an install-date or efficiency-rating
  property under any vendor property set (verified by grepping both files'
  actual `IFCPROPERTYSINGLEVALUE` names). The fields are kept as named,
  always-zero placeholders rather than removed, so the shape doesn't need to
  change the moment a real source format is identified — only the value.

Property sets are matched via `IFCRELDEFINESBYPROPERTIES` →
`IFCPROPERTYSET` → `IFCPROPERTYSINGLEVALUE` only.
`IFCPROPERTYSETDEFINITIONSET` and other property-set carriers are not
walked.

## 6. Validated against

Both real Revit 2021 (IFC2x3) exports in `assets/IFC/` parse and place
sensors end-to-end (`ifc_validation_test.zig`, part of `zig build test`):

| File | Entities | Elements | Storeys | Spaces | Walls | Flow segments | Equipment | Sensors placed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `2KHRJ17-CUN-TD-712-EL-MOD-00001-00-IFC.ifc` | 220,718 | 989 | 4 | 0 | 0 | 263 | 719 | 2,490 |
| `2KHRJ17-HASC-SD-710-EV-MOD-00001.ifc` | 110,803 | 187 | 2 | 0 | 0 | 0 | 182 | 364 |

Neither file has any `IFCSPACE` or `IFCWALL` entities at all — both are
electrical/services models that lean entirely on `.equipment` and
`flow_segment`. This is exactly the case the `.equipment` bucket (§2) exists
for: without it, both files would place **zero** sensors.

Only IFC2x3 Revit exports have been validated. The lexer itself is
schema-agnostic (it parses SPF syntax, not a fixed IFC4/IFC2x3 schema), but
the entity-name table in §2 has only been exercised against these two files
— an IFC4 export using different entity names for equivalent concepts would
silently fall into `.other`.

## 7. Sensor-eligible vs. parsed-only element types

Parsing an element and being eligible for sensor placement are **different
sets**. Under `sensor_placer.zig`'s `DEFAULT_RULES`, only four `ElementType`
values get sensors: `.space`, `.flow_segment`, `.beam`, `.equipment`.

`.project`, `.site`, `.building`, `.storey`, `.wall`, and `.slab` are parsed
into `BuildingElement`s (so they appear in the hierarchy, can be queried, and
participate in zone/position resolution) but **never host a sensor** under
the defaults — `.wall` and `.slab` are explicitly excluded by a dedicated
test (`findRule(&DEFAULT_RULES, .wall) == null`). A caller can still attach
sensors to walls/slabs by passing custom `PlacementRule`s (the mechanism
already supports it — see `sensor_placer.zig`'s "custom rules slice fully
overrides defaults" test) — there's just no default building-type profile
that does so today.

## 8. Malformed-input behavior

| Condition | Behavior |
|---|---|
| No `DATA;` section in the file | `error.MissingDataSection` |
| Two entities share the same `#N` id | `error.DuplicateEntityId` |
| Unterminated string / bad number / bad reference / unexpected EOF | A specific lexer error (`UnterminatedString`, `InvalidNumber`, `InvalidReference`, `UnexpectedEndOfInput`, ...) — never a panic. |
| Broken/cyclic placement chain | Degrades to position `{0,0,0}` (§4) — not an error. |
| Space with no containing storey | `floor_level = 0` (§5) — not an error. |
| Element type not in §2's table | Lexed, stored in the entity map, excluded from `building_elements` — not an error. |

`C`-style `/* ... */` comments nest correctly (tracked by depth, not just
"find the next `*/`"), and doubled single-quotes (`''`) inside string
literals round-trip to one literal `'`.
