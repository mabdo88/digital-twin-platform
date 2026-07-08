// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Columnar backend — ClickHouse MergeTree-style storage.
//
// Models ClickHouse's MergeTree engine: data is organised into
// time-partitioned parts (one per sensor_type per day). Each part stores
// values column-by-column with per-column compression. Queries scan only
// the partitions overlapping the time range. Retention drops entire
// expired parts — O(parts), not O(rows), matching ClickHouse's
// MergeTree part-drop retention.
//
// Within each partition, data is kept sorted by (timestamp asc, sensor_id
// asc) — the MergeTree sort key analogue. Insert appends + marks dirty;
// queries call `ensurePartitionSorted` lazily per partition.
//
// Sparse granule index (ClickHouse's primary index): instead of binary
// searching the full timestamp array, a sparse index stores one entry per
// GRANULE_SIZE rows (the first timestamp of each granule). Binary search
// on the granule index narrows to a ~8192-row block, then a linear scan
// within that block finds the exact range. This is O(log(n/granule))
// instead of O(log n) — fewer comparisons, better cache locality.
//
// Column compression (matching ClickHouse encodings):
//   - Timestamps: delta encoding + zigzag + LEB128 varint (ClickHouse's
//     DELTA_BINARY_PACKED analogue).
//   - Sensor IDs: dictionary encoding (ClickHouse's LowCardinality).
//     A small dictionary of unique IDs + u16 indices per row.
//   - Values: delta encoding + zigzag + varint (ClickHouse's
//     DELTA_DOUBLE for float columns — we use integer zigzag on the
//     bit-cast representation).
//   - Sensor_type: NOT stored — implicit from the partition key, saving
//     an entire column (ClickHouse partition pruning).
//
// Part merging (ClickHouse background merge): small adjacent day-partitions
// for the same sensor_type are merged into larger parts to keep the part
// count bounded. `mergeParts` is called lazily before queries that span
// multiple partitions, consolidating parts whose combined size is below
// the merge threshold. This prevents unbounded part growth from
// fine-grained daily partitions.
//
// Iteration order: sorted by (timestamp asc, sensor_id asc).
// Compression, granule index, and column layout are fully internal — the
// public surface is exactly the StorageBackend interface.

const std = @import("std");
const sb = @import("../storage_backend.zig");
const ZoneIndex = @import("../zone_index.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

const PARTITION_MS: i64 = 86_400_000; // 1 day in milliseconds

/// ClickHouse default granule size — one sparse index entry per this many rows.
const GRANULE_SIZE: usize = 8192;

/// Parts with combined row count below this threshold are candidates for merging.
const MERGE_THRESHOLD: usize = 4096;

const PartitionKey = struct {
    sensor_type: SensorType,
    day_index: i64,
};

/// ClickHouse MergeTree part: column-major storage with per-column
/// compression and a sparse granule index on the sort key (timestamp).
const Partition = struct {
    // Raw columns (decompressed working set).
    sensor_ids: std.ArrayList(u32),
    timestamps: std.ArrayList(i64),
    values: std.ArrayList(f32),
    sorted: bool,

    // Compressed columns (rebuilt lazily from raw columns).
    ts_deltas: std.ArrayList(u8), // delta + zigzag + varint timestamps
    sid_dict: std.ArrayList(u32), // dictionary of unique sensor IDs
    sid_indices: std.ArrayList(u16), // per-row index into sid_dict
    val_deltas: std.ArrayList(u8), // delta + zigzag + varint on f32 bits
    compressed: bool,

    // Sparse granule index: one entry per GRANULE_SIZE rows, storing the
    // first timestamp of each granule. Binary search narrows to a granule,
    // then linear scan within it finds the exact range.
    granule_marks: std.ArrayList(usize), // row index of each granule start
    granule_ts: std.ArrayList(i64), // first timestamp of each granule
    index_valid: bool,

    // Min/max timestamps across all rows in this part. Used for time-range
    // pruning instead of day_index, so merged parts spanning multiple days
    // are still correctly queried. Matches ClickHouse's part min/max blocks.
    min_ts: i64,
    max_ts: i64,
};

allocator: std.mem.Allocator,
partitions: std.AutoHashMap(PartitionKey, Partition),
total_count: usize,
latest_by_sensor: std.AutoHashMap(u32, SensorReading),
latest_dirty: bool,
zone_index: ZoneIndex,
parts_merged: bool,

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .partitions = std.AutoHashMap(PartitionKey, Partition).init(allocator),
        .total_count = 0,
        .latest_by_sensor = std.AutoHashMap(u32, SensorReading).init(allocator),
        .latest_dirty = false,
        .zone_index = ZoneIndex.init(allocator),
        .parts_merged = true,
    };
}

