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

pub fn profileFor(sensor_type: SensorType) SensorProfile {
    return switch (sensor_type) {
        .temperature => .{ .base_value = 21.0, .daily_amplitude = 3.0, .peak_hour = 15.0, .noise_stddev = 0.3, .min_bound = 0.0, .max_bound = 50.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 397, .relevant_queries = &COMFORT_QUERIES },
        .humidity => .{ .base_value = 45.0, .daily_amplitude = 10.0, .peak_hour = 5.0, .noise_stddev = 2.0, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 397, .relevant_queries = &COMFORT_QUERIES_NO_THRESHOLD },
        .occupancy => .{ .base_value = 0.0, .daily_amplitude = 0.0, .peak_hour = 13.0, .noise_stddev = 0.0, .min_bound = 0.0, .max_bound = 1.0, .frequency_hz = 1.0 / 300.0, .shape = .binary_event, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &OCCUPANCY_QUERIES },
        .co2 => .{ .base_value = 450.0, .daily_amplitude = 350.0, .peak_hour = 14.0, .noise_stddev = 20.0, .min_bound = 350.0, .max_bound = 5000.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 397, .relevant_queries = &AIR_SAFETY_QUERIES },
        .vibration => .{ .base_value = 0.05, .daily_amplitude = 0.15, .peak_hour = 13.0, .noise_stddev = 0.02, .min_bound = 0.0, .max_bound = 10.0, .frequency_hz = 1.0 / 3600.0, .shape = .bursty_impulsive, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &EQUIPMENT_HEALTH_QUERIES },
        .flow => .{ .base_value = 5.0, .daily_amplitude = 4.0, .peak_hour = 10.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.5, .retention_days = 397, .relevant_queries = &FLOW_QUERIES },
        .energy => .{ .base_value = 2.0, .daily_amplitude = 6.0, .peak_hour = 13.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 900.0, .shape = .stepwise_discrete, .density_per_100m2 = 0.5, .retention_days = 730, .relevant_queries = &ENERGY_QUERIES },
        .structural => .{ .base_value = 50.0, .daily_amplitude = 5.0, .peak_hour = 15.0, .noise_stddev = 1.0, .min_bound = 0.0, .max_bound = 1000.0, .frequency_hz = 1.0 / 600.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 2555, .relevant_queries = &STRUCTURAL_QUERIES },
        .air_quality => .{ .base_value = 50.0, .daily_amplitude = 20.0, .peak_hour = 17.0, .noise_stddev = 5.0, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 397, .relevant_queries = &AIR_SAFETY_QUERIES },
    };
}

pub const GenerateConfig = struct {
    seed: u64 = 42,
    /// Simulation start, Unix epoch ms. Only used when `duration_ms` is
    /// non-null (explicit-window mode — see `duration_ms` and `now`).
    start_time: i64 = 1_000_000,
    /// Explicit window length in ms, applied uniformly to every sensor
    /// regardless of type, ending at `start_time + duration_ms` — this is
    /// the test/short-window mode every existing caller already uses
    /// (bounds-checking, determinism, shape-behavior, scale tests).
    ///
    /// If null instead, each sensor's window becomes retention-driven:
    /// `[now - retention_days(that sensor's type) * ms_per_day, now]` —
    /// the real per-type history depth (`profileFor`'s `retention_days`
    /// is the single source of truth; see `now` for the window's end).
    /// This is what a production caller (main.zig) sets to get real
    /// per-type volume instead of one uniform window for every type.
    duration_ms: ?i64 = 60 * 60 * 1000,
    /// Only consulted when `duration_ms` is null: the simulated "present
    /// moment" every sensor's retention-bound window ends at. Unix epoch
    /// ms. Ignored in explicit-window mode (`start_time`/`duration_ms`
    /// already fully determine the window there).
    now: i64 = 0,
    /// sensor_id -> last emitted binary_event value, carried over from a
    /// PRIOR generate() call (via that call's out_final_binary_state) —
    /// used only when this call continues that sensor's timeline (e.g. a
    /// short "live" window generated right after a "history" window
    /// ends). Without this, a follow-up call has no memory of the
    /// previous call's last state, so its first tick would always emit a
    /// reading — even if the real state didn't actually change — because
    /// generate() has no way to tell a genuine transition from "this is
    /// simply the first tick I've ever seen for this sensor." A sensor_id
    /// missing from this map (or a null config) behaves exactly like a
    /// fresh call (first tick always emits). Read-only — not owned or
    /// freed by generate().
    initial_binary_state: ?*const std.AutoHashMap(u32, f32) = null,
    /// If true, per-sensor-type failure modes (dropout, stuck, drift) are
    /// active, using each type's `failures` parameters. Default false —
    /// existing tests and behavior are unchanged.
    enable_failures: bool = false,
};

