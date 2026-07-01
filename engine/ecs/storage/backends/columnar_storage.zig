// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Columnar backend — values stored column-by-column with compression.
//
// Models ClickHouse-style behaviour: each field lives in its own contiguous
// column. Timestamps use delta encoding (store the difference from the
// previous row, zigzag + LEB128 varint packed into `ts_deltas`); sensor_ids
// and values are stored raw but in column-major layout so aggregation scans
// touch only the column they need.
//
// Data is kept sorted by (timestamp asc, sensor_id asc) — the ClickHouse
// merge-tree sort key analogue. Insert appends + marks dirty; queries
// call `ensureSorted` lazily (same pattern as TimeSeries).
//
// Compression model (`ensureCompressed`): once sorted, consecutive
// timestamps differ by small deltas (sensor sampling intervals), so
// zigzag-encoding the delta then LEB128-varint-packing it typically takes
// 1-3 bytes instead of the raw column's 8 — the actual win compression
// gives a time-series-shaped column. `ts_deltas` is the value `memoryUsed`
// reports for the timestamp column (the on-disk-equivalent cost); the raw
// `timestamps` array is kept resident as the decompressed working set
// queries read from, the same way a real columnar engine keeps a hot
// block's decompressed form in its buffer pool rather than re-decoding on
// every scan. `rangeByTime`'s unfiltered path calls `ensureCompressed`
// before searching, so the compressed column is always kept in sync with
// what queries are actually relying on, not just built once and forgotten.
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).
// Compression and column layout are fully internal — the public surface
// is exactly the StorageBackend interface.

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

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
// Byte stream: each entry is zigzag(timestamp[i] - timestamp[i-1]) (first
// entry's "previous" is 0), LEB128-varint-packed. See `ensureCompressed`.
ts_deltas: std.ArrayList(u8),
ts_compressed: bool,

zone_index: ZoneIndex,

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
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.sensor_ids.deinit(self.allocator);
    self.timestamps.deinit(self.allocator);
    self.values.deinit(self.allocator);
    self.sensor_types.deinit(self.allocator);
    self.ts_deltas.deinit(self.allocator);
    self.zone_index.deinit();
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

