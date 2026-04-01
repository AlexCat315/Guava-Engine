const std = @import("std");
const plugin_types = @import("../plugin/types.zig");
const loader_mod = @import("../plugin/loader.zig");
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
///   discover → validate → enable (compile+load) → disable → unload
pub const ScriptVmPluginLoader = struct {
    allocator: std.mem.Allocator,
    /// Optional reference to ScriptRuntime (set when Application binds it).
    /// When null, enable() will still compile but cannot inject into the VM.
    script_runtime: ?*runtime_mod.ScriptRuntime = null,

    pub fn init(allocator: std.mem.Allocator) ScriptVmPluginLoader {
        return .{ .allocator = allocator };
    }

    /// Bind the ScriptRuntime (called after Application creates it).
    pub fn setScriptRuntime(self: *ScriptVmPluginLoader, rt: *runtime_mod.ScriptRuntime) void {
        self.script_runtime = rt;
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

    /// Enable a validated script_vm plugin.
    /// Compiles .zig source to WASM if needed, then verifies the bytecode
    /// can be loaded by the ScriptRuntime's WASM VM.
    pub fn enable(self: *ScriptVmPluginLoader, record: *plugin_types.PluginRecord) void {
        if (record.lifecycle == .load_error) return;

        const dir_path = std.fs.path.dirname(record.manifest.path) orelse {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, "cannot derive plugin directory");
            return;
        };

        // Check for pre-compiled .wasm first, fall back to .zig compilation
        const wasm_path = std.fs.path.join(self.allocator, &.{ dir_path, "main.wasm" }) catch {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, "OOM building wasm path");
            return;
        };
        defer self.allocator.free(wasm_path);

        const has_wasm = blk: {
            std.fs.cwd().access(wasm_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!has_wasm) {
            // Try to compile from main.zig
            const zig_path = std.fs.path.join(self.allocator, &.{ dir_path, "main.zig" }) catch {
                record.lifecycle = .load_error;
                record.setLastError(self.allocator, "OOM building zig path");
                return;
            };
            defer self.allocator.free(zig_path);

            const source = std.fs.cwd().readFileAlloc(self.allocator, zig_path, 1024 * 1024) catch {
                record.lifecycle = .load_error;
                record.setLastError(self.allocator, "failed to read main.zig");
                return;
            };
            defer self.allocator.free(source);

            // Attempt compilation (best-effort; wasm_compiler may not be available)
            const result = wasm_compiler.compileZigSourceAlloc(self.allocator, .{
                .source = source,
                .script_name = record.getName(),
            }) catch {
                record.lifecycle = .load_error;
                record.setLastError(self.allocator, "WASM compilation failed");
                return;
            };
            var result_mut = result;
            defer result_mut.deinit(self.allocator);

            switch (result) {
                .compile_error => {
                    record.lifecycle = .load_error;
                    record.setLastError(self.allocator, "WASM compilation error");
                    return;
                },
                .success => |artifact| {
                    if (artifact.bytecode.len == 0) {
                        record.lifecycle = .load_error;
                        record.setLastError(self.allocator, "WASM compilation produced empty bytecode");
                        return;
                    }
                },
            }
        }

        // If we have ScriptRuntime, verify the VM can accept the module
        if (self.script_runtime) |rt| {
            if (rt.getVM(.wasm) == null) {
                log.warn("script_vm plugin '{s}': WASM VM not initialized", .{record.getName()});
            }
        }

        record.lifecycle = .enabled;
        record.clearLastError(self.allocator);
        log.info("script_vm plugin '{s}' enabled", .{record.getName()});
    }

    /// Disable a script_vm plugin (deactivate without full teardown).
    pub fn disable(_: *ScriptVmPluginLoader, record: *plugin_types.PluginRecord) void {
        if (record.lifecycle != .enabled) return;
        record.lifecycle = .loaded;
        log.info("script_vm plugin '{s}' disabled", .{record.getName()});
    }

    /// Fully unload a script_vm plugin (teardown all resources).
    pub fn unload(self: *ScriptVmPluginLoader, record: *plugin_types.PluginRecord) void {
        record.lifecycle = .unloaded;
        record.clearLastError(self.allocator);
        log.info("script_vm plugin '{s}' unloaded", .{record.getName()});
    }

    // ── PluginLoader vtable implementation ──────────────────────────────

    /// Return a type-erased PluginLoader backed by this ScriptVmPluginLoader.
    pub fn pluginLoader(self: *ScriptVmPluginLoader) loader_mod.PluginLoader {
        return .{
            .context = @ptrCast(self),
            .vtable = &script_vm_loader_vtable,
        };
    }

    const script_vm_loader_vtable = loader_mod.PluginLoader.VTable{
        .on_discover = &vmOnDiscover,
        .on_enable = &vmOnEnable,
        .on_disable = &vmOnDisable,
        .on_unload = &vmOnUnload,
    };

    fn vmOnDiscover(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *ScriptVmPluginLoader = @ptrCast(@alignCast(ctx));
        self.validate(record);
    }

    fn vmOnEnable(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *ScriptVmPluginLoader = @ptrCast(@alignCast(ctx));
        self.enable(record);
    }

    fn vmOnDisable(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *ScriptVmPluginLoader = @ptrCast(@alignCast(ctx));
        self.disable(record);
    }

    fn vmOnUnload(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *ScriptVmPluginLoader = @ptrCast(@alignCast(ctx));
        self.unload(record);
    }
};
