// Zig 0.16.0 (tested against 0.17.0-dev)
//
// ZoneIndex — shared sensor/zone/floor bookkeeping for the five "flat"
// backends (AoS, SoA, TimeSeries, Columnar, RingBuffer).
//
// Every flat backend needs the exact same answer to "which sensors are in
// this zone/floor" — there is no backend-specific optimisation opportunity
// in a hashmap of {sensor_id: u32 -> zone_id: u32} plus {zone_id -> floor_id},
// since none of these backends partition their reading storage by zone.
// Writing that bookkeeping five times (one copy-paste per backend) would be
// exactly the kind of duplication CLAUDE.md's review checklist rejects.
// Hierarchical is the one backend with something real to exploit (a tree
// indexed by the same zone/floor ids) and implements the StorageBackend
// zone methods itself rather than embedding this.
//
// This is composition, not a manager/singleton: each backend embeds one
// ZoneIndex value as a field and delegates to it, the same way every
// backend already embeds std.ArrayList fields.

const std = @import("std");

allocator: std.mem.Allocator,
/// sensor_id -> zone_id. One entry per sensor that has ever been
/// registered, independent of how many readings it has.
zone_of: std.AutoHashMap(u32, u32),
/// zone_id -> floor_id. One entry per zone that has ever been registered
/// to a floor.
floor_of: std.AutoHashMap(u32, u32),

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .zone_of = std.AutoHashMap(u32, u32).init(allocator),
        .floor_of = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.zone_of.deinit();
    self.floor_of.deinit();
}

pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
    try self.zone_of.put(sensor_id, zone_id);
}

pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
    try self.floor_of.put(zone_id, floor_id);
}

pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
    return self.floor_of.get(zone_id);
}

/// Every sensor_id registered under zone_id, sorted ascending.
pub fn sensorIdsByZone(self: *const Self, allocator: std.mem.Allocator, zone_id: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.zone_of.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == zone_id) try result.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

/// Every sensor_id registered to a zone whose registered floor is floor_id,
/// sorted ascending.
pub fn sensorIdsByFloor(self: *const Self, allocator: std.mem.Allocator, floor_id: u32) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);

    var it = self.zone_of.iterator();
    while (it.next()) |entry| {
        const zone_id = entry.value_ptr.*;
        const fid = self.floor_of.get(zone_id) orelse continue;
        if (fid == floor_id) try result.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

pub fn memoryUsed(self: *const Self) usize {
    return self.zone_of.capacity() * (@sizeOf(u32) + @sizeOf(u32)) +
        self.floor_of.capacity() * (@sizeOf(u32) + @sizeOf(u32));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ZoneIndex: sensorIdsByZone returns sorted distinct sensors for a zone" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    // Real-world-shaped ids: arbitrary, not sequential blocks.
    try idx.registerZone(7, 4291);
    try idx.registerZone(2, 4291);
    try idx.registerZone(9, 88);

    const zone4291 = try idx.sensorIdsByZone(testing.allocator, 4291);
    defer testing.allocator.free(zone4291);
    try testing.expectEqualSlices(u32, &.{ 2, 7 }, zone4291);

    const zone88 = try idx.sensorIdsByZone(testing.allocator, 88);
    defer testing.allocator.free(zone88);
    try testing.expectEqualSlices(u32, &.{9}, zone88);
}

test "ZoneIndex: an unregistered zone returns an empty slice, not an error" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();
    try idx.registerZone(1, 100);

    const result = try idx.sensorIdsByZone(testing.allocator, 999);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "ZoneIndex: sensorIdsByFloor composes through the zone->floor link" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();

    // Two zones (4291, 88) on floor 2; one zone (50) on floor 0.
    try idx.registerZone(1, 4291);
    try idx.registerZone(2, 88);
    try idx.registerZone(3, 50);
    try idx.registerFloor(4291, 2);
    try idx.registerFloor(88, 2);
    try idx.registerFloor(50, 0);

    const floor2 = try idx.sensorIdsByFloor(testing.allocator, 2);
    defer testing.allocator.free(floor2);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, floor2);

    const floor0 = try idx.sensorIdsByFloor(testing.allocator, 0);
    defer testing.allocator.free(floor0);
    try testing.expectEqualSlices(u32, &.{3}, floor0);
}

test "ZoneIndex: a zone registered to a sensor but never assigned a floor contributes to neither floor" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();
    try idx.registerZone(1, 4291); // zone 4291 never gets registerFloor

    const floor0 = try idx.sensorIdsByFloor(testing.allocator, 0);
    defer testing.allocator.free(floor0);
    try testing.expectEqual(@as(usize, 0), floor0.len);
    try testing.expect(idx.floorOfZone(4291) == null);
}

test "ZoneIndex: re-registering a sensor's zone moves it, not duplicates it" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();
    try idx.registerZone(1, 100);
    try idx.registerZone(1, 200); // sensor 1 moves from zone 100 to zone 200

    const zone100 = try idx.sensorIdsByZone(testing.allocator, 100);
    defer testing.allocator.free(zone100);
    try testing.expectEqual(@as(usize, 0), zone100.len);

    const zone200 = try idx.sensorIdsByZone(testing.allocator, 200);
    defer testing.allocator.free(zone200);
    try testing.expectEqualSlices(u32, &.{1}, zone200);
}

test "ZoneIndex: floorOfZone reflects the most recent registerFloor call" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();
    try idx.registerFloor(4291, 0);
    try testing.expectEqual(@as(?u32, 0), idx.floorOfZone(4291));
    try idx.registerFloor(4291, 3);
    try testing.expectEqual(@as(?u32, 3), idx.floorOfZone(4291));
}

test "ZoneIndex: memoryUsed grows after registration and is zero when empty" {
    var idx = Self.init(testing.allocator);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.memoryUsed());
    try idx.registerZone(1, 100);
    try idx.registerFloor(100, 0);
    try testing.expect(idx.memoryUsed() > 0);
}
