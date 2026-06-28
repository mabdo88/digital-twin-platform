// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Task 4.4 — validate the hand-rolled IFC parser against real exported files.
//
// The synthetic fixtures in ifc_parser.zig prove the parser handles the
// constructs we wrote ourselves. Those tests don't catch vendor-specific
// quirks: stray characters, oversized comments, unusual whitespace, entity
// types we hadn't seen, header sections we hadn't anticipated. This file
// runs the full parse + placement pipeline against the two real IFC2x3
// models in assets/IFC/ — both Revit 2021 exports.
//
// Both files were dropped into the repo by the user; if a future contributor
// removes them, every test here degrades to a "file not found, skipped" log
// rather than a hard failure. The synthetic tests are the ground truth; this
// is a confidence check on top.

const std = @import("std");
const testing = std.testing;
const ifc = @import("ifc_parser.zig");
const placer = @import("sensor_placer.zig");

const FILES = [_][]const u8{
    "assets/IFC/2KHRJ17-CUN-TD-712-EL-MOD-00001-00-IFC.ifc",
    "assets/IFC/2KHRJ17-HASC-SD-710-EV-MOD-00001.ifc",
};

/// Load a file relative to cwd via the Io API the rest of the platform uses.
/// Returns null when the file isn't present (skip-friendly) and propagates
/// the error otherwise.
fn tryLoadIfc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

test "real IFC: both Revit-exported files parse and place sensors without error" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var any_seen = false;

    for (FILES) |path| {
        const source = (try tryLoadIfc(testing.allocator, io, path)) orelse {
            std.debug.print("skip: {s} not present\n", .{path});
            continue;
        };
        defer testing.allocator.free(source);
        any_seen = true;

        var model = try ifc.parseSlice(testing.allocator, source);
        defer model.deinit();

        // Sanity: the parser found SOMETHING and the file actually has a
        // building hierarchy in it (Revit always emits an IfcBuilding).
        try testing.expect(model.entities.count() > 0);

        var buildings: usize = 0;
        var storeys: usize = 0;
        var spaces: usize = 0;
        var flow_segments: usize = 0;
        var beams: usize = 0;
        var walls: usize = 0;
        var slabs: usize = 0;
        var equipment_count: usize = 0;
        for (model.building_elements) |e| {
            switch (e.element_type) {
                .building => buildings += 1,
                .storey => storeys += 1,
                .space => spaces += 1,
                .flow_segment => flow_segments += 1,
                .beam => beams += 1,
                .wall => walls += 1,
                .slab => slabs += 1,
                .equipment => equipment_count += 1,
                else => {},
            }
        }

        std.debug.print(
            "\n{s}\n  entities: {d}\n  elements: {d} (buildings={d} storeys={d} spaces={d} walls={d} slabs={d} beams={d} flow_segments={d} equipment={d})\n  zones: {d}\n  equipment metadata: {d}\n",
            .{
                path,
                model.entities.count(),
                model.building_elements.len,
                buildings, storeys, spaces, walls, slabs, beams, flow_segments, equipment_count,
                model.zones.len,
                model.equipment.len,
            },
        );

        // Every .equipment BuildingElement must have a matching
        // EquipmentMetadata row (always emitted, even if manufacturer/model
        // end up "" — see components.zig's EquipmentMetadata doc comment).
        try testing.expectEqual(equipment_count, model.equipment.len);

        // Confidence check: the property-set walk should find REAL data on
        // a real file, not just default to "" for everything (which would
        // mean the IfcRelDefinesByProperties chain silently isn't matching
        // anything despite compiling cleanly).
        var with_manufacturer: usize = 0;
        var with_model: usize = 0;
        for (model.equipment) |eq| {
            if (eq.manufacturer.len > 0) with_manufacturer += 1;
            if (eq.model.len > 0) with_model += 1;
        }
        std.debug.print("  equipment with manufacturer: {d}/{d}, with model: {d}/{d}\n", .{
            with_manufacturer, model.equipment.len, with_model, model.equipment.len,
        });
        if (model.equipment.len > 0) {
            try testing.expect(with_manufacturer > 0 or with_model > 0);
        }

        try testing.expect(buildings >= 1);
        try testing.expect(storeys >= 1);

        // Every parent_id we emit must resolve to an entity we actually
        // parsed — otherwise the hierarchy is half-baked and downstream
        // systems would chase null refs.
        for (model.building_elements) |e| {
            if (e.parent_id) |pid| {
                try testing.expect(model.entities.contains(pid));
            }
        }

        // Positions should be finite. NaN/Inf from a malformed placement
        // would silently poison spatial queries later.
        for (model.building_elements) |e| {
            try testing.expect(std.math.isFinite(e.position.x));
            try testing.expect(std.math.isFinite(e.position.y));
            try testing.expect(std.math.isFinite(e.position.z));
        }

        // Placement: with DEFAULT_RULES and the 100 m² area fallback, every
        // matching element produces at least one sensor of each type. These
        // electrical/services models lean heavily on flow_segments and have
        // few spaces — but `>=1` is the right floor: the placer should not
        // silently produce zero sensors on a real building.
        var p = try placer.place(testing.allocator, model.building_elements, model.zones, .{});
        defer p.deinit();

        std.debug.print("  sensors placed: {d}\n", .{p.sensors.len});

        const matching = spaces + flow_segments + beams + equipment_count;
        if (matching > 0) {
            try testing.expect(p.sensors.len >= matching);

            // sensor_ids dense and monotonic.
            for (p.sensors, 0..) |s, i| {
                try testing.expectEqual(@as(u32, @intCast(i)), s.sensor_id);
            }
            try testing.expectEqual(p.sensors.len, p.locations.len);
        }
    }

    // At least one real file should have been present — otherwise the test
    // is silently a no-op and the validation guarantee is hollow.
    try testing.expect(any_seen);
}
