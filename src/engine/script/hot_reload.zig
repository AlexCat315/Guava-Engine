const std = @import("std");
const types = @import("./types.zig");
const runtime_mod = @import("./runtime.zig");
const handles = @import("../assets/handles.zig");

const log = std.log.scoped(.hot_reload);

/// 热重载管理器
pub const HotReloadManager = struct {
    /// 文件修改时间缓存
    file_mtimes: std.AutoHashMap([]const u8, i128),
    /// 待重载的脚本列表
    pending_reload: std.ArrayList(handles.ScriptHandle),
    /// 运行时引用
    runtime: *runtime_mod.ScriptRuntime,
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rt: *runtime_mod.ScriptRuntime) HotReloadManager {
        return .{
            .file_mtimes = std.AutoHashMap([]const u8, i128).init(allocator),
            .pending_reload = std.ArrayList(handles.ScriptHandle).init(allocator),
            .runtime = rt,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HotReloadManager) void {
        var keys = self.file_mtimes.keyIterator();
        while (keys.next()) |key| {
            self.allocator.free(key.*);
        }
        self.file_mtimes.deinit();
        self.pending_reload.deinit(self.allocator);
    }

    /// 注册脚本文件
    pub fn registerScript(self: *HotReloadManager, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const mtime = getFileMtime(path) catch 0;
        try self.file_mtimes.put(path_copy, mtime);
    }

    /// 检查是否有脚本需要重载
    pub fn checkForChanges(self: *HotReloadManager) void {
        self.pending_reload.clearRetainingCapacity();

        var it = self.file_mtypes.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const last_mtime = entry.value_ptr.*;

            const current_mtime = getFileMtime(path) catch continue;
            if (current_mtime > last_mtime) {
                // 文件已修改，标记待重载
                log.info("Script file modified: {s}", .{path});
                // TODO: 查找对应的脚本句柄并加入待重载列表
                entry.value_ptr.* = current_mtime;
            }
        }
    }

    /// 处理待重载的脚本
    pub fn processPendingReload(self: *HotReloadManager) void {
        _ = self;
        // TODO: 实现具体的重载逻辑
    }

    /// 触发单个脚本重载
    pub fn reloadScript(self: *HotReloadManager, handle: handles.ScriptHandle) !void {
        try self.runtime.reloadScript(handle);
    }
};

/// 获取文件修改时间
fn getFileMtime(path: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    return stat.mtime;
}

/// 文件监听器（未来可扩展为操作系统原生监听）
pub const FileWatcher = struct {
    /// 监听的文件路径
    paths: std.ArrayList([]const u8),
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileWatcher {
        return .{
            .paths = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit();
    }

    /// 添加监听路径
    pub fn addPath(self: *FileWatcher, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.paths.append(path_copy);
    }

    /// 检查变更（轮询实现）
    pub fn pollChanges(self: *FileWatcher, last_mtimes: *std.AutoHashMap([]const u8, i128)) void {
        for (self.paths.items) |path| {
            const current_mtime = getFileMtime(path) catch continue;
            if (last_mtimes.get(path)) |last_mtime| {
                if (current_mtime > last_mtime.*) {
                    log.info("File changed: {s}", .{path});
                }
            }
            last_mtimes.put(path, current_mtime) catch {};
        }
    }
};
