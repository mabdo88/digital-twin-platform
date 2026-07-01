# CLAUDE.md — Digital Twin Optimization Platform

> Project rules and context for Claude (and any AI agent) working in this repository.
> **Read this before writing any code.** These rules are non-negotiable; violations
> will be rejected in review.

---

## 1. What this project is

A **headless benchmarking and optimisation research platform** for digital-twin data
infrastructure. Given a real BIM/CAD model and a set of sensor definitions, it:

1. parses the building (IFC) into ECS entities,
2. attaches virtual sensors,
3. generates realistic synthetic sensor data,
4. runs every relevant query pattern against every storage backend, and
5. emits a measured, project-specific recommendation: which storage strategy to use
   and what it will cost.

> **Core principle.** This is **not** a visualization tool, dashboard, or rendering
> engine. Output is structured data (JSON) + a human-readable report. No guessing,
> no industry defaults — measured answers specific to the project.

**Slogan that drives every design decision:** *a hospital is not a factory.* Sensor
density, query mix, and retention differ per building type, so the platform measures
rather than assumes.

---

## 2. Tech stack & language

- **Language:** Zig (existing in-house ECS engine).
- **Architecture:** Pure ECS (entities + components + systems). The ECS layer is a
  **storage abstraction** — the same queries run unchanged across every backend.
- **Domain:** Digital twin / building IoT.
- **No external database dependencies.** Every storage backend is pure in-process Zig.
- **Headless.** No Vulkan, no GLFW, no rendering of any kind.
- **Cross-platform.** Must build and run unmodified on Windows, Linux, and macOS.
  Use only `std.fs` / `std.process` / `std.Io` — no OS-specific APIs, no shell-outs
  to platform tools, no hard-coded path separators (use `std.fs.path` helpers).
  File selection is a CLI argument (`--bim <path>`), not a GUI file picker.

---

## 3. Non-negotiable rules

### 3.1 ECS rules
- **No manager classes. No singletons. No global state.** Everything is entities and components.
- **Systems are pure functions over `World` queries.** A system does not own state.
- **No new file, component, or system without a clear reason.** If something can be
  expressed as a query on existing components, it must be.
- When in doubt: **one entity, multiple components** — not one component with nested structs.

### 3.2 Storage rules
- Every backend implements the `StorageBackend` interface **exactly**. No extra public methods.
- Backends are compared **apples-to-apples**. No backend-specific optimisation leaks
  into the query layer.
- A backend may optimise its **internal** layout freely; it may **not** change the interface.
- **All backends must produce identical query results** for the same input data.
  Results are validated before benchmarks run.

### 3.3 BIM parser rules
- Extract **only** what Section 7.1 of the spec lists (hierarchy, positions, types,
  zone/equipment metadata). **No geometry reconstruction** beyond position points.
- Parser output is **ECS entities only** — no intermediate non-component data structures.
- Handle missing fields **gracefully**; IFC files are inconsistent across vendors.

### 3.4 Benchmark rules
- **All benchmarks are deterministic.** RNG is seeded; same input → same output, always.
- Metrics are recorded by **`metrics_system.zig` only**. No ad-hoc timing elsewhere.
- Each query runs a **minimum of 25 iterations** per backend. Report median, p95, p99.
- Memory is measured **after ingest, before queries, and after queries**.

### 3.5 General rules
- No rendering. No Vulkan. No GLFW. Headless tool.
- No external database dependencies. All backends are pure Zig in-process.
- **No hard-coded building assumptions. Rules are data, not code** (placement rules,
  building profiles, vendor pricing are all data structures).
- Every new backend or query **must include a benchmark result** proving it works.

---

## 4. Folder structure (authoritative)

```
engine/
├── ecs/
│   ├── components/
│   │   ├── sensor.zig          // SensorReading, SensorMetadata, ZoneLocation
│   │   └── building.zig        // BuildingElement, ZoneMetadata
│   ├── systems/
│   │   ├── ingest_system.zig   // Writes synthetic sensor data into the world
│   │   ├── query_system.zig    // Runs all benchmark queries
│   │   ├── metrics_system.zig  // Records latency, throughput, memory
│   │   └── report_system.zig   // Outputs final recommendation report
│   └── storage/
│       ├── storage_backend.zig // Shared comptime interface
│       └── backends/
│           ├── timeseries_storage.zig
│           ├── columnar_storage.zig
│           ├── hierarchical_storage.zig
│           ├── ringbuffer_storage.zig
│           ├── soa_storage.zig
│           └── aos_storage.zig
├── bim/
│   ├── ifc_parser.zig          // Parses IFC hierarchy + metadata
│   ├── sensor_placer.zig       // Attaches sensors to building elements
│   └── profiles.zig            // Building-type profiles
├── synthetic/
│   ├── generator.zig           // Core generator w/ statistical models
│   └── validator.zig           // Physical-plausibility checks
├── benchmark/
│   ├── runner.zig              // Orchestrates runs across all backends
│   ├── queries.zig             // All 12 query patterns
│   ├── cost_model.zig          // Cloud-cost estimation
│   └── report.zig              // Report generation
├── calibration/
│   └── duckdb_adapter.zig      // Optional real-engine validation
└── main.zig                    // Entry point
```

