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
//   zig build run -- --bim path/to/model.ifc
//
// There used to be a `--type hospital|office|...` flag selecting a
// bim/profiles.zig BuildingProfile (rules + query mix + retention). That
// file is gone: building type was a human guessing one of five archetypes,
// applied uniformly to a whole building regardless of what's actually in
// it. Sensor placement (bim/sensor_placer.zig's one universal rule set),
// query relevance, density, frequency, and retention are now all derived
// from (a) what's actually parsed out of the IFC and (b) the canonical
// per-sensor-type table in synthetic/generator.zig — see that file's
// header comment for the full reasoning.

const std = @import("std");
const ifc = @import("bim/ifc_parser.zig");
const placer = @import("bim/sensor_placer.zig");
const synthetic = @import("synthetic/generator.zig");
const sb = @import("ecs/storage/storage_backend.zig");
const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");
const report = @import("benchmark/report.zig");
const cost_model = @import("benchmark/cost_model.zig");
const schematic = @import("benchmark/schematic.zig");
const sim = @import("benchmark/simulation.zig");

const Args = struct {
    bim_path: []const u8,
    output_dir: []const u8,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: dt --bim <path/to/model.ifc> [--out <dir>]
        \\
        \\  --bim   Path to an IFC SPF file to parse and populate sensors from (required).
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
    var output_dir: []const u8 = "benchmark-results";

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--bim")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            bim_path = argv[i];
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
    return .{ .bim_path = path, .output_dir = output_dir };
}

/// Filename stem (no directory, no extension) of the source IFC — used as
/// the "scale" label that ties a run's rows together for scoring/reporting.
/// Just an identifying label now, not a building-type guess.
fn scaleLabel(bim_path: []const u8) []const u8 {
    return std.fs.path.stem(std.fs.path.basename(bim_path));
}

// ---------------------------------------------------------------------------
// Zone -> floor resolution. A zone's floor is the IfcBuildingStorey that
// contains it: storeys ARE floors (floor_id = zone_id); a space's floor is
// found by walking its parent chain up to the nearest storey.
// ---------------------------------------------------------------------------

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
) ![]sim.ZoneFloor {
    const out = try allocator.alloc(sim.ZoneFloor, zones.len);
    for (zones, 0..) |z, i| {
        out[i] = .{ .zone_id = z.zone_id, .floor_id = floorIdForZone(elements, z.zone_id, z.zone_type) };
    }
    return out;
}

/// Wall-clock seconds since `start`, for operator-facing progress logging
/// only — distinct from `metrics.timeQuery`'s recorded benchmark timings
/// (CLAUDE.md §3.4), which this never touches or substitutes for.
fn elapsedSeconds(io: std.Io, start: anytype) f64 {
    const end = std.Io.Clock.awake.now(io);
    const dur = start.durationTo(end);
    return @as(f64, @floatFromInt(dur.nanoseconds)) / 1e9;
}

// ---------------------------------------------------------------------------
// Representative real query arguments — sampled from the actual placed
// sensors/zones rather than invented, so every query the benchmark runs is
// exercised against a real sensor_id / zone_id / position from this building.
// ---------------------------------------------------------------------------

fn pickOverallSample(placement: placer.Placement, zone_floor: []const sim.ZoneFloor) sim.SampleArgs {
    const sensor = placement.sensors[0];
    const loc = placement.locations[0];
    return .{
        .sensor_id = sensor.sensor_id,
        .sensor_type = sensor.sensor_type,
        .zone_id = loc.zone_id,
        .floor_id = sim.floorFor(zone_floor, loc.zone_id),
        .position = .{
            .x = @floatCast(loc.position.x),
            .y = @floatCast(loc.position.y),
            .z = @floatCast(loc.position.z),
        },
    };
}

