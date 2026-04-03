///! handlers/camera.zig — camera bookmark management.
///!
///! In editor-server mode, the camera is a world entity (MainCamera).
///! Bookmarks save/restore the camera entity's transform (translation + rotation).
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

// ── Bookmark storage (process-lifetime, shared across RPC calls) ────

const Bookmark = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 }, // quaternion xyzw
    fov: f32 = 1.0471976, // ~60 degrees in radians

    fn getName(self: *const Bookmark) []const u8 {
        return self.name[0..self.name_len];
    }
};

const max_bookmarks = 64;
var bookmark_buf: [max_bookmarks]Bookmark = undefined;
var bookmark_len: usize = 0;

// ── RPC handlers ────────────────────────────────────────────────

pub fn listBookmarks(ctx: *Ctx) !void {
    const Info = struct {
        index: u64,
        name: []const u8,
        position: struct { x: f32, y: f32, z: f32 },
        rotation: struct { x: f32, y: f32, z: f32, w: f32 },
        fov: f32,
    };

    var list = std.ArrayList(Info).empty;
    defer list.deinit(ctx.allocator);

    for (bookmark_buf[0..bookmark_len], 0..) |*b, i| {
        try list.append(ctx.allocator, .{
            .index = @intCast(i),
            .name = b.getName(),
            .position = .{ .x = b.translation[0], .y = b.translation[1], .z = b.translation[2] },
            .rotation = .{ .x = b.rotation[0], .y = b.rotation[1], .z = b.rotation[2], .w = b.rotation[3] },
            .fov = b.fov,
        });
    }

    try ctx.reply(.{ .bookmarks = list.items });
}

pub fn addBookmark(ctx: *Ctx) !void {
    if (bookmark_len >= max_bookmarks) return error.OutOfMemory;
    const name = (try ctx.paramOpt([]const u8, "name")) orelse "Bookmark";

    // Get current camera transform from the world
    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    const camera_entity = world.getEntityConst(camera_id) orelse return error.NotAvailable;
    const transform = if (world.worldTransformConst(camera_id)) |wt| wt else camera_entity.local_transform;

    const fov: f32 = if (camera_entity.camera) |cam| switch (cam.projection) {
        .perspective => |p| p.fov_y_radians,
        else => 1.0471976,
    } else 1.0471976;

    var b = Bookmark{
        .translation = transform.translation,
        .rotation = transform.rotation,
        .fov = fov,
    };
    b.name_len = @min(name.len, 63);
    @memcpy(b.name[0..b.name_len], name[0..b.name_len]);

    bookmark_buf[bookmark_len] = b;
    bookmark_len += 1;
    try ctx.reply(.{ .index = @as(u64, @intCast(bookmark_len - 1)) });
}

pub fn removeBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    // Shift elements down
    if (idx + 1 < bookmark_len) {
        std.mem.copyForwards(Bookmark, bookmark_buf[idx .. bookmark_len - 1], bookmark_buf[idx + 1 .. bookmark_len]);
    }
    bookmark_len -= 1;
    try ctx.reply(.{});
}

pub fn applyBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    const b = &bookmark_buf[idx];

    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    var camera_entity = world.getEntity(camera_id) orelse return error.NotAvailable;

    camera_entity.local_transform.translation = b.translation;
    camera_entity.local_transform.rotation = b.rotation;

    try ctx.reply(.{});
}

pub fn renameBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const name = try ctx.param([]const u8, "name");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    var b = &bookmark_buf[idx];
    b.name_len = @min(name.len, 63);
    @memset(&b.name, 0);
    @memcpy(b.name[0..b.name_len], name[0..b.name_len]);
    try ctx.reply(.{});
}
