// Zig 0.16.0 (tested against 0.17.0-dev)
//
// RingBuffer backend — fixed-size circular buffer per sensor keeping only
// the latest N readings in memory. Models an in-memory cache.
//
// Each sensor gets its own pre-allocated circular buffer of capacity N.
// When the buffer is full, new inserts overwrite the oldest entry.
// getLatestBySensor is O(1) — the latest reading is cached on insert.
//
// LIMITATION: Because old readings are evicted, rangeByTime and iterateAll
// return only the readings still in the buffer. Historical / long-lookback
// queries that span evicted data will return fewer results than a full-
// retention backend. The results returned are always correct (never
// fabricated) — they are simply the subset that has not been evicted.
// Equivalence tests must account for this by comparing only on queries
// whose data falls entirely within the retention window.
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).

const std = @import("std");
const sb = @import("../storage_backend.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

/// Default number of readings retained per sensor.
const DEFAULT_CAPACITY_PER_SENSOR: usize = 1000;

/// Per-sensor circular buffer. Internal only.
const SensorBuffer = struct {
    buffer: []SensorReading,
    head: usize,
    len: usize,
    latest: ?SensorReading,
};

allocator: std.mem.Allocator,
sensors: std.AutoHashMap(u32, SensorBuffer),
capacity_per_sensor: usize,
total_count: usize,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .sensors = std.AutoHashMap(u32, SensorBuffer).init(allocator),
        .capacity_per_sensor = DEFAULT_CAPACITY_PER_SENSOR,
        .total_count = 0,
    };
}

pub fn deinit(self: *Self) void {
    var it = self.sensors.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.buffer);
    }
    self.sensors.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    if (self.sensors.getPtr(reading.sensor_id)) |sb_ptr| {
        sb_ptr.buffer[sb_ptr.head] = reading;
        sb_ptr.head = (sb_ptr.head + 1) % self.capacity_per_sensor;
        if (sb_ptr.len < self.capacity_per_sensor) {
            sb_ptr.len += 1;
            self.total_count += 1;
        }
        if (sb_ptr.latest == null or reading.timestamp > sb_ptr.latest.?.timestamp) {
            sb_ptr.latest = reading;
        }
        return;
    }

    const buf = try self.allocator.alloc(SensorReading, self.capacity_per_sensor);
    errdefer self.allocator.free(buf);
    buf[0] = reading;
    try self.sensors.put(reading.sensor_id, .{
        .buffer = buf,
        .head = 1,
        .len = 1,
        .latest = reading,
    });
    self.total_count += 1;
}

pub fn count(self: *const Self) usize {
    return self.total_count;
}

pub fn memoryUsed(self: *const Self) usize {
    var total: usize = self.sensors.capacity() * (@sizeOf(u32) + @sizeOf(SensorBuffer));
    var it = self.sensors.iterator();
    while (it.next()) |_| {
        total += self.capacity_per_sensor * @sizeOf(SensorReading);
    }
    return total;
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
/// Only readings still in the buffer are returned.
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    var it = self.sensors.iterator();
    while (it.next()) |entry| {
        const sensor_buf = entry.value_ptr;
        for (sensor_buf.buffer[0..sensor_buf.len]) |r| {
            try result.append(allocator, r);
        }
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return result.toOwnedSlice(allocator);
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const sensor_buf = self.sensors.getPtr(sensor_id) orelse return null;
    return sensor_buf.latest;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Only readings still in the buffer are returned — evicted readings are not
/// included. See file header for the limitation documentation.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    if (q.sensor_id) |sid| {
        const sensor_buf = self.sensors.getPtr(sid) orelse return &.{};
        for (sensor_buf.buffer[0..sensor_buf.len]) |r| {
            if (r.timestamp >= q.start_time and r.timestamp <= q.end_time) {
                try result.append(allocator, r);
            }
        }
    } else {
        var it = self.sensors.iterator();
        while (it.next()) |entry| {
            const sensor_buf = entry.value_ptr;
            for (sensor_buf.buffer[0..sensor_buf.len]) |r| {
                if (r.timestamp >= q.start_time and r.timestamp <= q.end_time) {
                    try result.append(allocator, r);
                }
            }
        }
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return result.toOwnedSlice(allocator);
}

/// Unlike every other backend, this needs no scan at all: `sensors` is
/// already keyed by sensor_id, so group membership is a direct filter over
/// the hashmap's keys — O(num_sensors), not O(num_readings).
pub fn sensorIdsByGroup(self: *const Self, allocator: std.mem.Allocator, group_id: u32, divisor: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.sensors.keyIterator();
    while (it.next()) |sid| {
        if (sid.* / divisor == group_id) try result.append(allocator, sid.*);
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RingBuffer: assertImplements" {
    sb.assertImplements(Self);
}

test "RingBuffer: insert N readings and read them back" {
    const N: usize = 100;
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    for (0..N) |i| {
        try backend.insert(.{
            .sensor_id = @intCast(i % 10),
            .timestamp = @intCast(i),
            .value = @floatFromInt(i),
            .sensor_type = .temperature,
        });
    }

    try std.testing.expectEqual(N, backend.count());

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);

    try std.testing.expectEqual(N, all.len);
    // iterateAll returns sorted by (timestamp, sensor_id)
    for (0..N) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
    }
}

test "RingBuffer: getLatestBySensor" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 300, .value = 30.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 200, .value = 20.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 500, .value = 50.0, .sensor_type = .humidity });

    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 30.0), latest.value);

    try std.testing.expect(backend.getLatestBySensor(999) == null);
}

