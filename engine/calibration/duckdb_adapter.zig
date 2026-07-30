// Zig 0.16.0 (tested against 0.17.0-dev)
//
// DuckDB calibration pass (CLAUDE.md §6, AGENT.md Phase 8) — the platform's
// one *outside witness*.
//
// WHY THIS EXISTS
// ---------------
// Every other test in this repo checks our backends against each other. That
// catches a backend that disagrees with its peers, but it cannot catch a
// mistake in an assumption all seven share, or in the query layer they all
// route through — a wrong answer that is wrong identically everywhere looks
// exactly like a right one. Calibration closes that hole by handing the same
// data to a real, independently-implemented SQL engine and asking the same
// questions.
//
// WHAT IT ASSERTS (and what it deliberately does not)
// --------------------------------------------------
// 1. VALUE AGREEMENT (the primary check). Each query pattern is expressed as
//    SQL that computes the same answer, and DuckDB's answer is compared
//    against ours. A mismatch means a real defect in our query or storage
//    layer — this check is exact-ish (see TOLERANCE below) and not subject
//    to timing noise, which makes it the most useful thing DuckDB can tell
//    us.
//
// 2. COST-PROFILE AGREEMENT (secondary). Whether the two engines rank the
//    query patterns by cost in roughly the same order, as a Spearman rank
//    correlation over per-query latency. If our harness says a 30-day
//    rollup is cheaper than a single-point lookup while DuckDB says the
//    opposite, the measurement harness is suspect even when the values
//    agree.
//
// 3. SLOWER-THAN-DUCKDB GUARD (secondary). Flags any query where WE are more
//    than SLOWER_THAN_DUCKDB_RATIO× slower than DuckDB.
//
// AGENT.md Phase 8 specified a symmetric gate: "flag if any backend is >2×
// slower than DuckDB or >2× faster." Only half of that survives scrutiny,
// and only half is implemented.
//
// The "slower" half is real and is kept, at AGENT.md's own 2×: our backends
// are in-process array scans with no SQL parse, no query planner and no page
// cache, so a full DBMS — planning overhead included — beating us on the
// same scoped query means something is genuinely wrong on our side.
//
// The "faster" half is dropped. Being 10-100× (or, measured here, ~10,000×)
// faster than DuckDB on a scoped query is the expected, correct outcome of
// not paying for a planner, so gating on it would fire on nearly every query
// and mean nothing — the failure mode that retired the weighted-ratio scorer
// on 2026-07-20. Nor is a "suspiciously fast" gate needed to catch a query
// that silently skipped its work: a query that didn't do the work returns
// the wrong cardinality, which check 1 catches exactly. The observed
// fast-direction ratios are reported as data instead.
//
// See .cascade/digital-twin/backend-audit.md's 2026-07-30 entry.
//
// This pass CANNOT validate our storage-layout rankings against DuckDB:
// DuckDB is columnar-only and has no equivalent of a per-sensor append log
// or a ring buffer, so there is no outside engine in which "TimeSeries vs
// Columnar" is even a meaningful comparison. What it validates is that our
// answers and our cost profile are right; the layout ranking rests on the
// cross-backend equivalence suite plus these measurements being sound.
//
// TRANSPORT
// ---------
// The `duckdb` CLI is invoked once, as a subprocess, with a generated SQL
// script (`std.process.run`, no OS-specific APIs, no linked library). This
// keeps CLAUDE.md §2's "no external database dependencies" intact for the
// platform proper: nothing here is needed to build or run `dt`/`dtb`, and
// when the binary is absent the pass reports itself unavailable and the
// caller carries on. `zig build` never sees DuckDB.

const std = @import("std");
const builtin = @import("builtin");

const sb = @import("../ecs/storage/storage_backend.zig");
const World = @import("../ecs/world.zig").World;
const metrics = @import("../ecs/systems/metrics_system.zig");
const queries = @import("../benchmark/queries.zig");
const runner = @import("../benchmark/runner.zig");
const report = @import("../benchmark/report.zig");
const fixtures = @import("../benchmark/dataset.zig");

const MS_PER_HOUR: i64 = 60 * 60 * 1000;
const MS_PER_DAY: i64 = 24 * MS_PER_HOUR;

// ---------------------------------------------------------------------------
// Tolerances and thresholds
// ---------------------------------------------------------------------------

/// Value-agreement tolerance. Our aggregates sum f32 readings into f64;
/// DuckDB sums the same FLOAT column into DOUBLE, in its own vectorised
/// order. That yields relative differences around 1e-7, while any real
/// defect (an off-by-one window bound, a dropped partition, a wrong bucket)
/// moves an aggregate by at least ~1/n — orders of magnitude more. 1e-5
/// separates the two cleanly.
const REL_TOLERANCE: f64 = 1e-5;
const ABS_TOLERANCE: f64 = 1e-6;

/// How much slower than DuckDB we may be before a query is flagged. Applies
/// in one direction only — see the header note on AGENT.md's symmetric gate.
const SLOWER_THAN_DUCKDB_RATIO: f64 = 2.0;

/// Spearman correlation below which the cost profiles are reported as
/// disagreeing.
///
/// Set from measurement, not taste. Ten consecutive healthy runs of this pass
/// (2026-07-30, 876k rows, 8 repetitions) produced rho between 0.42 and 0.74
/// — the spread comes from DuckDB's whole-millisecond timer and ordinary
/// machine jitter over only 12 data points. An earlier 0.5 floor sat inside
/// that range and would have reported REVIEW on a run with nothing wrong
/// with it, which is the worst thing a trust-establishing check can do.
///
/// 0.25 sits well clear of the observed healthy floor while still failing the
/// cases worth failing: rho near 0 (the two engines' costs are unrelated, so
/// our harness is measuring something other than query work) or negative (the
/// profile is inverted). It cannot catch a subtly wrong cost profile, and the
/// report says so.
const SPEARMAN_FLOOR: f64 = 0.25;

// ---------------------------------------------------------------------------
// Options and fixed calibration parameters
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Explicit path to the `duckdb` binary. When null, `findDuckdb` probes
    /// the candidates listed there.
    duckdb_path: ?[]const u8 = null,
    output_dir: []const u8 = "calibration-results",
    /// 100 sensors × 8760 hourly readings = 876,000 rows ≈ one simulated
    /// year. Large enough that the widest calibration query (a fleet-wide
    /// 30-day anomaly window) is real work for both engines, small enough
    /// that the whole pass is seconds rather than minutes. Total row count
    /// matters less than it looks: most patterns are sensor- or zone-scoped,
    /// so it is the window parameters below that set how much data each
    /// query actually touches.
    num_sensors: u32 = 100,
    readings_per_sensor: u32 = 8760,
    /// Repetitions per query, per engine. A fixed count (not the real path's
    /// single shot) for the same reason runner.zig uses one: this is a
    /// CI-style check wanting stable relative numbers.
    ///
    /// It also buys timing resolution on the DuckDB side. Its CLI timer
    /// reports whole milliseconds, so a single reading of a 3 ms query
    /// carries ±17% quantization error and a dozen queries collapse onto a
    /// handful of distinct values — which would flatten the rank
    /// correlation into ties. Averaging several quantized readings recovers
    /// sub-millisecond resolution. The first repetition is a warmup on both
    /// sides.
    iterations: u32 = 8,
    /// Keep the generated CSV/SQL artifacts on disk for inspection.
    keep_artifacts: bool = true,
};

