// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Synthetic sensor data generator — Phase 6, revised after research into
// real per-sensor-type behavior (see CLAUDE.md history / backend-audit.md
// for the discussion that motivated this).
//
// Turns the sensors `bim/sensor_placer.zig` placed on a real (or test)
// building into deterministic, physically-plausible readings. Per CLAUDE.md
// §3.5: "no hard-coded building assumptions; rules are data, not code" —
// every per-sensor-type characteristic (frequency, statistical shape, daily
// pattern) lives entirely in `profileFor`'s table, never in branching logic
// keyed on a specific type inside `generate`.
//
// `frequency_hz`, `shape`, `density_per_100m2`, `retention_days`, and
// `relevant_queries` are deliberately NOT building-profile concerns. There
// used to be a bim/profiles.zig with five hand-picked "building types"
// (hospital/office/warehouse/...), each re-declaring its own density,
// query-mix weighting, and retention — guessed independently per profile,
// which is exactly what caused the original bugs: energy ranged 0.1-10Hz
// and structural 1-10Hz across profiles, none close to real sensor rates,
// and density/query-mix/retention had the same problem with no research
// behind any of it. None of those characteristics are actually
// building-specific — they're properties of the SENSOR TYPE (a vibration
// sensor samples the same way and needs the same kind of anomaly detection
// whether it's in a hospital or a warehouse). This file is now the single
// canonical source for all of them; sensor_placer.zig reads
// frequency_hz/density_per_100m2 from here, main.zig derives a building's
// effective query mix from whichever sensor types actually got placed
// (via relevant_queries) instead of a human guessing a building archetype.
//
// density_per_100m2 and relevant_queries' weights are judgment calls, not
// externally verified the way frequency_hz is (AMI's 15-minute standard,
// SHM's 1-15 minute static-monitoring literature, etc.) — there's no
// equivalent industry-standard source for "how many temperature sensors
// per 100m²" or "how much does a building care about avg_zone_type for
// CO2." Each value's doc comment says which case it is.
//
// Four generation shapes, not one — a single sine+noise model was being
// applied to every sensor type regardless of how that type actually
// behaves:
//   - diurnal_continuous: smooth 24h cycle + Gaussian noise (temperature,
//     humidity, CO2, air_quality, flow, structural — real BMS/SHM trend
//     logging is smooth and slow-changing at these rates).
//   - binary_event: occupancy is a 0/1 state with realistic dwell time, not
//     a continuous value (real PIR sensors report motion/no-motion, not a
//     fractional "0.37 occupied").
//   - stepwise_discrete: energy meters hold a level (off/idle/running) and
//     jump between levels, not continuously drift (AMI meters report
//     discrete readings at fixed intervals).
//   - bursty_impulsive: vibration is flat baseline with rare sharp events,
//     not a smooth wave — this also makes anomaly detection meaningful
//     (z-score outliers correspond to injected burst events, not just
//     Gaussian tail noise that happens to clear the threshold).
//
// Determinism (CLAUDE.md §3.4): one PRNG, seeded once from `config.seed`,
// consumed in `sensors` order. Same sensors + same config -> byte-identical
// output, always.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");
const components = @import("../bim/components.zig");
const queries = @import("../benchmark/queries.zig");

pub const SensorReading = sb.SensorReading;
pub const SensorType = sb.SensorType;
pub const SensorMetadata = components.SensorMetadata;
pub const QueryWeight = queries.QueryWeight;

/// Which generation function a sensor type uses — see this file's header
/// comment for what real-world behavior each one models.
pub const Shape = enum {
    diurnal_continuous,
    binary_event,
    stepwise_discrete,
    bursty_impulsive,
};

/// Sensor failure modes modeled after real-world sensor degradation:
///   - dropout: sensor stops reporting entirely (gap in timestamps).
///   - stuck: sensor keeps reporting but the value freezes (stale reading).
///   - drift: sensor's calibration slowly shifts away from the true value.
/// All three are per-sensor-type data, not branching code. All default to
/// zero (disabled) so existing behavior is unchanged unless explicitly
/// enabled via GenerateConfig.enable_failures.
pub const FailureParams = struct {
    /// Probability per tick that this sensor enters a dropout (stops
    /// reporting). 0 = never. A sensor in dropout skips emitting readings
    /// for `dropout_duration_ticks` ticks, then resumes.
    dropout_rate: f32 = 0.0,
    /// How many ticks a dropout lasts once entered.
    dropout_duration_ticks: u32 = 10,
    /// Probability per tick that this sensor gets stuck (repeats its
    /// last real reading). 0 = never. A stuck sensor emits readings with
    /// advancing timestamps but the same value as the last real one,
    /// for `stuck_duration_ticks` ticks, then resumes normal generation.
    stuck_rate: f32 = 0.0,
    /// How many ticks a stuck condition lasts once entered.
    stuck_duration_ticks: u32 = 20,
    /// Calibration drift in parts-per-million per tick. Accumulates
    /// linearly: after N ticks, the reported value is shifted by
    /// `drift_rate_ppm * N * 1e-6 * base_value`. 0 = no drift.
    drift_rate_ppm: f32 = 0.0,
};

/// Statistical shape and full real-world characterization of one sensor
/// type. `base_value` is the 24h mean (or, for binary_event, unused —
/// occupancy likelihood is derived from `peak_hour` instead);
/// `daily_amplitude` is the swing of the daily cycle
/// (diurnal_continuous/stepwise_discrete) peaking at `peak_hour` (0-23);
/// `noise_stddev` is per-reading jitter; `[min_bound, max_bound]` is the
/// physical floor/ceiling every reading is clamped to. `frequency_hz` is
/// the canonical real-world sampling rate. `density_per_100m2` is how many
/// sensors of this type to place per 100m² of the element they attach to.
/// `retention_days` is how long this type's data is realistically kept
/// before archival/eviction. `relevant_queries` is which of the 12 query
/// patterns matter for this type and how much — main.zig derives a
/// building's effective query mix from the union of whichever types
/// actually got placed, instead of a human guessing a building archetype.
/// See this file's header comment for why all of this lives here and not
/// in a building-profile file.
pub const SensorProfile = struct {
    base_value: f32,
    daily_amplitude: f32,
    peak_hour: f32,
    noise_stddev: f32,
    min_bound: f32,
    max_bound: f32,
    frequency_hz: f32,
    shape: Shape,
    density_per_100m2: f32,
    retention_days: u32,
    relevant_queries: []const QueryWeight,
    /// Per-type failure mode parameters. All default to zero (disabled).
    /// Set GenerateConfig.enable_failures = true to activate them.
    failures: FailureParams = .{},
};

