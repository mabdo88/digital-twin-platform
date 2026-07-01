// Test root for synthetic data generator tests.
// Placed at engine/ level so generator.zig can import ../ecs/ and ../bim/
// without going outside the module path — same reason bim_test.zig,
// benchmark_test.zig, and metrics_test.zig live here.

const generator = @import("synthetic/generator.zig");
const validator = @import("synthetic/validator.zig");

comptime {
    _ = generator;
    _ = validator;
}