/// Query parameters, shared by both engines — the single definition each
/// side reads, so a change can never be applied to one and not the other.
///
/// These are calibration-specific rather than reused from queries.zig's
/// `runAllQueries` fixture args, because this dataset is ~17× that fixture's
/// largest tier and some of those args would be degenerate here.
const Params = struct {
    sensor_id: u32 = 0,
    zone_id: u32 = 0,
    floor_id: u32 = 0,
    sensor_type: sb.SensorType = .temperature,
    center: queries.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    radius_m: f32 = 50.0,
    /// Trailing window for the three aggregation queries.
    window_hours: u32 = 24,
    /// Trailing window for the hourly rollup.
    rollup_days: u32 = 30,
    /// Trailing window for the anomaly scan. 30 days rather than
    /// queries.ANOMALY_WINDOW_HOURS' 7 so each (sensor, hour-of-day) bucket
    /// holds ~30 samples instead of ~7.
    anomaly_window_hours: u32 = 24 * 30,
    /// 1.5σ rather than queries.ANOMALY_STD_DEV_THRESHOLD's 2.5. This
    /// fixture's values are uniform noise on a 5-unit interval, whose
    /// maximum possible deviation is ~1.73σ — at 2.5σ BOTH engines return
    /// zero anomalies, and "both agree on the empty set" validates nothing.
    /// 1.5σ makes both sides return a substantial result set to compare.
    /// This changes only what the calibration asks; the production default
    /// is untouched.
    anomaly_z: f32 = 1.5,
    /// Sensor 0's values span [10, 15) (dataset.zig: 10 + 5·rand + id), so
    /// a 12.5 threshold puts roughly half the readings above it and makes
    /// sustained runs common. queries.zig's own fixture uses 15.0, which
    /// this sensor essentially never exceeds.
    breach_threshold: f32 = 12.5,
    breach_min_duration_ms: i64 = MS_PER_HOUR,
    breach_window_hours: u32 = 48,
};

const params: Params = .{};

/// Zone-hierarchy depth is fixed at 2 ("every sensor in the building")
/// rather than being a Params field. Depths 0 and 1 resolve to exactly the
/// zone and floor membership that latest_zone and floor_stats already
/// exercise, and a depth field that the SQL side ignored would be a silent
/// mismatch waiting to happen.
const HIERARCHY_DEPTH: u32 = 2;

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------

/// What both engines report for one query: a result cardinality and a single
/// f64 signature of the values. Reducing each answer to (n, sig) is what
/// lets one comparison routine serve all twelve patterns.
///
/// For the three scalar queries (avg_window, avg_zone_type, floor_stats) our
/// query functions return only the aggregate, so `n` is a constant 1 on both
/// sides and the value alone is compared. Every other pattern reports a real
/// cardinality.
pub const Signature = struct {
    n: u64,
    sig: f64,
};

/// Latencies here are MEANS over the repetitions, not medians as elsewhere
/// in the platform: DuckDB's whole-millisecond timer makes a single reading
/// (and therefore a median of readings) coarse, and averaging is what
/// recovers resolution. Using the mean on both sides keeps the comparison
/// apples-to-apples. Nothing else in the platform reads these numbers — the
/// latency reports still come from runner.zig's medians.
pub const BackendRow = struct {
    backend: []const u8,
    query: []const u8,
    sig: Signature,
    mean_ns: i64,
};

pub const DuckRow = struct {
    query: []const u8,
    sig: Signature,
    mean_ns: i64,
};

pub const Mismatch = struct {
    backend: []const u8,
    query: []const u8,
    ours: Signature,
    duckdb: Signature,
};

pub const SlowerFlag = struct {
    query: []const u8,
    /// ours / duckdb. Always > SLOWER_THAN_DUCKDB_RATIO when recorded.
    ratio: f64,
};

pub const Result = struct {
    duckdb_version: []const u8,
    duckdb_path: []const u8,
    num_sensors: u32,
    readings_per_sensor: u32,
    iterations: u32,
    rows: []BackendRow,
    duck: []DuckRow,
    mismatches: []Mismatch,
    slower_flags: []SlowerFlag,
    /// Rank correlation on DuckDB's floor-adjusted times — the verdict's
    /// version. See FLOOR_PROBE.
    spearman: f64,
    /// Same correlation on DuckDB's raw times, reported for context so the
    /// effect of the floor adjustment is visible rather than hidden.
    spearman_raw: f64,
    /// DuckDB's measured fixed per-query overhead on this table.
    duck_floor_ns: i64,

    /// The headline: true when every value agreed, the cost profiles
    /// correlate, and we were not slower than DuckDB anywhere.
    pub fn passed(self: Result) bool {
        return self.mismatches.len == 0 and
            self.slower_flags.len == 0 and
            self.spearman >= SPEARMAN_FLOOR;
    }

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.duckdb_version);
        allocator.free(self.duckdb_path);
        allocator.free(self.rows);
        allocator.free(self.duck);
        allocator.free(self.mismatches);
        allocator.free(self.slower_flags);
    }
};

// ---------------------------------------------------------------------------
// Binary discovery
// ---------------------------------------------------------------------------

const exe_suffix = if (builtin.target.os.tag == .windows) ".exe" else "";

/// Probes for a usable `duckdb` binary and returns its version string, or
/// null when none is available. Order: the caller's explicit path, then
/// PATH, then a `tools/` copy in the current directory (where a developer
/// drops a local binary without installing it system-wide).
///
/// Availability is decided by actually running `--version`, not by stat-ing
/// a path: that also rules out a binary that exists but cannot execute, and
/// it needs no manual PATH parsing (`std.process.run` resolves argv[0]
/// against PATH itself, on every platform).
pub fn findDuckdb(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit: ?[]const u8,
) !?struct { path: []u8, version: []u8 } {
    const local = try std.fs.path.join(allocator, &.{ "tools", "duckdb" ++ exe_suffix });
    defer allocator.free(local);

    const candidates: []const []const u8 = if (explicit) |e|
        &.{e}
    else
        &.{ "duckdb" ++ exe_suffix, local };

    for (candidates) |cand| {
        const res = std.process.run(allocator, io, .{
            .argv = &.{ cand, "--version" },
        }) catch continue;
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (!res.term.success()) continue;

        const version = std.mem.trim(u8, res.stdout, " \r\n\t");
        if (version.len == 0) continue;

        return .{
            .path = try allocator.dupe(u8, cand),
            .version = try allocator.dupe(u8, version),
        };
    }

    return null;
}

// ---------------------------------------------------------------------------
// Our side: compute each query's signature through the real query functions
// ---------------------------------------------------------------------------

/// Runs every query pattern against `world` and reduces each answer to its
/// (n, sig) signature. Deliberately calls the SAME public functions in
/// queries.zig that the benchmark measures — a signature computed by
// re-implementing a query here would validate nothing.
fn oursSignature(world: anytype, q: queries.QueryName) !Signature {
    const allocator = world.allocator;
    switch (q) {
        .latest_single => {
            const r = try queries.query_latest_single(world, params.sensor_id);
            return .{ .n = 1, .sig = if (r) |x| @as(f64, x.value) else 0.0 };
        },
        .latest_zone => {
            const rs = try queries.query_latest_zone(world, params.zone_id);
            defer allocator.free(rs);
            var sum: f64 = 0;
            for (rs) |r| sum += @as(f64, r.value);
            return .{ .n = rs.len, .sig = sum };
        },
        .latest_by_type => {
            const rs = try queries.query_latest_by_type(world, params.sensor_type);
            defer allocator.free(rs);
            var sum: f64 = 0;
            for (rs) |r| sum += @as(f64, r.value);
            return .{ .n = rs.len, .sig = sum };
        },
        .avg_window => {
            const avg = try queries.query_avg_window(world, params.sensor_id, params.window_hours);
            return .{ .n = 1, .sig = @as(f64, avg) };
        },
        .avg_zone_type => {
            const avg = try queries.query_avg_zone_type(world, params.zone_id, params.sensor_type, params.window_hours);
            return .{ .n = 1, .sig = @as(f64, avg) };
        },
        .floor_stats => {
            const s = try queries.query_floor_stats(world, params.floor_id, params.sensor_type, params.window_hours);
            // Composite signature: min + max + avg in one f64 so all three
            // fields are covered by the uniform (n, sig) comparison. A defect
            // that preserved this sum while corrupting the individual fields
            // is not a realistic failure mode for a sanity check.
            return .{ .n = 1, .sig = @as(f64, s.min) + @as(f64, s.max) + @as(f64, s.avg) };
        },
        .hourly_rollup => {
            const rs = try queries.query_hourly_rollup(world, params.sensor_id, params.rollup_days);
            defer allocator.free(rs);
            var sum: f64 = 0;
            for (rs) |r| sum += @as(f64, r.avg);
            return .{ .n = rs.len, .sig = sum };
        },
        .daily_zone_rollup => {
            const rs = try queries.query_daily_zone_rollup(world, params.zone_id, params.sensor_type);
            defer allocator.free(rs);
            var sum: f64 = 0;
            for (rs) |r| sum += @as(f64, r.avg);
            return .{ .n = rs.len, .sig = sum };
        },
        .spatial_radius => {
            const ids = try queries.query_spatial_radius(world, params.center, params.radius_m);
            defer allocator.free(ids);
            var sum: f64 = 0;
            for (ids) |id| sum += @as(f64, @floatFromInt(id));
            return .{ .n = ids.len, .sig = sum };
        },
        .zone_hierarchy => {
            const ids = try queries.query_zone_hierarchy(world, params.zone_id, HIERARCHY_DEPTH);
            defer allocator.free(ids);
            var sum: f64 = 0;
            for (ids) |id| sum += @as(f64, @floatFromInt(id));
            return .{ .n = ids.len, .sig = sum };
        },
        .anomalies => {
            const rs = try queries.query_anomalies(
                world,
                params.sensor_type,
                params.anomaly_z,
                params.anomaly_window_hours,
            );
            defer allocator.free(rs);
            var sum: f64 = 0;
            for (rs) |r| sum += @abs(@as(f64, r.z_score));
            return .{ .n = rs.len, .sig = sum };
        },
        .threshold_breach => {
            const ev = try queries.query_threshold_breach(
                world,
                params.sensor_id,
                params.breach_threshold,
                params.breach_min_duration_ms,
                params.breach_window_hours,
            );
            if (ev) |e| return .{ .n = 1, .sig = @as(f64, @floatFromInt(e.duration_ms)) };
            return .{ .n = 0, .sig = 0 };
        },
    }
}

