// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Entry point — Phase 9. Wires the whole pipeline CLAUDE.md §1 describes:
// parse a real IFC file -> place real sensors -> register their real
// zone/floor topology -> generate synthetic readings for those real
// sensors -> benchmark every storage backend against the building's query
// mix -> emit a report. No GUI, no file picker: this is a headless,
// cross-platform CLI tool (Windows/Linux/macOS — only std.fs/std.process,
// nothing OS-specific), invoked as:
//
//   zig build run -- --bim path/to/model.ifc --type Hospital
//
// `--type` selects a profiles.zig BuildingProfile (rules + query mix +
// retention) — itself data, not a code branch (CLAUDE.md §3.5).

const std = @import("std");
const ifc = @import("bim/ifc_parser.zig");
const placer = @import("bim/sensor_placer.zig");
const profiles = @import("bim/profiles.zig");
const synthetic = @import("synthetic/generator.zig");
const sb = @import("ecs/storage/storage_backend.zig");
const World = @import("ecs/world.zig").World;
const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");
const metrics = @import("ecs/systems/metrics_system.zig");
const report = @import("benchmark/report.zig");

const Args = struct {
    bim_path: []const u8,
    building_type: profiles.BuildingType,
    output_dir: []const u8,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: digital-twin --bim <path/to/model.ifc> [--type hospital|office|warehouse|manufacturing|campus] [--out <dir>]
        \\
        \\  --bim   Path to an IFC SPF file to parse and populate sensors from (required).
        \\  --type  Building profile selecting sensor density + query mix (default: office).
        \\  --out   Directory to write benchmark.html/latency.md/latency.json into (default: benchmark-results).
        \\
    , .{});
}

/// `arena` backs every returned string — freed automatically when the
/// process exits (per `std.process.Init.arena`), so callers don't need to
/// free `Args` fields individually.
fn parseArgs(arena: std.mem.Allocator, args: std.process.Args) !Args {
    const argv = try args.toSlice(arena);

    var bim_path: ?[]const u8 = null;
    var building_type: profiles.BuildingType = .office;
    var output_dir: []const u8 = "benchmark-results";

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--bim")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            bim_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            building_type = parseBuildingType(argv[i]) orelse return error.UnknownBuildingType;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            output_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArgument;
        }
    }

    const path = bim_path orelse return error.MissingBimPath;
    return .{ .bim_path = path, .building_type = building_type, .output_dir = output_dir };
}

