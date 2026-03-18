const std = @import("std");
const image_decoder = @import("image_decoder.zig");
const registry_mod = @import("registry.zig");
const library_mod = @import("library.zig");
const ibl_precompute = @import("../render/ibl_precompute.zig");
const environment_map_resource = @import("environment_map_resource.zig");
const handles = @import("handles.zig");
const rhi_types = @import("../rhi/types.zig");

pub const current_environment_map_cache_version: u32 = registry_mod.AssetType.texture.importVersion() + 2;

const derived_importer_name = "ibl-derived-v1";

const CookedIBLData = struct {
    version: u32 = current_environment_map_cache_version,
    asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32,
    irradiance_width: u32,
    irradiance_height: u32,
    prefiltered_width: u32,
    prefiltered_height: u32,
    prefiltered_mip_levels: u32,
    brdf_lut_size: u32,
    irradiance_pixels_hex: []const u8,
    prefiltered_pixels_hex: []const u8,
};

pub fn cookedIBLPathAlloc(allocator: std.mem.Allocator, cooked_texture_path: []const u8) ![]u8 {
    const base_dir = std.fs.path.dirname(cooked_texture_path) orelse ".";
    const filename = std.fs.path.basename(cooked_texture_path);
    const name_without_ext = if (std.mem.lastIndexOfScalar(u8, filename, '.')) |idx| filename[0..idx] else filename;
    return std.fmt.allocPrint(allocator, "{s}/{s}_ibl.json", .{ base_dir, name_without_ext });
}

pub fn generateIBLDataForHDR(
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32,
    width: u32,
    height: u32,
    hdr_pixels: []const f32,
) ![]u8 {
    const irradiance_pixels = try ibl_precompute.generateIrradianceMap(
        allocator,
        width,
        height,
        hdr_pixels,
        64,
    );
    defer allocator.free(irradiance_pixels);

    const prefiltered_pixels = try ibl_precompute.generatePrefilteredMap(
        allocator,
        width,
        height,
        hdr_pixels,
        5,
    );
    defer allocator.free(prefiltered_pixels);

    const irradiance_pixels_hex = try encodeHexAlloc(allocator, std.mem.sliceAsBytes(irradiance_pixels));
    defer allocator.free(irradiance_pixels_hex);

    const prefiltered_pixels_hex = try encodeHexAlloc(allocator, std.mem.sliceAsBytes(prefiltered_pixels));
    defer allocator.free(prefiltered_pixels_hex);

    const cooked = CookedIBLData{
        .asset_id = asset_id,
        .source_path = source_path,
        .source_hash = source_hash,
        .import_settings_hash = import_settings_hash,
        .import_version = import_version,
        .irradiance_width = 64,
        .irradiance_height = 64,
        .prefiltered_width = width,
        .prefiltered_height = height,
        .prefiltered_mip_levels = 5,
        .brdf_lut_size = 256,
        .irradiance_pixels_hex = irradiance_pixels_hex,
        .prefiltered_pixels_hex = prefiltered_pixels_hex,
    };

    return stringifyAlloc(allocator, cooked);
}

pub fn ensureCookedIBLData(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) ![]u8 {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
        return error.AssetTypeMismatch;
    }
    if (record.outputs.len == 0) {
        return error.MissingCookedOutput;
    }

    const cooked_ibl_path = try cookedIBLPathAlloc(allocator, record.outputs[0].path);
    const should_recook = recook: {
        std.fs.cwd().access(cooked_ibl_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :recook true,
            else => return err,
        };
        break :recook !(try cookedIBLDataIsCurrent(allocator, record, cooked_ibl_path));
    };
    if (should_recook) {
        try cookIBLDataRecord(allocator, record, cooked_ibl_path);
    }
    return cooked_ibl_path;
}

