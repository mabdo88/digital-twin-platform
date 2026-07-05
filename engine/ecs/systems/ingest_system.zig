// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Ingest system — pure function deciding whether one generated reading
// should ever reach storage. Per CLAUDE.md §3.1: a system is a pure
// function, owns no state, and never branches on the concrete backend type
// (this one doesn't touch World/backends at all — it runs BEFORE a reading
// is inserted anywhere).
//
// This is the missing "ingestion" stage between a real sensor and a real
// historian. It is deliberately NOT a network gateway/message broker
// (CLAUDE.md §6 explicitly excludes measuring network I/O) — it is the
// in-process equivalent decision a real gateway makes before forwarding a
// reading.
//
// Scoped to what's realistic, not "validate and flag everything" (see
// synthetic/generator.zig's FailureParams doc comment for the three
// failure modes and how each is actually handled in real systems):
//   - Out-of-bounds (physically impossible) values are REJECTED here —
//     never inserted. A real gateway drops a reading outside a sensor's
//     calibrated range rather than forwarding known-garbage to the
//     historian. Every generative shape already clamps its own output to
//     [min_bound, max_bound], so in practice the only way a reading
//     reaches this function out-of-bounds is FailureParams.drift_rate_ppm
//     (deliberately applied AFTER the shape's own clamp, uncapped — see
//     generator.zig's generate()/tickOnce) — this check has real teeth
//     against drift specifically, not a tautology that never fires.
//   - Dropout needs no ingest-side decision: a dropped tick never produces
//     a reading at all (tickOnce returns null), which is already the
//     correct "gap in the log" behavior.
//   - Stuck values are NOT rejected here — a real historian keeps a frozen
//     reading (with a quality flag, per OPC-UA's Good/Bad/Uncertain
//     convention) rather than discarding it, since the flatline itself is
//     diagnostic evidence. Attaching that quality flag needs a `quality`
//     field on SensorReading itself, which touches every backend's struct
//     layout — out of scope for this pass, tracked as a follow-up.

const std = @import("std");
const sb = @import("../storage/storage_backend.zig");
const generator = @import("../../synthetic/generator.zig");

/// Whether `reading` should be inserted at all. Rejects only readings
/// outside their sensor type's physical bounds (generator.profileFor's
/// min_bound/max_bound) — the one failure mode a real gateway can actually
/// detect from a single reading in isolation (see this file's header
/// comment for why dropout and stuck-value handling live elsewhere).
pub fn shouldAccept(reading: sb.SensorReading) bool {
    const profile = generator.profileFor(reading.sensor_type);
    return reading.value >= profile.min_bound and reading.value <= profile.max_bound;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "shouldAccept: an in-bounds reading is accepted" {
    const profile = generator.profileFor(.temperature);
    const r = sb.SensorReading{ .sensor_id = 1, .timestamp = 0, .value = profile.base_value, .sensor_type = .temperature };
    try testing.expect(shouldAccept(r));
}

test "shouldAccept: a reading outside the sensor type's physical bounds is rejected" {
    const profile = generator.profileFor(.temperature);
    const too_hot = sb.SensorReading{ .sensor_id = 1, .timestamp = 0, .value = profile.max_bound + 1.0, .sensor_type = .temperature };
    const too_cold = sb.SensorReading{ .sensor_id = 1, .timestamp = 0, .value = profile.min_bound - 1.0, .sensor_type = .temperature };
    try testing.expect(!shouldAccept(too_hot));
    try testing.expect(!shouldAccept(too_cold));
}

test "shouldAccept: exact boundary values are accepted (inclusive bounds)" {
    const profile = generator.profileFor(.co2);
    const at_min = sb.SensorReading{ .sensor_id = 1, .timestamp = 0, .value = profile.min_bound, .sensor_type = .co2 };
    const at_max = sb.SensorReading{ .sensor_id = 1, .timestamp = 0, .value = profile.max_bound, .sensor_type = .co2 };
    try testing.expect(shouldAccept(at_min));
    try testing.expect(shouldAccept(at_max));
}

test "shouldAccept: a reading drifted past bounds via a real generator.Stream is rejected" {
    // Every generative shape clamps its own output before drift is applied
    // (see generator.zig's generate()/tickOnce) — so accumulated drift is
    // the ONLY realistic way a generated reading can end up out-of-bounds.
    // This proves shouldAccept has real teeth against it, not just
    // synthetic out-of-range literals. Exercised through the public Stream
    // API (not generator.zig's private tickOnce) since this is a different
    // file/module.
    const sensors = [_]generator.SensorMetadata{
        .{ .sensor_id = 1, .sensor_type = .temperature, .frequency_hz = generator.profileFor(.temperature).frequency_hz, .element_id = 1 },
    };
    var stream = try generator.Stream.init(testing.allocator, &sensors, 6, 0, true);
    defer stream.deinit();

    // temperature's profileFor sets drift_rate_ppm = 1.6 (deliberately small
    // — see generator.zig's TEMPERATURE_FAILURES comment for why), crossing
    // the ~26 units of headroom to max_bound (50.0) only very late in a
    // multi-year run. 2750 simulated days (~792,000 ticks) is comfortably
    // past that crossing point.
    const test_window_ms: i64 = 2750 * 24 * 60 * 60 * 1000;
    const chunk = try stream.nextChunk(testing.allocator, test_window_ms);
    defer testing.allocator.free(chunk);

    var found_rejection = false;
    for (chunk) |r| {
        if (!shouldAccept(r)) found_rejection = true;
    }
    try testing.expect(found_rejection);
}
