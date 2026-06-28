// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Hierarchical backend — data indexed by a zone tree
// (Floor → Zone → Sensor) via parent-child links.
//
// Models graph-db behaviour: readings are stored in per-sensor leaf
// nodes of a tree index. The zone-hierarchy query (Q10) traverses the
// tree to collect sensors from a subtree directly (e.g. "all sensors on
// floor 2") via `sensorIdsByGroup`, instead of scanning every reading.
//
// The tree is an internal detail invisible to queries — the public
// surface is exactly the StorageBackend interface. The tree makes
// per-sensor lookups O(1) (hash map from sensor_id to leaf node) and
// `sensorIdsByGroup` O(num_floors + num_zones_on_that_floor) instead of
// O(num_readings) when the caller's divisor matches a tree level.
//
// Zone assignment (deterministic, derived from sensor_id) MUST match the
// topology engine/benchmark/dataset.zig defines (SENSORS_PER_ZONE=5,
// SENSORS_PER_FLOOR=10) — these are duplicated as local constants below
// rather than imported, since storage backends sit below the benchmark
// layer and must not depend on it. If dataset.zig's topology ever
// changes, these constants need to change with it or the tree's fast
// path in `sensorIdsByGroup` silently stops matching and falls back to a
// full scan (still correct, just slower — see the `else` branch there):
//   floor = sensor_id / SENSORS_PER_FLOOR (10)
//   zone  = sensor_id / SENSORS_PER_ZONE (5)
//   sensor = sensor_id (leaf)
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

/// Tree topology — must match engine/benchmark/dataset.zig. See file
/// header comment for why these are duplicated rather than imported.
const SENSORS_PER_ZONE: u32 = 5;
const SENSORS_PER_FLOOR: u32 = 10;

const Self = @This();

// Tree node — represents a Floor or Zone, or a Sensor leaf.
// Internal only; never exposed through the interface.
const Node = struct {
    parent: ?u32,
    children: std.ArrayList(u32),
    readings: ?std.ArrayList(SensorReading),
    sensor_id: ?u32,
    zone_key: u32,
    /// Latest reading by timestamp for this leaf, maintained incrementally
    /// on insert (same pattern ringbuffer_storage.zig's SensorBuffer.latest
    /// already uses) so getLatestBySensor is O(1) instead of O(readings on
    /// this leaf). Null for non-leaf (Floor/Zone) nodes.
    latest: ?SensorReading,
};

allocator: std.mem.Allocator,
nodes: std.ArrayList(Node),
sensor_to_node: std.AutoHashMap(u32, u32),
root: u32,
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
        .root = 0,
        .total_count = 0,
        .sorted_cache = .empty,
        .cache_valid = true,
    };
    try self.nodes.append(allocator, .{
        .parent = null,
        .children = .empty,
        .readings = null,
        .sensor_id = null,
        .zone_key = 0,
        .latest = null,
    });
    self.root = 0;
    return self;
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
    self.sorted_cache.deinit(self.allocator);
    self.* = undefined;
}

