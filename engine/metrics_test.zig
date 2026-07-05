// Test entry point for the ecs/systems module family.
// Placed at engine/ level so metrics_system.zig/ingest_system.zig can
// import ../storage/, ../world.zig, and ../../benchmark/ or
// ../../synthetic/ without leaving the module path.

const metrics = @import("ecs/systems/metrics_system.zig");
const ingest = @import("ecs/systems/ingest_system.zig");

comptime {
    _ = metrics;
    _ = ingest;
}
