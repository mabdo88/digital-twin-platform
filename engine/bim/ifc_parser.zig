// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Hand-rolled IFC SPF (STEP Physical File) parser — Phase 4.1.
//
// Scope (CLAUDE.md spec §7.1): the MINIMAL subset needed to spawn ECS entities
// for sensor placement and query optimisation. We parse:
//
//   ENTITIES (by NAME after =)
//     IfcProject, IfcBuilding, IfcBuildingStorey, IfcSpace
//     IfcWall, IfcSlab, IfcBeam, IfcFlowSegment
//     IfcRelAggregates                       (parent -> children edges)
//     IfcRelContainedInSpatialStructure      (storey -> contained elements)
//     IfcLocalPlacement / IfcAxis2Placement3D / IfcCartesianPoint
//                                            (resolved into a world-space Vec3)
//
//   DELIBERATELY SKIPPED in this pass (will be documented in IFC_SUPPORT.md /
//   Task 4.5): geometry beyond the placement origin, IfcPropertySet /
//   IfcRelDefinesByProperties (Phase 4 task on its own), units / IfcUnitAssignment,
//   IfcSite (passed through but not promoted to a hierarchy level), materials,
//   styling, and the long tail of IFC entity types — every other type lands in
//   the entity map as a generic Entity and is ignored by the hierarchy step.
//
// The parser is two-phase per spec §7.1:
//   Phase 1 (parse + index) — tokenise the DATA section into a HashMap(u32, Entity)
//                              keyed by `#N`. Pure lex/parse; no semantic work.
//   Phase 2 (resolve)      — walk IfcRelAggregates / IfcRelContainedInSpatialStructure
//                              to reconstruct the building tree, and walk every
//                              spatial element's IfcLocalPlacement chain to
//                              compute its world position.
//
// IFC quirks handled:
//   - Strings are 'single quoted'; embedded apostrophes are doubled ('').
//   - Numbers may carry a leading sign and use scientific notation (1.5E-3).
//   - `$` means UNSET, `*` means DERIVED — both modelled as distinct args.
//   - Comments use C-style /* ... */ and may appear anywhere between tokens.
//   - Whitespace (incl. line breaks) is insignificant between tokens.
//
// Returned ParsedModel owns ALL backing memory through an internal arena
// allocator — caller frees with `model.deinit()` and that's it; no per-entity
// or per-string cleanup. This matches the "asset-style" lifetime IFC data has
// in the platform (parsed once, consumed, dropped).

const std = @import("std");
const Allocator = std.mem.Allocator;
const components = @import("components.zig");

// ---------------------------------------------------------------------------
// Re-exports — components live in components.zig but every caller of the
// parser ends up wanting the component types too, so we re-export them here
// to keep the single-import surface (`@import("ifc_parser.zig")`).
// ---------------------------------------------------------------------------

pub const Vec3 = components.Vec3;
pub const ElementType = components.ElementType;
pub const ZoneType = components.ZoneType;
pub const BuildingElement = components.BuildingElement;
pub const ZoneMetadata = components.ZoneMetadata;
pub const EquipmentMetadata = components.EquipmentMetadata;

/// One IFC entity argument. IFC SPF args are an irregular grammar — a single
/// arg slot can be any of these shapes, including a nested list.
pub const ArgValue = union(enum) {
    unset, // `$`
    derived, // `*`
    integer: i64,
    real: f64,
    string: []const u8, // owned by ParsedModel arena
    enum_lit: []const u8, // owned by ParsedModel arena (the inner text of `.NAME.`)
    ref: u32, // `#N`
    list: []ArgValue, // owned by ParsedModel arena
};

pub const Entity = struct {
    /// `#N` id from the file.
    id: u32,
    /// Upper-cased IFC type, e.g. "IFCBUILDINGSTOREY". Owned by arena.
    type_name: []const u8,
    /// Top-level argument slice. Owned by arena.
    args: []ArgValue,
};