fn parseBuildingType(raw: []const u8) ?profiles.BuildingType {
    var buf: [32]u8 = undefined;
    const len = @min(raw.len, buf.len);
    for (raw[0..len], 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    return std.meta.stringToEnum(profiles.BuildingType, buf[0..len]);
}

// ---------------------------------------------------------------------------
// Zone -> floor resolution. A zone's floor is the IfcBuildingStorey that
// contains it: storeys ARE floors (floor_id = zone_id); a space's floor is
// found by walking its parent chain up to the nearest storey.
// ---------------------------------------------------------------------------

const ZoneFloor = struct { zone_id: u32, floor_id: u32 };

fn findElement(elements: []const ifc.BuildingElement, id: u32) ?ifc.BuildingElement {
    for (elements) |e| {
        if (e.ifc_id == id) return e;
    }
    return null;
}

fn floorIdForZone(elements: []const ifc.BuildingElement, zone_id: u32, zone_type: ifc.ZoneType) u32 {
    if (zone_type == .storey) return zone_id;
    var current = findElement(elements, zone_id);
    while (current) |el| {
        if (el.element_type == .storey) return el.ifc_id;
        current = if (el.parent_id) |pid| findElement(elements, pid) else null;
    }
    // No containing storey found in the hierarchy — the zone is its own floor.
    return zone_id;
}

fn buildZoneFloorMap(
    allocator: std.mem.Allocator,
    elements: []const ifc.BuildingElement,
    zones: []const ifc.ZoneMetadata,
) ![]ZoneFloor {
    const out = try allocator.alloc(ZoneFloor, zones.len);
    for (zones, 0..) |z, i| {
        out[i] = .{ .zone_id = z.zone_id, .floor_id = floorIdForZone(elements, z.zone_id, z.zone_type) };
    }
    return out;
}

fn floorFor(zone_floor: []const ZoneFloor, zone_id: u32) u32 {
    for (zone_floor) |zf| {
        if (zf.zone_id == zone_id) return zf.floor_id;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Representative real query arguments — sampled from the actual placed
// sensors/zones rather than invented, so every query the benchmark runs is
// exercised against a real sensor_id / zone_id / position from this building.
// ---------------------------------------------------------------------------

const SampleArgs = struct {
    sensor_id: u32,
    sensor_type: sb.SensorType,
    zone_id: u32,
    floor_id: u32,
    position: queries.Vec3,
};

fn pickSample(placement: placer.Placement, zone_floor: []const ZoneFloor) SampleArgs {
    if (placement.sensors.len == 0) {
        return .{ .sensor_id = 0, .sensor_type = .temperature, .zone_id = 0, .floor_id = 0, .position = .{ .x = 0, .y = 0, .z = 0 } };
    }
    const sensor = placement.sensors[0];
    const loc = placement.locations[0];
    return .{
        .sensor_id = sensor.sensor_id,
        .sensor_type = sensor.sensor_type,
        .zone_id = loc.zone_id,
        .floor_id = floorFor(zone_floor, loc.zone_id),
        .position = .{
            .x = @floatCast(loc.position.x),
            .y = @floatCast(loc.position.y),
            .z = @floatCast(loc.position.z),
        },
    };
}

fn queryName(q: profiles.QueryName) []const u8 {
    return switch (q) {
        .avg_window => "query_avg_window",
        .avg_zone_type => "query_avg_zone_type",
        .floor_stats => "query_floor_stats",
        .hourly_rollup => "query_hourly_rollup",
        .daily_zone_rollup => "query_daily_zone_rollup",
        .spatial_radius => "query_spatial_radius",
        .zone_hierarchy => "query_zone_hierarchy",
        .anomalies => "query_anomalies",
        .threshold_breach => "query_threshold_breach",
        .latest_single => "query_latest_single",
        .latest_zone => "query_latest_zone",
        .latest_by_type => "query_latest_by_type",
    };
}

fn isHistorical(q: profiles.QueryName) bool {
    return q == .hourly_rollup or q == .daily_zone_rollup;
}

/// Minimum iteration count per CLAUDE.md §3.4.
const ITERATIONS: u32 = 25;
const ONE_HOUR_MS: i64 = 60 * 60 * 1000;

fn runOne(
    world: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: profiles.QueryName,
    sample: SampleArgs,
) !metrics.LatencyStats {
    return switch (query) {
        .avg_window => try metrics.timeQuery(allocator, io, ITERATIONS, queries.query_avg_window, .{ world, sample.sensor_id, @as(u32, 24) }),
        .latest_single => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q1_wrapper, .{ world, sample.sensor_id }),
        .latest_zone => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q2_wrapper, .{ world, sample.zone_id }),
        .latest_by_type => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q3_wrapper, .{ world, sample.sensor_type }),
        .avg_zone_type => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q5_wrapper, .{ world, sample.zone_id, sample.sensor_type, @as(u32, 24) }),
        .floor_stats => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q6_wrapper, .{ world, sample.floor_id, sample.sensor_type, @as(u32, 24) }),
        .hourly_rollup => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q7_wrapper, .{ world, sample.sensor_id, @as(u32, 2) }),
        .daily_zone_rollup => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q8_wrapper, .{ world, sample.zone_id, sample.sensor_type }),
        .spatial_radius => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q9_wrapper, .{ world, sample.position, @as(f32, 50.0) }),
        .zone_hierarchy => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q10_wrapper, .{ world, sample.zone_id, @as(u32, 2) }),
        .anomalies => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q11_wrapper, .{ world, sample.sensor_type, @as(f32, 1.0) }),
        .threshold_breach => try metrics.timeQuery(allocator, io, ITERATIONS, runner.q12_wrapper, .{
            world, sample.sensor_id, synthetic.profileFor(sample.sensor_type).base_value, ONE_HOUR_MS,
        }),
    };
}

fn benchProfile(
    comptime b: runner.BackendEntry,
    comptime historical_supported: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    readings: []const sb.SensorReading,
    locations: []const placer.ZoneLocation,
    zone_floor: []const ZoneFloor,
    profile: profiles.BuildingProfile,
    sample: SampleArgs,
    scale_label: []const u8,
    rows: *std.ArrayList(report.RunRow),
) !void {
    var world = try World(b.T).init(allocator);
    defer world.deinit();

    for (readings) |r| try world.insert(r);
    for (locations) |loc| try world.registerZone(loc.sensor_id, loc.zone_id);
    for (zone_floor) |zf| try world.registerFloor(zf.zone_id, zf.floor_id);

    for (profile.query_mix) |qw| {
        if (!historical_supported and isHistorical(qw.query)) continue;

        const stats = try runOne(&world, allocator, io, qw.query, sample);
        try rows.append(allocator, .{
            .scale = scale_label,
            .query = queryName(qw.query),
            .backend = b.name,
            .memory_bytes = world.memoryUsed(),
            .stats = stats,
        });
    }
}

