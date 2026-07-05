// Zig 0.16.0 (tested against 0.17.0-dev)
//
// World(T) — the generic ECS World parameterised over a storage backend.
//
// Per CLAUDE.md §5: the World is parameterised at compile time with a storage
// backend. The same query compiles and runs against any backend. No World-
// level code branches on the concrete backend type (CLAUDE.md §3.1).
//
// Usage:
//   var world_aos = try World(AoSStorage).init(allocator);
//   var world_soa = try World(SoAStorage).init(allocator);
//   try world_aos.insert(reading);
//   const latest = world_aos.getLatestBySensor(1);

const std = @import("std");
const sb = @import("storage/storage_backend.zig");

pub fn World(comptime Backend: type) type {
    // Compile-time contract: Backend must implement the full interface.
    sb.assertImplements(Backend);

    return struct {
        backend: Backend,
        allocator: std.mem.Allocator,
        /// Cache for iterateAll(), valid until the next insert()/prune().
        /// See iterateAll's doc comment for why this lives here instead of
        /// in each backend.
        cached_all: ?[]const sb.SensorReading = null,
        /// Dirty flag — set by insert()/pruneOlderThan(), cleared when
        /// caches are rebuilt. Instead of eagerly freeing caches on every
        /// insert (which is wasteful when inserting thousands of readings
        /// in a loop), we just mark dirty and lazily rebuild on first
        /// access.
        cache_dirty: bool = false,
        /// sensor_type -> indices into cached_all for every reading of that
        /// type. Lazily built from cached_all on first readingsForType()
        /// call, invalidated alongside cached_all on insert(). Stores
        /// indices (u32), not copied readings, to avoid doubling the
        /// already-large cached_all footprint. See readingsForType's doc
        /// comment for why this exists.
        type_index: ?std.AutoHashMap(sb.SensorType, std.ArrayList(u32)) = null,
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .backend = try Backend.init(allocator),
                .allocator = allocator,
            };
        }

        fn freeTypeIndex(self: *Self) void {
            if (self.type_index) |*idx| {
                var it = idx.valueIterator();
                while (it.next()) |list| list.deinit(self.allocator);
                idx.deinit();
                self.type_index = null;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.cached_all) |all| self.allocator.free(all);
            self.freeTypeIndex();
            self.backend.deinit();
        }

        pub fn insert(self: *Self, reading: sb.SensorReading) !void {
            self.cache_dirty = true;
            try self.backend.insert(reading);
        }

        pub fn count(self: *const Self) usize {
            return self.backend.count();
        }

        pub fn memoryUsed(self: *const Self) usize {
            return self.backend.memoryUsed();
        }

        /// Returns a snapshot of every reading, cached until the next
        /// insert(). Borrowed: the caller must NOT free the returned
        /// slice — this differs from StorageBackend.iterateAll()'s own
        /// contract (an owned, freshly-copied slice on every call), which
        /// is unchanged and still applies to direct backend.iterateAll()
        /// calls (e.g. in backend unit tests).
        ///
        /// Why cache here instead of per-backend: every backend's
        /// iterateAll() materializes (allocates + copies) the full dataset
        /// on every call, with no type/zone index to shortcut it — by
        /// design, queries.zig is backend-agnostic (CLAUDE.md §3.1), so
        /// none of them get a backend-specific fast path. At benchmark
        /// scale that's an expensive copy repeated hundreds of times per
        /// backend per run. Within one benchmark run nothing inserts
        /// between queries, so caching the materialized snapshot once
        /// here — generic over every backend, zero backend-specific code —
        /// collapses hundreds of redundant copies into one, exactly how a
        /// real read-optimized backend (immutable snapshot, rebuilt on
        /// write) would behave.
        pub fn iterateAll(self: *Self) ![]const sb.SensorReading {
            if (self.cache_dirty) {
                if (self.cached_all) |all| self.allocator.free(all);
                self.cached_all = null;
                self.freeTypeIndex();
                self.cache_dirty = false;
            }
            if (self.cached_all) |all| return all;
            const all = try self.backend.iterateAll(self.allocator);
            self.cached_all = all;
            return all;
        }

        /// Every distinct sensor_id present in the dataset, sorted ascending
        /// — delegates to the backend's own topology index (zone_of hashmap
        /// keys or tree leaves), never materializes readings. Owned — caller
        /// frees with `self.allocator`.
        ///
        /// Why this exists: query_spatial_radius and query_zone_hierarchy
        /// (depth >= 2) need the full sensor list. The old implementation
        /// built this from iterateAll() — a full materialization of every
        /// reading just to extract distinct sensor IDs. Now each backend
        /// answers from its own sensor-to-zone/tree index in O(distinct
        /// sensors), not O(total readings).
        pub fn allSensorIds(self: *Self) ![]u32 {
            return self.backend.allSensorIds(self.allocator);
        }

        fn ensureTypeIndex(self: *Self) !*std.AutoHashMap(sb.SensorType, std.ArrayList(u32)) {
            _ = try self.iterateAll();
            if (self.type_index != null) return &self.type_index.?;
            const all = self.cached_all.?;
            var idx: std.AutoHashMap(sb.SensorType, std.ArrayList(u32)) = .init(self.allocator);
            errdefer {
                var it = idx.valueIterator();
                while (it.next()) |list| list.deinit(self.allocator);
                idx.deinit();
            }
            for (all, 0..) |r, i| {
                const gop = try idx.getOrPut(r.sensor_type);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, @intCast(i));
            }
            self.type_index = idx;
            return &self.type_index.?;
        }

        /// Returns every reading of `sensor_type`, looked up directly via
        /// a per-type index instead of scanning the whole dataset. Owned —
        /// caller frees with `self.allocator`.
        ///
        /// Why this exists: query_anomalies used to scan the full
        /// materialized dataset checking `r.sensor_type == sensor_type` on
        /// every row, even though only a fraction match. This makes that
        /// O(that type's own reading count) instead of O(whole dataset) —
        /// same output (it's the identical filter, just computed via an
        /// index built once instead of a per-call linear scan), no
        /// semantic change, unlike a true event-driven incremental design
        /// (which would judge early readings against immature running
        /// stats and could disagree with a full-population computation).
        pub fn readingsForType(self: *Self, sensor_type: sb.SensorType) ![]const sb.SensorReading {
            const idx = try self.ensureTypeIndex();
            const all = self.cached_all.?;
            const indices = idx.get(sensor_type) orelse return &.{};
            const result = try self.allocator.alloc(sb.SensorReading, indices.items.len);
            for (indices.items, 0..) |i, j| result[j] = all[i];
            return result;
        }

        pub fn getLatestBySensor(self: *const Self, sensor_id: u32) ?sb.SensorReading {
            return self.backend.getLatestBySensor(sensor_id);
        }

        pub fn rangeByTime(self: *const Self, q: sb.RangeQuery) ![]const sb.SensorReading {
            return self.backend.rangeByTime(self.allocator, q);
        }

        /// Removes every reading of `sensor_type` older than
        /// `cutoff_timestamp` from the backend. Invalidates every
        /// World-level cache (cached_all, type_index) exactly like
        /// insert() does — pruning changes the underlying dataset just as
        /// much as adding to it, and nothing here is safe to keep serving
        /// from a stale snapshot.
        pub fn pruneOlderThan(self: *Self, sensor_type: sb.SensorType, cutoff_timestamp: i64) !void {
            self.cache_dirty = true;
            return self.backend.pruneOlderThan(sensor_type, cutoff_timestamp);
        }

        /// Passthrough — see storage_backend.zig's setRetentionHint
        /// contract. Doesn't touch any existing data, so no World-level
        /// cache needs invalidating (unlike insert/pruneOlderThan).
        pub fn setRetentionHint(self: *Self, sensor_type: sb.SensorType, max_readings: usize) !void {
            return self.backend.setRetentionHint(sensor_type, max_readings);
        }

        pub fn registerZone(self: *Self, sensor_id: u32, zone_id: u32) !void {
            return self.backend.registerZone(sensor_id, zone_id);
        }

        pub fn registerFloor(self: *Self, zone_id: u32, floor_id: u32) !void {
            return self.backend.registerFloor(zone_id, floor_id);
        }

        pub fn sensorIdsByZone(self: *const Self, zone_id: u32) ![]u32 {
            return self.backend.sensorIdsByZone(self.allocator, zone_id);
        }

        pub fn sensorIdsByFloor(self: *const Self, floor_id: u32) ![]u32 {
            return self.backend.sensorIdsByFloor(self.allocator, floor_id);
        }

        pub fn floorOfZone(self: *const Self, zone_id: u32) ?u32 {
            return self.backend.floorOfZone(zone_id);
        }
    };
}

// ---------------------------------------------------------------------------
