// Test root for benchmark query tests.
// Placed at engine/ level so queries.zig can import ../ecs/ without
// going outside the module path.

const queries = @import("benchmark/queries.zig");
const runner = @import("benchmark/runner.zig");

comptime {
    _ = queries;
    _ = runner;
}
