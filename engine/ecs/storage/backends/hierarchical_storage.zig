// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Hierarchical backend — data indexed by a zone tree
// (Floor → Zone → Sensor) via parent-child links.
//
// Models graph-db behaviour: readings are stored in per-sensor leaf
// nodes of a tree index. The zone-hierarchy query (Q10) traverses the
// tree to collect sensors from a subtree directly (e.g. "all sensors on
// floor 2") via `sensorIdsByZone`/`sensorIdsByFloor`, instead of scanning
// every reading.
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
// Iteration order: sorted by (timestamp asc, sensor_id asc). The sorted
// view is cached and only rebuilt when `insert` has run since the last
// build (`cache_valid = false`) — earlier versions of this file re-walked
// the whole tree AND re-sorted on every single iterateAll/rangeByTime
// call, which made every multi-sensor query 10-80x slower than a flat
// backend at scale even though the underlying data hadn't changed.

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

/// Flattened, timestamp-sorted view of every reading — rebuilt lazily by
/// `ensureCache` only when `cache_valid` is false. Backs iterateAll and
/// the no-sensor-filter branch of rangeByTime so repeated calls against a
/// static dataset (the shape every benchmark loop takes) don't re-walk
/// and re-sort the whole tree every time.
sorted_cache: std.ArrayList(SensorReading),
cache_valid: bool,

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
        .sorted_cache = .empty,
        .cache_valid = true,
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
    self.sorted_cache.deinit(self.allocator);
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    const leaf_idx = try self.ensureLeaf(reading.sensor_id);
    const node = &self.nodes.items[leaf_idx];
    if (node.readings == null) {
        node.readings = .empty;
    }
    try node.readings.?.append(self.allocator, reading);
    if (node.latest == null or reading.timestamp > node.latest.?.timestamp) {
        node.latest = reading;
    }
    self.total_count += 1;
    self.cache_valid = false;
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
    total += self.sorted_cache.capacity * @sizeOf(SensorReading);
    return total;
}

/// Rebuilds `sorted_cache` from the tree if `insert` has run since the
/// last build. No-op otherwise — repeated calls against a static dataset
/// (the shape every benchmark loop takes) pay the walk+sort cost once.
fn ensureCache(self: *Self) !void {
    if (self.cache_valid) return;

    self.sorted_cache.clearRetainingCapacity();
    for (self.nodes.items) |node| {
        if (node.readings) |r| {
            try self.sorted_cache.appendSlice(self.allocator, r.items);
        }
    }

    std.mem.sort(SensorReading, self.sorted_cache.items, {}, struct {
        fn lt(_: void, lhs: SensorReading, rhs: SensorReading) bool {
            if (lhs.timestamp != rhs.timestamp) return lhs.timestamp < rhs.timestamp;
            return lhs.sensor_id < rhs.sensor_id;
        }
    }.lt);

    self.cache_valid = true;
}

/// Iteration order: sorted by (timestamp asc, sensor_id asc).
pub fn iterateAll(self: *const Self, allocator: std.mem.Allocator) ![]const SensorReading {
    const self_mut: *Self = @constCast(self);
    try self_mut.ensureCache();

    const result = try allocator.alloc(SensorReading, self.sorted_cache.items.len);
    @memcpy(result, self.sorted_cache.items);
    return result;
}

/// O(1): the leaf's `latest` field is maintained incrementally on insert.
pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?SensorReading {
    const node_idx = self.sensor_to_node.get(sensor_id) orelse return null;
    return self.nodes.items[node_idx].latest;
}

