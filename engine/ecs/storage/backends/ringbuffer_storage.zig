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
const ZoneIndex = @import("../zone_index.zig");

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
/// Fallback capacity for any sensor_type that never got a setRetentionHint
/// call. A sensor's OWN buffer size, once allocated, lives on
/// SensorBuffer.buffer.len (see capacityForType/setRetentionHint's doc
/// comments for why this field is not used for existing sensors' wraparound
/// math anymore).
default_capacity_per_sensor: usize,
/// sensor_type -> capacity hint set via setRetentionHint, consulted only
/// when allocating a NEW sensor's buffer (first insert for that
/// sensor_id). See setRetentionHint's doc comment.
capacity_per_type: std.AutoHashMap(SensorType, usize),
total_count: usize,
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .sensors = std.AutoHashMap(u32, SensorBuffer).init(allocator),
        .default_capacity_per_sensor = DEFAULT_CAPACITY_PER_SENSOR,
        .capacity_per_type = std.AutoHashMap(SensorType, usize).init(allocator),
        .total_count = 0,
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.sensors.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.buffer);
    }
    self.sensors.deinit();
    self.capacity_per_type.deinit();
    self.zone_index.deinit();
    self.* = undefined;
}

fn capacityForType(self: *const Self, sensor_type: SensorType) usize {
    return self.capacity_per_type.get(sensor_type) orelse self.default_capacity_per_sensor;
}

/// See storage_backend.zig's setRetentionHint contract: only affects
/// sensors of `sensor_type` not yet inserted (their buffer is allocated at
/// this size on first insert); already-allocated sensors keep their
/// original buffer size.
pub fn setRetentionHint(self: *Self, sensor_type: SensorType, max_readings: usize) !void {
    try self.capacity_per_type.put(sensor_type, max_readings);
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    if (self.sensors.getPtr(reading.sensor_id)) |sb_ptr| {
        // Wraparound math must use THIS sensor's own buffer length, not a
        // backend-wide constant — different sensor types can have
        // different capacities (see setRetentionHint), so two sensors in
        // the same backend instance may have differently-sized buffers.
        const capacity = sb_ptr.buffer.len;
        sb_ptr.buffer[sb_ptr.head] = reading;
        sb_ptr.head = (sb_ptr.head + 1) % capacity;
        if (sb_ptr.len < capacity) {
            sb_ptr.len += 1;
            self.total_count += 1;
        }
        if (sb_ptr.latest == null or reading.timestamp > sb_ptr.latest.?.timestamp) {
            sb_ptr.latest = reading;
        }
        return;
    }

    const buf = try self.allocator.alloc(SensorReading, self.capacityForType(reading.sensor_type));
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
    while (it.next()) |entry| {
        // Each sensor's own buffer length, not a single backend-wide
        // constant — capacities can differ per sensor_type (setRetentionHint).
        total += entry.value_ptr.buffer.len * @sizeOf(SensorReading);
    }
    total += self.capacity_per_type.capacity() * (@sizeOf(SensorType) + @sizeOf(usize));
    return total + self.zone_index.memoryUsed();
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

/// Zone/floor topology bookkeeping delegates to the shared ZoneIndex — see
/// storage_backend.zig's doc comment for the contract.
pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
    return self.zone_index.registerZone(sensor_id, zone_id);
}

pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
    return self.zone_index.registerFloor(zone_id, floor_id);
}

pub fn sensorIdsByZone(self: *const Self, allocator: std.mem.Allocator, zone_id: u32) ![]u32 {
    return self.zone_index.sensorIdsByZone(allocator, zone_id);
}

pub fn sensorIdsByFloor(self: *const Self, allocator: std.mem.Allocator, floor_id: u32) ![]u32 {
    return self.zone_index.sensorIdsByFloor(allocator, floor_id);
}

pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
    return self.zone_index.floorOfZone(zone_id);
}

pub fn allSensorIds(self: *const Self, allocator: std.mem.Allocator) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.sensors.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// No-op — the ring buffer's circular overwrite already handles retention.
/// Old readings are evicted automatically when the buffer is full and a
/// new reading is inserted, so explicit time-based pruning is unnecessary.
/// See storage_backend.zig's pruneOlderThan contract.
pub fn pruneOlderThan(_: *Self, _: SensorType, _: i64) !void {}

