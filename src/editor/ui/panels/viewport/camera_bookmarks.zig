const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");

pub const CameraBookmark = struct {
    name: [64]u8,
    name_len: usize,
    position: [3]f32,
    target: [3]f32,
    pitch: f32,
    yaw: f32,
    distance: f32,
    fov: f32,
    orthographic: bool,
    timestamp: i64,

    pub fn init(name: []const u8, position: [3]f32, target: [3]f32, pitch: f32, yaw: f32, distance: f32, fov: f32, orthographic: bool) CameraBookmark {
        var bookmark = CameraBookmark{
            .name = [_]u8{0} ** 64,
            .name_len = @min(name.len, 63),
            .position = position,
            .target = target,
            .pitch = pitch,
            .yaw = yaw,
            .distance = distance,
            .fov = fov,
            .orthographic = orthographic,
            .timestamp = std.time.timestamp(),
        };
        @memcpy(bookmark.name[0..name.len], name.ptr);
        return bookmark;
    }

    pub fn getName(self: *const CameraBookmark) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn clone(self: *const CameraBookmark) CameraBookmark {
        return self.*;
    }
};

pub const CameraBookmarkManager = struct {
    allocator: std.mem.Allocator,
    bookmarks: std.ArrayList(CameraBookmark),
    selected_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) CameraBookmarkManager {
        return .{
            .allocator = allocator,
            .bookmarks = std.ArrayList(CameraBookmark).init(allocator),
        };
    }

    pub fn deinit(self: *CameraBookmarkManager) void {
        self.bookmarks.deinit();
        self.* = undefined;
    }

    pub fn addBookmark(self: *CameraBookmarkManager, bookmark: CameraBookmark) !usize {
        try self.bookmarks.append(bookmark);
        return self.bookmarks.items.len - 1;
    }

    pub fn removeBookmark(self: *CameraBookmarkManager, index: usize) bool {
        if (index >= self.bookmarks.items.len) return false;
        _ = self.bookmarks.orderedRemove(index);
        if (self.selected_index) |*si| {
            if (si.* == index) {
                si.* = null;
            } else if (si.* > index) {
                si.* -= 1;
            }
        }
        return true;
    }

    pub fn getBookmark(self: *const CameraBookmarkManager, index: usize) ?*const CameraBookmark {
        if (index >= self.bookmarks.items.len) return null;
        return &self.bookmarks.items[index];
    }

    pub fn renameBookmark(self: *CameraBookmarkManager, index: usize, new_name: []const u8) bool {
        if (index >= self.bookmarks.items.len) return false;
        const bookmark = &self.bookmarks.items[index];
        bookmark.name_len = @min(new_name.len, 63);
        @memcpy(bookmark.name[0..new_name.len], new_name.ptr);
        return true;
    }

    pub fn bookmarkCount(self: *const CameraBookmarkManager) usize {
        return self.bookmarks.items.len;
    }
};

pub fn drawCameraBookmarkPanel(manager: *CameraBookmarkManager, current_position: [3]f32, current_target: [3]f32, current_pitch: f32, current_yaw: f32, current_distance: f32, current_fov: f32, current_orthographic: bool, on_apply: *const fn (usize) void) void {
    if (gui.begin("Camera Bookmarks")) {
        defer gui.end();

        if (gui.button("Add Current View")) {
            const bookmark = CameraBookmark.init(
                "Bookmark",
                current_position,
                current_target,
                current_pitch,
                current_yaw,
                current_distance,
                current_fov,
                current_orthographic,
            );
            _ = manager.addBookmark(bookmark) catch {};
        }

        gui.separator();

        if (manager.bookmarks.items.len == 0) {
            gui.text("No bookmarks saved");
        } else {
            var i: usize = 0;
            while (i < manager.bookmarks.items.len) : (i += 1) {
                const bookmark = &manager.bookmarks.items[i];

                const is_selected = manager.selected_index != null and manager.selected_index.? == i;

                var name_buf: [128]u8 = undefined;
                const display_name = std.fmt.bufPrint(&name_buf, "{s}##{}", .{ bookmark.getName(), i }) catch continue;

                if (gui.selectable(display_name, is_selected)) {
                    manager.selected_index = i;
                }

                if (gui.beginPopupContextItem()) {
                    if (gui.selectable("Apply", false)) {
                        on_apply(i);
                    }
                    if (gui.selectable("Rename", false)) {
                    }
                    if (gui.selectable("Delete", false)) {
                        _ = manager.removeBookmark(i);
                        i -= 1;
                        if (i < 0) i = 0;
                    }
                    gui.endPopup();
                }

                if (gui.isItemHovered() and gui.isMouseDoubleClicked(.left)) {
                    on_apply(i);
                }
            }
        }
    }
}