/// One row per `SensorType` — the only place "realistic" is defined. Adding
/// a new SensorType means adding one row here, never an `if` in `generate`.
///
/// frequency_hz is research-grounded, not guessed:
///   - temperature/humidity: BMS trend logging at 5-minute intervals is
///     the documented convention for monitoring points (ControlsHub
///     Article 98, ASHRAE Guideline 13). 1/300.
///   - co2/air_quality: IAQ sensors use the same 5-minute BMS trend
///     interval — 3-minute was too aggressive for historian logging.
///     ControlsHub: monitoring points = 5-15min. 1/300.
///   - flow: HVAC control loops update ~30s internally, but what gets
///     logged/historized is coarser — 1/300 (5min) reflects realistic
///     historian logging per ControlsHub's monitoring-point category,
///     not the internal PID rate.
///   - occupancy: PIR sensors are event-based (COV — Change-of-Value),
///     NOT periodic pollers. They report only on state transitions
///     (occupied → unoccupied). frequency_hz here represents the minimum
///     gap between logged events (debounce/cooldown), not a fixed sampling
///     rate. 1/300 (5-min minimum gap) matches BACnet COV reporting
///     intervals. The binary_event shape already emits only on transitions,
///     so actual readings are ~15/day for a typical office, not 288/day.
///   - energy: 15-minute intervals are the documented AMI/smart-meter
///     industry standard (IEC 62056, Dutch DSMR, Measurement Canada).
///     1/900.
///   - vibration: ISO 13373-1 says normal-range condition monitoring is
///     periodic (hours/days), not minutes. Continuous high-frequency
///     capture is reserved for alarm/maintenance conditions. 1/3600
///     (1hr) for baseline trending of steady-state rotating equipment.
///   - structural: static SHM trend monitoring uses 1-15 minute intervals
///     (continuous high-Hz sampling is reserved for active seismic/dynamic
///     EVENT capture, not baseline monitoring); 1/600 (10min) sits in that
///     range. The previous 1-10Hz values across building profiles were
///     600-6000x too fast for this sensor type.
///
/// retention_days is research-grounded:
///   - temperature/humidity/flow: 397 days (13 months) — ASHRAE Guideline 13
///     specifies 13 months minimum for trend data to enable full seasonal
///     comparison (the extra month provides year-over-year overlap).
///     ControlsHub Article 98 confirms: trend data min 13 months,
///     recommended 3-5 years.
///   - co2/air_quality: 397 days (13 months) — same ASHRAE Guideline 13
///     minimum for trend data. The previous 3yr (WELL) was for compliance
///     records, not operational trend logs; 13 months is the defensible
///     trend-data retention.
///   - occupancy: 90 days — no regulatory retention standard exists for
///     occupancy data. Privacy/data-minimization literature (GDPR Article 5,
///     BACnet COV best practices) argues for keeping this short. 90 days
///     is generous for occupancy analytics and pattern detection.
///   - energy: 730 days (2 years) — Measurement Canada E-35 policy:
///     15-min interval data retained minimum 2 calendar years. EU
///     Regulation 2023/1162 aligns. Previous 5yr was excessive for this
///     tool's scope.
///   - structural: 2555 days (7 years) — strain gauges have 10+ year
///     service life (Resensys, SHM industry). 7 years matches typical
///     facility-records compliance windows for long-term structural drift.
///   - vibration: 90 days — ISO 13373-1 recommends increasing surveillance
///     when vibration trends change; 90 days allows seasonal comparison
///     for condition trending. Steady-state data dumping is standard
///     practice per ISO 13373.
///
/// density_per_100m2 has no equivalent external standard the way
/// frequency_hz does — there's no "ISO spec for thermostats per square
/// meter." These are reasonable placement defaults (roughly one
/// comfort/safety sensor per typical room for occupancy-adjacent types,
/// sparser for equipment-bound types that scale with equipment count more
/// than floor area), not verified against building codes.
///
/// relevant_queries is judgment, not research — there's no published
/// source for "how often does a building query CO2 anomaly detection."
/// The reasoning: latest_single/latest_zone are universal (every type
/// benefits from "what's the current reading"); anomalies/threshold_breach
/// concentrate on safety/equipment-health types (vibration, energy,
/// structural, CO2/air_quality) where statistical or fixed-limit alerting
/// is a real use case, and are intentionally absent or low-weight for
/// occupancy (binary — z-score anomaly detection on a 0/1 signal isn't
/// meaningful) and humidity/flow (comfort-only, lower safety stakes).
const COMFORT_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 3.0, .hot = true },
    .{ .query = .latest_zone, .weight = 3.0, .hot = true },
    .{ .query = .avg_window, .weight = 3.0, .hot = false },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .hourly_rollup, .weight = 2.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 2.0, .hot = false },
    .{ .query = .threshold_breach, .weight = 3.0, .hot = true },
    .{ .query = .anomalies, .weight = 1.0, .hot = true },
};

const COMFORT_QUERIES_NO_THRESHOLD = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 2.0, .hot = true },
    .{ .query = .latest_zone, .weight = 2.0, .hot = true },
    .{ .query = .avg_window, .weight = 3.0, .hot = false },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 2.0, .hot = false },
    .{ .query = .threshold_breach, .weight = 2.0, .hot = true },
};

const OCCUPANCY_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 4.0, .hot = true },
    .{ .query = .latest_zone, .weight = 5.0, .hot = true },
    .{ .query = .avg_zone_type, .weight = 3.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 2.0, .hot = false },
    .{ .query = .zone_hierarchy, .weight = 2.0, .hot = false },
    .{ .query = .spatial_radius, .weight = 2.0, .hot = true },
};

