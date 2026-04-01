const std = @import("std");
const plugin_types = @import("../plugin/types.zig");
const runtime_mod = @import("./runtime.zig");
const wasm_vm_mod = @import("./wasm_vm.zig");
const wasm_compiler = @import("./wasm_compiler.zig");
const script_resource_mod = @import("../assets/script_resource.zig");
const types = @import("./types.zig");

const log = std.log.scoped(.script_vm_plugin);

/// Typed loader for `script_vm` plugins discovered by `PluginRegistry`.
///
/// `script_vm` plugins provide WASM modules that can be loaded into the
/// ScriptRuntime.  The manifest declares the entry-point source file and
/// compilation mode.
///
/// Lifecycle:
///   discover (PluginRegistry) → dispatchScriptVmPlugins → compile/load → enable
///   disable → unload → remove from PluginRegistry
pub const ScriptVmPluginLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ScriptVmPluginLoader {
        return .{ .allocator = allocator };
    }

    /// Validate a `script_vm` plugin from its PluginRecord.
    /// Checks that the manifest path exists and contains a compilable source.
    /// Does NOT compile — that happens on enable.
    pub fn validate(self: *ScriptVmPluginLoader, record: *plugin_types.PluginRecord) void {
        if (record.manifest.path.len == 0) {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, "script_vm plugin has no manifest path");
            return;
        }

        const dir_path = std.fs.path.dirname(record.manifest.path) orelse {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, "cannot derive plugin directory from path");
            return;
        };

        // Check for a main.zig or main.wasm in the plugin directory
        const has_source = blk: {
            const zig_path = std.fs.path.join(self.allocator, &.{ dir_path, "main.zig" }) catch break :blk false;
            defer self.allocator.free(zig_path);
            std.fs.cwd().access(zig_path, .{}) catch break :blk false;
            break :blk true;
        };

        const has_wasm = blk: {
            const wasm_path = std.fs.path.join(self.allocator, &.{ dir_path, "main.wasm" }) catch break :blk false;
            defer self.allocator.free(wasm_path);
            std.fs.cwd().access(wasm_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!has_source and !has_wasm) {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, "script_vm plugin missing main.zig or main.wasm");
            return;
        }

        // Validation passed — mark loaded
        record.lifecycle = .loaded;
        record.clearLastError(self.allocator);
        log.info("script_vm plugin '{s}' validated", .{record.getName()});
    }
};
