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
const ingest_system = @import("../ecs/systems/ingest_system.zig");
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
    rejected: u64 = 0,
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

/// Ingest quality for one sensor type over the whole run — how many
/// readings this type's stream generated vs. how many ingest_system.zig
/// rejected as out-of-bounds (real gateway behavior for a physically-
/// impossible value; see ingest_system.zig's header comment). Identical
/// across every backend by construction (shared generation + shared
/// validation happen once per day, upstream of any backend's insert), so
/// it's tracked once for the whole run rather than per backend.
pub const TypeQuality = struct {
    sensor_type: sb.SensorType,
    generated: u64,
    rejected: u64,
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

// ---------------------------------------------------------------------------
// The simulation itself.
//
// Step 2 of the sim-perf-overhaul: every backend used to own its own
// synthetic.Stream and independently regenerate the ENTIRE deterministic
// multi-year feed from scratch (5x redundant generation for identical
// output — only ingest genuinely differs per backend). Now there is a
// single shared Stream and a single day loop: each simulated day's readings
// are generated exactly once (`stream.nextChunk`) and fanned out to every
// backend's own timed insert. Ingest/prune/query timing stays per-backend
// and per-day exactly as before; only the (previously redundant) generation
// work is now shared.
// ---------------------------------------------------------------------------

/// timeMutation callable — inserts one already-generated day's chunk into
/// one backend's World, timed. Generation itself happens once, upstream in
/// simulateAllBackends' day loop — this only measures this backend's own
/// insert cost, not shared generation cost.
fn IngestChunkCall(comptime W: type) type {
    return struct {
        world: *W,
        chunk: []const sb.SensorReading,

        fn call(self: *@This()) !void {
            for (self.chunk) |r| try self.world.insert(r);
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

/// Per-backend mutable state carried across the shared day loop —
/// everything simulateBackend used to keep in function-local variables,
/// now living long enough to survive across every backend's turn within
/// the same simulated day.
fn BackendRunState(comptime T: type) type {
    return struct {
        world: World(T),
        stats: SimStats,
        /// Per-type prune bookkeeping, in sim-relative ms. The SCHEDULE
        /// (shouldPrune's threshold) depends only on simulated time and is
        /// identical across backends; the watermark of when THIS backend
        /// last actually pruned is still tracked per backend since prune
        /// calls are individually timed and independently scheduled around
        /// slack.
        last_prune: [SENSOR_TYPE_COUNT]i64 = @splat(0),
    };
}

fn typeForBackend(comptime name: []const u8) type {
    inline for (runner.backends) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.T;
    }
    @compileError("simulateAllBackends: no registered backend named " ++ name ++
        " — keep AllBackendStates' fields in sync with runner.zig's backends list");
}

/// One named field per entry in runner.backends — hand-written rather than
/// built via @Type/comptime reflection. runner.backends is explicitly "the
/// single place all backends are registered" and changes rarely; adding a
/// backend means adding one line here too, and typeForBackend turns a
/// forgotten one into a clear @compileError rather than a silent mismatch.
const AllBackendStates = struct {
    TimeSeries: BackendRunState(typeForBackend("TimeSeries")),
    Columnar: BackendRunState(typeForBackend("Columnar")),
    Hierarchical: BackendRunState(typeForBackend("Hierarchical")),
    RingBuffer: BackendRunState(typeForBackend("RingBuffer")),
    Lake: BackendRunState(typeForBackend("Lake")),
};

fn isHistoricalSupported(comptime b: runner.BackendEntry) bool {
    inline for (runner.supported_backends) |sup| {
        if (std.mem.eql(u8, sup.name, b.name)) return true;
    }
    return false;
}

/// Simulate every registered backend through the building's whole day-zero
/// timeline together: one shared Stream generates each simulated day's
/// readings once, fanned out to every backend's own timed insert, prune,
/// and (at checkpoints) query benchmarking. The final (steady-state)
/// checkpoint additionally times the type-scoped per-type queries and emits
/// the RunRows that feed recommendCompound — the headline recommendation is
/// grounded in steady state; earlier checkpoints only feed the growth curve.
pub fn simulateAllBackends(
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
    rows: *std.ArrayList(report.RunRow),
    type_rows: *std.ArrayList(report.RunRow),
    growth: *std.ArrayList(GrowthPoint),
    sim_stats_out: *std.ArrayList(SimStats),
    type_volumes: *std.ArrayList(TypeVolume),
    type_quality: *std.ArrayList(TypeQuality),
) !void {
    if (checkpoints.len == 0) return;

    std.debug.print("\n--- Live day-zero simulation: {d} backends, shared generation ---\n", .{runner.backends.len});
    std.debug.print("  Initializing worlds + registering {d} zones/floors each...\n", .{locations.len});
    // Wall clock for operator-facing progress only — never a benchmark
    // metric (those all go through metrics.timeQuery/timeMutation).
    const wall_start = std.Io.Clock.awake.now(io);

    var states: AllBackendStates = undefined;
    inline for (runner.backends) |b| {
        const W = World(b.T);
        var world = try W.init(allocator);
        // Cap every placed sensor type at RINGBUFFER_CAP BEFORE the first
        // insert (RingBuffer sizes a sensor's buffer when it's first seen);
        // a no-op on the full-retention backends.
        for (type_samples) |group| try world.setRetentionHint(group.sensor_type, RINGBUFFER_CAP);
        // Topology up front — the first checkpoint's zone/floor queries need it.
        for (locations) |loc| try world.registerZone(loc.sensor_id, loc.zone_id);
        for (zone_floor) |zf| try world.registerFloor(zf.zone_id, zf.floor_id);

        @field(states, b.name) = .{ .world = world, .stats = .{ .backend = b.name } };
    }
    defer inline for (runner.backends) |b| {
        @field(states, b.name).world.deinit();
    };

    // enable_failures = true: dropout/stuck/drift are now active per each
    // type's own FailureParams (synthetic.profileFor) — see
    // ingest_system.zig's header comment for how each is actually handled.
    var stream = try synthetic.Stream.init(allocator, sensors, seed, SIM_START_MS, true);
    defer stream.deinit();

    // Ingest quality tally, accumulated once across the whole run (shared —
    // rejection is a property of the reading itself, identical for every
    // backend, computed once here rather than 5x).
    var quality_accum: [SENSOR_TYPE_COUNT]struct { generated: u64 = 0, rejected: u64 = 0 } = @splat(.{});

    const total_days = checkpoints[checkpoints.len - 1].sim_day;
    var next_cp: usize = 0;

    var day: u32 = 1;
    while (day <= total_days) : (day += 1) {
        const elapsed_ms: i64 = @as(i64, day) * CHUNK_MS;
        const day_end: i64 = SIM_START_MS + elapsed_ms;

        // Generate this simulated day's readings ONCE, shared across every
        // backend (the fix for the 5x redundant generation this file's
        // header comment describes).
        const chunk = try stream.nextChunk(allocator, day_end);
        defer allocator.free(chunk);

        // Ingest validation, also shared: a rejected reading never reaches
        // ANY backend's storage, not just some — computed once here rather
        // than once per backend.
        var accepted: std.ArrayList(sb.SensorReading) = .empty;
        defer accepted.deinit(allocator);
        for (chunk) |r| {
            const type_idx = @intFromEnum(r.sensor_type);
            quality_accum[type_idx].generated += 1;
            if (ingest_system.shouldAccept(r)) {
                try accepted.append(allocator, r);
            } else {
                quality_accum[type_idx].rejected += 1;
            }
        }

        // Operator-facing heartbeat between (possibly year-apart) checkpoints.
        if (day % 100 == 0) {
            const now = std.Io.Clock.awake.now(io);
            const elapsed_s = @as(f64, @floatFromInt(@as(i64, @intCast(wall_start.durationTo(now).nanoseconds)))) / 1e9;
            std.debug.print("  day {d}/{d} ({d:.0}%): {d} readings today, {d:.1}s elapsed\n", .{
                day, total_days, @as(f64, @floatFromInt(day)) / @as(f64, @floatFromInt(total_days)) * 100.0, chunk.len, elapsed_s,
            });
        }

        const at_checkpoint = next_cp < checkpoints.len and checkpoints[next_cp].sim_day == day;
        const cp = if (at_checkpoint) checkpoints[next_cp] else undefined;
        const is_final = at_checkpoint and next_cp == checkpoints.len - 1;

        inline for (runner.backends) |b| {
            const W = World(b.T);
            const state = &@field(states, b.name);

            var ingest = IngestChunkCall(W){ .world = &state.world, .chunk = accepted.items };
            state.stats.ingest_ns += try metrics.timeMutation(io, IngestChunkCall(W).call, .{&ingest});
            state.stats.generated += chunk.len;
            state.stats.ingested += accepted.items.len;
            state.stats.rejected += chunk.len - accepted.items.len;

            // Retention eviction: slack-scheduled normally, but
            // unconditional right before a checkpoint so every backend is
            // at the exact retention watermark when queried.
            for (type_samples) |group| {
                const type_idx = @intFromEnum(group.sensor_type);
                const retention_ms: i64 = @as(i64, synthetic.profileFor(group.sensor_type).retention_days) * CHUNK_MS;
                if (!at_checkpoint and !shouldPrune(state.last_prune[type_idx], elapsed_ms, retention_ms)) continue;
                if (elapsed_ms <= retention_ms) continue; // Nothing can be out of retention yet.

                const cutoff = day_end - retention_ms;
                const before = state.world.count();
                var prune = PruneCall(W){ .world = &state.world, .sensor_type = group.sensor_type, .cutoff = cutoff };
                state.stats.prune_ns += try metrics.timeMutation(io, PruneCall(W).call, .{&prune});
                state.stats.prune_calls += 1;
                state.stats.evicted += before - state.world.count();
                state.last_prune[type_idx] = elapsed_ms;
            }

            // Checkpoint work is gated by a runtime `if`, not an early
            // `continue` — a `continue` here would be comptime control
            // flow (this whole block is the body of an `inline for`) gated
            // on a runtime condition, which Zig rejects.
            if (at_checkpoint) {
                std.debug.print("\n  [{s}] === Checkpoint {s} (day {d}/{d}) ===\n", .{ b.name, cp.label, cp.sim_day, total_days });

                // Time the building-level query mix once each, against this
                // backend's real accumulated state at this simulated age.
                const live_count = state.world.count();
                const live_bytes = live_count * @sizeOf(sb.SensorReading);
                std.debug.print("  [{s}] running {d} building-level queries ({d} live readings, {d:.1} MB)...\n", .{
                    b.name, query_mix.len, live_count, @as(f64, @floatFromInt(live_bytes)) / (1024.0 * 1024.0),
                });
                for (query_mix) |qw| {
                    if (!isHistoricalSupported(b) and isHistorical(qw.query)) continue;

                    const qstats = try runOne(&state.world, allocator, io, qw.query, overall_sample);
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
                        .memory_bytes = state.world.memoryUsed(),
                        .live_bytes = live_bytes,
                        .reading_count = live_count,
                    });
                    if (is_final) {
                        try rows.append(allocator, .{
                            .scale = scale_label,
                            .query = queryName(qw.query),
                            .backend = b.name,
                            .memory_bytes = state.world.memoryUsed(),
                            .stats = qstats,
                        });
                    }
                }

                // Steady state only: the type-scoped per-type queries that
                // feed the per-sensor-type recommendations, and (once, from
                // the first backend to reach it — a full-retention one) the
                // per-type volume table the report uses to expose
                // disproportionate types.
                if (is_final) {
                    std.debug.print("  [{s}] steady state — running type-scoped queries across {d} sensor types...\n", .{ b.name, type_samples.len });
                    for (type_samples) |group| {
                        const type_mix = synthetic.profileFor(group.sensor_type).relevant_queries;
                        for (type_mix) |qw| {
                            if (!isTypeScoped(qw.query)) continue;
                            if (!isHistoricalSupported(b) and isHistorical(qw.query)) continue;

                            const qstats = try runOne(&state.world, allocator, io, qw.query, group.args);
                            try type_rows.append(allocator, .{
                                .scale = @tagName(group.sensor_type),
                                .query = queryName(qw.query),
                                .backend = b.name,
                                .memory_bytes = state.world.memoryUsed(),
                                .stats = qstats,
                            });
                        }
                    }

                    if (type_volumes.items.len == 0) {
                        for (type_samples) |group| {
                            const rs = try state.world.readingsForType(group.sensor_type);
                            defer allocator.free(rs);
                            try type_volumes.append(allocator, .{
                                .sensor_type = group.sensor_type,
                                .reading_count = rs.len,
                                .bytes = rs.len * @sizeOf(sb.SensorReading),
                            });
                        }
                    }
                }
            }
        }

        if (at_checkpoint) next_cp += 1;
    }

    for (type_samples) |group| {
        const q = quality_accum[@intFromEnum(group.sensor_type)];
        try type_quality.append(allocator, .{ .sensor_type = group.sensor_type, .generated = q.generated, .rejected = q.rejected });
    }

    // Per-backend wall_ns is deliberately NOT a wall-clock measurement here:
    // with generation now shared across backends within one interleaved day
    // loop, no backend has an independent "start to finish" wall-clock span
    // to attribute a compression ratio to. Instead it's the sum of that
    // backend's own timed ingest+prune cost — an honest "how fast can THIS
    // backend absorb and evict data" compression figure that excludes both
    // shared generation and query time, rather than a number that would
    // double-count time other backends were also using the CPU.
    inline for (runner.backends) |b| {
        const state = &@field(states, b.name);
        state.stats.sim_ms = @as(i64, total_days) * CHUNK_MS;
        state.stats.wall_ns = state.stats.ingest_ns + state.stats.prune_ns;
        try sim_stats_out.append(allocator, state.stats);

        std.debug.print("  [{s}] simulation complete: {d} days, {d} generated, {d} ingested, {d} evicted in {d} prunes (~{d:.0}x ingest+prune compression)\n", .{
            b.name,
            total_days,
            state.stats.generated,
            state.stats.ingested,
            state.stats.evicted,
            state.stats.prune_calls,
            state.stats.compressionRatio(),
        });
    }

    const wall_end = std.Io.Clock.awake.now(io);
    const total_wall_s = @as(f64, @floatFromInt(@as(i64, @intCast(wall_start.durationTo(wall_end).nanoseconds)))) / 1e9;
    std.debug.print("\n--- Simulation complete: {d} days across {d} backends in {d:.1}s wall time ---\n", .{ total_days, runner.backends.len, total_wall_s });
}

// ---------------------------------------------------------------------------
// Tests — written fresh against the current simulation.zig (2026-07-04),
// covering the pure-math functions this file's performance rewrite (Steps
// 1/2/4 of the sim-perf-overhaul plan) depends on staying correct.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "simDaysForRetention: short retention gets the 30-day floor margin" {
    // 90d retention -> margin max(30, 90/20=4) = 30 -> 120 sim days.
    try testing.expectEqual(@as(u32, 120), simDaysForRetention(90));
}

