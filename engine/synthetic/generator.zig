// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Synthetic sensor data generator — Phase 6.
//
// Turns the sensors `bim/sensor_placer.zig` placed on a real (or test)
// building into deterministic, physically-plausible readings. Per CLAUDE.md
// §3.5: "no hard-coded building assumptions; rules are data, not code" — the
// per-sensor-type statistical shape lives entirely in `profileFor`'s table,
// never in branching logic inside `generate`.
//
// Model: each sensor type gets one sine wave (a 24h daily cycle peaking at
// a fixed hour) plus per-reading Gaussian noise, clamped to a physical
// floor/ceiling. This is deliberately the simplest model that satisfies the
// spec's three requirements (bounds, daily pattern, equipment off-hours —
// a high-amplitude profile like `.energy`'s IS the off-hours signal: its
// trough naturally lands at night) without inventing a second mechanism.
//
// Determinism (CLAUDE.md §3.4): one PRNG, seeded once from `config.seed`,
// consumed in `sensors` order. Same sensors + same config -> byte-identical
// output, always.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");
const components = @import("../bim/components.zig");

pub const SensorReading = sb.SensorReading;
pub const SensorType = sb.SensorType;
pub const SensorMetadata = components.SensorMetadata;

/// Statistical shape of one sensor type's daily cycle. `base_value` is the
/// 24h mean; `daily_amplitude` is the swing of a single sine wave peaking at
/// `peak_hour` (0-23); `noise_stddev` is per-reading Gaussian jitter;
/// `[min_bound, max_bound]` is the physical floor/ceiling every reading is
/// clamped to regardless of how the model above lands.
pub const SensorProfile = struct {
    base_value: f32,
    daily_amplitude: f32,
    peak_hour: f32,
    noise_stddev: f32,
    min_bound: f32,
    max_bound: f32,
};

/// One row per `SensorType` — the only place "realistic" is defined. Adding
/// a new SensorType means adding one row here, never an `if` in `generate`.
/// Ranges are illustrative real-world ballparks (indoor temp/humidity,
/// office CO2, AQI 0-500, etc.), not measured — Phase 6's job is plausible
/// synthetic data, not a calibrated sensor model.
pub fn profileFor(sensor_type: SensorType) SensorProfile {
    return switch (sensor_type) {
        .temperature => .{ .base_value = 21.0, .daily_amplitude = 3.0, .peak_hour = 15.0, .noise_stddev = 0.3, .min_bound = 0.0, .max_bound = 50.0 },
        .humidity => .{ .base_value = 45.0, .daily_amplitude = 10.0, .peak_hour = 5.0, .noise_stddev = 2.0, .min_bound = 0.0, .max_bound = 100.0 },
        .occupancy => .{ .base_value = 0.3, .daily_amplitude = 0.3, .peak_hour = 11.0, .noise_stddev = 0.05, .min_bound = 0.0, .max_bound = 1.0 },
        .co2 => .{ .base_value = 450.0, .daily_amplitude = 350.0, .peak_hour = 14.0, .noise_stddev = 20.0, .min_bound = 350.0, .max_bound = 5000.0 },
        .vibration => .{ .base_value = 0.05, .daily_amplitude = 0.15, .peak_hour = 13.0, .noise_stddev = 0.02, .min_bound = 0.0, .max_bound = 10.0 },
        .flow => .{ .base_value = 5.0, .daily_amplitude = 4.0, .peak_hour = 10.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 100.0 },
        .energy => .{ .base_value = 2.0, .daily_amplitude = 6.0, .peak_hour = 13.0, .noise_stddev = 0.5, .min_bound = 0.0, .max_bound = 500.0 },
        .structural => .{ .base_value = 50.0, .daily_amplitude = 5.0, .peak_hour = 15.0, .noise_stddev = 1.0, .min_bound = 0.0, .max_bound = 1000.0 },
        .air_quality => .{ .base_value = 50.0, .daily_amplitude = 20.0, .peak_hour = 17.0, .noise_stddev = 5.0, .min_bound = 0.0, .max_bound = 500.0 },
    };
}

pub const GenerateConfig = struct {
    seed: u64 = 42,
    /// Simulation start, Unix epoch ms.
    start_time: i64 = 1_000_000,
    /// Total duration to simulate, in ms. Default 1 hour — callers driving
    /// a full benchmark dataset pass a longer duration explicitly.
    duration_ms: i64 = 60 * 60 * 1000,
};

