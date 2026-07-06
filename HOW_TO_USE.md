# How to Use the Digital Twin Optimization Platform

A step-by-step walkthrough for going from a real IFC building model to a
storage-backend recommendation, a sensor schematic, and a readable report.

---

## 1. Download the executable

Head to [`releases/`](releases/) and download the pre-built executable for your platform:

- **Windows**: `dt.exe`
- **Linux**: `dt-linux`
- **macOS (Intel)**: `dt-macos-x86_64`
- **macOS (Apple Silicon)**: `dt-macos-aarch64`

Save it somewhere on your computer.

### Optional: Build from source

If you prefer to compile it yourself:

```sh
zig build
```

This requires [Zig](https://ziglang.org/) master (0.16.0+). The compiled
executable lands in `zig-out/bin/`. The `dt` executable is always built
ReleaseFast regardless of `-Doptimize` — it's a measurement tool, and a
Debug build would silently distort a multi-year simulation's wall time.

---

## 2. Prepare your IFC file

You'll need an **IFC file** (`.ifc`, SPF text format) for the building you want to model.

IFC assets are **not tracked in this repository** (they're large binaries;
`assets/IFC/` is gitignored) — bring your own export, or grab a public
sample. The files this guide's examples use, all validated end-to-end:

- `AC20-FZK-Haus.ifc` — a small single-family house (KIT's public sample), good for a first run
- `LargeHospitalComplex.ifc` — a 2000-element hospital, the large-scale stress case
- `2KHRJ17-HASC-SD-710-EV-MOD-00001.ifc` — a medium office building (760 equipment items)

Any Revit/ArchiCAD IFC export in SPF text format should parse; missing or
vendor-specific fields are handled gracefully.

---

## 3. Run the executable from a terminal

**Important:** This is a headless CLI tool. You **must** run it from a terminal/command prompt —
double-clicking the executable will just flash and exit.

Two things trip people up, both about **paths**:

1. **The `--bim` path is relative to your terminal's current directory**, not to
   where the executable lives. If you `cd` into the folder holding the .exe and
   the IFC file is elsewhere, you need `..\` (Windows) or `../` (Linux/macOS)
   to back out, or just use a full path.
2. **PowerShell won't run an executable from the current directory by name
   alone** — you must prefix it with `.\` (this is a PowerShell security
   feature, not a bug). `cmd.exe` and Linux/macOS shells don't have this
   restriction.

Open a terminal/command prompt and run:

```bash
# Linux/macOS:
./dt-linux --bim assets/IFC/AC20-FZK-Haus.ifc

# Windows, cmd.exe:
dt.exe --bim assets\IFC\AC20-FZK-Haus.ifc

# Windows, PowerShell — note the .\ prefix:
.\dt.exe --bim assets\IFC\AC20-FZK-Haus.ifc
```

**If you downloaded the .exe into `releases/` and run it from there**, the
sample IFC files are one directory up, so the path becomes:

```powershell
.\dt.exe --bim ..\assets\IFC\AC20-FZK-Haus.ifc
```

When in doubt, use a full path instead of a relative one — it removes the
ambiguity entirely:

```powershell
.\dt.exe --bim "C:\digital-twin-platform\assets\IFC\AC20-FZK-Haus.ifc"
```

(Adjust the path to your IFC file.)

### Flags

| Flag     | Required | Description |
|----------|----------|-------------|
| `--bim`  | yes      | Path to the IFC file to parse and populate sensors from. |
| `--out`  | no       | Output directory for reports. Default: `benchmark-results`. |
| `--help` | no       | Print usage and exit. |

There is no `--type` flag anymore: the tool derives everything from what it
actually parses out of YOUR building — which sensor types get placed (from
the real elements/zones/equipment found), each type's sampling rate and
retention window, and which of the 12 query patterns the recommendation
weights (the union of the placed types' relevant queries). That is
CLAUDE.md's "a hospital is not a factory" principle taken to its
conclusion: the building itself is the profile.

### What happens when you run it

1. The IFC file is parsed into building elements, zones, and equipment.
2. Sensors are placed on matching elements per data-driven placement rules;
   zone/floor topology and real sensor positions are registered from the
   IFC's own coordinates (zone-, floor-, and radius-scoped queries run
   against the real building, not synthetic geometry).
3. A **live day-zero simulation** runs: the building starts empty and
   accumulates synthetic sensor data day by day for its whole derived
   lifetime (driven by the longest retention window among the placed
   sensor types — e.g. structural sensors push it to ~7 years). Backends
   run **sequentially**: the first pass generates the data once and spills
   it to an on-disk replay cache; the other backends replay that identical
   feed, so results are byte-for-byte comparable while only one backend's
   data is ever in RAM.
4. At log-spaced **checkpoints** (day 1, week 1, month 1 ... steady state)
   every query in the building's mix is timed against each backend's real
   accumulated state — that's the latency-vs-building-age growth curve.
5. A **compound recommendation** is computed: a real-time track (who
   answers "latest value" queries fastest) and a historical track (who
   wins aggregations/rollups/anomaly scans over full retention), plus a
   per-sensor-type breakdown.
6. Everything is printed to the terminal and written to disk.

Expect terminal output like this (a large hospital; a small house prints
the same shape with smaller numbers):

```
[1/6] Parsing IFC: assets/IFC/LargeHospitalComplex.ifc...
Parsed assets/IFC/LargeHospitalComplex.ifc: 2007 elements, 520 zones, 760 equipment items (0.1s).

[2/6] Placing sensors...
Placed 1520 sensors (0.0s).

[3/6] Setting up simulation...
  Sim duration: 2682 days (7.3 years)
  Checkpoints: 13 — day 1, week 1, month 1, ... year 7, steady state
  Backends: 5

[4/6] Running live day-zero simulation...
--- Backend 1/5: TimeSeries (generating + spilling replay cache) ---
  [TimeSeries] === Checkpoint day 1 (day 1/2682) ===
  ...
[5/6] Computing recommendations...

=== Recommendation (LargeHospitalComplex) ===
Real-time track (latest_* queries — all backends compete):
Backend              Score     Coverage
Hierarchical         1.000         100%
...
Historical track (aggregation/historical/spatial/anomaly — full-retention backends only):
...
Deployment combo: Hierarchical (live) + Hierarchical (historical)

[6/6] Writing reports...
  Wrote recommendation.md + simulation.json to benchmark-results/
  Wrote schematic.svg to benchmark-results/
```

### How long does it take?

Simulated duration is derived from the placed sensor types' retention
windows, and each type stops generating once its own retention window has
filled (its dataset is at steady-state size after that — longer generation
would change nothing a query can see). Rough real-world figures from the
two shipped samples on an ordinary 16 GB machine (release build):

- `AC20-FZK-Haus.ifc` (small house, 39 sensors, 7.3 simulated years): **~8 seconds**.
- `LargeHospitalComplex.ifc` (1520 sensors, 7.3 simulated years, ~163M readings × 5 backends): **~8 minutes**, peaking around 7.5 GB RAM at the final checkpoint.

---

## 4. Read the output

Everything lands in `--out` (default `benchmark-results/`):

| File | What it's for |
|------|----------------|
| `recommendation.md` | The human-readable report: building stats, sensor counts by type, the compound recommendation (real-time + historical tracks + per-type breakdown), a per-query winner table, the latency-vs-building-age growth curve, per-backend simulation cost, steady-state data volume per type, and an ingest data-quality table. **Start here.** |
| `simulation.json` | The same data machine-readable: per-backend stats, growth-curve points, type volumes and quality. |
| `schematic.svg` | A rough floor-by-floor map: zone labels and sensor positions (colored by sensor type), derived directly from the IFC file's real coordinates. Open it in a browser or image viewer. |

### Reading the recommendation

The headline is a **deployment combo**, not a single winner, because real
deployments split hot and cold paths:

- **Real-time track** — all backends compete on the `latest_*` queries.
  A tiny count-capped cache (RingBuffer, 10 readings/sensor) can
  legitimately win here.
- **Historical track** — aggregations, rollups, spatial and anomaly
  queries; only full-retention backends compete (a cache that evicted
  the data can't fake-win a query it can't actually answer).

Within each track:

- **Score** = weighted average of (this backend's median latency / the
  per-query winner's median latency), across every query in this
  building's derived mix. **1.00 = this backend won every weighted
  query.** Higher is worse.
- **Coverage** = fraction of the weighted queries this backend has data
  for. Check coverage before trusting a score.

All scores come from the **steady-state checkpoint** — the building at
retention-full, actively-evicting age — while the growth-curve table shows
how each query's latency evolved from day 1 to get there.

### Honesty headline (per CLAUDE.md §6)

Relative rankings between backends are reliable for *your* workload.
Absolute latency numbers are approximate — this tool doesn't model network
I/O, replication, page caches, or query planners. It tells you which
storage *shape* fits your query mix, not what a specific database will
measure in production.

---

## 5. (Optional) Run the synthetic benchmark suite instead

If you don't have a real IFC file handy, or want to see backend behavior
across multiple dataset sizes (Small/Medium/Large), run the standalone
benchmark suite instead:

```sh
zig build bench
```

This generates its own deterministic synthetic dataset (no IFC file
needed) and writes `latency.md`, `latency.json`, and `benchmark.html` to
`benchmark-results/`. `benchmark.html` is an interactive dashboard with
per-scale tabs; `latency.md` includes a per-query winner table that flags
when the measured result agrees or disagrees with the textbook
storage×query expectation.

---

## 6. Run the test suite

Before trusting any change to the codebase, or just to confirm your build
is healthy:

```sh
zig build test
```

This runs every unit test and golden-result equivalence test (every
backend must produce identical query results on the same seeded dataset).

---

## Troubleshooting

- **"No sensors placed"** — the IFC file has no elements matching any
  placement rule (the rules key off parsed element/zone/equipment types).
  Check the parsed element/zone/equipment counts in the terminal output —
  if they're all near zero, the file may use IFC constructs outside the
  supported subset.

- **Run takes a long time** — expected for very large buildings: sensor
  count and the longest retention window among placed types drive the
  simulated duration (a building with structural sensors simulates ~7
  years). A 1500-sensor hospital takes ~8 minutes; progress heartbeats
  print every 100 simulated days so you can see it moving. The build
  system always compiles the `dt` executable as ReleaseFast, so there is
  no debug-build trap. If memory is tight, note the peak lands at each
  backend's final (steady-state) checkpoint.

- **On macOS: "cannot be opened because the developer cannot be verified"** —
  macOS blocks unsigned binaries by default. Either:
  - Right-click the executable, select "Open", and confirm
  - Or allow unsigned executables: `sudo xattr -rd com.apple.quarantine /path/to/dt-macos-x86_64`
