// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Lake backend — cold tier modelling S3 + Parquet columnar storage.
//
// Models an object-store/cold-archive layout (e.g. S3 + Parquet): data is
// stored in time-partitioned objects (one per sensor_type per day). Each
// partition stores data in column-major format with per-column compression,
// matching how real Parquet files organise data into column chunks within
// time-partitioned directory prefixes (year=2026/month=01/day=02/).
//
// Column compression (matching Parquet encodings):
//   - Timestamps: delta encoding + zigzag + LEB128 varint (Parquet's
//     DELTA_BINARY_PACKED equivalent). Typical sensor sampling intervals
//     produce small deltas that varint-encode to 1-3 bytes vs 8 raw.
//   - Sensor IDs: dictionary encoding (Parquet's PLAIN_DICTIONARY). A
//     small dictionary of unique sensor IDs + u16 indices per row —
//     typically 2 bytes/row vs 4 bytes raw u32 when cardinality < 65536.
//   - Values: raw f32 column (Parquet would use byte-stream-split or
//     RLE for floats; we keep raw for simplicity — the dominant wins
//     are timestamp delta and sensor_id dictionary encoding).
//   - Sensor_type: NOT stored — it's implicit from the partition key
//     (every row in a (sensor_type, day) partition has the same type),
//     saving an entire column. Real Parquet files similarly elide
//     constant columns via partition pruning.
//
// No decompressed data is kept resident — columns are decoded on every
// scan, modelling how cold storage reads from S3 and decompresses on
// demand. This makes queries slower (decode cost per scan) but keeps
// memory footprint minimal (only compressed bytes are stored), which is
// the fundamental cold-storage tradeoff: cheap to store, expensive to query.
//
// Retention is O(partitions_dropped) — entire expired objects are deleted,
// matching S3 lifecycle policies that drop old prefixes, not row-level
// DELETEs.
//
// Unlike AoS/SoA (worst-case reference baselines, explicitly not
// deployment candidates — see backend-audit.md and runner.zig's
// `backends` list), Lake IS a real deployment candidate: it is expected to
// win precisely when a query is infrequent/cold enough that paying for
// Columnar/TimeSeries's indexing overhead isn't worthwhile for that
// sensor type's retention window.
//
// Iteration order: insertion order within each partition, partitions
// iterated in unspecified (HashMap) order — same tradeoff as AoS/SoA.

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

const PARTITION_MS: i64 = 86_400_000; // 1 day in milliseconds

const PartitionKey = struct {
    sensor_type: SensorType,
    day_index: i64,
};

/// Parquet-style columnar partition. Each column is stored independently
/// with its own encoding. No decompressed row data is kept resident —
/// columns are decoded on every scan (cold-storage read pattern).
const Partition = struct {
    row_count: usize,
    // Delta + zigzag + LEB128 varint encoded timestamps.
    ts_deltas: std.ArrayList(u8),
    // Dictionary-encoded sensor_id column.
    sid_dict: std.ArrayList(u32), // unique sensor IDs
    sid_indices: std.ArrayList(u16), // per-row index into sid_dict
    // Raw f32 values column.
    values: std.ArrayList(f32),
    // Last decoded timestamp — avoids re-decoding the whole column on insert.
    last_ts: i64,
};

