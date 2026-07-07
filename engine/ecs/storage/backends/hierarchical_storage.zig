// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Hierarchical backend — data indexed by a zone tree
// (Floor → Zone → Sensor) via parent-child links.
//
// Models a graph database (e.g. Neo4j): readings are stored as properties
// on per-sensor leaf nodes of a tree index. The zone-hierarchy query (Q10)
// traverses the tree to collect sensors from a subtree directly (e.g. "all
// sensors on floor 2") via `sensorIdsByZone`/`sensorIdsByFloor`, instead of
// scanning every reading — matching Neo4j's graph traversal for topology
// queries.
//
// Time-series queries use a temporal property index: each leaf's readings
// are kept in a single ArrayList sorted by timestamp ascending on insert.
// This mirrors how real graph databases maintain a sorted temporal index
// per node (e.g. Neo4j's native range index or a relational B-tree index on
// a sensor's time-series property). `rangeByTime` with a sensor filter
// binary-searches the sorted array for the time range. `pruneOlderThan`
// binary-searches for the cutoff timestamp, then compacts the prefix —
// O(log n) to find the boundary plus O(k) to compact.
//
// The tree is an internal detail invisible to queries — the public
// surface is exactly the StorageBackend interface. The tree makes
// per-sensor lookups O(1) (hash map from sensor_id to leaf node) and
// `sensorIdsByZone`/`sensorIdsByFloor` O(zone/floor subtree size) instead
// of O(num_readings).
//
// Zone/floor placement is REAL topology, not sensor_id arithmetic: a
// sensor's zone comes from `registerZone` (called once, mirroring
// sensor_placer.zig's ZoneLocation for a real building, or a synthetic
// equivalent for benchmark fixtures), and a zone's floor comes from
// `registerFloor` (mirroring ZoneMetadata.floor_level). There is
// deliberately no arithmetic relationship assumed between sensor_id and
// zone_id anywhere in this file — a real building's zones hold a variable
// number of sensors with arbitrary ids (the source IFC entity id), not a
// fixed-width block. (An earlier version of this file derived zone/floor
// from `sensor_id / 5` / `sensor_id / 10`, duplicated from
// engine/benchmark/dataset.zig's synthetic fixture — that only ever
// matched the benchmark's own made-up topology, never a real building's.)
//
// `insert` doesn't need to know a sensor's zone: a sensor with no
// registration yet gets a leaf parented under `unassigned_zone` (itself
// under root), and `registerZone`/`registerFloor` re-parent nodes into
// the right place whenever they're called, in either order, relative to
// `insert`.
//
// Iteration order: sorted by (timestamp asc, sensor_id asc). Each leaf is
// kept sorted by timestamp on insert, and `iterateAll` / no-sensor-filter
// `rangeByTime` merge the leaf arrays on demand instead of maintaining a
// duplicate sorted cache of the entire dataset.

const std = @import("std");
const sb = @import("../storage_backend.zig");

const SensorReading = sb.SensorReading;
const SensorType = sb.SensorType;
const RangeQuery = sb.RangeQuery;

const Self = @This();

// Tree node — represents a Floor, a Zone, or a Sensor leaf, or one of the
// two "unassigned" catch-all buckets. Internal only; never exposed
// through the interface. `key` means: for a Floor node, its floor_id; for
// a Zone node, its zone_id; for a Sensor leaf, its sensor_id. Unused
// (0) for root and the two unassigned buckets, which are found via
// dedicated fields, never by key lookup.
const Node = struct {
    parent: ?u32,
    children: std.ArrayList(u32),
    /// ArrayList of readings for leaf nodes, kept sorted by timestamp
    /// ascending on insert. All readings in a leaf share the same sensor_id,
    /// so the sort key is effectively timestamp; the global (timestamp,
    /// sensor_id) order is produced by merging leaves on demand. Null for
    /// non-leaf nodes.
    readings: ?std.ArrayList(SensorReading),
    sensor_id: ?u32,
    key: u32,
    /// Latest reading by timestamp for this leaf, maintained incrementally
    /// on insert (same pattern ringbuffer_storage.zig's SensorBuffer.latest
    /// already uses) so getLatestBySensor is O(1) instead of O(readings on
    /// this leaf). Null for non-leaf nodes.
    latest: ?SensorReading,
};

