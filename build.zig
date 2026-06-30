const std = @import("std");

// Digital Twin Optimization Platform — headless benchmarking engine.
// No Vulkan, no GLFW, no C dependencies: every step here is plain Zig.
pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run all digital twin platform tests");

    const targets = [_][]const u8{
        "engine/ecs/storage/storage_backend.zig",
        "engine/ecs/storage/backends_test.zig",
        "engine/ecs/world.zig",
        "engine/benchmark_test.zig",
        "engine/metrics_test.zig",
        "engine/bim_test.zig",
        "engine/synthetic_test.zig",
    };

    for (targets) |t| {
        const cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            t,
            "-ODebug",
            "--cache-dir",
            ".zig-cache",
        });
        test_step.dependOn(&cmd.step);
    }

    // Benchmark runner — standalone exe that runs the full latency suite
    // and writes Markdown + JSON reports to ./benchmark-results/.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bench_exe = b.addExecutable(.{
        .name = "dtb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("engine/bench_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmark suite and write reports to ./benchmark-results/");
    bench_step.dependOn(&run_bench.step);

    // Main entrypoint — parse a real IFC file, place sensors, benchmark
    // every backend against the building profile's query mix, write reports.
    const main_exe = b.addExecutable(.{
        .name = "dt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("engine/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main = b.addRunArtifact(main_exe);
    b.installArtifact(main_exe);
    const run_step = b.step("run", "Build dt (run zig-out/bin/dt directly to pass --bim/--type/--out flags)");
    run_step.dependOn(&run_main.step);
}