const AIR_SAFETY_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 3.0, .hot = true },
    .{ .query = .latest_zone, .weight = 3.0, .hot = true },
    .{ .query = .avg_window, .weight = 2.0, .hot = false },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .threshold_breach, .weight = 4.0, .hot = true },
    .{ .query = .anomalies, .weight = 2.0, .hot = true },
};

const EQUIPMENT_HEALTH_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 2.0, .hot = true },
    .{ .query = .anomalies, .weight = 5.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 3.0, .hot = true },
    .{ .query = .avg_zone_type, .weight = 1.0, .hot = false },
    .{ .query = .spatial_radius, .weight = 2.0, .hot = true },
};

const FLOW_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 2.0, .hot = true },
    .{ .query = .avg_window, .weight = 3.0, .hot = false },
    .{ .query = .threshold_breach, .weight = 3.0, .hot = true },
    .{ .query = .hourly_rollup, .weight = 2.0, .hot = false },
};

const ENERGY_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 3.0, .hot = true },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .hourly_rollup, .weight = 3.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 3.0, .hot = false },
    .{ .query = .anomalies, .weight = 4.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 3.0, .hot = true },
};

const STRUCTURAL_QUERIES = [_]QueryWeight{
    .{ .query = .latest_single, .weight = 2.0, .hot = true },
    .{ .query = .avg_zone_type, .weight = 2.0, .hot = false },
    .{ .query = .daily_zone_rollup, .weight = 2.0, .hot = false },
    .{ .query = .anomalies, .weight = 5.0, .hot = true },
    .{ .query = .threshold_breach, .weight = 4.0, .hot = true },
    .{ .query = .spatial_radius, .weight = 2.0, .hot = true },
};

/// Per-type failure rates below are reasoned defaults, not researched
/// figures (no published source gives "dropout probability per tick" the
/// way frequency_hz has one) — same disclosure category as
/// density_per_100m2. Only drift_rate_ppm has any effect on
/// ingest_system.shouldAccept: every generative shape already clamps its
/// own output to [min_bound, max_bound], so dropout/stuck never produce an
/// out-of-bounds reading by construction — only accumulated drift (applied
/// AFTER a shape's own clamp) can push a value outside physical bounds,
/// which is the one thing a real gateway can actually catch from a single
/// reading. Left at zero (disabled) for types not listed below — enabling
/// every type at once would make failure noise dominate every query result
/// rather than being an occasional, realistic degradation.
/// 1.6 ppm is calibrated (not researched) so accumulated drift crosses
/// temperature's ~26-unit headroom to max_bound only very close to the end
/// of a multi-year run with structural sensors present (~2682 sim days) —
/// a smoke test at 5 ppm crossed at ~32% of the way through the run,
/// meaning most of a 7-year simulated building's temperature history would
/// have been permanently rejected (drift only grows, never resets) instead
/// of the rare, late-onset degradation this is meant to model.
const TEMPERATURE_FAILURES = FailureParams{ .drift_rate_ppm = 1.6 };
const OCCUPANCY_FAILURES = FailureParams{ .stuck_rate = 0.0003, .stuck_duration_ticks = 30 };
const ENERGY_FAILURES = FailureParams{ .dropout_rate = 0.0004, .dropout_duration_ticks = 8 };
const VIBRATION_FAILURES = FailureParams{ .dropout_rate = 0.0008, .dropout_duration_ticks = 6 };

pub fn profileFor(sensor_type: SensorType) SensorProfile {
    return switch (sensor_type) {
        .temperature => .{ .base_value = 21.0, .daily_amplitude = 3.0, .peak_hour = 15.0, .noise_stddev = 0.3, .min_bound = 0.0, .max_bound = 50.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 397, .relevant_queries = &COMFORT_QUERIES, .failures = TEMPERATURE_FAILURES },
        .humidity => .{ .base_value = 45.0, .daily_amplitude = 10.0, .peak_hour = 5.0, .noise_stddev = 2.0, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 397, .relevant_queries = &COMFORT_QUERIES_NO_THRESHOLD },
        .occupancy => .{ .base_value = 0.0, .daily_amplitude = 0.0, .peak_hour = 13.0, .noise_stddev = 0.0, .min_bound = 0.0, .max_bound = 1.0, .frequency_hz = 1.0 / 300.0, .shape = .binary_event, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &OCCUPANCY_QUERIES, .failures = OCCUPANCY_FAILURES },
        .co2 => .{ .base_value = 450.0, .daily_amplitude = 350.0, .peak_hour = 14.0, .noise_stddev = 20.0, .min_bound = 350.0, .max_bound = 5000.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 397, .relevant_queries = &AIR_SAFETY_QUERIES },
        .vibration => .{ .base_value = 0.05, .daily_amplitude = 0.15, .peak_hour = 13.0, .noise_stddev = 0.02, .min_bound = 0.0, .max_bound = 10.0, .frequency_hz = 1.0 / 3600.0, .shape = .bursty_impulsive, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &EQUIPMENT_HEALTH_QUERIES, .failures = VIBRATION_FAILURES },
        .flow => .{ .base_value = 5.0, .daily_amplitude = 4.0, .peak_hour = 10.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.5, .retention_days = 397, .relevant_queries = &FLOW_QUERIES },
        .energy => .{ .base_value = 2.0, .daily_amplitude = 6.0, .peak_hour = 13.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 900.0, .shape = .stepwise_discrete, .density_per_100m2 = 0.5, .retention_days = 730, .relevant_queries = &ENERGY_QUERIES, .failures = ENERGY_FAILURES },
        .structural => .{ .base_value = 50.0, .daily_amplitude = 5.0, .peak_hour = 15.0, .noise_stddev = 1.0, .min_bound = 0.0, .max_bound = 1000.0, .frequency_hz = 1.0 / 600.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 2555, .relevant_queries = &STRUCTURAL_QUERIES },
        .air_quality => .{ .base_value = 50.0, .daily_amplitude = 20.0, .peak_hour = 17.0, .noise_stddev = 5.0, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 397, .relevant_queries = &AIR_SAFETY_QUERIES },
    };
}

