# AGENT.md — Workflow & Operating Guide

This document is **for Claude (or any agent)** working on the digital twin platform.
Read digital-twin/CLAUDE.md first — that is the law. This explains *how* to work within it.

---

## 1. Your job

You are building a **headless benchmarking engine** that measures which storage
backend wins for a given building's sensor workload. You do not render, visualize,
or guess. You measure and report.

The platform has three main loops:

1. **Parse & place:** BIM file → ECS entities with attached sensors.
2. **Generate & ingest:** Synthetic sensor readings into every backend, deterministically.
3. **Query & measure:** Run the same 12 queries against every backend, recording latency,
   throughput, and memory.

Output is JSON (machine-readable) + Markdown (human-readable), with a clear
recommendation: "Use strategy X, expect $Y/year."

---

## 2. Fast "no" guardrails

**Do not do these things; they will be rejected:**

- **Singletons, managers, or global state.** Everything is an entity or component.
- **Backend-specific code in queries.** If you need an if-statement on backend type,
  the logic belongs inside the backend's internal layout.
- **Hard-coded building rules.** Placement, density, retention — it's all data
  (in `profiles.zig` or a data file).
- **Measurements that aren't deterministic.** No ambient timing, thread counts, or
  allocator artifacts. Same input, same seed → same numbers, always.
- **Geometry or rendering.** Position points only. No meshes, no Vulkan, no visual output.
- **External database calls.** All backends are in-process Zig. Period.
- **New files without a reason.** If it's a query, it goes in `queries.zig`. If it's
  a backend, it goes in `backends/`. If it's a rule, it's a data structure in `profiles.zig`.

---

## 3. The workflow

### Phase 1: Storage Abstraction Layer
**Goal:** One comptime interface, two baseline backends (time-series log, columnar),
first benchmark metrics.

- [ ] Wire `zig build`, `zig build test`, `zig build bench`.
- [ ] Define `StorageBackend` comptime interface (init, insert, query, memory_used).
- [ ] Implement TimeSeriesStorage (append-only log).
- [ ] Implement ColumnarStorage (column-per-metric).
- [ ] Golden-result test: both backends answer identically on a fixed dataset.
- [ ] Wire metrics_system to record latency, memory.
- [ ] First benchmark: TimeSeriesStorage vs ColumnarStorage on 1000 sensors, 100K readings.

**Hand off when:** Both backends compile, pass golden-result test, and produce a
benchmark report showing relative wins by query type.

---

### Phase 2: Remaining Storage Backends
**Goal:** Add four more backends (hierarchical, ring buffer, SoA, AoS); auto-participate
in all benchmarks.

For each backend:
- [ ] Implement the backend (same interface as Phase 1).
- [ ] Golden-result test against TimeSeriesStorage.
- [ ] Benchmark against all prior backends.

Use the `digital-twin/add-storage-backend.md` skill — it's the checklist.

**Hand off when:** All six backends exist, all benchmarks run, and reports compare
all six on the same workload.

---

### Phase 3: Query Pattern Library
**Goal:** All 12 production query patterns, looped automatically across all backends.

Queries (from spec Section 6.2):
1. Average sensor reading by zone
2. Peak readings in a time window (zone)
3. Anomaly detection (readings outside ±2σ)
4. Equipment downtime (sensor goes silent >5 min)
5. Cross-zone correlation (two metrics, lag 0–30s)
6. Hourly rollup (avg/min/max per zone per hour)
7. Alert trigger (readings > threshold, persistence 2+ reads)
8. Capacity planning (projected growth, current utilization)
9. Maintenance schedule (equipment age + reliability)
10. Energy cost (predicted monthly bill)
11. Compliance audit (readings in spec range)
12. Supply-chain impact (sensor lost, effect on downtime risk)

For each query:
- [ ] Implement backend-agnostically (pure query on World).
- [ ] Add to `queries.zig`.
- [ ] Golden-result test (all backends give identical results).
- [ ] Benchmark all backends on this query.

Use the `digital-twin/add-query-pattern.md` skill.

**Hand off when:** All 12 queries loop, benchmark reports show per-query winner
rankings, and median/p95/p99 latencies are recorded.

---

### Phase 4: BIM / IFC Parser
**Goal:** Turn real IFC files into ECS entities (hierarchy, positions, zones, equipment).

- [ ] Decide: wrap IfcOpenShell (C-interop) or write minimal subset parser.
- [ ] Parse IFC hierarchy (building → zones → equipment).
- [ ] Extract positions (x, y, z tuples).
- [ ] Extract zone metadata (type, size, climate).
- [ ] Extract equipment metadata (age, model, efficiency).
- [ ] Create ECS entities: one entity per building element, with components for
      each attribute.
- [ ] Handle missing fields gracefully (log warnings, use sensible defaults).
- [ ] Test on a real hospital IFC file (provided or sourced).

**Hand off when:** Parser ingests a real IFC, emits ECS entities, and entity count
matches manual inspection.

---

### Phase 5: Building-Type Profiles
**Goal:** Data-driven placement rules, density assumptions, and retention policies.

For each building type (Hospital, Office, Warehouse, Manufacturing, Campus):
- [ ] Define sensor density (sensors per 10m³).
- [ ] Define sensor distribution (HVAC zones, equipment rooms, hallways, etc.).
- [ ] Define typical query mix (cold queries for historical, hot for current state).
- [ ] Define data retention (30 days? 1 year?).
- [ ] Store as data (struct or JSON), not code.

Use this in sensor placement: given a building type and a raw IFC, place sensors
per the profile.

**Hand off when:** Profiles for 5 building types exist, placement is reproducible
per profile, and reports show per-building-type recommendations.

---