pub fn deinit(self: *Self) void {
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const part = entry.value_ptr;
        part.sensor_ids.deinit(self.allocator);
        part.timestamps.deinit(self.allocator);
        part.values.deinit(self.allocator);
        part.ts_deltas.deinit(self.allocator);
        part.sid_dict.deinit(self.allocator);
        part.sid_indices.deinit(self.allocator);
        part.val_deltas.deinit(self.allocator);
        part.granule_marks.deinit(self.allocator);
        part.granule_ts.deinit(self.allocator);
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
            .sensor_ids = .empty,
            .timestamps = .empty,
            .values = .empty,
            .sorted = true,
            .ts_deltas = .empty,
            .sid_dict = .empty,
            .sid_indices = .empty,
            .val_deltas = .empty,
            .compressed = true,
            .granule_marks = .empty,
            .granule_ts = .empty,
            .index_valid = true,
            .min_ts = reading.timestamp,
            .max_ts = reading.timestamp,
        };
    }
    const part = gop.value_ptr;
    try part.sensor_ids.append(self.allocator, reading.sensor_id);
    try part.timestamps.append(self.allocator, reading.timestamp);
    try part.values.append(self.allocator, reading.value);
    part.sorted = false;
    part.compressed = false;
    part.index_valid = false;
    if (reading.timestamp < part.min_ts) part.min_ts = reading.timestamp;
    if (reading.timestamp > part.max_ts) part.max_ts = reading.timestamp;
    self.total_count += 1;
    self.parts_merged = false;
    self.updateLatest(reading);
}

pub fn count(self: *const Self) usize {
    return self.total_count;
}