/// Lookup that maps a raw IFC type name (uppercased) to our reduced
/// ElementType taxonomy. Lives here (not on the enum) because the enum
/// itself is in components.zig and shouldn't carry IFC-name knowledge.
fn elementTypeFromIfcName(name: []const u8) ElementType {
    // Type names already get uppercased at lex time, so byte-equality is fine.
    const T = struct {
        fn eq(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };
    if (T.eq(name, "IFCPROJECT")) return .project;
    if (T.eq(name, "IFCSITE")) return .site;
    if (T.eq(name, "IFCBUILDING")) return .building;
    if (T.eq(name, "IFCBUILDINGSTOREY")) return .storey;
    if (T.eq(name, "IFCSPACE")) return .space;
    if (T.eq(name, "IFCWALL")) return .wall;
    if (T.eq(name, "IFCWALLSTANDARDCASE")) return .wall;
    if (T.eq(name, "IFCSLAB")) return .slab;
    if (T.eq(name, "IFCBEAM")) return .beam;
    if (T.eq(name, "IFCFLOWSEGMENT")) return .flow_segment;
    // Granular MEP/electrical types — see components.zig's ElementType
    // doc comments for which sensors go on each.
    if (T.eq(name, "IFCFLOWTERMINAL")) return .flow_terminal;
    if (T.eq(name, "IFCFLOWFITTING")) return .flow_fitting;
    if (T.eq(name, "IFCFLOWCONTROLLER")) return .flow_controller;
    if (T.eq(name, "IFCFLOWMOVINGDEVICE")) return .flow_moving_device;
    if (T.eq(name, "IFCFLOWSTORAGEDEVICE")) return .flow_storage_device;
    if (T.eq(name, "IFCENERGYCONVERSIONDEVICE")) return .energy_conversion_device;
    if (T.eq(name, "IFCDISTRIBUTIONCONTROLELEMENT")) return .distribution_control_element;
    if (T.eq(name, "IFCBUILDINGELEMENTPROXY")) return .building_element_proxy;
    if (T.eq(name, "IFCELECTRICAPPLIANCE")) return .electric_appliance;
    if (T.eq(name, "IFCALARM")) return .alarm;
    if (T.eq(name, "IFCCABLECARRIERSEGMENT")) return .cable_segment;
    if (T.eq(name, "IFCCABLESEGMENT")) return .cable_segment;
    return .other;
}

pub const ParsedModel = struct {
    arena: std.heap.ArenaAllocator,
    /// Every entity in the file, keyed by `#N`. Considered an implementation
    /// detail — downstream systems should consume `building_elements` and
    /// `zones`, not iterate this map.
    entities: std.AutoHashMapUnmanaged(u32, Entity),
    /// One per supported spatial element (IfcProject/IfcBuilding/etc.).
    /// Sorted by ifc_id ascending for deterministic test comparisons.
    building_elements: []BuildingElement,
    /// Sidecar metadata for entities that act as zones (storeys and spaces).
    /// `zones[i].zone_id` matches the corresponding `BuildingElement.ifc_id`.
    /// Sorted by zone_id ascending.
    zones: []ZoneMetadata,
    /// Sidecar metadata for entities that act as equipment (flow_terminal,
    /// flow_fitting, flow_controller, flow_moving_device, flow_storage_device,
    /// energy_conversion_device, distribution_control_element,
    /// building_element_proxy, electric_appliance, alarm, cable_segment).
    /// One entry per equipment-typed BuildingElement
    /// (`equipment[i].element_id` matches the corresponding
    /// `BuildingElement.ifc_id`). Sorted by element_id ascending.
    equipment: []EquipmentMetadata,

    pub fn deinit(self: *ParsedModel) void {
        // Arena owns everything strings / arg lists / element slices point at,
        // so a single arena reset is enough. The HashMap header itself is in
        // the arena too (Unmanaged variant).
        self.arena.deinit();
    }
};

pub const ParseError = error{
    UnexpectedEndOfInput,
    UnexpectedCharacter,
    InvalidEntityHeader,
    InvalidNumber,
    InvalidReference,
    UnterminatedString,
    MissingDataSection,
    DuplicateEntityId,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Lexer + parser
// ---------------------------------------------------------------------------

/// Single-pass lexer/parser over IFC SPF source text. State is just the cursor
/// + arena; everything we produce hangs off the arena.
const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: Allocator,

    fn init(src: []const u8, arena: Allocator) Parser {
        return .{ .src = src, .pos = 0, .arena = arena };
    }

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.atEnd()) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.atEnd()) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    /// Skip whitespace and /* ... */ comments. Comments can be nested in SPF
    /// per ISO 10303-21 — we keep a depth counter rather than the simpler
    /// "find next */" so deeply-commented sample files don't trip us up.
    fn skipTrivia(self: *Parser) void {
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                var depth: usize = 1;
                while (!self.atEnd() and depth > 0) {
                    const a = self.src[self.pos];
                    if (a == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (a == '*' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                continue;
            }
            break;
        }
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        self.skipTrivia();
        if (self.atEnd()) return error.UnexpectedEndOfInput;
        if (self.src[self.pos] != ch) return error.UnexpectedCharacter;
        self.pos += 1;
    }

    /// Try to consume a literal keyword (case-insensitive) at a word
    /// boundary. Returns true on success; leaves cursor untouched on miss.
    ///
    /// Both sides matter: without the LEFT boundary, "FOODATA" matches;
    /// without the RIGHT one, "DATABASE" matches. Real IFC headers contain
    /// the literal word "Database" in comments and "Data" inside string
    /// literals like 'The EXPRESS Data Manager', and we have to ignore them.
    fn tryKeyword(self: *Parser, kw: []const u8) bool {
        self.skipTrivia();
        if (self.pos > 0) {
            const prev = self.src[self.pos - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_') return false;
        }
        if (self.pos + kw.len > self.src.len) return false;
        for (kw, 0..) |kc, i| {
            if (std.ascii.toUpper(self.src[self.pos + i]) != std.ascii.toUpper(kc)) return false;
        }
        const next = self.pos + kw.len;
        if (next < self.src.len) {
            const c = self.src[next];
            if (std.ascii.isAlphanumeric(c) or c == '_') return false;
        }
        self.pos += kw.len;
        return true;
    }

    /// `#NNN` reference. Cursor must be on `#`.
    fn readRef(self: *Parser) ParseError!u32 {
        if (self.peek() != @as(?u8, '#')) return error.InvalidReference;
        self.pos += 1;
        const start = self.pos;
        while (!self.atEnd() and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
        if (self.pos == start) return error.InvalidReference;
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch return error.InvalidReference;
    }

    /// SPF string literal: 'abc' with '' representing a literal single quote.
    /// Cursor must be on the opening `'`. Returns a copy in the arena.
    fn readString(self: *Parser) ParseError![]const u8 {
        if (self.peek() != @as(?u8, '\'')) return error.UnexpectedCharacter;
        self.pos += 1;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);

        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (c == '\'') {
                // Doubled '' = embedded single quote, otherwise terminator.
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                    try buf.append(self.arena, '\'');
                    self.pos += 2;
                } else {
                    self.pos += 1;
                    return try buf.toOwnedSlice(self.arena);
                }
            } else {
                try buf.append(self.arena, c);
                self.pos += 1;
            }
        }
        return error.UnterminatedString;
    }

    /// Enumeration literal: `.NAME.` — returns just the inner NAME (uppercased).
    fn readEnum(self: *Parser) ParseError![]const u8 {
        if (self.peek() != @as(?u8, '.')) return error.UnexpectedCharacter;
        self.pos += 1;
        const start = self.pos;
        while (!self.atEnd() and self.src[self.pos] != '.') : (self.pos += 1) {}
        if (self.atEnd()) return error.UnexpectedEndOfInput;
        const slice = self.src[start..self.pos];
        self.pos += 1; // closing '.'
        return try self.arena.dupe(u8, slice);
    }

    /// Identifier (type name like IFCBUILDINGSTOREY). Stored uppercased to
    /// make later type-name compares case-stable.
    fn readIdent(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') self.pos += 1 else break;
        }
        if (self.pos == start) return error.UnexpectedCharacter;
        const out = try self.arena.alloc(u8, self.pos - start);
        for (self.src[start..self.pos], 0..) |c, i| out[i] = std.ascii.toUpper(c);
        return out;
    }

    /// Numeric literal — integer or real. Returns the typed ArgValue.
    fn readNumber(self: *Parser) ParseError!ArgValue {
        const start = self.pos;
        if (self.peek() == @as(?u8, '+') or self.peek() == @as(?u8, '-')) self.pos += 1;

        var has_dot = false;
        var has_exp = false;
        while (!self.atEnd()) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c)) {
                self.pos += 1;
            } else if (c == '.' and !has_dot and !has_exp) {
                has_dot = true;
                self.pos += 1;
            } else if ((c == 'e' or c == 'E') and !has_exp) {
                has_exp = true;
                self.pos += 1;
                if (self.peek() == @as(?u8, '+') or self.peek() == @as(?u8, '-')) self.pos += 1;
            } else break;
        }
        if (self.pos == start) return error.InvalidNumber;

        const text = self.src[start..self.pos];
        if (has_dot or has_exp) {
            const v = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
            return .{ .real = v };
        }
        const v = std.fmt.parseInt(i64, text, 10) catch return error.InvalidNumber;
        return .{ .integer = v };
    }

    /// Parse one argument value.
    fn readArg(self: *Parser) ParseError!ArgValue {
        self.skipTrivia();
        if (self.atEnd()) return error.UnexpectedEndOfInput;
        const c = self.src[self.pos];
        return switch (c) {
            '$' => blk: {
                self.pos += 1;
                break :blk .unset;
            },
            '*' => blk: {
                self.pos += 1;
                break :blk .derived;
            },
            '\'' => .{ .string = try self.readString() },
            '.' => .{ .enum_lit = try self.readEnum() },
            '#' => .{ .ref = try self.readRef() },
            '(' => try self.readList(),
            '+', '-', '0'...'9' => try self.readNumber(),
            'A'...'Z', 'a'...'z', '_' => try self.readTypedArg(),
            else => error.UnexpectedCharacter,
        };
    }

    /// `IDENT(arg)` — typed constants like IFCLABEL('foo'), IFCIDENTIFIER('x'),
    /// IFCREAL(1.5). The type tag is schema metadata we don't care about; we
    /// only want the inner value. Returns the inner arg's ArgValue directly,
    /// so downstream code sees a plain string / real / etc. as if no wrapper
    /// had been there.
    fn readTypedArg(self: *Parser) ParseError!ArgValue {
        _ = try self.readIdent(); // consume + discard the type tag
        self.skipTrivia();
        try self.expect('(');
        self.skipTrivia();
        // Empty `IFCLABEL()` is legal in some shapes — treat as unset.
        if (self.peek() == @as(?u8, ')')) {
            self.pos += 1;
            return .unset;
        }
        const inner = try self.readArg();
        self.skipTrivia();
        try self.expect(')');
        return inner;
    }

    /// `(arg, arg, ...)` — also handles the empty list `()`.
    fn readList(self: *Parser) ParseError!ArgValue {
        try self.expect('(');
        var items: std.ArrayList(ArgValue) = .empty;
        defer items.deinit(self.arena);

        self.skipTrivia();
        if (self.peek() == @as(?u8, ')')) {
            self.pos += 1;
            const slice = try items.toOwnedSlice(self.arena);
            return .{ .list = slice };
        }

        while (true) {
            const v = try self.readArg();
            try items.append(self.arena, v);
            self.skipTrivia();
            if (self.peek() == @as(?u8, ',')) {
                self.pos += 1;
                continue;
            }
            try self.expect(')');
            break;
        }

        const slice = try items.toOwnedSlice(self.arena);
        return .{ .list = slice };
    }

    /// `#N = TYPE(args);` — parses one entity declaration.
    fn readEntity(self: *Parser) ParseError!Entity {
        const id = try self.readRef();
        self.skipTrivia();
        try self.expect('=');
        self.skipTrivia();
        const tname = try self.readIdent();
        self.skipTrivia();
        const args_val = try self.readList();
        self.skipTrivia();
        try self.expect(';');
        return .{ .id = id, .type_name = tname, .args = args_val.list };
    }
};