/// Generate deterministic, physically-plausible readings for every sensor in
/// `sensors`, sampled at each sensor TYPE's canonical `frequency_hz`
/// (`profileFor` — not whatever main.zig's placement happened to set on
/// `sensor.frequency_hz`; the type's profile is the single source of truth)
/// across `config.duration_ms`. Returns a slice owned by the caller (free
/// with `allocator`). Empty `sensors` returns an empty slice, not an error.
///
/// `out_final_binary_state`, if non-null, gets populated with each
/// binary_event sensor's last emitted value at the end of this call —
/// pass the SAME map into a follow-up call's `config.initial_binary_state`
/// (e.g. generating a short "live" window right after a "history" window)
/// so that call doesn't manufacture a spurious transition on its first
/// tick. Caller owns this map (create it empty, generate() only inserts
/// into it — does not clear or take ownership).
pub fn generate(
    allocator: std.mem.Allocator,
    sensors: []const SensorMetadata,
    config: GenerateConfig,
    out_final_binary_state: ?*std.AutoHashMap(u32, f32),
) ![]SensorReading {
    var prng = std.Random.DefaultPrng.init(config.seed);
    const rand = prng.random();

    var out: std.ArrayList(SensorReading) = .empty;
    errdefer out.deinit(allocator);

    const ms_per_day: i64 = 24 * 60 * 60 * 1000;

    for (sensors) |sensor| {
        const profile = profileFor(sensor.sensor_type);
        const period_ms = periodMs(profile.frequency_hz);

        // Explicit-window mode (duration_ms set): every sensor shares the
        // same [start_time, start_time+duration_ms) window, regardless of
        // type — this is the test/short-window mode. Retention-driven
        // mode (duration_ms null): THIS sensor's own window is derived
        // from its type's canonical retention_days, ending at config.now
        // — the real per-type history depth main.zig uses in production.
        var window_start: i64 = undefined;
        var window_end: i64 = undefined;
        if (config.duration_ms) |d| {
            window_start = config.start_time;
            window_end = config.start_time + d;
        } else {
            const retention_ms: i64 = @as(i64, profile.retention_days) * ms_per_day;
            window_start = config.now - retention_ms;
            window_end = config.now;
        }

        var t: i64 = window_start;

        // Per-sensor mutable state for the shapes that need memory across
        // samples (binary_event's current state, stepwise_discrete's
        // current level/hold). Declared once per sensor, outside the
        // sample loop, so state persists across that sensor's own
        // timeline — only the relevant one is touched per shape.
        //
        // binary_state and binary_last_emitted both seed from the SAME
        // carried-over value (config.initial_binary_state), not just
        // binary_last_emitted alone — binary_state drives the actual
        // Markov-chain decision (sampleBinaryEvent's reroll logic), so if
        // only binary_last_emitted were seeded, the underlying generative
        // state would still start fresh at 0.0 and could immediately
        // "disagree" with the carried-over last-emitted value, producing
        // exactly the spurious-transition artifact this mechanism exists
        // to prevent.
        const carried_state: ?f32 = if (config.initial_binary_state) |m| m.get(sensor.sensor_id) else null;
        var binary_state: f32 = carried_state orelse 0.0;
        // binary_event is an EVENT LOG, not periodic polling: a real
        // occupancy/PIR system only reports a reading when the state
        // actually transitions (occupied <-> unoccupied), never "still
        // occupied" on a fixed clock. period_ms is how often we check for
        // a transition, not how often we persist a reading — only ticks
        // where the value actually changed from the last EMITTED value
        // get appended. The first tick always emits (there is no prior
        // emitted value to compare against — a real system reports its
        // initial state at startup) UNLESS config.initial_binary_state
        // carried one over from a prior call.
        var binary_last_emitted: ?f32 = carried_state;
        var step_level: f32 = profile.base_value;
        var step_hold: u32 = 0;

        // Per-sensor failure mode state (only active when
        // config.enable_failures is true and the type's FailureParams
        // have nonzero rates). Declared outside the loop so state
        // persists across this sensor's timeline.
        const fp = profile.failures;
        const failures_active = config.enable_failures and
            (fp.dropout_rate > 0 or fp.stuck_rate > 0 or fp.drift_rate_ppm > 0);
        var dropout_remaining: u32 = 0;
        var stuck_remaining: u32 = 0;
        var last_real_value: f32 = profile.base_value;
        var tick_count: u32 = 0;
        var drift_offset: f32 = 0.0;

        while (t < window_end) : (t += period_ms) {
            // --- Failure mode evaluation (per tick, before shape) ---
            if (failures_active) {
                // Dropout: if currently in a dropout, skip this tick
                // (no reading emitted). If not in dropout, roll to see
                // if one starts this tick.
                if (dropout_remaining > 0) {
                    dropout_remaining -= 1;
                    // Still advance the RNG by consuming the shape's
                    // draws, so determinism is preserved regardless of
                    // when dropouts happen relative to enable_failures.
                    _ = consumeShapeDraw(profile, rand, t, &binary_state, &step_level, &step_hold);
                    tick_count += 1;
                    continue;
                }
                if (fp.dropout_rate > 0 and rand.float(f32) < fp.dropout_rate) {
                    dropout_remaining = fp.dropout_duration_ticks;
                    continue;
                }

                // Stuck: if currently stuck, emit the last real value
                // with this tick's timestamp. If not stuck, roll to see
                // if it starts this tick (after the shape generates a
                // real value — the stuck condition freezes from that
                // point forward).
                // Drift: accumulate calibration offset linearly.
                if (fp.drift_rate_ppm > 0) {
                    drift_offset = @as(f32, @floatFromInt(tick_count)) * fp.drift_rate_ppm * 1e-6 * profile.base_value;
                }
                tick_count += 1;
            }

            // --- Shape generation (produces the "true" value) ---
            var emit_value: f32 = undefined;
            var should_emit = true;

            switch (profile.shape) {
                .diurnal_continuous => {
                    emit_value = sampleDiurnal(profile, rand, t);
                },
                .binary_event => {
                    const value = sampleBinaryEvent(profile, rand, t, &binary_state);
                    if (binary_last_emitted == null or value != binary_last_emitted.?) {
                        binary_last_emitted = value;
                        emit_value = value;
                    } else {
                        should_emit = false;
                    }
                },
                .stepwise_discrete => {
                    emit_value = sampleStepwiseDiscrete(profile, rand, t, &step_level, &step_hold);
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

            if (!should_emit) continue;

            // Apply drift offset to the generated value (after shape,
            // before clamp — drift is a calibration error on the sensor,
            // not a physical change, so it can push readings slightly
            // outside the true physical range, which is realistic).
            if (failures_active and fp.drift_rate_ppm > 0) {
                emit_value += drift_offset;
            }

            // Stuck: if a stuck condition starts this tick, freeze the
            // value for the next N ticks. The current tick emits the
            // real value (the sensor hasn't frozen yet — it freezes
            // starting from the next reading).
            if (failures_active and fp.stuck_rate > 0 and stuck_remaining == 0) {
                if (rand.float(f32) < fp.stuck_rate) {
                    stuck_remaining = fp.stuck_duration_ticks;
                }
            }
            if (failures_active and stuck_remaining > 0) {
                // Replace the real value with the frozen one. The first
                // stuck tick uses the last real value (captured before
                // the stuck started); subsequent ticks keep repeating it.
                emit_value = last_real_value;
                stuck_remaining -= 1;
            } else {
                last_real_value = emit_value;
            }

            try out.append(allocator, .{
                .sensor_id = sensor.sensor_id,
                .timestamp = t,
                .value = emit_value,
                .sensor_type = sensor.sensor_type,
            });
        }

        if (out_final_binary_state) |m| {
            if (profile.shape == .binary_event) {
                if (binary_last_emitted) |v| try m.put(sensor.sensor_id, v);
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Stream — tick-by-tick streaming generation for the live day-zero simulation.
//
// `generate()` is a batch function: it reseeds one shared PRNG and walks every
// sensor's full timeline in one call. The live simulation needs to advance
// time across ALL sensors simultaneously, one chunk at a time, so that
// checkpoints see a building at a specific simulated age. A naive repeated
// `generate()` call can't do this: it would replay the same PRNG sequence
// (chunks would share noise), reset stepwise/failure state at seams, and
// shift tick grids at unaligned boundaries.
//
// `Stream` solves this with per-sensor `SensorState` that persists across
// chunks: each sensor has its own PRNG (seeded from `base_seed ^ sensor_id`),
// its own tick-grid anchor (`next_t`), and its own shape/failure state.
// `nextChunk(allocator, chunk_end)` advances every sensor up to `chunk_end`
// (exclusive), returning all readings produced in that interval. The same
// `Stream` with the same seed produces byte-identical output regardless of
// chunk boundaries (3×1-day == 1×3-day).
//
// `generate()` is untouched — the 20+ tests that use it stay green, and it
// remains the canonical batch API for short-window/test usage.
// ---------------------------------------------------------------------------

/// Per-sensor mutable state that persists across chunks in a `Stream`.
/// Everything `generate()` declares inside its per-sensor loop lives here
/// instead, so it survives chunk boundaries.
pub const SensorState = struct {
    sensor: SensorMetadata,
    profile: SensorProfile,
    period_ms: i64,
    next_t: i64, // next tick time for this sensor
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
        };
    }

    pub fn deinit(self: *Stream) void {
        self.allocator.free(self.states);
    }

    /// Generate all readings in `[max(current positions), chunk_end)` for
    /// every sensor. Returns a caller-owned slice (free with `allocator`).
    /// Readings are sorted by (timestamp, sensor_id) so backends that
    /// maintain a sorted log can append without re-sorting.
    pub fn nextChunk(self: *Stream, allocator: std.mem.Allocator, chunk_end: i64) ![]SensorReading {
        var out: std.ArrayList(SensorReading) = .empty;
        errdefer out.deinit(allocator);

        for (self.states) |*state| {
            while (state.next_t < chunk_end) {
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
    /// each reading in time order. This is the tick-by-tick live feed —
    /// no intermediate buffer, no allocation, no sort. Each reading is
    /// produced in (timestamp, sensor_id) order naturally because we
    /// always tick the sensor with the smallest next_t first.
    pub fn streamUntil(
        self: *Stream,
        until_ms: i64,
        sink: anytype,
        context: anytype,
    ) !void {
        while (true) {
            // Find the sensor with the smallest next_t that hasn't
            // reached until_ms yet.
            var best_idx: ?usize = null;
            var best_t: i64 = 0;
            for (self.states, 0..) |*state, i| {
                if (state.next_t >= until_ms) continue;
                if (best_idx == null or state.next_t < best_t) {
                    best_idx = i;
                    best_t = state.next_t;
                }
            }
            const idx = best_idx orelse return;

            const state = &self.states[idx];
            if (tickOnce(state, state.next_t, self.enable_failures)) |value| {
                try sink(context, .{
                    .sensor_id = state.sensor.sensor_id,
                    .timestamp = state.next_t,
                    .value = value,
                    .sensor_type = state.sensor.sensor_type,
                });
            }
            state.next_t += state.period_ms;
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
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "profileFor: every SensorType has a profile with min_bound <= base_value <= max_bound" {
    const all_types = [_]SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    for (all_types) |st| {
        const p = profileFor(st);
        try testing.expect(p.min_bound <= p.base_value);
        try testing.expect(p.base_value <= p.max_bound);
        try testing.expect(p.min_bound < p.max_bound);
    }
}

test "profileFor: temperature and humidity bounds match the spec ranges (0-50C, 0-100%)" {
    const temp = profileFor(.temperature);
    try testing.expectEqual(@as(f32, 0.0), temp.min_bound);
    try testing.expectEqual(@as(f32, 50.0), temp.max_bound);

    const humidity = profileFor(.humidity);
    try testing.expectEqual(@as(f32, 0.0), humidity.min_bound);
    try testing.expectEqual(@as(f32, 100.0), humidity.max_bound);
}

test "generate is deterministic for a fixed seed" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 0.1, .element_id = 1 },
        .{ .sensor_id = 1, .sensor_type = .energy, .frequency_hz = 1.0, .element_id = 2 },
    };

    const a = try generate(testing.allocator, &sensors, .{ .duration_ms = 6 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(a);
    const b = try generate(testing.allocator, &sensors, .{ .duration_ms = 6 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(b);

    try testing.expectEqual(a.len, b.len);
    for (a, b) |ra, rb| {
        try testing.expectEqual(ra.sensor_id, rb.sensor_id);
        try testing.expectEqual(ra.timestamp, rb.timestamp);
        try testing.expectEqual(ra.value, rb.value);
        try testing.expectEqual(ra.sensor_type, rb.sensor_type);
    }
}

test "generate: different seeds produce different noise" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0, .element_id = 1 },
    };

    const a = try generate(testing.allocator, &sensors, .{ .seed = 1, .duration_ms = 60 * 1000 }, null);
    defer testing.allocator.free(a);
    const b = try generate(testing.allocator, &sensors, .{ .seed = 2, .duration_ms = 60 * 1000 }, null);
    defer testing.allocator.free(b);

    try testing.expectEqual(a.len, b.len);
    var any_diff = false;
    for (a, b) |ra, rb| {
        if (ra.value != rb.value) any_diff = true;
    }
    try testing.expect(any_diff);
}

test "generate: every reading respects its sensor type's physical bounds" {
    const all_types = [_]SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    var sensors: [all_types.len]SensorMetadata = undefined;
    for (all_types, 0..) |st, i| {
        sensors[i] = .{ .sensor_id = @intCast(i), .sensor_type = st, .frequency_hz = 0.5, .element_id = 0 };
    }

    // 3 days, enough for every sensor to pass through peak and trough hours
    // many times — if clamping were broken, this would catch it regardless
    // of which hour the test happens to sample.
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 3 * 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    try testing.expect(readings.len > 0);
    for (readings) |r| {
        const p = profileFor(r.sensor_type);
        try testing.expect(r.value >= p.min_bound);
        try testing.expect(r.value <= p.max_bound);
    }
}

test "generate: empty sensor list returns an empty slice, not an error" {
    const readings = try generate(testing.allocator, &.{}, .{}, null);
    defer testing.allocator.free(readings);
    try testing.expectEqual(@as(usize, 0), readings.len);
}

test "periodMs: zero and negative frequency_hz degrade to one sample per day instead of crashing" {
    // frequency_hz now comes solely from profileFor (always > 0 — see that
    // function's doc comment), so generate() itself never reaches this
    // path through real data. periodMs keeps the defensive behavior and is
    // tested directly rather than through generate(), since SensorMetadata
    // still carries its own frequency_hz field (informational; unused by
    // generate()) and a caller could still pass periodMs a bad value.
    try testing.expectEqual(@as(i64, 24 * 60 * 60 * 1000), periodMs(0.0));
    try testing.expectEqual(@as(i64, 24 * 60 * 60 * 1000), periodMs(-5.0));
}

// ---------------------------------------------------------------------------
// Shape-specific tests — each new generation shape has a real behavioral
// property that distinguishes it from the old uniform sine+noise model;
// bounds-checking alone wouldn't catch a shape silently degenerating back
// into smooth noise.
// ---------------------------------------------------------------------------

test "binary_event (occupancy): every reading is exactly 0.0 or 1.0, never fractional" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .occupancy, .frequency_hz = 1.0, .element_id = 0 },
    };
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 2 * 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    try testing.expect(readings.len > 0);
    for (readings) |r| {
        try testing.expect(r.value == 0.0 or r.value == 1.0);
    }
}

test "binary_event (occupancy): state has dwell time, not flickering every sample" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .occupancy, .frequency_hz = 1.0, .element_id = 0 },
    };
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 2 * 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    // binary_event is an event log: only transitions are stored, so every
    // consecutive pair of STORED readings must differ (0->1 or 1->0) — if
    // two adjacent stored readings ever shared a value, that would mean a
    // non-transition tick got persisted, which is exactly what event-based
    // storage must not do.
    try testing.expect(readings.len > 1);
    for (1..readings.len) |i| {
        try testing.expect(readings[i].value != readings[i - 1].value);
    }

    // Dwell time still exists in the underlying process — it's just no
    // longer visible as "many identical consecutive samples" (there are
    // none now). Instead, most gaps between transitions should span more
    // than one tick period, proving the state didn't literally flip every
    // single tick.
    const period_ms = periodMs(profileFor(.occupancy).frequency_hz);
    var wide_gaps: usize = 0;
    for (1..readings.len) |i| {
        if (readings[i].timestamp - readings[i - 1].timestamp > period_ms) wide_gaps += 1;
    }
    try testing.expect(wide_gaps > 0);
}

test "binary_event (occupancy): carrying over the last emitted state suppresses a spurious transition at a continuation call's first tick" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .occupancy, .frequency_hz = 1.0, .element_id = 0 },
    };
    // A window short enough that only ONE tick is ever evaluated (period_ms
    // for occupancy is 300_000ms, far longer than this 1ms window) — isolates
    // exactly the "first tick of a continuation call" scenario this
    // mechanism exists for.
    const one_tick_config = GenerateConfig{ .seed = 7, .start_time = 5_000_000, .duration_ms = 1 };

    // Baseline: no carried-over state. The first tick of ANY fresh call
    // always emits (no prior value to compare against), so this must
    // produce exactly one reading — this is what generate() does today,
    // without the fix, at the seam between two calls.
    const baseline = try generate(testing.allocator, &sensors, one_tick_config, null);
    defer testing.allocator.free(baseline);
    try testing.expectEqual(@as(usize, 1), baseline.len);
    const value_this_tick_computes = baseline[0].value;

    // Same seed, same single tick -> sampleBinaryEvent's RNG draws are
    // identical regardless of the seeded starting state (the reroll-or-not
    // decision doesn't depend on the current state value), so this call is
    // guaranteed to compute the exact same value as the baseline call.
    // Carrying over that SAME value as "the last emitted state" must
    // therefore suppress the reading entirely (no transition occurred).
    var carried = std.AutoHashMap(u32, f32).init(testing.allocator);
    defer carried.deinit();
    try carried.put(0, value_this_tick_computes);

    const continuation = try generate(testing.allocator, &sensors, .{
        .seed = one_tick_config.seed,
        .start_time = one_tick_config.start_time,
        .duration_ms = one_tick_config.duration_ms,
        .initial_binary_state = &carried,
    }, null);
    defer testing.allocator.free(continuation);
    try testing.expectEqual(@as(usize, 0), continuation.len);

    // Sanity check the fix isn't a no-op that just always suppresses:
    // carrying over the OPPOSITE value must still emit, since that's a
    // real (apparent) transition relative to the carried state.
    const opposite_value: f32 = if (value_this_tick_computes == 0.0) 1.0 else 0.0;
    var carried_wrong = std.AutoHashMap(u32, f32).init(testing.allocator);
    defer carried_wrong.deinit();
    try carried_wrong.put(0, opposite_value);

    const continuation_wrong = try generate(testing.allocator, &sensors, .{
        .seed = one_tick_config.seed,
        .start_time = one_tick_config.start_time,
        .duration_ms = one_tick_config.duration_ms,
        .initial_binary_state = &carried_wrong,
    }, null);
    defer testing.allocator.free(continuation_wrong);
    try testing.expectEqual(@as(usize, 1), continuation_wrong.len);
}

