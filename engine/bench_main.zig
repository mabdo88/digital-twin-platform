// Zig 0.16.0 (tested against 0.17.0-dev)
//
// Standalone benchmark entrypoint — runs the full latency suite and writes
// Markdown + JSON reports under ./benchmark-results/.
//
// Lives at engine/ level (not benchmark/) so the runner's transitive imports
// of ../ecs/* resolve inside this module's path — same constraint that puts
// benchmark_test.zig and metrics_test.zig here. Invoke via `zig build bench`.

const std = @import("std");
const runner = @import("benchmark/runner.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try runner.run(allocator, io, .{
        .output_dir = "benchmark-results",
    });
}