pub fn loadIBLData(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) !environment_map_resource.EnvironmentMapResource {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
        return error.AssetTypeMismatch;
    }

    const environment_map_handle = library.textureHandleByAssetId(asset_id) orelse return error.EnvironmentMapTextureNotLoaded;
    const cooked_ibl_path = try ensureCookedIBLData(allocator, registry, asset_id);
    defer allocator.free(cooked_ibl_path);

    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_ibl_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedIBLData, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const cooked = parsed.value;

    const irradiance_bytes = try decodeRgb32fHexToRgbaBytes(allocator, cooked.irradiance_pixels_hex);
    defer allocator.free(irradiance_bytes);

    const prefiltered_bytes = try decodeRgb32fHexToRgbaBytes(allocator, cooked.prefiltered_pixels_hex);
    defer allocator.free(prefiltered_bytes);

    const irradiance_handle = try ensureDerivedTexture(
        allocator,
        library,
        record,
        asset_id,
        "ibl/irradiance",
        "IBL Irradiance",
        cooked.irradiance_width,
        cooked.irradiance_height,
        .rgba32_float,
        irradiance_bytes,
    );
    const prefiltered_handle = try ensureDerivedTexture(
        allocator,
        library,
        record,
        asset_id,
        "ibl/prefiltered",
        "IBL Prefiltered",
        cooked.prefiltered_width,
        cooked.prefiltered_height,
        .rgba32_float,
        prefiltered_bytes,
    );
    const brdf_lut_handle = try ensureBRDFLUT(allocator, library, cooked.brdf_lut_size);

    return .{
        .name = try allocator.dupe(u8, record.id),
        .source_width = 0,
        .source_height = 0,
        .source_pixels = try allocator.alloc(f32, 0),
        .environment_map_handle = environment_map_handle,
        .irradiance_map_handle = irradiance_handle,
        .prefiltered_map_handle = prefiltered_handle,
        .brdf_lut_handle = brdf_lut_handle,
        .irradiance_size = cooked.irradiance_width,
        .prefiltered_size = cooked.prefiltered_width,
        .prefiltered_mip_levels = cooked.prefiltered_mip_levels,
    };
}

pub fn ensureBRDFLUT(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    size: u32,
) !handles.TextureHandle {
    const asset_id = try std.fmt.allocPrint(allocator, "builtin://ibl/brdf_lut/{d}", .{size});
    defer allocator.free(asset_id);

    if (library.textureHandleByAssetId(asset_id)) |handle| {
        return handle;
    }

    const lut = try ibl_precompute.generateBRDFLUT(allocator, size);
    defer allocator.free(lut);

    const lut_bytes = try expandRg32fToRgbaBytes(allocator, lut);
    defer allocator.free(lut_bytes);

    const handle = try library.createTexture(.{
        .name = "IBL BRDF LUT",
        .width = size,
        .height = size,
        .format = .rgba32_float,
        .pixels = lut_bytes,
    });
    _ = try library.bindTextureAssetRecord(
        handle,
        try makeSyntheticTextureRecord(
            allocator,
            asset_id,
            "internal://ibl/brdf_lut",
            "IBL BRDF LUT",
            "ibl-brdf-lut",
            derived_importer_name,
            &.{},
        ),
    );
    return handle;
}