fn isSupported(comptime b: runner.BackendEntry) bool {
    for (runner.supported_backends) |sup| {
        if (std.mem.eql(u8, sup.name, b.name)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = parseArgs(init.arena.allocator(), init.minimal.args) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage();
            return;
        },
        else => {
            printUsage();
            return err;
        },
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(io, args.bim_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(source);

    var model = try ifc.parseSlice(allocator, source);
    defer model.deinit();

    std.debug.print(
        "Parsed {s}: {d} elements, {d} zones, {d} equipment items.\n",
        .{ args.bim_path, model.building_elements.len, model.zones.len, model.equipment.len },
    );

    const profile = profiles.getProfile(args.building_type);

    var placement = try placer.place(allocator, model.building_elements, model.zones, .{ .rules = profile.rules });
    defer placement.deinit();

    std.debug.print("Placed {d} sensors.\n", .{placement.sensors.len});
    if (placement.sensors.len == 0) {
        std.debug.print("No sensors placed (no elements matched the profile's rules) — nothing to benchmark.\n", .{});
        return;
    }

    // 1h of synthetic data (generator's own default duration) — real
    // building/profile combinations can place high-frequency sensors
    // (hospital equipment samples at 5-10 Hz) on hundreds of elements, so a
    // longer fixed window risks generating hundreds of millions of readings.
    const readings = try synthetic.generate(allocator, placement.sensors, .{});
    defer allocator.free(readings);
    std.debug.print("Generated {d} synthetic readings.\n", .{readings.len});

    const zone_floor = try buildZoneFloorMap(allocator, model.building_elements, model.zones);
    defer allocator.free(zone_floor);

    const sample = pickSample(placement, zone_floor);

    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(allocator);

    const scale_label = @tagName(args.building_type);

    inline for (runner.backends) |b| {
        try benchProfile(
            b,
            isSupported(b),
            allocator,
            io,
            readings,
            placement.locations,
            zone_floor,
            profile,
            sample,
            scale_label,
            &rows,
        );
    }

    const recommendation = try report.recommendBackend(allocator, rows.items, scale_label, profile);
    defer allocator.free(recommendation.scores);

    std.debug.print("\n=== Recommendation ({s} profile) ===\n", .{scale_label});
    std.debug.print("{s:<15} {s:>10} {s:>12}\n", .{ "Backend", "Score", "Coverage" });
    for (recommendation.scores) |s| {
        std.debug.print("{s:<15} {d:>10.3} {d:>11.0}%\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    std.debug.print("Winner: {s} (lowest weighted median across this building's query mix; 1.0 = won every query)\n", .{recommendation.winner});

    try writeRecommendationReport(allocator, io, args.output_dir, args.bim_path, scale_label, model, placement, recommendation);
    std.debug.print("Wrote recommendation.md to {s}/\n", .{args.output_dir});
}

fn writeRecommendationReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    bim_path: []const u8,
    scale_label: []const u8,
    model: ifc.ParsedModel,
    placement: placer.Placement,
    recommendation: report.Recommendation,
) !void {
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(allocator);

    try md.print(allocator, "# Digital Twin — Storage Recommendation\n\n", .{});
    try md.print(allocator, "- Source IFC: `{s}`\n", .{bim_path});
    try md.print(allocator, "- Building profile: `{s}`\n", .{scale_label});
    try md.print(allocator, "- Elements: {d} | Zones: {d} | Equipment: {d} | Sensors placed: {d}\n\n", .{
        model.building_elements.len, model.zones.len, model.equipment.len, placement.sensors.len,
    });
    try md.print(allocator, "> Honesty headline: relative rankings are reliable; absolute numbers are approximate (CLAUDE.md §6).\n\n", .{});
    try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
    for (recommendation.scores) |s| {
        try md.print(allocator, "| {s} | {d:.3} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    try md.print(allocator, "\n**Winner: {s}**\n", .{recommendation.winner});

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, output_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "recommendation.md", .data = md.items });
}