allocator: std.mem.Allocator,
nodes: std.ArrayList(Node),
sensor_to_node: std.AutoHashMap(u32, u32),
/// zone_id -> node index, for direct (non-scanning) lookup in registerZone
/// and sensorIdsByZone.
zone_to_node: std.AutoHashMap(u32, u32),
/// floor_id -> node index, same purpose for floors.
floor_to_node: std.AutoHashMap(u32, u32),
root: u32,
/// Holds leaves for sensors that have been inserted but never registered
/// to a zone via registerZone.
unassigned_zone: u32,
/// Holds zone nodes that have been created (via registerZone) but never
/// registered to a floor via registerFloor.
unassigned_floor: u32,
total_count: usize,

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{
        .allocator = allocator,
        .nodes = .empty,
        .sensor_to_node = std.AutoHashMap(u32, u32).init(allocator),
        .zone_to_node = std.AutoHashMap(u32, u32).init(allocator),
        .floor_to_node = std.AutoHashMap(u32, u32).init(allocator),
        .root = 0,
        .unassigned_zone = 0,
        .unassigned_floor = 0,
        .total_count = 0,
    };

    try self.nodes.append(allocator, emptyNode(null, 0));
    self.root = 0;

    try self.nodes.append(allocator, emptyNode(self.root, 0));
    self.unassigned_floor = 1;
    try self.nodes.items[self.root].children.append(allocator, self.unassigned_floor);

    try self.nodes.append(allocator, emptyNode(self.root, 0));
    self.unassigned_zone = 2;
    try self.nodes.items[self.root].children.append(allocator, self.unassigned_zone);

    return self;
}

fn emptyNode(parent: ?u32, key: u32) Node {
    return .{
        .parent = parent,
        .children = .empty,
        .readings = null,
        .sensor_id = null,
        .key = key,
        .latest = null,
    };
}

pub fn deinit(self: *Self) void {
    for (self.nodes.items) |*node| {
        node.children.deinit(self.allocator);
        if (node.readings) |*r| {
            r.deinit(self.allocator);
        }
    }
    self.nodes.deinit(self.allocator);
    self.sensor_to_node.deinit();
    self.zone_to_node.deinit();
    self.floor_to_node.deinit();
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    const leaf_idx = try self.ensureLeaf(reading.sensor_id);
    const node = &self.nodes.items[leaf_idx];
    if (node.readings == null) {
        node.readings = .empty;
    }
    const readings = &node.readings.?;

    // Keep the leaf's readings sorted by timestamp on every insert. For the
    // live feed this is O(1) append because timestamps are monotonic per
    // sensor; out-of-order inserts pay O(n) to shift. This mirrors how real
    // graph/zone-tree databases maintain a temporal index per node, rather
    // than deferring a full sort until a query runs.
    if (readings.items.len == 0 or
        reading.timestamp >= readings.items[readings.items.len - 1].timestamp)
    {
        try readings.append(self.allocator, reading);
    } else {
        const idx = std.sort.upperBound(SensorReading, readings.items, reading.timestamp, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);
        try readings.insert(self.allocator, idx, reading);
    }

    if (node.latest == null or reading.timestamp > node.latest.?.timestamp) {
        node.latest = reading;
    }
    self.total_count += 1;
}

pub fn count(self: *const Self) usize {
    return self.total_count;
}

pub fn memoryUsed(self: *const Self) usize {
    var total: usize = self.nodes.capacity * @sizeOf(Node);
    for (self.nodes.items) |node| {
        total += node.children.capacity * @sizeOf(u32);
        if (node.readings) |r| {
            total += r.capacity * @sizeOf(SensorReading);
        }
    }
    total += self.sensor_to_node.capacity() * (@sizeOf(u32) + @sizeOf(u32));
    total += self.zone_to_node.capacity() * (@sizeOf(u32) + @sizeOf(u32));
    total += self.floor_to_node.capacity() * (@sizeOf(u32) + @sizeOf(u32));
    return total;
}