fn cookedIBLDataIsCurrent(
    allocator: std.mem.Allocator,
    record: *const registry_mod.AssetRecord,
    cooked_path: []const u8,
) !bool {
    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = std.json.parseFromSlice(CookedIBLData, allocator, encoded, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const cooked = parsed.value;
    return cooked.version == current_environment_map_cache_version and
        std.mem.eql(u8, cooked.asset_id, record.id) and
        std.mem.eql(u8, cooked.source_path, record.source_path) and
        std.mem.eql(u8, cooked.source_hash, record.source_hash) and
        std.mem.eql(u8, cooked.import_settings_hash, record.import_settings_hash) and
        cooked.import_version == record.resolvedImportVersion();
}

fn cookIBLDataRecord(
    allocator: std.mem.Allocator,
    record: *const registry_mod.AssetRecord,
    cooked_ibl_path: []const u8,
) !void {
    const encoded = try std.fs.cwd().readFileAlloc(allocator, record.source_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var decoded = try image_decoder.decodeRgba32f(allocator, encoded);
    defer decoded.deinit();

    const cooked_ibl = try generateIBLDataForHDR(
        allocator,
        record.id,
        record.source_path,
        record.source_hash,
        record.import_settings_hash,
        record.resolvedImportVersion(),
        decoded.width,
        decoded.height,
        decoded.pixels,
    );
    defer allocator.free(cooked_ibl);

    if (std.fs.path.dirname(cooked_ibl_path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = cooked_ibl_path,
        .data = cooked_ibl,
    });
}

fn ensureDerivedTexture(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    source_record: *const registry_mod.AssetRecord,
    asset_id: []const u8,
    suffix: []const u8,
    display_name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels: []const u8,
) !handles.TextureHandle {
    const derived_asset_id = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ asset_id, suffix });
    defer allocator.free(derived_asset_id);

    if (library.textureHandleByAssetId(derived_asset_id)) |handle| {
        return handle;
    }

    const source_path = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ source_record.source_path, suffix });
    defer allocator.free(source_path);

    const handle = try library.createTexture(.{
        .name = display_name,
        .width = width,
        .height = height,
        .format = format,
        .pixels = pixels,
    });
    _ = try library.bindTextureAssetRecord(
        handle,
        try makeSyntheticTextureRecord(
            allocator,
            derived_asset_id,
            source_path,
            display_name,
            source_record.source_hash,
            source_record.import_settings_hash,
            &.{source_record.id},
        ),
    );
    return handle;
}

fn makeSyntheticTextureRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    dependencies: []const []const u8,
) !registry_mod.AssetRecord {
    const dependency_ids = try allocator.alloc([]u8, dependencies.len);
    var dependency_count: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < dependency_count) : (index += 1) {
            allocator.free(dependency_ids[index]);
        }
        allocator.free(dependency_ids);
    }
    for (dependencies, 0..) |dependency, index| {
        dependency_ids[index] = try allocator.dupe(u8, dependency);
        dependency_count = index + 1;
    }

    return .{
        .id = try allocator.dupe(u8, id),
        .type = .texture,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, source_hash),
        .import_settings_hash = try allocator.dupe(u8, import_settings_hash),
        .import_version = current_environment_map_cache_version,
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, derived_importer_name),
            .source_extension = try allocator.dupe(u8, ".hdr"),
        },
    };
}

fn decodeRgb32fHexToRgbaBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const rgb_bytes = try decodeHexAlloc(allocator, hex);
    defer allocator.free(rgb_bytes);

    const rgb_aligned: []align(@alignOf(f32)) const u8 = @alignCast(rgb_bytes);
    const rgb = std.mem.bytesAsSlice(f32, rgb_aligned);
    if (rgb.len % 3 != 0) {
        return error.InvalidIBLPixelPayload;
    }

    const pixel_count = rgb.len / 3;
    var rgba = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(rgba);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const src = index * 3;
        const dst = index * 4;
        rgba[dst] = rgb[src];
        rgba[dst + 1] = rgb[src + 1];
        rgba[dst + 2] = rgb[src + 2];
        rgba[dst + 3] = 1.0;
    }

    const bytes = try allocator.alloc(u8, rgba.len * @sizeOf(f32));
    @memcpy(bytes, std.mem.sliceAsBytes(rgba));
    allocator.free(rgba);
    return bytes;
}

fn expandRg32fToRgbaBytes(allocator: std.mem.Allocator, rg: []const f32) ![]u8 {
    if (rg.len % 2 != 0) {
        return error.InvalidBRDFPayload;
    }

    const pixel_count = rg.len / 2;
    var rgba = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(rgba);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const src = index * 2;
        const dst = index * 4;
        rgba[dst] = rg[src];
        rgba[dst + 1] = rg[src + 1];
        rgba[dst + 2] = 0.0;
        rgba[dst + 3] = 1.0;
    }

    const bytes = try allocator.alloc(u8, rgba.len * @sizeOf(f32));
    @memcpy(bytes, std.mem.sliceAsBytes(rgba));
    allocator.free(rgba);
    return bytes;
}

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
