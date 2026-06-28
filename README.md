# Digital Twin Optimization Platform

A headless benchmarking and optimisation research platform for digital-twin
data infrastructure. Given a real BIM/CAD model and a set of sensor
definitions, it:

1. parses the building (IFC) into entities,
2. attaches virtual sensors,
3. generates realistic synthetic sensor data,
4. runs every relevant query pattern against every storage backend, and
5. emits a measured, project-specific recommendation: which storage strategy
   to use and what it will cost.

Pure ECS architecture in Zig. No rendering, no external database
dependencies — every storage backend is in-process Zig, compared
apples-to-apples through one shared interface.

> This project was extracted from the `digital-twin` branch of
> [ZigEngine](https://github.com/mabdo88/ZigEngine), where it started as an
> experiment alongside an unrelated Vulkan game engine. It has no
> dependency on that engine and lives here as its own project going forward.

## Rules and roadmap

- [`CLAUDE.md`](CLAUDE.md) — non-negotiable project rules (read this first).
- [`AGENT.md`](AGENT.md) — phase-by-phase workflow and task checklist.
- [`.cascade/digital-twin/backend-audit.md`](.cascade/digital-twin/backend-audit.md) — known issues per backend.

## Build & test

```sh
zig build test    # run all unit + golden-result equivalence tests
zig build bench   # run the full benchmark suite, write reports to ./benchmark-results/
```

Requires Zig master (tested against 0.16.0 / 0.17.0-dev). No external
dependencies.