test "simDaysForRetention: long retention gets the proportional (5%) margin instead" {
    // structural: 2555d retention -> margin max(30, 2555/20=127) = 127 -> 2682.
    try testing.expectEqual(@as(u32, 2682), simDaysForRetention(2555));
}

test "deriveSimDays: uses the longest retention among placed types; empty input is zero" {
    const types = [_]sb.SensorType{ .temperature, .vibration, .structural };
    try testing.expectEqual(simDaysForRetention(2555), deriveSimDays(&types));

    const short = [_]sb.SensorType{.vibration}; // 90d retention
    try testing.expectEqual(simDaysForRetention(90), deriveSimDays(&short));

    try testing.expectEqual(@as(u32, 0), deriveSimDays(&.{}));
}

test "deriveCheckpoints: short building gets day/week/month ladder + steady state, no duplicate" {
    const cps = try deriveCheckpoints(testing.allocator, 120);
    defer testing.allocator.free(cps);

    const expected_days = [_]u32{ 1, 7, 30, 90, 120 };
    try testing.expectEqual(expected_days.len, cps.len);
    for (cps, expected_days) |cp, d| try testing.expectEqual(d, cp.sim_day);
    try testing.expectEqualStrings("steady state", cps[cps.len - 1].label);
}

test "deriveCheckpoints: a ladder day exactly equal to the sim end collapses into steady state, not both" {
    const cps = try deriveCheckpoints(testing.allocator, 365);
    defer testing.allocator.free(cps);

    // 365 ("year 1") is on the ladder AND is the sim end — must appear once.
    const expected_days = [_]u32{ 1, 7, 30, 90, 182, 365 };
    try testing.expectEqual(expected_days.len, cps.len);
    for (cps, expected_days) |cp, d| try testing.expectEqual(d, cp.sim_day);
    try testing.expectEqualStrings("steady state", cps[cps.len - 1].label);
}