test "RingBuffer: rangeByTime filters and sorts" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 3, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 30, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 4.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 5, .timestamp = 200, .value = 5.0, .sensor_type = .temperature });

    const result = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 100 });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[0].timestamp);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[1].timestamp);
    try std.testing.expectEqual(@as(u32, 2), result[2].sensor_id);
    try std.testing.expectEqual(@as(i64, 30), result[2].timestamp);
    try std.testing.expectEqual(@as(u32, 3), result[3].sensor_id);
    try std.testing.expectEqual(@as(i64, 50), result[3].timestamp);
}

test "RingBuffer: rangeByTime with sensor filter" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 10, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 20, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 30, .value = 3.0, .sensor_type = .temperature });

    const result = try backend.rangeByTime(std.testing.allocator, .{
        .sensor_id = 1,
        .start_time = 0,
        .end_time = 100,
    });
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
}

test "RingBuffer: empty backend" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try std.testing.expectEqual(@as(usize, 0), backend.count());
    try std.testing.expect(backend.getLatestBySensor(0) == null);

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 0), all.len);

    const rng = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 100 });
    defer std.testing.allocator.free(rng);
    try std.testing.expectEqual(@as(usize, 0), rng.len);
}

test "RingBuffer: eviction keeps only latest N readings" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Insert more than DEFAULT_CAPACITY_PER_SENSOR readings for sensor 0.
    const N: usize = DEFAULT_CAPACITY_PER_SENSOR + 100;
    for (0..N) |i| {
        try backend.insert(.{
            .sensor_id = 0,
            .timestamp = @intCast(i),
            .value = @floatFromInt(i),
            .sensor_type = .temperature,
        });
    }

    // count should be capped at capacity
    try std.testing.expectEqual(DEFAULT_CAPACITY_PER_SENSOR, backend.count());

    // getLatestBySensor returns the highest-timestamp reading
    const latest = backend.getLatestBySensor(0).?;
    try std.testing.expectEqual(@as(i64, @intCast(N - 1)), latest.timestamp);

    // iterateAll returns exactly capacity readings
    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(DEFAULT_CAPACITY_PER_SENSOR, all.len);

    // The oldest 100 readings (timestamps 0..99) should be evicted.
    // The retained readings should have timestamps 100..N-1.
    for (all) |r| {
        try std.testing.expect(r.timestamp >= 100);
    }

    // rangeByTime for the evicted range returns empty
    const evicted = try backend.rangeByTime(std.testing.allocator, .{
        .sensor_id = 0,
        .start_time = 0,
        .end_time = 99,
    });
    defer std.testing.allocator.free(evicted);
    try std.testing.expectEqual(@as(usize, 0), evicted.len);

    // rangeByTime for the retained range returns all retained readings
    const retained = try backend.rangeByTime(std.testing.allocator, .{
        .sensor_id = 0,
        .start_time = 100,
        .end_time = @intCast(N - 1),
    });
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqual(DEFAULT_CAPACITY_PER_SENSOR, retained.len);
}

test "RingBuffer: out-of-order inserts handled correctly" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 300, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 200, .value = 2.0, .sensor_type = .temperature });

    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(i64, 100), all[0].timestamp);
    try std.testing.expectEqual(@as(i64, 200), all[1].timestamp);
    try std.testing.expectEqual(@as(i64, 300), all[2].timestamp);
}

test "RingBuffer: memoryUsed reports nonzero after insert" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try std.testing.expectEqual(@as(usize, 0), backend.memoryUsed());

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try std.testing.expect(backend.memoryUsed() > 0);
}

test "RingBuffer and TimeSeries produce identical results when data fits in buffer" {
    var rb = try Self.init(std.testing.allocator);
    defer rb.deinit();
    var ts = try @import("timeseries_storage.zig").init(std.testing.allocator);
    defer ts.deinit();

    // Dataset small enough to fit entirely within the ring buffer.
    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try rb.insert(r);
        try ts.insert(r);
    }

    try std.testing.expectEqual(ts.count(), rb.count());

    // rangeByTime — both must return same sorted results
    const rb_rng = try rb.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(rb_rng);
    const ts_rng = try ts.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(ts_rng);

    try std.testing.expectEqual(ts_rng.len, rb_rng.len);
    for (0..ts_rng.len) |i| {
        try std.testing.expectEqual(ts_rng[i].sensor_id, rb_rng[i].sensor_id);
        try std.testing.expectEqual(ts_rng[i].timestamp, rb_rng[i].timestamp);
        try std.testing.expectEqual(ts_rng[i].value, rb_rng[i].value);
        try std.testing.expectEqual(ts_rng[i].sensor_type, rb_rng[i].sensor_type);
    }

    // getLatestBySensor — both must agree
    for (0..6) |sid| {
        const rb_latest = rb.getLatestBySensor(@intCast(sid));
        const ts_latest = ts.getLatestBySensor(@intCast(sid));
        if (ts_latest) |t| {
            try std.testing.expect(rb_latest != null);
            try std.testing.expectEqual(t.timestamp, rb_latest.?.timestamp);
            try std.testing.expectEqual(t.sensor_id, rb_latest.?.sensor_id);
            try std.testing.expectEqual(t.value, rb_latest.?.value);
        } else {
            try std.testing.expect(rb_latest == null);
        }
    }

    // iterateAll — both must return same sorted results
    const rb_all = try rb.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(rb_all);
    const ts_all = try ts.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(ts_all);

    try std.testing.expectEqual(ts_all.len, rb_all.len);
    for (0..ts_all.len) |i| {
        try std.testing.expectEqual(ts_all[i].sensor_id, rb_all[i].sensor_id);
        try std.testing.expectEqual(ts_all[i].timestamp, rb_all[i].timestamp);
        try std.testing.expectEqual(ts_all[i].value, rb_all[i].value);
        try std.testing.expectEqual(ts_all[i].sensor_type, rb_all[i].sensor_type);
    }
}