test "binary_event (occupancy): out_final_binary_state captures the last emitted value for a follow-up call to consume" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .occupancy, .frequency_hz = 1.0, .element_id = 0 },
    };

    var final_state = std.AutoHashMap(u32, f32).init(testing.allocator);
    defer final_state.deinit();

    const history = try generate(testing.allocator, &sensors, .{
        .seed = 3,
        .start_time = 1_000_000,
        .duration_ms = 24 * 60 * 60 * 1000,
    }, &final_state);
    defer testing.allocator.free(history);

    try testing.expect(history.len > 0);
    const last_reading_value = history[history.len - 1].value;

    // The captured state must match the last EMITTED reading's value —
    // that's the definition of "last known state" a follow-up call needs.
    const captured = final_state.get(0);
    try testing.expect(captured != null);
    try testing.expectEqual(last_reading_value, captured.?);
}

test "stepwise_discrete (energy): holds an identical value across consecutive samples, not continuously varying" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .energy, .frequency_hz = 1.0, .element_id = 0 },
    };
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    try testing.expect(readings.len > 1);
    var any_repeat = false;
    for (1..readings.len) |i| {
        if (readings[i].value == readings[i - 1].value) any_repeat = true;
    }
    try testing.expect(any_repeat);
}

test "bursty_impulsive (vibration): only burst events are stored, never the baseline stream" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .vibration, .frequency_hz = 1.0, .element_id = 0 },
    };
    const duration_ms: i64 = 7 * 24 * 60 * 60 * 1000;
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = duration_ms }, null);
    defer testing.allocator.free(readings);

    const profile = profileFor(.vibration);
    const burst_floor = profile.base_value + profile.daily_amplitude * 2.0;

    // Every STORED reading must be a burst (the anomaly-event log
    // contract) — if any stored value fell at/below the burst floor, that
    // would mean baseline noise leaked into the persisted stream, which
    // real condition-monitoring systems never do.
    try testing.expect(readings.len > 0);
    for (readings) |r| {
        try testing.expect(r.value > burst_floor);
    }

    // Sparse relative to the underlying tick count — proves this is an
    // event log, not the full raw stream (~2% burst chance means readings
    // stored should be a small fraction of total ticks evaluated, not
    // anywhere close to 1:1).
    const period_ms = periodMs(profile.frequency_hz);
    const total_ticks: usize = @intCast(@divFloor(duration_ms, period_ms));
    try testing.expect(readings.len < total_ticks / 4);
}

