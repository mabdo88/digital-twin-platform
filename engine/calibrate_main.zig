// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Calibration entrypoint — runs the optional DuckDB calibration pass and
// writes calibration.md + calibration.json under ./calibration-results/.
//
// Lives at engine/ level (not calibration/) so the adapter's transitive
// imports of ../ecs/* and ../benchmark/* resolve inside this module's path —
// the same constraint that puts bench_main.zig here. Invoke via
// `zig build calibrate`, or run zig-out/bin/dtc directly to pass flags.

const std = @import("std");
const calibration = @import("calibration/duckdb_adapter.zig");

fn printUsage() void {
    std.debug.print(
        \\Usage: dtc [options]   — DuckDB calibration pass (optional)
        \\
        \\  --duckdb <path>   Path to the duckdb binary (default: probe PATH, then ./tools/duckdb).
        \\  --out <dir>       Output directory (default: calibration-results).
        \\  --sensors <n>     Sensors in the calibration dataset (default 100).
        \\  --readings <n>    Readings per sensor (default 8760 = 1 year hourly).
        \\  --iterations <n>  Repetitions per query per engine (default 6).
        \\  --clean           Delete the generated CSV/SQL artifacts afterwards.
        \\
        \\Exits 0 when the calibration passes OR when no duckdb binary is found
        \\(the pass is optional by design); exits 1 when it runs and disagrees.
        \\
    , .{});
}

/// Same split as main.zig's parseArgs/parseArgsFromSlice, for the same
/// reason: `std.process.Args` is a platform-specific OS type a test can't
/// construct, so the real logic lives in the plain-slice version below.
fn parseArgsFromSlice(argv: []const [:0]const u8) !calibration.Options {
    var options: calibration.Options = .{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--clean")) {
            options.keep_artifacts = false;
        } else if (std.mem.eql(u8, arg, "--duckdb")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.duckdb_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.output_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--sensors")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.num_sensors = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--readings")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.readings_per_sensor = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.iterations = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }

    if (options.iterations == 0) return error.InvalidIterations;
    if (options.num_sensors == 0 or options.readings_per_sensor == 0) return error.EmptyDataset;

    return options;
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseArgsFromSlice(argv) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage();
            return;
        },
        else => {
            printUsage();
            return err;
        },
    };

    // Split out so every defer below runs before the exit-code decision —
    // std.process.exit would skip them, and skipping the allocator's deinit
    // would suppress its leak report.
    const passed = try calibrate(init.gpa, init.io, options);
    if (!passed) std.process.exit(1);
}

/// Returns whether the calibration passed. A missing DuckDB binary counts as
/// passing: the pass is optional by design and its absence must not fail a
/// build or a CI job that simply doesn't have DuckDB installed.
fn calibrate(allocator: std.mem.Allocator, io: std.Io, options: calibration.Options) !bool {
    const maybe = try calibration.run(allocator, io, options);
    const res = maybe orelse {
        std.debug.print(
            \\Calibration skipped: no `duckdb` binary found.
            \\
            \\Install the DuckDB CLI (https://duckdb.org/docs/installation/) and
            \\put it on PATH, drop it at ./tools/duckdb, or pass --duckdb <path>.
            \\
        , .{});
        return true;
    };
    defer res.deinit(allocator);

    try calibration.writeReports(allocator, io, options.output_dir, res);

    std.debug.print(
        \\
        \\DuckDB calibration: {s}
        \\  duckdb           {s}
        \\  dataset          {d} sensors x {d} readings ({d} rows)
        \\  value mismatches {d}
        \\  cost-profile rho {d:.3}
        \\  slower than duck {d}
        \\  reports          {s}/calibration.md, {s}/calibration.json
        \\
    , .{
        if (res.passed()) "PASS" else "REVIEW",
        res.duckdb_version,
        res.num_sensors,
        res.readings_per_sensor,
        @as(u64, res.num_sensors) * @as(u64, res.readings_per_sensor),
        res.mismatches.len,
        res.spearman,
        res.slower_flags.len,
        options.output_dir,
        options.output_dir,
    });

    return res.passed();
}

// ---------------------------------------------------------------------------
// Tests — argument parsing. Same rationale as main.zig's: these guard the
// defaults the documented CLI promises, and the "missing value" path, which
// is where an off-by-one in the index walk would silently read the next flag
// as a value.
// ---------------------------------------------------------------------------

test "parseArgsFromSlice: defaults match the documented ones when no flags are passed" {
    const argv = [_][:0]const u8{"dtc"};
    const o = try parseArgsFromSlice(&argv);
    try std.testing.expectEqual(@as(?[]const u8, null), o.duckdb_path);
    try std.testing.expectEqualStrings("calibration-results", o.output_dir);
    try std.testing.expectEqual(@as(u32, 100), o.num_sensors);
    try std.testing.expectEqual(@as(u32, 8760), o.readings_per_sensor);
    try std.testing.expect(o.keep_artifacts);
}

test "parseArgsFromSlice: a flag with its value omitted is an error, not a silent read of the next flag" {
    const argv = [_][:0]const u8{ "dtc", "--duckdb" };
    try std.testing.expectError(error.MissingValue, parseArgsFromSlice(&argv));

    const argv2 = [_][:0]const u8{ "dtc", "--sensors" };
    try std.testing.expectError(error.MissingValue, parseArgsFromSlice(&argv2));
}

test "parseArgsFromSlice: zero iterations is rejected — it would divide by nothing downstream" {
    const argv = [_][:0]const u8{ "dtc", "--iterations", "0" };
    try std.testing.expectError(error.InvalidIterations, parseArgsFromSlice(&argv));
}

test "parseArgsFromSlice: an empty dataset is rejected" {
    const argv = [_][:0]const u8{ "dtc", "--sensors", "0" };
    try std.testing.expectError(error.EmptyDataset, parseArgsFromSlice(&argv));
}

test "parseArgsFromSlice: flags are honored regardless of order" {
    const a = [_][:0]const u8{ "dtc", "--out", "d", "--sensors", "7", "--clean" };
    const o = try parseArgsFromSlice(&a);
    try std.testing.expectEqualStrings("d", o.output_dir);
    try std.testing.expectEqual(@as(u32, 7), o.num_sensors);
    try std.testing.expect(!o.keep_artifacts);
}

test {
    // Pull in the adapter's own tests (parser, tolerance, Spearman).
    std.testing.refAllDecls(calibration);
}