test "deriveCheckpoints: zero sim days yields an empty schedule, not a crash" {
    const cps = try deriveCheckpoints(testing.allocator, 0);
    defer testing.allocator.free(cps);
    try testing.expectEqual(@as(usize, 0), cps.len);
}

test "prune cadence: 10% slack, never finer than one chunk" {
    const day: i64 = MS_PER_DAY;

    // 90d retention -> prune every 9 simulated days, not before.
    const temp_retention = 90 * day;
    try testing.expectEqual(9 * day, pruneIntervalMs(temp_retention));
    try testing.expect(!shouldPrune(0, 8 * day, temp_retention));
    try testing.expect(shouldPrune(0, 9 * day, temp_retention));

    // A retention window so short that 10% of it is under one chunk still
    // prunes no finer than per-chunk (never a sub-day prune schedule).
    try testing.expectEqual(CHUNK_MS, pruneIntervalMs(2 * day));
}

test "SimStats.compressionRatio: sim/wall ratio, guards divide-by-zero" {
    var s = SimStats{ .backend = "TimeSeries" };
    try testing.expectEqual(@as(f64, 0.0), s.compressionRatio());

    // 1 simulated hour compressed into 1 wall millisecond = 3,600,000x.
    s.sim_ms = 60 * 60 * 1000;
    s.wall_ns = 1_000_000;
    try testing.expectApproxEqRel(@as(f64, 3_600_000.0), s.compressionRatio(), 1e-9);
}

// ---------------------------------------------------------------------------
