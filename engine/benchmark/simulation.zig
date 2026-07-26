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
/// of this many readings PER SENSOR for EVERY sensor type, floored here and
/// raised only if a placed type samples fast enough to need more (see
/// deriveRingBufferCap below — revised 2026-07-07; the original design
/// decision 2026-07-01 used this as an unconditional flat value with no
/// per-type or frequency math at all). The live feed writes at each type's
/// own cadence and RingBuffer's existing eviction (the Nth+1 write drops
/// the oldest) keeps only the most recent capacity. `setRetentionHint` is a
/// genuine no-op on every full-retention backend, so applying it
/// unconditionally caps only RingBuffer. Because RingBuffer thus holds a
/// fraction of the data most queries need, it competes only in the compound
/// recommendation's real-time track (report.recommendCompound), never the
/// historical one.
pub const RINGBUFFER_CAP_FLOOR: usize = 10;

/// RingBuffer capacity for a building whose fastest-sampling placed type
/// samples at max_frequency_hz — enough readings to cover a 1-second
/// real-time window at that rate, floored at RINGBUFFER_CAP_FLOOR. A flat
/// 10-reading cap is fine for today's sub-1Hz sensor types (5-60 minute
/// intervals) but would starve a genuinely high-frequency type (e.g. a
/// 100Hz accelerometer) down to a fraction of a second of history. Pure
/// math, exposed for tests; production callers use deriveRingBufferCap.
pub fn ringBufferCapForFrequency(max_frequency_hz: f32) usize {
    const from_rate: usize = @intFromFloat(@ceil(max_frequency_hz));
    return @max(RINGBUFFER_CAP_FLOOR, from_rate);
}

/// Flat RingBuffer capacity for the actual placed sensor types in this
/// building — sized to whichever placed type samples fastest, not
/// hardcoded. Still one flat number applied to every type (no per-type
/// formula — CLAUDE.md's storage-redesign-plan.md), just building-derived
/// instead of a literal constant. Returns the floor for an empty slice.
pub fn deriveRingBufferCap(sensor_types: []const sb.SensorType) usize {
    var max_frequency_hz: f32 = 0;
    for (sensor_types) |t| {
        max_frequency_hz = @max(max_frequency_hz, synthetic.profileFor(t).frequency_hz);
    }
    return ringBufferCapForFrequency(max_frequency_hz);
}

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
    /// Total readings no longer resident at run end (ingested minus live
    /// count), derived generically from `ingested - count()` rather than
    /// accumulated from pruneOlderThan deltas. A per-prune delta would read
    /// as zero for RingBuffer, whose real eviction is an unobservable
    /// overwrite inside insert() (pruneOlderThan is a no-op for it, per
    /// storage_backend.zig) — the interface exposes no eviction-count
    /// method (CLAUDE.md 3.2: no backend-specific public surface), so this
    /// is computed from data every backend already reports.
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

/// Overwrites `.memory_bytes` on every GrowthPoint from `start_idx` onward
/// with `memory_bytes` — so every row a checkpoint's query batch produced
/// reports one consistent snapshot (taken once, after that batch finished)
/// instead of a value that depended on which query in the batch happened
/// to run first (CLAUDE.md §3.4's memory-measurement phases collapse to
/// one number per RunRow/GrowthPoint; this is the "after this batch of
/// queries" phase, applied uniformly rather than order-dependently).
fn backfillGrowthMemory(growth: []GrowthPoint, start_idx: usize, memory_bytes: usize) void {
    for (growth[start_idx..]) |*g| g.memory_bytes = memory_bytes;
}