// ---------------------------------------------------------------------------
// Tests — this file had none until 2026-07-20 (.cascade/digital-twin/
// backend-audit.md's 2026-07-20 entry: four backend files, RingBuffer
// included, had lost all dedicated regression tests somewhere between the
// 2026-07-01 "8 new regression tests... one for RingBuffer specifically
// forcing a wrapped buffer" entry and the current tree — cross-backend
// correctness was still covered by runner.zig's dynamic equivalence suite,
// but nothing exercised RingBuffer's own eviction mechanism in isolation).
//
// `insert`'s circular overwrite — not `pruneOlderThan`, which is a genuine
// no-op here (see its doc comment above) — is the mechanism that actually
// produces RingBuffer's coverage gaps: the same gaps `scoreBackends`'
// UNCOVERED_QUERY_PENALTY (report.zig) exists to charge against a
// recommendation. A silent regression here (e.g. evicting the wrong slot,
// or `head`/`len` losing sync with `buffer.len` after `setRetentionHint`
// gives two sensor types different capacities) would corrupt exactly the
// data the penalty is trying to score honestly.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "RingBuffer insert: wraparound evicts oldest-first, keeping exactly the last `capacity` readings" {
    const allocator = testing.allocator;
    var rb = try Self.init(allocator);
    defer rb.deinit();

    const sensor_id: u32 = 1;
    const capacity: usize = 3;
    try rb.setRetentionHint(.temperature, capacity);

    // Insert capacity + 2 readings with distinct increasing timestamps —
    // forces the buffer past one full wraparound (head cycles back to 0
    // mid-insert), so physical slot order and logical (oldest-to-newest)
    // order diverge.
    var i: i64 = 0;
    while (i < @as(i64, @intCast(capacity)) + 2) : (i += 1) {
        try rb.insert(.{ .sensor_id = sensor_id, .sensor_type = .temperature, .timestamp = i, .value = @floatFromInt(i) });
    }

    const all = try rb.rangeByTime(allocator, .{ .sensor_id = sensor_id, .start_time = 0, .end_time = 1000 });
    defer allocator.free(all);

    // Only the last `capacity` readings survive (timestamps 2,3,4 — 0 and
    // 1 were evicted), in ascending order despite the physical buffer's
    // wrapped layout.
    try testing.expectEqual(capacity, all.len);
    for (all, 0..) |r, idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)) + 2, r.timestamp);
    }

    try testing.expectEqual(@as(i64, 4), rb.getLatestBySensor(sensor_id).?.timestamp);
    // count() must track only what's actually resident, never the total
    // ever inserted — capacity + 2 inserts, capacity survivors.
    try testing.expectEqual(capacity, rb.count());
}

test "RingBuffer insert: two sensor types with different setRetentionHint capacities evict independently, each using its own buffer length" {
    const allocator = testing.allocator;
    var rb = try Self.init(allocator);
    defer rb.deinit();

    // Different capacities for different types, set before either sensor's
    // first insert — the documented contract (setRetentionHint's doc
    // comment): a hint only affects sensors of that type allocated after
    // it's set. Getting this wrong (e.g. reintroducing a single backend-
    // wide capacity field for wraparound math) would make one sensor's
    // modulo arithmetic silently corrupt using the other type's capacity.
    try rb.setRetentionHint(.temperature, 2);
    try rb.setRetentionHint(.humidity, 4);

    const temp_id: u32 = 10;
    const humid_id: u32 = 20;

    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try rb.insert(.{ .sensor_id = temp_id, .sensor_type = .temperature, .timestamp = i, .value = 0 });
        try rb.insert(.{ .sensor_id = humid_id, .sensor_type = .humidity, .timestamp = i, .value = 0 });
    }

    const temp_all = try rb.rangeByTime(allocator, .{ .sensor_id = temp_id, .start_time = 0, .end_time = 1000 });
    defer allocator.free(temp_all);
    const humid_all = try rb.rangeByTime(allocator, .{ .sensor_id = humid_id, .start_time = 0, .end_time = 1000 });
    defer allocator.free(humid_all);

    // temperature (capacity 2): keeps only the last 2 of 5 -> timestamps 3,4.
    try testing.expectEqual(@as(usize, 2), temp_all.len);
    try testing.expectEqual(@as(i64, 3), temp_all[0].timestamp);
    try testing.expectEqual(@as(i64, 4), temp_all[1].timestamp);

    // humidity (capacity 4): keeps the last 4 of 5 -> timestamps 1,2,3,4.
    try testing.expectEqual(@as(usize, 4), humid_all.len);
    try testing.expectEqual(@as(i64, 1), humid_all[0].timestamp);
    try testing.expectEqual(@as(i64, 4), humid_all[3].timestamp);
}
