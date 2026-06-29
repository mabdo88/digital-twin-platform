// Zig 0.16.0
const std = @import("std");

// ---------------------------------------------------------------------------
// Shared data types — the vocabulary of the storage interface.
//
// These types define the ONLY data shape that flows through the backend
// interface. Backends are free to store data internally in any layout (AoS,
// SoA, columnar, hierarchical, ring buffer) but must accept and return
// SensorReading values through the interface.
// ---------------------------------------------------------------------------

/// Physical sensor categories the platform models.
pub const SensorType = enum(u8) {
    temperature,
    humidity,
    occupancy,
    co2,
    vibration,
    flow,
    energy,
    structural,
    air_quality,
};

/// A single sensor reading — the atomic unit every backend stores.
/// Plain data: no pointers, no ownership, no allocation.
pub const SensorReading = struct {
    sensor_id: u32,
    /// Unix epoch milliseconds.
    timestamp: i64,
    value: f32,
    sensor_type: SensorType,
};

/// Time-range query specification.
/// `sensor_id` is optional: null means "all sensors in the time range".
pub const RangeQuery = struct {
    sensor_id: ?u32 = null,
    start_time: i64,
    end_time: i64,
};

// ---------------------------------------------------------------------------
// Comptime interface — StorageBackend
//
// A storage backend is a Zig struct that implements every method listed
// below. This is a COMPTIME interface: there is no vtable, no dynamic
// dispatch. The World(T) generic parameterises over a concrete backend
// type at compile time, and `assertImplements` verifies the contract.
//
// Per CLAUDE.md 3.2: the interface is the ONLY public surface a backend
// may expose. No backend-specific methods anywhere — not in queries, not
// in systems, not in World.
// ---------------------------------------------------------------------------