/// Same as `backfillGrowthMemory`, for the `report.RunRow` slice.
fn backfillRowMemory(rows: []report.RunRow, start_idx: usize, memory_bytes: usize) void {
    for (rows[start_idx..]) |*r| r.memory_bytes = memory_bytes;
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
// Steps 2 + memory fix of the sim-perf-overhaul: every backend used to own
// its own synthetic.Stream and independently regenerate the ENTIRE
// deterministic multi-year feed from scratch (5x redundant generation for
// identical output — only ingest genuinely differs per backend). An
// interim design shared one day loop across all backends simultaneously,
// which fixed the redundant generation but kept every backend's full
// multi-year history resident in RAM at the same time — ~4 full-retention
// copies (~12-14GB at hospital scale), more than a 16GB machine holds.
//
// Current design: backends run SEQUENTIALLY, one full timeline each, so
// peak memory is ONE backend's history plus one day's chunk — while
// generation still happens exactly once. The first backend consumes the
// live Stream, and each day's accepted readings are simultaneously spilled
// to an on-disk replay file (length-prefixed raw SensorReading records);
// every subsequent backend replays that file day-by-day. Byte-identical
// input for every backend by construction (same seed wrote the file), so
// results stay apples-to-apples and deterministic. The replay file is a
// generation cache, not a storage backend — every backend still ingests
// into RAM and is queried in RAM (CLAUDE.md §6's do-not-measure list is
// untouched; file I/O happens between timed sections, never inside
// metrics.timeQuery/timeMutation).
// ---------------------------------------------------------------------------

/// timeMutation callable — inserts one already-generated day's chunk into
/// one backend's World, timed. Generation/replay happens upstream in the
/// day loop — this only measures this backend's own insert cost.
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

fn isHistoricalSupported(comptime b: runner.BackendEntry) bool {
    inline for (runner.supported_backends) |sup| {
        if (std.mem.eql(u8, sup.name, b.name)) return true;
    }
    return false;
}

/// Name of the replay-cache file created inside the caller-provided
/// directory for the duration of one simulateAllBackends run. Exposed so
/// main.zig can clean it up (it lives in the run's output dir).
pub const REPLAY_FILE_NAME = "replay-cache.tmp";

/// Per-type ingest quality tally, accumulated during generation only (the
/// first backend's pass) — rejection is a property of the reading itself,
/// identical for every backend.
const QualityAccum = struct { generated: u64 = 0, rejected: u64 = 0 };

/// Append-side of the on-disk replay cache. One frame per simulated day:
/// a 16-byte header (u64 raw generated count — pre-validation, so replaying
/// backends can report the same generated/rejected stats as the generating
/// one — then u64 accepted count) followed by that many raw SensorReading
/// structs (std.mem.sliceAsBytes — same process, same ABI, never persisted
/// beyond the run, so raw in-memory layout is safe and zero-cost).
const ReplayWriter = struct {
    file: std.Io.File,
    io: std.Io,
    offset: u64 = 0,

    fn appendChunk(self: *ReplayWriter, generated: u64, chunk: []const sb.SensorReading) !void {
        const header: [16]u8 = @bitCast([2]u64{ generated, chunk.len });
        try self.file.writePositionalAll(self.io, &header, self.offset);
        self.offset += header.len;
        const bytes = std.mem.sliceAsBytes(chunk);
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

/// Read-side cursor over the replay cache — one per replaying backend,
/// starting at offset 0. nextChunk returns exactly the day frames
/// appendChunk wrote, in order.
const ReplayCursor = struct {
    file: std.Io.File,
    io: std.Io,
    offset: u64 = 0,

    fn nextChunk(self: *ReplayCursor, allocator: std.mem.Allocator, generated_out: *u64) ![]sb.SensorReading {
        var header: [16]u8 = undefined;
        const header_read = try self.file.readPositionalAll(self.io, &header, self.offset);
        if (header_read != header.len) return error.ReplayCacheTruncated;
        self.offset += header.len;

        const counts: [2]u64 = @bitCast(header);
        generated_out.* = counts[0];
        const chunk = try allocator.alloc(sb.SensorReading, counts[1]);
        errdefer allocator.free(chunk);
        const bytes = std.mem.sliceAsBytes(chunk);
        const body_read = try self.file.readPositionalAll(self.io, bytes, self.offset);
        if (body_read != bytes.len) return error.ReplayCacheTruncated;
        self.offset += bytes.len;

        return chunk;
    }
};

/// Where one backend's day loop gets its readings: the first backend
/// generates (validating, tallying quality, and spilling to the replay
/// file as it goes); every later backend replays the file. Both variants
/// return the identical accepted-readings chunk for a given day.
const DaySource = union(enum) {
    generate: struct {
        stream: *synthetic.Stream,
        writer: *ReplayWriter,
        quality: *[SENSOR_TYPE_COUNT]QualityAccum,
    },
    replay: ReplayCursor,

    /// Caller frees the returned slice. `generated_out` reports how many
    /// readings the stream produced BEFORE ingest validation (equals the
    /// returned slice's length in replay mode, where rejected readings
    /// were never written).
    fn nextChunk(self: *DaySource, allocator: std.mem.Allocator, day_end: i64, generated_out: *u64) ![]sb.SensorReading {
        switch (self.*) {
            .generate => |g| {
                const raw = try g.stream.nextChunk(allocator, day_end);
                defer allocator.free(raw);
                generated_out.* = raw.len;

                // Ingest validation (see ingest_system.zig): rejected
                // readings never reach ANY backend — they are neither
                // ingested here nor written to the replay file.
                var accepted: std.ArrayList(sb.SensorReading) = .empty;
                errdefer accepted.deinit(allocator);
                for (raw) |r| {
                    g.quality[@intFromEnum(r.sensor_type)].generated += 1;
                    if (ingest_system.shouldAccept(r)) {
                        try accepted.append(allocator, r);
                    } else {
                        g.quality[@intFromEnum(r.sensor_type)].rejected += 1;
                    }
                }

                const owned = try accepted.toOwnedSlice(allocator);
                errdefer allocator.free(owned);
                try g.writer.appendChunk(raw.len, owned);
                return owned;
            },
            .replay => |*cursor| {
                return cursor.nextChunk(allocator, generated_out);
            },
        }
    }
};

/// Simulate every registered backend through the building's whole day-zero
/// timeline, SEQUENTIALLY: the first backend consumes the live Stream
/// (spilling each day's accepted readings to a replay file in
/// `replay_dir`); every later backend replays that file — generation
/// happens once, but only ONE backend's history is ever resident in RAM.
/// The final (steady-state) checkpoint additionally times the type-scoped
/// per-type queries and emits the RunRows that feed recommendCompound —
/// the headline recommendation is grounded in steady state; earlier
/// checkpoints only feed the growth curve.
///
/// The caller owns `replay_dir` and deletes REPLAY_FILE_NAME after the run.
pub fn simulateAllBackends(
    allocator: std.mem.Allocator,
    io: std.Io,
    replay_dir: std.Io.Dir,
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

    // Same flat cap for every backend/type this run — computed once from
    // the building's actual placed types (deriveRingBufferCap), not the
    // old hardcoded literal.
    var placed_types: std.ArrayList(sb.SensorType) = .empty;
    defer placed_types.deinit(allocator);
    for (type_samples) |ts| try placed_types.append(allocator, ts.sensor_type);
    const ringbuffer_cap = deriveRingBufferCap(placed_types.items);

    const total_days = checkpoints[checkpoints.len - 1].sim_day;

    std.debug.print("\n--- Live day-zero simulation: {d} backends, sequential (replay-cached generation) ---\n", .{runner.backends.len});
    // Wall clock for operator-facing progress only — never a benchmark
    // metric (those all go through metrics.timeQuery/timeMutation).
    const run_start = std.Io.Clock.awake.now(io);

    // enable_failures = true: dropout/stuck/drift are active per each
    // type's own FailureParams (synthetic.profileFor) — see
    // ingest_system.zig's header comment for how each is actually handled.
    var stream = try synthetic.Stream.init(allocator, sensors, seed, SIM_START_MS, true);
    defer stream.deinit();

    // Step 4 of the sim-perf-overhaul: cap each sensor type's generation at
    // its OWN retention-derived horizon (simDaysForRetention — the same
    // formula that sizes the whole run off the longest type, so the longest
    // type's horizon equals total_days and is never actually capped). Past
    // its horizon a type's dataset is frozen at steady-state size; ticking
    // it further would only churn identical-shaped data through
    // insert+prune. Safe because every benchmark query anchors its window
    // to the data's own newest reading (getLatestBySensor / newest among
    // members), never to absolute sim-now. Data-driven per type — the day
    // counts come from profileFor's retention_days, no type branches.
    var type_horizon_days: [SENSOR_TYPE_COUNT]u32 = @splat(0);
    for (type_samples) |group| {
        const retention = synthetic.profileFor(group.sensor_type).retention_days;
        type_horizon_days[@intFromEnum(group.sensor_type)] = simDaysForRetention(retention);
    }
    stream.capHorizons(&type_horizon_days);

    const replay_file = try replay_dir.createFile(io, REPLAY_FILE_NAME, .{ .read = true });
    defer replay_file.close(io);

    var replay_writer = ReplayWriter{ .file = replay_file, .io = io };
    var quality_accum: [SENSOR_TYPE_COUNT]QualityAccum = @splat(.{});

    inline for (runner.backends, 0..) |b, backend_idx| {
        const W = World(b.T);

        std.debug.print("\n--- Backend {d}/{d}: {s} ({s}) ---\n", .{
            backend_idx + 1,
            runner.backends.len,
            b.name,
            if (backend_idx == 0) "generating + spilling replay cache" else "replaying cache",
        });

        var world = try W.init(allocator);
        defer world.deinit();

        // Cap every placed sensor type at ringbuffer_cap BEFORE the first
        // insert (RingBuffer sizes a sensor's buffer when it's first seen);
        // a no-op on the full-retention backends.
        for (type_samples) |group| try world.setRetentionHint(group.sensor_type, ringbuffer_cap);
        // Topology up front — the first checkpoint's zone/floor/spatial
        // queries need it. Positions are the REAL parsed placement
        // (ZoneLocation.position from the IFC), same source as zones.
        for (locations) |loc| {
            try world.registerZone(loc.sensor_id, loc.zone_id);
            try world.registerPosition(loc.sensor_id, .{
                .x = @floatCast(loc.position.x),
                .y = @floatCast(loc.position.y),
                .z = @floatCast(loc.position.z),
            });
        }
        for (zone_floor) |zf| try world.registerFloor(zf.zone_id, zf.floor_id);

        var source: DaySource = if (backend_idx == 0)
            .{ .generate = .{ .stream = &stream, .writer = &replay_writer, .quality = &quality_accum } }
        else
            .{ .replay = .{ .file = replay_file, .io = io } };

        var stats = SimStats{ .backend = b.name };
        // Per-type prune bookkeeping, in sim-relative ms. The schedule
        // depends only on simulated time -> identical across backends.
        var last_prune: [SENSOR_TYPE_COUNT]i64 = @splat(0);
        var next_cp: usize = 0;
        const backend_start = std.Io.Clock.awake.now(io);

        var day: u32 = 1;
        while (day <= total_days) : (day += 1) {
            const elapsed_ms: i64 = @as(i64, day) * CHUNK_MS;
            const day_end: i64 = SIM_START_MS + elapsed_ms;

            var generated_today: u64 = 0;
            const chunk = try source.nextChunk(allocator, day_end, &generated_today);
            defer allocator.free(chunk);

            var ingest = IngestChunkCall(W){ .world = &world, .chunk = chunk };
            stats.ingest_ns += try metrics.timeMutation(io, IngestChunkCall(W).call, .{&ingest});
            stats.generated += generated_today;
            stats.ingested += chunk.len;
            stats.rejected += generated_today - chunk.len;

            // Operator-facing heartbeat between (possibly year-apart) checkpoints.
            if (day % 100 == 0) {
                const now = std.Io.Clock.awake.now(io);
                const elapsed_s = @as(f64, @floatFromInt(@as(i64, @intCast(run_start.durationTo(now).nanoseconds)))) / 1e9;
                std.debug.print("  [{s}] day {d}/{d} ({d:.0}%): {d} readings today, {d} live, {d:.1}s total elapsed\n", .{
                    b.name, day, total_days, @as(f64, @floatFromInt(day)) / @as(f64, @floatFromInt(total_days)) * 100.0, chunk.len, world.count(), elapsed_s,
                });
            }

            const at_checkpoint = next_cp < checkpoints.len and checkpoints[next_cp].sim_day == day;

            // Retention eviction: slack-scheduled normally, but
            // unconditional right before a checkpoint so every backend is
            // at the exact retention watermark when queried.
            //
            // The prune watermark freezes with the type's generation
            // horizon (capHorizons above): once a type stops generating,
            // advancing the cutoff with sim time would eventually evict
            // its ENTIRE frozen dataset and late checkpoints would measure
            // empty backends. Freezing the cutoff keeps exactly the
            // steady-state retention window resident — the same data the
            // type would hold at any later checkpoint anyway. After the
            // freeze-watermark prune has run once, the type is skipped
            // (further prunes with the same cutoff are guaranteed no-ops).
            for (type_samples) |group| {
                const type_idx = @intFromEnum(group.sensor_type);
                const retention_ms: i64 = @as(i64, synthetic.profileFor(group.sensor_type).retention_days) * CHUNK_MS;
                const horizon_ms: i64 = @as(i64, type_horizon_days[type_idx]) * CHUNK_MS;
                const watermark_ms = @min(elapsed_ms, horizon_ms);
                if (last_prune[type_idx] >= horizon_ms) continue; // Frozen; final prune already ran.
                if (!at_checkpoint and !shouldPrune(last_prune[type_idx], watermark_ms, retention_ms)) continue;
                if (watermark_ms <= retention_ms) continue; // Nothing can be out of retention yet.

                const cutoff = SIM_START_MS + watermark_ms - retention_ms;
                var prune = PruneCall(W){ .world = &world, .sensor_type = group.sensor_type, .cutoff = cutoff };
                stats.prune_ns += try metrics.timeMutation(io, PruneCall(W).call, .{&prune});
                stats.prune_calls += 1;
                last_prune[type_idx] = watermark_ms;
            }

            if (at_checkpoint) {
                const cp = checkpoints[next_cp];
                const is_final = next_cp == checkpoints.len - 1;

                std.debug.print("\n  [{s}] === Checkpoint {s} (day {d}/{d}) ===\n", .{ b.name, cp.label, cp.sim_day, total_days });

                // Time the building-level query mix once each, against this
                // backend's real accumulated state at this simulated age.
                const live_count = world.count();
                const live_bytes = live_count * @sizeOf(sb.SensorReading);
                std.debug.print("  [{s}] running {d} building-level queries ({d} live readings, {d:.1} MB)...\n", .{
                    b.name, query_mix.len, live_count, @as(f64, @floatFromInt(live_bytes)) / (1024.0 * 1024.0),
                });
                // Warm up once, untimed, before any query in the mix is
                // measured. Some backends defer write-time housekeeping to
                // first read (TimeSeries/Columnar lazily sort/compress a
                // freshly-ingested day-partition inside rangeByTime) — with
                // no warmup, whichever query happens to run first absorbs
                // that one-time rebuild cost while every later query in the
                // same checkpoint measures against an already-warm
                // structure, making that first query's own number a poor
                // proxy for its true steady-state cost (query_avg_window is
                // always first, since QueryName's declaration order fixes
                // deriveQueryMix's emission order — see backend-audit.md's
                // 2026-07-20 entry). Mirrors timeQuery's existing "warm up
                // once before the timed loop" convention for iterations > 1
                // (metrics_system.zig), extended to the once-per-checkpoint
                // granularity: run the first eligible query in the mix once
                // and discard the result, so the rebuild cost lands before
                // the timed loop starts rather than inside it.
                for (query_mix) |warmup_qw| {
                    if (!isHistoricalSupported(b) and isHistorical(warmup_qw.query)) continue;
                    _ = try runOne(&world, allocator, io, warmup_qw.query, overall_sample);
                    break;
                }

                const growth_start_idx = growth.items.len;
                const rows_start_idx = rows.items.len;
                for (query_mix) |qw| {
                    if (!isHistoricalSupported(b) and isHistorical(qw.query)) continue;

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
                        .memory_bytes = 0, // backfilled below, once, after the batch
                        .live_bytes = live_bytes,
                        .reading_count = live_count,
                    });
                    if (is_final) {
                        try rows.append(allocator, .{
                            .scale = scale_label,
                            .query = queryName(qw.query),
                            .backend = b.name,
                            .memory_bytes = 0, // backfilled below, once, after the batch
                            .stats = qstats,
                        });
                    }
                }
                // One memory snapshot for the whole batch, taken after every
                // query in it ran (CLAUDE.md §3.4) — not resampled per query,
                // which made a row's reported memory depend on its position
                // in the loop rather than reflecting a real measurement phase.
                const post_query_memory = world.memoryUsed();
                backfillGrowthMemory(growth.items, growth_start_idx, post_query_memory);
                if (is_final) backfillRowMemory(rows.items, rows_start_idx, post_query_memory);

                // Steady state only: the type-scoped per-type queries that
                // feed the per-sensor-type recommendations, and (once, from
                // the first backend — a full-retention one) the per-type
                // volume table the report uses to expose disproportionate
                // types.
                if (is_final) {
                    std.debug.print("  [{s}] steady state — running type-scoped queries across {d} sensor types...\n", .{ b.name, type_samples.len });
                    const type_rows_start_idx = type_rows.items.len;
                    for (type_samples) |group| {
                        const type_mix = synthetic.profileFor(group.sensor_type).relevant_queries;
                        for (type_mix) |qw| {
                            if (!isTypeScoped(qw.query)) continue;
                            if (!isHistoricalSupported(b) and isHistorical(qw.query)) continue;

                            const qstats = try runOne(&world, allocator, io, qw.query, group.args);
                            try type_rows.append(allocator, .{
                                .scale = @tagName(group.sensor_type),
                                .query = queryName(qw.query),
                                .backend = b.name,
                                .memory_bytes = 0, // backfilled below, once, after the batch
                                .stats = qstats,
                            });
                        }
                    }
                    // Same one-snapshot-per-batch treatment as the building-
                    // level query mix above.
                    backfillRowMemory(type_rows.items, type_rows_start_idx, world.memoryUsed());

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

                next_cp += 1;
            }
        }

        // wall_ns = this backend's own timed ingest+prune cost, NOT the
        // backend's wall-clock span: the first backend's span includes
        // shared generation + replay-file writes and the others' include
        // replay-file reads — none of which is the backend's own work.
        // ingest+prune is the symmetric, honest "how fast can THIS backend
        // absorb and evict data" figure the compression ratio reports.
        stats.sim_ms = @as(i64, total_days) * CHUNK_MS;
        stats.wall_ns = stats.ingest_ns + stats.prune_ns;
        stats.evicted = stats.ingested - world.count();
        try sim_stats_out.append(allocator, stats);

        const backend_end = std.Io.Clock.awake.now(io);
        std.debug.print("  [{s}] done: {d} days in {d:.1}s wall ({d} generated, {d} ingested, {d} evicted in {d} prunes, ~{d:.0}x ingest+prune compression)\n", .{
            b.name,
            total_days,
            @as(f64, @floatFromInt(@as(i64, @intCast(backend_start.durationTo(backend_end).nanoseconds)))) / 1e9,
            stats.generated,
            stats.ingested,
            stats.evicted,
            stats.prune_calls,
            stats.compressionRatio(),
        });
    }

    for (type_samples) |group| {
        const q = quality_accum[@intFromEnum(group.sensor_type)];
        try type_quality.append(allocator, .{ .sensor_type = group.sensor_type, .generated = q.generated, .rejected = q.rejected });
    }

    const run_end = std.Io.Clock.awake.now(io);
    const total_wall_s = @as(f64, @floatFromInt(@as(i64, @intCast(run_start.durationTo(run_end).nanoseconds)))) / 1e9;
    std.debug.print("\n--- Simulation complete: {d} days x {d} backends (sequential) in {d:.1}s wall time ---\n", .{ total_days, runner.backends.len, total_wall_s });
}

// ---------------------------------------------------------------------------
// Tests — written fresh against the current simulation.zig (2026-07-04),
// covering the pure-math functions this file's performance rewrite (Steps
// 1/2/4 of the sim-perf-overhaul plan) depends on staying correct.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "backfillGrowthMemory: overwrites memory_bytes only from start_idx onward" {
    var growth = [_]GrowthPoint{
        .{ .sim_day = 1, .label = "a", .backend = "TimeSeries", .query = "q1", .median_ns = 0, .memory_bytes = 111, .live_bytes = 0, .reading_count = 0 },
        .{ .sim_day = 1, .label = "a", .backend = "TimeSeries", .query = "q2", .median_ns = 0, .memory_bytes = 222, .live_bytes = 0, .reading_count = 0 },
        .{ .sim_day = 1, .label = "a", .backend = "TimeSeries", .query = "q3", .median_ns = 0, .memory_bytes = 333, .live_bytes = 0, .reading_count = 0 },
    };

    // Simulates: q1 belonged to an earlier checkpoint (untouched); q2/q3
    // belong to the checkpoint whose post-query memory snapshot is 999 —
    // both must end up reporting that SAME value, not whatever
    // world.memoryUsed() happened to return mid-loop when each was appended.
    backfillGrowthMemory(&growth, 1, 999);

    try testing.expectEqual(@as(usize, 111), growth[0].memory_bytes);
    try testing.expectEqual(@as(usize, 999), growth[1].memory_bytes);
    try testing.expectEqual(@as(usize, 999), growth[2].memory_bytes);
}

test "backfillRowMemory: overwrites memory_bytes only from start_idx onward" {
    const zero_stats: metrics.LatencyStats = .{
        .iterations = 1,
        .median_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .total_ns = 0,
    };
    var rows = [_]report.RunRow{
        .{ .scale = "S", .query = "q1", .backend = "TimeSeries", .memory_bytes = 111, .stats = zero_stats },
        .{ .scale = "S", .query = "q2", .backend = "TimeSeries", .memory_bytes = 222, .stats = zero_stats },
    };

    backfillRowMemory(&rows, 1, 999);

    try testing.expectEqual(@as(usize, 111), rows[0].memory_bytes);
    try testing.expectEqual(@as(usize, 999), rows[1].memory_bytes);
}

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

test "ringBufferCapForFrequency: floors at RINGBUFFER_CAP_FLOOR for today's sub-1Hz sensor rates" {
    try testing.expectEqual(@as(usize, RINGBUFFER_CAP_FLOOR), ringBufferCapForFrequency(1.0 / 300.0));
}

test "ringBufferCapForFrequency: zero frequency still floors" {
    try testing.expectEqual(@as(usize, RINGBUFFER_CAP_FLOOR), ringBufferCapForFrequency(0));
}

test "ringBufferCapForFrequency: a rate faster than the floor raises the cap to cover it" {
    // 100Hz sensor -> a 1-second real-time window needs 100 readings, not 10.
    try testing.expectEqual(@as(usize, 100), ringBufferCapForFrequency(100.0));
}

test "deriveRingBufferCap: uses the fastest placed type's rate; empty input is the floor" {
    const types = [_]sb.SensorType{ .temperature, .vibration, .structural };
    try testing.expectEqual(@as(usize, RINGBUFFER_CAP_FLOOR), deriveRingBufferCap(&types));

    try testing.expectEqual(@as(usize, RINGBUFFER_CAP_FLOOR), deriveRingBufferCap(&.{}));
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