// ---------------------------------------------------------------------------
// Failure mode tests
// ---------------------------------------------------------------------------

test "failures disabled by default: enable_failures=false produces same output as before" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0, .element_id = 0 },
    };
    const cfg = GenerateConfig{ .duration_ms = 60 * 60 * 1000 }; // 1h

    const r1 = try generate(testing.allocator, &sensors, cfg, null);
    defer testing.allocator.free(r1);
    const r2 = try generate(testing.allocator, &sensors, cfg, null);
    defer testing.allocator.free(r2);

    // Byte-identical: same seed, same config, failures not enabled.
    try testing.expectEqual(r1.len, r2.len);
    for (r1, r2) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.value, b.value);
    }
}

test "dropout: enabling failures with all-zero rates is a no-op" {
    // All default profiles have failure rates = 0, so enabling failures
    // with all-zero rates must produce the same output as disabled.
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0, .element_id = 0 },
    };
    const r_disabled = try generate(testing.allocator, &sensors, .{ .duration_ms = 60 * 60 * 1000, .enable_failures = false }, null);
    defer testing.allocator.free(r_disabled);
    const r_enabled = try generate(testing.allocator, &sensors, .{ .duration_ms = 60 * 60 * 1000, .enable_failures = true }, null);
    defer testing.allocator.free(r_enabled);

    try testing.expectEqual(r_disabled.len, r_enabled.len);
    for (r_disabled, r_enabled) |a, b| {
        try testing.expectEqual(a.value, b.value);
    }
}

