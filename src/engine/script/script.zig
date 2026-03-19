const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");
const runtime = @import("./runtime.zig");
const vm = @import("./vm.zig");
const hot_reload = @import("./hot_reload.zig");

pub const types_mod = types;
pub const context_mod = context;
pub const runtime_mod = runtime;
pub const vm_mod = vm;
pub const hot_reload_mod = hot_reload;

/// 导出常用类型
pub const Script = types.Script;
pub const ScriptResource = types.ScriptResource;
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
pub const ScriptVM = vm.ScriptVM;
pub const ZigVM = vm.ZigVM;
pub const CSharpVM = vm.CSharpVM;
pub const LuaVM = vm.LuaVM;

pub const HotReloadManager = hot_reload.HotReloadManager;
pub const FileWatcher = hot_reload.FileWatcher;
