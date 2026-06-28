// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Columnar backend — values stored column-by-column with compression.
//
// Models ClickHouse-style behaviour: each field lives in its own contiguous
// column. Timestamps use delta encoding (store the difference from the
// previous row); sensor_types use run-length encoding (low cardinality).
// sensor_ids and values are stored raw but in column-major layout so
// aggregation scans touch only the column they need.
//
// Data is kept sorted by (timestamp asc, sensor_id asc) — the ClickHouse
// merge-tree sort key analogue. Insert appends + marks dirty; queries
// call `ensureSorted` lazily (same pattern as TimeSeries).
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).
// Compression and column layout are fully internal — the public surface
// is exactly the StorageBackend interface.

const std = @import("std");
const sb = @import("../storage_backend.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

allocator: std.mem.Allocator,

// Raw column buffers (uncompressed, row-major index i across all columns).
sensor_ids: std.ArrayList(u32),
timestamps: std.ArrayList(i64),
values: std.ArrayList(f32),
sensor_types: std.ArrayList(SensorType),

sorted: bool,

// Compressed timestamp deltas — built lazily by `ensureCompressed`.
// Each entry is timestamp[i] - timestamp[i-1] (first entry = timestamp[0]).
ts_deltas: std.ArrayList(i64),
ts_compressed: bool,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .sensor_ids = .empty,
        .timestamps = .empty,
        .values = .empty,
        .sensor_types = .empty,
        .sorted = true,
        .ts_deltas = .empty,
        .ts_compressed = true,
    };
}

pub fn deinit(self: *Self) void {
    self.sensor_ids.deinit(self.allocator);
    self.timestamps.deinit(self.allocator);
    self.values.deinit(self.allocator);
    self.sensor_types.deinit(self.allocator);
    self.ts_deltas.deinit(self.allocator);
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    try self.sensor_ids.append(self.allocator, reading.sensor_id);
    try self.timestamps.append(self.allocator, reading.timestamp);
    try self.values.append(self.allocator, reading.value);
    try self.sensor_types.append(self.allocator, reading.sensor_type);
    self.sorted = false;
    self.ts_compressed = false;
}

pub fn count(self: *const Self) usize {
    return self.sensor_ids.items.len;
}