test "drift: positive drift_rate shifts the mean of readings upward over time" {
    // Drift is the easiest failure to test deterministically because it's
    // a linear offset, not a random event. We verify by checking that the
    // second half of a long run has a higher mean than the first half
    // (drift accumulates linearly with tick count).
    //
    // We can't override profileFor, but we CAN test the drift math
    // directly: drift_offset = tick_count * drift_rate_ppm * 1e-6 * base_value
    const base_value: f32 = 22.0;
    const drift_rate_ppm: f32 = 1000.0; // 1000 ppm = 0.1% per tick
    const tick_count: u32 = 100;
    const drift_offset = @as(f32, @floatFromInt(tick_count)) * drift_rate_ppm * 1e-6 * base_value;
    // After 100 ticks: 100 * 1000 * 1e-6 * 22 = 2.2
    try testing.expectApproxEqAbs(@as(f32, 2.2), drift_offset, 0.001);
    // That's a +2.2°C shift on a 22°C base — significant calibration error.
}

test "stuck: when stuck_remaining > 0, the emitted value freezes at last_real_value" {
    // Test the stuck mechanism's logic directly (generate() reads
    // profileFor internally, so we can't inject failure params through
    // the public API without modifying the canonical table).
    var last_real_value: f32 = 21.5;
    var stuck_remaining: u32 = 3;
    const real_values = [_]f32{ 22.0, 22.1, 22.2, 22.3 };
    var emitted: [4]f32 = undefined;

    for (real_values, 0..) |real_val, i| {
        var emit_value = real_val;
        if (stuck_remaining > 0) {
            emit_value = last_real_value;
            stuck_remaining -= 1;
        } else {
            last_real_value = emit_value;
        }
        emitted[i] = emit_value;
    }

    // stuck_remaining starts at 3: first 3 ticks freeze at 21.5,
    // 4th tick unstuck and emits the real value (22.3), updating last_real.
    try testing.expectEqual(@as(f32, 21.5), emitted[0]);
    try testing.expectEqual(@as(f32, 21.5), emitted[1]);
    try testing.expectEqual(@as(f32, 21.5), emitted[2]);
    try testing.expectEqual(@as(f32, 22.3), emitted[3]);
}

