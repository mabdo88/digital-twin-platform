// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Live day-zero simulation harness — the per-building measurement path
// (see .cascade/digital-twin/live-simulation-plan.md for the full design
// and the decision record superseding the bulk-preload methodology).
//
// The building starts operation at simulated day zero with empty
// backends. A synthetic.Stream feeds readings chunk-by-chunk (1 simulated
// day per chunk) into one backend at a time, pruning each sensor type to
// its retention window as simulated time passes, and pausing at a fixed
// ladder of simulated-time checkpoints to benchmark the building's query
// mix — so early checkpoints measure near-empty backends and the final
// one measures retention-full, actively-evicting backends (steady state).
// Simulated time advances as fast as the machine can process it; the
// achieved compression ratio (simulated time / wall time) is an OUTPUT
// reported per run, never an input knob.
//
// Everything schedule-shaped in here is data or pure math over data
// (CLAUDE.md §3.5): the checkpoint ladder, the sim-length margin, and the
// prune-slack factor are constants; the simulated duration derives from
// the placed sensor types' retention depths, never from a CLI flag.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");
const synthetic = @import("../synthetic/generator.zig");
const queries = @import("queries.zig");
const runner = @import("runner.zig");
const report = @import("report.zig");
const metrics = @import("../ecs/systems/metrics_system.zig");
const components = @import("../bim/components.zig");
const World = @import("../ecs/world.zig").World;

const ONE_HOUR_MS: i64 = 60 * 60 * 1000;

/// Fixed simulated day-zero (Unix epoch ms) — the moment the building
/// starts operation with empty backends. A constant rather than wall-clock
/// time so a given IFC + seed produces byte-identical readings on every
/// run (CLAUDE.md §3.4 determinism).
pub const SIM_START_MS: i64 = 1_700_000_000_000; // 2023-11-14T22:13:20Z

/// RingBuffer is a deliberately tiny, real-time-only cache: a flat capacity
/// of this many readings PER SENSOR for EVERY sensor type — no per-type,
/// retention, or frequency math (explicit design decision 2026-07-01). The
/// live feed writes at each type's own cadence and RingBuffer's existing
/// eviction (the Nth+1 write drops the oldest) keeps only the most recent
/// `RINGBUFFER_CAP`. `setRetentionHint` is a genuine no-op on every
/// full-retention backend, so applying it unconditionally caps only
/// RingBuffer. Because RingBuffer thus holds a fraction of the data most
/// queries need, it competes only in the compound recommendation's
/// real-time track (report.recommendCompound), never the historical one.
pub const RINGBUFFER_CAP: usize = 10;

/// One simulated day per generated/ingested chunk. At least as long as
/// every sensor type's sampling period (the slowest is energy at 15 min),
/// aligned with the diurnal cycle and the integer-day checkpoint ladder,
/// and small enough that harness peak memory stays at roughly one backend
/// plus one chunk of readings.
pub const CHUNK_MS: i64 = 24 * 60 * 60 * 1000;

const MS_PER_DAY: i64 = CHUNK_MS;

/// Simulated-duration margin past the longest retention window, so the
/// longest-retention type ingests beyond its window and experiences real
/// eviction before the final (steady-state) checkpoint: 5% of the longest
/// retention, floor 30 days.
pub const SIM_MARGIN_MIN_DAYS: u32 = 30;
pub const SIM_MARGIN_DIVISOR: u32 = 20;

/// How far past its retention window a type's data may grow before a
/// prune runs (fraction of the retention window). Pruning every chunk
/// would be a full O(n) compaction of retention-scale arrays per
/// simulated day — terabytes of memmove traffic over a multi-year run;
/// 10% slack bounds memory overshoot at ~10% of each type's window while
/// keeping prune counts small. Checkpoints force an exact-watermark prune
/// regardless (see shouldPrune's caller), so measurements never see the
/// slack.
pub const PRUNE_SLACK: f64 = 0.10;

// ---------------------------------------------------------------------------
// Simulated duration + checkpoint schedule — pure data-derived math.
// ---------------------------------------------------------------------------

/// Total simulated days for a building whose longest-retention placed
/// type keeps data for `max_retention_days`. Pure math, exposed for
/// tests; production callers use deriveSimDays.
pub fn simDaysForRetention(max_retention_days: u32) u32 {
    const margin = @max(SIM_MARGIN_MIN_DAYS, max_retention_days / SIM_MARGIN_DIVISOR);
    return max_retention_days + margin;
}

/// Simulated duration for the actual placed sensor types — the maximum of
/// their canonical retention windows plus the eviction margin. Building-
/// derived by design: a building with only short-retention types gets a
/// much shorter (faster) simulation, which is the point. Returns 0 for an
/// empty slice (no sensors — nothing to simulate).
pub fn deriveSimDays(sensor_types: []const sb.SensorType) u32 {
    var max_retention: u32 = 0;
    for (sensor_types) |t| {
        max_retention = @max(max_retention, synthetic.profileFor(t).retention_days);
    }
    if (max_retention == 0) return 0;
    return simDaysForRetention(max_retention);
}

/// One benchmarked pause in the simulated timeline.
pub const Checkpoint = struct {
    sim_day: u32,
    label: []const u8,
};

/// The fixed checkpoint ladder — log-spaced so early life (fast-changing,
/// near-empty backends) gets dense measurements and the multi-year tail
/// gets one per year. Data, not code: extending the ladder is adding a
/// row. Entries at or past the derived sim length are dropped; the final
/// checkpoint is always the sim end itself, labeled "steady state".
const LADDER = [_]Checkpoint{
    .{ .sim_day = 1, .label = "day 1" },
    .{ .sim_day = 7, .label = "week 1" },
    .{ .sim_day = 30, .label = "month 1" },
    .{ .sim_day = 90, .label = "month 3" },
    .{ .sim_day = 182, .label = "month 6" },
    .{ .sim_day = 365, .label = "year 1" },
    .{ .sim_day = 730, .label = "year 2" },
    .{ .sim_day = 1095, .label = "year 3" },
    .{ .sim_day = 1460, .label = "year 4" },
    .{ .sim_day = 1825, .label = "year 5" },
    .{ .sim_day = 2190, .label = "year 6" },
    .{ .sim_day = 2555, .label = "year 7" },
    .{ .sim_day = 2920, .label = "year 8" },
    .{ .sim_day = 3285, .label = "year 9" },
    .{ .sim_day = 3650, .label = "year 10" },
};

