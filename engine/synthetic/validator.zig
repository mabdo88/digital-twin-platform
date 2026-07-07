// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Synthetic data validator — Phase 6.
//
// Two independent checks on `generator.zig`'s output, matching AGENT.md's
// Phase 6 checklist: physical plausibility (bounds) and daily-pattern
// presence (the data isn't flat noise). Neither check mutates or filters
// readings — callers decide what to do with violations.

const std = @import("std");
const sb = @import("../ecs/storage/storage_backend.zig");
const generator = @import("generator.zig");

pub const SensorReading = sb.SensorReading;
pub const SensorType = sb.SensorType;

pub const BoundsViolation = struct {
    sensor_id: u32,
    timestamp: i64,
    value: f32,
    min_bound: f32,
    max_bound: f32,
};

/// Check every reading against its sensor type's physical bounds
/// (`generator.profileFor`'s min/max). Returns the list of violations —
/// empty means every reading is plausible. Pure function: never panics on
/// out-of-range data, since out-of-range data is exactly what it's looking for.
pub fn validateBounds(allocator: std.mem.Allocator, readings: []const SensorReading) ![]BoundsViolation {
    var violations: std.ArrayList(BoundsViolation) = .empty;
    errdefer violations.deinit(allocator);

    for (readings) |r| {
        const profile = generator.profileFor(r.sensor_type);
        if (r.value < profile.min_bound or r.value > profile.max_bound) {
            try violations.append(allocator, .{
                .sensor_id = r.sensor_id,
                .timestamp = r.timestamp,
                .value = r.value,
                .min_bound = profile.min_bound,
                .max_bound = profile.max_bound,
            });
        }
    }
    return violations.toOwnedSlice(allocator);
}

/// Circular distance between two hour-of-day values (0-24 wraps to 0).
fn circularHourDistance(a: f32, b: f32) f32 {
    const diff = @abs(a - b);
    return @min(diff, 24.0 - diff);
}

/// Statistical sanity check, not a per-reading rule: for a sensor type whose
/// profile has a nonzero `daily_amplitude`, the average value within 2 hours
/// of `peak_hour` should be measurably higher than the average within 2
/// hours of the opposite hour (`peak_hour + 12`, wrapped) — confirming
/// `generate` actually produced a day/night cycle (which, for a
/// high-amplitude profile like `.energy`, IS the "equipment off-hours"
/// signal) rather than flat noise. Types with `daily_amplitude == 0` have
/// nothing to check and trivially pass.
///
/// Needs readings spanning at least a few days to have enough samples in
/// both windows — a few hours of data isn't enough signal either way.
pub fn hasDailyPattern(readings: []const SensorReading, sensor_type: SensorType) bool {
    const profile = generator.profileFor(sensor_type);
    if (profile.daily_amplitude <= 0) return true;

    const trough_hour = @mod(profile.peak_hour + 12.0, 24.0);

    var peak_sum: f64 = 0;
    var peak_n: usize = 0;
    var trough_sum: f64 = 0;
    var trough_n: usize = 0;

    for (readings) |r| {
        if (r.sensor_type != sensor_type) continue;
        const hour = generator.hourOfDay(r.timestamp);
        if (circularHourDistance(hour, profile.peak_hour) <= 2.0) {
            peak_sum += r.value;
            peak_n += 1;
        }
        if (circularHourDistance(hour, trough_hour) <= 2.0) {
            trough_sum += r.value;
            trough_n += 1;
        }
    }

    if (peak_n == 0 or trough_n == 0) return false;

    const peak_avg = peak_sum / @as(f64, @floatFromInt(peak_n));
    const trough_avg = trough_sum / @as(f64, @floatFromInt(trough_n));
    // Expect at least half the modeled swing to survive noise averaging.
    return (peak_avg - trough_avg) >= @as(f64, profile.daily_amplitude) * 0.5;
}

// ---------------------------------------------------------------------------
