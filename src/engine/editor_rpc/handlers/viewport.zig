///! handlers/viewport.zig — viewport & gizmo control.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn setGizmoMode(ctx: *Ctx) !void {
    // TODO: wire to EditorState.manipulation_mode when bridge is available
    _ = try ctx.param([]const u8, "mode");
    try ctx.reply(.{});
}