// ---------------------------------------------------------------------------
// Top-level parse
// ---------------------------------------------------------------------------

/// Parse an IFC SPF source string into a ParsedModel. Caller must call
/// `model.deinit()` to release the arena.
///
/// The HEADER section is skipped wholesale — we don't validate it. We jump
/// straight to `DATA;`, parse every `#N = ...;` until `ENDSEC;`, then return.
pub fn parseSlice(allocator: Allocator, source: []const u8) ParseError!ParsedModel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const ar = arena.allocator();

    var p = Parser.init(source, ar);

    // Walk to the start of the DATA section. We have to LEX through the
    // header (skipping comments AND string literals) rather than just
    // scanning bytes, because real exporter headers contain strings like
    // 'The EXPRESS Data Manager' that would otherwise match DATA on a
    // case-insensitive compare.
    while (true) {
        p.skipTrivia();
        if (p.atEnd()) return error.MissingDataSection;

        // Skip over a string literal wholesale — every char inside is opaque.
        if (p.src[p.pos] == '\'') {
            p.pos += 1;
            while (!p.atEnd()) {
                const sc = p.src[p.pos];
                if (sc == '\'') {
                    // `''` is an escaped quote inside a string, not a terminator.
                    if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\'') {
                        p.pos += 2;
                    } else {
                        p.pos += 1;
                        break;
                    }
                } else {
                    p.pos += 1;
                }
            }
            continue;
        }

        if (p.tryKeyword("DATA")) {
            p.skipTrivia();
            try p.expect(';');
            break;
        }
        p.pos += 1;
    }

    var entities: std.AutoHashMapUnmanaged(u32, Entity) = .empty;

    while (true) {
        p.skipTrivia();
        if (p.atEnd()) return error.UnexpectedEndOfInput;
        if (p.tryKeyword("ENDSEC")) {
            p.skipTrivia();
            try p.expect(';');
            break;
        }
        if (p.peek() != @as(?u8, '#')) return error.InvalidEntityHeader;
        const ent = try p.readEntity();
        const gop = try entities.getOrPut(ar, ent.id);
        if (gop.found_existing) return error.DuplicateEntityId;
        gop.value_ptr.* = ent;
    }

    // Phase 2: resolve hierarchy + positions + zones. Has to be a separate
    // pass since forward references are common (a parent's IfcRelAggregates
    // often lists child IDs that haven't been read yet at the parent's own
    // declaration).
    const resolved = try resolveHierarchy(ar, &entities);

    return .{
        .arena = arena,
        .entities = entities,
        .building_elements = resolved.building_elements,
        .zones = resolved.zones,
        .equipment = resolved.equipment,
    };
}

