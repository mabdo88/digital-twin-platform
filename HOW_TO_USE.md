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
zig build -Doptimize=ReleaseFast
```

This requires [Zig](https://ziglang.org/) master (0.16.0+). The compiled executable lands in `zig-out/bin/`.

---

## 2. Prepare your IFC file

You'll need an **IFC file** (`.ifc`, SPF text format) for the building you want to model.

Two real sample files ship in [`assets/IFC/`](assets/IFC/):
- `AC20-FZK-Haus.ifc` — a small single-family house, good for testing
- `2KHRJ17-HASC-SD-710-EV-MOD-00001.ifc` — a medium office building (182 equipment items)
- `2KHRJ17-CUN-TD-712-EL-MOD-00001-00-IFC.ifc` — another medium building

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
./dt-linux --bim assets/IFC/AC20-FZK-Haus.ifc --type office

# Windows, cmd.exe:
dt.exe --bim assets\IFC\AC20-FZK-Haus.ifc --type office

# Windows, PowerShell — note the .\ prefix:
.\dt.exe --bim assets\IFC\AC20-FZK-Haus.ifc --type office
```

**If you downloaded the .exe into `releases/` and run it from there**, the
sample IFC files are one directory up, so the path becomes:

```powershell
.\dt.exe --bim ..\assets\IFC\AC20-FZK-Haus.ifc --type office
```

When in doubt, use a full path instead of a relative one — it removes the
ambiguity entirely:

```powershell
.\dt.exe --bim "C:\digital-twin-platform\assets\IFC\AC20-FZK-Haus.ifc" --type office
```

(Adjust the path to your IFC file.)

### Flags

| Flag     | Required | Description |
|----------|----------|-------------|
| `--bim`  | yes      | Path to the IFC file to parse and populate sensors from. |
| `--type` | no       | Building profile: `hospital`, `office`, `warehouse`, `manufacturing`, `campus`. Default: `office`. Controls sensor density/frequency and which queries get weighted in the recommendation. |
| `--out`  | no       | Output directory for reports. Default: `benchmark-results`. |
| `--help` | no       | Print usage and exit. |

Pick `--type` based on what the building actually is — it changes both how
densely sensors are placed (a hospital samples equipment at 5 Hz; an office
samples at 0.1 Hz) and which of the 12 query patterns the recommendation
weights most heavily (CLAUDE.md's "a hospital is not a factory" principle).

### What happens when you run it

1. The IFC file is parsed into building elements, zones, and equipment.
2. Sensors are placed on matching elements per the profile's placement rules.
3. Zone/floor topology is registered (so zone- and floor-scoped queries work).
4. One hour of synthetic sensor data is generated for every placed sensor.
5. Every storage backend (TimeSeries, Columnar, Hierarchical, RingBuffer) is
   benchmarked against the building's actual query mix.
6. A recommendation is computed and printed to the terminal, then written to
   disk along with a sensor schematic.

Expect terminal output like:

```
Parsed assets/IFC/AC20-FZK-Haus.ifc: 33 elements, 9 zones, 0 equipment items.
Placed 21 sensors.
Generated 7581 synthetic readings.

=== Recommendation (office profile) ===
Backend              Score     Coverage
Hierarchical         1.042         100%
Columnar             1.585         100%
RingBuffer           2.117          50%
TimeSeries           3.475         100%
Winner: Hierarchical (lowest weighted median across this building's query mix; 1.0 = won every query)
Wrote recommendation.md to benchmark-results/
Wrote schematic.svg to benchmark-results/
```

---

## 4. Read the output

Everything lands in `--out` (default `benchmark-results/`):

| File | What it's for |
|------|----------------|
| `recommendation.md` | The human-readable report: building stats, sensor counts by type, the backend recommendation with score/coverage, and a per-query latency table for this specific building. **Start here.** |
| `schematic.svg` | A rough floor-by-floor map: zone labels and sensor positions (colored by sensor type), derived directly from the IFC file's real coordinates. Open it in a browser or image viewer. |

### Reading the recommendation score

- **Score** = weighted average of (this backend's median latency / the
  per-query winner's median latency), across every query this building's
  profile cares about. **1.00 = this backend won every weighted query.**
  Higher is worse.
- **Coverage** = fraction of the profile's weighted queries this backend has
  data for. Below 100% (e.g. RingBuffer on historical rollups, which it
  can't answer because it evicts old data) means a low score might be
  winning by omission, not speed — check coverage before trusting a score.

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

- **"No sensors placed"** — the IFC file has no elements matching the
  selected profile's placement rules (e.g. a `--type hospital` rule set
  expects equipment/flow segments that aren't present in a simple
  residential model). Try a different `--type`, or check the parsed
  element/zone counts in the terminal output.

- **Run takes a very long time / seems to hang** — you're likely running
  on a machine with limited resources, or the building is very large with
  a dense profile (hospital/manufacturing = many high-frequency sensors).
  If you built from source, try the release build: `zig build -Doptimize=ReleaseFast`.

- **On macOS: "cannot be opened because the developer cannot be verified"** —
  macOS blocks unsigned binaries by default. Either:
  - Right-click the executable, select "Open", and confirm
  - Or allow unsigned executables: `sudo xattr -rd com.apple.quarantine /path/to/dt-macos-x86_64`