/// Merge the sorted per-sensor readings arrays into a single (timestamp asc,
/// sensor_id asc) sorted slice. Instead of maintaining a duplicate sorted
/// cache of the entire dataset, we merge the already-sorted leaves on demand.
/// `filter`, when non-null, restricts the merge to a timestamp range.
///
/// Heap-based k-way merge — O(n log k) for n output readings across k
/// leaves, the same merging-iterator structure every real multi-sorted-
/// source engine uses (LSM-tree SSTable reads in RocksDB/Cassandra,
/// InfluxDB TSM block merges, Prometheus/ClickHouse part merges). An
/// earlier version rescanned every cursor linearly per output row —
/// O(n × k), ~3.3 billion comparisons for a 7-day hospital-scale window —
/// which models no real engine and buried the layout's honest merge cost
/// under a quadratic implementation artifact. The merge itself is still
/// deliberately paid here (per-sensor partitioning means global
/// time-ordered scans cost a merge that a time-ordered log gets for free —
/// that's this layout's true tradeoff, per CLAUDE.md §6).
fn mergeAllLeaves(
    self: *const Self,
    allocator: std.mem.Allocator,
    filter: ?struct { start_time: i64, end_time: i64 },
) ![]const SensorReading {
    var result: std.ArrayList(SensorReading) = .empty;
    errdefer result.deinit(allocator);

    // Heap entries carry the cursor's current reading inline so the
    // comparator never chases node/readings pointers.
    const Cursor = struct {
        current: SensorReading,
        node_idx: u32,
        pos: usize,
        end: usize,
    };
    const lessThan = struct {
        fn cmp(_: void, a: Cursor, b: Cursor) std.math.Order {
            if (a.current.timestamp != b.current.timestamp)
                return std.math.order(a.current.timestamp, b.current.timestamp);
            return std.math.order(a.current.sensor_id, b.current.sensor_id);
        }
    }.cmp;
    const Heap = std.PriorityQueue(Cursor, void, lessThan);

    var heap: Heap = .empty;
    defer heap.deinit(allocator);

    var total: usize = 0;
    for (self.nodes.items, 0..) |node, i| {
        if (node.sensor_id == null) continue;
        const readings = node.readings orelse continue;
        if (readings.items.len == 0) continue;

        var start: usize = 0;
        var end: usize = readings.items.len;

        if (filter) |f| {
            if (readings.items[end - 1].timestamp < f.start_time or readings.items[0].timestamp > f.end_time) {
                continue;
            }
            start = std.sort.lowerBound(SensorReading, readings.items, f.start_time, struct {
                fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                    return std.math.order(ctx, item.timestamp);
                }
            }.cmp);
            end = std.sort.upperBound(SensorReading, readings.items, f.end_time, struct {
                fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                    return std.math.order(ctx, item.timestamp);
                }
            }.cmp);
            if (start >= end) continue;
        }

        total += end - start;
        try heap.push(allocator, .{
            .current = readings.items[start],
            .node_idx = @intCast(i),
            .pos = start,
            .end = end,
        });
    }

    try result.ensureTotalCapacity(allocator, total);

    while (heap.pop()) |cursor| {
        result.appendAssumeCapacity(cursor.current);
        const next_pos = cursor.pos + 1;
        if (next_pos < cursor.end) {
            try heap.push(allocator, .{
                .current = self.nodes.items[cursor.node_idx].readings.?.items[next_pos],
                .node_idx = cursor.node_idx,
                .pos = next_pos,
                .end = cursor.end,
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    return self.mergeAllLeaves(allocator, null);
}

/// O(1): the leaf's `latest` field is maintained incrementally on insert.
pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const node_idx = self.sensor_to_node.get(sensor_id) orelse return null;
    return self.nodes.items[node_idx].latest;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    if (q.start_time > q.end_time) return &.{};

    if (q.sensor_id) |sid| {
        // Single-sensor filter: go straight to that leaf, binary-search
        // the sorted array for the time range. The array is kept sorted by
        // timestamp on insert, so no lazy sort is needed.
        const node_idx = self.sensor_to_node.get(sid) orelse return &.{};
        const node = &self.nodes.items[node_idx];
        const readings = node.readings orelse return &.{};
        const items = readings.items;
        if (items.len == 0) return &.{};

        const lo = std.sort.lowerBound(SensorReading, items, q.start_time, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);
        const hi = std.sort.upperBound(SensorReading, items, q.end_time, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);

        const result = try allocator.alloc(SensorReading, hi - lo);
        @memcpy(result, items[lo..hi]);
        return result;
    }

    // No sensor filter: merge the per-sensor sorted arrays, restricted to
    // the requested time range. No duplicate global cache is maintained.
    return self.mergeAllLeaves(allocator, .{ .start_time = q.start_time, .end_time = q.end_time });
}

/// See storage_backend.zig's doc comment for the contract. Creates the
/// sensor's leaf if it doesn't exist yet (registerZone may run before any
/// insert for that sensor), then re-parents it under the zone node
/// (creating that too if needed, initially under unassigned_floor until
/// registerFloor names its real floor).
pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
    const leaf_idx = try self.ensureLeaf(sensor_id);
    const zone_idx = try self.ensureZoneNode(zone_id);
    try self.reparent(leaf_idx, zone_idx);
}

/// See storage_backend.zig's doc comment for the contract. One call per
/// zone (not per sensor) — re-parents the zone node under the floor node.
pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
    const zone_idx = try self.ensureZoneNode(zone_id);
    const floor_idx = try self.ensureFloorNode(floor_id);
    try self.reparent(zone_idx, floor_idx);
}

pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
    const zone_idx = self.zone_to_node.get(zone_id) orelse return null;
    const floor_node = self.nodes.items[zone_idx].parent orelse return null;
    if (floor_node == self.unassigned_floor) return null;
    return self.nodes.items[floor_node].key;
}

/// Prunes readings of `sensor_type` older than `cutoff_timestamp` from
/// every leaf. Uses binary search on the sorted array to find the cutoff
/// point, then compacts the prefix — O(log n) to find the boundary plus
/// O(k) to shift surviving readings, where k is bounded by that one
/// sensor's own reading count. `latest` is recomputed from surviving
/// readings only if the previous latest was itself pruned. Tree structure,
/// zone/floor topology, and `sensor_to_node`/`zone_to_node`/`floor_to_node`
/// are untouched. See storage_backend.zig's pruneOlderThan contract.
/// Hierarchical has no fixed-capacity concept — see aos_storage.zig's
/// setRetentionHint for why this is a no-op.
pub fn setRetentionHint(_: *Self, _: SensorType, _: usize) !void {}

pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    for (self.nodes.items) |*node| {
        if (node.readings == null) continue;
        const readings = &node.readings.?;

        // The leaf's readings are already sorted by timestamp on insert, so
        // we can binary search for the cutoff directly.
        const cutoff_idx = std.sort.lowerBound(SensorReading, readings.items, cutoff_timestamp, struct {
            fn cmp(ctx: i64, item: SensorReading) std.math.Order {
                return std.math.order(ctx, item.timestamp);
            }
        }.cmp);

        if (cutoff_idx == 0) continue; // Nothing to prune.

        // Count how many of the pruned prefix matches sensor_type.
        var pruned: usize = 0;
        var write: usize = 0;
        for (readings.items[0..cutoff_idx]) |r| {
            if (r.sensor_type == sensor_type) {
                pruned += 1;
            } else {
                readings.items[write] = r;
                write += 1;
            }
        }

        // Shift surviving readings from after the cutoff.
        for (readings.items[cutoff_idx..]) |r| {
            readings.items[write] = r;
            write += 1;
        }

        if (pruned == 0) continue;
        readings.shrinkRetainingCapacity(write);
        self.total_count -= pruned;

        // Recompute latest if the current latest was pruned.
        if (node.latest) |latest| {
            if (latest.sensor_type == sensor_type and latest.timestamp < cutoff_timestamp) {
                var new_latest: ?SensorReading = null;
                for (readings.items) |r| {
                    if (new_latest == null or r.timestamp > new_latest.?.timestamp) {
                        new_latest = r;
                    }
                }
                node.latest = new_latest;
            }
        }
    }
}