// ---------------------------------------------------------------------------
// Hierarchy + position resolution (Phase 2)
// ---------------------------------------------------------------------------

/// Output of phase 2 — all component slices, arena-owned.
const Resolved = struct {
    building_elements: []BuildingElement,
    zones: []ZoneMetadata,
    equipment: []EquipmentMetadata,
};

/// Per-element accumulator while resolving IfcRelDefinesByProperties chains.
/// `model_rank` tracks which property name supplied `model` so a
/// higher-priority name (lower rank) can override a lower-priority one
/// already found in an earlier-processed property set.
const EquipmentAcc = struct {
    manufacturer: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_rank: ?u8 = null,
};

/// Priority order for which property supplies `EquipmentMetadata.model`,
/// lowest rank wins. Picked from the property names actually observed in
/// assets/IFC/*.ifc (grepped IfcPropertySingleValue names directly) — Revit
/// carries no field literally named "Model", but "Family and Type" /
/// "Type Name" / "Family Name" are the closest real equivalents, in
/// descending specificity.
fn modelFieldRank(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "Family and Type")) return 0;
    if (std.mem.eql(u8, name, "Type Name")) return 1;
    if (std.mem.eql(u8, name, "Family Name")) return 2;
    return null;
}

/// Walk every IfcRelDefinesByProperties -> IfcPropertySet ->
/// IfcPropertySingleValue chain and resolve manufacturer/model per element.
///
/// Processes relationships in `#N`-ascending order (not HashMap iteration
/// order) so that when multiple property sets target the same element with
/// conflicting values, the result is deterministic regardless of hash
/// layout — same input always produces the same output.
fn resolveEquipmentProperties(
    arena: Allocator,
    entities: *const std.AutoHashMapUnmanaged(u32, Entity),
) ParseError!std.AutoHashMapUnmanaged(u32, EquipmentAcc) {
    var rel_ids: std.ArrayList(u32) = .empty;
    defer rel_ids.deinit(arena);
    {
        var it = entities.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.type_name, "IFCRELDEFINESBYPROPERTIES")) {
                try rel_ids.append(arena, kv.key_ptr.*);
            }
        }
    }
    std.mem.sort(u32, rel_ids.items, {}, std.sort.asc(u32));

    var by_element: std.AutoHashMapUnmanaged(u32, EquipmentAcc) = .empty;

    for (rel_ids.items) |rel_id| {
        const rel = entities.get(rel_id).?;
        // IfcRelDefinesByProperties(GlobalId, OwnerHistory, Name,
        //   Description, RelatedObjects[], RelatingPropertyDefinition)
        if (rel.args.len < 6) continue;
        const related_objects = rel.args[4];
        const propdef_ref = rel.args[5];
        if (related_objects != .list or propdef_ref != .ref) continue;

        const pset = entities.get(propdef_ref.ref) orelse continue;
        // RelatingPropertyDefinition may also point at an IfcElementQuantity
        // or IfcPropertySetDefinitionSet — neither carries the named
        // single-value properties we read here, so skip gracefully.
        if (!std.mem.eql(u8, pset.type_name, "IFCPROPERTYSET")) continue;
        if (pset.args.len < 5 or pset.args[4] != .list) continue;

        var manufacturer: ?[]const u8 = null;
        var model: ?[]const u8 = null;
        var model_rank: ?u8 = null;

        for (pset.args[4].list) |prop_ref| {
            if (prop_ref != .ref) continue;
            const prop = entities.get(prop_ref.ref) orelse continue;
            if (!std.mem.eql(u8, prop.type_name, "IFCPROPERTYSINGLEVALUE")) continue;
            // IfcPropertySingleValue(Name, Description, NominalValue, Unit)
            if (prop.args.len < 1 or prop.args[0] != .string) continue;
            const pname = prop.args[0].string;
            // NominalValue is already unwrapped to its inner value by
            // readTypedArg (IFCLABEL('x') etc. collapse to the plain string).
            const pval: ?[]const u8 = if (prop.args.len > 2 and prop.args[2] == .string) prop.args[2].string else null;
            if (pval == null) continue;

            if (manufacturer == null and std.mem.eql(u8, pname, "Manufacturer")) {
                manufacturer = pval;
            }
            if (modelFieldRank(pname)) |rank| {
                if (model_rank == null or rank < model_rank.?) {
                    model = pval;
                    model_rank = rank;
                }
            }
        }

        if (manufacturer == null and model == null) continue;

        for (related_objects.list) |obj| {
            if (obj != .ref) continue;
            const gop = try by_element.getOrPut(arena, obj.ref);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (gop.value_ptr.manufacturer == null) gop.value_ptr.manufacturer = manufacturer;
            if (model_rank != null and (gop.value_ptr.model_rank == null or model_rank.? < gop.value_ptr.model_rank.?)) {
                gop.value_ptr.model = model;
                gop.value_ptr.model_rank = model_rank;
            }
        }
    }

    return by_element;
}

