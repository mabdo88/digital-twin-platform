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
};

/// One row per `SensorType` — the only place "realistic" is defined. Adding
/// a new SensorType means adding one row here, never an `if` in `generate`.
///
/// frequency_hz is research-grounded, not guessed:
///   - temperature/humidity/co2/air_quality: BMS trend logging is
///     conventionally minutes-scale; 1/300 (5min) and 1/180 (3min, faster
///     for IAQ where occupancy-driven swings matter more) are within the
///     documented practical range.
///   - flow: HVAC control loops update ~30s internally, but what gets
///     logged/historized is coarser — 1/60 (1min) reflects realistic
///     historian logging, not the internal PID rate.
///   - occupancy: PIR poll/report rate ~1min is typical for
///     presence-detection logging (binary_event shape, not a frequency in
///     the continuous-signal sense).
///   - energy: 15-minute intervals are the documented AMI/smart-meter
///     industry standard — this one has a hard real-world number, not a
///     ballpark.
///   - vibration: real condition-monitoring systems don't stream raw
///     high-Hz data continuously — they capture periodic bursts (commonly
///     ~every 2 minutes) and extract features; 1/120 represents one
///     feature-extracted reading per burst interval.
///   - structural: static SHM trend monitoring uses 1-15 minute intervals
///     (continuous high-Hz sampling is reserved for active seismic/dynamic
///     EVENT capture, not baseline monitoring); 1/600 (10min) sits in that
///     range. The previous 1-10Hz values across building profiles were
///     600-6000x too fast for this sensor type.
///
/// retention_days is research-grounded for:
///   - energy: 5yr, within the documented 3yr-private/5yr-third-party-
///     sharing range for AMI data.
///   - structural: 7yr, strain gauges are built for 10yr+ service life,
///     matching typical facility-records compliance windows.
///   - co2/air_quality: 3yr (1095 days), the WELL Building Standard's
///     documented minimum for air-quality monitoring records (a real,
///     regulatory-grounded number — OSHA's 29 CFR 1910.1020 requires up to
///     30yr for employee-exposure records at regulated facilities, but
///     that's disproportionate for this tool's scope; WELL's 3yr is the
///     defensible, bounded choice).
/// The rest are reasoned operational defaults, not backed by an external
/// standard (labeled honestly, not dressed up as researched):
///   - temperature/humidity: 90 days — no retention standard exists for
///     BMS trend logs in the literature (only the 15-min sampling
///     convention is documented); kept short since this is fast-changing
///     operational data with no long-term compliance value.
///   - flow: 1yr — genuinely ambiguous whether a given flow sensor is
///     billing-relevant (utility water-meter retention runs 3yr+ in some
///     jurisdictions) or a purely internal HVAC/plumbing trend sensor (no
///     standard applies); 1yr is a pragmatic middle ground, not a
///     researched number.
///   - occupancy: 1yr — no retention standard found; privacy/data-
///     minimization literature argues for keeping this short, not long.
///   - vibration: 30 days — this is now an ANOMALY-EVENT log, not raw
///     history (see Shape.bursty_impulsive's doc comment), so the window
///     length barely affects volume either way; no external standard
///     found for condition-monitoring alarm-log retention.
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
        .temperature => .{ .base_value = 21.0, .daily_amplitude = 3.0, .peak_hour = 15.0, .noise_stddev = 0.3, .min_bound = 0.0, .max_bound = 50.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &COMFORT_QUERIES },
        .humidity => .{ .base_value = 45.0, .daily_amplitude = 10.0, .peak_hour = 5.0, .noise_stddev = 2.0, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 300.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.0, .retention_days = 90, .relevant_queries = &COMFORT_QUERIES_NO_THRESHOLD },
        .occupancy => .{ .base_value = 0.0, .daily_amplitude = 0.0, .peak_hour = 13.0, .noise_stddev = 0.0, .min_bound = 0.0, .max_bound = 1.0, .frequency_hz = 1.0 / 60.0, .shape = .binary_event, .density_per_100m2 = 1.0, .retention_days = 365, .relevant_queries = &OCCUPANCY_QUERIES },
        .co2 => .{ .base_value = 450.0, .daily_amplitude = 350.0, .peak_hour = 14.0, .noise_stddev = 20.0, .min_bound = 350.0, .max_bound = 5000.0, .frequency_hz = 1.0 / 180.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 1095, .relevant_queries = &AIR_SAFETY_QUERIES },
        .vibration => .{ .base_value = 0.05, .daily_amplitude = 0.15, .peak_hour = 13.0, .noise_stddev = 0.02, .min_bound = 0.0, .max_bound = 10.0, .frequency_hz = 1.0 / 120.0, .shape = .bursty_impulsive, .density_per_100m2 = 1.0, .retention_days = 30, .relevant_queries = &EQUIPMENT_HEALTH_QUERIES },
        .flow => .{ .base_value = 5.0, .daily_amplitude = 4.0, .peak_hour = 10.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 100.0, .frequency_hz = 1.0 / 60.0, .shape = .diurnal_continuous, .density_per_100m2 = 1.5, .retention_days = 365, .relevant_queries = &FLOW_QUERIES },
        .energy => .{ .base_value = 2.0, .daily_amplitude = 6.0, .peak_hour = 13.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 900.0, .shape = .stepwise_discrete, .density_per_100m2 = 0.5, .retention_days = 1825, .relevant_queries = &ENERGY_QUERIES },
        .structural => .{ .base_value = 50.0, .daily_amplitude = 5.0, .peak_hour = 15.0, .noise_stddev = 1.0, .min_bound = 0.0, .max_bound = 1000.0, .frequency_hz = 1.0 / 600.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 2555, .relevant_queries = &STRUCTURAL_QUERIES },
        .air_quality => .{ .base_value = 50.0, .daily_amplitude = 20.0, .peak_hour = 17.0, .noise_stddev = 5.0, .min_bound = 0.0, .max_bound = 500.0, .frequency_hz = 1.0 / 180.0, .shape = .diurnal_continuous, .density_per_100m2 = 0.5, .retention_days = 1095, .relevant_queries = &AIR_SAFETY_QUERIES },
    };
}