/// Timestamp column cost is reported as the compressed footprint
/// (`ts_deltas`) when compression is up to date, since that's what the
/// column actually costs to store — `timestamps` itself is a decompressed
/// working-set cache (see file header). Falls back to the raw column's
/// size while dirty/uncompressed so memoryUsed never *under*-reports.
pub fn memoryUsed(self: *const Self) usize {
    const ts_cost: usize = if (self.ts_compressed)
        self.ts_deltas.items.len
    else
        self.timestamps.capacity * @sizeOf(i64);

    return self.sensor_ids.capacity * @sizeOf(u32) +
        ts_cost +
        self.values.capacity * @sizeOf(f32) +
        self.sensor_types.capacity * @sizeOf(SensorType) +
        self.zone_index.memoryUsed();
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
    // Keep the compressed column in sync with what this query relies on —
    // ts_deltas is the value memoryUsed() reports, so it must never be
    // allowed to silently go stale relative to the data being queried.
    try self_mut.ensureCompressed();

    const ts_items = self.timestamps.items;
    if (ts_items.len == 0) return &.{};
    // An inverted range (start > end) is unsatisfiable by definition — bail
    // out before the binary search, which otherwise computes lo > hi and
    // panics (`hi - lo` underflow, or `for (lo..hi)` on the filtered path).
    if (q.start_time > q.end_time) return &.{};

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

/// Removes every reading of `sensor_type` older than `cutoff_timestamp` via
/// an in-place stable compaction across all columns (readings of other
/// types, and this backend's zone/floor topology, are untouched). Preserves
/// whatever sort order the columns were already in, so `sorted` doesn't
/// need to change — but `ts_deltas` encodes each row's delta from its
/// PREVIOUS row, so removing rows invalidates every delta after the first
/// removed one; marking `ts_compressed = false` forces `ensureCompressed`
/// to rebuild it from the (correct) raw `timestamps` column on next use,
/// same as a fresh insert already does. See storage_backend.zig's
/// pruneOlderThan contract.
/// Columnar has no fixed-capacity concept — see aos_storage.zig's
/// setRetentionHint for why this is a no-op.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    var write: usize = 0;
    for (self.sensor_ids.items, 0..) |sid, i| {
        const ts = self.timestamps.items[i];
        const st = self.sensor_types.items[i];
        if (st == sensor_type and ts < cutoff_timestamp) continue;
        self.sensor_ids.items[write] = sid;
        self.timestamps.items[write] = ts;
        self.values.items[write] = self.values.items[i];
        self.sensor_types.items[write] = st;
        write += 1;
    }
    self.sensor_ids.shrinkRetainingCapacity(write);
    self.timestamps.shrinkRetainingCapacity(write);
    self.values.shrinkRetainingCapacity(write);
    self.sensor_types.shrinkRetainingCapacity(write);
    self.ts_compressed = false;
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

/// Rebuilds `ts_deltas` from `timestamps` (must already be sorted) if a
/// write has invalidated it since the last build. No-op otherwise — same
/// lazy-rebuild shape as `ensureSorted` and hierarchical_storage.zig's
/// `ensureCache`.
fn ensureCompressed(self: *Self) !void {
    if (self.ts_compressed) return;

    self.ts_deltas.clearRetainingCapacity();
    var prev: i64 = 0;
    for (self.timestamps.items) |ts| {
        const delta = ts -% prev;
        try appendVarint(self.allocator, &self.ts_deltas, zigzagEncode(delta));
        prev = ts;
    }
    self.ts_compressed = true;
}

/// Decodes `ts_deltas` back into absolute timestamps. Used by tests to
/// prove the compressed column round-trips losslessly — the same encoding
/// `ensureCompressed` builds and `memoryUsed` reports the cost of.
fn decodeTimestamps(allocator: std.mem.Allocator, deltas: []const u8, n: usize) ![]i64 {
    const result = try allocator.alloc(i64, n);
    var pos: usize = 0;
    var prev: i64 = 0;
    for (0..n) |i| {
        const delta = zigzagDecode(readVarint(deltas, &pos));
        prev +%= delta;
        result[i] = prev;
    }
    return result;
}

/// Maps signed deltas to unsigned so small magnitudes (positive or
/// negative) both varint-encode to few bytes. Standard protobuf zigzag.
fn zigzagEncode(v: i64) u64 {
    const uv: u64 = @bitCast(v);
    const sign_mask: u64 = @bitCast(v >> 63);
    return (uv << 1) ^ sign_mask;
}

fn zigzagDecode(n: u64) i64 {
    const shifted = n >> 1;
    const sign_mask: u64 = 0 -% (n & 1);
    return @bitCast(shifted ^ sign_mask);
}

/// LEB128 unsigned varint — 1 byte per 7 bits, continuation bit in the MSB.
fn appendVarint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: u64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) {
            try buf.append(allocator, byte | 0x80);
        } else {
            try buf.append(allocator, byte);
            return;
        }
    }
}

fn readVarint(buf: []const u8, pos: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = buf[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
    }
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

test "Columnar: sensorIdsByZone/sensorIdsByFloor reflect real (non-arithmetic) registration" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 7, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.registerZone(7, 4291);
    try backend.registerZone(2, 4291);
    try backend.registerFloor(4291, 3);

    const zone = try backend.sensorIdsByZone(std.testing.allocator, 4291);
    defer std.testing.allocator.free(zone);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, zone);

    const floor = try backend.sensorIdsByFloor(std.testing.allocator, 3);
    defer std.testing.allocator.free(floor);
    try std.testing.expectEqualSlices(u32, &.{ 2, 7 }, floor);

    try std.testing.expectEqual(@as(?u32, 3), backend.floorOfZone(4291));

    const empty = try backend.sensorIdsByZone(std.testing.allocator, 99);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Columnar: getLatestBySensor is deterministic across repeated calls when timestamps tie" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 20.0, .sensor_type = .temperature });

    const first = backend.getLatestBySensor(1).?;
    const second = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 100), first.timestamp);
    try std.testing.expectEqual(first.value, second.value);
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