pub fn insert(self: *Self, reading: SensorReading) !void {
    const leaf_idx = try self.ensureSensorPath(reading.sensor_id);
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

/// See storage_backend.zig's doc comment for the contract. Fast path: when
/// `divisor` matches one of this tree's own levels (Zone or Floor), walk
/// directly to the matching node and collect its leaf sensor_ids — never
/// touching nodes outside that subtree. Any other divisor falls back to a
/// full scan (still correct, just without the shortcut).
pub fn sensorIdsByGroup(self: *const Self, allocator: std.mem.Allocator, group_id: u32, divisor: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    if (divisor == SENSORS_PER_ZONE) {
        const floor_id = group_id / (SENSORS_PER_FLOOR / SENSORS_PER_ZONE);
        if (self.findChild(self.root, floor_id)) |floor_idx| {
            if (self.findChild(floor_idx, group_id)) |zone_idx| {
                try self.collectLeafSensorIds(zone_idx, &result, allocator);
            }
        }
    } else if (divisor == SENSORS_PER_FLOOR) {
        if (self.findChild(self.root, group_id)) |floor_idx| {
            try self.collectLeafSensorIds(floor_idx, &result, allocator);
        }
    } else {
        for (self.nodes.items) |node| {
            if (node.sensor_id) |sid| {
                if (sid / divisor == group_id) try result.append(allocator, sid);
            }
        }
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

fn findChild(self: *const Self, parent_idx: u32, zone_key: u32) ?u32 {
    for (self.nodes.items[parent_idx].children.items) |child_idx| {
        if (self.nodes.items[child_idx].zone_key == zone_key) return child_idx;
    }
    return null;
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
// Internal — tree path management
// ---------------------------------------------------------------------------

fn ensureSensorPath(self: *Self, sensor_id: u32) !u32 {
    if (self.sensor_to_node.get(sensor_id)) |idx| return idx;

    const floor_key = sensor_id / SENSORS_PER_FLOOR;
    const zone_key = sensor_id / SENSORS_PER_ZONE;

    const floor_idx = try self.ensureChild(self.root, floor_key);
    const zone_idx = try self.ensureChild(floor_idx, zone_key);
    const leaf_idx = try self.createLeaf(zone_idx, sensor_id);

    try self.sensor_to_node.put(sensor_id, leaf_idx);
    return leaf_idx;
}

fn ensureChild(self: *Self, parent_idx: u32, zone_key: u32) !u32 {
    for (self.nodes.items[parent_idx].children.items) |child_idx| {
        if (self.nodes.items[child_idx].zone_key == zone_key) {
            return child_idx;
        }
    }
    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .parent = parent_idx,
        .children = .empty,
        .readings = null,
        .sensor_id = null,
        .zone_key = zone_key,
        .latest = null,
    });
    // Access parent after append — append may reallocate nodes.items
    try self.nodes.items[parent_idx].children.append(self.allocator, idx);
    return idx;
}

fn createLeaf(self: *Self, parent_idx: u32, sensor_id: u32) !u32 {
    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .parent = parent_idx,
        .children = .empty,
        .readings = null,
        .sensor_id = sensor_id,
        .zone_key = sensor_id,
        .latest = null,
    });
    // Access parent after append — append may reallocate nodes.items
    try self.nodes.items[parent_idx].children.append(self.allocator, idx);
    return idx;
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

test "Hierarchical: tree structure creates correct zone hierarchy" {
    var backend = try Self.init(std.testing.allocator);
    defer backend.deinit();

    // sensor 0  → floor 0 (0/10), zone 0 (0/5)
    // sensor 3  → floor 0,         zone 0   (same zone as sensor 0)
    // sensor 7  → floor 0,         zone 1   (same floor, different zone)
    // sensor 23 → floor 2 (23/10), zone 4 (23/5)  (different floor entirely)
    try backend.insert(.{ .sensor_id = 0, .timestamp = 100, .value = 1.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 3, .timestamp = 100, .value = 2.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 7, .timestamp = 100, .value = 3.0, .sensor_type = .temperature });
    try backend.insert(.{ .sensor_id = 23, .timestamp = 100, .value = 4.0, .sensor_type = .temperature });

    // Root + floor0 + floor2 + zone0 + zone1 + zone4 + sensor0 + sensor3 + sensor7 + sensor23
    // = 10 nodes
    try std.testing.expectEqual(@as(usize, 10), backend.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 0), backend.root);

    // Root has 2 children (floor 0, floor 2)
    try std.testing.expectEqual(@as(usize, 2), backend.nodes.items[0].children.items.len);

    // All 4 sensors are leaf nodes with readings
    try std.testing.expectEqual(@as(usize, 4), backend.count());

    // sensorIdsByGroup exercises the actual subtree-walk fast path: zone 0
    // (divisor=SENSORS_PER_ZONE=5) should contain exactly sensors 0 and 3,
    // not sensor 7 (zone 1) or sensor 23 (a different floor entirely).
    const zone0 = try backend.sensorIdsByGroup(std.testing.allocator, 0, SENSORS_PER_ZONE);
    defer std.testing.allocator.free(zone0);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, zone0);

    // Floor 0 (divisor=SENSORS_PER_FLOOR=10) should contain sensors 0, 3,
    // and 7 (both its zones), but not sensor 23 (floor 2).
    const floor0 = try backend.sensorIdsByGroup(std.testing.allocator, 0, SENSORS_PER_FLOOR);
    defer std.testing.allocator.free(floor0);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 7 }, floor0);

    // An empty/nonexistent group returns an empty slice, not a crash.
    const empty = try backend.sensorIdsByGroup(std.testing.allocator, 999, SENSORS_PER_ZONE);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
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