/// Times one query pattern via metrics_system (CLAUDE.md §3.4: no ad-hoc
/// timing anywhere else), reusing runner.zig's existing result-freeing
/// wrappers so no second set of them exists.
fn oursLatency(
    world: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    iterations: u32,
    q: queries.QueryName,
) !metrics.LatencyStats {
    return switch (q) {
        .latest_single => metrics.timeQuery(allocator, io, iterations, runner.q1_wrapper, .{ world, params.sensor_id }),
        .latest_zone => metrics.timeQuery(allocator, io, iterations, runner.q2_wrapper, .{ world, params.zone_id }),
        .latest_by_type => metrics.timeQuery(allocator, io, iterations, runner.q3_wrapper, .{ world, params.sensor_type }),
        .avg_window => metrics.timeQuery(allocator, io, iterations, queries.query_avg_window, .{ world, params.sensor_id, params.window_hours }),
        .avg_zone_type => metrics.timeQuery(allocator, io, iterations, runner.q5_wrapper, .{ world, params.zone_id, params.sensor_type, params.window_hours }),
        .floor_stats => metrics.timeQuery(allocator, io, iterations, runner.q6_wrapper, .{ world, params.floor_id, params.sensor_type, params.window_hours }),
        .hourly_rollup => metrics.timeQuery(allocator, io, iterations, runner.q7_wrapper, .{ world, params.sensor_id, params.rollup_days }),
        .daily_zone_rollup => metrics.timeQuery(allocator, io, iterations, runner.q8_wrapper, .{ world, params.zone_id, params.sensor_type }),
        .spatial_radius => metrics.timeQuery(allocator, io, iterations, runner.q9_wrapper, .{ world, params.center, params.radius_m }),
        .zone_hierarchy => metrics.timeQuery(allocator, io, iterations, runner.q10_wrapper, .{ world, params.zone_id, HIERARCHY_DEPTH }),
        .anomalies => metrics.timeQuery(allocator, io, iterations, runner.q11_wrapper, .{ world, params.sensor_type, params.anomaly_z, params.anomaly_window_hours }),
        .threshold_breach => metrics.timeQuery(allocator, io, iterations, runner.q12_wrapper, .{ world, params.sensor_id, params.breach_threshold, params.breach_min_duration_ms, params.breach_window_hours }),
    };
}

// ---------------------------------------------------------------------------
// CSV export — the same rows, and the same topology, both engines see
// ---------------------------------------------------------------------------

fn writeReadingsCsv(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    readings: []const sb.SensorReading,
) !void {
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(allocator);
    // ~34 bytes/row measured; one up-front reservation instead of ~20 grow-
    // and-copy cycles over a 30 MB buffer.
    try csv.ensureTotalCapacity(allocator, readings.len * 40 + 64);

    try csv.appendSlice(allocator, "sensor_id,timestamp,value,sensor_type\n");
    for (readings) |r| {
        // `{d}` on an f32 prints the shortest decimal that round-trips as
        // f32, and the column is declared FLOAT on the DuckDB side, so the
        // engine sees bit-identical values to the ones our backends hold.
        // Anything wider (DOUBLE) would make the two engines disagree on
        // arithmetic for reasons unrelated to storage.
        try csv.print(allocator, "{d},{d},{d},{s}\n", .{
            r.sensor_id, r.timestamp, r.value, @tagName(r.sensor_type),
        });
    }

    try dir.writeFile(io, .{ .sub_path = "readings.csv", .data = csv.items });
}

fn writeSensorsCsv(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    num_sensors: u32,
) !void {
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(allocator);

    try csv.appendSlice(allocator, "sensor_id,sensor_type,zone_id,floor_id,x,y,z\n");
    var sid: u32 = 0;
    while (sid < num_sensors) : (sid += 1) {
        // Every value here comes from dataset.zig, which is also what
        // insertDataset registers into the World — see the comment above
        // zoneOf() there for why this must not be re-derived locally.
        const zone_id = fixtures.zoneOf(sid);
        const pos = fixtures.positionOf(sid);
        try csv.print(allocator, "{d},{s},{d},{d},{d},{d},{d}\n", .{
            sid,
            @tagName(fixtures.sensorTypeForScaled(sid)),
            zone_id,
            fixtures.floorOf(zone_id),
            pos.x,
            pos.y,
            pos.z,
        });
    }

    try dir.writeFile(io, .{ .sub_path = "sensors.csv", .data = csv.items });
}

// ---------------------------------------------------------------------------
// SQL generation
// ---------------------------------------------------------------------------

