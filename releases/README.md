# Digital Twin Optimization Platform — Pre-built Executables

Ready-to-run binaries for Windows, Linux, and macOS (Intel and ARM).

## Download and run

Pick the executable for your platform and save it somewhere on your computer.

| Platform | File | Size |
|----------|------|------|
| **Windows** (x86-64) | `dt.exe` | 1.3 MB |
| **Linux** (x86-64) | `dt-linux` | 7.2 MB |
| **macOS** (Intel/x86-64) | `dt-macos-x86_64` | 896 KB |
| **macOS** (Apple Silicon/ARM) | `dt-macos-aarch64` | 819 KB |

### Quick start

Open a terminal/command prompt in the directory where you saved the executable:

**Windows:**
```cmd
dt.exe --bim path\to\building.ifc --type office
```

**Linux/macOS:**
```bash
./dt-linux --bim path/to/building.ifc --type office
```

(Use the Intel or ARM macOS version depending on your Mac.)

### Full documentation

See [`HOW_TO_USE.md`](../HOW_TO_USE.md) in the root directory for:
- Detailed flag reference
- What the output files mean
- Troubleshooting

---

## Building from source (optional)

If you prefer to build it yourself or need a different target:

```sh
git clone <this-repo>
cd digital-twin-platform
zig build -Doptimize=ReleaseFast
zig-out/bin/dt --bim model.ifc --type office
```

Requires [Zig](https://ziglang.org/) master (0.16.0+). No other dependencies.