allocator: std.mem.Allocator,
partitions: std.AutoHashMap(PartitionKey, Partition),
total_count: usize,
latest_by_sensor: std.AutoHashMap(u32, SensorReading),
latest_dirty: bool,
zone_index: ZoneIndex,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .partitions = std.AutoHashMap(PartitionKey, Partition).init(allocator),
        .total_count = 0,
        .latest_by_sensor = std.AutoHashMap(u32, SensorReading).init(allocator),
        .latest_dirty = false,
        .zone_index = ZoneIndex.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const part = entry.value_ptr;
        part.ts_deltas.deinit(self.allocator);
        part.sid_dict.deinit(self.allocator);
        part.sid_indices.deinit(self.allocator);
        part.values.deinit(self.allocator);
    }
    self.partitions.deinit();
    self.latest_by_sensor.deinit();
    self.zone_index.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    const key = PartitionKey{
        .sensor_type = reading.sensor_type,
        .day_index = @divFloor(reading.timestamp, PARTITION_MS),
    };
    const gop = try self.partitions.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .row_count = 0,
            .ts_deltas = .empty,
            .sid_dict = .empty,
            .sid_indices = .empty,
            .values = .empty,
            .last_ts = 0,
        };
    }
    const part = gop.value_ptr;

    // Encode timestamp: delta from previous row, zigzag, varint.
    const prev_ts = part.last_ts;
    const delta = reading.timestamp -% prev_ts;
    try appendVarint(self.allocator, &part.ts_deltas, zigzagEncode(delta));
    part.last_ts = reading.timestamp;

    // Dictionary-encode sensor_id: look up in dict, or add.
    var dict_idx: u16 = 0;
    for (part.sid_dict.items, 0..) |sid, i| {
        if (sid == reading.sensor_id) {
            dict_idx = @intCast(i);
            break;
        }
    } else {
        dict_idx = @intCast(part.sid_dict.items.len);
        try part.sid_dict.append(self.allocator, reading.sensor_id);
    }
    try part.sid_indices.append(self.allocator, dict_idx);

    // Raw values column.
    try part.values.append(self.allocator, reading.value);

    part.row_count += 1;
    self.total_count += 1;

    if (self.latest_by_sensor.get(reading.sensor_id)) |current| {
        if (reading.timestamp > current.timestamp) {
            self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
        }
    } else {
        self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
    }
}

pub fn count(self: *const Self) usize {
    return self.total_count;
}

/// Reports the compressed footprint — only the bytes actually stored
/// (compressed columns), not any decompressed working set. This is the
/// "on-disk" cost that makes cold storage cheap: timestamp deltas are
/// typically 1-3 bytes vs 8 raw, sensor_id indices are 2 bytes vs 4 raw,
/// and the sensor_type column is eliminated entirely.
pub fn memoryUsed(self: *const Self) usize {
    var total: usize = self.partitions.capacity() * (@sizeOf(PartitionKey) + @sizeOf(Partition));
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const part = entry.value_ptr;
        total += part.ts_deltas.items.len; // compressed timestamps
        total += part.sid_dict.items.len * @sizeOf(u32); // dictionary
        total += part.sid_indices.items.len * @sizeOf(u16); // indices
        total += part.values.items.len * @sizeOf(f32); // raw values
    }
    total += self.latest_by_sensor.capacity() * (@sizeOf(u32) + @sizeOf(SensorReading));
    return total + self.zone_index.memoryUsed();
}

/// Iteration order: insertion order within each partition.
/// Decodes compressed columns on the fly — no decompressed data is cached.
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, self.total_count);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const part = entry.value_ptr;
        try decodePartition(part, key.sensor_type, allocator, &result, null);
    }

    return result.toOwnedSlice(allocator);
}

pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    return self_mut.latest_by_sensor.get(sensor_id);
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Full linear scan of partitions overlapping the query time range.
/// Decodes compressed columns on the fly, filtering during decode.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    if (q.start_time > q.end_time) return &.{};

    const start_day = @divFloor(q.start_time, PARTITION_MS);
    const end_day = @divFloor(q.end_time, PARTITION_MS);

    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.day_index < start_day or key.day_index > end_day) continue;

        const part = entry.value_ptr;
        const filter = RangeFilter{
            .start_time = q.start_time,
            .end_time = q.end_time,
            .sensor_id = q.sensor_id,
        };
        try decodePartition(part, key.sensor_type, allocator, &result, filter);
    }

    std.mem.sort(SensorReading, result.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    return try result.toOwnedSlice(allocator);
}

/// Zone/floor topology bookkeeping delegates to the shared ZoneIndex — see
/// storage_backend.zig's doc comment for the contract and zone_index.zig's
/// header for why this is shared rather than copy-pasted per backend.
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

    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    var it = self_mut.latest_by_sensor.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Drops entire time-partitions of `sensor_type` that are fully older than
/// `cutoff_timestamp` — O(partitions), not O(readings). Only the boundary
/// partition gets row-level compaction. See storage_backend.zig's
/// pruneOlderThan contract.
/// Lake has no fixed-capacity concept — it holds everything inserted,
/// bounded only by pruneOlderThan. No-op, per storage_backend.zig's
/// setRetentionHint contract.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    var to_drop: std.ArrayList(PartitionKey) = .empty;
    defer to_drop.deinit(self.allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.sensor_type != sensor_type) continue;

        const part_start = key.day_index * PARTITION_MS;
        const part_end = (key.day_index + 1) * PARTITION_MS;

        if (part_end <= cutoff_timestamp) {
            try to_drop.append(self.allocator, key);
            self.total_count -= entry.value_ptr.row_count;
        } else if (part_start < cutoff_timestamp) {
            // Boundary partition: decode, filter, re-encode.
            const part = entry.value_ptr;
            try self.compactPartition(part, cutoff_timestamp);
        }
    }

    for (to_drop.items) |key| {
        if (self.partitions.fetchRemove(key)) |kv| {
            var part = kv.value;
            part.ts_deltas.deinit(self.allocator);
            part.sid_dict.deinit(self.allocator);
            part.sid_indices.deinit(self.allocator);
            part.values.deinit(self.allocator);
        }
    }

    self.latest_dirty = true;
}

