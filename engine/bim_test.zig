// Test root for BIM/IFC module tests.
// Placed at engine/ level so components.zig can import ../ecs/storage/* for
// the shared SensorType enum — same module-path reason benchmark_test.zig
// and metrics_test.zig live here.

const ifc_parser = @import("bim/ifc_parser.zig");
const sensor_placer = @import("bim/sensor_placer.zig");
const ifc_validation_test = @import("bim/ifc_validation_test.zig");

comptime {
    _ = ifc_parser;
    _ = sensor_placer;
    _ = ifc_validation_test;
}