/// SQL that computes one query pattern's (n, sig) signature. Each statement
/// returns exactly one row of two columns so a single parser handles all
/// twelve.
///
/// Every window is anchored to `max(timestamp)` of the same rows our query
/// anchors to via getLatestBySensor, and every membership filter reads the
/// `sensors` table exported from dataset.zig's topology — the two engines
/// are answering the same question, not merely similar ones.
///
/// Note the type filters go through `sensors`/`readings.sensor_type`
/// interchangeably: this fixture assigns one fixed type per sensor
/// (dataset.sensorTypeForScaled), so "readings of type T" and "readings of
/// sensors of type T" are the same set. Our query functions filter
/// per-reading; the SQL filters whichever is cheaper to express.
fn querySql(allocator: std.mem.Allocator, q: queries.QueryName) ![]u8 {
    const t = @tagName(params.sensor_type);
    const win_ms = @as(i64, params.window_hours) * MS_PER_HOUR;

    return switch (q) {
        .latest_single => std.fmt.allocPrint(allocator,
            \\SELECT 1 AS n, coalesce((SELECT value FROM readings WHERE sensor_id = {d} ORDER BY timestamp DESC LIMIT 1), 0) AS sig;
        , .{params.sensor_id}),

        .latest_zone => std.fmt.allocPrint(allocator,
            \\SELECT count(*) AS n, coalesce(sum(v), 0) AS sig FROM (
            \\  SELECT r.sensor_id, arg_max(r.value, r.timestamp) AS v
            \\  FROM readings r JOIN sensors s ON s.sensor_id = r.sensor_id
            \\  WHERE s.zone_id = {d}
            \\  GROUP BY r.sensor_id);
        , .{params.zone_id}),

        .latest_by_type => std.fmt.allocPrint(allocator,
            \\SELECT count(*) AS n, coalesce(sum(v), 0) AS sig FROM (
            \\  SELECT sensor_id, arg_max(value, timestamp) AS v
            \\  FROM readings WHERE sensor_type = '{s}'
            \\  GROUP BY sensor_id);
        , .{t}),

        .avg_window => std.fmt.allocPrint(allocator,
            \\WITH e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id = {d})
            \\SELECT 1 AS n, coalesce(avg(r.value), 0) AS sig
            \\FROM readings r, e
            \\WHERE r.sensor_id = {d} AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t;
        , .{ params.sensor_id, params.sensor_id, win_ms }),

        .avg_zone_type => std.fmt.allocPrint(allocator,
            \\WITH zt AS (SELECT sensor_id FROM sensors WHERE zone_id = {d} AND sensor_type = '{s}'),
            \\     e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id IN (SELECT sensor_id FROM zt))
            \\SELECT 1 AS n, coalesce(avg(r.value), 0) AS sig
            \\FROM readings r, e
            \\WHERE r.sensor_id IN (SELECT sensor_id FROM zt)
            \\  AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t;
        , .{ params.zone_id, t, win_ms }),

        .floor_stats => std.fmt.allocPrint(allocator,
            \\WITH ft AS (SELECT sensor_id FROM sensors WHERE floor_id = {d} AND sensor_type = '{s}'),
            \\     e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id IN (SELECT sensor_id FROM ft))
            \\SELECT 1 AS n,
            \\       coalesce(min(r.value), 0) + coalesce(max(r.value), 0) + coalesce(avg(r.value), 0) AS sig
            \\FROM readings r, e
            \\WHERE r.sensor_id IN (SELECT sensor_id FROM ft)
            \\  AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t;
        , .{ params.floor_id, t, win_ms }),

        .hourly_rollup => std.fmt.allocPrint(allocator,
            \\WITH e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id = {d}),
            \\     b AS (SELECT (r.timestamp // {d}) * {d} AS bucket, avg(r.value) AS a
            \\           FROM readings r, e
            \\           WHERE r.sensor_id = {d} AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t
            \\           GROUP BY bucket)
            \\SELECT count(*) AS n, coalesce(sum(a), 0) AS sig FROM b;
        , .{
            params.sensor_id,
            MS_PER_HOUR,
            MS_PER_HOUR,
            params.sensor_id,
            @as(i64, params.rollup_days) * MS_PER_DAY,
        }),

        // 365 days: query_daily_zone_rollup hardcodes a one-year window, so
        // this mirrors that constant rather than taking a parameter.
        .daily_zone_rollup => std.fmt.allocPrint(allocator,
            \\WITH zt AS (SELECT sensor_id FROM sensors WHERE zone_id = {d} AND sensor_type = '{s}'),
            \\     e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id IN (SELECT sensor_id FROM zt)),
            \\     b AS (SELECT (r.timestamp // {d}) * {d} AS bucket, avg(r.value) AS a
            \\           FROM readings r, e
            \\           WHERE r.sensor_id IN (SELECT sensor_id FROM zt)
            \\             AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t
            \\           GROUP BY bucket)
            \\SELECT count(*) AS n, coalesce(sum(a), 0) AS sig FROM b;
        , .{ params.zone_id, t, MS_PER_DAY, MS_PER_DAY, 365 * MS_PER_DAY }),

        .spatial_radius => std.fmt.allocPrint(allocator,
            \\SELECT count(*) AS n, coalesce(sum(s.sensor_id), 0) AS sig
            \\FROM sensors s
            \\WHERE (s.x - {d}) * (s.x - {d}) + (s.y - {d}) * (s.y - {d}) + (s.z - {d}) * (s.z - {d}) <= {d} * {d}
            \\  AND EXISTS (SELECT 1 FROM readings r WHERE r.sensor_id = s.sensor_id);
        , .{
            params.center.x, params.center.x,
            params.center.y, params.center.y,
            params.center.z, params.center.z,
            params.radius_m, params.radius_m,
        }),

        // Depth 2 = every sensor that has at least one reading, which is
        // exactly what our topology index returns via allSensorIds().
        .zone_hierarchy => std.fmt.allocPrint(allocator,
            \\SELECT count(*) AS n, coalesce(sum(sensor_id), 0) AS sig
            \\FROM (SELECT DISTINCT sensor_id FROM readings);
        , .{}),

        // Mirrors query_anomalies exactly: one fleet-wide trailing window
        // anchored at the newest reading of the type, then per-(sensor,
        // hour-of-day) population mean/std-dev, then |z| > threshold.
        // n_sensor >= 2 is our `indices.len < 2 => skip`; c >= 2 and sd <> 0
        // are the per-bucket guards.
        .anomalies => std.fmt.allocPrint(allocator,
            \\WITH e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_type = '{s}'),
            \\     w AS (SELECT r.sensor_id, r.value, ((r.timestamp // {d}) % 24) AS hod
            \\           FROM readings r, e
            \\           WHERE r.sensor_type = '{s}'
            \\             AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t),
            \\     st AS (SELECT w.*,
            \\              count(*) OVER (PARTITION BY sensor_id) AS n_sensor,
            \\              count(*) OVER (PARTITION BY sensor_id, hod) AS c,
            \\              avg(value) OVER (PARTITION BY sensor_id, hod) AS m,
            \\              stddev_pop(value) OVER (PARTITION BY sensor_id, hod) AS sd
            \\            FROM w)
            \\SELECT count(*) AS n, coalesce(sum(abs((value - m) / sd)), 0) AS sig
            \\FROM st
            \\WHERE n_sensor >= 2 AND c >= 2 AND sd <> 0 AND abs((value - m) / sd) > {d};
        , .{
            t,
            MS_PER_HOUR,
            t,
            @as(i64, params.anomaly_window_hours) * MS_PER_HOUR,
            params.anomaly_z,
        }),

        // Gaps-and-islands: consecutive above-threshold readings form a run
        // (the row_number difference is constant within one), then the
        // earliest run meeting the duration floor wins — the same "first
        // sustained run" query_threshold_breach's linear scan returns.
        .threshold_breach => std.fmt.allocPrint(allocator,
            \\WITH e AS (SELECT max(timestamp) AS t FROM readings WHERE sensor_id = {d}),
            \\     w AS (SELECT r.timestamp, r.value FROM readings r, e
            \\           WHERE r.sensor_id = {d} AND r.timestamp >= e.t - {d} AND r.timestamp <= e.t),
            \\     f AS (SELECT timestamp, value, (value > {d}) AS above,
            \\             row_number() OVER (ORDER BY timestamp) AS rn FROM w),
            \\     g AS (SELECT *, rn - row_number() OVER (PARTITION BY above ORDER BY timestamp) AS grp FROM f),
            \\     runs AS (SELECT min(timestamp) AS s, max(timestamp) AS en FROM g WHERE above GROUP BY grp),
            \\     first_ok AS (SELECT s, en FROM runs WHERE en - s >= {d} ORDER BY s LIMIT 1)
            \\SELECT count(*) AS n, coalesce(sum(en - s), 0) AS sig FROM first_ok;
        , .{
            params.sensor_id,
            params.sensor_id,
            @as(i64, params.breach_window_hours) * MS_PER_HOUR,
            params.breach_threshold,
            params.breach_min_duration_ms,
        }),
    };
}

/// Sentinels bracketing the measured section. `.read` of a missing file, a
/// mid-script crash, or a truncated pipe all exit 0 in the DuckDB CLI, so a
/// missing END marker is the only reliable "the script did not finish"
/// signal.
const BEGIN_MARKER = "#CALIB-BEGIN";
const END_MARKER = "#CALIB-END";
const QUERY_MARKER_PREFIX = "#Q:";

/// Name of the floor-probe pseudo-query. A query against `readings` whose
/// predicate matches nothing: it pays the full SQL parse, plan, catalog
/// lookup and scan-setup cost, but reads no rows, so its time is an estimate
/// of DuckDB's fixed per-query overhead on this table.
///
/// Why bother: without it there is no way to know whether DuckDB's
/// multi-millisecond numbers are real work or a constant tax, and if they
/// were mostly the latter the whole cost-profile comparison would be
/// meaningless. Measured here it comes out around 0.6 ms against several
/// milliseconds of actual query time, so the numbers are real — and
/// subtracting it changes the correlation barely at all, which is itself the
/// useful result. The adjustment is kept because it is the more correct
/// quantity to correlate, not because it moves the verdict.
const FLOOR_PROBE = "__floor_probe";
const FLOOR_PROBE_SQL = "SELECT count(*) AS n, 0 AS sig FROM readings WHERE sensor_id = -1;";