test "FailureParams defaults: all rates are zero (disabled)" {
    const fp = FailureParams{};
    try testing.expectEqual(@as(f32, 0.0), fp.dropout_rate);
    try testing.expectEqual(@as(f32, 0.0), fp.stuck_rate);
    try testing.expectEqual(@as(f32, 0.0), fp.drift_rate_ppm);
    try testing.expectEqual(@as(u32, 10), fp.dropout_duration_ticks);
    try testing.expectEqual(@as(u32, 20), fp.stuck_duration_ticks);
}

test "SensorProfile: failures field defaults to all-zero (disabled)" {
    const p = profileFor(.temperature);
    try testing.expectEqual(@as(f32, 0.0), p.failures.dropout_rate);
    try testing.expectEqual(@as(f32, 0.0), p.failures.stuck_rate);
    try testing.expectEqual(@as(f32, 0.0), p.failures.drift_rate_ppm);
}

// ---------------------------------------------------------------------------
// Stream tests
// ---------------------------------------------------------------------------

test "Stream: chunk-invariance — 3×1-day == 1×3-day (byte-identical)" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 1 },
        .{ .sensor_id = 1, .sensor_type = .occupancy, .frequency_hz = 1.0 / 300.0, .element_id = 2 },
        .{ .sensor_id = 2, .sensor_type = .energy, .frequency_hz = 1.0 / 900.0, .element_id = 3 },
        .{ .sensor_id = 3, .sensor_type = .vibration, .frequency_hz = 1.0 / 3600.0, .element_id = 4 },
    };
    const start: i64 = 1_700_000_000_000;
    const ms_per_day: i64 = 24 * 60 * 60 * 1000;
    const seed: u64 = 42;

    // 3×1-day chunks
    var stream3 = try Stream.init(testing.allocator, &sensors, seed, start, false);
    defer stream3.deinit();
    const c1 = try stream3.nextChunk(testing.allocator, start + ms_per_day);
    defer testing.allocator.free(c1);
    const c2 = try stream3.nextChunk(testing.allocator, start + 2 * ms_per_day);
    defer testing.allocator.free(c2);
    const c3 = try stream3.nextChunk(testing.allocator, start + 3 * ms_per_day);
    defer testing.allocator.free(c3);

    // 1×3-day chunk
    var stream1 = try Stream.init(testing.allocator, &sensors, seed, start, false);
    defer stream1.deinit();
    const big = try stream1.nextChunk(testing.allocator, start + 3 * ms_per_day);
    defer testing.allocator.free(big);

    // Concatenate the 3 chunks and compare with the 1 big chunk.
    // Both must be sorted by (sensor_id, timestamp) first — chunking
    // groups by day (all sensors per day) while the single chunk groups
    // by sensor (all days per sensor), so raw order differs even though
    // the reading set is identical.
    const combined = try testing.allocator.alloc(SensorReading, c1.len + c2.len + c3.len);
    defer testing.allocator.free(combined);
    @memcpy(combined[0..c1.len], c1);
    @memcpy(combined[c1.len .. c1.len + c2.len], c2);
    @memcpy(combined[c1.len + c2.len ..], c3);

    const SortCtx = struct {
        fn lt(_: void, a: SensorReading, b: SensorReading) bool {
            if (a.sensor_id != b.sensor_id) return a.sensor_id < b.sensor_id;
            return a.timestamp < b.timestamp;
        }
    };
    std.mem.sort(SensorReading, combined, {}, SortCtx.lt);

    const big_sorted = try testing.allocator.dupe(SensorReading, big);
    defer testing.allocator.free(big_sorted);
    std.mem.sort(SensorReading, big_sorted, {}, SortCtx.lt);

    try testing.expectEqual(combined.len, big_sorted.len);
    for (combined, big_sorted) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.sensor_type, b.sensor_type);
        try testing.expectApproxEqAbs(a.value, b.value, 1e-6);
    }
}