// ---------------------------------------------------------------------------
// Stream — tick-by-tick streaming generation for the live day-zero simulation.
//
// The live simulation needs to advance time across ALL sensors
// simultaneously, one chunk at a time, so that checkpoints see a building at
// a specific simulated age. A naive batch call that reseeds one shared PRNG
// and walks each sensor's full timeline in one shot can't do this: repeated
// calls would replay the same PRNG sequence (chunks would share noise),
// reset stepwise/failure state at seams, and shift tick grids at unaligned
// boundaries.
//
// `Stream` solves this with per-sensor `SensorState` that persists across
// chunks: each sensor has its own PRNG (seeded from `base_seed ^ sensor_id`),
// its own tick-grid anchor (`next_t`), and its own shape/failure state.
// `nextChunk(allocator, chunk_end)` advances every sensor up to `chunk_end`
// (exclusive), returning all readings produced in that interval. The same
// `Stream` with the same seed produces byte-identical output regardless of
// chunk boundaries (3×1-day == 1×3-day).
// ---------------------------------------------------------------------------

/// Per-sensor mutable state that persists across chunks in a `Stream`.
pub const SensorState = struct {
    sensor: SensorMetadata,
    profile: SensorProfile,
    period_ms: i64,
    next_t: i64, // next tick time for this sensor
    /// Absolute ms past which this sensor never ticks again (exclusive) —
    /// set by Stream.capHorizons, unbounded by default. See capHorizons
    /// for what this models and why it is caller-supplied data.
    horizon_end: i64 = std.math.maxInt(i64),
    // Shape state
    binary_state: f32 = 0.0,
    binary_last_emitted: ?f32 = null,
    step_level: f32 = 0.0,
    step_hold: u32 = 0,
    // Failure state
    dropout_remaining: u32 = 0,
    stuck_remaining: u32 = 0,
    last_real_value: f32 = 0.0,
    tick_count: u32 = 0,
    drift_offset: f32 = 0.0,
    // Per-sensor PRNG — seeded from base_seed mixed with sensor_id so
    // chunk boundaries don't affect the random sequence.
    prng: std.Random.DefaultPrng,
};

/// Process one tick for one sensor. Returns the reading value if this tick
/// produces a reading, or null if it's suppressed (binary_event no-transition,
/// bursty_impulsive non-event, dropout). Updates `state` in place.
///
/// This mirrors `generate()`'s inner loop exactly — same draw order, same
/// shape logic, same failure handling. The only difference is that the PRNG
/// and all mutable state live in `SensorState` (per-sensor, persistent across
/// chunks) instead of local variables (per-sensor, lost at call boundary).
fn tickOnce(state: *SensorState, t: i64, enable_failures: bool) ?f32 {
    const profile = state.profile;
    const rand = state.prng.random();
    const fp = profile.failures;
    const failures_active = enable_failures and
        (fp.dropout_rate > 0 or fp.stuck_rate > 0 or fp.drift_rate_ppm > 0);

    // --- Failure mode evaluation (per tick, before shape) ---
    if (failures_active) {
        if (state.dropout_remaining > 0) {
            state.dropout_remaining -= 1;
            _ = consumeShapeDraw(profile, rand, t, &state.binary_state, &state.step_level, &state.step_hold);
            state.tick_count += 1;
            return null;
        }
        if (fp.dropout_rate > 0 and rand.float(f32) < fp.dropout_rate) {
            state.dropout_remaining = fp.dropout_duration_ticks;
            return null;
        }
        if (fp.drift_rate_ppm > 0) {
            state.drift_offset = @as(f32, @floatFromInt(state.tick_count)) * fp.drift_rate_ppm * 1e-6 * profile.base_value;
        }
        state.tick_count += 1;
    }

    // --- Shape generation ---
    var emit_value: f32 = undefined;
    var should_emit = true;

    switch (profile.shape) {
        .diurnal_continuous => {
            emit_value = sampleDiurnal(profile, rand, t);
        },
        .binary_event => {
            const value = sampleBinaryEvent(profile, rand, t, &state.binary_state);
            if (state.binary_last_emitted == null or value != state.binary_last_emitted.?) {
                state.binary_last_emitted = value;
                emit_value = value;
            } else {
                should_emit = false;
            }
        },
        .stepwise_discrete => {
            emit_value = sampleStepwiseDiscrete(profile, rand, t, &state.step_level, &state.step_hold);
        },
        .bursty_impulsive => {
            const sample = sampleBurstyImpulsive(profile, rand);
            if (sample.is_event) {
                emit_value = sample.value;
            } else {
                should_emit = false;
            }
        },
    }

    if (!should_emit) return null;

    // Apply drift offset
    if (failures_active and fp.drift_rate_ppm > 0) {
        emit_value += state.drift_offset;
    }

    // Stuck handling
    if (failures_active and fp.stuck_rate > 0 and state.stuck_remaining == 0) {
        if (rand.float(f32) < fp.stuck_rate) {
            state.stuck_remaining = fp.stuck_duration_ticks;
        }
    }
    if (failures_active and state.stuck_remaining > 0) {
        emit_value = state.last_real_value;
        state.stuck_remaining -= 1;
    } else {
        state.last_real_value = emit_value;
    }

    return emit_value;
}