/// Verify at compile time that `T` implements the full StorageBackend
/// interface. Call this inside World(T) or any code that parameterises
/// over a backend:
///
///   const World = struct {
///       pub fn init(comptime Backend: type) World(Backend) {
///           storage_backend.assertImplements(Backend);
///           ...
///       }
///   };
///
/// If a method is missing, the compile error names the offending type
/// and the missing declaration.
pub fn assertImplements(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("StorageBackend: " ++ @typeName(T) ++ " must be a struct, got " ++ @tagName(info));
    }

    if (!@hasDecl(T, "init")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn init");
    if (!@hasDecl(T, "deinit")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn deinit");
    if (!@hasDecl(T, "insert")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn insert");
    if (!@hasDecl(T, "count")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn count");
    if (!@hasDecl(T, "memoryUsed")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn memoryUsed");
    if (!@hasDecl(T, "iterateAll")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn iterateAll");
    if (!@hasDecl(T, "getLatestBySensor")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn getLatestBySensor");
    if (!@hasDecl(T, "rangeByTime")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn rangeByTime");
    if (!@hasDecl(T, "registerZone")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn registerZone");
    if (!@hasDecl(T, "registerFloor")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn registerFloor");
    if (!@hasDecl(T, "sensorIdsByZone")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn sensorIdsByZone");
    if (!@hasDecl(T, "sensorIdsByFloor")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn sensorIdsByFloor");
    if (!@hasDecl(T, "floorOfZone")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn floorOfZone");
}

// ---------------------------------------------------------------------------
// Method contracts (documentation only — backends implement these as
// regular pub fn declarations on their struct).
//
// The signatures below use `T` as a placeholder for the concrete backend
// type. Each backend replaces T with its own name.
// ---------------------------------------------------------------------------

//  pub fn init(allocator: std.mem.Allocator) !T
//
//      Create a new backend instance with no readings.
//      May fail on allocation.
//
//  pub fn deinit(self: *T) void
//
//      Release all internally owned memory.
//      After deinit the instance must not be used.
//
//  pub fn insert(self: *T, reading: SensorReading) !void
//
//      Append a single reading to the backend.
//      Readings are NOT required to arrive in timestamp order; the
//      backend may sort or index internally.
//      May fail on allocation.
//
//  pub fn count(self: *const T) usize
//
//      Total number of readings currently stored.
//      Returns 0 when the backend is empty.
//
//  pub fn memoryUsed(self: *const T) usize
//
//      Total bytes allocated by the backend's internal data structures
//      (excluding the struct itself). Used by metrics_system for memory
//      benchmarking. Includes any indices, buffers, or auxiliary arrays.
//
//  pub fn iterateAll(self: *const T, allocator: std.mem.Allocator) ![]const SensorReading
//
//      Return ALL readings as a slice.
//      Ordering: NOT guaranteed to be insertion order — each backend
//      documents its own iteration order in its source file.
//      Ownership: the caller owns the returned slice and must free it
//      with `allocator`.
//      Empty behaviour: returns an empty slice (&.{}).
//
//  pub fn getLatestBySensor(self: *const T, sensor_id: u32) ?SensorReading
//
//      Return the most recent reading (highest timestamp) for the given
//      sensor_id.
//      If multiple readings share the highest timestamp, any one of
//      them may be returned (backends are not required to break ties
//      deterministically, but SHOULD do so for golden-result tests).
//      Empty behaviour: returns null if no readings exist for that
//      sensor.
//
//  pub fn rangeByTime(self: *const T, allocator: std.mem.Allocator, q: RangeQuery) ![]const SensorReading
//
//      Return all readings with timestamp in [q.start_time, q.end_time]
//      (inclusive).
//      If q.sensor_id is non-null, filter to that sensor only.
//      Ordering: results are ordered by timestamp ascending. Ties are
//      broken by sensor_id ascending.
//      Ownership: the caller owns the returned slice and must free it
//      with `allocator`.
//      Empty behaviour: returns an empty slice (&.{}).
//
//  pub fn registerZone(self: *T, sensor_id: u32, zone_id: u32) !void
//
//      Record which zone a sensor lives in. This is TOPOLOGY, not a
//      reading: it comes from real placement data (sensor_placer.zig's
//      ZoneLocation for a real building, or a synthetic equivalent for
//      benchmark fixtures) and is established once per sensor, decoupled
//      from how many readings that sensor later produces. There is
//      deliberately NO arithmetic relationship between sensor_id and
//      zone_id assumed anywhere in this interface — a real building's
//      zones hold a variable number of sensors with arbitrary IDs (the
//      source IFC entity id), not a fixed-width block.
//      Calling this again for the same sensor_id moves it to the new
//      zone_id (last write wins). Safe to call before or after any
//      `insert` for that sensor.
//      May fail on allocation.
//
//  pub fn registerFloor(self: *T, zone_id: u32, floor_id: u32) !void
//
//      Record which floor a zone belongs to. One call per zone (not per
//      sensor) — floor membership is a property of the zone, mirroring
//      ZoneMetadata.floor_level in the real BIM pipeline. Calling this
//      again for the same zone_id moves it to the new floor_id.
//      May fail on allocation.
//
//  pub fn sensorIdsByZone(self: *const T, allocator: std.mem.Allocator, zone_id: u32) ![]u32
//
//      Every DISTINCT sensor_id registered (via registerZone) under
//      zone_id. A backend that indexes by zone internally (e.g. a
//      Floor/Zone tree) can walk straight to that subtree; others scan
//      their zone registrations (cheap: one entry per sensor, not per
//      reading).
//      Results are sorted by sensor_id ascending.
//      Ownership: the caller owns the returned slice and must free it
//      with `allocator`.
//      Empty behaviour: returns an empty slice (&.{}) — including for a
//      zone_id nothing was ever registered under. Not an error.
//
//  pub fn sensorIdsByFloor(self: *const T, allocator: std.mem.Allocator, floor_id: u32) ![]u32
//
//      Every DISTINCT sensor_id registered under any zone whose
//      registerFloor call named this floor_id.
//      Results are sorted by sensor_id ascending.
//      Ownership/empty behaviour: same as sensorIdsByZone.
//
//  pub fn floorOfZone(self: *const T, zone_id: u32) ?u32
//
//      The floor_id most recently registered (via registerFloor) for
//      zone_id, or null if that zone has never been registered to a
//      floor. No allocation — a value lookup, like getLatestBySensor.

// ---------------------------------------------------------------------------
// Tests — verify the interface types and assertImplements compile.
// ---------------------------------------------------------------------------

test "SensorReading is plain data" {
    const r = SensorReading{
        .sensor_id = 42,
        .timestamp = 1700000000,
        .value = 23.5,
        .sensor_type = .temperature,
    };
    try std.testing.expectEqual(@as(u32, 42), r.sensor_id);
    try std.testing.expectEqual(@as(i64, 1700000000), r.timestamp);
    try std.testing.expectEqual(@as(f32, 23.5), r.value);
    try std.testing.expectEqual(SensorType.temperature, r.sensor_type);
}

test "RangeQuery defaults to all sensors" {
    const q = RangeQuery{ .start_time = 0, .end_time = 100 };
    try std.testing.expect(q.sensor_id == null);
}

test "RangeQuery with sensor filter" {
    const q = RangeQuery{ .sensor_id = 7, .start_time = 0, .end_time = 100 };
    try std.testing.expectEqual(@as(?u32, 7), q.sensor_id);
}

/// Minimal stub that satisfies the interface — used only to verify
/// assertImplements accepts a correctly-shaped type. NOT a real backend.
const StubBackend = struct {
    pub fn init(_: std.mem.Allocator) !StubBackend {
        return .{};
    }
    pub fn deinit(_: *StubBackend) void {}
    pub fn insert(_: *StubBackend, _: SensorReading) !void {}
    pub fn count(_: *const StubBackend) usize {
        return 0;
    }
    pub fn memoryUsed(_: *const StubBackend) usize {
        return 0;
    }
    pub fn iterateAll(_: *const StubBackend, _: std.mem.Allocator) ![]const SensorReading {
        return &.{};
    }
    pub fn getLatestBySensor(_: *const StubBackend, _: u32) ?SensorReading {
        return null;
    }
    pub fn rangeByTime(_: *const StubBackend, _: std.mem.Allocator, _: RangeQuery) ![]const SensorReading {
        return &.{};
    }
    pub fn registerZone(_: *StubBackend, _: u32, _: u32) !void {}
    pub fn registerFloor(_: *StubBackend, _: u32, _: u32) !void {}
    pub fn sensorIdsByZone(_: *const StubBackend, _: std.mem.Allocator, _: u32) ![]u32 {
        return &.{};
    }
    pub fn sensorIdsByFloor(_: *const StubBackend, _: std.mem.Allocator, _: u32) ![]u32 {
        return &.{};
    }
    pub fn floorOfZone(_: *const StubBackend, _: u32) ?u32 {
        return null;
    }
};

test "assertImplements accepts a valid backend" {
    assertImplements(StubBackend);
}

/// A second stub with extra public methods beyond the required interface.
/// CLAUDE.md §3.2 says backends should expose no extra public methods, but
/// that's a style rule enforced by review, not by `assertImplements` itself:
/// the check only looks for the required `@hasDecl`s, so it is purely
/// additive and never rejects a type for having more than the interface
/// asks for. This test documents that present (lenient) behavior so a
/// future tightening of `assertImplements` is a deliberate decision, not an
/// accidental regression.
const ExtendedBackend = struct {
    pub fn init(_: std.mem.Allocator) !ExtendedBackend {
        return .{};
    }
    pub fn deinit(_: *ExtendedBackend) void {}
    pub fn insert(_: *ExtendedBackend, _: SensorReading) !void {}
    pub fn count(_: *const ExtendedBackend) usize {
        return 0;
    }
    pub fn memoryUsed(_: *const ExtendedBackend) usize {
        return 0;
    }
    pub fn iterateAll(_: *const ExtendedBackend, _: std.mem.Allocator) ![]const SensorReading {
        return &.{};
    }
    pub fn getLatestBySensor(_: *const ExtendedBackend, _: u32) ?SensorReading {
        return null;
    }
    pub fn rangeByTime(_: *const ExtendedBackend, _: std.mem.Allocator, _: RangeQuery) ![]const SensorReading {
        return &.{};
    }
    pub fn registerZone(_: *ExtendedBackend, _: u32, _: u32) !void {}
    pub fn registerFloor(_: *ExtendedBackend, _: u32, _: u32) !void {}
    pub fn sensorIdsByZone(_: *const ExtendedBackend, _: std.mem.Allocator, _: u32) ![]u32 {
        return &.{};
    }
    pub fn sensorIdsByFloor(_: *const ExtendedBackend, _: std.mem.Allocator, _: u32) ![]u32 {
        return &.{};
    }
    pub fn floorOfZone(_: *const ExtendedBackend, _: u32) ?u32 {
        return null;
    }
    // Not part of the StorageBackend interface — should not affect the check.
    pub fn debugDump(_: *const ExtendedBackend) void {}
};

test "assertImplements ignores extra public methods beyond the interface" {
    assertImplements(ExtendedBackend);
}