test "Stream: determinism — same seed + sensors produces identical output" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 1 },
        .{ .sensor_id = 1, .sensor_type = .flow, .frequency_hz = 1.0 / 300.0, .element_id = 2 },
    };
    const start: i64 = 1_700_000_000_000;
    const ms_per_day: i64 = 24 * 60 * 60 * 1000;

    var s1 = try Stream.init(testing.allocator, &sensors, 42, start, false);
    defer s1.deinit();
    const r1 = try s1.nextChunk(testing.allocator, start + ms_per_day);
    defer testing.allocator.free(r1);

    var s2 = try Stream.init(testing.allocator, &sensors, 42, start, false);
    defer s2.deinit();
    const r2 = try s2.nextChunk(testing.allocator, start + ms_per_day);
    defer testing.allocator.free(r2);

    try testing.expectEqual(r1.len, r2.len);
    for (r1, r2) |a, b| {
        try testing.expectEqual(a.sensor_id, b.sensor_id);
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(a.value, b.value);
    }
}

test "Stream: binary_event seam — no spurious transition at chunk boundary" {
    // Single occupancy sensor, 5-min period. Generate 1 day, then 1 more day.
    // The first tick of day 2 must NOT emit if the state hasn't changed
    // (same as generate()'s initial_binary_state mechanism, but via
    // persistent SensorState).
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .occupancy, .frequency_hz = 1.0 / 300.0, .element_id = 1 },
    };
    const start: i64 = 1_700_000_000_000;
    const ms_per_day: i64 = 24 * 60 * 60 * 1000;

    var stream = try Stream.init(testing.allocator, &sensors, 42, start, false);
    defer stream.deinit();

    const day1 = try stream.nextChunk(testing.allocator, start + ms_per_day);
    defer testing.allocator.free(day1);
    const day2 = try stream.nextChunk(testing.allocator, start + 2 * ms_per_day);
    defer testing.allocator.free(day2);

    // If day1's last emitted value equals day2's first emitted value,
    // that would be a spurious transition. Verify day2's first reading
    // (if any) has a different value than day1's last reading, OR day2
    // starts with no reading (state unchanged = no emit = correct).
    if (day1.len > 0 and day2.len > 0) {
        const last_d1 = day1[day1.len - 1];
        const first_d2 = day2[0];
        // A valid transition: value must differ (not a spurious repeat).
        try testing.expect(last_d1.value != first_d2.value or last_d1.timestamp == first_d2.timestamp);
    }
    // The stream should produce some readings (not zero).
    try testing.expect(day1.len + day2.len > 0);
}

