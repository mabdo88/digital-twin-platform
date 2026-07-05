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