/// Walks straight to the zone node (O(1) hashmap lookup) and collects its
/// leaf sensor_ids — never touches nodes outside that subtree.
pub fn sensorIdsByZone(self: *const Self, allocator: std.mem.Allocator, zone_id: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    if (self.zone_to_node.get(zone_id)) |zone_idx| {
        try self.collectLeafSensorIds(zone_idx, &result, allocator);
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Walks straight to the floor node and collects every leaf under every
/// zone parented to it.
pub fn sensorIdsByFloor(self: *const Self, allocator: std.mem.Allocator, floor_id: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    if (self.floor_to_node.get(floor_id)) |floor_idx| {
        try self.collectLeafSensorIds(floor_idx, &result, allocator);
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

fn collectLeafSensorIds(self: *const Self, node_idx: u32, out: *std.ArrayList(u32), allocator: std.mem.Allocator) !void {
    const node = &self.nodes.items[node_idx];
    if (node.sensor_id) |sid| {
        try out.append(allocator, sid);
        return;
    }
    for (node.children.items) |child_idx| {
        try self.collectLeafSensorIds(child_idx, out, allocator);
    }
}

/// Every distinct sensor_id that has ever been registered, sorted ascending.
/// Uses sensor_to_node's keys — no tree walk or reading scan needed.
pub fn allSensorIds(self: *const Self, allocator: std.mem.Allocator) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.sensor_to_node.keyIterator();
    while (it.next()) |k| try result.append(allocator, k.*);

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Internal — tree node management
// ---------------------------------------------------------------------------

fn ensureLeaf(self: *Self, sensor_id: u32) !u32 {
    if (self.sensor_to_node.get(sensor_id)) |idx| return idx;

    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .parent = self.unassigned_zone,
        .children = .empty,
        .readings = null,
        .sensor_id = sensor_id,
        .key = sensor_id,
        .latest = null,
    });
    try self.nodes.items[self.unassigned_zone].children.append(self.allocator, idx);
    try self.sensor_to_node.put(sensor_id, idx);
    return idx;
}

fn ensureZoneNode(self: *Self, zone_id: u32) !u32 {
    if (self.zone_to_node.get(zone_id)) |idx| return idx;

    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, emptyNode(self.unassigned_floor, zone_id));
    try self.nodes.items[self.unassigned_floor].children.append(self.allocator, idx);
    try self.zone_to_node.put(zone_id, idx);
    return idx;
}

fn ensureFloorNode(self: *Self, floor_id: u32) !u32 {
    if (self.floor_to_node.get(floor_id)) |idx| return idx;

    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, emptyNode(self.root, floor_id));
    try self.nodes.items[self.root].children.append(self.allocator, idx);
    try self.floor_to_node.put(floor_id, idx);
    return idx;
}

fn removeChild(self: *Self, parent_idx: u32, child_idx: u32) void {
    const children = &self.nodes.items[parent_idx].children;
    for (children.items, 0..) |c, i| {
        if (c == child_idx) {
            _ = children.swapRemove(i);
            return;
        }
    }
}

/// Moves `child_idx` from its current parent (if any) to `new_parent_idx`.
/// No-op if it's already there.
fn reparent(self: *Self, child_idx: u32, new_parent_idx: u32) !void {
    const old_parent = self.nodes.items[child_idx].parent;
    if (old_parent) |op| {
        if (op == new_parent_idx) return;
        self.removeChild(op, child_idx);
    }
    self.nodes.items[child_idx].parent = new_parent_idx;
    try self.nodes.items[new_parent_idx].children.append(self.allocator, child_idx);
}

