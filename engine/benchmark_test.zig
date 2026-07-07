// Test entry point for the benchmark module family.
// Placed at engine/ level so queries.zig can import ../ecs/ without leaving
// the module path.

const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");
const schematic = @import("benchmark/schematic.zig");
const cost_model = @import("benchmark/cost_model.zig");
const report = @import("benchmark/report.zig");

comptime {
    _ = queries;
    _ = runner;
    _ = schematic;
    _ = cost_model;
    _ = report;
}