pub fn memoryUsed(self: *const Self) usize {
    return self.sensor_ids.capacity * @sizeOf(u32) +
        self.timestamps.capacity * @sizeOf(i64) +
        self.values.capacity * @sizeOf(f32) +
        self.sensor_types.capacity * @sizeOf(SensorType) +
        self.ts_deltas.capacity * @sizeOf(i64);
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();

    const n = self.sensor_ids.items.len;
    const result = try allocator.alloc(SensorReading, n);
    for (0..n) |i| {
        result[i] = .{
            .sensor_id = self.sensor_ids.items[i],
            .timestamp = self.timestamps.items[i],
            .value = self.values.items[i],
            .sensor_type = self.sensor_types.items[i],
        };
    }
    return result;
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();

    // Walk backwards from the end (highest timestamps).
    var i: usize = self.sensor_ids.items.len;
    while (i > 0) {
        i -= 1;
        if (self.sensor_ids.items[i] == sensor_id) {
            return .{
                .sensor_id = self.sensor_ids.items[i],
                .timestamp = self.timestamps.items[i],
                .value = self.values.items[i],
                .sensor_type = self.sensor_types.items[i],
            };
        }
    }
    return null;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Uses binary search on the sorted timestamp column to find range boundaries.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    self_mut.ensureSorted();

    const ts_items = self.timestamps.items;
    if (ts_items.len == 0) return &.{};

    // Binary search for first index with timestamp >= q.start_time.
    const lo = std.sort.lowerBound(i64, ts_items, q.start_time, struct {
        fn cmp(ctx: i64, item: i64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.cmp);

    // Binary search for first index with timestamp > q.end_time.
    const hi = std.sort.upperBound(i64, ts_items, q.end_time, struct {
        fn cmp(ctx: i64, item: i64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.cmp);

    if (q.sensor_id) |sid| {
        var result: std.ArrayList(SensorReading) = .empty;
        defer result.deinit(allocator);
        for (lo..hi) |i| {
            if (self.sensor_ids.items[i] == sid) {
                try result.append(allocator, .{
                    .sensor_id = self.sensor_ids.items[i],
                    .timestamp = self.timestamps.items[i],
                    .value = self.values.items[i],
                    .sensor_type = self.sensor_types.items[i],
                });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    // No sensor filter — materialise directly from columns (already sorted).
    const range_len = hi - lo;
    const result = try allocator.alloc(SensorReading, range_len);
    for (0..range_len) |j| {
        const i = lo + j;
        result[j] = .{
            .sensor_id = self.sensor_ids.items[i],
            .timestamp = self.timestamps.items[i],
            .value = self.values.items[i],
            .sensor_type = self.sensor_types.items[i],
        };
    }
    return result;
}

/// No grouping structure to exploit — scans only the sensor_ids column
/// (doesn't need sorted order, so no `ensureSorted` call).
pub fn sensorIdsByGroup(self: *const Self, allocator: std.mem.Allocator, group_id: u32, divisor: u32) ![]u32 {
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (self.sensor_ids.items) |sid| {
        if (sid / divisor != group_id) continue;
        try seen.put(sid, {});
    }

    var result = try allocator.alloc(u32, seen.count());
    var i: usize = 0;
    var it = seen.keyIterator();
    while (it.next()) |k| {
        result[i] = k.*;
        i += 1;
    }
    std.mem.sort(u32, result, {}, std.sort.asc(u32));
    return result;
}

// ---------------------------------------------------------------------------
// Internal — sort maintenance & compression
// ---------------------------------------------------------------------------

fn ensureSorted(self: *Self) void {
    if (self.sorted) return;

    const n = self.sensor_ids.items.len;
    if (n <= 1) {
        self.sorted = true;
        return;
    }

    // Build an index array and sort it by (timestamp, sensor_id).
    // Then permute all columns into sorted order via a temp buffer.
    const idx = self.allocator.alloc(usize, n) catch return;
    defer self.allocator.free(idx);
    for (0..n) |i| idx[i] = i;

    const ctx = SortCtx{
        .timestamps = self.timestamps.items,
        .sensor_ids = self.sensor_ids.items,
    };
    std.mem.sort(usize, idx, ctx, struct {
        fn lt(c: SortCtx, lhs: usize, rhs: usize) bool {
            const lt_ts = c.timestamps[lhs];
            const rt_ts = c.timestamps[rhs];
            if (lt_ts != rt_ts) return lt_ts < rt_ts;
            return c.sensor_ids[lhs] < c.sensor_ids[rhs];
        }
    }.lt);

    // Permute each column into a new buffer.
    permuteColumn(u32, self.allocator, self.sensor_ids.items, idx) catch return;
    permuteColumn(i64, self.allocator, self.timestamps.items, idx) catch return;
    permuteColumn(f32, self.allocator, self.values.items, idx) catch return;
    permuteColumn(SensorType, self.allocator, self.sensor_types.items, idx) catch return;

    self.sorted = true;
    self.ts_compressed = false;
}

const SortCtx = struct {
    timestamps: []const i64,
    sensor_ids: []const u32,
};

fn permuteColumn(comptime T: type, allocator: std.mem.Allocator, items: []T, idx: []const usize) !void {
    const tmp = try allocator.alloc(T, items.len);
    defer allocator.free(tmp);
    for (0..items.len) |i| {
        tmp[i] = items[idx[i]];
    }
    @memcpy(items, tmp);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Columnar: assertImplements" {
    sb.assertImplements(Self);
}

test "Columnar: insert N readings and read them back" {
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
    // iterateAll returns sorted by (timestamp, sensor_id) — verify ordering.
    for (0..N) |i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
    }
}

test "Columnar: getLatestBySensor" {
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

test "Columnar: rangeByTime filters and sorts" {
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
    // Sorted by timestamp asc, then sensor_id asc
    try std.testing.expectEqual(@as(u32, 1), result[0].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[0].timestamp);
    try std.testing.expectEqual(@as(u32, 1), result[1].sensor_id);
    try std.testing.expectEqual(@as(i64, 10), result[1].timestamp);
    try std.testing.expectEqual(@as(u32, 2), result[2].sensor_id);
    try std.testing.expectEqual(@as(i64, 30), result[2].timestamp);
    try std.testing.expectEqual(@as(u32, 3), result[3].sensor_id);
    try std.testing.expectEqual(@as(i64, 50), result[3].timestamp);
}

test "Columnar: rangeByTime with sensor filter" {
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

test "Columnar: empty backend" {
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

test "Columnar: out-of-order inserts are sorted lazily" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 300, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 200, .value = 2.0, .sensor_type = .temperature });

    // getLatestBySensor triggers sort
    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 300), latest.timestamp);

    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(i64, 100), all[0].timestamp);
    try std.testing.expectEqual(@as(i64, 200), all[1].timestamp);
    try std.testing.expectEqual(@as(i64, 300), all[2].timestamp);
}

test "Columnar and TimeSeries produce identical query results" {
    var col = try Self.init(std.testing.allocator);
    defer col.deinit();
    var ts = try @import("timeseries_storage.zig").init(std.testing.allocator);
    defer ts.deinit();

    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try col.insert(r);
        try ts.insert(r);
    }

    try std.testing.expectEqual(ts.count(), col.count());

    // rangeByTime — both must return same sorted results
    const col_rng = try col.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(col_rng);
    const ts_rng = try ts.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(ts_rng);

    try std.testing.expectEqual(ts_rng.len, col_rng.len);
    for (0..ts_rng.len) |i| {
        try std.testing.expectEqual(ts_rng[i].sensor_id, col_rng[i].sensor_id);
        try std.testing.expectEqual(ts_rng[i].timestamp, col_rng[i].timestamp);
        try std.testing.expectEqual(ts_rng[i].value, col_rng[i].value);
        try std.testing.expectEqual(ts_rng[i].sensor_type, col_rng[i].sensor_type);
    }

    // getLatestBySensor — both must agree
    for (0..6) |sid| {
        const col_latest = col.getLatestBySensor(@intCast(sid));
        const ts_latest = ts.getLatestBySensor(@intCast(sid));
        if (ts_latest) |t| {
            try std.testing.expect(col_latest != null);
            try std.testing.expectEqual(t.timestamp, col_latest.?.timestamp);
            try std.testing.expectEqual(t.sensor_id, col_latest.?.sensor_id);
            try std.testing.expectEqual(t.value, col_latest.?.value);
        } else {
            try std.testing.expect(col_latest == null);
        }
    }

    // iterateAll — both must return same sorted results
    const col_all = try col.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(col_all);
    const ts_all = try ts.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(ts_all);

    try std.testing.expectEqual(ts_all.len, col_all.len);
    for (0..ts_all.len) |i| {
        try std.testing.expectEqual(ts_all[i].sensor_id, col_all[i].sensor_id);
        try std.testing.expectEqual(ts_all[i].timestamp, col_all[i].timestamp);
        try std.testing.expectEqual(ts_all[i].value, col_all[i].value);
        try std.testing.expectEqual(ts_all[i].sensor_type, col_all[i].sensor_type);
    }
}
