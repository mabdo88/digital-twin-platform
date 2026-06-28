// Test root for storage backend tests.
// Placed at storage/ level so backends can import ../storage_backend.zig
// without going outside the module path.

const aos = @import("backends/aos_storage.zig");
const soa = @import("backends/soa_storage.zig");
const ts = @import("backends/timeseries_storage.zig");
const col = @import("backends/columnar_storage.zig");
const hier = @import("backends/hierarchical_storage.zig");
const rb = @import("backends/ringbuffer_storage.zig");

// Re-export so all tests in those files are discovered.
comptime {
    _ = aos;
    _ = soa;
    _ = ts;
    _ = col;
    _ = hier;
    _ = rb;
}