/// Reports the compressed footprint across all partitions. Timestamp
/// and value columns use delta+varint encoding; sensor_id uses dictionary
/// encoding; sensor_type is eliminated (implicit from partition key).
///
/// Disclosed tradeoff: this is a storage-cost proxy for what a real
/// column store persists to disk, NOT this benchmark's actual resident
/// RAM. The raw `sensor_ids`/`timestamps`/`values` ArrayLists (see
/// Partition above) stay fully allocated for every compressed part too —
/// `rangeByTime`/`iterateAll` scan those raw columns directly rather than
/// decoding `ts_deltas`/`sid_dict`/`val_deltas` on every query — so this
/// backend's actual in-process RAM is closer to TimeSeries's uncompressed
/// footprint than the number below suggests. Fine for comparing on-disk
/// storage cost across backends; not a live memory measurement for this
/// one.
pub fn memoryUsed(self: *const Self) usize {
    var total: usize = self.partitions.capacity() * (@sizeOf(PartitionKey) + @sizeOf(Partition));
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const part = entry.value_ptr;
        if (part.compressed) {
            total += part.ts_deltas.items.len; // compressed timestamps
            total += part.sid_dict.items.len * @sizeOf(u32); // dictionary
            total += part.sid_indices.items.len * @sizeOf(u16); // indices
            total += part.val_deltas.items.len; // compressed values
        } else {
            total += part.timestamps.capacity * @sizeOf(i64);
            total += part.sensor_ids.capacity * @sizeOf(u32);
            total += part.values.capacity * @sizeOf(f32);
        }
        total += part.granule_marks.items.len * @sizeOf(usize);
        total += part.granule_ts.items.len * @sizeOf(i64);
    }
    total += self.latest_by_sensor.capacity() * (@sizeOf(u32) + @sizeOf(SensorReading));
    return total + self.zone_index.memoryUsed();
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    try self_mut.mergeParts();

    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, self.total_count);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const part = entry.value_ptr;
        if (!part.sorted) self_mut.ensurePartitionSorted(part);
        const n = part.sensor_ids.items.len;
        for (0..n) |i| {
            try result.append(allocator, .{
                .sensor_id = part.sensor_ids.items[i],
                .timestamp = part.timestamps.items[i],
                .value = part.values.items[i],
                .sensor_type = key.sensor_type,
            });
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
    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    return self_mut.latest_by_sensor.get(sensor_id);
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
/// Scans only partitions overlapping the query time range, using the sparse
/// granule index to narrow to ~GRANULE_SIZE-row blocks before linear scan.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    if (q.start_time > q.end_time) return &.{};

    try self_mut.mergeParts();

    // When scoped to one sensor, narrow the partition scan to that
    // sensor's own type instead of paying ensurePartitionCompressed/
    // ensureGranuleIndex setup on every time-overlapping partition
    // regardless of type. A sensor's type is fixed across all its
    // readings, and latest_by_sensor already caches it. A sensor with no
    // resident readings (no entry here) has nothing to return.
    var only_type: ?SensorType = null;
    if (q.sensor_id) |sid| {
        if (self_mut.latest_dirty) self_mut.rebuildLatest();
        const latest = self.latest_by_sensor.get(sid) orelse return &.{};
        only_type = latest.sensor_type;
    }

    var result: std.ArrayList(SensorReading) = .empty;
    defer result.deinit(allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const part = entry.value_ptr;

        if (only_type) |t| {
            if (key.sensor_type != t) continue;
        }

        // Use min_ts/max_ts for pruning instead of day_index, so merged
        // parts spanning multiple days are correctly included.
        if (part.max_ts < q.start_time or part.min_ts > q.end_time) continue;

        if (!part.sorted) self_mut.ensurePartitionSorted(part);
        self_mut.ensurePartitionCompressed(part) catch {};
        self_mut.ensureGranuleIndex(part);

        const ts_items = part.timestamps.items;
        if (ts_items.len == 0) continue;

        // Sparse granule index: binary search on granule_ts to find the
        // starting granule, then linear scan from there.
        const lo = self_mut.granuleLowerBound(part, q.start_time);
        const hi = self_mut.granuleUpperBound(part, q.end_time);

        for (lo..hi) |i| {
            if (i >= ts_items.len) break;
            if (ts_items[i] < q.start_time) continue;
            if (ts_items[i] > q.end_time) break;
            if (q.sensor_id) |sid| {
                if (part.sensor_ids.items[i] != sid) continue;
            }
            try result.append(allocator, .{
                .sensor_id = part.sensor_ids.items[i],
                .timestamp = part.timestamps.items[i],
                .value = part.values.items[i],
                .sensor_type = key.sensor_type,
            });
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

/// Drops entire time-partitions of `sensor_type` that are fully older than
/// `cutoff_timestamp` — O(parts), not O(rows). Only the boundary partition
/// gets row-level compaction across all columns. See storage_backend.zig's
/// pruneOlderThan contract.
/// Columnar has no fixed-capacity concept — see aos_storage.zig's
/// setRetentionHint for why this is a no-op.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    var to_drop: std.ArrayList(PartitionKey) = .empty;
    defer to_drop.deinit(self.allocator);

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.sensor_type != sensor_type) continue;

        const part = entry.value_ptr;

        // Use min_ts/max_ts for pruning instead of day_index.
        if (part.max_ts < cutoff_timestamp) {
            // Entire part is older than cutoff — drop it.
            try to_drop.append(self.allocator, key);
            self.total_count -= part.sensor_ids.items.len;
        } else if (part.min_ts < cutoff_timestamp) {
            if (!part.sorted) self.ensurePartitionSorted(part);
            var write: usize = 0;
            for (part.sensor_ids.items, 0..) |_, i| {
                if (part.timestamps.items[i] < cutoff_timestamp) continue;
                part.sensor_ids.items[write] = part.sensor_ids.items[i];
                part.timestamps.items[write] = part.timestamps.items[i];
                part.values.items[write] = part.values.items[i];
                write += 1;
            }
            self.total_count -= part.sensor_ids.items.len - write;
            part.sensor_ids.shrinkRetainingCapacity(write);
            part.timestamps.shrinkRetainingCapacity(write);
            part.values.shrinkRetainingCapacity(write);
            part.compressed = false;
            part.index_valid = false;
            // Recompute min_ts after compaction.
            if (write > 0) {
                part.min_ts = part.timestamps.items[0];
                part.max_ts = part.timestamps.items[write - 1];
            }
        }
    }

    for (to_drop.items) |key| {
        if (self.partitions.fetchRemove(key)) |kv| {
            var part = kv.value;
            part.sensor_ids.deinit(self.allocator);
            part.timestamps.deinit(self.allocator);
            part.values.deinit(self.allocator);
            part.ts_deltas.deinit(self.allocator);
            part.sid_dict.deinit(self.allocator);
            part.sid_indices.deinit(self.allocator);
            part.val_deltas.deinit(self.allocator);
            part.granule_marks.deinit(self.allocator);
            part.granule_ts.deinit(self.allocator);
        }
    }

    self.latest_dirty = true;
    self.parts_merged = false;
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

    const self_mut: *Self = @constCast(self);
    if (self_mut.latest_dirty) self_mut.rebuildLatest();
    var it = self_mut.latest_by_sensor.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Internal — per-partition sort, compression & latest cache
// ---------------------------------------------------------------------------

const SortCtx = struct {
    timestamps: []const i64,
    sensor_ids: []const u32,
};

fn ensurePartitionSorted(self: *Self, part: *Partition) void {
    if (part.sorted) return;

    const n = part.sensor_ids.items.len;
    if (n <= 1) {
        part.sorted = true;
        return;
    }

    const idx = self.allocator.alloc(usize, n) catch return;
    defer self.allocator.free(idx);
    for (0..n) |i| idx[i] = i;

    const ctx = SortCtx{
        .timestamps = part.timestamps.items,
        .sensor_ids = part.sensor_ids.items,
    };
    std.mem.sort(usize, idx, ctx, struct {
        fn lt(c: SortCtx, lhs: usize, rhs: usize) bool {
            const lt_ts = c.timestamps[lhs];
            const rt_ts = c.timestamps[rhs];
            if (lt_ts != rt_ts) return lt_ts < rt_ts;
            return c.sensor_ids[lhs] < c.sensor_ids[rhs];
        }
    }.lt);

    permuteColumn(u32, self.allocator, part.sensor_ids.items, idx) catch return;
    permuteColumn(i64, self.allocator, part.timestamps.items, idx) catch return;
    permuteColumn(f32, self.allocator, part.values.items, idx) catch return;

    part.sorted = true;
    part.compressed = false;
    part.index_valid = false;
}

fn permuteColumn(comptime T: type, allocator: std.mem.Allocator, items: []T, idx: []const usize) !void {
    const tmp = try allocator.alloc(T, items.len);
    defer allocator.free(tmp);
    for (0..items.len) |i| {
        tmp[i] = items[idx[i]];
    }
    @memcpy(items, tmp);
}

/// Compresses all columns: timestamps (delta+varint), sensor_ids
/// (dictionary), values (delta+varint on bit-cast). Called lazily by
/// rangeByTime and iterateAll.
fn ensurePartitionCompressed(self: *Self, part: *Partition) !void {
    if (part.compressed) return;

    // Timestamps: delta + zigzag + varint.
    part.ts_deltas.clearRetainingCapacity();
    var prev_ts: i64 = 0;
    for (part.timestamps.items) |ts| {
        const delta = ts -% prev_ts;
        try appendVarint(self.allocator, &part.ts_deltas, zigzagEncode(delta));
        prev_ts = ts;
    }

    // Sensor IDs: dictionary encoding.
    part.sid_dict.clearRetainingCapacity();
    part.sid_indices.clearRetainingCapacity();
    for (part.sensor_ids.items) |sid| {
        const dict_idx = try sb.dictionaryIndex(self.allocator, &part.sid_dict, sid);
        try part.sid_indices.append(self.allocator, dict_idx);
    }

    // Values: delta + zigzag + varint on bit-cast f32->i32->u32.
    part.val_deltas.clearRetainingCapacity();
    var prev_bits: u32 = 0;
    for (part.values.items) |val| {
        const bits: u32 = @bitCast(val);
        const delta: i32 = @bitCast(bits -% prev_bits);
        try appendVarint(self.allocator, &part.val_deltas, zigzagEncode(delta));
        prev_bits = bits;
    }

    part.compressed = true;
}

fn updateLatest(self: *Self, reading: SensorReading) void {
    if (self.latest_dirty) return;
    if (self.latest_by_sensor.get(reading.sensor_id)) |current| {
        if (reading.timestamp > current.timestamp) {
            self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
        }
    } else {
        self.latest_by_sensor.put(reading.sensor_id, reading) catch {};
    }
}

fn rebuildLatest(self: *Self) void {
    self.latest_by_sensor.clearRetainingCapacity();
    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const part = entry.value_ptr;
        for (0..part.sensor_ids.items.len) |i| {
            const sid = part.sensor_ids.items[i];
            const ts = part.timestamps.items[i];
            if (self.latest_by_sensor.get(sid)) |current| {
                if (ts > current.timestamp) {
                    self.latest_by_sensor.put(sid, .{
                        .sensor_id = sid,
                        .timestamp = ts,
                        .value = part.values.items[i],
                        .sensor_type = key.sensor_type,
                    }) catch {};
                }
            } else {
                self.latest_by_sensor.put(sid, .{
                    .sensor_id = sid,
                    .timestamp = ts,
                    .value = part.values.items[i],
                    .sensor_type = key.sensor_type,
                }) catch {};
            }
        }
    }
    self.latest_dirty = false;
}