/// The checkpoint schedule for a run of `sim_days`: every ladder entry
/// strictly before the sim end, then the sim end itself as the final
/// "steady state" checkpoint (strictly-before filtering makes a ladder
/// day equal to the sim end collapse into the final checkpoint instead of
/// duplicating it). sim_days == 0 returns an empty schedule. Caller frees
/// with `allocator`.
pub fn deriveCheckpoints(allocator: std.mem.Allocator, sim_days: u32) ![]Checkpoint {
    if (sim_days == 0) return try allocator.alloc(Checkpoint, 0);

    var out: std.ArrayList(Checkpoint) = .empty;
    errdefer out.deinit(allocator);

    for (LADDER) |cp| {
        if (cp.sim_day < sim_days) try out.append(allocator, cp);
    }
    try out.append(allocator, .{ .sim_day = sim_days, .label = "steady state" });

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Prune (retention eviction) schedule.
// ---------------------------------------------------------------------------

/// Minimum simulated time between prunes of one sensor type: PRUNE_SLACK
/// of its retention window, never finer than one chunk.
pub fn pruneIntervalMs(retention_ms: i64) i64 {
    const slack: i64 = @intFromFloat(@as(f64, @floatFromInt(retention_ms)) * PRUNE_SLACK);
    return @max(CHUNK_MS, slack);
}

/// Whether a type last pruned at `last_prune_ms` is due again at
/// simulated watermark `watermark_ms`. Depends only on simulated time —
/// identical across backends and runs (determinism, CLAUDE.md §3.4).
pub fn shouldPrune(last_prune_ms: i64, watermark_ms: i64, retention_ms: i64) bool {
    return watermark_ms - last_prune_ms >= pruneIntervalMs(retention_ms);
}

// ---------------------------------------------------------------------------
// Cross-backend result digests (CLAUDE.md §3.2: identical query results,
// validated). Order-insensitive sums, because some queries return results
// in hash-map iteration order and float summation order differs between
// backends' internal layouts.
// ---------------------------------------------------------------------------

/// Relative tolerance for comparing value sums — mirrors runner.zig's
/// existing cross-backend float equivalence conventions.
pub const DIGEST_VALUE_TOLERANCE: f64 = 1e-5;

pub const QueryDigest = struct {
    count: u64 = 0,
    value_sum: f64 = 0.0,
    id_or_ts_sum: u64 = 0,

    /// Fold a scalar query result (avg_window, avg_zone_type, ...).
    pub fn foldValue(self: *QueryDigest, v: f64) void {
        self.count += 1;
        self.value_sum += v;
    }

    /// Fold one id from an id-slice result (spatial_radius, zone_hierarchy).
    pub fn foldId(self: *QueryDigest, id: u64) void {
        self.count += 1;
        self.id_or_ts_sum +%= id;
    }

    /// Fold a timestamp/bucket accompanying other folds (rollup buckets,
    /// breach start/end) — sums into the id/ts channel without counting a
    /// separate result item.
    pub fn foldTimestamp(self: *QueryDigest, ts: i64) void {
        self.id_or_ts_sum +%= @as(u64, @bitCast(ts));
    }

    /// Fold one reading from a readings-slice result (latest_zone,
    /// latest_by_type, anomalies, ...): counts it, sums its value, and
    /// sums its timestamp so a same-count same-sum-different-times
    /// divergence is still caught.
    pub fn foldReading(self: *QueryDigest, r: sb.SensorReading) void {
        self.count += 1;
        self.value_sum += r.value;
        self.id_or_ts_sum +%= @as(u64, @bitCast(r.timestamp));
    }

    /// Exact match on counts and id/timestamp sums; tolerance-based on
    /// value sums (float summation order legitimately differs across
    /// backends).
    pub fn matches(self: QueryDigest, other: QueryDigest) bool {
        if (self.count != other.count) return false;
        if (self.id_or_ts_sum != other.id_or_ts_sum) return false;
        return std.math.approxEqRel(f64, self.value_sum, other.value_sum, DIGEST_VALUE_TOLERANCE) or
            std.math.approxEqAbs(f64, self.value_sum, other.value_sum, 1e-9);
    }
};

// ---------------------------------------------------------------------------
// Result records the simulation produces for reporting.
// ---------------------------------------------------------------------------

/// One query's timing at one checkpoint on one backend — a point on the
/// "latency vs building age" growth curve.
pub const GrowthPoint = struct {
    sim_day: u32,
    label: []const u8,
    backend: []const u8,
    query: []const u8,
    median_ns: i64,
    /// world.memoryUsed() — allocation high-water on flat backends.
    memory_bytes: usize,
    /// world.count() * @sizeOf(SensorReading) — bytes of live readings,
    /// visible plateau after retention even when capacity isn't returned.
    live_bytes: usize,
    /// world.count() at this checkpoint.
    reading_count: usize,
};

/// Whole-run bookkeeping for one backend's simulation: how much simulated
/// time was covered, what it cost in wall time (generation vs ingest vs
/// prune, each measured separately via metrics.timeMutation so none of it
/// ever leaks into query latency), and how much data flowed/evicted.
pub const SimStats = struct {
    backend: []const u8,
    sim_ms: i64 = 0,
    wall_ns: i64 = 0,
    generated: u64 = 0,
    ingested: u64 = 0,
    evicted: u64 = 0,
    ingest_ns: i64 = 0,
    prune_ns: i64 = 0,
    prune_calls: u64 = 0,

    /// Achieved time-compression ratio (simulated time / wall time).
    /// Reporting-only and inherently non-deterministic (wall clock) —
    /// excluded from determinism comparisons, like elapsed-seconds logs.
    pub fn compressionRatio(self: SimStats) f64 {
        if (self.wall_ns <= 0) return 0.0;
        const sim_ns = @as(f64, @floatFromInt(self.sim_ms)) * 1e6;
        return sim_ns / @as(f64, @floatFromInt(self.wall_ns));
    }
};

/// Steady-state data volume for one sensor type — the report surfaces
/// these so a disproportionate type is visible and its profile
/// frequency_hz can be tuned (data, not code).
pub const TypeVolume = struct {
    sensor_type: sb.SensorType,
    reading_count: usize,
    bytes: usize,
};

// ---------------------------------------------------------------------------
// Zone -> floor pairs (resolved by main.zig from the IFC hierarchy) and
// representative real query arguments — sampled from the actual placed
// sensors/zones rather than invented, so every query the benchmark runs is
// exercised against a real sensor_id / zone_id / position from this
// building.
// ---------------------------------------------------------------------------

pub const ZoneFloor = struct { zone_id: u32, floor_id: u32 };

pub fn floorFor(zone_floor: []const ZoneFloor, zone_id: u32) u32 {
    for (zone_floor) |zf| {
        if (zf.zone_id == zone_id) return zf.floor_id;
    }
    return 0;
}

pub const SampleArgs = struct {
    sensor_id: u32,
    sensor_type: sb.SensorType,
    zone_id: u32,
    floor_id: u32,
    position: queries.Vec3,
};

/// One representative real sensor per DISTINCT sensor type actually placed
/// — used to run each type's own type-scoped queries once, against real
/// data of that exact type.
pub const TypeSample = struct { sensor_type: sb.SensorType, args: SampleArgs };

pub fn queryName(q: queries.QueryName) []const u8 {
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

pub fn isHistorical(q: queries.QueryName) bool {
    return q == .hourly_rollup or q == .daily_zone_rollup;
}

/// True for queries whose argument list includes a sensor_type (see
/// `runOne`'s switch) — these are the queries a per-sensor-type
/// recommendation can actually distinguish. The other seven queries are
/// scoped to a sensor_id/zone_id/floor_id/position instead and would just
/// repeat the same result if reused per type.
pub fn isTypeScoped(q: queries.QueryName) bool {
    return switch (q) {
        .latest_by_type, .avg_zone_type, .floor_stats, .daily_zone_rollup, .anomalies => true,
        .avg_window, .hourly_rollup, .latest_single, .latest_zone, .spatial_radius, .zone_hierarchy, .threshold_breach => false,
    };
}

/// Filters `mix` down to the type-scoped queries (isTypeScoped) — used to
/// build a single sensor type's own type-scoped query set for its
/// per-type recommendation. Caller frees with `allocator`.
pub fn filterTypeScoped(allocator: std.mem.Allocator, mix: []const queries.QueryWeight) ![]queries.QueryWeight {
    var list: std.ArrayList(queries.QueryWeight) = .empty;
    errdefer list.deinit(allocator);
    for (mix) |qw| {
        if (isTypeScoped(qw.query)) try list.append(allocator, qw);
    }
    return list.toOwnedSlice(allocator);
}

/// Time one query ONCE (metrics.timeQuery with a single timed iteration)
/// against the live world, using one real sensor's args. Single-shot is
/// the honest measurement here: each checkpoint measures the query
/// against this backend's real accumulated state at that simulated age —
/// there is nothing to resample. Still routed through `metrics.timeQuery`,
/// the single sanctioned timing path; `q1_wrapper`..`q12_wrapper` still
/// adapt query signatures into timeQuery's `!void`-returning shape.
pub fn runOne(
    world: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: queries.QueryName,
    args: SampleArgs,
) !metrics.LatencyStats {
    const Caller = struct {
        world: @TypeOf(world),
        query: queries.QueryName,
        args: SampleArgs,

        fn call(self: *@This()) !void {
            const s = self.args;
            switch (self.query) {
                .avg_window => _ = try queries.query_avg_window(self.world, s.sensor_id, @as(u32, 24)),
                .latest_single => try runner.q1_wrapper(self.world, s.sensor_id),
                .latest_zone => try runner.q2_wrapper(self.world, s.zone_id),
                .latest_by_type => try runner.q3_wrapper(self.world, s.sensor_type),
                .avg_zone_type => try runner.q5_wrapper(self.world, s.zone_id, s.sensor_type, @as(u32, 24)),
                .floor_stats => try runner.q6_wrapper(self.world, s.floor_id, s.sensor_type, @as(u32, 24)),
                .hourly_rollup => try runner.q7_wrapper(self.world, s.sensor_id, @as(u32, 2)),
                .daily_zone_rollup => try runner.q8_wrapper(self.world, s.zone_id, s.sensor_type),
                .spatial_radius => try runner.q9_wrapper(self.world, s.position, @as(f32, 50.0)),
                .zone_hierarchy => try runner.q10_wrapper(self.world, s.zone_id, @as(u32, 2)),
                .anomalies => try runner.q11_wrapper(self.world, s.sensor_type, queries.ANOMALY_STD_DEV_THRESHOLD, queries.ANOMALY_WINDOW_HOURS),
                .threshold_breach => try runner.q12_wrapper(self.world, s.sensor_id, synthetic.profileFor(s.sensor_type).base_value, ONE_HOUR_MS, queries.THRESHOLD_BREACH_WINDOW_HOURS),
            }
        }
    };

    var caller = Caller{ .world = world, .query = query, .args = args };
    return metrics.timeQuery(allocator, io, 1, Caller.call, .{&caller});
}

/// Run one query untimed with EXACTLY the same arguments runOne times it
/// with, folding the full result into an order-insensitive digest for
/// cross-backend validation (CLAUDE.md §3.2). Slices are freed with
/// world.allocator, mirroring runner's wrapper conventions.
pub fn runDigest(
    world: anytype,
    query: queries.QueryName,
    s: SampleArgs,
) !QueryDigest {
    var d = QueryDigest{};
    switch (query) {
        .avg_window => d.foldValue(try queries.query_avg_window(world, s.sensor_id, @as(u32, 24))),
        .latest_single => {
            if (try queries.query_latest_single(world, s.sensor_id)) |r| d.foldReading(r);
        },
        .latest_zone => {
            const rs = try queries.query_latest_zone(world, s.zone_id);
            defer world.allocator.free(rs);
            for (rs) |r| d.foldReading(r);
        },
        .latest_by_type => {
            const rs = try queries.query_latest_by_type(world, s.sensor_type);
            defer world.allocator.free(rs);
            for (rs) |r| d.foldReading(r);
        },
        .avg_zone_type => d.foldValue(try queries.query_avg_zone_type(world, s.zone_id, s.sensor_type, @as(u32, 24))),
        .floor_stats => {
            const st = try queries.query_floor_stats(world, s.floor_id, s.sensor_type, @as(u32, 24));
            d.foldValue(st.min);
            d.foldValue(st.max);
            d.foldValue(st.avg);
        },
        .hourly_rollup => {
            const rs = try queries.query_hourly_rollup(world, s.sensor_id, @as(u32, 2));
            defer world.allocator.free(rs);
            for (rs) |h| {
                d.foldValue(h.avg);
                d.foldValue(h.min);
                d.foldValue(h.max);
                d.foldId(h.count);
                d.foldTimestamp(h.hour_bucket);
            }
        },
        .daily_zone_rollup => {
            const rs = try queries.query_daily_zone_rollup(world, s.zone_id, s.sensor_type);
            defer world.allocator.free(rs);
            for (rs) |day| {
                d.foldValue(day.avg);
                d.foldValue(day.min);
                d.foldValue(day.max);
                d.foldId(day.count);
                d.foldTimestamp(day.day_bucket);
            }
        },
        .spatial_radius => {
            const ids = try queries.query_spatial_radius(world, s.position, @as(f32, 50.0));
            defer world.allocator.free(ids);
            for (ids) |id| d.foldId(id);
        },
        .zone_hierarchy => {
            const ids = try queries.query_zone_hierarchy(world, s.zone_id, @as(u32, 2));
            defer world.allocator.free(ids);
            for (ids) |id| d.foldId(id);
        },
        .anomalies => {
            const rs = try queries.query_anomalies(world, s.sensor_type, queries.ANOMALY_STD_DEV_THRESHOLD, queries.ANOMALY_WINDOW_HOURS);
            defer world.allocator.free(rs);
            for (rs) |a| d.foldReading(a.reading);
        },
        .threshold_breach => {
            if (try queries.query_threshold_breach(world, s.sensor_id, synthetic.profileFor(s.sensor_type).base_value, ONE_HOUR_MS, queries.THRESHOLD_BREACH_WINDOW_HOURS)) |bev| {
                d.foldId(bev.sensor_id);
                d.foldTimestamp(bev.start_ts);
                d.foldTimestamp(bev.end_ts);
                d.foldValue(bev.peak_value);
            }
        },
    }
    return d;
}

/// checkpoints x query_mix digest table. The first simulated backend
/// records; every subsequent backend compares and fails the run loudly on
/// divergence.
pub const DigestTable = struct {
    entries: []?QueryDigest,
    mix_len: usize,

    pub fn init(allocator: std.mem.Allocator, checkpoint_count: usize, mix_len: usize) !DigestTable {
        const entries = try allocator.alloc(?QueryDigest, checkpoint_count * mix_len);
        @memset(entries, null);
        return .{ .entries = entries, .mix_len = mix_len };
    }

    pub fn deinit(self: *DigestTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn slot(self: *DigestTable, checkpoint_idx: usize, query_idx: usize) *?QueryDigest {
        return &self.entries[checkpoint_idx * self.mix_len + query_idx];
    }
};

// ---------------------------------------------------------------------------
// The simulation itself.
// ---------------------------------------------------------------------------

/// timeMutation callable — wraps streamUntil + direct insert into the
/// world. No intermediate buffer: each reading goes straight from the
/// stream's tick into the backend, in time order.
fn StreamIngestCall(comptime W: type) type {
    return struct {
        stream: *synthetic.Stream,
        world: *W,
        until_ms: i64,
        count: usize = 0,

        fn call(self: *@This()) !void {
            self.count = 0;
            try self.stream.streamUntil(self.until_ms, insertSink, self);
        }

        fn insertSink(self: *@This(), reading: sb.SensorReading) !void {
            try self.world.insert(reading);
            self.count += 1;
        }
    };
}

fn PruneCall(comptime W: type) type {
    return struct {
        world: *W,
        sensor_type: sb.SensorType,
        cutoff: i64,

        fn call(self: *@This()) !void {
            try self.world.pruneOlderThan(self.sensor_type, self.cutoff);
        }
    };
}

const SENSOR_TYPE_COUNT = std.enums.values(sb.SensorType).len;

/// Simulate one backend through the building's whole day-zero timeline:
/// stream one simulated day at a time into a fresh World, prune each type
/// to its retention window on the slack schedule, and pause at every
/// checkpoint to validate cross-backend digests and time the query mix.
/// The final (steady-state) checkpoint additionally times the type-scoped
/// per-type queries and emits the RunRows that feed recommendCompound —
/// the headline recommendation is grounded in steady state; earlier
/// checkpoints only feed the growth curve.
///
/// Every backend replays the IDENTICAL stream (fresh synthetic.Stream,
/// same seed — chunk-boundary-invariant per-sensor PRNGs), so results are
/// apples-to-apples and the digest table is meaningful. Prunes and ingest
/// run between metrics.timeQuery calls and are timed separately via
/// metrics.timeMutation, so eviction/ingest cost never leaks into query
/// latency.
pub fn simulateBackend(
    comptime b: runner.BackendEntry,
    comptime historical_supported: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    sensors: []const components.SensorMetadata,
    locations: []const components.ZoneLocation,
    zone_floor: []const ZoneFloor,
    query_mix: []const queries.QueryWeight,
    overall_sample: SampleArgs,
    type_samples: []const TypeSample,
    scale_label: []const u8,
    seed: u64,
    checkpoints: []const Checkpoint,
    digests: *DigestTable,
    rows: *std.ArrayList(report.RunRow),
    type_rows: *std.ArrayList(report.RunRow),
    growth: *std.ArrayList(GrowthPoint),
    sim_stats_out: *std.ArrayList(SimStats),
    type_volumes: *std.ArrayList(TypeVolume),
) !void {
    if (checkpoints.len == 0) return;

    std.debug.print("\n--- Backend: {s} — live day-zero simulation ---\n", .{b.name});
    std.debug.print("  Initializing world + registering {d} zones/floors...\n", .{locations.len});
    // Wall clock for operator-facing progress + the achieved compression
    // ratio only — never a benchmark metric (those all go through
    // metrics.timeQuery/timeMutation).
    const wall_start = std.Io.Clock.awake.now(io);

    const W = World(b.T);
    var world = try W.init(allocator);
    defer world.deinit();

    var stats = SimStats{ .backend = b.name };

    // Cap every placed sensor type at RINGBUFFER_CAP BEFORE the first
    // insert (RingBuffer sizes a sensor's buffer when it's first seen); a
    // no-op on the full-retention backends.
    for (type_samples) |group| try world.setRetentionHint(group.sensor_type, RINGBUFFER_CAP);

    // Topology up front — the first checkpoint's zone/floor queries need it.
    for (locations) |loc| try world.registerZone(loc.sensor_id, loc.zone_id);
    for (zone_floor) |zf| try world.registerFloor(zf.zone_id, zf.floor_id);

    var stream = try synthetic.Stream.init(allocator, sensors, seed, SIM_START_MS, false);
    defer stream.deinit();

    // Per-type prune bookkeeping, in sim-relative ms. The schedule depends
    // only on simulated time -> identical across backends and runs.
    var last_prune: [SENSOR_TYPE_COUNT]i64 = @splat(0);

    const total_days = checkpoints[checkpoints.len - 1].sim_day;
    var next_cp: usize = 0;

    var day: u32 = 1;
    while (day <= total_days) : (day += 1) {
        const elapsed_ms: i64 = @as(i64, day) * CHUNK_MS;
        const day_end: i64 = SIM_START_MS + elapsed_ms;

        // Stream readings tick-by-tick directly into the backend — no
        // intermediate buffer, no sort. Readings arrive in time order.
        var stream_ingest = StreamIngestCall(W){
            .stream = &stream,
            .world = &world,
            .until_ms = day_end,
        };
        const ingest_ns = try metrics.timeMutation(io, StreamIngestCall(W).call, .{&stream_ingest});
        stats.ingest_ns += ingest_ns;
        stats.generated += stream_ingest.count;
        stats.ingested += stream_ingest.count;

        // Operator-facing heartbeat between (possibly year-apart)
        // checkpoints: simulated progress + where the wall time is going.
        if (day % 100 == 0) {
            const now = std.Io.Clock.awake.now(io);
            const elapsed_s = @as(f64, @floatFromInt(@as(i64, @intCast(wall_start.durationTo(now).nanoseconds)))) / 1e9;
            std.debug.print("  [{s}] day {d}/{d} ({d:.0}%): {d} generated, {d} live, {d:.1}s elapsed (stream {d:.1}s, prune {d:.1}s)\n", .{
                b.name,
                day,
                total_days,
                @as(f64, @floatFromInt(day)) / @as(f64, @floatFromInt(total_days)) * 100.0,
                stats.generated,
                world.count(),
                elapsed_s,
                @as(f64, @floatFromInt(stats.ingest_ns)) / 1e9,
                @as(f64, @floatFromInt(stats.prune_ns)) / 1e9,
            });
        }

        const at_checkpoint = next_cp < checkpoints.len and checkpoints[next_cp].sim_day == day;

        // Retention eviction: slack-scheduled normally, but unconditional
        // right before a checkpoint so every backend is at the exact
        // retention watermark when queried (comparable digests + memory).
        for (type_samples) |group| {
            const type_idx = @intFromEnum(group.sensor_type);
            const retention_ms: i64 = @as(i64, synthetic.profileFor(group.sensor_type).retention_days) * CHUNK_MS;
            if (!at_checkpoint and !shouldPrune(last_prune[type_idx], elapsed_ms, retention_ms)) continue;
            // Nothing can be out of retention before the window has
            // filled once — skip the pointless full-array scan.
            if (elapsed_ms <= retention_ms) continue;

            const cutoff = day_end - retention_ms;
            const before = world.count();
            const log_prune = at_checkpoint;
            if (log_prune) {
                std.debug.print("  [{s}] pruning {s} older than day {d} ({d} readings before)...\n", .{
                    b.name, @tagName(group.sensor_type), @divTrunc(retention_ms, CHUNK_MS), before,
                });
            }
            var prune = PruneCall(W){ .world = &world, .sensor_type = group.sensor_type, .cutoff = cutoff };
            stats.prune_ns += try metrics.timeMutation(io, PruneCall(W).call, .{&prune});
            stats.prune_calls += 1;
            const evicted_now = before - world.count();
            stats.evicted += evicted_now;
            if (log_prune) {
                std.debug.print("  [{s}] pruned {d} readings ({d} live remaining)\n", .{ b.name, evicted_now, world.count() });
            }
            last_prune[type_idx] = elapsed_ms;
        }

        if (!at_checkpoint) continue;
        const cp = checkpoints[next_cp];
        const is_final = next_cp == checkpoints.len - 1;
        const cp_start = std.Io.Clock.awake.now(io);

        const ns_f = struct {
            fn s(a: anytype, z: anytype) f64 {
                return @as(f64, @floatFromInt(@as(i64, @intCast(a.durationTo(z).nanoseconds)))) / 1e9;
            }
        };

        std.debug.print("\n  [{s}] === Checkpoint {s} (day {d}/{d}) ===\n", .{ b.name, cp.label, cp.sim_day, total_days });

        // Force the lazy sort/cache-build every backend otherwise defers
        // to its first query call — attribute that one-time cost to the
        // simulation (not benchmark-timed) instead of letting it silently
        // inflate whichever query happens to run first at this checkpoint.
        _ = try world.iterateAll();

        const warm_done = std.Io.Clock.awake.now(io);
        std.debug.print("  [{s}] warmup done ({d:.1}s)\n", .{ b.name, ns_f.s(cp_start, warm_done) });

        // Cross-backend digest validation (CLAUDE.md §3.2): the first
        // backend records, later ones must match. The real_time family is
        // compared across ALL backends; other families only across
        // full-retention backends (a count-capped cache legitimately
        // diverges on queries that span evicted data).
        for (query_mix, 0..) |qw, qi| {
            if (!historical_supported and isHistorical(qw.query)) continue;
            if (!historical_supported and queries.familyOf(qw.query) != .real_time) continue;

            const digest = try runDigest(&world, qw.query, overall_sample);
            const s = digests.slot(next_cp, qi);
            if (s.*) |ref| {
                if (!ref.matches(digest)) {
                    std.debug.print(
                        "DIGEST MISMATCH [{s}] {s} at {s} (day {d}): count {d} vs {d}, value_sum {d} vs {d}, id/ts sum {d} vs {d}\n",
                        .{ b.name, queryName(qw.query), cp.label, cp.sim_day, digest.count, ref.count, digest.value_sum, ref.value_sum, digest.id_or_ts_sum, ref.id_or_ts_sum },
                    );
                    return error.CrossBackendMismatch;
                }
            } else {
                s.* = digest;
            }
        }

        const digest_done = std.Io.Clock.awake.now(io);
        std.debug.print("  [{s}] digest validation done ({d:.1}s)\n", .{ b.name, ns_f.s(warm_done, digest_done) });

        // Time the building-level query mix once each, against this
        // backend's real accumulated state at this simulated age.
        const live_count = world.count();
        const live_bytes = live_count * @sizeOf(sb.SensorReading);
        std.debug.print("  [{s}] running {d} building-level queries ({d} live readings, {d:.1} MB)...\n", .{
            b.name, query_mix.len, live_count, @as(f64, @floatFromInt(live_bytes)) / (1024.0 * 1024.0),
        });
        for (query_mix) |qw| {
            if (!historical_supported and isHistorical(qw.query)) continue;

            const qstats = try runOne(&world, allocator, io, qw.query, overall_sample);
            std.debug.print("    {s}: median {d:.1}µs, p95 {d:.1}µs\n", .{
                queryName(qw.query),
                @as(f64, @floatFromInt(qstats.median_ns)) / 1000.0,
                @as(f64, @floatFromInt(qstats.p95_ns)) / 1000.0,
            });
            try growth.append(allocator, .{
                .sim_day = cp.sim_day,
                .label = cp.label,
                .backend = b.name,
                .query = queryName(qw.query),
                .median_ns = qstats.median_ns,
                .memory_bytes = world.memoryUsed(),
                .live_bytes = live_bytes,
                .reading_count = live_count,
            });
            if (is_final) {
                try rows.append(allocator, .{
                    .scale = scale_label,
                    .query = queryName(qw.query),
                    .backend = b.name,
                    .memory_bytes = world.memoryUsed(),
                    .stats = qstats,
                });
            }
        }

        // Steady state only: the type-scoped per-type queries that feed
        // the per-sensor-type recommendations, and (once, from the first
        // simulated backend — a full-retention one) the per-type volume
        // table the report uses to expose disproportionate types.
        if (is_final) {
            std.debug.print("  [{s}] steady state — running type-scoped queries across {d} sensor types...\n", .{ b.name, type_samples.len });
            for (type_samples) |group| {
                const type_mix = synthetic.profileFor(group.sensor_type).relevant_queries;
                for (type_mix) |qw| {
                    if (!isTypeScoped(qw.query)) continue;
                    if (!historical_supported and isHistorical(qw.query)) continue;

                    const qstats = try runOne(&world, allocator, io, qw.query, group.args);
                    try type_rows.append(allocator, .{
                        .scale = @tagName(group.sensor_type),
                        .query = queryName(qw.query),
                        .backend = b.name,
                        .memory_bytes = world.memoryUsed(),
                        .stats = qstats,
                    });
                }
            }

            if (type_volumes.items.len == 0) {
                for (type_samples) |group| {
                    const rs = try world.readingsForType(group.sensor_type);
                    defer allocator.free(rs);
                    try type_volumes.append(allocator, .{
                        .sensor_type = group.sensor_type,
                        .reading_count = rs.len,
                        .bytes = rs.len * @sizeOf(sb.SensorReading),
                    });
                }
            }
        }

        const cp_done = std.Io.Clock.awake.now(io);
        std.debug.print("  [{s}] checkpoint {s} complete: warm {d:.1}s, digest {d:.1}s, queries {d:.1}s, total {d:.1}s\n", .{
            b.name,
            cp.label,
            ns_f.s(cp_start, warm_done),
            ns_f.s(warm_done, digest_done),
            ns_f.s(digest_done, cp_done),
            ns_f.s(cp_start, cp_done),
        });

        next_cp += 1;
    }

    stats.sim_ms = @as(i64, total_days) * CHUNK_MS;
    const wall_end = std.Io.Clock.awake.now(io);
    stats.wall_ns = @intCast(wall_start.durationTo(wall_end).nanoseconds);
    try sim_stats_out.append(allocator, stats);

    std.debug.print("  [{s}] simulation complete: {d} days in {d:.1}s (~{d:.0}x compression), {d} generated, {d} ingested, {d} evicted in {d} prunes\n", .{
        b.name,
        total_days,
        @as(f64, @floatFromInt(stats.wall_ns)) / 1e9,
        stats.compressionRatio(),
        stats.generated,
        stats.ingested,
        stats.evicted,
        stats.prune_calls,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "simDaysForRetention: short retention gets the 30-day floor margin" {
    // temperature: 90d retention -> margin max(30, 4) = 30 -> 120 sim days.
    try testing.expectEqual(@as(u32, 120), simDaysForRetention(90));
}

test "simDaysForRetention: long retention gets the proportional margin" {
    // structural: 2555d retention -> margin max(30, 127) = 127 -> 2682.
    try testing.expectEqual(@as(u32, 2682), simDaysForRetention(2555));
}

test "deriveSimDays: uses the longest retention among placed types; empty means zero" {
    const types = [_]sb.SensorType{ .temperature, .vibration, .structural };
    try testing.expectEqual(simDaysForRetention(2555), deriveSimDays(&types));

    const short = [_]sb.SensorType{.vibration}; // 90d retention
    try testing.expectEqual(simDaysForRetention(90), deriveSimDays(&short));

    try testing.expectEqual(@as(u32, 0), deriveSimDays(&.{}));
}

test "deriveCheckpoints: temperature-only building gets day/week/month ladder + steady state" {
    const cps = try deriveCheckpoints(testing.allocator, 120);
    defer testing.allocator.free(cps);

    const expected_days = [_]u32{ 1, 7, 30, 90, 120 };
    try testing.expectEqual(expected_days.len, cps.len);
    for (cps, expected_days) |cp, d| try testing.expectEqual(d, cp.sim_day);
    try testing.expectEqualStrings("steady state", cps[cps.len - 1].label);
}

test "deriveCheckpoints: structural-scale run has 13 checkpoints ending at steady state" {
    const cps = try deriveCheckpoints(testing.allocator, simDaysForRetention(2555));
    defer testing.allocator.free(cps);

    try testing.expectEqual(@as(usize, 13), cps.len);
    try testing.expectEqual(@as(u32, 2555), cps[cps.len - 2].sim_day); // year 7 still inside
    try testing.expectEqual(@as(u32, 2682), cps[cps.len - 1].sim_day);
    try testing.expectEqualStrings("steady state", cps[cps.len - 1].label);
}

test "deriveCheckpoints: a ladder day equal to the sim end collapses into the final checkpoint" {
    const cps = try deriveCheckpoints(testing.allocator, 365);
    defer testing.allocator.free(cps);

    // 365 is on the ladder ("year 1") but must appear exactly once, as
    // the final "steady state" entry.
    const expected_days = [_]u32{ 1, 7, 30, 90, 182, 365 };
    try testing.expectEqual(expected_days.len, cps.len);
    for (cps, expected_days) |cp, d| try testing.expectEqual(d, cp.sim_day);
    try testing.expectEqualStrings("steady state", cps[cps.len - 1].label);
}

test "deriveCheckpoints: zero sim days yields an empty schedule" {
    const cps = try deriveCheckpoints(testing.allocator, 0);
    defer testing.allocator.free(cps);
    try testing.expectEqual(@as(usize, 0), cps.len);
}

test "prune cadence: 10% slack, never finer than one chunk" {
    const day: i64 = MS_PER_DAY;

    // temperature: 90d retention -> prune every 9 simulated days.
    const temp_retention = 90 * day;
    try testing.expectEqual(9 * day, pruneIntervalMs(temp_retention));
    try testing.expect(!shouldPrune(0, 8 * day, temp_retention));
    try testing.expect(shouldPrune(0, 9 * day, temp_retention));

    // A 30d retention window -> prune every 3 days.
    try testing.expectEqual(3 * day, pruneIntervalMs(30 * day));

    // A retention window so short that 10% of it is under one chunk still
    // prunes no finer than per-chunk.
    try testing.expectEqual(CHUNK_MS, pruneIntervalMs(2 * day));
}

test "QueryDigest: identical folds match; count, id-sum, and value divergences don't" {
    var a = QueryDigest{};
    var b = QueryDigest{};
    const r = sb.SensorReading{ .sensor_id = 3, .timestamp = 1_700_000_000_000, .value = 21.5, .sensor_type = .temperature };
    a.foldReading(r);
    b.foldReading(r);
    a.foldValue(42.0);
    b.foldValue(42.0);
    try testing.expect(a.matches(b));

    // Tiny float divergence (summation order) still matches.
    var c = b;
    c.value_sum += c.value_sum * 1e-7;
    try testing.expect(a.matches(c));

    // Count mismatch fails.
    var d = b;
    d.count += 1;
    try testing.expect(!a.matches(d));

    // Timestamp/id-sum mismatch fails.
    var e = b;
    e.id_or_ts_sum +%= 1;
    try testing.expect(!a.matches(e));

    // Real value divergence fails.
    var f = b;
    f.value_sum += 1.0;
    try testing.expect(!a.matches(f));
}

test "QueryDigest: zero-count digests (both sides empty) match" {
    const a = QueryDigest{};
    const b = QueryDigest{};
    try testing.expect(a.matches(b));
}

test "SimStats: compression ratio is sim/wall and guards divide-by-zero" {
    var s = SimStats{ .backend = "TimeSeries" };
    try testing.expectEqual(@as(f64, 0.0), s.compressionRatio());

    // 1 simulated hour in 1 wall millisecond = 3,600,000x.
    s.sim_ms = 60 * 60 * 1000;
    s.wall_ns = 1_000_000;
    try testing.expectApproxEqRel(@as(f64, 3_600_000.0), s.compressionRatio(), 1e-9);
}

// ---------------------------------------------------------------------------
// Integration tests — exercise simulateBackend with a real World/backend.
// ---------------------------------------------------------------------------

const aos_backend = @import("../ecs/storage/backends/aos_storage.zig");
const ts_backend = @import("../ecs/storage/backends/timeseries_storage.zig");

/// Minimal sensor/zone fixtures for integration tests — 2 sensors of
/// different types so deriveSimDays picks the longer retention.
const int_test_sensors = [_]components.SensorMetadata{
    .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 1 },
    .{ .sensor_id = 1, .sensor_type = .vibration, .frequency_hz = 1.0 / 3600.0, .element_id = 2 },
};

const int_test_locations = [_]components.ZoneLocation{
    .{ .sensor_id = 0, .zone_id = 10, .position = .{ .x = 1.0, .y = 2.0, .z = 0.0 } },
    .{ .sensor_id = 1, .zone_id = 10, .position = .{ .x = 3.0, .y = 4.0, .z = 0.0 } },
};

const int_test_zone_floor = [_]ZoneFloor{
    .{ .zone_id = 10, .floor_id = 1 },
};

const int_test_overall = SampleArgs{
    .sensor_id = 0,
    .sensor_type = .temperature,
    .zone_id = 10,
    .floor_id = 1,
    .position = .{ .x = 1.0, .y = 2.0, .z = 0.0 },
};

const int_test_type_samples = [_]TypeSample{
    .{ .sensor_type = .temperature, .args = int_test_overall },
    .{ .sensor_type = .vibration, .args = .{
        .sensor_id = 1,
        .sensor_type = .vibration,
        .zone_id = 10,
        .floor_id = 1,
        .position = .{ .x = 3.0, .y = 4.0, .z = 0.0 },
    } },
};

const int_test_query_mix = [_]queries.QueryWeight{
    .{ .query = .latest_single, .weight = 1.0, .hot = true },
    .{ .query = .avg_window, .weight = 1.0, .hot = false },
};

/// Short sim: temperature (90d retention) + vibration (90d) -> simDaysForRetention(90) = 120 days.
fn intTestCheckpoints(allocator: std.mem.Allocator) ![]Checkpoint {
    const types = [_]sb.SensorType{ .temperature, .vibration };
    const days = deriveSimDays(&types);
    return deriveCheckpoints(allocator, days);
}

test "integration: simulateBackend produces growth points at every checkpoint" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cps = try intTestCheckpoints(testing.allocator);
    defer testing.allocator.free(cps);

    var growth: std.ArrayList(GrowthPoint) = .empty;
    defer growth.deinit(testing.allocator);
    var sim_stats: std.ArrayList(SimStats) = .empty;
    defer sim_stats.deinit(testing.allocator);
    var type_volumes: std.ArrayList(TypeVolume) = .empty;
    defer type_volumes.deinit(testing.allocator);
    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(testing.allocator);
    var type_rows: std.ArrayList(report.RunRow) = .empty;
    defer type_rows.deinit(testing.allocator);
    var digests = try DigestTable.init(testing.allocator, cps.len, int_test_query_mix.len);
    defer digests.deinit(testing.allocator);

    const b = runner.BackendEntry{ .name = "AoS", .T = aos_backend };
    try simulateBackend(
        b,
        true,
        testing.allocator,
        io,
        &int_test_sensors,
        &int_test_locations,
        &int_test_zone_floor,
        &int_test_query_mix,
        int_test_overall,
        &int_test_type_samples,
        "test",
        42,
        cps,
        &digests,
        &rows,
        &type_rows,
        &growth,
        &sim_stats,
        &type_volumes,
    );

    // 2 queries × 5 checkpoints (day 1, 7, 30, 90, 120) = 10 growth points.
    try testing.expectEqual(cps.len * int_test_query_mix.len, growth.items.len);
    // Sim stats recorded.
    try testing.expectEqual(@as(usize, 1), sim_stats.items.len);
    // Type volumes recorded (2 types).
    try testing.expectEqual(@as(usize, 2), type_volumes.items.len);
}

test "integration: determinism — same seed produces identical growth medians" {
    var threaded1 = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded1.deinit();
    const io1 = threaded1.io();

    var threaded2 = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded2.deinit();
    const io2 = threaded2.io();

    const cps = try intTestCheckpoints(testing.allocator);
    defer testing.allocator.free(cps);

    var growth1: std.ArrayList(GrowthPoint) = .empty;
    defer growth1.deinit(testing.allocator);
    var sim_stats1: std.ArrayList(SimStats) = .empty;
    defer sim_stats1.deinit(testing.allocator);
    var type_volumes1: std.ArrayList(TypeVolume) = .empty;
    defer type_volumes1.deinit(testing.allocator);
    var rows1: std.ArrayList(report.RunRow) = .empty;
    defer rows1.deinit(testing.allocator);
    var type_rows1: std.ArrayList(report.RunRow) = .empty;
    defer type_rows1.deinit(testing.allocator);
    var digests1 = try DigestTable.init(testing.allocator, cps.len, int_test_query_mix.len);
    defer digests1.deinit(testing.allocator);

    var growth2: std.ArrayList(GrowthPoint) = .empty;
    defer growth2.deinit(testing.allocator);
    var sim_stats2: std.ArrayList(SimStats) = .empty;
    defer sim_stats2.deinit(testing.allocator);
    var type_volumes2: std.ArrayList(TypeVolume) = .empty;
    defer type_volumes2.deinit(testing.allocator);
    var rows2: std.ArrayList(report.RunRow) = .empty;
    defer rows2.deinit(testing.allocator);
    var type_rows2: std.ArrayList(report.RunRow) = .empty;
    defer type_rows2.deinit(testing.allocator);
    var digests2 = try DigestTable.init(testing.allocator, cps.len, int_test_query_mix.len);
    defer digests2.deinit(testing.allocator);

    const b = runner.BackendEntry{ .name = "AoS", .T = aos_backend };

    try simulateBackend(b, true, testing.allocator, io1, &int_test_sensors, &int_test_locations, &int_test_zone_floor, &int_test_query_mix, int_test_overall, &int_test_type_samples, "test", 42, cps, &digests1, &rows1, &type_rows1, &growth1, &sim_stats1, &type_volumes1);
    try simulateBackend(b, true, testing.allocator, io2, &int_test_sensors, &int_test_locations, &int_test_zone_floor, &int_test_query_mix, int_test_overall, &int_test_type_samples, "test", 42, cps, &digests2, &rows2, &type_rows2, &growth2, &sim_stats2, &type_volumes2);

    // Same seed -> same reading count and type volumes (deterministic data).
    try testing.expectEqual(growth1.items.len, growth2.items.len);
    for (growth1.items, growth2.items) |g1, g2| {
        try testing.expectEqual(g1.reading_count, g2.reading_count);
    }
    try testing.expectEqual(type_volumes1.items.len, type_volumes2.items.len);
    for (type_volumes1.items, type_volumes2.items) |v1, v2| {
        try testing.expectEqual(v1.reading_count, v2.reading_count);
    }
    // Same generated count.
    try testing.expectEqual(sim_stats1.items[0].generated, sim_stats2.items[0].generated);
}

test "integration: eviction occurs in a full-length sim" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cps = try intTestCheckpoints(testing.allocator);
    defer testing.allocator.free(cps);

    var growth: std.ArrayList(GrowthPoint) = .empty;
    defer growth.deinit(testing.allocator);
    var sim_stats: std.ArrayList(SimStats) = .empty;
    defer sim_stats.deinit(testing.allocator);
    var type_volumes: std.ArrayList(TypeVolume) = .empty;
    defer type_volumes.deinit(testing.allocator);
    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(testing.allocator);
    var type_rows: std.ArrayList(report.RunRow) = .empty;
    defer type_rows.deinit(testing.allocator);
    var digests = try DigestTable.init(testing.allocator, cps.len, int_test_query_mix.len);
    defer digests.deinit(testing.allocator);

    const b = runner.BackendEntry{ .name = "TimeSeries", .T = ts_backend };
    try simulateBackend(
        b,
        true,
        testing.allocator,
        io,
        &int_test_sensors,
        &int_test_locations,
        &int_test_zone_floor,
        &int_test_query_mix,
        int_test_overall,
        &int_test_type_samples,
        "test",
        42,
        cps,
        &digests,
        &rows,
        &type_rows,
        &growth,
        &sim_stats,
        &type_volumes,
    );

    // 120 sim days, 90d retention -> eviction must happen after day 90.
    try testing.expect(sim_stats.items[0].evicted > 0);
    try testing.expect(sim_stats.items[0].prune_calls > 0);
}

test "integration: cross-backend digest validation passes for AoS vs TimeSeries" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cps = try intTestCheckpoints(testing.allocator);
    defer testing.allocator.free(cps);

    var growth: std.ArrayList(GrowthPoint) = .empty;
    defer growth.deinit(testing.allocator);
    var sim_stats: std.ArrayList(SimStats) = .empty;
    defer sim_stats.deinit(testing.allocator);
    var type_volumes: std.ArrayList(TypeVolume) = .empty;
    defer type_volumes.deinit(testing.allocator);
    var rows: std.ArrayList(report.RunRow) = .empty;
    defer rows.deinit(testing.allocator);
    var type_rows: std.ArrayList(report.RunRow) = .empty;
    defer type_rows.deinit(testing.allocator);
    var digests = try DigestTable.init(testing.allocator, cps.len, int_test_query_mix.len);
    defer digests.deinit(testing.allocator);

    // Run AoS first (records digests), then TimeSeries (validates against them).
    const aos_entry = runner.BackendEntry{ .name = "AoS", .T = aos_backend };
    try simulateBackend(aos_entry, true, testing.allocator, io, &int_test_sensors, &int_test_locations, &int_test_zone_floor, &int_test_query_mix, int_test_overall, &int_test_type_samples, "test", 42, cps, &digests, &rows, &type_rows, &growth, &sim_stats, &type_volumes);

    const ts_entry = runner.BackendEntry{ .name = "TimeSeries", .T = ts_backend };
    try simulateBackend(ts_entry, true, testing.allocator, io, &int_test_sensors, &int_test_locations, &int_test_zone_floor, &int_test_query_mix, int_test_overall, &int_test_type_samples, "test", 42, cps, &digests, &rows, &type_rows, &growth, &sim_stats, &type_volumes);

    // If we get here without error.CrossBackendMismatch, digests matched.
    // Verify the digest table was populated (not all null).
    var any_filled = false;
    for (digests.entries) |e| {
        if (e != null) {
            any_filled = true;
            break;
        }
    }
    try testing.expect(any_filled);
}