/// Streaming sensor data generator for the live day-zero simulation.
/// See the doc comment above `SensorState` for the full rationale.
pub const Stream = struct {
    states: []SensorState,
    allocator: std.mem.Allocator,
    base_seed: u64,
    enable_failures: bool,
    start_time: i64,

    /// Create a stream. Each sensor gets its own `SensorState` with a
    /// per-sensor PRNG seeded from `seed` mixed with `sensor_id`. The
    /// stream starts at `start_time` — every sensor's first tick is at
    /// `start_time` (aligned tick grid).
    pub fn init(
        allocator: std.mem.Allocator,
        sensors: []const SensorMetadata,
        seed: u64,
        start_time: i64,
        enable_failures: bool,
    ) !Stream {
        const states = try allocator.alloc(SensorState, sensors.len);
        for (sensors, 0..) |sensor, i| {
            const profile = profileFor(sensor.sensor_type);
            states[i] = .{
                .sensor = sensor,
                .profile = profile,
                .period_ms = periodMs(profile.frequency_hz),
                .next_t = start_time,
                .step_level = profile.base_value,
                .last_real_value = profile.base_value,
                .prng = std.Random.DefaultPrng.init(seed ^ (@as(u64, sensor.sensor_id) *% 0x9E3779B97F4A7C15)),
            };
        }
        return .{
            .states = states,
            .allocator = allocator,
            .base_seed = seed,
            .enable_failures = enable_failures,
            .start_time = start_time,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.allocator.free(self.states);
    }

    /// Cap each sensor's generation at its own type's horizon:
    /// `horizon_days_by_type` is indexed by `@intFromEnum(sensor_type)`
    /// and gives the number of simulated days (from `start_time`) after
    /// which sensors of that type stop ticking. 0 means "no cap".
    ///
    /// Why: once a type's retention window (+ margin) has filled, its
    /// dataset is at steady-state size and further ticks only churn
    /// identical-shaped data through insert+prune without changing any
    /// query-relevant statistic — every benchmark query anchors its window
    /// to the data's own newest reading, never to absolute sim-now. The
    /// day counts are caller-supplied DATA (computed from each type's
    /// retention_days by the simulation harness); this function neither
    /// knows nor cares why a number was chosen.
    ///
    /// Determinism: each sensor has a private PRNG, so capping one type
    /// leaves every other sensor's output byte-identical, and a capped
    /// sensor's pre-horizon output is byte-identical to its uncapped run.
    ///
    /// Call before the first nextChunk/streamUntil — horizons are
    /// anchored at `start_time`, not at the stream's current position.
    pub fn capHorizons(self: *Stream, horizon_days_by_type: []const u32) void {
        const ms_per_day: i64 = 24 * 60 * 60 * 1000;
        for (self.states) |*state| {
            const days = horizon_days_by_type[@intFromEnum(state.sensor.sensor_type)];
            if (days == 0) continue;
            state.horizon_end = self.start_time + @as(i64, days) * ms_per_day;
        }
    }

    /// Generate all readings in `[max(current positions), chunk_end)` for
    /// every sensor. Returns a caller-owned slice (free with `allocator`).
    /// Readings are sorted by (timestamp, sensor_id) so backends that
    /// maintain a sorted log can append without re-sorting.
    pub fn nextChunk(self: *Stream, allocator: std.mem.Allocator, chunk_end: i64) ![]SensorReading {
        var out: std.ArrayList(SensorReading) = .empty;
        errdefer out.deinit(allocator);

        for (self.states) |*state| {
            const end = @min(chunk_end, state.horizon_end);
            while (state.next_t < end) {
                if (tickOnce(state, state.next_t, self.enable_failures)) |value| {
                    try out.append(allocator, .{
                        .sensor_id = state.sensor.sensor_id,
                        .timestamp = state.next_t,
                        .value = value,
                        .sensor_type = state.sensor.sensor_type,
                    });
                }
                state.next_t += state.period_ms;
            }
        }

        std.mem.sort(SensorReading, out.items, {}, struct {
            fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
                if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
                return lhs.sensor_id < rhs.sensor_id;
            }
        }.lt);

        return out.toOwnedSlice(allocator);
    }

    /// Advance the stream to `until_ms` (exclusive), calling `sink` for
    /// each reading in time order. Each reading is produced in (timestamp,
    /// sensor_id) order via a binary min-heap over `(next_t, sensor_id)`,
    /// rebuilt once per call (O(sensors log sensors)) and then popped/
    /// repushed once per tick (O(log sensors) each) — replaces an earlier
    /// version that linearly rescanned every sensor's state on every single
    /// tick (O(sensors) per tick, effectively quadratic in sensor count over
    /// a multi-year simulated run — see .cascade sim-perf-overhaul plan).
    /// Tie-breaking on sensor_id (not array position) matches this file's
    /// documented iteration-order contract directly, rather than depending
    /// on callers happening to pass `sensors` pre-sorted by sensor_id.
    pub fn streamUntil(
        self: *Stream,
        until_ms: i64,
        sink: anytype,
        context: anytype,
    ) !void {
        const HeapEntry = struct { next_t: i64, sensor_id: u32, idx: usize };
        const lessThan = struct {
            fn cmp(_: void, a: HeapEntry, b: HeapEntry) std.math.Order {
                if (a.next_t != b.next_t) return std.math.order(a.next_t, b.next_t);
                return std.math.order(a.sensor_id, b.sensor_id);
            }
        }.cmp;
        const Heap = std.PriorityQueue(HeapEntry, void, lessThan);

        var heap: Heap = .empty;
        defer heap.deinit(self.allocator);

        for (self.states, 0..) |*state, i| {
            if (state.next_t < @min(until_ms, state.horizon_end)) {
                try heap.push(self.allocator, .{ .next_t = state.next_t, .sensor_id = state.sensor.sensor_id, .idx = i });
            }
        }

        while (heap.pop()) |entry| {
            const state = &self.states[entry.idx];
            if (tickOnce(state, state.next_t, self.enable_failures)) |value| {
                try sink(context, .{
                    .sensor_id = state.sensor.sensor_id,
                    .timestamp = state.next_t,
                    .value = value,
                    .sensor_type = state.sensor.sensor_type,
                });
            }
            state.next_t += state.period_ms;
            if (state.next_t < @min(until_ms, state.horizon_end)) {
                try heap.push(self.allocator, .{ .next_t = state.next_t, .sensor_id = state.sensor.sensor_id, .idx = entry.idx });
            }
        }
    }

    /// Get the final binary state of all binary_event sensors, for
    /// continuity if switching from Stream to generate() or vice versa.
    pub fn captureBinaryState(self: *const Stream, map: *std.AutoHashMap(u32, f32)) !void {
        for (self.states) |state| {
            if (state.profile.shape == .binary_event) {
                if (state.binary_last_emitted) |v| try map.put(state.sensor.sensor_id, v);
            }
        }
    }
};

/// Sampling period in ms from a sensor type's canonical Hz. Frequencies <= 0
/// degrade to one sample per day rather than dividing by zero or looping
/// forever — no profile produces this today (every profileFor entry is
/// > 0), but `generate` shouldn't trust that as a precondition.
pub fn periodMs(frequency_hz: f32) i64 {
    if (frequency_hz <= 0) return 24 * 60 * 60 * 1000;
    const period_s: f64 = 1.0 / @as(f64, frequency_hz);
    return @intFromFloat(@max(1.0, @round(period_s * 1000.0)));
}

