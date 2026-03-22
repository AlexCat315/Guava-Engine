//! Metal RT 后端 — 通过 C 桥接调用原生 Metal 光线追踪 API。
//!
//! 仅在 macOS 上可用；其他平台编译为空壳 (stub)。

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("rt_backend.zig");

pub const MetalRtBackend = if (builtin.os.tag == .macos) MetalRtImpl else MetalRtStub;

// =========================================================================
// macOS 真实实现
// =========================================================================
const MetalRtImpl = struct {
    ctx: *anyopaque,

    // ---- C bridge extern 声明 ----
    extern fn guava_metal_rt_init() ?*anyopaque;
    extern fn guava_metal_rt_is_supported(ctx: *anyopaque) bool;
    extern fn guava_metal_rt_build_accel(ctx: *anyopaque, triangles: [*]const rt.RtTriangle, count: u32) bool;
    extern fn guava_metal_rt_trace(ctx: *anyopaque, params: *const rt.RtParams, output: [*]u8, size: u32) bool;
    extern fn guava_metal_rt_destroy(ctx: *anyopaque) void;

    pub fn init() ?MetalRtImpl {
        const ctx = guava_metal_rt_init() orelse return null;
        return .{ .ctx = ctx };
    }

    pub fn isSupported(self: *const MetalRtImpl) bool {
        return guava_metal_rt_is_supported(self.ctx);
    }

    pub fn buildAccelerationStructure(self: *MetalRtImpl, triangles: []const rt.RtTriangle) bool {
        if (triangles.len == 0) return false;
        return guava_metal_rt_build_accel(self.ctx, triangles.ptr, @intCast(triangles.len));
    }

    pub fn traceRays(self: *MetalRtImpl, params: *const rt.RtParams, output: []u8) bool {
        if (output.len == 0) return false;
        return guava_metal_rt_trace(self.ctx, params, output.ptr, @intCast(output.len));
    }

    pub fn deinit(self: *MetalRtImpl) void {
        guava_metal_rt_destroy(self.ctx);
        self.ctx = undefined;
    }
};

// =========================================================================
// 非 macOS 空壳
// =========================================================================
const MetalRtStub = struct {
    pub fn init() ?MetalRtStub {
        return null;
    }
    pub fn isSupported(_: *const MetalRtStub) bool {
        return false;
    }
    pub fn buildAccelerationStructure(_: *MetalRtStub, _: []const rt.RtTriangle) bool {
        return false;
    }
    pub fn traceRays(_: *MetalRtStub, _: *const rt.RtParams, _: []u8) bool {
        return false;
    }
    pub fn deinit(_: *MetalRtStub) void {}
};
