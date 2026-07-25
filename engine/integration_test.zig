// End-to-end integration tests — run the real `dt` pipeline (parse IFC ->
// place sensors -> live simulation -> write reports) against real IFC
// sample files from assets/IFC/, exercising the actual entry point a user
// runs rather than individual internal functions in isolation.
//
// Deliberately NOT part of `zig build test` (which compiles in -ODebug):
// sim duration is derived from the building's own placed sensor types'
// retention depths (up to ~7 years for structural sensors — see
// bs-Structural.ifc below), and CLAUDE.md already documents that a
// multi-year simulated run in Debug mode turns into a multi-hour
// wall-clock one (bounds checks, no inlining). `dt`/`dtb` are built
// ReleaseFast for exactly this reason (build.zig); this file is compiled
// the same way, via its own `zig build test-integration` step, so the
// regular fast unit-test suite never risks hanging on a real building file.
//
// Run with: zig build test-integration

const std = @import("std");
const main = @import("main.zig");
const testing = std.testing;

/// Runs the full pipeline against `bim_path`, writing into `out_dir`.
/// Cleanup of `out_dir` is the CALLER's responsibility (deliberately not
/// done here) — callers need to inspect the written output after this
/// returns, before removing it.
fn runAgainst(allocator: std.mem.Allocator, io: std.Io, bim_path: []const u8, out_dir: []const u8) !void {
    try main.runPipeline(allocator, io, .{ .bim_path = bim_path, .output_dir = out_dir });
}

test "runPipeline: a small real building (bs-Architecture.ifc) produces a complete, well-formed report set" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out_dir = "zig-cache-integration-test-arch";
    try runAgainst(allocator, io, "assets/IFC/bs-Architecture.ifc", out_dir);

    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, out_dir) catch {};
    var dir = try cwd.openDir(io, out_dir, .{});
    defer dir.close(io);

    // recommendation.md — the human-readable report. Check for the
    // sections every building's report must have, per
    // writeRecommendationReport's fixed structure, not just "the file
    // exists" (a truncated or half-written report would still "exist").
    const md = try dir.readFileAlloc(io, "recommendation.md", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "## Verdict") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## Sensors placed, by type") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## Per-query dashboard") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## Cost estimate") != null);
    try testing.expect(std.mem.indexOf(u8, md, "wins") != null); // track_winners' "wins N of M" phrasing

    // recommendation.html — the interactive dashboard. Confirm it's a
    // complete document (matching open/close tags, not truncated
    // mid-write) and that the per-query dashboard's interactive elements
    // actually rendered, not just the static shell.
    const html = try dir.readFileAlloc(io, "recommendation.html", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"pq-table\"") != null);

    // simulation.json — the machine-readable growth/stats data. Must be
    // syntactically valid JSON, not just present.
    const js = try dir.readFileAlloc(io, "simulation.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(js);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, js, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.contains("sim_stats"));
    try testing.expect(parsed.value.object.contains("growth_points"));

    // schematic.svg — the floor-plan sensor map.
    const svg = try dir.readFileAlloc(io, "schematic.svg", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(svg);
    try testing.expect(std.mem.startsWith(u8, svg, "<?xml") or std.mem.startsWith(u8, svg, "<svg"));
    try testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}

test "runPipeline: a building with no placeable elements exits cleanly without writing a report" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // bs-Hvac.ifc's elements don't match any placement rule (0 sensors) —
    // exercises runPipeline's early-return branch ("nothing to
    // benchmark"). Must return successfully (not error) and must NOT
    // write a partial/empty report that would misrepresent an untested
    // building as a benchmarked one.
    const out_dir = "zig-cache-integration-test-empty";
    try runAgainst(allocator, io, "assets/IFC/bs-Hvac.ifc", out_dir);

    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, out_dir) catch {};
    var dir = cwd.openDir(io, out_dir, .{}) catch |err| switch (err) {
        // The output directory itself may never have been created if
        // nothing was ever written to it — also a valid clean exit.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    try testing.expectError(error.FileNotFound, dir.readFileAlloc(io, "recommendation.md", allocator, .limited(1024)));
}
