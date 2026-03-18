const std = @import("std");
const registry_mod = @import("registry.zig");
const library_mod = @import("library.zig");
const ibl_precompute = @import("../render/ibl_precompute.zig");
const environment_map_resource = @import("environment_map_resource.zig");
const handles = @import("handles.zig");
const rhi_types = @import("../rhi/types.zig");

pub const current_environment_map_cache_version: u32 = registry_mod.AssetType.texture.importVersion() + 1; // Different version for IBL

const CookedIBLData = struct {
    version: u32 = current_environment_map_cache_version,
    asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    irradiance_size: u32,
    prefiltered_size: u32,
    prefiltered_mip_levels: u32,
    irradiance_pixels_hex: []const u8,
    prefiltered_pixels_hex: []const u8,
    brdf_lut_handle: ?handles.TextureHandle,
};

// Generate IBL data for an environment map during import
pub fn generateIBLDataForHDR(
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    width: u32,
    height: u32,
    hdr_pixels: []const f32,
) ![]u8 {
    
    // Generate irradiance map using spherical harmonics
    const irradiance_pixels = try ibl_precompute.generateIrradianceMap(
        allocator,
        width,
        height,
        hdr_pixels,
        64, // Target irradiance map size
    );
    defer allocator.free(irradiance_pixels);

    // Generate prefiltered environment map
    const prefiltered_pixels = try ibl_precompute.generatePrefilteredMap(
        allocator,
        width,
        height,
        hdr_pixels,
        5, // 5 mip levels for roughness from 0 to 1
    );
    defer allocator.free(prefiltered_pixels);

    // Encode pixels to hex for storage
    const irradiance_pixels_hex = try encodeHexAlloc(allocator, std.mem.sliceAsBytes(irradiance_pixels));
    defer allocator.free(irradiance_pixels_hex);

    const prefiltered_pixels_hex = try encodeHexAlloc(allocator, std.mem.sliceAsBytes(prefiltered_pixels));
    defer allocator.free(prefiltered_pixels_hex);

    const cooked = CookedIBLData{
        .asset_id = asset_id,
        .source_path = source_path,
        .source_hash = source_hash,
        .import_settings_hash = import_settings_hash,
        .irradiance_size = 64,
        .prefiltered_size = 256,
        .prefiltered_mip_levels = 5,
        .irradiance_pixels_hex = irradiance_pixels_hex,
        .prefiltered_pixels_hex = prefiltered_pixels_hex,
        .brdf_lut_handle = null, // Will be set by the asset library
    };

    return try stringifyAlloc(allocator, cooked);
}

// Check if cooked IBL data is current
fn cookedIBLDataIsCurrent(allocator: std.mem.Allocator, record: *const registry_mod.AssetRecord, cooked_path: []const u8) !bool {
    std.fs.cwd().access(cooked_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = std.json.parseFromSlice(CookedIBLData, allocator, encoded, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const cooked = parsed.value;
    if (cooked.version != current_environment_map_cache_version) {
        return false;
    }

    if (!std.mem.eql(u8, cooked.source_hash, record.source_hash)) {
        return false;
    }

    if (!std.mem.eql(u8, cooked.import_settings_hash, record.import_settings_hash)) {
        return false;
    }

    return true;
}

// Load cooked IBL data and upload to GPU
pub fn loadIBLData(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
    device: anytype, // RHI device
) !environment_map_resource.EnvironmentMapResource {
    
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    
    // Find cooked IBL data path
    const cooked_ibl_path = cookedIBLPath: {
        const base_dir = std.fs.path.dirname(record.outputs[0].path) orelse break :cookedIBLPath record.outputs[0].path;
        const filename = std.fs.path.basename(record.outputs[0].path);
        const name_without_ext = if (std.mem.lastIndexOfScalar(u8, filename, '.')) |idx| filename[0..idx] else filename;
        break :cookedIBLPath try std.fmt.allocPrint(allocator, "{s}/{s}_ibl.json", .{ base_dir, name_without_ext });
    };
    defer allocator.free(cooked_ibl_path);

    // Ensure IBL data is cooked
    if (!(try cookedIBLDataIsCurrent(allocator, record, cooked_ibl_path))) {
        // Generate IBL data - this should have been done during asset import
        return error.IBLDataNotCooked;
    }

    // Load cooked IBL data
    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_ibl_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedIBLData, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const cooked = parsed.value;

    // Decode irradiance map pixels
    const irradiance_pixels = try decodeHexAlloc(allocator, cooked.irradiance_pixels_hex);
    defer allocator.free(irradiance_pixels);

    // Decode prefiltered map pixels
    const prefiltered_pixels = try decodeHexAlloc(allocator, cooked.prefiltered_pixels_hex);
    defer allocator.free(prefiltered_pixels);

    // Create environment map resource
    var resource = environment_map_resource.EnvironmentMapResource{
        .name = try allocator.dupe(u8, record.id),
        .source_width = cooked.irradiance_size,
        .source_height = cooked.irradiance_size,
        .source_pixels = try allocator.dupe(f32, std.mem.bytesAsSlice(f32, irradiance_pixels)),
        .irradiance_size = cooked.irradiance_size,
        .prefiltered_size = cooked.prefiltered_size,
        .prefiltered_mip_levels = cooked.prefiltered_mip_levels,
    };

    // TODO: Upload to GPU and create texture handles
    // resource.irradiance_map_handle = try device.createTexture(...);
    // resource.prefiltered_map_handle = try device.createTexture(...);
    // resource.brdf_lut_handle = cooked.brdf_lut_handle;

    return resource;
}

// Generate BRDF LUT if not exists (should be done once globally)
pub fn ensureBRDFLUT(allocator: std.mem.Allocator, library: *library_mod.ResourceLibrary, device: anytype) !handles.TextureHandle {
    const brdf_lut_asset_id = "internal/brdf_lut";
    
    if (library.textureHandleByAssetId(brdf_lut_asset_id)) |handle| {
        return handle;
    }

    const size = 512;
    const lut_pixels = try ibl_precompute.generateBRDFLUT(allocator, size);
    defer allocator.free(lut_pixels);

    // TODO: Create GPU texture
    // const texture_handle = try device.createTexture(...);
    // try library.mapTextureAssetId(brdf_lut_asset_id, texture_handle);
    
    return .{};
}

// Helper functions
fn encodeHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(result);

    for (bytes, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return result;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) {
        return error.InvalidHexLength;
    }

    var result = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(result);

    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const high = try hexCharToValue(hex[i]);
        const low = try hexCharToValue(hex[i + 1]);
        result[i / 2] = (high << 4) | low;
    }

    return result;
}

fn hexCharToValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [2048]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}