/// Smooth 24h cycle + Gaussian noise — temperature, humidity, CO2,
/// air_quality, flow, structural. See this file's header comment.
fn sampleDiurnal(profile: SensorProfile, rand: std.Random, timestamp_ms: i64) f32 {
    const hour = hourOfDay(timestamp_ms);
    const phase = (hour - profile.peak_hour) * (std.math.pi * 2.0 / 24.0);
    const daily = profile.daily_amplitude * @cos(phase);
    const noise = rand.floatNorm(f32) * profile.noise_stddev;
    const raw = profile.base_value + daily + noise;
    return std.math.clamp(raw, profile.min_bound, profile.max_bound);
}

/// Occupancy likelihood given hour-of-day: a smooth bump centered on
/// `peak_hour` (the building's busiest hour), tapering toward 0 the further
/// `hour` is from it. Not a hard business-hours window — real occupancy
/// ramps up/down rather than switching instantly at 9am/5pm.
fn occupancyLikelihood(hour: f32, peak_hour: f32) f32 {
    const diff = @abs(hour - peak_hour);
    const wrapped = @min(diff, 24.0 - diff);
    return std.math.clamp(1.0 - wrapped / 6.0, 0.05, 0.95);
}

/// Binary 0/1 state with realistic dwell time — occupancy. Real PIR sensors
/// report motion/no-motion, not a continuously varying fraction; this only
/// has a small chance to re-roll its state on each sample (biased toward
/// `occupancyLikelihood`), so it stays in a state for a while rather than
/// flickering every sample the way independently redrawing it each time
/// would.
fn sampleBinaryEvent(profile: SensorProfile, rand: std.Random, timestamp_ms: i64, state: *f32) f32 {
    const transition_chance: f32 = 0.15;
    if (rand.float(f32) < transition_chance) {
        const likelihood = occupancyLikelihood(hourOfDay(timestamp_ms), profile.peak_hour);
        state.* = if (rand.float(f32) < likelihood) 1.0 else 0.0;
    }
    return state.*;
}

/// Holds at a discrete level (e.g. off/idle/running/peak) for several
/// samples, then jumps — energy meters. Real AMI readings are precise,
/// stepped values at fixed intervals, not a continuously drifting curve;
/// `daily_amplitude` still drives which level is likely at a given hour
/// (more load during the day), but the value snaps to one of a handful of
/// levels and holds rather than interpolating smoothly between samples.
fn sampleStepwiseDiscrete(profile: SensorProfile, rand: std.Random, timestamp_ms: i64, level: *f32, hold: *u32) f32 {
    if (hold.* == 0) {
        const hour = hourOfDay(timestamp_ms);
        const phase = (hour - profile.peak_hour) * (std.math.pi * 2.0 / 24.0);
        const target = profile.base_value + profile.daily_amplitude * @cos(phase);
        const level_step = @max(profile.daily_amplitude / 3.0, 0.01);
        const level_idx = @round(target / level_step);
        level.* = std.math.clamp(level_idx * level_step, profile.min_bound, profile.max_bound);
        hold.* = 4 + rand.uintLessThan(u32, 8); // hold for several samples before re-evaluating
    }
    hold.* -= 1;
    const noise = rand.floatNorm(f32) * profile.noise_stddev * 0.2; // meter reads are precise, small jitter only
    return std.math.clamp(level.* + noise, profile.min_bound, profile.max_bound);
}

/// One sample from the bursty_impulsive model, tagged with whether it's an
/// actual event (burst) worth persisting — see sampleBurstyImpulsive's doc
/// comment and generate()'s bursty_impulsive branch for why only
/// `is_event == true` samples get stored.
const BurstSample = struct { value: f32, is_event: bool };

/// Flat baseline with rare sharp bursts — vibration. Real condition-
/// monitoring signals sit near a quiet baseline almost all the time, with
/// occasional events (impacts, bearing faults) producing a sharp spike.
/// Unlike the old uniform Gaussian-noise model, this makes anomaly
/// detection mean something: outliers correspond to actual injected burst
/// events, not just random tail noise that happened to clear the
/// threshold. `is_event` reports which branch produced this sample so the
/// caller can decide whether to persist it — tied directly to the
/// generative branch, not a derived magnitude threshold that could
/// disagree near the boundary.
fn sampleBurstyImpulsive(profile: SensorProfile, rand: std.Random) BurstSample {
    const burst_chance: f32 = 0.02;
    if (rand.float(f32) < burst_chance) {
        const burst_magnitude = profile.daily_amplitude * (3.0 + rand.float(f32) * 4.0);
        const value = std.math.clamp(profile.base_value + burst_magnitude, profile.min_bound, profile.max_bound);
        return .{ .value = value, .is_event = true };
    }
    const noise = rand.floatNorm(f32) * profile.noise_stddev;
    const value = std.math.clamp(profile.base_value + noise, profile.min_bound, profile.max_bound);
    return .{ .value = value, .is_event = false };
}

/// Consume the same RNG draws a shape would consume, without emitting a
/// reading. Used during dropout so the PRNG stays in sync regardless of
/// when dropouts occur — same seed + same sensors = same output, whether
/// or not failures are enabled. The return value is discarded.
fn consumeShapeDraw(
    profile: SensorProfile,
    rand: std.Random,
    t: i64,
    binary_state: *f32,
    step_level: *f32,
    step_hold: *u32,
) void {
    switch (profile.shape) {
        .diurnal_continuous => _ = sampleDiurnal(profile, rand, t),
        .binary_event => _ = sampleBinaryEvent(profile, rand, t, binary_state),
        .stepwise_discrete => _ = sampleStepwiseDiscrete(profile, rand, t, step_level, step_hold),
        .bursty_impulsive => _ = sampleBurstyImpulsive(profile, rand),
    }
}

/// Hour-of-day (0.0-23.999...) for a given epoch-ms timestamp. Exposed so
/// `validator.zig` can check the same daily cycle `generate` models, without
/// duplicating the math.
pub fn hourOfDay(timestamp_ms: i64) f32 {
    const ms_per_day: i64 = 24 * 60 * 60 * 1000;
    const ms_per_hour: i64 = 60 * 60 * 1000;
    // @mod (not @rem) so this stays in [0, ms_per_day) even if a future
    // caller passes a timestamp before the epoch.
    const ms_into_day = @mod(timestamp_ms, ms_per_day);
    return @as(f32, @floatFromInt(ms_into_day)) / @as(f32, @floatFromInt(ms_per_hour));
}