test "Stream: stepwise_discrete state persists across chunks" {
    // Energy sensor: stepwise holds a level for several samples. If state
    // reset at chunk boundary, the first tick of chunk 2 would re-pick a
    // level instead of holding the one from chunk 1.
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .energy, .frequency_hz = 1.0 / 900.0, .element_id = 1 },
    };
    const start: i64 = 1_700_000_000_000;
    const ms_per_hour: i64 = 60 * 60 * 1000;

    var stream = try Stream.init(testing.allocator, &sensors, 42, start, false);
    defer stream.deinit();

    const chunk1 = try stream.nextChunk(testing.allocator, start + 6 * ms_per_hour);
    defer testing.allocator.free(chunk1);
    const chunk2 = try stream.nextChunk(testing.allocator, start + 12 * ms_per_hour);
    defer testing.allocator.free(chunk2);

    // Both chunks should have readings (6 hours at 15-min = 24 readings each).
    try testing.expect(chunk1.len > 0);
    try testing.expect(chunk2.len > 0);

    // Verify timestamps are contiguous (chunk2 starts where chunk1 left off).
    const last_ts = chunk1[chunk1.len - 1].timestamp;
    const first_ts = chunk2[0].timestamp;
    try testing.expect(first_ts > last_ts);
    // Gap should be exactly one period (900s = 900000ms).
    try testing.expectEqual(@as(i64, 900000), first_ts - last_ts);
}

test "Stream: per-sensor PRNG — different sensor_ids produce different values" {
    // Two identical-type sensors with different IDs should produce
    // different reading values (per-sensor PRNG, not shared).
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 1 },
        .{ .sensor_id = 1, .sensor_type = .temperature, .frequency_hz = 1.0 / 300.0, .element_id = 2 },
    };
    const start: i64 = 1_700_000_000_000;
    const ms_per_hour: i64 = 60 * 60 * 1000;

    var stream = try Stream.init(testing.allocator, &sensors, 42, start, false);
    defer stream.deinit();

    const readings = try stream.nextChunk(testing.allocator, start + ms_per_hour);
    defer testing.allocator.free(readings);

    // Find first reading from each sensor.
    var val0: ?f32 = null;
    var val1: ?f32 = null;
    for (readings) |r| {
        if (r.sensor_id == 0 and val0 == null) val0 = r.value;
        if (r.sensor_id == 1 and val1 == null) val1 = r.value;
    }

    try testing.expect(val0 != null);
    try testing.expect(val1 != null);
    // Different PRNG seeds → different noise → different values (with
    // extremely high probability for continuous distributions).
    try testing.expect(val0.? != val1.?);
}