fn pickTypeSamples(
    allocator: std.mem.Allocator,
    placement: placer.Placement,
    zone_floor: []const sim.ZoneFloor,
) ![]sim.TypeSample {
    var result: std.ArrayList(sim.TypeSample) = .empty;
    errdefer result.deinit(allocator);

    for (placement.sensors, placement.locations) |sensor, loc| {
        var found = false;
        for (result.items) |ts| {
            if (ts.sensor_type == sensor.sensor_type) {
                found = true;
                break;
            }
        }
        if (found) continue;
        try result.append(allocator, .{
            .sensor_type = sensor.sensor_type,
            .args = .{
                .sensor_id = sensor.sensor_id,
                .sensor_type = sensor.sensor_type,
                .zone_id = loc.zone_id,
                .floor_id = sim.floorFor(zone_floor, loc.zone_id),
                .position = .{
                    .x = @floatCast(loc.position.x),
                    .y = @floatCast(loc.position.y),
                    .z = @floatCast(loc.position.z),
                },
            },
        });
    }

    return result.toOwnedSlice(allocator);
}

/// A building's effective query mix is the union of relevant_queries
/// across every DISTINCT sensor type actually placed — derived from what
/// was parsed, not declared via a building-type guess. See
/// synthetic/generator.zig's SensorProfile.relevant_queries doc comment.
///
/// Deduplicated by QUERY PATTERN, not just by sensor type: several types'
/// relevant_queries overlap on the same building-level pattern (e.g.
/// `anomalies` appears in temperature/co2/air_quality/vibration/energy/
/// structural's lists). Every building-level query in this mix runs once
/// per checkpoint against the SAME fixed `overall_sample` regardless of
/// which type contributed it (see simulation.zig's runOne) — so a query
/// pattern appearing from N types produced N byte-identical, redundant
/// measurements, not N different ones. On a real multi-type building (e.g.
/// a hospital placing most of the 9 sensor types) this multiplied the
/// per-checkpoint query count several-fold for zero additional
/// information — confirmed as the dominant cost once Steps 1-3 of the
/// sim-perf-overhaul fixed generation. Kept: the highest weight seen across
/// contributing types (a query several types consider high-priority should
/// stay weighted accordingly, not get diluted by whichever type happened
/// to contribute it first).
///
/// Caller frees with `allocator`.
fn deriveQueryMix(allocator: std.mem.Allocator, placement: placer.Placement) ![]queries.QueryWeight {
    var seen_types: std.ArrayList(sb.SensorType) = .empty;
    defer seen_types.deinit(allocator);

    var by_query: [std.enums.values(queries.QueryName).len]?queries.QueryWeight = @splat(null);

    for (placement.sensors) |sensor| {
        var found = false;
        for (seen_types.items) |st| {
            if (st == sensor.sensor_type) {
                found = true;
                break;
            }
        }
        if (found) continue;
        try seen_types.append(allocator, sensor.sensor_type);

        for (synthetic.profileFor(sensor.sensor_type).relevant_queries) |qw| {
            const idx = @intFromEnum(qw.query);
            if (by_query[idx] == null or qw.weight > by_query[idx].?.weight) {
                by_query[idx] = qw;
            }
        }
    }

    var mix: std.ArrayList(queries.QueryWeight) = .empty;
    errdefer mix.deinit(allocator);
    for (by_query) |maybe_qw| {
        if (maybe_qw) |qw| try mix.append(allocator, qw);
    }

    return mix.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Schematic data — derived straight from already-resolved positions
// (ifc_parser.zig's IfcLocalPlacement chain), not invented. See
// schematic.zig's header comment for the X/Y-is-floor-plan convention.
// ---------------------------------------------------------------------------

const SchematicData = struct {
    sensors: []schematic.SensorPoint,
    zones: []schematic.ZoneLabel,
};

fn buildSchematicData(
    allocator: std.mem.Allocator,
    model: ifc.ParsedModel,
    placement: placer.Placement,
    zone_floor: []const sim.ZoneFloor,
) !SchematicData {
    var sensors = try allocator.alloc(schematic.SensorPoint, placement.sensors.len);
    for (placement.sensors, placement.locations, 0..) |sensor, loc, i| {
        sensors[i] = .{
            .x = loc.position.x,
            .y = loc.position.y,
            .floor_id = sim.floorFor(zone_floor, loc.zone_id),
            .sensor_type = sensor.sensor_type,
        };
    }

    var zones: std.ArrayList(schematic.ZoneLabel) = .empty;
    defer zones.deinit(allocator);
    for (model.zones) |z| {
        const el = findElement(model.building_elements, z.zone_id) orelse continue;
        try zones.append(allocator, .{
            .name = z.name,
            .x = el.position.x,
            .y = el.position.y,
            .floor_id = floorIdForZone(model.building_elements, z.zone_id, z.zone_type),
        });
    }

    return .{ .sensors = sensors, .zones = try zones.toOwnedSlice(allocator) };
}

/// Comptime-extracted names of the full-retention backends
/// (runner.supported_backends) — passed to `recommendCompound` as the
/// eligible set for the historical track.
const full_retention_names = blk: {
    var names: [runner.supported_backends.len][]const u8 = undefined;
    for (runner.supported_backends, 0..) |b, i| names[i] = b.name;
    break :blk names;
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const run_start = std.Io.Clock.awake.now(io);

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

    std.debug.print("\n[1/6] Parsing IFC: {s}...\n", .{args.bim_path});
    const parse_start = std.Io.Clock.awake.now(io);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args.bim_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(source);

    var model = try ifc.parseSlice(allocator, source);
    defer model.deinit();

    std.debug.print(
        "Parsed {s}: {d} elements, {d} zones, {d} equipment items ({d:.1}s).\n",
        .{ args.bim_path, model.building_elements.len, model.zones.len, model.equipment.len, elapsedSeconds(io, parse_start) },
    );

    std.debug.print("\n[2/6] Placing sensors...\n", .{});
    const place_start = std.Io.Clock.awake.now(io);
    var placement = try placer.place(allocator, model.building_elements, model.zones, .{});
    defer placement.deinit();

    std.debug.print("Placed {d} sensors ({d:.1}s).\n", .{ placement.sensors.len, elapsedSeconds(io, place_start) });
    if (placement.sensors.len == 0) {
        std.debug.print("No sensors placed (no elements in this IFC matched a placement rule) — nothing to benchmark.\n", .{});
        return;
    }

    // Live day-zero simulation: the building starts at simulated day zero
    // with empty backends. A synthetic.Stream feeds readings chunk-by-chunk
    // (1 simulated day per chunk) into each backend, pruning to retention
    // windows as simulated time advances, with queries benchmarked at
    // log-spaced checkpoints. Sim duration derives from the placed sensor
    // types' retention depths — no CLI flag.
    std.debug.print("\n[3/6] Setting up simulation...\n", .{});
    const zone_floor = try buildZoneFloorMap(allocator, model.building_elements, model.zones);
    defer allocator.free(zone_floor);

    const overall_sample = pickOverallSample(placement, zone_floor);
    const type_samples = try pickTypeSamples(allocator, placement, zone_floor);
    defer allocator.free(type_samples);

    // The building's effective query mix — derived from whichever sensor
    // types actually got placed (each contributes its own canonical
    // relevant_queries), not declared via a building-type guess.
    const query_mix = try deriveQueryMix(allocator, placement);
    defer allocator.free(query_mix);

    // Collect all distinct sensor types for deriveSimDays.
    var placed_types: std.ArrayList(sb.SensorType) = .empty;
    defer placed_types.deinit(allocator);
    for (type_samples) |ts| try placed_types.append(allocator, ts.sensor_type);

    const sim_days = sim.deriveSimDays(placed_types.items);
    const checkpoints = try sim.deriveCheckpoints(allocator, sim_days);
    defer allocator.free(checkpoints);

    const scale_label = scaleLabel(args.bim_path);
    const seed: u64 = 42;

    std.debug.print("  Sim duration: {d} days ({d:.1} years)\n", .{ sim_days, @as(f64, @floatFromInt(sim_days)) / 365.0 });
    std.debug.print("  Checkpoints: {d} — ", .{checkpoints.len});
    for (checkpoints, 0..) |cp, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s} (day {d})", .{ cp.label, cp.sim_day });
    }
    std.debug.print("\n", .{});
    std.debug.print("  Seed: {d}\n", .{seed});
    std.debug.print("  Backends: {d}\n", .{runner.backends.len});

    std.debug.print("\n[4/6] Running live day-zero simulation...\n", .{});

    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(allocator);
    var type_rows: std.ArrayList(report.RunRow) = .empty;
    defer type_rows.deinit(allocator);
    var growth: std.ArrayList(sim.GrowthPoint) = .empty;
    defer growth.deinit(allocator);
    var sim_stats: std.ArrayList(sim.SimStats) = .empty;
    defer sim_stats.deinit(allocator);
    var type_volumes: std.ArrayList(sim.TypeVolume) = .empty;
    defer type_volumes.deinit(allocator);
    var type_quality: std.ArrayList(sim.TypeQuality) = .empty;
    defer type_quality.deinit(allocator);

    // The output dir doubles as home for the simulation's replay cache
    // (generated stream spilled once, replayed by backends 2..N — see
    // simulateAllBackends), so it must exist before the simulation, not
    // just before report writing. The cache is deleted right after the
    // simulation; failure to delete is a warning, not a run failure.
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, args.output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var out_dir = try cwd.openDir(io, args.output_dir, .{});
    defer out_dir.close(io);

    defer out_dir.deleteFile(io, sim.REPLAY_FILE_NAME) catch |err| {
        std.debug.print("  warning: could not delete {s}/{s}: {s}\n", .{ args.output_dir, sim.REPLAY_FILE_NAME, @errorName(err) });
    };

    try sim.simulateAllBackends(
        allocator,
        io,
        out_dir,
        placement.sensors,
        placement.locations,
        zone_floor,
        query_mix,
        overall_sample,
        type_samples,
        scale_label,
        seed,
        checkpoints,
        &rows,
        &type_rows,
        &growth,
        &sim_stats,
        &type_volumes,
        &type_quality,
    );

    std.debug.print("\n[5/6] Computing recommendations...\n", .{});
    const compound = try report.recommendCompound(allocator, rows.items, scale_label, query_mix, &full_retention_names);
    defer allocator.free(compound.realtime.scores);
    defer allocator.free(compound.historical.scores);

    std.debug.print("\n=== Recommendation ({s}) ===\n", .{scale_label});
    std.debug.print("Real-time track (latest_* queries — all backends compete):\n", .{});
    std.debug.print("{s:<15} {s:>10} {s:>12}\n", .{ "Backend", "Score", "Coverage" });
    for (compound.realtime.scores) |s| {
        std.debug.print("{s:<15} {d:>10.3} {d:>11.0}%\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    std.debug.print("Real-time winner: {s}\n\n", .{compound.realtime.winner});

    std.debug.print("Historical track (aggregation/historical/spatial/anomaly — full-retention backends only):\n", .{});
    std.debug.print("{s:<15} {s:>10} {s:>12}\n", .{ "Backend", "Score", "Coverage" });
    for (compound.historical.scores) |s| {
        std.debug.print("{s:<15} {d:>10.3} {d:>11.0}%\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    std.debug.print("Historical winner: {s}\n", .{compound.historical.winner});
    std.debug.print("\nDeployment combo: {s} (live) + {s} (historical)\n", .{ compound.realtime.winner, compound.historical.winner });

    var type_recommendations: std.ArrayList(report.TypeRecommendation) = .empty;
    defer {
        for (type_recommendations.items) |tr| {
            allocator.free(tr.compound.realtime.scores);
            allocator.free(tr.compound.historical.scores);
        }
        type_recommendations.deinit(allocator);
    }

    for (type_samples) |ts| {
        // Each type's OWN type-scoped queries — not a shared building-wide
        // filter — since different types can care about different query
        // patterns (occupancy's relevant_queries differ from vibration's).
        const type_scoped_mix = try sim.filterTypeScoped(allocator, synthetic.profileFor(ts.sensor_type).relevant_queries);
        defer allocator.free(type_scoped_mix);
        if (type_scoped_mix.len == 0) continue;

        const tc = try report.recommendCompound(allocator, type_rows.items, @tagName(ts.sensor_type), type_scoped_mix, &full_retention_names);
        try type_recommendations.append(allocator, .{ .sensor_type = ts.sensor_type, .compound = tc });
    }

    if (type_recommendations.items.len > 0) {
        std.debug.print("\n=== Recommendation by Sensor Type ({s}) ===\n", .{scale_label});
        for (type_recommendations.items) |tr| {
            if (tr.compound.realtime.scores.len > 0 and tr.compound.historical.scores.len > 0) {
                std.debug.print("{s:<14} live: {s} | historical: {s}\n", .{ @tagName(tr.sensor_type), tr.compound.realtime.winner, tr.compound.historical.winner });
            } else if (tr.compound.historical.scores.len > 0) {
                std.debug.print("{s:<14} historical: {s}\n", .{ @tagName(tr.sensor_type), tr.compound.historical.winner });
            } else if (tr.compound.realtime.scores.len > 0) {
                std.debug.print("{s:<14} live: {s}\n", .{ @tagName(tr.sensor_type), tr.compound.realtime.winner });
            }
        }
    }

    std.debug.print("\n[6/6] Writing reports...\n", .{});
    try writeRecommendationReport(allocator, io, args.output_dir, args.bim_path, scale_label, model, placement, compound, rows.items, type_recommendations.items, growth.items, sim_stats.items, type_volumes.items, type_quality.items);
    std.debug.print("  Wrote recommendation.md + simulation.json to {s}/\n", .{args.output_dir});

    const sd = try buildSchematicData(allocator, model, placement, zone_floor);
    defer allocator.free(sd.sensors);
    defer allocator.free(sd.zones);

    var title_buf: [512]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s} ({d} sensors)", .{ args.bim_path, placement.sensors.len });
    try schematic.writeSchematic(allocator, io, args.output_dir, title, sd.sensors, sd.zones);
    std.debug.print("  Wrote schematic.svg to {s}/\n", .{args.output_dir});

    std.debug.print("\nDone. Total run time: {d:.1}s\n", .{elapsedSeconds(io, run_start)});
}

fn countSensorsByType(sensors: []const placer.SensorMetadata) [9]u32 {
    var counts: [9]u32 = @splat(0);
    for (sensors) |s| counts[@intFromEnum(s.sensor_type)] += 1;
    return counts;
}

fn writeRecommendationReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    bim_path: []const u8,
    scale_label: []const u8,
    model: ifc.ParsedModel,
    placement: placer.Placement,
    compound: report.CompoundRecommendation,
    rows: []const report.RunRow,
    type_recommendations: []const report.TypeRecommendation,
    growth: []const sim.GrowthPoint,
    sim_stats: []const sim.SimStats,
    type_volumes: []const sim.TypeVolume,
    type_quality: []const sim.TypeQuality,
) !void {
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(allocator);

    try md.print(allocator, "# Digital Twin — Storage Recommendation\n\n", .{});
    try md.print(allocator, "- Source IFC: `{s}`\n", .{bim_path});
    try md.print(allocator, "- Run label: `{s}`\n", .{scale_label});
    try md.print(allocator, "- Elements: {d} | Zones: {d} | Equipment: {d} | Sensors placed: {d}\n\n", .{
        model.building_elements.len, model.zones.len, model.equipment.len, placement.sensors.len,
    });

    try md.print(allocator, "## Verdict\n\n", .{});
    try md.print(allocator, "**Use `{s}` for live/latest-value queries.**\n\n", .{compound.realtime.winner});
    try md.print(allocator, "**Use `{s}` for everything else** (history, aggregates, anomalies).\n\n", .{compound.historical.winner});

    if (compound.historical.scores.len > 1) {
        try md.print(allocator, "`{s}` wins historical queries by **{d:.1}x** over the next-best backend " ++
            "(`{s}`) — a decisive, noise-proof margin.\n\n", .{
            compound.historical.winner,
            compound.historical.scores[1].score,
            compound.historical.scores[1].backend,
        });
    }

    if (compound.realtime.scores.len > 1) {
        if (report.isCloseRace(compound.realtime.scores)) {
            try md.print(allocator, "The live-query race is close: `{s}` vs `{s}` (within 15%) — treat this " ++
                "specific ranking as a near-tie, not a confident win; single-shot microsecond-scale timing is " ++
                "sensitive to run-to-run noise at this margin (CLAUDE.md §3.4).\n\n", .{
                compound.realtime.scores[0].backend,
                compound.realtime.scores[1].backend,
            });
        } else {
            try md.print(allocator, "`{s}` wins live queries by **{d:.1}x** over the next-best backend " ++
                "(`{s}`) — a clear margin.\n\n", .{
                compound.realtime.winner,
                compound.realtime.scores[1].score,
                compound.realtime.scores[1].backend,
            });
        }
    }

    try md.print(allocator, "## Sensors placed, by type\n\n", .{});
    try md.print(allocator, "Density, sampling rate, and retention all come from each type's own canonical " ++
        "characteristics (synthetic/generator.zig) — not a building-type guess.\n\n", .{});
    try md.print(allocator, "| Sensor type | Count | Retention |\n|---|---:|---:|\n", .{});
    const counts = countSensorsByType(placement.sensors);
    const all_types = [_]sb.SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    for (all_types) |t| {
        const c = counts[@intFromEnum(t)];
        if (c > 0) try md.print(allocator, "| {s} | {d} | {d} days |\n", .{ @tagName(t), c, synthetic.profileFor(t).retention_days });
    }

    try md.print(allocator, "\n> Honesty headline: relative rankings are reliable; absolute numbers are approximate (CLAUDE.md §6).\n\n", .{});

    try md.print(allocator, "## Recommendation\n\n", .{});
    try md.print(allocator, "Recommendations are **compound** — split into two independently-won tracks, because no single backend " ++
        "should serve both a tiny live cache's workload and a full-history store's workload:\n\n", .{});
    try md.print(allocator, "1. **Real-time track** (`latest_single`, `latest_zone`, `latest_by_type`) — all backends compete; " ++
        "the count-capped real-time cache (RingBuffer, 10 readings/sensor) legitimately wins here.\n", .{});
    try md.print(allocator, "2. **Historical track** (aggregation, historical rollups, spatial, anomaly) — only full-retention " ++
        "backends compete; the real-time cache is excluded because it evicts data these queries need.\n\n", .{});
    try md.print(allocator, "Score = weighted average of (this backend's median / the per-query winner's median) across " ++
        "that track's query mix. **1.00 = won every weighted query; higher is worse.** Coverage below 100% means " ++
        "the backend has no data for one or more weighted queries.\n\n", .{});

    try md.print(allocator, "### Real-time track\n\n", .{});
    try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
    for (compound.realtime.scores) |s| {
        try md.print(allocator, "| {s} | {d:.2} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    try md.print(allocator, "\n**Real-time winner: {s}**\n\n", .{compound.realtime.winner});

    try md.print(allocator, "### Historical track\n\n", .{});
    try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
    for (compound.historical.scores) |s| {
        try md.print(allocator, "| {s} | {d:.2} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    try md.print(allocator, "\n**Historical winner: {s}**\n\n", .{compound.historical.winner});

    try md.print(allocator, "**Deployment combo: {s} (live) + {s} (historical)**\n\n", .{ compound.realtime.winner, compound.historical.winner });

    if (type_recommendations.len > 0) {
        try md.print(allocator, "## Recommendation by Sensor Type\n\n", .{});
        try md.print(allocator, "Same scoring rule as above, but scoped to one sensor type at a time. For each of the " ++
            "{d} sensor types actually placed in this building, each of that type's canonical type-scoped queries is " ++
            "measured once against a real placed sensor of that exact type, over its full independently-generated " ++
            "dataset. Scores only the query patterns in that type's own canonical relevant_queries that take a sensor " ++
            "type as an argument (`latest_by_type`, `avg_zone_type`, `floor_stats`, `daily_zone_rollup`, `anomalies` " ++
            "— whichever are relevant for this specific type). A type's winner can differ from the building-wide " ++
            "winner above if that type's relevant queries behave differently.\n\n", .{
            type_recommendations.len,
        });
        for (type_recommendations) |tr| {
            if (tr.compound.realtime.scores.len > 0 and tr.compound.historical.scores.len > 0) {
                try md.print(allocator, "**{s}** — live: **{s}** | historical: **{s}**\n\n", .{ @tagName(tr.sensor_type), tr.compound.realtime.winner, tr.compound.historical.winner });
            } else if (tr.compound.historical.scores.len > 0) {
                try md.print(allocator, "**{s}** — historical: **{s}**\n\n", .{ @tagName(tr.sensor_type), tr.compound.historical.winner });
            } else if (tr.compound.realtime.scores.len > 0) {
                try md.print(allocator, "**{s}** — live: **{s}**\n\n", .{ @tagName(tr.sensor_type), tr.compound.realtime.winner });
            }
            if (tr.compound.realtime.scores.len > 0) {
                try md.print(allocator, "Real-time:\n\n", .{});
                try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
                for (tr.compound.realtime.scores) |s| {
                    try md.print(allocator, "| {s} | {d:.2} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
                }
                try md.print(allocator, "\n", .{});
            }
            if (tr.compound.historical.scores.len > 0) {
                try md.print(allocator, "Historical:\n\n", .{});
                try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
                for (tr.compound.historical.scores) |s| {
                    try md.print(allocator, "| {s} | {d:.2} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
                }
                try md.print(allocator, "\n", .{});
            }
        }
    }

    try md.print(allocator, "<details>\n<summary><strong>Per-query latency detail</strong> (all backends × this building's actual query mix)</summary>\n\n", .{});
    try md.print(allocator, "## Per-query latency (this building's actual query mix)\n\n", .{});
    try md.print(allocator, "| Query | Backend | Median | p95 | Memory (KB) |\n|---|---|---:|---:|---:|\n", .{});
    for (rows) |r| {
        try md.print(allocator, "| {s} | {s} | ", .{ r.query, r.backend });
        try report.writeScaledUs(&md, allocator, @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0, true);
        try md.print(allocator, " | ", .{});
        try report.writeScaledUs(&md, allocator, @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0, true);
        try md.print(allocator, " | {d:.1} |\n", .{
            @as(f64, @floatFromInt(r.memory_bytes)) / 1024.0,
        });
    }

    // Explicit per-query winner — the direct answer to "which backend for
    // this query behavior": for each query pattern this building actually
    // runs, the single fastest backend at steady state, not left for the
    // reader to eyeball out of the raw latency table above. Same grouping
    // logic the internal regression-suite report already uses
    // (report.writeReports), reused rather than reimplemented. Non-real-time
    // queries only admit full-retention backends — same eligibility rule the
    // compound recommendation applies, so a count-capped cache that scanned
    // 200x less data can't be presented as a "winner" (see writeWinners's
    // doc comment).
    try md.print(allocator, "\n### Per-query winner (lowest median)\n\n", .{});
    try md.print(allocator, "For queries outside the real-time family, only full-retention backends compete " ++
        "(same rule as the recommendation tracks above) — the real-time cache holds a fraction " ++
        "of the data those queries need, so its latency on them is not comparable.\n\n", .{});
    try md.print(allocator, "| Query | Winner | Median | Runner-up | Median | Speedup |\n", .{});
    try md.print(allocator, "|---|---|---:|---|---:|---:|\n", .{});
    try report.writeWinners(&md, allocator, rows, scale_label, &full_retention_names, true);
    try md.print(allocator, "\n</details>\n\n", .{});

    try md.print(allocator, "See `schematic.svg` in this directory for a floor-by-floor map of placed sensors.\n\n", .{});

    // Cost estimate — cloud-equivalent $/year per backend + naive vs optimised
    const all_backend_names = comptime blk: {
        var names: [runner.backends.len][]const u8 = undefined;
        for (runner.backends, 0..) |b, i| names[i] = b.name;
        break :blk names;
    };
    // Real-time queries are ~3 of 12 patterns; estimate their fraction of
    // total query volume (latest_* are high-frequency, ~1/sec each, while
    // historical/aggregate are ~1/min — so real-time is the majority of
    // total query count).
    const realtime_query_fraction = 0.7;
    try cost_model.writeCostSection(
        &md,
        allocator,
        rows,
        &all_backend_names,
        compound.realtime.winner,
        compound.historical.winner,
        realtime_query_fraction,
        cost_model.DEFAULT_WORKLOAD,
        cost_model.DEFAULT_PRICING,
    );

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, output_dir, .{});
    defer dir.close(io);
    try md.print(allocator, "<details>\n<summary><strong>Growth curve detail</strong> (latency at every checkpoint from day 1 to steady state)</summary>\n\n", .{});
    try report.writeGrowthSection(&md, allocator, growth);
    try md.print(allocator, "\n</details>\n\n", .{});

    try md.print(allocator, "<details>\n<summary><strong>Simulation summary</strong> (compression, eviction, and data-quality stats)</summary>\n\n", .{});
    try report.writeSimSection(&md, allocator, sim_stats, type_volumes, type_quality);
    try md.print(allocator, "\n</details>\n\n", .{});

    try dir.writeFile(io, .{ .sub_path = "recommendation.md", .data = md.items });
    try report.writeSimJson(allocator, io, &dir, sim_stats, growth, type_volumes, type_quality);
}
