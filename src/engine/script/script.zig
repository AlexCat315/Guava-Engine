const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");
const runtime = @import("./runtime.zig");
const vm = @import("./vm.zig");
const hot_reload = @import("./hot_reload.zig");
const vm_interface = @import("./vm_interface.zig");
const wasm_compiler = @import("./wasm_compiler.zig");
const script_resource_mod = @import("../assets/script_resource.zig");

pub const types_mod = types;
pub const context_mod = context;
pub const runtime_mod = runtime;
pub const vm_mod = vm;
pub const hot_reload_mod = hot_reload;

/// 导出常用类型
pub const Script = types.Script;
pub const ScriptResource = script_resource_mod.ScriptResource;
pub const ScriptInstance = types.ScriptInstance;
pub const ScriptInstanceId = types.ScriptInstanceId;
pub const ScriptInstanceState = types.ScriptInstanceState;
pub const ScriptVTable = types.ScriptVTable;
pub const ScriptLanguage = types.ScriptLanguage;
pub const ScriptError = types.ScriptError;
pub const ScriptSystemConfig = types.ScriptSystemConfig;

pub const ScriptContext = context.ScriptContext;
pub const EntityId = context.EntityId;

pub const ScriptRuntime = runtime.ScriptRuntime;
pub const ScriptVM = vm_interface.ScriptVM;
pub const ZigVM = vm.ZigVM;
pub const CSharpVM = vm.CSharpVM;
pub const LuaVM = vm.LuaVM;
pub const WasmVM = vm.WasmVM;
pub const WasmCompileResult = wasm_compiler.CompileResult;

pub const HotReloadManager = hot_reload.HotReloadManager;
pub const FileWatcher = hot_reload.FileWatcher;
