# Skill: Add a Storage Backend

## When to use

You have been asked to add a new storage backend (e.g., "Add a ring-buffer backend
that keeps only the last N readings per sensor").

## Definition of done

1. ✅ Backend compiles and implements `StorageBackend` interface exactly.
2. ✅ Golden-result test: backend produces identical output to TimeSeriesStorage on
   a fixed workload.
3. ✅ All 12 queries run against the new backend without crashing.
4. ✅ Benchmark results included in the PR (latency, memory, throughput).
5. ✅ No backend-specific code leaked into queries or systems.
6. ✅ Code is minimal; no extra public methods or state.

---

## Procedure

### 1. Create the file

Place the new backend at `engine/ecs/storage/backends/<name>_storage.zig`.

Example: `engine/ecs/storage/backends/ringbuffer_storage.zig`.

### 2. Implement the interface

```zig
// Stub; fill in as you go.
pub const RingBufferStorage = struct {
    allocator: std.mem.Allocator,
    // ... internal state (opaque to queries)

    pub fn init(allocator: std.mem.Allocator) !RingBufferStorage {
        return RingBufferStorage{
            .allocator = allocator,
            // ...
        };
    }

    pub fn deinit(self: *RingBufferStorage) void {
        // cleanup
    }

    // ... implement StorageBackend interface methods
};
```

Refer to `storage_backend.zig` for the exact interface signature.

### 3. Write the golden-result test

In `tests/golden_results.zig` (or a new test file), add:

```zig
test "RingBufferStorage produces same results as TimeSeriesStorage" {
    const allocator = std.testing.allocator;
    const fixed_data = buildFixedWorkload();  // 1000 sensors, 100K readings
    
    var world_ts = try World(TimeSeriesStorage).init(allocator);
    defer world_ts.deinit();
    ingestFixedData(&world_ts, fixed_data);
    
    var world_rb = try World(RingBufferStorage).init(allocator);
    defer world_rb.deinit();
    ingestFixedData(&world_rb, fixed_data);
    
    // Run all 12 queries on both worlds
    for (queries) |query| {
        const results_ts = query(&world_ts);
        const results_rb = query(&world_rb);
        try std.testing.expectEqualSlices(/* ... */, results_ts, results_rb);
    }
}
```

**Run `zig build test`.** This test must pass before proceeding.

### 4. Integrate into the benchmark runner

Edit `engine/benchmark/runner.zig`:

```zig
// Add to the list of backends
const backends = [_]type {
    TimeSeriesStorage,
    ColumnarStorage,
    HierarchicalStorage,
    RingBufferStorage,  // <- new
    SoAStorage,
    AoSStorage,
};
```

The benchmark loop will automatically include the new backend in all comparisons.

### 5. Run benchmarks

```sh
zig build bench
```

The output should show latency, memory, and throughput for the new backend on all
12 queries. Include this in the PR.

### 6. Code review checklist

Before handing off, verify:

- [ ] Interface implementation is complete (no unimplemented stubs).
- [ ] Golden-result test passes.
- [ ] No backend-specific code in `query_system.zig` or any query.
- [ ] No global state or singletons in the backend.
- [ ] Internal state is opaque; queries cannot access it directly.
- [ ] Benchmark results show sensible numbers (no NaN, no crashes).
- [ ] Code is minimal; no extra public methods.
- [ ] Memory usage is reasonable (scales with data size, not query count).

---

## Common mistakes

❌ **Writing backend-specific code in queries.**
```zig
// BAD: query checks backend type
if (backend == .RingBuffer) {
    // special case
}
```
✅ **Backend handles all logic internally.**
The query calls the same interface method; the backend decides what to return.

---

❌ **Adding extra public methods.**
```zig
// BAD: query layer calls ringbuffer-specific method
const recent = backend.getLastNReadings(sensor_id, 100);
```
✅ **Query calls the standard interface.**
```zig
// GOOD: query uses the standard `query()` method
const results = backend.query(.{ .sensor_id = sensor_id });
```

---

❌ **Storing state outside the backend.**
```zig
// BAD: global cache
var cache = std.AutoHashMap(...){};
```
✅ **All state lives in the backend struct.**

---

❌ **Non-deterministic timing.**
```zig
// BAD: ambient timing affects results
const start = std.time.nanoTimestamp();
doWork();
const elapsed = std.time.nanoTimestamp() - start;
```
✅ **Metrics system records timing; queries don't.**
Timing lives in `metrics_system.zig`, seeded RNG ensures reproducibility.

---

## When you're done

1. Commit the new backend file.
2. Commit the golden-result test.
3. Run `zig build test` and `zig build bench` — both must pass.
4. Include benchmark results in the PR description.
5. List any open decisions (e.g., "RingBuffer defaults to keeping 1000 readings per
   sensor; this is configurable in the struct").

---

## Minimal example: TimeSeriesStorage

For reference, here's what a minimal backend looks like:

```zig
pub const TimeSeriesStorage = struct {
    allocator: std.mem.Allocator,
    log: std.ArrayList(SensorReading),

    pub fn init(allocator: std.mem.Allocator) !TimeSeriesStorage {
        return TimeSeriesStorage{
            .allocator = allocator,
            .log = std.ArrayList(SensorReading).init(allocator),
        };
    }

    pub fn deinit(self: *TimeSeriesStorage) void {
        self.log.deinit();
    }

    pub fn insert(self: *TimeSeriesStorage, reading: SensorReading) !void {
        try self.log.append(reading);
    }

    pub fn query(self: TimeSeriesStorage, q: QuerySpec) ![]const SensorReading {
        // Return all readings matching q.sensor_id in time range q.start .. q.end
        var results = std.ArrayList(SensorReading).init(self.allocator);
        for (self.log.items) |reading| {
            if (reading.sensor_id == q.sensor_id and
                reading.timestamp >= q.start and
                reading.timestamp <= q.end) {
                try results.append(reading);
            }
        }
        return results.items;
    }

    pub fn memory_used(self: TimeSeriesStorage) usize {
        return self.log.items.len * @sizeOf(SensorReading);
    }
};
```

Implement similarly for your backend. Keep internal layout hidden; expose only the
interface.