/// Results ordered by timestamp ascending, ties broken by sensor_id ascending.
pub fn rangeByTime(self: *const Self, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading {
    if (q.sensor_id) |sid| {
        // Single-sensor filter: go straight to that leaf, never touch the
        // rest of the tree or the cache.
        var result: std.ArrayList(SensorReading) = .empty;
        defer result.deinit(allocator);

        const node_idx = self.sensor_to_node.get(sid) orelse return &.{};
        const readings = self.nodes.items[node_idx].readings orelse return &.{};
        for (readings.items) |r| {
            if (r.timestamp >= q.start_time and r.timestamp <= q.end_time) {
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

    // No sensor filter — binary-search the cached sorted view instead of
    // re-walking + re-sorting the whole tree (same pattern timeseries
    // and columnar storage already use).
    const self_mut: *Self = @constCast(self);
    try self_mut.ensureCache();
    const items = self.sorted_cache.items;
    if (items.len == 0) return &.{};
    // An inverted range (start > end) is unsatisfiable by definition — bail
    // out before the binary search, which otherwise computes lo > hi and
    // panics on `hi - lo` underflowing below.
    if (q.start_time > q.end_time) return &.{};

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

/// Removes every reading of `sensor_type` older than `cutoff_timestamp`,
/// per sensor leaf, via the same in-place stable compaction the flat
/// backends use — readings live per-leaf here, so each leaf's own
/// `readings` list is compacted independently. `latest` is recomputed from
/// the surviving readings only if the previous latest reading was itself
/// pruned (cheap: bounded by that one sensor's own remaining reading
/// count, not the tree). Tree structure, zone/floor topology, and
/// `sensor_to_node`/`zone_to_node`/`floor_to_node` are untouched — pruning
/// only ever removes readings, never a sensor's place in the tree. See
/// storage_backend.zig's pruneOlderThan contract.
pub fn pruneOlderThan(self: *Self, sensor_type: SensorType, cutoff_timestamp: i64) !void {
    for (self.nodes.items) |*node| {
        if (node.readings == null) continue;
        const readings = &node.readings.?;
        var write: usize = 0;
        var removed: usize = 0;
        for (readings.items) |r| {
            if (r.sensor_type == sensor_type and r.timestamp < cutoff_timestamp) {
                removed += 1;
                continue;
            }
            readings.items[write] = r;
            write += 1;
        }
        if (removed == 0) continue;
        readings.shrinkRetainingCapacity(write);
        self.total_count -= removed;

        if (node.latest) |latest| {
            if (latest.sensor_type == sensor_type and latest.timestamp < cutoff_timestamp) {
                var new_latest: ?SensorReading = null;
                for (readings.items) |r| {
                    if (new_latest == null or r.timestamp > new_latest.?.timestamp) new_latest = r;
                }
                node.latest = new_latest;
            }
        }
    }
    self.cache_valid = false;
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
// Tests
// ---------------------------------------------------------------------------

test "Hierarchical: assertImplements" {
    sb.assertImplements(Self);
}

test "Hierarchical: insert N readings and read them back" {
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
        try std.testing.expectEqual(@as(i64, @intCast(i)), all[i].timestamp);
    }
}

test "Hierarchical: getLatestBySensor" {
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

test "Hierarchical: rangeByTime filters and sorts" {
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

test "Hierarchical: rangeByTime with sensor filter" {
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

test "Hierarchical: sensorIdsByZone/sensorIdsByFloor reflect real (non-arithmetic) registration" {
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

test "Hierarchical: getLatestBySensor is deterministic across repeated calls when timestamps tie" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 10.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 100, .value = 20.0, .sensor_type = .temperature });

    const first = backend.getLatestBySensor(1).?;
    const second = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 100), first.timestamp);
    try std.testing.expectEqual(first.value, second.value);
}

test "Hierarchical: empty backend" {
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

test "Hierarchical: out-of-order inserts handled correctly" {
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

test "Hierarchical: tree structure creates correct zone hierarchy from real registration" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // Arbitrary, non-sequential ids — like a real building: zone 4291 and
    // zone 88 both sit on floor 2; zone 50 sits on floor 0.
    try backend.insert(.{ .sensor_id = 0, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 3, .timestamp = 100, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 7, .timestamp = 100, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 23, .timestamp = 100, .value = 4.0, .sensor_type = .temperature });

    try backend.registerZone(0, 4291);
    try backend.registerZone(3, 4291);
    try backend.registerZone(7, 88);
    try backend.registerZone(23, 50);
    try backend.registerFloor(4291, 2);
    try backend.registerFloor(88, 2);
    try backend.registerFloor(50, 0);

    // sensorIdsByZone exercises the real subtree-walk fast path: zone 4291
    // should contain exactly sensors 0 and 3, not sensor 7 (zone 88, same
    // floor) or sensor 23 (a different floor entirely).
    const zone4291 = try backend.sensorIdsByZone(std.testing.allocator, 4291);
    defer std.testing.allocator.free(zone4291);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, zone4291);

    // Floor 2 should contain sensors 0, 3, and 7 (both its zones), but
    // not sensor 23 (floor 0).
    const floor2 = try backend.sensorIdsByFloor(std.testing.allocator, 2);
    defer std.testing.allocator.free(floor2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 7 }, floor2);

    // An empty/nonexistent zone or floor returns an empty slice, not a crash.
    const empty = try backend.sensorIdsByZone(std.testing.allocator, 999999);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Hierarchical: a sensor inserted before registration lands in the unassigned bucket, then moves on registerZone" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 5, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });

    // Not registered yet — must not appear under any real zone.
    const before = try backend.sensorIdsByZone(std.testing.allocator, 10);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    try backend.registerZone(5, 10);

    const after = try backend.sensorIdsByZone(std.testing.allocator, 10);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u32, &.{5}, after);

    // getLatestBySensor must still work — registration never touched the
    // reading data, only where the leaf is parented.
    try std.testing.expectEqual(@as(i64, 0), backend.getLatestBySensor(5).?.timestamp);
}

test "Hierarchical: re-registering a sensor's zone moves it, not duplicates it" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.registerZone(1, 100);
    try backend.registerZone(1, 200);

    const zone100 = try backend.sensorIdsByZone(std.testing.allocator, 100);
    defer std.testing.allocator.free(zone100);
    try std.testing.expectEqual(@as(usize, 0), zone100.len);

    const zone200 = try backend.sensorIdsByZone(std.testing.allocator, 200);
    defer std.testing.allocator.free(zone200);
    try std.testing.expectEqualSlices(u32, &.{1}, zone200);
}

test "Hierarchical: floorOfZone reflects the most recent registerFloor call, null if never registered" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 0, .value = 1.0, .sensor_type = .temperature });
    try backend.registerZone(1, 4291);
    try std.testing.expect(backend.floorOfZone(4291) == null);

    try backend.registerFloor(4291, 0);
    try std.testing.expectEqual(@as(?u32, 0), backend.floorOfZone(4291));
    try backend.registerFloor(4291, 3);
    try std.testing.expectEqual(@as(?u32, 3), backend.floorOfZone(4291));
}