// ---------------------------------------------------------------------------
// Tests — written fresh against the current Stream/tickOnce implementation
// (2026-07-04), ahead of the streamUntil O(sensors)-per-tick performance
// rewrite (see .cascade plans). The determinism/ordering/chunk-equivalence
// tests below are the safety net for that rewrite: a heap-based replacement
// must reproduce this exact output for the same seed.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSensors() [3]SensorMetadata {
    return .{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 1 }, // 5min
        .{ .sensor_id = 1, .sensor_type = .energy, .frequency_hz = 1.0 / 900.0, .element_id = 2 }, // 15min
        .{ .sensor_id = 2, .sensor_type = .vibration, .frequency_hz = 1.0 / 3600.0, .element_id = 3 }, // 1hr
    };
}

const Collector = struct {
    readings: std.ArrayList(SensorReading) = .empty,
    fn sink(self: *Collector, r: SensorReading) !void {
        try self.readings.append(testing.allocator, r);
    }
};

test "periodMs: converts canonical Hz to milliseconds, degrades gracefully at/below zero" {
    try testing.expectEqual(@as(i64, 300_000), periodMs(1.0 / 300.0));
    try testing.expectEqual(@as(i64, 900_000), periodMs(1.0 / 900.0));
    try testing.expectEqual(@as(i64, 24 * 60 * 60 * 1000), periodMs(0));
    try testing.expectEqual(@as(i64, 24 * 60 * 60 * 1000), periodMs(-1.0));
}

test "hourOfDay: wraps into [0,24), including for pre-epoch negative timestamps" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), hourOfDay(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 12.0), hourOfDay(12 * 60 * 60 * 1000), 1e-6);
    // One hour before epoch must land at hour 23, not -1 or crash/UB.
    try testing.expectApproxEqAbs(@as(f32, 23.0), hourOfDay(-60 * 60 * 1000), 1e-6);
}

test "Stream: streamUntil is byte-identical across two runs with the same seed" {
    const sensors = testSensors();
    var stream1 = try Stream.init(testing.allocator, &sensors, 42, 0, false);
    defer stream1.deinit();
    var stream2 = try Stream.init(testing.allocator, &sensors, 42, 0, false);
    defer stream2.deinit();

    var c1 = Collector{};
    defer c1.readings.deinit(testing.allocator);
    var c2 = Collector{};
    defer c2.readings.deinit(testing.allocator);

    const until: i64 = 3 * 24 * 60 * 60 * 1000; // 3 days
    try stream1.streamUntil(until, Collector.sink, &c1);
    try stream2.streamUntil(until, Collector.sink, &c2);

    try testing.expectEqual(c1.readings.items.len, c2.readings.items.len);
    for (c1.readings.items, c2.readings.items) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.value, b.value);
    }
}

test "Stream: streamUntil output is sorted by (timestamp asc, sensor_id asc)" {
    const sensors = testSensors();
    var stream = try Stream.init(testing.allocator, &sensors, 7, 0, false);
    defer stream.deinit();

    var c = Collector{};
    defer c.readings.deinit(testing.allocator);
    try stream.streamUntil(2 * 24 * 60 * 60 * 1000, Collector.sink, &c);

    try testing.expect(c.readings.items.len > 0);
    for (c.readings.items[1..], 0..) |r, i| {
        const prev = c.readings.items[i];
        try testing.expect(r.timestamp > prev.timestamp or
            (r.timestamp == prev.timestamp and r.sensor_id > prev.sensor_id));
    }
}

test "Stream.capHorizons: a capped type stops exactly at its horizon; uncapped types continue; pre-horizon output is byte-identical to an uncapped run" {
    const sensors = testSensors();
    const one_day: i64 = 24 * 60 * 60 * 1000;
    const until: i64 = 5 * one_day;

    var uncapped = try Stream.init(testing.allocator, &sensors, 42, 0, false);
    defer uncapped.deinit();
    var capped = try Stream.init(testing.allocator, &sensors, 42, 0, false);
    defer capped.deinit();

    // Cap temperature at 2 days; energy and vibration stay unbounded (0).
    var horizons: [std.enums.values(SensorType).len]u32 = @splat(0);
    horizons[@intFromEnum(SensorType.temperature)] = 2;
    capped.capHorizons(&horizons);

    var cu = Collector{};
    defer cu.readings.deinit(testing.allocator);
    var cc = Collector{};
    defer cc.readings.deinit(testing.allocator);
    try uncapped.streamUntil(until, Collector.sink, &cu);
    try capped.streamUntil(until, Collector.sink, &cc);

    // 1. The capped run is exactly the uncapped run minus temperature
    //    readings at/after the horizon — same order, same values (each
    //    sensor's PRNG is private, so capping one type can't perturb
    //    another's sequence).
    var expected: std.ArrayList(SensorReading) = .empty;
    defer expected.deinit(testing.allocator);
    for (cu.readings.items) |r| {
        if (r.sensor_type == .temperature and r.timestamp >= 2 * one_day) continue;
        try expected.append(testing.allocator, r);
    }
    try testing.expectEqual(expected.items.len, cc.readings.items.len);
    for (expected.items, cc.readings.items) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.value, b.value);
    }

    // 2. Both boundary directions are real: temperature produced readings
    //    right up to (but never at/after) the horizon, and an uncapped
    //    type kept producing well after it.
    var last_temp: i64 = -1;
    var last_energy: i64 = -1;
    for (cc.readings.items) |r| {
        switch (r.sensor_type) {
            .temperature => last_temp = @max(last_temp, r.timestamp),
            .energy => last_energy = @max(last_energy, r.timestamp),
            else => {},
        }
    }
    try testing.expectEqual(2 * one_day - 300_000, last_temp); // final 5-min tick before day 2
    try testing.expect(last_energy >= 4 * one_day);
}

