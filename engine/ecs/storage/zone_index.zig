// Zig 0.16.0 (tested against 0.17.0-dev)
//
// ZoneIndex — shared sensor/zone/floor bookkeeping for the six "flat"
// backends (AoS, SoA, TimeSeries, Columnar, RingBuffer, Lake).
//
// Every flat backend needs the exact same answer to "which sensors are in
// this zone/floor" — there is no backend-specific optimisation opportunity
// in this bookkeeping, since none of these backends partition their reading
// storage by zone. Writing it six times (one copy-paste per backend) would
// be exactly the kind of duplication CLAUDE.md's review checklist rejects.
// Hierarchical is the one backend with something real to exploit (a tree
// indexed by the same zone/floor ids) and implements the StorageBackend
// zone methods itself rather than embedding this.
//
// This is composition, not a manager/singleton: each backend embeds one
// ZoneIndex value as a field and delegates to it, the same way every
// backend already embeds std.ArrayList fields.
//
// sensors_by_zone is a maintained reverse index (zone_id -> sensor_ids),
// not a per-query scan — the original version scanned every registered
// sensor in the building on every sensorIdsByZone/sensorIdsByFloor call
// (O(total_sensors) regardless of the target zone's size). That made every
// zone-scoped query pay a full-building scan even for a two-sensor closet,
// which is what let Hierarchical's real tree win zone-scoped queries by an
// order of magnitude that had nothing to do with its actual storage layout.
// Maintaining the reverse index at registration time (registration happens
// once per sensor at ingest, not per query) keeps this a pure internal-
// layout optimisation — no query-layer or interface change (CLAUDE.md §3.2).

const std = @import("std");

allocator: std.mem.Allocator,
/// sensor_id -> zone_id. One entry per sensor that has ever been
/// registered, independent of how many readings it has.
zone_of: std.AutoHashMap(u32, u32),
/// zone_id -> floor_id. One entry per zone that has ever been registered
/// to a floor.
floor_of: std.AutoHashMap(u32, u32),
/// zone_id -> every sensor_id currently registered to that zone (reverse
/// of zone_of). Kept in sync by registerZone, including moving a sensor
/// out of its old zone's list on re-registration. Unsorted; callers get a
/// sorted copy from sensorIdsByZone/sensorIdsByFloor.
sensors_by_zone: std.AutoHashMap(u32, std.ArrayList(u32)),

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .zone_of = std.AutoHashMap(u32, u32).init(allocator),
        .floor_of = std.AutoHashMap(u32, u32).init(allocator),
        .sensors_by_zone = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.zone_of.deinit();
    self.floor_of.deinit();
    var it = self.sensors_by_zone.valueIterator();
    while (it.next()) |list| list.deinit(self.allocator);
    self.sensors_by_zone.deinit();
}

pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
    if (self.zone_of.get(sensor_id)) |old_zone_id| {
        if (old_zone_id == zone_id) return;
        if (self.sensors_by_zone.getPtr(old_zone_id)) |old_list| {
            for (old_list.items, 0..) |sid, i| {
                if (sid == sensor_id) {
                    _ = old_list.swapRemove(i);
                    break;
                }
            }
        }
    }

    try self.zone_of.put(sensor_id, zone_id);

    const gop = try self.sensors_by_zone.getOrPut(zone_id);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(self.allocator, sensor_id);
}

pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
    try self.floor_of.put(zone_id, floor_id);
}

pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
    return self.floor_of.get(zone_id);
}

/// Every sensor_id registered under zone_id, sorted ascending.
pub fn sensorIdsByZone(self: *const Self, allocator: std.mem.Allocator, zone_id: u32) ![]u32 {
    const list = self.sensors_by_zone.get(zone_id) orelse return &.{};

    const out = try allocator.dupe(u32, list.items);
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    return out;
}

/// Every sensor_id registered to a zone whose registered floor is floor_id,
/// sorted ascending. Walks floor_of (one entry per zone) rather than
/// zone_of (one entry per sensor) — zones are always far fewer than
/// sensors, and each matching zone's members come from the O(1)
/// sensors_by_zone lookup instead of a per-sensor scan.
pub fn sensorIdsByFloor(self: *const Self, allocator: std.mem.Allocator, floor_id: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.floor_of.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != floor_id) continue;
        const zone_id = entry.key_ptr.*;
        if (self.sensors_by_zone.get(zone_id)) |list| {
            try result.appendSlice(allocator, list.items);
        }
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

pub fn memoryUsed(self: *const Self) usize {
    var zone_list_bytes: usize = 0;
    var it = self.sensors_by_zone.valueIterator();
    while (it.next()) |list| zone_list_bytes += list.capacity * @sizeOf(u32);

    return self.zone_of.capacity() * (@sizeOf(u32) + @sizeOf(u32)) +
        self.floor_of.capacity() * (@sizeOf(u32) + @sizeOf(u32)) +
        zone_list_bytes;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "sensorIdsByZone: returns only sensors registered to that zone, sorted ascending" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    try idx.registerZone(30, 1);
    try idx.registerZone(10, 1);
    try idx.registerZone(20, 2);

    const members = try idx.sensorIdsByZone(testing.allocator, 1);
    defer testing.allocator.free(members);

    try testing.expectEqualSlices(u32, &.{ 10, 30 }, members);
}

test "sensorIdsByZone: unregistered zone returns empty slice" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    try idx.registerZone(1, 1);

    const members = try idx.sensorIdsByZone(testing.allocator, 999);
    defer testing.allocator.free(members);

    try testing.expectEqual(@as(usize, 0), members.len);
}

test "registerZone: re-registering a sensor to a different zone moves it out of the old zone's results" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    try idx.registerZone(1, 100);
    try idx.registerZone(2, 100);

    // Sensor 1 gets reassigned to zone 200.
    try idx.registerZone(1, 200);

    const old_zone_members = try idx.sensorIdsByZone(testing.allocator, 100);
    defer testing.allocator.free(old_zone_members);
    try testing.expectEqualSlices(u32, &.{2}, old_zone_members);

    const new_zone_members = try idx.sensorIdsByZone(testing.allocator, 200);
    defer testing.allocator.free(new_zone_members);
    try testing.expectEqualSlices(u32, &.{1}, new_zone_members);
}

test "sensorIdsByFloor: aggregates sensors across every zone registered to that floor" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    try idx.registerZone(10, 1);
    try idx.registerZone(20, 2);
    try idx.registerZone(30, 3);
    try idx.registerFloor(1, 5);
    try idx.registerFloor(2, 5);
    try idx.registerFloor(3, 6);

    const members = try idx.sensorIdsByFloor(testing.allocator, 5);
    defer testing.allocator.free(members);

    try testing.expectEqualSlices(u32, &.{ 10, 20 }, members);
}