When adding files, follow this layout. Do not invent new top-level directories
without a documented reason.

---

## 5. The storage-abstraction contract

The ECS `World` is parameterised at compile time with a storage backend. The same
query compiles and runs against any backend:

```zig
var world_ts  = World(TimeSeriesStorage).init();
var world_col = World(ColumnarStorage).init();
const r1 = benchmark(world_ts,  query_avg_temp_zone);
const r2 = benchmark(world_col, query_avg_temp_zone);
```

A query **never** references a concrete backend. If you find yourself writing
`if (backend == .Columnar)` inside a query, stop — that logic belongs in the backend's
internal layout, not the query.

---

## 6. What the benchmarks do (and don't) measure

**Preserve:** fundamental data-structure characteristics (B-tree vs columnar vs
append-only log vs ring buffer), relative rankings (which backend wins which query,
by what order of magnitude), and memory/CPU/compression efficiency.

**Do NOT measure:** network I/O, replication/consensus, DBMS page cache, query
planners, allocator strategies, durability (WAL/fsync), concurrent connections.

**Honest headline (must appear in every report):** the benchmarks tell you whether a
columnar layout beats a time-series log *for your workload*. They do **not** tell you
whether ClickHouse answers in 80 ms or 800 ms. Absolute numbers are approximate;
**relative rankings are reliable.** The optional DuckDB calibration pass and a
±2× sanity check guard against gross magnitude errors.

---

## 7. Build, test & run

```sh
zig build            # compile the platform
zig build test       # run unit + golden-result tests
zig build bench      # run the full benchmark suite
zig build run -- --bim path/to/model.ifc --type Hospital --scale 5000
```

> **Agent note:** if these commands are not yet wired in `build.zig`, wiring them is a
> legitimate early task — but do it as its own change, documented in the PR.

---

## 8. Definition of done (every change)

1. Compiles with `zig build` and passes `zig build test`.
2. If it touches storage or queries: **golden-result test proves identical output
   across all backends.**
3. If it adds a backend or query: **a benchmark result is included.**
4. No new global state, manager, or singleton introduced.
5. Any new "rule" (placement, profile, pricing) is **data**, not branching code.
6. The change is the smallest one that satisfies the requirement.

---

## 9. Skills available to agents

Reusable, repeatable procedures live in `.cascade/digital-twin/`:

- **`add-storage-backend.md`** — add a new backend that auto-participates in all benchmarks.
- **`add-query-pattern.md`** — add a backend-agnostic query to the pattern library.

Follow these verbatim when the task matches; they encode the review checklist.

The same folder also holds **status docs** (read as current state, not as procedures):

- **`backend-audit.md`** — per-backend correctness verdict, rechecked against live
  benchmark output. Read before touching a backend's internals.
- **`Digital Twin Roadmap.html`** — the phase-by-phase completion tracker, rechecked
  against actual repo state each time it's updated. Treat this as more current than
  `AGENT.md`'s phase checklists, which have drifted from what was actually built
  (e.g. `AGENT.md`'s Phase 3 query list no longer matches `queries.zig`).
- **`storage-redesign-plan.md`** — agreed 2026-06-30, **not yet implemented**: real
  retention-bound per-sensor datasets (no toy 1h dataset, no sampling/replication
  across sibling sensors), real eviction across every backend (not just
  RingBuffer), a live tick-based simulator, and no backend-eligibility assumptions
  (every backend races every query, empirical winner reported). This plan
  explicitly supersedes §3.4's "minimum 25 iterations" rule below once
  implemented — read it before touching `synthetic/generator.zig`,
  `ecs/storage/*`, `benchmark/queries.zig`, or `main.zig`'s orchestration.

---

## 10. Open decisions (track, don't silently assume)

- **IFC wrapper — resolved:** went with a hand-rolled subset parser (`ifc_parser.zig`),
  not an IfcOpenShell C-interop wrapper. Validated end-to-end against two real Revit
  IFC exports (see the Roadmap, Phase 4).
- **Scale ceiling:** target 100,000 sensors for Phase 1; keep allocation strategy
  able to grow. Not yet exercised — the standalone synthetic generator (Phase 6)
  doesn't exist yet, so the largest sensor count tested today is the benchmark
  suite's "Large" tier (100 sensors, 500 readings each = 50,000 readings total).
- **Report format:** emit JSON, a human-readable Markdown report, **and** an
  interactive HTML dashboard — all three written by `engine/benchmark/report.zig`
  (`latency.json`, `latency.md`, `benchmark.html`).
- **Tiered strategies:** the platform *recommends* mixed strategies but only
  *benchmarks* single backends; recommendations come from per-query winners + cost.
  Not yet built (Phase 7).
- **Calibration:** DuckDB is the primary calibration; vendor benchmarks are optional
  metadata. Not yet built (Phase 8).

If a task forces one of these decisions, surface it in the PR description rather than
quietly hard-coding a choice.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
