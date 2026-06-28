# Skill: Add a Query Pattern

## When to use

You have been asked to add a new query pattern to the library (e.g., "Add a query
that finds anomalies: readings outside ±2σ of the zone's mean").

## Definition of done

1. ✅ Query is implemented in `engine/benchmark/queries.zig` as a pure function over `World`.
2. ✅ Query is backend-agnostic (does not reference concrete storage backend).
3. ✅ Golden-result test: all backends return identical results for the same input.
4. ✅ Query runs on all backends in the benchmark loop without crashing.
5. ✅ Benchmark results (latency, throughput) are recorded and included in the PR.
6. ✅ No state leakage; query is a pure function.

---

## Procedure

### 1. Understand the query specification

The query is defined in the platform spec (Section 6.2). Read it carefully:

- **Query name:** e.g., "Anomaly Detection"
- **Input:** sensor ID, time window, or zone ID
- **Output:** list of anomalous readings (timestamp, value, deviation)
- **Logic:** e.g., readings that fall outside mean ± 2σ

### 2. Add to `engine/benchmark/queries.zig`

Create a function with a standard signature:

```zig
pub fn queryAnomalyDetection(
    world: *const World,
    params: struct {
        zone_id: u32,
        start_time: i64,
        end_time: i64,
    },
) ![]const AnomalyResult {
    var arena = std.heap.ArenaAllocator.init(world.allocator);
    defer arena.deinit();
    
    // Query the world (backend-agnostically)
    var results = std.ArrayList(AnomalyResult).init(arena.allocator());
    
    // Iterate through all readings in the zone
    var query = world.query()
        .filter(SensorReading)
        .filter(SensorMetadata)
        .filter(ZoneLocation);
    
    var iterator = query.iterator();
    while (iterator.next()) |entity| {
        const reading = entity.get(SensorReading);
        const location = entity.get(ZoneLocation);
        
        if (location.zone_id != params.zone_id) continue;
        if (reading.timestamp < params.start_time or 
            reading.timestamp > params.end_time) continue;
        
        // Calculate mean and stddev (from prior readings)
        // Flag if outside ±2σ
        if (isAnomaly(reading, mean, stddev)) {
            try results.append(.{
                .timestamp = reading.timestamp,
                .sensor_id = entity.id,
                .value = reading.value,
                .deviation = calculateDeviation(reading, mean),
            });
        }
    }
    
    return results.items;
}
```

**Key rules:**
- Query takes a `*const World` and a params struct.
- Query iterates using `world.query().filter(...).iterator()`.
- Query **never** checks the backend type or calls backend-specific methods.
- Query returns results allocated in an arena (caller's responsibility to copy if needed).
- All logic is pure (same input → same output, always).

### 3. Add to the query registry

In `engine/benchmark/queries.zig`, add to the public list:

```zig
pub const all_queries = [_]QueryPattern {
    // ... existing queries
    .{
        .name = "Anomaly Detection",
        .run = queryAnomalyDetection,
        // ... metadata
    },
};
```

### 4. Write the golden-result test

In `tests/golden_results.zig`:

```zig
test "Anomaly detection query produces identical results on all backends" {
    const allocator = std.testing.allocator;
    const fixed_data = buildFixedWorkload();
    
    var world_ts = try World(TimeSeriesStorage).init(allocator);
    defer world_ts.deinit();
    ingestFixedData(&world_ts, fixed_data);
    
    var world_col = try World(ColumnarStorage).init(allocator);
    defer world_col.deinit();
    ingestFixedData(&world_col, fixed_data);
    
    // Run the query on both
    const results_ts = try queryAnomalyDetection(&world_ts, .{
        .zone_id = 1,
        .start_time = 0,
        .end_time = 100_000,
    });
    
    const results_col = try queryAnomalyDetection(&world_col, .{
        .zone_id = 1,
        .start_time = 0,
        .end_time = 100_000,
    });
    
    // Compare results
    try std.testing.expectEqual(results_ts.len, results_col.len);
    for (results_ts, results_col) |ts, col| {
        try std.testing.expectEqual(ts.timestamp, col.timestamp);
        try std.testing.expectEqual(ts.sensor_id, col.sensor_id);
        try std.testing.expectApproxEqAbs(ts.value, col.value, 1e-6);
    }
}
```

**Run `zig build test`.** This test must pass.

### 5. Verify in the benchmark loop

The benchmark runner will automatically include this query when you run:

```sh
zig build bench
```

The output should show latency and throughput for this query on all backends.

### 6. Code review checklist

Before handing off:

- [ ] Query is a pure function (no side effects, no global state).
- [ ] Query uses only `world.query()` (backend-agnostic).
- [ ] Golden-result test passes on all backends.
- [ ] Query handles edge cases (empty zones, time range with no data, zero readings).
- [ ] Results are deterministic (same seed → same results).
- [ ] Benchmark runs without crashing.
- [ ] No backend-specific code or type checks.
- [ ] Allocations are scoped (arena or temporary).

---

## Common mistakes

❌ **Query checks backend type.**
```zig
// BAD: query branches on backend
if (backend_type == .Columnar) {
    // special case for columnar
}
```
✅ **Query is pure; backend decides how to answer.**

---

❌ **Query keeps global state.**
```zig
// BAD: static cache survives across queries
var cache = std.AutoHashMap(u32, f32){};
```
✅ **Local scope (arena) or allocate fresh per call.**

---

❌ **Query does timing.**
```zig
// BAD: query measures latency
const start = std.time.nanoTimestamp();
// ... do work
const elapsed = std.time.nanoTimestamp() - start;
```
✅ **Metrics system handles timing; query computes results.**

---

❌ **Query allocates unbounded memory.**
```zig
// BAD: results array grows without limit
var results = std.ArrayList(Result).init(allocator);
// ... add millions of items
```
✅ **Use an arena; cap result size or stream results.**

---

## When you're done

1. Commit the query function to `queries.zig`.
2. Commit the golden-result test.
3. Run `zig build test` and `zig build bench` — both must pass.
4. Include the new query's benchmark results in the PR.
5. In the PR description, note any assumptions (e.g., "assumes at least 10 readings
   per sensor to compute stddev; returns empty if fewer").

---

## Minimal example: Average by Zone

Here's a simple query for reference:

```zig
pub fn queryAvgByZone(
    world: *const World,
    params: struct {
        zone_id: u32,
        metric: []const u8,  // "temperature", "humidity", etc.
    },
) !f64 {
    var sum: f64 = 0;
    var count: u32 = 0;
    
    var query = world.query()
        .filter(SensorReading)
        .filter(ZoneLocation);
    
    var iterator = query.iterator();
    while (iterator.next()) |entity| {
        const location = entity.get(ZoneLocation);
        if (location.zone_id != params.zone_id) continue;
        
        const reading = entity.get(SensorReading);
        if (!std.mem.eql(u8, reading.metric_type, params.metric)) continue;
        
        sum += reading.value;
        count += 1;
    }
    
    return if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0;
}
```

Simple, pure, backend-agnostic. Use this as a template.