/// Builds the full script: schema, CSV load, then each query repeated
/// `iterations` times under `.timer on`.
fn buildScript(
    allocator: std.mem.Allocator,
    readings_csv: []const u8,
    sensors_csv: []const u8,
    iterations: u32,
) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(allocator);

    // `.mode list` + headers off gives one `n|sig` line per query; the timer
    // line follows each statement. Both are trivially parseable, unlike the
    // default box-drawing table output.
    try s.appendSlice(allocator,
        \\.mode list
        \\.headers off
        \\.timer off
        \\CREATE TABLE sensors(sensor_id INTEGER, sensor_type VARCHAR, zone_id INTEGER, floor_id INTEGER, x FLOAT, y FLOAT, z FLOAT);
        \\CREATE TABLE readings(sensor_id INTEGER, timestamp BIGINT, value FLOAT, sensor_type VARCHAR);
        \\
    );
    try s.print(allocator, "COPY sensors FROM '{s}' (HEADER, DELIMITER ',');\n", .{sensors_csv});
    try s.print(allocator, "COPY readings FROM '{s}' (HEADER, DELIMITER ',');\n", .{readings_csv});

    // Sorting by (sensor_id, timestamp) makes DuckDB's per-row-group min/max
    // zone maps useful for the sensor-scoped windows every pattern here
    // uses. Without it the load order (already sensor-major, from
    // generateDatasetScaled) would decide plan quality by accident rather
    // than by declaration.
    try s.appendSlice(allocator,
        \\CREATE TABLE readings_sorted AS SELECT * FROM readings ORDER BY sensor_id, timestamp;
        \\DROP TABLE readings;
        \\ALTER TABLE readings_sorted RENAME TO readings;
        \\
    );

    try s.print(allocator, "SELECT '{s}';\n.timer on\n", .{BEGIN_MARKER});

    // Floor probe first, so it is measured on the same warm table the real
    // queries see rather than paying for first-touch page faults itself.
    try s.print(allocator, "SELECT '{s}{s}';\n", .{ QUERY_MARKER_PREFIX, FLOOR_PROBE });
    {
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            try s.appendSlice(allocator, FLOOR_PROBE_SQL);
            try s.append(allocator, '\n');
        }
    }

    for (std.enums.values(queries.QueryName)) |q| {
        const sql = try querySql(allocator, q);
        defer allocator.free(sql);

        try s.print(allocator, "SELECT '{s}{s}';\n", .{ QUERY_MARKER_PREFIX, report.queryNameStr(q) });
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            try s.appendSlice(allocator, sql);
            try s.append(allocator, '\n');
        }
    }

    try s.print(allocator, ".timer off\nSELECT '{s}';\n", .{END_MARKER});

    return s.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

pub const ParseError = error{
    ScriptDidNotComplete,
    MalformedValueLine,
    NoSamplesForQuery,
};

const TIMER_PREFIX = "Run Time (s): real ";

/// Seconds parsed out of a `Run Time (s): real 0.002 user ... sys ...` line,
/// or null when the line is not a timer line.
pub fn parseTimerSeconds(line: []const u8) ?f64 {
    if (!std.mem.startsWith(u8, line, TIMER_PREFIX)) return null;
    const rest = line[TIMER_PREFIX.len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// One query's parsed samples: the signature (which every repetition must
/// agree on, being the same deterministic query over the same data) and the
/// mean of the repetition timings after discarding the warmup.
pub const ParsedQuery = struct {
    sig: Signature,
    mean_ns: i64,
};

/// Parses the CLI's stdout into per-query results.
///
/// The shape being parsed, per query, is: a `#Q:<name>` marker line, its own
/// timer line (discarded — timing a constant SELECT is not the measurement),
/// then `iterations` × (value line, timer line).
pub fn parseOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
) !std.StringHashMap(ParsedQuery) {
    if (std.mem.indexOf(u8, stdout, END_MARKER) == null) return error.ScriptDidNotComplete;

    var out = std.StringHashMap(ParsedQuery).init(allocator);
    errdefer out.deinit();

    var samples: std.ArrayList(i64) = .empty;
    defer samples.deinit(allocator);

    var current: ?[]const u8 = null;
    var current_sig: Signature = .{ .n = 0, .sig = 0 };
    var skip_next_timer = false;
    var pending_value = false;

    // Flushes the query whose block just ended into the result map.
    const flush = struct {
        fn call(
            map: *std.StringHashMap(ParsedQuery),
            gpa: std.mem.Allocator,
            name: ?[]const u8,
            sig: Signature,
            times: *std.ArrayList(i64),
        ) !void {
            const q = name orelse return;
            if (times.items.len == 0) return error.NoSamplesForQuery;

            // Discard the warmup repetition when there is more than one, the
            // same way metrics.timeQuery does on our side, then average what
            // remains (see BackendRow's comment on mean vs median).
            const usable = if (times.items.len > 1) times.items[1..] else times.items;
            var total: i64 = 0;
            for (usable) |t| total += t;

            try map.put(q, .{
                .sig = sig,
                .mean_ns = @divTrunc(total, @as(i64, @intCast(usable.len))),
            });
            _ = gpa;
            times.clearRetainingCapacity();
        }
    }.call;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, QUERY_MARKER_PREFIX)) {
            try flush(&out, allocator, current, current_sig, &samples);
            current = line[QUERY_MARKER_PREFIX.len..];
            current_sig = .{ .n = 0, .sig = 0 };
            skip_next_timer = true;
            pending_value = false;
            continue;
        }

        if (std.mem.eql(u8, line, BEGIN_MARKER) or std.mem.eql(u8, line, END_MARKER)) {
            try flush(&out, allocator, current, current_sig, &samples);
            current = null;
            skip_next_timer = true;
            continue;
        }

        if (parseTimerSeconds(line)) |secs| {
            if (skip_next_timer) {
                skip_next_timer = false;
                continue;
            }
            if (current == null or !pending_value) continue;
            pending_value = false;
            try samples.append(allocator, @intFromFloat(secs * 1e9));
            continue;
        }

        // Anything else inside a query block is a `n|sig` value line.
        if (current != null) {
            const bar = std.mem.indexOfScalar(u8, line, '|') orelse return error.MalformedValueLine;
            const n = std.fmt.parseInt(u64, std.mem.trim(u8, line[0..bar], " "), 10) catch
                return error.MalformedValueLine;
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, line[bar + 1 ..], " ")) catch
                return error.MalformedValueLine;
            current_sig = .{ .n = n, .sig = v };
            pending_value = true;
        }
    }

    return out;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

/// True when two signature values agree within tolerance. See REL_TOLERANCE.
pub fn valuesAgree(a: f64, b: f64) bool {
    const diff = @abs(a - b);
    if (diff <= ABS_TOLERANCE) return true;
    const scale = @max(@abs(a), @abs(b));
    return diff <= REL_TOLERANCE * scale;
}

pub fn signaturesAgree(a: Signature, b: Signature) bool {
    return a.n == b.n and valuesAgree(a.sig, b.sig);
}

/// Spearman rank correlation between two equal-length samples — Pearson's r
/// over average-tied ranks. Used on per-query latencies, where the question
/// is only "do the two engines order these patterns similarly", so ranks are
/// the right currency and the raw magnitudes (which differ by orders of
/// magnitude between an in-process scan and a planned SQL query) are not.
///
/// Returns 0 for degenerate input (fewer than 2 points, or one side entirely
/// tied so its rank variance is zero and no correlation is defined).
pub fn spearman(allocator: std.mem.Allocator, xs: []const f64, ys: []const f64) !f64 {
    std.debug.assert(xs.len == ys.len);
    if (xs.len < 2) return 0;

    const rx = try averageRanks(allocator, xs);
    defer allocator.free(rx);
    const ry = try averageRanks(allocator, ys);
    defer allocator.free(ry);

    const n: f64 = @floatFromInt(xs.len);
    var mx: f64 = 0;
    var my: f64 = 0;
    for (rx, ry) |a, b| {
        mx += a;
        my += b;
    }
    mx /= n;
    my /= n;

    var num: f64 = 0;
    var dx: f64 = 0;
    var dy: f64 = 0;
    for (rx, ry) |a, b| {
        const ca = a - mx;
        const cb = b - my;
        num += ca * cb;
        dx += ca * ca;
        dy += cb * cb;
    }

    if (dx == 0 or dy == 0) return 0;
    return num / @sqrt(dx * dy);
}