fn rebuildLatest(self: *Self) void {
    self.latest_by_sensor.clearRetainingCapacity();
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const part = entry.value_ptr;

        // Decode timestamps and sensor_ids to find latest per sensor.
        var ts_pos: usize = 0;
        var prev_ts: i64 = 0;
        for (0..part.row_count) |i| {
            const delta = zigzagDecode(readVarint(part.ts_deltas.items, &ts_pos));
            prev_ts +%= delta;
            const sid = part.sid_dict.items[part.sid_indices.items[i]];
            const reading = SensorReading{
                .sensor_id = sid,
                .timestamp = prev_ts,
                .value = part.values.items[i],
                .sensor_type = key.sensor_type,
            };
            if (self.latest_by_sensor.get(sid)) |current| {
                if (prev_ts > current.timestamp) {
                    self.latest_by_sensor.put(sid, reading) catch {};
                }
            } else {
                self.latest_by_sensor.put(sid, reading) catch {};
            }
        }
    }
    self.latest_dirty = false;
}

// ---------------------------------------------------------------------------
// Internal — column decode/encode helpers
// ---------------------------------------------------------------------------

const RangeFilter = struct {
    start_time: i64,
    end_time: i64,
    sensor_id: ?u32,
};

/// Decodes a partition's compressed columns into SensorReading rows,
/// optionally filtering by time range and sensor_id during decode (avoids
/// materialising rows that would be discarded). Models Parquet page-level
/// predicate pushdown.
fn decodePartition(
    part: *const Partition,
    sensor_type: SensorType,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(SensorReading),
    filter: ?RangeFilter,
) !void {
    if (part.row_count == 0) return;

    var ts_pos: usize = 0;
    var prev_ts: i64 = 0;

    for (0..part.row_count) |i| {
        const delta = zigzagDecode(readVarint(part.ts_deltas.items, &ts_pos));
        prev_ts +%= delta;
        const sid = part.sid_dict.items[part.sid_indices.items[i]];
        const val = part.values.items[i];

        if (filter) |f| {
            if (prev_ts < f.start_time or prev_ts > f.end_time) continue;
            if (f.sensor_id) |fsid| {
                if (sid != fsid) continue;
            }
        }

        try out.append(allocator, .{
            .sensor_id = sid,
            .timestamp = prev_ts,
            .value = val,
            .sensor_type = sensor_type,
        });
    }
}

/// Compacts a boundary partition by decoding, filtering out rows older
/// than cutoff, and re-encoding the surviving rows. Models rewriting a
/// Parquet file after a partial delete (rare in real cold storage —
/// typically the whole file is replaced).
fn compactPartition(self: *Self, part: *Partition, cutoff_timestamp: i64) !void {
    if (part.row_count == 0) return;

    // Decode all rows, keep only those >= cutoff.
    var ts_pos: usize = 0;
    var prev_ts: i64 = 0;

    var new_ts_deltas: std.ArrayList(u8) = .empty;
    var new_sid_dict: std.ArrayList(u32) = .empty;
    var new_sid_indices: std.ArrayList(u16) = .empty;
    var new_values: std.ArrayList(f32) = .empty;

    var new_last_ts: i64 = 0;
    var new_count: usize = 0;

    for (0..part.row_count) |i| {
        const delta = zigzagDecode(readVarint(part.ts_deltas.items, &ts_pos));
        prev_ts +%= delta;
        const sid = part.sid_dict.items[part.sid_indices.items[i]];
        const val = part.values.items[i];

        if (prev_ts < cutoff_timestamp) continue;

        // Re-encode timestamp delta from new sequence.
        const new_delta = prev_ts -% new_last_ts;
        try appendVarint(self.allocator, &new_ts_deltas, zigzagEncode(new_delta));
        new_last_ts = prev_ts;

        // Re-encode sensor_id into new dictionary.
        var dict_idx: u16 = 0;
        for (new_sid_dict.items, 0..) |d_sid, j| {
            if (d_sid == sid) {
                dict_idx = @intCast(j);
                break;
            }
        } else {
            dict_idx = @intCast(new_sid_dict.items.len);
            try new_sid_dict.append(self.allocator, sid);
        }
        try new_sid_indices.append(self.allocator, dict_idx);
        try new_values.append(self.allocator, val);
        new_count += 1;
    }

    self.total_count -= part.row_count - new_count;

    // Replace partition contents.
    part.ts_deltas.deinit(self.allocator);
    part.sid_dict.deinit(self.allocator);
    part.sid_indices.deinit(self.allocator);
    part.values.deinit(self.allocator);

    part.ts_deltas = new_ts_deltas;
    part.sid_dict = new_sid_dict;
    part.sid_indices = new_sid_indices;
    part.values = new_values;
    part.row_count = new_count;
    part.last_ts = new_last_ts;
}

