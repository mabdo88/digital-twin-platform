// Test root for metrics system tests.
// Placed at engine/ level so metrics_system.zig can import ../storage/,
// ../world.zig, and ../../benchmark/ without going outside the module path.

const metrics = @import("ecs/systems/metrics_system.zig");

comptime {
    _ = metrics;
}
