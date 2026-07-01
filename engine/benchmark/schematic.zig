// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Rough building schematic — a top-down SVG plot of each floor showing zone
// labels and placed sensors (colored by sensor type). This is a static data
// visualization (one SVG file, no rendering loop, no GUI), consistent with
// CLAUDE.md §1/§3.5: output is structured data, not a live rendering engine.
//
// Positions come straight from the IFC-resolved Vec3 (ifc_parser.zig's
// IfcLocalPlacement chain) — nothing here invents geometry. IFC convention
// is Z-up, so the floor plan is the X/Y plane; floor_id groups points into
// one panel per storey.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");

/// One sensor marker on the schematic.
pub const SensorPoint = struct {
    x: f64,
    y: f64,
    floor_id: u32,
    sensor_type: sb.SensorType,
};

/// One zone label on the schematic (space/storey name + position).
pub const ZoneLabel = struct {
    name: []const u8,
    x: f64,
    y: f64,
    floor_id: u32,
};

fn colorFor(t: sb.SensorType) []const u8 {
    return switch (t) {
        .temperature => "#f87171",
        .humidity => "#60a5fa",
        .co2 => "#a78bfa",
        .occupancy => "#fbbf24",
        .energy => "#34d399",
        .flow => "#22d3ee",
        .vibration => "#fb923c",
        .structural => "#94a3b8",
        .air_quality => "#c084fc",
    };
}

const Bounds = struct { min_x: f64, max_x: f64, min_y: f64, max_y: f64 };

fn boundsFor(floor_id: u32, sensors: []const SensorPoint, zones: []const ZoneLabel) Bounds {
    var b = Bounds{ .min_x = std.math.floatMax(f64), .max_x = -std.math.floatMax(f64), .min_y = std.math.floatMax(f64), .max_y = -std.math.floatMax(f64) };
    var any = false;
    for (sensors) |s| {
        if (s.floor_id != floor_id) continue;
        any = true;
        b.min_x = @min(b.min_x, s.x);
        b.max_x = @max(b.max_x, s.x);
        b.min_y = @min(b.min_y, s.y);
        b.max_y = @max(b.max_y, s.y);
    }
    for (zones) |z| {
        if (z.floor_id != floor_id) continue;
        any = true;
        b.min_x = @min(b.min_x, z.x);
        b.max_x = @max(b.max_x, z.x);
        b.min_y = @min(b.min_y, z.y);
        b.max_y = @max(b.max_y, z.y);
    }
    if (!any or b.max_x - b.min_x < 1.0) {
        b.min_x -= 5.0;
        b.max_x += 5.0;
    }
    if (!any or b.max_y - b.min_y < 1.0) {
        b.min_y -= 5.0;
        b.max_y += 5.0;
    }
    return b;
}