test "Stream.capHorizons: nextChunk honors the horizon across chunk boundaries" {
    const sensors = testSensors();
    const one_day: i64 = 24 * 60 * 60 * 1000;

    var stream = try Stream.init(testing.allocator, &sensors, 7, 0, false);
    defer stream.deinit();
    var horizons: [std.enums.values(SensorType).len]u32 = @splat(0);
    horizons[@intFromEnum(SensorType.temperature)] = 1;
    stream.capHorizons(&horizons);

    // Day 1: temperature present. Days 2-3: temperature absent, others present.
    var day: i64 = 1;
    while (day <= 3) : (day += 1) {
        const chunk = try stream.nextChunk(testing.allocator, day * one_day);
        defer testing.allocator.free(chunk);
        var temp_count: usize = 0;
        var other_count: usize = 0;
        for (chunk) |r| {
            if (r.sensor_type == .temperature) temp_count += 1 else other_count += 1;
        }
        if (day == 1) {
            try testing.expect(temp_count > 0);
        } else {
            try testing.expectEqual(@as(usize, 0), temp_count);
        }
        try testing.expect(other_count > 0);
    }
}

test "Stream: one streamUntil call matches three chunked nextChunk calls (chunk-boundary invariance)" {
    const sensors = testSensors();
    var stream_a = try Stream.init(testing.allocator, &sensors, 99, 0, false);
    defer stream_a.deinit();
    var stream_b = try Stream.init(testing.allocator, &sensors, 99, 0, false);
    defer stream_b.deinit();

    const one_day: i64 = 24 * 60 * 60 * 1000;

    var c = Collector{};
    defer c.readings.deinit(testing.allocator);
    try stream_a.streamUntil(3 * one_day, Collector.sink, &c);

    var chunked: std.ArrayList(SensorReading) = .empty;
    defer chunked.deinit(testing.allocator);
    var day: i64 = 1;
    while (day <= 3) : (day += 1) {
        const chunk = try stream_b.nextChunk(testing.allocator, day * one_day);
        defer testing.allocator.free(chunk);
        try chunked.appendSlice(testing.allocator, chunk);
    }

    try testing.expectEqual(c.readings.items.len, chunked.items.len);
    for (c.readings.items, chunked.items) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.value, b.value);
    }
}

test "binary_event: a reading is stored only when the value actually transitions" {
    var state: f32 = 0.0;
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    const profile = profileFor(.occupancy);

    var last_emitted: ?f32 = null;
    var transitions: usize = 0;
    var t: i64 = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const value = sampleBinaryEvent(profile, rand, t, &state);
        if (last_emitted == null or value != last_emitted.?) {
            transitions += 1;
            last_emitted = value;
        }
        t += periodMs(profile.frequency_hz);
    }

    // Real dwell time: far fewer stored transitions than samples evaluated,
    // but at least the mandatory first-tick emit.
    try testing.expect(transitions >= 1);
    try testing.expect(transitions < 500);
}

test "bursty_impulsive: every stored event sample is a real burst, never baseline noise" {
    var prng = std.Random.DefaultPrng.init(2);
    const rand = prng.random();
    const profile = profileFor(.vibration);

    var events: usize = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const sample = sampleBurstyImpulsive(profile, rand);
        if (sample.is_event) {
            events += 1;
            // A burst is base_value + at least 3x daily_amplitude; baseline
            // Gaussian noise (noise_stddev) cannot reach that for this
            // profile's parameters, so this distinguishes real events from
            // noise that happened to clear some derived threshold.
            try testing.expect(sample.value > profile.base_value + profile.daily_amplitude * 2.0);
        }
    }
    // Sparse (~2% burst chance per sample), never near-continuous.
    try testing.expect(events > 0);
    try testing.expect(events < 500);
}

fn stateWithFailures(profile: SensorProfile, seed: u64) SensorState {
    return .{
        .sensor = .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = profile.frequency_hz, .element_id = 1 },
        .profile = profile,
        .period_ms = periodMs(profile.frequency_hz),
        .next_t = 0,
        .step_level = profile.base_value,
        .last_real_value = profile.base_value,
        .prng = std.Random.DefaultPrng.init(seed),
    };
}

test "failure modes: dropout produces a gap of exactly dropout_duration_ticks, then resumes" {
    var profile = profileFor(.temperature);
    profile.failures = .{ .dropout_rate = 1.0, .dropout_duration_ticks = 5 };
    var state = stateWithFailures(profile, 3);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(tickOnce(&state, state.next_t, true) == null);
        state.next_t += state.period_ms;
    }
    // dropout_remaining has reached 0 — turn off the retrigger chance (which
    // was 1.0, so it would otherwise re-enter dropout on every single tick
    // forever) to isolate "the gap actually ends" from "did a brand new
    // random dropout coincidentally start right after."
    state.profile.failures.dropout_rate = 0;
    try testing.expect(tickOnce(&state, state.next_t, true) != null);
}

test "failure modes: stuck freezes the exact value for stuck_duration_ticks" {
    var profile = profileFor(.temperature);
    profile.failures = .{ .stuck_rate = 1.0, .stuck_duration_ticks = 4 };
    var state = stateWithFailures(profile, 4);

    // stuck_rate = 1.0 guarantees the FIRST tick starts a stuck condition
    // (freezing from the next reading onward, per tickOnce's contract).
    const first = tickOnce(&state, state.next_t, true) orelse return error.TestUnexpectedResult;
    state.next_t += state.period_ms;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const v = tickOnce(&state, state.next_t, true) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(first, v);
        state.next_t += state.period_ms;
    }
}

test "failure modes: drift accumulates monotonically, moving later readings further from baseline" {
    var profile = profileFor(.temperature);
    profile.failures = .{ .drift_rate_ppm = 100_000.0 }; // exaggerated for a short test window
    profile.noise_stddev = 0.0; // isolate drift from Gaussian jitter
    var state = stateWithFailures(profile, 5);

    const first = tickOnce(&state, state.next_t, true) orelse return error.TestUnexpectedResult;
    state.next_t += state.period_ms;

    var last: f32 = first;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        last = tickOnce(&state, state.next_t, true) orelse return error.TestUnexpectedResult;
        state.next_t += state.period_ms;
    }

    try testing.expect(@abs(last - profile.base_value) > @abs(first - profile.base_value));
}

// ---------------------------------------------------------------------------