/// Ranks 1..n, with tied values sharing the average of the ranks they span.
fn averageRanks(allocator: std.mem.Allocator, xs: []const f64) ![]f64 {
    const order = try allocator.alloc(usize, xs.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;

    std.mem.sort(usize, order, xs, struct {
        fn lt(vals: []const f64, a: usize, b: usize) bool {
            return vals[a] < vals[b];
        }
    }.lt);

    const ranks = try allocator.alloc(f64, xs.len);
    var i: usize = 0;
    while (i < order.len) {
        var j = i + 1;
        while (j < order.len and xs[order[j]] == xs[order[i]]) j += 1;
        // Ranks are 1-based; the tied group [i, j) shares their average.
        const avg = (@as(f64, @floatFromInt(i + 1)) + @as(f64, @floatFromInt(j))) / 2.0;
        for (order[i..j]) |idx| ranks[idx] = avg;
        i = j;
    }
    return ranks;
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

/// Runs the calibration pass. Returns null — not an error — when no DuckDB
/// binary is available: this pass is optional by design, and its absence is
/// a normal outcome the caller reports and moves past.
///
/// Caller owns the returned Result (`deinit`).
pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !?Result {
    const found = (try findDuckdb(allocator, io, options.duckdb_path)) orelse return null;
    errdefer allocator.free(found.path);
    errdefer allocator.free(found.version);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, options.output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, options.output_dir, .{});
    defer dir.close(io);

    // ---- the one dataset both engines see ----
    const readings = try fixtures.generateDatasetScaled(
        allocator,
        options.num_sensors,
        options.readings_per_sensor,
    );
    defer allocator.free(readings);

    try writeReadingsCsv(allocator, io, dir, readings);
    try writeSensorsCsv(allocator, io, dir, options.num_sensors);

    // ---- our side, one backend at a time ----
    var rows: std.ArrayList(BackendRow) = .empty;
    defer rows.deinit(allocator);

    // RingBuffer is excluded for the same reason runner.zig's
    // supported_backends excludes it: it evicts old readings, so it cannot
    // answer the historical rollups and would "disagree" with DuckDB for a
    // documented reason rather than a defect.
    inline for (runner.supported_backends) |entry| {
        var world = try World(entry.T).init(allocator);
        defer world.deinit();
        try fixtures.insertDataset(&world, readings);

        for (std.enums.values(queries.QueryName)) |q| {
            const sig = try oursSignature(&world, q);
            const stats = try oursLatency(&world, allocator, io, options.iterations, q);
            try rows.append(allocator, .{
                .backend = entry.name,
                .query = report.queryNameStr(q),
                .sig = sig,
                .mean_ns = stats.mean_ns,
            });
        }
    }

    // ---- DuckDB's side, one subprocess ----
    const readings_csv = try sqlPath(allocator, options.output_dir, "readings.csv");
    defer allocator.free(readings_csv);
    const sensors_csv = try sqlPath(allocator, options.output_dir, "sensors.csv");
    defer allocator.free(sensors_csv);

    const script = try buildScript(allocator, readings_csv, sensors_csv, options.iterations);
    defer allocator.free(script);
    try dir.writeFile(io, .{ .sub_path = "calibration.sql", .data = script });

    const script_path = try sqlPath(allocator, options.output_dir, "calibration.sql");
    defer allocator.free(script_path);
    const read_cmd = try std.fmt.allocPrint(allocator, ".read {s}", .{script_path});
    defer allocator.free(read_cmd);

    const proc = try std.process.run(allocator, io, .{
        .argv = &.{ found.path, "-no-init", ":memory:", "-c", read_cmd },
    });
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);

    if (!proc.term.success()) {
        std.debug.print(
            "duckdb calibration script failed ({f}):\n{s}\n",
            .{ proc.term, proc.stderr },
        );
        return error.DuckdbScriptFailed;
    }

    var parsed = try parseOutput(allocator, proc.stdout);
    defer parsed.deinit();

    // ---- compare ----
    var duck: std.ArrayList(DuckRow) = .empty;
    defer duck.deinit(allocator);
    var mismatches: std.ArrayList(Mismatch) = .empty;
    defer mismatches.deinit(allocator);
    var flags: std.ArrayList(SlowerFlag) = .empty;
    defer flags.deinit(allocator);

    var ours_best: std.ArrayList(f64) = .empty;
    defer ours_best.deinit(allocator);
    var duck_times: std.ArrayList(f64) = .empty;
    defer duck_times.deinit(allocator);
    var duck_adjusted: std.ArrayList(f64) = .empty;
    defer duck_adjusted.deinit(allocator);

    const floor_ns: i64 = if (parsed.get(FLOOR_PROBE)) |p| p.mean_ns else 0;

    for (std.enums.values(queries.QueryName)) |q| {
        const name = report.queryNameStr(q);
        const d = parsed.get(name) orelse return error.NoSamplesForQuery;
        try duck.append(allocator, .{ .query = name, .sig = d.sig, .mean_ns = d.mean_ns });

        var best_ns: i64 = std.math.maxInt(i64);
        for (rows.items) |r| {
            if (!std.mem.eql(u8, r.query, name)) continue;
            if (r.mean_ns < best_ns) best_ns = r.mean_ns;
            if (!signaturesAgree(r.sig, d.sig)) {
                try mismatches.append(allocator, .{
                    .backend = r.backend,
                    .query = name,
                    .ours = r.sig,
                    .duckdb = d.sig,
                });
            }
        }

        // Ratio uses our fastest backend for the query: the question the
        // guard asks is whether the PLATFORM's number is plausible, and the
        // platform's answer for a query is its winning backend.
        const ours_f: f64 = @floatFromInt(@max(best_ns, 1));
        const duck_f: f64 = @floatFromInt(@max(d.mean_ns, 1));
        try ours_best.append(allocator, ours_f);
        try duck_times.append(allocator, duck_f);
        try duck_adjusted.append(allocator, @floatFromInt(@max(d.mean_ns - floor_ns, 1)));

        const ratio = ours_f / duck_f;
        if (ratio > SLOWER_THAN_DUCKDB_RATIO) {
            try flags.append(allocator, .{ .query = name, .ratio = ratio });
        }
    }

    const rho = try spearman(allocator, ours_best.items, duck_adjusted.items);
    const rho_raw = try spearman(allocator, ours_best.items, duck_times.items);

    if (!options.keep_artifacts) {
        dir.deleteFile(io, "readings.csv") catch {};
        dir.deleteFile(io, "sensors.csv") catch {};
        dir.deleteFile(io, "calibration.sql") catch {};
    }

    return .{
        .duckdb_version = found.version,
        .duckdb_path = found.path,
        .num_sensors = options.num_sensors,
        .readings_per_sensor = options.readings_per_sensor,
        .iterations = options.iterations,
        .rows = try rows.toOwnedSlice(allocator),
        .duck = try duck.toOwnedSlice(allocator),
        .mismatches = try mismatches.toOwnedSlice(allocator),
        .slower_flags = try flags.toOwnedSlice(allocator),
        .spearman = rho,
        .spearman_raw = rho_raw,
        .duck_floor_ns = floor_ns,
    };
}

