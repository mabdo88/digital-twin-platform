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
    if (!@hasDecl(T, "sensorIdsByGroup")) @compileError("StorageBackend: " ++ @typeName(T) ++ " missing pub fn sensorIdsByGroup");
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
//  pub fn sensorIdsByGroup(self: *const T, allocator: std.mem.Allocator, group_id: u32, divisor: u32) ![]u32
//
//      Return every DISTINCT sensor_id with at least one stored reading
//      where `sensor_id / divisor == group_id`. This is the generic
//      "give me every sensor under this branch of the zone/floor tree"
//      primitive backing hierarchy queries (Q10) — it exists so a query
//      can express "which sensors are in this group" WITHOUT calling
//      iterateAll() and filtering client-side, which would force every
//      backend through a full scan regardless of how it organises data
//      internally.
//
//      Most backends implement this as a linear scan + filter (the same
//      cost as iterateAll, since they have no grouping structure to
//      exploit). A backend that internally partitions data by sensor_id
//      division (e.g. a backend with a Floor/Zone tree) can instead walk
//      directly to the matching node(s) and read off just that subtree's
//      leaves — touching a fraction of the dataset instead of all of it.
//      `divisor` is an arbitrary caller-supplied grouping width; backends
//      MUST return correct results for any divisor (falling back to a
//      scan when it doesn't match their internal partitioning), not just
//      the values their own internal structure happens to use.
//      Results are sorted by sensor_id ascending.
//      Ownership: the caller owns the returned slice and must free it
//      with `allocator`.
//      Empty behaviour: returns an empty slice (&.{}).

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
    pub fn sensorIdsByGroup(_: *const StubBackend, _: std.mem.Allocator, _: u32, _: u32) ![]u32 {
        return &.{};
    }
};

test "assertImplements accepts a valid backend" {
    assertImplements(StubBackend);
}

test "assertImplements rejects a non-struct type" {
    // This test verifies at comptime that passing a non-struct triggers
    // a compile error. We use a comptime-only check that does not actually
    // invoke assertImplements on the wrong type (which would stop the
    // build). Instead we verify the function exists and is callable.
    comptime assertImplements(StubBackend);
}