test "Hierarchical and TimeSeries produce identical query results" {
    var hier = try Self.init(std.testing.allocator);
    defer hier.deinit();
    var ts = try @import("timeseries_storage.zig").init(std.testing.allocator);
    defer ts.deinit();

    const readings = [_]SensorReading{
        .{ .sensor_id = 5, .timestamp = 100, .value = 1.5, .sensor_type = .temperature },
        .{ .sensor_id = 2, .timestamp = 300, .value = 2.5, .sensor_type = .humidity },
        .{ .sensor_id = 5, .timestamp = 200, .value = 3.5, .sensor_type = .co2 },
        .{ .sensor_id = 1, .timestamp = 200, .value = 4.5, .sensor_type = .occupancy },
    };

    for (readings) |r| {
        try hier.insert(r);
        try ts.insert(r);
    }

    try std.testing.expectEqual(ts.count(), hier.count());

    // rangeByTime — both must return same sorted results
    const hier_rng = try hier.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(hier_rng);
    const ts_rng = try ts.rangeByTime(std.testing.allocator, .{ .start_time = 150, .end_time = 250 });
    defer std.testing.allocator.free(ts_rng);

    try std.testing.expectEqual(ts_rng.len, hier_rng.len);
    for (0..ts_rng.len) |i| {
        try std.testing.expectEqual(ts_rng[i].sensor_id, hier_rng[i].sensor_id);
        try std.testing.expectEqual(ts_rng[i].timestamp, hier_rng[i].timestamp);
        try std.testing.expectEqual(ts_rng[i].value, hier_rng[i].value);
        try std.testing.expectEqual(ts_rng[i].sensor_type, hier_rng[i].sensor_type);
    }

    // getLatestBySensor — both must agree
    for (0..6) |sid| {
        const hier_latest = hier.getLatestBySensor(@intCast(sid));
        const ts_latest = ts.getLatestBySensor(@intCast(sid));
        if (ts_latest) |t| {
            try std.testing.expect(hier_latest != null);
            try std.testing.expectEqual(t.timestamp, hier_latest.?.timestamp);
            try std.testing.expectEqual(t.sensor_id, hier_latest.?.sensor_id);
            try std.testing.expectEqual(t.value, hier_latest.?.value);
        } else {
            try std.testing.expect(hier_latest == null);
        }
    }

    // iterateAll — both must return same sorted results
    const hier_all = try hier.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(hier_all);
    const ts_all = try ts.iterateAll(std.testing.allocator);
    defer std.testing.allocator.free(ts_all);

    try std.testing.expectEqual(ts_all.len, hier_all.len);
    for (0..ts_all.len) |i| {
        try std.testing.expectEqual(ts_all[i].sensor_id, hier_all[i].sensor_id);
        try std.testing.expectEqual(ts_all[i].timestamp, hier_all[i].timestamp);
        try std.testing.expectEqual(ts_all[i].value, hier_all[i].value);
        try std.testing.expectEqual(ts_all[i].sensor_type, hier_all[i].sensor_type);
    }
}

test "Hierarchical: pruneOlderThan removes only the matching type older than cutoff and recomputes latest" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    // This is sensor 1's latest reading, and it's the one that gets pruned
    // -- latest must be recomputed from the surviving reading, not left
    // stale or nulled out entirely.
    try backend.insert(.{ .sensor_id = 1, .timestamp = 90, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 150, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 2, .timestamp = 50, .value = 4.0, .sensor_type = .humidity });

    try backend.pruneOlderThan(.temperature, 100);

    try std.testing.expectEqual(@as(usize, 2), backend.count());

    const latest = backend.getLatestBySensor(1).?;
    try std.testing.expectEqual(@as(i64, 150), latest.timestamp);
    try std.testing.expectEqual(@as(f32, 3.0), latest.value);

    // Untouched: different type, different sensor.
    const other_latest = backend.getLatestBySensor(2).?;
    try std.testing.expectEqual(@as(i64, 50), other_latest.timestamp);
}

test "Hierarchical: pruneOlderThan that empties a sensor's readings nulls its latest" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    try backend.insert(.{ .sensor_id = 1, .timestamp = 50, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 1, .timestamp = 90, .value = 2.0, .sensor_type = .temperature });

    try backend.pruneOlderThan(.temperature, 100);

    try std.testing.expectEqual(@as(usize, 0), backend.count());
    try std.testing.expect(backend.getLatestBySensor(1) == null);
}