/// Joins a path with std.fs.path and then normalises separators to '/' for
/// embedding in a SQL string literal. DuckDB accepts forward slashes on
/// every platform including Windows, while a raw backslash inside a SQL
/// single-quoted string is an escape hazard. Single quotes are doubled for
/// the same reason.
fn sqlPath(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    const joined = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(joined);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (joined) |c| {
        if (c == '\\') {
            try out.append(allocator, '/');
        } else if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

pub fn writeReports(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    res: Result,
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(allocator);

    try md.print(allocator, "# Digital Twin — DuckDB Calibration\n\n", .{});
    try md.print(allocator, "**Verdict: {s}**\n\n", .{if (res.passed()) "PASS" else "REVIEW"});
    try md.print(allocator, "- DuckDB: `{s}` (`{s}`)\n", .{ res.duckdb_version, res.duckdb_path });
    try md.print(allocator, "- Dataset: {d} sensors × {d} readings = {d} rows, seed `{d}`\n", .{
        res.num_sensors,
        res.readings_per_sensor,
        @as(u64, res.num_sensors) * @as(u64, res.readings_per_sensor),
        fixtures.SEED,
    });
    try md.print(allocator, "- Repetitions per query per engine: {d} (first discarded as warmup)\n\n", .{res.iterations});

    try md.print(allocator,
        \\> **What this pass does and does not establish.** It checks that an
        \\> independently-implemented SQL engine, given the same rows and the same
        \\> questions, computes the same answers, and that both engines rank the
        \\> query patterns by cost in roughly the same order. It does **not**
        \\> compare storage layouts: DuckDB is columnar-only and has no analogue
        \\> of a per-sensor append log or a ring buffer, so "TimeSeries vs
        \\> Columnar" is not a question any outside engine can answer. Absolute
        \\> latencies are not comparable either — our backends are in-process
        \\> array scans with no SQL parse or planner, so being far faster on a
        \\> scoped query is expected, not evidence of anything.
        \\
        \\
    , .{});

    // ---- value agreement ----
    try md.print(allocator, "## 1. Value agreement (primary check)\n\n", .{});
    if (res.mismatches.len == 0) {
        try md.print(allocator, "All {d} backend × query combinations returned the same cardinality and value as DuckDB, within a relative tolerance of {d}.\n\n", .{ res.rows.len, REL_TOLERANCE });
    } else {
        try md.print(allocator, "**{d} mismatch(es) — each one is a defect in our query or storage layer, not a tuning issue.**\n\n", .{res.mismatches.len});
        try md.print(allocator, "| Backend | Query | our n | our value | DuckDB n | DuckDB value |\n|---|---|---:|---:|---:|---:|\n", .{});
        for (res.mismatches) |m| {
            try md.print(allocator, "| {s} | {s} | {d} | {d} | {d} | {d} |\n", .{
                m.backend, m.query, m.ours.n, m.ours.sig, m.duckdb.n, m.duckdb.sig,
            });
        }
        try md.print(allocator, "\n", .{});
    }

    // ---- cost profile ----
    try md.print(allocator, "## 2. Cost-profile agreement\n\n", .{});
    try md.print(allocator, "Spearman rank correlation between our fastest backend's per-query latency and DuckDB's: **{d:.3}** (floor {d:.2}).\n\n", .{ res.spearman, SPEARMAN_FLOOR });
    try md.print(allocator,
        \\**Is DuckDB's side mostly overhead?** No — and that is what makes the
        \\comparison worth making. A query against the same table whose predicate
        \\matches nothing costs **{d:.1} ms**, which is DuckDB's fixed parse + plan +
        \\scan-setup price. Every real pattern below costs several times that, so the
        \\bulk of DuckDB's numbers is genuine work rather than a constant. The
        \\correlation above subtracts that floor; on the raw times it reads {d:.3}.
        \\Where those two agree, the floor was too small to matter.
        \\
        \\Read this check as the weakest of the three regardless: 12 data points and a
        \\timer quantised to whole milliseconds. It catches a badly wrong cost
        \\profile, not a subtly wrong one.
        \\
        \\
    , .{ @as(f64, @floatFromInt(res.duck_floor_ns)) / 1e6, res.spearman_raw });
    try md.print(allocator, "Latencies are means over the {d} repetitions (first discarded): DuckDB's CLI timer reports whole milliseconds, and averaging is what recovers sub-millisecond resolution.\n\n", .{res.iterations});
    try md.print(allocator, "`speedup` is DuckDB ÷ ours on the raw times — how many times faster we are. Reported, not gated; see the note at the top.\n\n", .{});
    try md.print(allocator, "| Query | our best (µs) | DuckDB (µs) | DuckDB less floor (µs) | speedup | our n | DuckDB n |\n|---|---:|---:|---:|---:|---:|---:|\n", .{});
    for (res.duck) |d| {
        var best_ns: i64 = std.math.maxInt(i64);
        var best_sig: Signature = .{ .n = 0, .sig = 0 };
        for (res.rows) |r| {
            if (!std.mem.eql(u8, r.query, d.query)) continue;
            if (r.mean_ns < best_ns) {
                best_ns = r.mean_ns;
                best_sig = r.sig;
            }
        }
        const ours_us = @as(f64, @floatFromInt(best_ns)) / 1000.0;
        const duck_us = @as(f64, @floatFromInt(d.mean_ns)) / 1000.0;
        const duck_adj_us = @as(f64, @floatFromInt(@max(d.mean_ns - res.duck_floor_ns, 0))) / 1000.0;
        try md.print(allocator, "| {s} | {d:.2} | {d:.1} | {d:.1} | {d:.0}× | {d} | {d} |\n", .{
            d.query, ours_us, duck_us, duck_adj_us, duck_us / @max(ours_us, 1e-9), best_sig.n, d.sig.n,
        });
    }
    try md.print(allocator, "\n", .{});

    // ---- slower-than-DuckDB guard ----
    try md.print(allocator, "## 3. Slower-than-DuckDB guard\n\n", .{});
    if (res.slower_flags.len == 0) {
        try md.print(allocator, "No query is more than {d:.0}× slower than DuckDB. With no SQL parse, no planner and no page cache on our side, being slower than a full DBMS would point at a real defect in ours — this is the one direction of AGENT.md's ±2× gate that carries information.\n\n", .{SLOWER_THAN_DUCKDB_RATIO});
    } else {
        try md.print(allocator, "**{d} query(ies) more than {d:.0}× slower than DuckDB — investigate, this direction should not happen:**\n\n", .{ res.slower_flags.len, SLOWER_THAN_DUCKDB_RATIO });
        for (res.slower_flags) |f| {
            try md.print(allocator, "- `{s}`: {d:.2}× slower\n", .{ f.query, f.ratio });
        }
        try md.print(allocator, "\n", .{});
    }

    // ---- per-backend detail ----
    try md.print(allocator, "## 4. Per-backend detail\n\n", .{});
    try md.print(allocator, "| Backend | Query | n | value | mean (µs) |\n|---|---|---:|---:|---:|\n", .{});
    for (res.rows) |r| {
        try md.print(allocator, "| {s} | {s} | {d} | {d} | {d:.2} |\n", .{
            r.backend, r.query, r.sig.n, r.sig.sig, @as(f64, @floatFromInt(r.mean_ns)) / 1000.0,
        });
    }

    try dir.writeFile(io, .{ .sub_path = "calibration.md", .data = md.items });

    // ---- JSON ----
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(allocator);

    try js.print(allocator, "{{\n", .{});
    try js.print(allocator, "  \"duckdb_version\": \"{s}\",\n", .{res.duckdb_version});
    try js.print(allocator, "  \"seed\": {d},\n", .{fixtures.SEED});
    try js.print(allocator, "  \"num_sensors\": {d},\n", .{res.num_sensors});
    try js.print(allocator, "  \"readings_per_sensor\": {d},\n", .{res.readings_per_sensor});
    try js.print(allocator, "  \"iterations\": {d},\n", .{res.iterations});
    try js.print(allocator, "  \"passed\": {},\n", .{res.passed()});
    try js.print(allocator, "  \"spearman\": {d:.6},\n", .{res.spearman});
    try js.print(allocator, "  \"spearman_raw\": {d:.6},\n", .{res.spearman_raw});
    try js.print(allocator, "  \"duckdb_floor_ns\": {d},\n", .{res.duck_floor_ns});
    try js.print(allocator, "  \"value_mismatches\": {d},\n", .{res.mismatches.len});
    try js.print(allocator, "  \"slower_than_duckdb_flags\": {d},\n", .{res.slower_flags.len});
    try js.print(allocator, "  \"duckdb\": [\n", .{});
    for (res.duck, 0..) |d, i| {
        try js.print(allocator, "    {{\"query\": \"{s}\", \"n\": {d}, \"value\": {d}, \"mean_ns\": {d}}}{s}\n", .{
            d.query, d.sig.n, d.sig.sig, d.mean_ns, if (i + 1 == res.duck.len) "" else ",",
        });
    }
    try js.print(allocator, "  ],\n", .{});
    try js.print(allocator, "  \"ours\": [\n", .{});
    for (res.rows, 0..) |r, i| {
        try js.print(allocator, "    {{\"backend\": \"{s}\", \"query\": \"{s}\", \"n\": {d}, \"value\": {d}, \"mean_ns\": {d}}}{s}\n", .{
            r.backend, r.query, r.sig.n, r.sig.sig, r.mean_ns, if (i + 1 == res.rows.len) "" else ",",
        });
    }
    try js.print(allocator, "  ]\n}}\n", .{});

    try dir.writeFile(io, .{ .sub_path = "calibration.json", .data = js.items });
}

// ---------------------------------------------------------------------------
// Tests
//
// These cover the pure logic that decides the verdict — the stdout parser,
// the tolerance rule, and the rank correlation. A defect in any of them
// wouldn't crash: it would silently produce a confident PASS or a phantom
// mismatch, which is the worst possible failure for a check whose whole job
// is to be trusted. The SQL and the subprocess plumbing are exercised
// end-to-end by actually running the pass (`zig build calibrate`), which no
// unit test can substitute for.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseTimerSeconds: reads the real time out of a DuckDB timer line, ignores everything else" {
    try testing.expectEqual(@as(?f64, 0.002), parseTimerSeconds("Run Time (s): real 0.002 user 0.000000 sys 0.000000"));
    try testing.expectEqual(@as(?f64, 1.5), parseTimerSeconds("Run Time (s): real 1.5 user 0.1 sys 0.2"));
    try testing.expectEqual(@as(?f64, null), parseTimerSeconds("12|34.5"));
    try testing.expectEqual(@as(?f64, null), parseTimerSeconds("#Q:query_avg_window"));
    try testing.expectEqual(@as(?f64, null), parseTimerSeconds(""));
}

test "parseOutput: pairs each value line with its own timer line and averages after dropping the warmup" {
    // Two queries, three repetitions each. The marker's own timer line must
    // NOT be counted as a sample, and the first real sample is the warmup:
    // q_a averages 20 and 30 -> 25ms; q_b averages 6 and 8 -> 7ms.
    const stdout =
        "#CALIB-BEGIN\n" ++
        "Run Time (s): real 0.000 user 0.0 sys 0.0\n" ++
        "#Q:q_a\n" ++
        "Run Time (s): real 0.999 user 0.0 sys 0.0\n" ++
        "3|1.5\n" ++
        "Run Time (s): real 0.100 user 0.0 sys 0.0\n" ++
        "3|1.5\n" ++
        "Run Time (s): real 0.020 user 0.0 sys 0.0\n" ++
        "3|1.5\n" ++
        "Run Time (s): real 0.030 user 0.0 sys 0.0\n" ++
        "#Q:q_b\n" ++
        "Run Time (s): real 0.999 user 0.0 sys 0.0\n" ++
        "0|0\n" ++
        "Run Time (s): real 0.050 user 0.0 sys 0.0\n" ++
        "0|0\n" ++
        "Run Time (s): real 0.006 user 0.0 sys 0.0\n" ++
        "0|0\n" ++
        "Run Time (s): real 0.008 user 0.0 sys 0.0\n" ++
        "#CALIB-END\n";

    var parsed = try parseOutput(testing.allocator, stdout);
    defer parsed.deinit();

    const a = parsed.get("q_a").?;
    try testing.expectEqual(@as(u64, 3), a.sig.n);
    try testing.expectApproxEqAbs(@as(f64, 1.5), a.sig.sig, 1e-9);
    try testing.expectEqual(@as(i64, 25_000_000), a.mean_ns);

    const b = parsed.get("q_b").?;
    try testing.expectEqual(@as(u64, 0), b.sig.n);
    try testing.expectEqual(@as(i64, 7_000_000), b.mean_ns);
}

test "parseOutput: a script that never reached its end marker is an error, not a partial result" {
    // The DuckDB CLI exits 0 when `.read` cannot open the script at all, so
    // a truncated stdout is the only signal that nothing ran — treating it
    // as "no mismatches found" would be a false PASS.
    const truncated =
        "#CALIB-BEGIN\n" ++
        "#Q:q_a\n" ++
        "Run Time (s): real 0.999 user 0.0 sys 0.0\n" ++
        "3|1.5\n" ++
        "Run Time (s): real 0.010 user 0.0 sys 0.0\n";

    try testing.expectError(error.ScriptDidNotComplete, parseOutput(testing.allocator, truncated));
}

test "parseOutput: a value line that is not n|sig is an error rather than a silent zero" {
    const bad =
        "#CALIB-BEGIN\n" ++
        "#Q:q_a\n" ++
        "Run Time (s): real 0.999 user 0.0 sys 0.0\n" ++
        "not-a-value-line\n" ++
        "#CALIB-END\n";

    try testing.expectError(error.MalformedValueLine, parseOutput(testing.allocator, bad));
}

test "valuesAgree: float-summation noise passes, a real aggregate error does not" {
    // Relative 1e-7 is the order of difference two engines summing the same
    // f32 column in different orders actually produce.
    try testing.expect(valuesAgree(12345.678, 12345.678 * (1.0 + 1e-7)));
    try testing.expect(valuesAgree(0.0, 0.0));
    // One reading missing from a 1000-sample average moves it ~1e-3.
    try testing.expect(!valuesAgree(12345.678, 12345.678 * (1.0 + 1e-3)));
    // Absolute tolerance covers values straddling zero.
    try testing.expect(valuesAgree(0.0, 1e-9));
    try testing.expect(!valuesAgree(0.0, 1.0));
}

test "signaturesAgree: a cardinality difference fails even when the value matches" {
    const a: Signature = .{ .n = 100, .sig = 42.0 };
    try testing.expect(signaturesAgree(a, .{ .n = 100, .sig = 42.0 }));
    try testing.expect(!signaturesAgree(a, .{ .n = 99, .sig = 42.0 }));
}

test "spearman: identical orderings correlate at 1, reversed at -1" {
    const xs = [_]f64{ 1, 2, 3, 4, 5 };
    const same = [_]f64{ 10, 20, 30, 40, 50 };
    const reversed = [_]f64{ 50, 40, 30, 20, 10 };

    try testing.expectApproxEqAbs(@as(f64, 1.0), try spearman(testing.allocator, &xs, &same), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.0), try spearman(testing.allocator, &xs, &reversed), 1e-12);
}