fn uniqueFloors(allocator: std.mem.Allocator, sensors: []const SensorPoint, zones: []const ZoneLabel) ![]u32 {
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(allocator);
    for (sensors) |s| {
        var found = false;
        for (seen.items) |f| {
            if (f == s.floor_id) {
                found = true;
                break;
            }
        }
        if (!found) try seen.append(allocator, s.floor_id);
    }
    for (zones) |z| {
        var found = false;
        for (seen.items) |f| {
            if (f == z.floor_id) {
                found = true;
                break;
            }
        }
        if (!found) try seen.append(allocator, z.floor_id);
    }
    std.mem.sort(u32, seen.items, {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    return try seen.toOwnedSlice(allocator);
}

const PANEL_W: f64 = 900;
const PANEL_H: f64 = 420;
const MARGIN: f64 = 50;

fn project(v: f64, lo: f64, hi: f64, pixel_lo: f64, pixel_hi: f64) f64 {
    if (hi - lo < 1e-9) return (pixel_lo + pixel_hi) / 2.0;
    return pixel_lo + (v - lo) / (hi - lo) * (pixel_hi - pixel_lo);
}

/// Write `schematic.svg` under `dir_path` (created if missing): one panel
/// per floor, zones as labeled squares, sensors as colored dots. `title`
/// is typically the source IFC filename + building type.
pub fn writeSchematic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    title: []const u8,
    sensors: []const SensorPoint,
    zones: []const ZoneLabel,
) !void {
    const floors = try uniqueFloors(allocator, sensors, zones);
    defer allocator.free(floors);

    const total_h = MARGIN + @as(f64, @floatFromInt(floors.len)) * (PANEL_H + MARGIN);

    var svg: std.ArrayList(u8) = .empty;
    defer svg.deinit(allocator);

    try svg.print(allocator, "<svg viewBox=\"0 0 {d:.0} {d:.0}\" xmlns=\"http://www.w3.org/2000/svg\" font-family=\"monospace\">\n", .{ PANEL_W + 2 * MARGIN, total_h + 60 });
    try svg.print(allocator, "<rect width=\"100%\" height=\"100%\" fill=\"#0f1419\"/>\n", .{});
    try svg.print(allocator, "<text x=\"{d:.0}\" y=\"30\" fill=\"#e6edf3\" font-size=\"18\" font-weight=\"bold\">{s}</text>\n", .{ MARGIN, title });

    for (floors, 0..) |floor_id, idx| {
        const panel_y = MARGIN + 40 + @as(f64, @floatFromInt(idx)) * (PANEL_H + MARGIN);
        const bounds = boundsFor(floor_id, sensors, zones);

        try svg.print(allocator, "<g>\n", .{});
        try svg.print(allocator, "<rect x=\"{d:.0}\" y=\"{d:.0}\" width=\"{d:.0}\" height=\"{d:.0}\" fill=\"#161c24\" stroke=\"#2a3441\" rx=\"6\"/>\n", .{ MARGIN, panel_y, PANEL_W, PANEL_H });
        try svg.print(allocator, "<text x=\"{d:.0}\" y=\"{d:.0}\" fill=\"#8b97a6\" font-size=\"13\">Floor {d}</text>\n", .{ MARGIN + 10, panel_y + 20, floor_id });

        const px_lo = MARGIN + 20;
        const px_hi = MARGIN + PANEL_W - 20;
        const py_lo = panel_y + 35;
        const py_hi = panel_y + PANEL_H - 15;

        for (zones) |z| {
            if (z.floor_id != floor_id) continue;
            const px = project(z.x, bounds.min_x, bounds.max_x, px_lo, px_hi);
            const py = project(z.y, bounds.min_y, bounds.max_y, py_lo, py_hi);
            try svg.print(allocator, "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"10\" height=\"10\" fill=\"none\" stroke=\"#4ea8de\" stroke-width=\"1.5\"/>\n", .{ px - 5, py - 5 });
            try svg.print(allocator, "<text x=\"{d:.1}\" y=\"{d:.1}\" fill=\"#4ea8de\" font-size=\"10\">{s}</text>\n", .{ px + 7, py - 7, z.name });
        }

        for (sensors) |s| {
            if (s.floor_id != floor_id) continue;
            const px = project(s.x, bounds.min_x, bounds.max_x, px_lo, px_hi);
            const py = project(s.y, bounds.min_y, bounds.max_y, py_lo, py_hi);
            try svg.print(allocator, "<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"3.5\" fill=\"{s}\"/>\n", .{ px, py, colorFor(s.sensor_type) });
        }

        try svg.print(allocator, "</g>\n", .{});
    }

    // Legend — sensor types actually present, in enum order.
    const all_types = [_]sb.SensorType{ .temperature, .humidity, .co2, .occupancy, .energy, .flow, .vibration, .structural, .air_quality };
    var legend_x: f64 = MARGIN;
    const legend_y = total_h + 45;
    try svg.print(allocator, "<text x=\"{d:.0}\" y=\"{d:.0}\" fill=\"#8b97a6\" font-size=\"12\">Legend:</text>\n", .{ MARGIN, legend_y - 18 });
    for (all_types) |t| {
        var present = false;
        for (sensors) |s| {
            if (s.sensor_type == t) {
                present = true;
                break;
            }
        }
        if (!present) continue;
        try svg.print(allocator, "<circle cx=\"{d:.0}\" cy=\"{d:.0}\" r=\"4\" fill=\"{s}\"/>\n", .{ legend_x, legend_y, colorFor(t) });
        try svg.print(allocator, "<text x=\"{d:.0}\" y=\"{d:.0}\" fill=\"#e6edf3\" font-size=\"11\">{s}</text>\n", .{ legend_x + 10, legend_y + 4, @tagName(t) });
        legend_x += 110;
    }

    try svg.print(allocator, "</svg>\n", .{});

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "schematic.svg", .data = svg.items });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeSchematic produces a non-empty SVG with one panel per floor" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sensors = [_]SensorPoint{
        .{ .x = 0, .y = 0, .floor_id = 0, .sensor_type = .temperature },
        .{ .x = 5, .y = 5, .floor_id = 0, .sensor_type = .humidity },
        .{ .x = 1, .y = 1, .floor_id = 1, .sensor_type = .energy },
    };
    const zones = [_]ZoneLabel{
        .{ .name = "Room A", .x = 0, .y = 0, .floor_id = 0 },
        .{ .name = "Room B", .x = 1, .y = 1, .floor_id = 1 },
    };

    const dir = "test-schematic-output";
    try writeSchematic(std.testing.allocator, io, dir, "test.ifc", &sensors, &zones);

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, dir ++ "/schematic.svg", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "Floor 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "Floor 1") != null);

    var dir_handle = try cwd.openDir(io, dir, .{});
    dir_handle.close(io);
    cwd.deleteTree(io, dir) catch {};
}