### Phase 6: Synthetic Data Generator
**Goal:** Realistic, deterministic sensor readings for any building type.

- [ ] Core generator: statistical models per sensor type (temperature, humidity,
      power, occupancy).
- [ ] Determinism: seed the RNG at the start; same seed → same readings.
- [ ] Physical plausibility: readings respect bounds (temp 0–50°C, humidity 0–100%),
      daily patterns, equipment off-hours.
- [ ] Validator: check readings against physical bounds and daily patterns.
- [ ] Scale to 100,000 sensors (Phase 1 ceiling).

**Hand off when:** Generator produces realistic data, is deterministic, passes validator,
and benchmarks scale to 100K sensors without memory blowup.

---

### Phase 7: Report Generator & Cost Model
**Goal:** Human-readable reports + cloud-cost recommendations.

- [ ] Report: per-query latencies, memory usage, relative backend rankings.
- [ ] Honest headline: "Benchmarks show *relative* winners; absolute numbers are ±2×."
- [ ] Cost model: storage size × cost/TB + query throughput × cost/op.
- [ ] Recommendation: "Use TimeSeriesStorage for your workload, expect $X/year."
- [ ] Output both JSON (machine) and Markdown (human).

**Hand off when:** Reports are readable, cost models are calibrated (±20% vs real
cloud pricing), and recommendations change sensibly as workload changes.

---

### Phase 8: Calibration & Validation
**Goal:** Compare against DuckDB to catch gross errors (±2× sanity check).

- [ ] Optional DuckDB adapter: ingest the same benchmark workload into DuckDB.
- [ ] Compare median latencies (DuckDB should be faster; we're measuring *relative*
      storage wins, not absolute speed).
- [ ] Flag if any backend is >2× slower than DuckDB or >2× faster (likely measurement bug).
- [ ] Document calibration in the report.

**Hand off when:** Calibration runs without crashing, DuckDB numbers are plausible,
and reports include a calibration note.

---

## 4. Prompt structure

When starting a task, you will receive a **rule-aware implementation prompt**. It:

1. **Names the task** (e.g., "Phase 2: Add ColumnarStorage backend").
2. **Lists constraints** (from CLAUDE.md: no singletons, backend-invisible to queries, etc.).
3. **Defines done:** what files, tests, and benchmarks must exist.
4. **Suggests structure:** where files go, what functions/types to define.
5. **Calls out traps:** common mistakes (e.g., timing in the query layer, backend-specific logic leaking).

**Follow the prompt.** It is derived from review feedback on the last iteration.

---

## 5. Testing & benchmarking

**Unit tests:** `zig build test`. All golden-result tests must pass; backends must
produce identical output.

**Benchmarks:** `zig build bench`. Records latency, throughput, memory for every
query on every backend. Publish the full results table in the PR.

**Before handing off:** run both. If `zig build test` fails, the PR will not merge.
If `zig build bench` crashes or reports NaN, fix it before handing off.

---

## 6. Handling ambiguity

The spec lists 10 open decisions (IFC wrapper, scale ceiling, report format, tiering,
calibration). **Do not silently pick one.** If a task forces a decision:

1. **Surface it in the PR description** (or a GitHub issue if one is open).
2. **State the choice:** "Using DuckDB for calibration; IfcOpenShell via C-interop for parsing."
3. **Explain the tradeoff:** why this choice over alternatives.
4. **Keep it reversible:** if the choice is data (a profile, a flag), make it obvious
   how to change it later.

---

## 7. Code style

- **Zig idioms:** error unions, comptime, defer, allocators.
- **Naming:** `snake_case` for functions/variables, `PascalCase` for types.
- **Comments:** explain *why*, not *what*. The code says what.
- **No magic numbers:** constants have names.
- **Allocators:** always explicit (e.g., `gpa` for general-purpose, `arena` for scope).

---

## 8. Files you own

You will create and maintain:

- `engine/ecs/storage/storage_backend.zig` — the interface.
- `engine/ecs/storage/backends/*.zig` — six backends.
- `engine/ecs/systems/metrics_system.zig` — timing & memory recording.
- `engine/ecs/systems/query_system.zig` — benchmark loop.
- `engine/benchmark/queries.zig` — all 12 query patterns.
- `engine/bim/ifc_parser.zig` — BIM parsing.
- `engine/bim/profiles.zig` — building-type rules (data).
- `engine/synthetic/generator.zig` — synthetic data.
- `engine/synthetic/validator.zig` — plausibility checks.
- `engine/benchmark/cost_model.zig` — cloud-cost estimation.
- `engine/benchmark/report.zig` — report generation.
- `build.zig` — wiring the build commands.

You do **not** create:
- The ECS core (entities, components, queries) — that is in-house.
- The main entry point — it exists.
- Utilities (allocators, time, RNG) — use Zig stdlib or the in-house libs.

---

## 9. Handoff checklist

When you finish a phase:

- [ ] Code compiles: `zig build` ✓
- [ ] Tests pass: `zig build test` ✓
- [ ] Benchmarks run: `zig build bench` ✓ (and output is in the PR)
- [ ] Golden-result tests cover new storage/queries ✓
- [ ] No new singletons or global state ✓
- [ ] All rules (placement, profiles, pricing) are data, not code ✓
- [ ] PR description surfaces any open decisions ✓
- [ ] Code is the smallest change that works ✓

---

## 10. When you're stuck

- **Reread digital-twin/CLAUDE.md.** Violations of the non-negotiables are common mistakes.
- **Check the folder structure.** Files go in specific places.
- **Golden-result test first.** Write the test before the backend.
- **Start with stubs.** Implement the interface, then fill it in.
- **Ask in the PR description.** Surface ambiguity rather than guessing.