// ---------------------------------------------------------------------------
// Zigzag + LEB128 varint encoding (same scheme as columnar_storage.zig)
// ---------------------------------------------------------------------------

fn zigzagEncode(n: i64) u64 {
    return @bitCast((n << 1) ^ (n >> 63));
}

fn zigzagDecode(n: u64) i64 {
    return @bitCast((n >> 1) ^ (~(n & 1) +% 1));
}

fn appendVarint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u64) !void {
    var v = value;
    while (v >= 0x80) {
        try list.append(allocator, @intCast((v & 0x7F) | 0x80));
        v >>= 7;
    }
    try list.append(allocator, @intCast(v));
}

fn readVarint(buf: []const u8, pos: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = buf[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Lake: insert N readings and read them back" {
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
    for (0..N) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i % 10)), all[i].sensor_id);
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), all[i].value);
        try std.testing.expectEqual(SensorType.temperature, all[i].sensor_type);
    }
}

test "Lake: getLatestBySensor" {
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

test "Lake: rangeByTime filters and sorts" {
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

test "Lake: rangeByTime with sensor filter" {
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

test "Lake: sensorIdsByZone/sensorIdsByFloor reflect real (non-arithmetic) registration" {
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

test "Lake: getLatestBySensor is deterministic across repeated calls when timestamps tie" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 20.0, .sensor_type = .temperature });

    const first = backend.getLatestBySensor(1).?;
    const second = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 100), first.timestamp);
    try std.testing.expectEqual(first.value, second.value);
}

test "Lake: empty backend" {
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

test "Lake: pruneOlderThan removes only the matching type older than cutoff" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 150, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 50, .value = 3.0, .sensor_type = .humidity });

    try backend.pruneOlderThan(.temperature, 100);

    try std.testing.expectEqual(@as(usize, 2), backend.count());
    const all = try backend.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(all);

    var found_old_temp = false;
    var found_new_temp = false;
    var found_humidity = false;
    for (all) |r| {
        if (r.sensor_type == .temperature and r.timestamp == 50) found_old_temp = true;
        if (r.sensor_type == .temperature and r.timestamp == 150) found_new_temp = true;
        if (r.sensor_type == .humidity and r.timestamp == 50) found_humidity = true;
    }
    try std.testing.expect(!found_old_temp);
    try std.testing.expect(found_new_temp);
    try std.testing.expect(found_humidity);
}

test "Lake and TimeSeries produce identical results" {
    var lake = try Self.init(std.testing.allocator);
    defer lake.deinit();
    var ts = try @import("timeseries_storage.zig").init(std.testing.allocator);
    defer ts.deinit();

    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try lake.insert(r);
        try ts.insert(r);
    }

    try std.testing.expectEqual(lake.count(), ts.count());

    const lake_all = try lake.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(lake_all);
    const ts_all = try ts.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(ts_all);

    try std.testing.expectEqual(lake_all.len, ts_all.len);

    const lake_rng = try lake.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(lake_rng);
    const ts_rng = try ts.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(ts_rng);

    try std.testing.expectEqual(lake_rng.len, ts_rng.len);
    for (0..lake_rng.len) |i| {
        try std.testing.expectEqual(lake_rng[i].sensor_id, ts_rng[i].sensor_id);
        try std.testing.expectEqual(lake_rng[i].timestamp, ts_rng[i].timestamp);
    }
}
