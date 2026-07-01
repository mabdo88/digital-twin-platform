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
const World = @import("ecs/world.zig").World;
const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");
const metrics = @import("ecs/systems/metrics_system.zig");
const report = @import("benchmark/report.zig");
const schematic = @import("benchmark/schematic.zig");

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

const SampleArgs = struct {
    sensor_id: u32,
    sensor_type: sb.SensorType,
    zone_id: u32,
    floor_id: u32,
    position: queries.Vec3,
};

/// Up to TYPE_SAMPLE_CAP distinct real sensors across the whole building
/// (not filtered by type — for the queries that aren't type-scoped),
/// cycling if fewer are placed. Same rationale and convention as
/// pickSamplesByType: repeating one fixed sensor 25 times keeps its data
/// artificially cache-hot and only measures that one sensor, not a real
/// deployment's mix of many. Caller frees with the same allocator.
fn pickOverallSamples(allocator: std.mem.Allocator, placement: placer.Placement, zone_floor: []const ZoneFloor) ![]SampleArgs {
    const n = @min(placement.sensors.len, TYPE_SAMPLE_CAP);
    const pool = try allocator.alloc(SampleArgs, n);
    defer allocator.free(pool);
    for (pool, 0..) |*s, i| {
        const sensor = placement.sensors[i];
        const loc = placement.locations[i];
        s.* = .{
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

    const samples = try allocator.alloc(SampleArgs, TYPE_SAMPLE_CAP);
    for (samples, 0..) |*s, i| s.* = pool[i % pool.len];
    return samples;
}

/// Up to `TYPE_SAMPLE_CAP` distinct real sensors per sensor type actually
/// placed in the building — not one sensor repeated. A type with fewer than
/// the cap has its sensor list cycled (repeated from the start) until the
/// cap is reached, so small populations still get the noise-smoothing
/// benefit of multiple timed calls, just spread across whichever real
/// sensors exist instead of hammering a single one. Caller owns `samples`
/// (free with the same allocator).
const TypeSamples = struct { sensor_type: sb.SensorType, samples: []const SampleArgs };

/// Reuses CLAUDE.md §3.4's 25-iteration floor as the sample cap too — no
/// new magic number, and it ties the "how many real sensors do we touch"
/// knob to the same constant as "how many timed calls do we make" (see
/// `runOneAcrossSamples`, which makes exactly this many calls, one per
/// cycled sample).
const TYPE_SAMPLE_CAP: usize = ITERATIONS;

fn pickSamplesByType(
    allocator: std.mem.Allocator,
    placement: placer.Placement,
    zone_floor: []const ZoneFloor,
) ![]TypeSamples {
    // Pass 1: bucket every placed sensor's args by its sensor_type, in
    // placement order. At most 9 buckets (sb.SensorType has 9 variants), so
    // a linear scan per insert is cheap.
    const Bucket = struct { sensor_type: sb.SensorType, list: std.ArrayList(SampleArgs) };
    var buckets: std.ArrayList(Bucket) = .empty;
    defer {
        for (buckets.items) |*bucket| bucket.list.deinit(allocator);
        buckets.deinit(allocator);
    }

    for (placement.sensors, placement.locations) |sensor, loc| {
        const args = SampleArgs{
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

        var found = false;
        for (buckets.items) |*bucket| {
            if (bucket.sensor_type == sensor.sensor_type) {
                try bucket.list.append(allocator, args);
                found = true;
                break;
            }
        }
        if (!found) {
            var list: std.ArrayList(SampleArgs) = .empty;
            try list.append(allocator, args);
            try buckets.append(allocator, .{ .sensor_type = sensor.sensor_type, .list = list });
        }
    }

    // Pass 2: cap each bucket at TYPE_SAMPLE_CAP distinct sensors, cycling
    // (repeating from the start) if the type has fewer than that many.
    var result: std.ArrayList(TypeSamples) = .empty;
    errdefer {
        for (result.items) |ts| allocator.free(ts.samples);
        result.deinit(allocator);
    }

    for (buckets.items) |bucket| {
        const pool = bucket.list.items; // always >= 1 element
        const samples = try allocator.alloc(SampleArgs, TYPE_SAMPLE_CAP);
        for (samples, 0..) |*s, i| s.* = pool[i % pool.len];
        try result.append(allocator, .{ .sensor_type = bucket.sensor_type, .samples = samples });
    }

    return result.toOwnedSlice(allocator);
}

fn queryName(q: queries.QueryName) []const u8 {
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

fn isHistorical(q: queries.QueryName) bool {
    return q == .hourly_rollup or q == .daily_zone_rollup;
}

/// True for queries whose argument list includes a sensor_type (see
/// `runOneAcrossSamples`'s switch) — these are the queries a
/// per-sensor-type recommendation can actually distinguish. The other
/// seven queries are scoped to a sensor_id/zone_id/floor_id/position
/// instead and would just repeat the same result if reused per type.
fn isTypeScoped(q: queries.QueryName) bool {
    return switch (q) {
        .latest_by_type, .avg_zone_type, .floor_stats, .daily_zone_rollup, .anomalies => true,
        .avg_window, .hourly_rollup, .latest_single, .latest_zone, .spatial_radius, .zone_hierarchy, .threshold_breach => false,
    };
}

/// True if `mix` weights `name` at all — used to decide whether a sensor
/// type's own canonical relevant_queries (synthetic.profileFor) cares
/// about a given query, e.g. whether to bother warming anomalies' stats
/// cache for that type.
fn hasQuery(mix: []const queries.QueryWeight, name: queries.QueryName) bool {
    for (mix) |qw| {
        if (qw.query == name) return true;
    }
    return false;
}

/// Filters `mix` down to the type-scoped queries (isTypeScoped) — used both
/// to build a single sensor type's own type-scoped query set
/// (synthetic.profileFor(st).relevant_queries) for its per-type
/// recommendation. Caller frees with `allocator`.
fn filterTypeScoped(allocator: std.mem.Allocator, mix: []const queries.QueryWeight) ![]queries.QueryWeight {
    var list: std.ArrayList(queries.QueryWeight) = .empty;
    errdefer list.deinit(allocator);
    for (mix) |qw| {
        if (isTypeScoped(qw.query)) try list.append(allocator, qw);
    }
    return list.toOwnedSlice(allocator);
}

/// A building's effective query mix is the union of relevant_queries
/// across every DISTINCT sensor type actually placed — derived from what
/// was parsed, not declared via a building-type guess. See
/// synthetic/generator.zig's SensorProfile.relevant_queries doc comment.
/// Caller frees with `allocator`.
fn deriveQueryMix(allocator: std.mem.Allocator, placement: placer.Placement) ![]queries.QueryWeight {
    var seen_types: std.ArrayList(sb.SensorType) = .empty;
    defer seen_types.deinit(allocator);

    var mix: std.ArrayList(queries.QueryWeight) = .empty;
    errdefer mix.deinit(allocator);

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
            try mix.append(allocator, qw);
        }
    }

    return mix.toOwnedSlice(allocator);
}

/// Minimum iteration count per CLAUDE.md §3.4.
const ITERATIONS: u32 = 25;
const ONE_HOUR_MS: i64 = 60 * 60 * 1000;

/// Times any query by cycling through `samples` (up to TYPE_SAMPLE_CAP real
/// sensors — type-filtered for type-scoped queries via pickSamplesByType,
/// or building-wide via pickOverallSamples for the rest) instead of
/// repeating one fixed sample. Hammering one sensor `ITERATIONS` times in a
/// row keeps its data artificially hot in cache, which is not how a real
/// deployment queries hundreds of different sensors. Still calls the
/// *same*, unmodified `metrics.timeQuery` (CLAUDE.md §3.4:
/// metrics_system.zig is the only place that times queries) — the only
/// difference is that the thing being timed (`Sampler.call`) advances to
/// the next real sensor on every invocation instead of reusing fixed args,
/// the same pattern `q1_wrapper`..`q12_wrapper` already use to adapt query
/// signatures into timeQuery's `!void`-returning shape.
fn runOneAcrossSamples(
    world: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: queries.QueryName,
    samples: []const SampleArgs,
) !metrics.LatencyStats {
    const Sampler = struct {
        world: @TypeOf(world),
        query: queries.QueryName,
        samples: []const SampleArgs,
        idx: usize = 0,

        fn call(self: *@This()) !void {
            const sample = self.samples[self.idx % self.samples.len];
            self.idx += 1;
            switch (self.query) {
                .avg_window => _ = try queries.query_avg_window(self.world, sample.sensor_id, @as(u32, 24)),
                .latest_single => try runner.q1_wrapper(self.world, sample.sensor_id),
                .latest_zone => try runner.q2_wrapper(self.world, sample.zone_id),
                .latest_by_type => try runner.q3_wrapper(self.world, sample.sensor_type),
                .avg_zone_type => try runner.q5_wrapper(self.world, sample.zone_id, sample.sensor_type, @as(u32, 24)),
                .floor_stats => try runner.q6_wrapper(self.world, sample.floor_id, sample.sensor_type, @as(u32, 24)),
                .hourly_rollup => try runner.q7_wrapper(self.world, sample.sensor_id, @as(u32, 2)),
                .daily_zone_rollup => try runner.q8_wrapper(self.world, sample.zone_id, sample.sensor_type),
                .spatial_radius => try runner.q9_wrapper(self.world, sample.position, @as(f32, 50.0)),
                .zone_hierarchy => try runner.q10_wrapper(self.world, sample.zone_id, @as(u32, 2)),
                .anomalies => try runner.q11_wrapper(self.world, sample.sensor_type, @as(f32, 1.0)),
                .threshold_breach => try runner.q12_wrapper(self.world, sample.sensor_id, synthetic.profileFor(sample.sensor_type).base_value, ONE_HOUR_MS),
            }
        }
    };

    var sampler = Sampler{ .world = world, .query = query, .samples = samples };
    return metrics.timeQuery(allocator, io, ITERATIONS, Sampler.call, .{&sampler});
}

fn benchProfile(
    comptime b: runner.BackendEntry,
    comptime historical_supported: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    readings: []const sb.SensorReading,
    locations: []const placer.ZoneLocation,
    zone_floor: []const ZoneFloor,
    query_mix: []const queries.QueryWeight,
    overall_samples: []const SampleArgs,
    type_samples: []const TypeSamples,
    scale_label: []const u8,
    rows: *std.ArrayList(report.RunRow),
    type_rows: *std.ArrayList(report.RunRow),
) !void {
    std.debug.print("\n--- Backend: {s} ---\n", .{b.name});

    var world = try World(b.T).init(allocator);
    defer world.deinit();

    std.debug.print("  [{s}] ingesting {d} readings + {d} zone/floor registrations...\n", .{ b.name, readings.len, locations.len });
    const ingest_start = std.Io.Clock.awake.now(io);
    for (readings) |r| try world.insert(r);
    for (locations) |loc| try world.registerZone(loc.sensor_id, loc.zone_id);
    for (zone_floor) |zf| try world.registerFloor(zf.zone_id, zf.floor_id);

    // Force the lazy sort/cache-build/sensor-index every backend otherwise
    // defers to its first query call — attribute that one-time cost to
    // ingest (already measured here) instead of letting it silently
    // inflate whichever query happens to run first (we measured this
    // directly: TimeSeries's first-ever sort cost 337s hidden inside
    // query_latest_single's uncounted warmup, then every later query
    // looked artificially fast because the work was already done).
    _ = try world.iterateAll();
    const warm = try world.readingsForSensor(overall_samples[0].sensor_id);
    allocator.free(warm);

    // statsForType/readingsForType exist solely for query_anomalies —
    // forcing them for every placed type would waste full-dataset passes
    // on types whose own canonical relevant_queries doesn't even include
    // anomalies (e.g. occupancy/temperature). Only warm what will
    // actually be queried, per each type's own table.
    var warmed_type_index = false;
    for (type_samples) |group| {
        const type_mix = synthetic.profileFor(group.sensor_type).relevant_queries;
        if (!hasQuery(type_mix, .anomalies)) continue;
        _ = try world.statsForType(group.sensor_type);
        if (!warmed_type_index) {
            const warm_type = try world.readingsForType(group.sensor_type);
            allocator.free(warm_type);
            warmed_type_index = true;
        }
    }

    std.debug.print("  [{s}] ingest done in {d:.1}s ({d:.1} MB)\n", .{
        b.name, elapsedSeconds(io, ingest_start), @as(f64, @floatFromInt(world.memoryUsed())) / (1024.0 * 1024.0),
    });

    std.debug.print("  [{s}] running {d} building-level queries...\n", .{ b.name, query_mix.len });
    for (query_mix) |qw| {
        if (!historical_supported and isHistorical(qw.query)) continue;

        std.debug.print("    {s}: starting...\n", .{queryName(qw.query)});
        const q_start = std.Io.Clock.awake.now(io);
        const stats = try runOneAcrossSamples(&world, allocator, io, qw.query, overall_samples);
        std.debug.print("    {s}: finished — median {d:.1}us, p95 {d:.1}us (took {d:.1}s)\n", .{
            queryName(qw.query),
            @as(f64, @floatFromInt(stats.median_ns)) / 1000.0,
            @as(f64, @floatFromInt(stats.p95_ns)) / 1000.0,
            elapsedSeconds(io, q_start),
        });
        try rows.append(allocator, .{
            .scale = scale_label,
            .query = queryName(qw.query),
            .backend = b.name,
            .memory_bytes = world.memoryUsed(),
            .stats = stats,
        });
    }

    // Re-run the type-scoped queries from each type's OWN canonical
    // relevant_queries (synthetic.profileFor), once per distinct sensor
    // type placed, against this same already-ingested world — no
    // re-ingest, so this stays cheap even at 72M-reading scale. Each query
    // is timed across up to TYPE_SAMPLE_CAP real sensors of that type (see
    // runOneAcrossSamples), not one sensor repeated.
    if (type_samples.len > 0) {
        std.debug.print("  [{s}] running type-scoped queries across {d} sensor types...\n", .{ b.name, type_samples.len });
    }
    for (type_samples) |group| {
        const type_mix = synthetic.profileFor(group.sensor_type).relevant_queries;
        for (type_mix) |qw| {
            if (!isTypeScoped(qw.query)) continue;
            if (!historical_supported and isHistorical(qw.query)) continue;

            std.debug.print("    {s} / {s}: starting...\n", .{ @tagName(group.sensor_type), queryName(qw.query) });
            const q_start = std.Io.Clock.awake.now(io);
            const stats = try runOneAcrossSamples(&world, allocator, io, qw.query, group.samples);
            std.debug.print("    {s} / {s}: finished — median {d:.1}us, p95 {d:.1}us (took {d:.1}s)\n", .{
                @tagName(group.sensor_type),
                queryName(qw.query),
                @as(f64, @floatFromInt(stats.median_ns)) / 1000.0,
                @as(f64, @floatFromInt(stats.p95_ns)) / 1000.0,
                elapsedSeconds(io, q_start),
            });
            try type_rows.append(allocator, .{
                .scale = @tagName(group.sensor_type),
                .query = queryName(qw.query),
                .backend = b.name,
                .memory_bytes = world.memoryUsed(),
                .stats = stats,
            });
        }
    }

    std.debug.print("  [{s}] backend done.\n", .{b.name});
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
    zone_floor: []const ZoneFloor,
) !SchematicData {
    var sensors = try allocator.alloc(schematic.SensorPoint, placement.sensors.len);
    for (placement.sensors, placement.locations, 0..) |sensor, loc, i| {
        sensors[i] = .{
            .x = loc.position.x,
            .y = loc.position.y,
            .floor_id = floorFor(zone_floor, loc.zone_id),
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

/// One backend ranking scoped to a single sensor type — same shape as
/// the building-level `report.Recommendation`, just filtered down to that
/// type's own type-scoped queries (synthetic.profileFor(st).relevant_queries
/// filtered through filterTypeScoped).
const TypeRecommendation = struct { sensor_type: sb.SensorType, rec: report.Recommendation };

fn isSupported(comptime b: runner.BackendEntry) bool {
    for (runner.supported_backends) |sup| {
        if (std.mem.eql(u8, sup.name, b.name)) return true;
    }
    return false;
}

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

    std.debug.print("Parsing {s}...\n", .{args.bim_path});
    const parse_start = std.Io.Clock.awake.now(io);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args.bim_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(source);

    var model = try ifc.parseSlice(allocator, source);
    defer model.deinit();

    std.debug.print(
        "Parsed {s}: {d} elements, {d} zones, {d} equipment items ({d:.1}s).\n",
        .{ args.bim_path, model.building_elements.len, model.zones.len, model.equipment.len, elapsedSeconds(io, parse_start) },
    );

    std.debug.print("Placing sensors...\n", .{});
    const place_start = std.Io.Clock.awake.now(io);
    var placement = try placer.place(allocator, model.building_elements, model.zones, .{});
    defer placement.deinit();

    std.debug.print("Placed {d} sensors ({d:.1}s).\n", .{ placement.sensors.len, elapsedSeconds(io, place_start) });
    if (placement.sensors.len == 0) {
        std.debug.print("No sensors placed (no elements in this IFC matched a placement rule) — nothing to benchmark.\n", .{});
        return;
    }

    // 1h of synthetic data (generator's own default duration). Sample rates
    // now come from synthetic.profileFor's canonical per-type table
    // (minutes-scale for most types), so this is a modest dataset — see
    // that file's header comment for why literal real-world retention
    // windows (e.g. 30 days of 100Hz vibration) aren't generated outright.
    std.debug.print("Generating synthetic readings for {d} sensors...\n", .{placement.sensors.len});
    const gen_start = std.Io.Clock.awake.now(io);
    const readings = try synthetic.generate(allocator, placement.sensors, .{}, null);
    defer allocator.free(readings);
    std.debug.print("Generated {d} synthetic readings ({d:.1}s).\n", .{ readings.len, elapsedSeconds(io, gen_start) });

    const zone_floor = try buildZoneFloorMap(allocator, model.building_elements, model.zones);
    defer allocator.free(zone_floor);

    const overall_samples = try pickOverallSamples(allocator, placement, zone_floor);
    defer allocator.free(overall_samples);
    const type_samples = try pickSamplesByType(allocator, placement, zone_floor);
    defer {
        for (type_samples) |ts| allocator.free(ts.samples);
        allocator.free(type_samples);
    }

    // The building's effective query mix — derived from whichever sensor
    // types actually got placed (each contributes its own canonical
    // relevant_queries), not declared via a building-type guess.
    const query_mix = try deriveQueryMix(allocator, placement);
    defer allocator.free(query_mix);

    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(allocator);
    var type_rows: std.ArrayList(report.RunRow) = .empty;
    defer type_rows.deinit(allocator);

    const scale_label = scaleLabel(args.bim_path);

    inline for (runner.backends) |b| {
        try benchProfile(
            b,
            isSupported(b),
            allocator,
            io,
            readings,
            placement.locations,
            zone_floor,
            query_mix,
            overall_samples,
            type_samples,
            scale_label,
            &rows,
            &type_rows,
        );
    }

    const recommendation = try report.recommendBackend(allocator, rows.items, scale_label, query_mix);
    defer allocator.free(recommendation.scores);

    std.debug.print("\n=== Recommendation ({s}) ===\n", .{scale_label});
    std.debug.print("{s:<15} {s:>10} {s:>12}\n", .{ "Backend", "Score", "Coverage" });
    for (recommendation.scores) |s| {
        std.debug.print("{s:<15} {d:>10.3} {d:>11.0}%\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    std.debug.print("Winner: {s} (lowest weighted median across this building's query mix; 1.0 = won every query)\n", .{recommendation.winner});

    var type_recommendations: std.ArrayList(TypeRecommendation) = .empty;
    defer {
        for (type_recommendations.items) |tr| allocator.free(tr.rec.scores);
        type_recommendations.deinit(allocator);
    }

    for (type_samples) |ts| {
        // Each type's OWN type-scoped queries — not a shared building-wide
        // filter — since different types can care about different query
        // patterns (occupancy's relevant_queries differ from vibration's).
        const type_scoped_mix = try filterTypeScoped(allocator, synthetic.profileFor(ts.sensor_type).relevant_queries);
        defer allocator.free(type_scoped_mix);
        if (type_scoped_mix.len == 0) continue;

        const rec = try report.recommendBackend(allocator, type_rows.items, @tagName(ts.sensor_type), type_scoped_mix);
        try type_recommendations.append(allocator, .{ .sensor_type = ts.sensor_type, .rec = rec });
    }

    if (type_recommendations.items.len > 0) {
        std.debug.print("\n=== Recommendation by Sensor Type ({s}) ===\n", .{scale_label});
        for (type_recommendations.items) |tr| {
            std.debug.print("{s:<14} winner: {s}\n", .{ @tagName(tr.sensor_type), tr.rec.winner });
        }
    }

    try writeRecommendationReport(allocator, io, args.output_dir, args.bim_path, scale_label, model, placement, recommendation, rows.items, type_recommendations.items);
    std.debug.print("Wrote recommendation.md to {s}/\n", .{args.output_dir});

    const sd = try buildSchematicData(allocator, model, placement, zone_floor);
    defer allocator.free(sd.sensors);
    defer allocator.free(sd.zones);

    var title_buf: [512]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s} ({d} sensors)", .{ args.bim_path, placement.sensors.len });
    try schematic.writeSchematic(allocator, io, args.output_dir, title, sd.sensors, sd.zones);
    std.debug.print("Wrote schematic.svg to {s}/\n", .{args.output_dir});

    std.debug.print("\nTotal run time: {d:.1}s\n", .{elapsedSeconds(io, run_start)});
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
    recommendation: report.Recommendation,
    rows: []const report.RunRow,
    type_recommendations: []const TypeRecommendation,
) !void {
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(allocator);

    try md.print(allocator, "# Digital Twin — Storage Recommendation\n\n", .{});
    try md.print(allocator, "- Source IFC: `{s}`\n", .{bim_path});
    try md.print(allocator, "- Run label: `{s}`\n", .{scale_label});
    try md.print(allocator, "- Elements: {d} | Zones: {d} | Equipment: {d} | Sensors placed: {d}\n\n", .{
        model.building_elements.len, model.zones.len, model.equipment.len, placement.sensors.len,
    });

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
    try md.print(allocator, "Score = weighted average of (this backend's median / the per-query winner's median) across " ++
        "the building's effective query mix — the union of relevant_queries across every sensor type actually " ++
        "placed (see synthetic/generator.zig). **1.00 = won every weighted query; higher is worse.** Coverage below " ++
        "100% means the backend has no data for one or more weighted queries.\n\n", .{});
    try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
    for (recommendation.scores) |s| {
        try md.print(allocator, "| {s} | {d:.3} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
    }
    try md.print(allocator, "\n**Winner: {s}**\n\n", .{recommendation.winner});

    if (type_recommendations.len > 0) {
        try md.print(allocator, "## Recommendation by Sensor Type\n\n", .{});
        try md.print(allocator, "Same scoring rule as above, but scoped to one sensor type at a time. For each of the " ++
            "{d} sensor types actually placed in this building, every timed call cycles to the next of up to {d} " ++
            "real sensors of that type (repeating from the start if fewer than {d} were placed) instead of repeating " ++
            "one fixed sensor — closer to a real deployment, which queries many different sensors of a type rather " ++
            "than the same one. Scores only the query patterns in that type's own canonical relevant_queries that " ++
            "take a sensor type as an argument (`latest_by_type`, `avg_zone_type`, `floor_stats`, " ++
            "`daily_zone_rollup`, `anomalies` — whichever are relevant for this specific type). A type's winner can " ++
            "differ from the building-wide winner above if that type's relevant queries behave differently.\n\n", .{
            type_recommendations.len, TYPE_SAMPLE_CAP, TYPE_SAMPLE_CAP,
        });
        for (type_recommendations) |tr| {
            try md.print(allocator, "**{s}** — winner: **{s}**\n\n", .{ @tagName(tr.sensor_type), tr.rec.winner });
            if (tr.rec.scores.len > 0) {
                try md.print(allocator, "| Backend | Score | Coverage |\n|---|---:|---:|\n", .{});
                for (tr.rec.scores) |s| {
                    try md.print(allocator, "| {s} | {d:.3} | {d:.0}% |\n", .{ s.backend, s.score, s.coverage * 100 });
                }
                try md.print(allocator, "\n", .{});
            }
        }
    }

    try md.print(allocator, "## Per-query latency (this building's actual query mix)\n\n", .{});
    try md.print(allocator, "| Query | Backend | Median µs | p95 µs | Memory (KB) |\n|---|---|---:|---:|---:|\n", .{});
    for (rows) |r| {
        try md.print(allocator, "| {s} | {s} | {d:.1} | {d:.1} | {d:.1} |\n", .{
            r.query,
            r.backend,
            @as(f64, @floatFromInt(r.stats.median_ns)) / 1000.0,
            @as(f64, @floatFromInt(r.stats.p95_ns)) / 1000.0,
            @as(f64, @floatFromInt(r.memory_bytes)) / 1024.0,
        });
    }

    try md.print(allocator, "\nSee `schematic.svg` in this directory for a floor-by-floor map of placed sensors.\n", .{});

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, output_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "recommendation.md", .data = md.items });
}
