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
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validateBounds: generator output has zero violations across all sensor types" {
    const all_types = [_]SensorType{ .temperature, .humidity, .occupancy, .co2, .vibration, .flow, .energy, .structural, .air_quality };
    var sensors: [all_types.len]generator.SensorMetadata = undefined;
    for (all_types, 0..) |st, i| {
        sensors[i] = .{ .sensor_id = @intCast(i), .sensor_type = st, .frequency_hz = 0.5, .element_id = 0 };
    }

    const readings = try generator.generate(testing.allocator, &sensors, .{ .duration_ms = 3 * 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    const violations = try validateBounds(testing.allocator, readings);
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "validateBounds: flags a hand-built out-of-bounds reading" {
    const readings = [_]SensorReading{
        .{ .sensor_id = 0, .timestamp = 0, .value = 25.0, .sensor_type = .temperature }, // in bounds
        .{ .sensor_id = 1, .timestamp = 0, .value = 999.0, .sensor_type = .temperature }, // way over 50C
        .{ .sensor_id = 2, .timestamp = 0, .value = -5.0, .sensor_type = .humidity }, // under 0%
    };

    const violations = try validateBounds(testing.allocator, &readings);
    defer testing.allocator.free(violations);

    try testing.expectEqual(@as(usize, 2), violations.len);
    try testing.expectEqual(@as(u32, 1), violations[0].sensor_id);
    try testing.expectEqual(@as(u32, 2), violations[1].sensor_id);
}

test "validateBounds: empty input has zero violations" {
    const violations = try validateBounds(testing.allocator, &.{});
    defer testing.allocator.free(violations);
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "hasDailyPattern: generator output shows a measurable day/night cycle for a high-amplitude type" {
    const sensors = [_]generator.SensorMetadata{
        .{ .sensor_id = 0, .sensor_type = .energy, .frequency_hz = 0.5, .element_id = 0 },
    };
    const readings = try generator.generate(testing.allocator, &sensors, .{ .duration_ms = 5 * 24 * 60 * 60 * 1000 }, null);
    defer testing.allocator.free(readings);

    try testing.expect(hasDailyPattern(readings, .energy));
}

test "hasDailyPattern: a hand-built flat dataset (no swing) fails the check for a high-amplitude type" {
    // Every reading pinned to the exact same value and the exact same hour
    // as the profile's trough — there's no peak-window data at all, so this
    // must report false rather than a false positive.
    var readings: [20]SensorReading = undefined;
    for (&readings, 0..) |*r, i| {
        r.* = .{
            .sensor_id = 0,
            // All readings land at hour 1 (energy's trough is hour 1 = peak
            // 13 + 12, wrapped) — same value, no peak-window samples.
            .timestamp = @as(i64, @intCast(i)) * 24 * 60 * 60 * 1000 + 1 * 60 * 60 * 1000,
            .value = 2.0,
            .sensor_type = .energy,
        };
    }

    try testing.expect(!hasDailyPattern(&readings, .energy));
}

test "hasDailyPattern: empty readings report no pattern rather than a false positive" {
    try testing.expect(!hasDailyPattern(&.{}, .temperature));
}
