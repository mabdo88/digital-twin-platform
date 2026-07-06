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
- Metrics are recorded by **`metrics_system.zig` only** (`timeQuery` for queries,
  `timeMutation` for state-mutating operations like ingest/prune). No ad-hoc timing elsewhere.
- **Live day-zero simulation** (replaces the former bulk-preload + live-tail
  methodology): the building starts at simulated day zero with empty backends.
  A `synthetic.Stream` feeds readings chunk-by-chunk (1 simulated day per chunk),
  pruning to retention windows as simulated time advances, with queries
  benchmarked at log-spaced checkpoints. Sim duration derives from the placed
  sensor types' retention depths (`deriveSimDays`). Backends run
  **sequentially** through the full timeline (one backend's history in RAM at
  a time): the first pass generates once and spills each day's accepted
  readings to an on-disk replay cache; later backends replay it byte-identically.
  Each sensor type stops generating at its **own** retention-derived horizon
  (`Stream.capHorizons`) and its prune watermark freezes with it — every query
  anchors its window to the data's newest reading, so a frozen type's
  steady-state window measures identically at any later checkpoint. See
  `benchmark/simulation.zig`, `.cascade/digital-twin/live-simulation-plan.md`,
  and `.cascade/digital-twin/sequential-execution-and-audit.md`.
- **Iteration count is workload-dependent, by deliberate design decision (see
  `.cascade/digital-twin/storage-redesign-plan.md`):**
  - The **real per-building path** (`main.zig`) runs the live simulation and
    measures each query **once** at each checkpoint (`timeQuery` with
    `iterations = 1`). The old "minimum 25 iterations" rule existed only to fake
    statistical spread over a 1-hour toy dataset via resampling; with real per-sensor
    volume there is nothing to resample, so single-shot is the honest measurement.
  - The **internal multi-scale regression suite** (`runner.zig`, against
    `dataset.zig`'s shared synthetic fixture) still runs a fixed per-tier iteration
    count for stable relative rankings on that small fixture — it is a CI-style
    regression check, not the project-specific recommendation.
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
│   │   ├── ingest_system.zig   // Ingest-time validation (bounds rejection)
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
│           ├── lake_storage.zig
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
│   ├── simulation.zig          // Live day-zero simulation harness
│   ├── cost_model.zig          // Cloud-cost estimation
│   └── report.zig              // Report generation (MD + JSON + HTML)
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
zig build run -- --bim path/to/model.ifc --out results-dir
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
- **`storage-redesign-plan.md`** — agreed 2026-06-30, **implemented and superseded
  by the live simulation**: real retention-bound per-sensor datasets were the
  first step; the current methodology is the live day-zero simulation (see
  `live-simulation-plan.md`). RingBuffer remains capped at 10 readings/sensor
  (flat, all types) via `setRetentionHint`, and compound recommendations split
  real-time vs historical tracks. Read it for historical context before
  touching `synthetic/generator.zig`, `ecs/storage/*`, `benchmark/queries.zig`,
  or `main.zig`'s orchestration.
- **`live-simulation-plan.md`** — agreed 2026-07-02, **implemented**: replaces
  the bulk-preload + live-tail methodology with a streaming simulation. The
  building starts at day zero with empty backends; a `synthetic.Stream` feeds
  readings chunk-by-chunk (1 day per chunk), pruning to retention as simulated
  time advances, with queries benchmarked at log-spaced checkpoints. See
  `benchmark/simulation.zig` for the implementation.
- **`sequential-execution-and-audit.md`** — agreed 2026-07-05, **implemented and
  verified at hospital scale**: extends the live simulation with sequential
  backend passes over an on-disk replay cache (one backend's history in RAM at
  a time, generation happens once), per-type generation-horizon capping
  (Step 4), and the full-scale audit findings — including the spatial-query
  real-position fix and the RingBuffer eviction-stat fix. The most current of
  the status docs; read it first when touching `benchmark/simulation.zig`.

---

## 10. Open decisions (track, don't silently assume)

- **IFC wrapper — resolved:** went with a hand-rolled subset parser (`ifc_parser.zig`),
  not an IfcOpenShell C-interop wrapper. Validated end-to-end against two real Revit
  IFC exports (see the Roadmap, Phase 4).
- **Scale ceiling:** target 100,000 sensors for Phase 1; keep allocation strategy
  able to grow. Largest exercised to date (2026-07-06): 1,520 sensors on a real
  hospital IFC through the full 7.3-year live simulation — ~163M readings
  generated once, replayed to 5 backends, ~8 min wall / ~7.5 GB peak on a
  16 GB machine (see `sequential-execution-and-audit.md`).
- **Report format:** the regression suite (`zig build bench`) emits JSON, a
  human-readable Markdown report, **and** an interactive HTML dashboard — all
  three written by `engine/benchmark/report.zig` (`latency.json`, `latency.md`,
  `benchmark.html`). The per-building path (`dt --bim ...`) writes
  `recommendation.md`, `simulation.json`, and `schematic.svg`.
- **Tiered strategies — resolved:** the platform now emits **compound recommendations**
  via `report.recommendCompound`: a real-time track (all backends compete, RingBuffer
  wins on `latest_*` queries) and a historical track (full-retention backends only;
  RingBuffer excluded). The final recommendation per building/type is a deployment
  combo: "<real-time winner> for live queries + <historical winner> for everything
  else." `main.zig` consumes this for both building-level and per-type reports.
- **RingBuffer eviction sizing — resolved:** flat capacity of 10 readings per
  sensor for ALL types (no per-type formula). `main.zig` calls
  `setRetentionHint(sensor_type, 10)` for every placed type before ingest.
  RingBuffer is a deliberately tiny real-time-only cache; its existing eviction
  (11th write evicts oldest) handles it. See `storage-redesign-plan.md` for the
  full reasoning.
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