test "Columnar: zigzag + varint round-trip on representative deltas" {
    const cases = [_]i64{ 0, 1, -1, 63, -64, 64, -65, 1000, -1000, 1_700_000_000_000, -1_700_000_000_000 };
    for (cases) |v| {
        const encoded = zigzagEncode(v);
        try std.testing.expectEqual(v, zigzagDecode(encoded));
    }
}

test "Columnar: ensureCompressed round-trips timestamps losslessly" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Out-of-order + irregular spacing, the realistic shape for a sensor
    // stream before ensureSorted runs.
    const inputs = [_]i64{ 5000, 1000, 3000, 1000, 9999, 0, 1_700_000_000_000 };
    for (inputs, 0..) |ts, i| {
        try backend.insert(.{ .sensor_id = @intCast(i), .timestamp = ts, .value = 1.0, .sensor_type = .temperature });
    }

    backend.ensureSorted();
    try backend.ensureCompressed();
    try std.testing.expect(backend.ts_compressed);

    const decoded = try decodeTimestamps(std.testing.allocator, backend.ts_deltas.items, backend.timestamps.items.len);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualSlices(i64, backend.timestamps.items, decoded);
}

test "Columnar: compression is invalidated by new inserts and re-synced by rangeByTime" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 200, .value = 2.0, .sensor_type = .temperature });

    const first = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 1000 });
    std.testing.allocator.free(first);
    try std.testing.expect(backend.ts_compressed);

    try backend.insert(.{ .sensor_id = 3, .timestamp = 300, .value = 3.0, .sensor_type = .temperature });
    try std.testing.expect(!backend.ts_compressed);

    const result = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 1000 });
    defer std.testing.allocator.free(result);
    try std.testing.expect(backend.ts_compressed);
    try std.testing.expectEqual(@as(usize, 3), result.len);

    const decoded = try decodeTimestamps(std.testing.allocator, backend.ts_deltas.items, backend.timestamps.items.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(i64, backend.timestamps.items, decoded);
}

test "Columnar: memoryUsed reflects compressed timestamp footprint, not raw" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Realistic regularly-sampled stream: 2000 readings, 1000ms apart.
    // Each delta is a constant 1000 -> 2 varint bytes, vs. 8 raw bytes.
    const N: usize = 2000;
    for (0..N) |i| {
        try backend.insert(.{
            .sensor_id = @intCast(i % 20),
            .timestamp = @intCast(i * 1000),
            .value = 1.0,
            .sensor_type = .temperature,
        });
    }

    const mem_before = backend.memoryUsed();
    backend.ensureSorted();
    try backend.ensureCompressed();
    const mem_after = backend.memoryUsed();

    // Compressed cost must be substantially smaller than 8 bytes/timestamp.
    try std.testing.expect(backend.ts_deltas.items.len < N * 4);
    // And memoryUsed must actually reflect that drop, not just compute it
    // and ignore it.
    try std.testing.expect(mem_after < mem_before);
}

test "Columnar: pruneOlderThan removes only the matching type older than cutoff and invalidates compression" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 150, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 50, .value = 3.0, .sensor_type = .humidity });

    backend.ensureSorted();
    try backend.ensureCompressed();
    try std.testing.expect(backend.ts_compressed);

    try backend.pruneOlderThan(.temperature, 100);

    // Removing rows invalidates the delta encoding (deltas are relative to
    // the previous row) -- must be marked dirty, not left stale.
    try std.testing.expect(!backend.ts_compressed);

    try std.testing.expectEqual(@as(usize, 2), backend.count());
    const rng = try backend.rangeByTime(std.testing.allocator, .{ .start_time = 0, .end_time = 1000 });
    defer std.testing.allocator.free(rng);
    try std.testing.expectEqual(@as(usize, 2), rng.len);
    try std.testing.expectEqual(@as(i64, 50), rng[0].timestamp);
    try std.testing.expectEqual(SensorType.humidity, rng[0].sensor_type);
    try std.testing.expectEqual(@as(i64, 150), rng[1].timestamp);
    try std.testing.expectEqual(SensorType.temperature, rng[1].sensor_type);
}