/// Generate deterministic, physically-plausible readings for every sensor in
/// `sensors`, sampled at each sensor's own `frequency_hz` across
/// `config.duration_ms`. Returns a slice owned by the caller (free with
/// `allocator`). Empty `sensors` returns an empty slice, not an error.
pub fn generate(
    allocator: std.mem.Allocator,
    sensors: []const SensorMetadata,
    config: GenerateConfig,
) ![]SensorReading {
    var prng = std.Random.DefaultPrng.init(config.seed);
    const rand = prng.random();

    var out: std.ArrayList(SensorReading) = .empty;
    errdefer out.deinit(allocator);

    const end_time = config.start_time + config.duration_ms;

    for (sensors) |sensor| {
        const profile = profileFor(sensor.sensor_type);
        const period_ms = periodMs(sensor.frequency_hz);
        var t: i64 = config.start_time;
        while (t < end_time) : (t += period_ms) {
            try out.append(allocator, .{
                .sensor_id = sensor.sensor_id,
                .timestamp = t,
                .value = sampleValue(profile, rand, t),
                .sensor_type = sensor.sensor_type,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Sampling period in ms from a sensor's Hz. Frequencies <= 0 degrade to one
/// sample per day rather than dividing by zero or looping forever — no
/// placement rule produces this today (sensor_placer's rules are all > 0),
/// but `generate` shouldn't trust that as a precondition.
fn periodMs(frequency_hz: f32) i64 {
    if (frequency_hz <= 0) return 24 * 60 * 60 * 1000;
    const period_s: f64 = 1.0 / @as(f64, frequency_hz);
    return @intFromFloat(@max(1.0, period_s * 1000.0));
}

fn sampleValue(profile: SensorProfile, rand: std.Random, timestamp_ms: i64) f32 {
    const hour = hourOfDay(timestamp_ms);
    const phase = (hour - profile.peak_hour) * (std.math.pi * 2.0 / 24.0);
    const daily = profile.daily_amplitude * @cos(phase);
    const noise = rand.floatNorm(f32) * profile.noise_stddev;
    const raw = profile.base_value + daily + noise;
    return std.math.clamp(raw, profile.min_bound, profile.max_bound);
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

    const a = try generate(testing.allocator, &sensors, .{ .duration_ms = 6 * 60 * 60 * 1000 });
    defer testing.allocator.free(a);
    const b = try generate(testing.allocator, &sensors, .{ .duration_ms = 6 * 60 * 60 * 1000 });
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

    const a = try generate(testing.allocator, &sensors, .{ .seed = 1, .duration_ms = 60 * 1000 });
    defer testing.allocator.free(a);
    const b = try generate(testing.allocator, &sensors, .{ .seed = 2, .duration_ms = 60 * 1000 });
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
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 3 * 24 * 60 * 60 * 1000 });
    defer testing.allocator.free(readings);

    try testing.expect(readings.len > 0);
    for (readings) |r| {
        const p = profileFor(r.sensor_type);
        try testing.expect(r.value >= p.min_bound);
        try testing.expect(r.value <= p.max_bound);
    }
}

test "generate: empty sensor list returns an empty slice, not an error" {
    const readings = try generate(testing.allocator, &.{}, .{});
    defer testing.allocator.free(readings);
    try testing.expectEqual(@as(usize, 0), readings.len);
}

test "generate: zero and negative frequency_hz degrade to one sample per day instead of crashing" {
    const sensors = [_]SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .temperature, .frequency_hz = 0.0, .element_id = 0 },
        .{ .sensor_id = 1, .sensor_type = .temperature, .frequency_hz = -5.0, .element_id = 0 },
    };
    const readings = try generate(testing.allocator, &sensors, .{ .duration_ms = 2 * 24 * 60 * 60 * 1000 });
    defer testing.allocator.free(readings);

    // 2-day duration at "1 sample per day" -> exactly 2 samples per sensor.
    try testing.expectEqual(@as(usize, 4), readings.len);
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
            .frequency_hz = 1.0,
            .element_id = 0,
        };
    }

    // Short duration so the test stays fast — this checks the generator's
    // per-sensor overhead scales to 100k sensors, not that it can produce a
    // full day of data for all of them in one test run.
    const readings = try generate(allocator, sensors, .{ .duration_ms = 2000 });
    defer allocator.free(readings);

    // 1Hz over 2000ms -> 2 samples/sensor.
    try testing.expectEqual(num_sensors * 2, readings.len);
}