// ---------------------------------------------------------------------------
// Tests — written fresh against the current implementation (2026-07-04),
// specifically covering the heap-based mergeAllLeaves rewrite (the k-way
// merge across per-sensor leaves that iterateAll and unfiltered rangeByTime
// depend on for global ordering).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mk(sensor_id: u32, ts: i64, value: f32) SensorReading {
    return .{ .sensor_id = sensor_id, .timestamp = ts, .value = value, .sensor_type = .temperature };
}

test "mergeAllLeaves: interleaved multi-sensor timelines merge into exact (timestamp, sensor_id) order" {
    var s = try Self.init(testing.allocator);
    defer s.deinit();

    // Three sensors with deliberately interleaved and tie-heavy timelines:
    // sensor 30's t=100 ties sensor 10's t=100 (sensor_id must break the
    // tie), and each leaf's internal order differs from the global order.
    try s.insert(mk(10, 100, 1.0));
    try s.insert(mk(10, 400, 2.0));
    try s.insert(mk(20, 200, 3.0));
    try s.insert(mk(20, 500, 4.0));
    try s.insert(mk(30, 100, 5.0));
    try s.insert(mk(30, 300, 6.0));

    const all = try s.iterateAll(testing.allocator);
    defer testing.allocator.free(all);

    const expected = [_]SensorReading{
        mk(10, 100, 1.0), // ts 100: sensor 10 before 30
        mk(30, 100, 5.0),
        mk(20, 200, 3.0),
        mk(30, 300, 6.0),
        mk(10, 400, 2.0),
        mk(20, 500, 4.0),
    };
    try testing.expectEqual(expected.len, all.len);
    for (all, expected) |got, want| {
        try testing.expectEqual(want.sensor_id, got.sensor_id);
        try testing.expectEqual(want.timestamp, got.timestamp);
        try testing.expectEqual(want.value, got.value);
    }
}

test "mergeAllLeaves: unfiltered rangeByTime window cuts each leaf at exact boundaries (inclusive)" {
    var s = try Self.init(testing.allocator);
    defer s.deinit();

    try s.insert(mk(1, 100, 1.0));
    try s.insert(mk(1, 200, 2.0));
    try s.insert(mk(1, 300, 3.0));
    try s.insert(mk(2, 150, 4.0));
    try s.insert(mk(2, 250, 5.0));
    try s.insert(mk(2, 350, 6.0));

    // [200, 300] inclusive on both ends: must include 200 and 300 exactly,
    // exclude 150 and 350 — off-by-one at either boundary fails this.
    const window = try s.rangeByTime(testing.allocator, .{ .sensor_id = null, .start_time = 200, .end_time = 300 });
    defer testing.allocator.free(window);

    const expected = [_]SensorReading{ mk(1, 200, 2.0), mk(2, 250, 5.0), mk(1, 300, 3.0) };
    try testing.expectEqual(expected.len, window.len);
    for (window, expected) |got, want| {
        try testing.expectEqual(want.sensor_id, got.sensor_id);
        try testing.expectEqual(want.timestamp, got.timestamp);
    }
}

test "mergeAllLeaves: merge output matches a reference sort of the same readings at scale" {
    var s = try Self.init(testing.allocator);
    defer s.deinit();

    // 40 sensors x 50 readings with pseudo-random timestamps (including
    // cross-sensor ties) — enough cursors that heap sift-up/down paths and
    // cursor-exhaustion re-push logic all get exercised, unlike the tiny
    // hand-built cases above.
    var reference: std.ArrayList(SensorReading) = .empty;
    defer reference.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var sid: u32 = 0;
    while (sid < 40) : (sid += 1) {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            const reading = mk(sid, rand.intRangeAtMost(i64, 0, 999), rand.float(f32));
            try s.insert(reading);
            try reference.append(testing.allocator, reading);
        }
    }

    std.mem.sort(SensorReading, reference.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    const all = try s.iterateAll(testing.allocator);
    defer testing.allocator.free(all);

    try testing.expectEqual(reference.items.len, all.len);
    for (all, reference.items) |got, want| {
        try testing.expectEqual(want.timestamp, got.timestamp);
        try testing.expectEqual(want.sensor_id, got.sensor_id);
    }
}

// ---------------------------------------------------------------------------