// ---------------------------------------------------------------------------
// Internal — sparse granule index (ClickHouse primary index)
// ---------------------------------------------------------------------------

/// Builds the sparse granule index: one entry per GRANULE_SIZE rows,
/// storing the row index and first timestamp of each granule. This is
/// ClickHouse's "skip index" — binary searching it narrows to a
/// ~8192-row block before a linear scan finds the exact range.
fn ensureGranuleIndex(self: *Self, part: *Partition) void {
    if (part.index_valid) return;
    part.granule_marks.clearRetainingCapacity();
    part.granule_ts.clearRetainingCapacity();

    const n = part.timestamps.items.len;
    const num_granules = (n + GRANULE_SIZE - 1) / GRANULE_SIZE;
    part.granule_marks.ensureTotalCapacity(self.allocator, num_granules) catch return;
    part.granule_ts.ensureTotalCapacity(self.allocator, num_granules) catch return;

    var i: usize = 0;
    while (i < n) {
        part.granule_marks.appendAssumeCapacity(i);
        part.granule_ts.appendAssumeCapacity(part.timestamps.items[i]);
        i += GRANULE_SIZE;
    }
    part.index_valid = true;
}

/// Binary search on granule_ts to find the first row that could contain
/// `start_time`. Returns the row index of the granule start.
fn granuleLowerBound(self: *Self, part: *Partition, start_time: i64) usize {
    _ = self;
    if (part.granule_ts.items.len == 0) return 0;

    const g_lo = std.sort.lowerBound(i64, part.granule_ts.items, start_time, struct {
        fn cmp(ctx: i64, item: i64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.cmp);

    if (g_lo == 0) return 0;
    return part.granule_marks.items[g_lo - 1];
}

/// Binary search on granule_ts to find the upper bound row for `end_time`.
/// Returns one past the last row that could contain `end_time`.
fn granuleUpperBound(self: *Self, part: *Partition, end_time: i64) usize {
    _ = self;
    const n = part.timestamps.items.len;
    if (n == 0) return 0;

    const g_hi = std.sort.upperBound(i64, part.granule_ts.items, end_time, struct {
        fn cmp(ctx: i64, item: i64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.cmp);

    if (g_hi >= part.granule_marks.items.len) return n;
    return part.granule_marks.items[g_hi] + GRANULE_SIZE;
}

// ---------------------------------------------------------------------------
// Internal — part merging (ClickHouse background merge)
// ---------------------------------------------------------------------------

/// Merges small adjacent day-partitions for the same sensor_type into
/// larger parts. ClickHouse does this in the background to keep the part
/// count bounded — without merging, daily partitions would grow unboundedly.
/// We do it lazily before queries that span multiple partitions.
fn mergeParts(self: *Self) !void {
    if (self.parts_merged) return;

    // Collect partitions by sensor_type, sorted by day_index.
    var by_type: std.AutoHashMap(SensorType, std.ArrayList(PartitionKey)) = .init(self.allocator);
    defer {
        var dit = by_type.iterator();
        while (dit.next()) |e| e.value_ptr.deinit(self.allocator);
        by_type.deinit();
    }

    var it = self.partitions.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const gop = try by_type.getOrPut(key.sensor_type);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, key);
    }

    // For each sensor_type, try merging adjacent small partitions.
    var tit = by_type.iterator();
    while (tit.next()) |type_entry| {
        const keys_arr = type_entry.value_ptr;
        if (keys_arr.items.len < 2) continue;

        std.mem.sort(PartitionKey, keys_arr.items, {}, struct {
            fn lt(_: void, lhs: PartitionKey, rhs: PartitionKey) bool {
                return lhs.day_index < rhs.day_index;
            }
        }.lt);

        var i: usize = 0;
        while (i < keys_arr.items.len) {
            const keys = keys_arr.items;
            const part_a = self.partitions.getPtr(keys[i]).?;
            if (part_a.sensor_ids.items.len >= MERGE_THRESHOLD) {
                i += 1;
                continue;
            }

            // Try to merge with the next adjacent partition.
            if (i + 1 >= keys.len) break;
            const part_b = self.partitions.getPtr(keys[i + 1]).?;
            const combined = part_a.sensor_ids.items.len + part_b.sensor_ids.items.len;
            if (combined > MERGE_THRESHOLD * 2) {
                i += 1;
                continue;
            }

            // Merge b into a, then remove b.
            try part_a.sensor_ids.appendSlice(self.allocator, part_b.sensor_ids.items);
            try part_a.timestamps.appendSlice(self.allocator, part_b.timestamps.items);
            try part_a.values.appendSlice(self.allocator, part_b.values.items);
            part_a.sorted = false;
            part_a.compressed = false;
            part_a.index_valid = false;
            // Update min_ts/max_ts to cover the merged range.
            if (part_b.min_ts < part_a.min_ts) part_a.min_ts = part_b.min_ts;
            if (part_b.max_ts > part_a.max_ts) part_a.max_ts = part_b.max_ts;

            // Remove part_b.
            if (self.partitions.fetchRemove(keys[i + 1])) |kv| {
                var pb = kv.value;
                pb.sensor_ids.deinit(self.allocator);
                pb.timestamps.deinit(self.allocator);
                pb.values.deinit(self.allocator);
                pb.ts_deltas.deinit(self.allocator);
                pb.sid_dict.deinit(self.allocator);
                pb.sid_indices.deinit(self.allocator);
                pb.val_deltas.deinit(self.allocator);
                pb.granule_marks.deinit(self.allocator);
                pb.granule_ts.deinit(self.allocator);
            }

            // Remove the merged key from the keys array.
            _ = type_entry.value_ptr.orderedRemove(i + 1);

            // Don't advance i — the merged part might still be small enough
            // to merge with the next one.
        }
    }

    self.parts_merged = true;
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