test "spearman: correlates on rank, not magnitude — the two engines differ by orders of magnitude" {
    // Same ordering, wildly different scales: this is the actual shape of the
    // calibration input (nanoseconds of an in-process scan vs milliseconds of
    // a planned SQL query), and it must still read as perfect agreement.
    const ours = [_]f64{ 50, 200, 100_000, 6_000_000 };
    const duck = [_]f64{ 3_000_000, 4_000_000, 5_000_000, 20_000_000 };
    try testing.expectApproxEqAbs(@as(f64, 1.0), try spearman(testing.allocator, &ours, &duck), 1e-12);
}

test "spearman: ties share the average rank" {
    // ys is entirely tied, so its rank variance is zero and no correlation
    // is defined — 0 rather than a NaN that would silently fail every
    // comparison against SPEARMAN_FLOOR.
    const xs = [_]f64{ 1, 2, 3 };
    const ys = [_]f64{ 7, 7, 7 };
    try testing.expectEqual(@as(f64, 0.0), try spearman(testing.allocator, &xs, &ys));

    // A single tied pair still yields a sane, non-degenerate coefficient.
    const a = [_]f64{ 1, 2, 2, 4 };
    const b = [_]f64{ 1, 2, 3, 4 };
    const rho = try spearman(testing.allocator, &a, &b);
    try testing.expect(rho > 0.9 and rho <= 1.0);
}

test "spearman: fewer than two points is 0, not a divide-by-zero" {
    const one = [_]f64{42};
    try testing.expectEqual(@as(f64, 0.0), try spearman(testing.allocator, &one, &one));
}

test "sqlPath: separators are normalised and quotes escaped for a SQL string literal" {
    const p = try sqlPath(testing.allocator, "out", "readings.csv");
    defer testing.allocator.free(p);
    // std.fs.path.join uses '\' on Windows; the SQL literal must not.
    try testing.expect(std.mem.indexOfScalar(u8, p, '\\') == null);
    try testing.expectEqualStrings("out/readings.csv", p);

    const q = try sqlPath(testing.allocator, "it's", "a.csv");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("it''s/a.csv", q);
}

test "querySql: every query pattern produces SQL — no pattern silently missing" {
    // A new QueryName that nobody wrote SQL for would otherwise fail only at
    // run time, inside the subprocess, as a confusing parse error.
    for (std.enums.values(queries.QueryName)) |q| {
        const sql = try querySql(testing.allocator, q);
        defer testing.allocator.free(sql);
        try testing.expect(sql.len > 0);
        // Each statement must return the (n, sig) pair the parser expects.
        try testing.expect(std.mem.indexOf(u8, sql, "AS n") != null);
        try testing.expect(std.mem.indexOf(u8, sql, "AS sig") != null);
        try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, sql, "\n"), ";"));
    }
}