/// Walk every IfcRelAggregates / IfcRelContainedInSpatialStructure to build
/// the parent map, then emit (a) one BuildingElement per supported spatial
/// entity with its position resolved from the IfcLocalPlacement chain, and
/// (b) one ZoneMetadata per storey/space.
fn resolveHierarchy(arena: Allocator, entities: *std.AutoHashMapUnmanaged(u32, Entity)) ParseError!Resolved {
    // Parent lookup: child_ifc_id -> parent_ifc_id.
    var parent_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    var it = entities.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr.*;

        // IfcRelAggregates(GlobalId, OwnerHistory, Name, Description,
        //                   RelatingObject, RelatedObjects[])
        if (std.mem.eql(u8, e.type_name, "IFCRELAGGREGATES") and e.args.len >= 6) {
            const parent_arg = e.args[4];
            const children_arg = e.args[5];
            if (parent_arg == .ref and children_arg == .list) {
                for (children_arg.list) |child| {
                    if (child == .ref) {
                        try parent_of.put(arena, child.ref, parent_arg.ref);
                    }
                }
            }
        }

        // IfcRelContainedInSpatialStructure(GlobalId, OwnerHistory, Name,
        //                                    Description, RelatedElements[],
        //                                    RelatingStructure)
        if (std.mem.eql(u8, e.type_name, "IFCRELCONTAINEDINSPATIALSTRUCTURE") and e.args.len >= 6) {
            const children_arg = e.args[4];
            const parent_arg = e.args[5];
            if (parent_arg == .ref and children_arg == .list) {
                for (children_arg.list) |child| {
                    if (child == .ref) {
                        try parent_of.put(arena, child.ref, parent_arg.ref);
                    }
                }
            }
        }
    }

    // Pre-pass: index storey elevations so spaces can inherit them in one
    // hop rather than re-walking the parent chain per space.
    // IfcBuildingStorey(GlobalId, OwnerHistory, Name, Description, ObjectType,
    //                    ObjectPlacement, Representation, LongName,
    //                    CompositionType, Elevation) — Elevation at index 9.
    var storey_elevation: std.AutoHashMapUnmanaged(u32, f64) = .empty;
    var it_st = entities.iterator();
    while (it_st.next()) |kv| {
        const e = kv.value_ptr.*;
        if (!std.mem.eql(u8, e.type_name, "IFCBUILDINGSTOREY")) continue;
        const elev: f64 = if (e.args.len > 9) numberAsF64(e.args[9]) orelse 0 else 0;
        try storey_elevation.put(arena, e.id, elev);
    }

    // Pre-pass: resolve IfcRelDefinesByProperties -> IfcPropertySet ->
    // IfcPropertySingleValue chains so the main pass can look up
    // manufacturer/model by element_id in O(1).
    var equipment_props = try resolveEquipmentProperties(arena, entities);

    // Main pass: emit BuildingElement + (for storeys/spaces) ZoneMetadata
    // + (for equipment) EquipmentMetadata.
    var elements: std.ArrayList(BuildingElement) = .empty;
    defer elements.deinit(arena);
    var zones: std.ArrayList(ZoneMetadata) = .empty;
    defer zones.deinit(arena);
    var equipment: std.ArrayList(EquipmentMetadata) = .empty;
    defer equipment.deinit(arena);

    var it2 = entities.iterator();
    while (it2.next()) |kv| {
        const e = kv.value_ptr.*;
        const etype = elementTypeFromIfcName(e.type_name);
        if (etype == .other) continue;

        // IFC root entities place Name at arg index 2.
        const name: []const u8 = if (e.args.len > 2 and e.args[2] == .string)
            e.args[2].string
        else
            "";

        // ObjectPlacement is at arg index 5 on IfcProduct subclasses
        // (IfcSpace/IfcWall/etc). IfcProject has no placement.
        var position: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
        if (e.args.len > 5 and e.args[5] == .ref) {
            position = resolvePlacement(entities, e.args[5].ref) orelse Vec3{ .x = 0, .y = 0, .z = 0 };
        }

        const parent_id = parent_of.get(e.id);

        try elements.append(arena, .{
            .ifc_id = e.id,
            .name = name,
            .element_type = etype,
            .parent_id = parent_id,
            .position = position,
        });

        // Zones: storeys carry their own elevation; spaces inherit from
        // their containing storey (if any) — gives zone-level queries a
        // ready-to-use floor_level without re-walking the hierarchy.
        switch (etype) {
            .storey => {
                try zones.append(arena, .{
                    .zone_id = e.id,
                    .name = name,
                    .zone_type = .storey,
                    .floor_level = storey_elevation.get(e.id) orelse 0,
                    .area_m2 = 0,
                });
            },
            .space => {
                const inherited = if (parent_id) |pid| storey_elevation.get(pid) orelse 0 else 0;
                try zones.append(arena, .{
                    .zone_id = e.id,
                    .name = name,
                    .zone_type = .space,
                    .floor_level = inherited,
                    .area_m2 = 0,
                });
            },
            .flow_terminal, .flow_fitting, .flow_controller, .flow_moving_device, .flow_storage_device, .energy_conversion_device, .distribution_control_element, .building_element_proxy, .electric_appliance, .alarm, .cable_segment => {
                const props = equipment_props.get(e.id);
                try equipment.append(arena, .{
                    .element_id = e.id,
                    .manufacturer = if (props) |p| (p.manufacturer orelse "") else "",
                    .model = if (props) |p| (p.model orelse "") else "",
                });
            },
            else => {},
        }
    }

    // Stable ordering: by id ascending, so tests can compare row[i] against
    // an expected fixture without depending on HashMap iteration order.
    std.mem.sort(BuildingElement, elements.items, {}, struct {
        fn lt(_: void, a: BuildingElement, b: BuildingElement) bool {
            return a.ifc_id < b.ifc_id;
        }
    }.lt);
    std.mem.sort(ZoneMetadata, zones.items, {}, struct {
        fn lt(_: void, a: ZoneMetadata, b: ZoneMetadata) bool {
            return a.zone_id < b.zone_id;
        }
    }.lt);
    std.mem.sort(EquipmentMetadata, equipment.items, {}, struct {
        fn lt(_: void, a: EquipmentMetadata, b: EquipmentMetadata) bool {
            return a.element_id < b.element_id;
        }
    }.lt);

    return .{
        .building_elements = try elements.toOwnedSlice(arena),
        .zones = try zones.toOwnedSlice(arena),
        .equipment = try equipment.toOwnedSlice(arena),
    };
}