pub const GenerateConfig = struct {
    seed: u64 = 42,
    /// Simulation start, Unix epoch ms.
    start_time: i64 = 1_000_000,
    /// Total duration to simulate, in ms. Default 1 hour — callers driving
    /// a full benchmark dataset pass a longer duration explicitly.
    duration_ms: i64 = 60 * 60 * 1000,
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

    const end_time = config.start_time + config.duration_ms;

    for (sensors) |sensor| {
        const profile = profileFor(sensor.sensor_type);
        const period_ms = periodMs(profile.frequency_hz);
        var t: i64 = config.start_time;

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

        while (t < end_time) : (t += period_ms) {
            switch (profile.shape) {
                .diurnal_continuous => try out.append(allocator, .{
                    .sensor_id = sensor.sensor_id,
                    .timestamp = t,
                    .value = sampleDiurnal(profile, rand, t),
                    .sensor_type = sensor.sensor_type,
                }),
                .binary_event => {
                    const value = sampleBinaryEvent(profile, rand, t, &binary_state);
                    if (binary_last_emitted == null or value != binary_last_emitted.?) {
                        binary_last_emitted = value;
                        try out.append(allocator, .{
                            .sensor_id = sensor.sensor_id,
                            .timestamp = t,
                            .value = value,
                            .sensor_type = sensor.sensor_type,
                        });
                    }
                },
                .stepwise_discrete => try out.append(allocator, .{
                    .sensor_id = sensor.sensor_id,
                    .timestamp = t,
                    .value = sampleStepwiseDiscrete(profile, rand, t, &step_level, &step_hold),
                    .sensor_type = sensor.sensor_type,
                }),
                .bursty_impulsive => {
                    // bursty_impulsive is an ANOMALY-EVENT LOG, not a raw
                    // stream: real condition-monitoring systems don't
                    // retain the continuous high-Hz signal — only the
                    // detected events (bursts) get stored long-term. The
                    // non-event (baseline) samples are generated
                    // transiently, purely to drive the RNG the same way
                    // every tick (determinism), and discarded immediately.
                    const sample = sampleBurstyImpulsive(profile, rand);
                    if (sample.is_event) {
                        try out.append(allocator, .{
                            .sensor_id = sensor.sensor_id,
                            .timestamp = t,
                            .value = sample.value,
                            .sensor_type = sensor.sensor_type,
                        });
                    }
                },
            }
        }

        if (out_final_binary_state) |m| {
            if (profile.shape == .binary_event) {
                if (binary_last_emitted) |v| try m.put(sensor.sensor_id, v);
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Sampling period in ms from a sensor type's canonical Hz. Frequencies <= 0
/// degrade to one sample per day rather than dividing by zero or looping
/// forever — no profile produces this today (every profileFor entry is
/// > 0), but `generate` shouldn't trust that as a precondition.
fn periodMs(frequency_hz: f32) i64 {
    if (frequency_hz <= 0) return 24 * 60 * 60 * 1000;
    const period_s: f64 = 1.0 / @as(f64, frequency_hz);
    return @intFromFloat(@max(1.0, period_s * 1000.0));
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

test "generate scales to 100,000 sensors (Phase 1 ceiling) without blowing up" {
    const allocator = testing.allocator;
    const num_sensors: usize = 100_000;
    const sensors = try allocator.alloc(SensorMetadata, num_sensors);
    defer allocator.free(sensors);

    const all_types = [_]SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    for (sensors, 0..) |*s, i| {
        s.* = .{
            .sensor_id = @intCast(i),
            .sensor_type = all_types[i % all_types.len],
            .frequency_hz = 1.0, // informational only — generate() uses profileFor's canonical rate
            .element_id = 0,
        };
    }

    // Short duration so the test stays fast — this checks the generator's
    // per-sensor overhead scales to 100k sensors, not that it can produce a
    // full day of data for all of them in one test run. Every canonical
    // per-type period is well over 2000ms (the fastest, occupancy/flow, is
    // 60000ms), so exactly one tick gets evaluated per sensor in this
    // window — but "one tick evaluated" no longer means "one reading
    // stored" for every type: continuous/stepwise types and occupancy's
    // first-ever tick always emit, but vibration's bursty_impulsive only
    // emits ~2% of the time (event-based storage — see generate()'s
    // bursty_impulsive branch). So readings.len is bounded above by
    // num_sensors, not equal to it; the real thing this test checks is
    // that generation completes and doesn't blow up at this scale.
    const readings = try generate(allocator, sensors, .{ .duration_ms = 2000 }, null);
    defer allocator.free(readings);

    try testing.expect(readings.len > 0);
    try testing.expect(readings.len <= num_sensors);
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
    // for occupancy is 60_000ms, far longer than this 1ms window) — isolates
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
