/// MCP Screenshot Tool - Convert viewport rendering to PNG and return as base64
/// Bridges renderer frame readback with PNG encoding for MCP resource delivery
const std = @import("std");
const core = @import("../core/layer.zig");

/// Error conditions for screenshot capture
pub const Error = error{
    RenderFrameNotReady,
    PngEncodingFailed,
    Base64EncodingFailed,
    AllocationFailed,
};

/// Encode RGBA pixel data to PNG in memory using stbi_write_png_to_mem
/// Returns PNG data as allocated bytes (caller must free)
fn encodePngAlloc(
    allocator: std.mem.Allocator,
    rgba_data: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    const c = @cImport({
        @cDefine("STBI_WRITE_NO_STDIO", "1");
        @cInclude("stb_image_write.h");
    });

    var out_len: c_int = 0;
    const png_data = c.stbi_write_png_to_mem(
        rgba_data.ptr,
        @intCast(width * 4), // stride in bytes for RGBA
        @intCast(width),
        @intCast(height),
        4, // 4 components (RGBA)
        &out_len,
    );

    if (png_data == null or out_len <= 0) {
        return error.PngEncodingFailed;
    }
    defer c.free(png_data);

    const result = try allocator.alloc(u8, @intCast(out_len));
    const src: [*]const u8 = @ptrCast(png_data.?);
    @memcpy(result, src[0..@intCast(out_len)]);
    return result;
}

/// Encode binary PNG data as base64 string
fn encodeBase64Alloc(allocator: std.mem.Allocator, png_data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(png_data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, png_data);
    return encoded;
}

/// Capture viewport frame, encode as PNG, return as base64 data URI
/// Returns allocated string "data:image/png;base64,{base64_data}"
pub fn screenshotAsDataUriAlloc(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
) ![]u8 {
    // Download RGBA frame from GPU (readback sync point)
    const rgba_data = try layer_context.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(rgba_data);

    // Get framebuffer dimensions
    const texture = layer_context.renderer.scene_viewport.color_texture orelse return error.RenderFrameNotReady;
    const width = texture.desc.width;
    const height = texture.desc.height;

    // Encode RGBA to PNG
    const png_data = try encodePngAlloc(allocator, rgba_data, width, height);
    defer allocator.free(png_data);

    // Encode PNG as base64
    const base64_data = try encodeBase64Alloc(allocator, png_data);
    defer allocator.free(base64_data);

    // Construct data URI
    const data_uri = try std.fmt.allocPrint(
        allocator,
        "data:image/png;base64,{s}",
        .{base64_data},
    );

    return data_uri;
}

/// Capture screenshot and return PNG as base64 (without data URI wrapper)
pub fn screenshotAsPngBase64Alloc(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
) ![]u8 {
    // Download RGBA frame from GPU (readback sync point)
    const rgba_data = try layer_context.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(rgba_data);

    // Get framebuffer dimensions
    const texture = layer_context.renderer.scene_viewport.color_texture orelse return error.RenderFrameNotReady;
    const width = texture.desc.width;
    const height = texture.desc.height;

    // Encode RGBA to PNG
    const png_data = try encodePngAlloc(allocator, rgba_data, width, height);
    defer allocator.free(png_data);

    // Encode PNG as base64
    const base64_data = try encodeBase64Alloc(allocator, png_data);
    return base64_data;
}