/// Walk an IfcLocalPlacement chain back to a world position.
/// Returns null if the chain breaks (missing entity, wrong type, no
/// IfcCartesianPoint terminal). Translations compose by addition; we ignore
/// IfcAxis2Placement3D rotation (Axis/RefDirection args) — for sensor
/// placement queries the origin is what matters, and supporting orientations
/// adds matrix math without changing any query result.
fn resolvePlacement(entities: *const std.AutoHashMapUnmanaged(u32, Entity), placement_id: u32) ?Vec3 {
    var sum: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    var current: ?u32 = placement_id;
    // Bound the walk in case of cyclic data — IFC shouldn't have cycles here,
    // but trusting the input is how runtime hangs are born.
    var hops: usize = 0;
    while (current) |cid| : (hops += 1) {
        if (hops > 64) return null;
        const placement = entities.get(cid) orelse return null;
        if (!std.mem.eql(u8, placement.type_name, "IFCLOCALPLACEMENT")) return null;
        // IfcLocalPlacement(PlacementRelTo: optional, RelativePlacement)
        if (placement.args.len < 2) return null;

        // arg[1] -> IfcAxis2Placement3D
        if (placement.args[1] == .ref) {
            const axis = entities.get(placement.args[1].ref) orelse return null;
            // IfcAxis2Placement3D(Location, Axis, RefDirection)
            if (std.mem.eql(u8, axis.type_name, "IFCAXIS2PLACEMENT3D") and axis.args.len >= 1 and axis.args[0] == .ref) {
                const point = entities.get(axis.args[0].ref) orelse return null;
                if (std.mem.eql(u8, point.type_name, "IFCCARTESIANPOINT") and point.args.len >= 1 and point.args[0] == .list) {
                    const coords = point.args[0].list;
                    if (coords.len >= 1) sum.x += numberAsF64(coords[0]) orelse 0;
                    if (coords.len >= 2) sum.y += numberAsF64(coords[1]) orelse 0;
                    if (coords.len >= 3) sum.z += numberAsF64(coords[2]) orelse 0;
                }
            }
        }

        // arg[0] -> parent IfcLocalPlacement (optional / $)
        current = if (placement.args[0] == .ref) placement.args[0].ref else null;
    }

    return sum;
}

fn numberAsF64(v: ArgValue) ?f64 {
    return switch (v) {
        .real => |r| r,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

// ---------------------------------------------------------------------------
