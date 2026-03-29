const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const handles = @import("../assets/handles.zig");
const material_resource_mod = @import("../assets/material_resource.zig");
const registry_mod = @import("../assets/registry.zig");
const texture_resource_mod = @import("../assets/texture_resource.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const scene_extraction = @import("scene_extraction.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");
const quat_mod = @import("../math/quat.zig");
const vec3 = @import("../math/vec3.zig");

pub const material_thumbnail_dimension: u32 = 128;
pub const material_thumbnail_jobs_per_frame: usize = 2;
pub const material_thumbnail_cache_limit: usize = 48;
pub const material_thumbnail_clear_color = [4]f32{ 0.075, 0.08, 0.09, 1.0 };
pub const thumbnail_viewport_state = types.EditorViewportState{
    .render_mode = .textured,
    .show_grid = false,
    .show_bones = false,
    .show_collision = false,
};

pub const MaterialThumbnailTextureFingerprint = struct {
    handle: ?handles.TextureHandle = null,
    width: u32 = 0,
    height: u32 = 0,
    format: rhi_types.TextureFormat = .unknown,
};

pub const MaterialThumbnailSignature = struct {
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    texture: MaterialThumbnailTextureFingerprint = .{},
};

pub const MaterialThumbnailSource = struct {
    material_handle: handles.MaterialHandle,
    material: *const material_resource_mod.MaterialResource,
    texture: ?*const texture_resource_mod.TextureResource = null,
    signature: MaterialThumbnailSignature,
};

pub const ThumbnailRenderTarget = struct {
    color_texture: rhi_mod.Texture,
    depth_texture: rhi_mod.Texture,

    pub fn init(device: *rhi_mod.RhiDevice) !ThumbnailRenderTarget {
        const color_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .bgra8_unorm_srgb,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer {
            var owned = color_texture;
            device.releaseTexture(&owned);
        }

        const depth_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .d32_float,
            .usage = rhi_types.TextureUsage.depth_stencil_target,
        });
        errdefer {
            var owned = depth_texture;
            device.releaseTexture(&owned);
        }

        return .{
            .color_texture = color_texture,
            .depth_texture = depth_texture,
        };
    }

    pub fn deinit(self: *ThumbnailRenderTarget, device: *rhi_mod.RhiDevice) void {
        device.releaseTexture(&self.color_texture);
        device.releaseTexture(&self.depth_texture);
        self.* = undefined;
    }
};

pub const MaterialThumbnailCacheEntry = struct {
    asset_id: []u8,
    target: ThumbnailRenderTarget,
    signature: MaterialThumbnailSignature = .{},
    dirty: bool = true,
    queued: bool = false,
    ready: bool = false,
    last_requested_frame: usize = 0,

    pub fn deinit(self: *MaterialThumbnailCacheEntry, allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) void {
        allocator.free(self.asset_id);
        self.target.deinit(device);
        self.* = undefined;
    }
};

pub const MaterialThumbnailPreview = struct {
    world: scene_mod.World,
    preview_entity: scene_mod.EntityId,
    preview_material_handle: handles.MaterialHandle,
    preview_texture_handle: ?handles.TextureHandle = null,

    pub fn init(allocator: std.mem.Allocator) !MaterialThumbnailPreview {
        var world = scene_mod.World.init(allocator, null);
        errdefer world.deinit();

        const sphere_mesh = try world.assets().ensurePrimitiveMesh(.sphere);
        const preview_material_handle = try world.assets().createMaterial(.{
            .name = "ThumbnailMaterial",
            .shading = .pbr_metallic_roughness,
            .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        });

        const preview_entity = try world.createEntity(.{
            .name = "ThumbnailSphere",
            .local_transform = .{
                .rotation = quat_mod.fromEuler(.{ 0.0, 0.42, 0.0 }),
                .scale = .{ 1.08, 1.08, 1.08 },
            },
            .mesh = .{
                .handle = sphere_mesh,
                .primitive = .sphere,
            },
            .material = .{
                .handle = preview_material_handle,
            },
        });

        const camera_position = [3]f32{ 1.8, 1.05, 2.45 };
        _ = try world.createEntity(.{
            .name = "ThumbnailCamera",
            .camera = .{
                .is_primary = true,
                .projection = .{
                    .perspective = .{
                        .fov_y_radians = 0.68,
                        .near_clip = 0.1,
                        .far_clip = 32.0,
                    },
                },
            },
            .local_transform = .{
                .translation = camera_position,
                .rotation = quat_mod.fromEuler(lookRotationEuler(camera_position, .{ 0.0, 0.0, 0.0 })),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailKeyLight",
            .light = .{
                .kind = .directional,
                .color = .{ 1.0, 0.98, 0.94 },
                .intensity = 2.6,
            },
            .local_transform = .{
                .rotation = quat_mod.fromEuler(.{ -0.88, 0.68, 0.0 }),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailFillLight",
            .light = .{
                .kind = .point,
                .color = .{ 0.72, 0.82, 1.0 },
                .intensity = 5.8,
                .range = 8.0,
            },
            .local_transform = .{
                .translation = .{ 1.7, 1.25, 1.2 },
            },
        });

        return .{
            .world = world,
            .preview_entity = preview_entity,
            .preview_material_handle = preview_material_handle,
        };
    }

    pub fn deinit(self: *MaterialThumbnailPreview) void {
        self.world.deinit();
        self.* = undefined;
    }

    pub fn syncFromSource(self: *MaterialThumbnailPreview, source: MaterialThumbnailSource) !void {
        var preview_texture_handle: ?handles.TextureHandle = null;
        if (source.texture) |texture| {
            preview_texture_handle = try self.upsertPreviewTexture(texture);
        }

        const material_index = handles.indexOf(self.preview_material_handle);
        const preview_material = &self.world.resources.materials.items[material_index];
        preview_material.shading = source.material.shading;
        preview_material.base_color_factor = source.material.base_color_factor;
        preview_material.base_color_texture = preview_texture_handle;

        if (self.world.getEntity(self.preview_entity)) |entity| {
            entity.material = .{
                .handle = self.preview_material_handle,
                .shading = source.material.shading,
                .base_color_factor = source.material.base_color_factor,
            };
        }
    }

    fn upsertPreviewTexture(
        self: *MaterialThumbnailPreview,
        source_texture: *const texture_resource_mod.TextureResource,
    ) !handles.TextureHandle {
        if (self.preview_texture_handle) |handle| {
            const owned_pixels = try self.world.allocator.dupe(u8, source_texture.pixels);
            errdefer self.world.allocator.free(owned_pixels);

            const preview_texture = &self.world.resources.textures.items[handles.indexOf(handle)];
            self.world.allocator.free(preview_texture.pixels);
            preview_texture.width = source_texture.width;
            preview_texture.height = source_texture.height;
            preview_texture.format = source_texture.format;
            preview_texture.pixels = owned_pixels;
            return handle;
        }

        const created = try self.world.assets().createTexture(.{
            .name = "ThumbnailTexture",
            .width = source_texture.width,
            .height = source_texture.height,
            .format = source_texture.format,
            .pixels = source_texture.pixels,
        });
        self.preview_texture_handle = created;
        return created;
    }
};

pub fn requestMaterialThumbnail(self: anytype, scene: *const scene_mod.Scene, asset_id: []const u8, frame_index: usize) !void {
    const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
        removeMaterialThumbnail(self, asset_id);
        return;
    };

    const entry = try ensureMaterialThumbnailEntry(self, asset_id);
    const signature_changed = !std.meta.eql(entry.signature, source.signature);
    if (signature_changed) {
        entry.signature = source.signature;
        entry.dirty = true;
        entry.ready = false;
    }
    entry.last_requested_frame = frame_index;
    if (entry.dirty and !entry.queued) {
        try enqueueMaterialThumbnailRequest(self, entry);
    }
}

pub fn materialThumbnailTexture(self: anytype, asset_id: []const u8) ?*const rhi_mod.Texture {
    const entry = findMaterialThumbnailCacheIndex(self, asset_id) orelse return null;
    if (!entry.ready) return null;
    return &entry.target.color_texture;
}

pub fn processMaterialThumbnailRequests(
    self: anytype,
    frame: rhi_mod.Frame,
    scene: *const scene_mod.Scene,
) !mesh_pass_mod.DrawStats {
    var stats = mesh_pass_mod.DrawStats{};
    if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
        return stats;
    }

    var processed: usize = 0;
    while (processed < material_thumbnail_jobs_per_frame and self.material_thumbnail_requests.items.len > 0) : (processed += 1) {
        const asset_id = self.material_thumbnail_requests.orderedRemove(0);
        defer self.allocator.free(asset_id);

        const entry_ptr = findMaterialThumbnailCacheIndex(self, asset_id) orelse continue;
        entry_ptr.queued = false;

        const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
            removeMaterialThumbnail(self, asset_id);
            continue;
        };

        try self.material_thumbnail_preview.syncFromSource(source);
        self.thumbnail_scene_cache.invalidateMaterialResources(&self.rhi);

        _ = try scene_extraction.extractWorld(
            &self.material_thumbnail_preview.world,
            &self.thumbnail_render_world,
            null,
            &.{},
            null,
        );

        var prepared_scene = try self.thumbnail_scene_cache.prepareScene(
            &self.rhi,
            &self.material_thumbnail_preview.world,
            &self.thumbnail_render_world,
            material_thumbnail_dimension,
            material_thumbnail_dimension,
        );
        defer prepared_scene.deinit();

        const render_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
            .color = .{
                .target = .{ .texture = &entry_ptr.target.color_texture },
                .clear_color = material_thumbnail_clear_color,
                .load_op = .clear,
                .store_op = .store,
            },
            .depth = .{
                .texture = &entry_ptr.target.depth_texture,
                .clear_depth = 1.0,
                .clear_stencil = 0,
                .load_op = .clear,
                .store_op = .dont_care,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
            },
        });

        const depth_stats = self.depth_prepass.draw(&self.rhi, frame, render_pass, &prepared_scene, .ldr);
        stats.add(depth_stats);
        const base_stats = try self.base_pass.draw(&self.rhi, frame, render_pass, &prepared_scene, .{
            .render_mode = thumbnail_viewport_state.render_mode,
            .target = .ldr,
        });
        stats.add(base_stats);
        self.rhi.endRenderPass(render_pass);

        entry_ptr.signature = source.signature;
        entry_ptr.dirty = false;
        entry_ptr.ready = true;
    }

    return stats;
}

pub fn findMaterialThumbnailCacheIndex(self: anytype, asset_id: []const u8) ?*MaterialThumbnailCacheEntry {
    return self.material_thumbnail_cache.getPtr(asset_id);
}

pub fn ensureMaterialThumbnailEntry(self: anytype, asset_id: []const u8) !*MaterialThumbnailCacheEntry {
    if (self.material_thumbnail_cache.getPtr(asset_id)) |entry| {
        return entry;
    }

    if (self.material_thumbnail_cache.count() >= material_thumbnail_cache_limit) {
        evictMaterialThumbnailEntry(self, asset_id);
    }

    const owned_asset_id = try self.allocator.dupe(u8, asset_id);
    errdefer self.allocator.free(owned_asset_id);

    const target = try ThumbnailRenderTarget.init(&self.rhi);
    errdefer {
        var owned = target;
        owned.deinit(&self.rhi);
    }

    const entry = MaterialThumbnailCacheEntry{
        .asset_id = owned_asset_id,
        .target = target,
    };
    try self.material_thumbnail_cache.put(owned_asset_id, entry);
    return self.material_thumbnail_cache.getPtr(owned_asset_id).?;
}

pub fn enqueueMaterialThumbnailRequest(self: anytype, entry: *MaterialThumbnailCacheEntry) !void {
    const queued_asset_id = try self.allocator.dupe(u8, entry.asset_id);
    errdefer self.allocator.free(queued_asset_id);

    try self.material_thumbnail_requests.append(self.allocator, queued_asset_id);
    entry.queued = true;
}

pub fn evictMaterialThumbnailEntry(self: anytype, keep_asset_id: []const u8) void {
    var oldest_unqueued_key: ?[]const u8 = null;
    var oldest_any_key: ?[]const u8 = null;
    var min_frame_unqueued: u64 = std.math.maxInt(u64);
    var min_frame_any: u64 = std.math.maxInt(u64);

    var it = self.material_thumbnail_cache.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr;
        if (std.mem.eql(u8, key, keep_asset_id)) {
            continue;
        }
        if (value.last_requested_frame < min_frame_any) {
            min_frame_any = value.last_requested_frame;
            oldest_any_key = key;
        }
        if (!value.queued and value.last_requested_frame < min_frame_unqueued) {
            min_frame_unqueued = value.last_requested_frame;
            oldest_unqueued_key = key;
        }
    }

    const key_to_remove = oldest_unqueued_key orelse oldest_any_key;
    if (key_to_remove) |key| {
        if (self.material_thumbnail_cache.fetchRemove(key)) |kv| {
            var value = kv.value;
            value.deinit(self.allocator, &self.rhi);
        }
    }
}

pub fn removeMaterialThumbnail(self: anytype, asset_id: []const u8) void {
    if (self.material_thumbnail_cache.fetchRemove(asset_id)) |kv| {
        var value = kv.value;
        value.deinit(self.allocator, &self.rhi);
    }
}

pub fn releaseMaterialThumbnailCache(self: anytype) void {
    var it = self.material_thumbnail_cache.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator, &self.rhi);
    }
    self.material_thumbnail_cache.deinit();
    self.material_thumbnail_cache = undefined;
}

pub fn releaseMaterialThumbnailRequests(self: anytype) void {
    for (self.material_thumbnail_requests.items) |asset_id| {
        self.allocator.free(asset_id);
    }
    self.material_thumbnail_requests.deinit(self.allocator);
    self.material_thumbnail_requests = .empty;
}

pub fn resolveMaterialThumbnailSource(
    resources: *const assets_lib.ResourceLibrary,
    asset_id: []const u8,
) ?MaterialThumbnailSource {
    const material_handle = resources.materialHandleByAssetId(asset_id) orelse return null;
    const material = resources.material(material_handle) orelse return null;

    var source = MaterialThumbnailSource{
        .material_handle = material_handle,
        .material = material,
        .signature = .{
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
        },
    };

    if (material.base_color_texture) |texture_handle| {
        if (resources.texture(texture_handle)) |texture| {
            source.texture = texture;
            source.signature.texture = .{
                .handle = texture_handle,
                .width = texture.width,
                .height = texture.height,
                .format = texture.format,
            };
        }
    }

    return source;
}

fn lookRotationEuler(from: [3]f32, to: [3]f32) [3]f32 {
    const direction = vec3.normalize(vec3.sub(to, from));
    return .{
        std.math.asin(std.math.clamp(direction[1], -1.0, 1.0)),
        std.math.atan2(-direction[0], -direction[2]),
        0.0,
    };
}

pub fn makeOwnedTestAssetRecord(
    allocator: std.mem.Allocator,
    asset_type: registry_mod.AssetType,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !registry_mod.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = asset_type,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "thumbnail-test-source"),
        .import_settings_hash = try allocator.dupe(u8, "thumbnail-test-settings"),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ".thumb"),
        },
    };
}

test "resolveMaterialThumbnailSource captures loaded material signatures" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewAlbedo",
        .width = 4,
        .height = 2,
        .pixels = &[_]u8{
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://preview", "assets/textures/preview.png", "Preview Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewMaterial",
        .shading = .lambert,
        .base_color_factor = .{ 0.2, 0.4, 0.6, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://preview", "assets/materials/preview.guava_material", "Preview Material"),
    );

    const source = resolveMaterialThumbnailSource(world.assets(), "material://preview").?;
    try std.testing.expectEqual(material_handle, source.material_handle);
    try std.testing.expectEqual(components.ShadingModel.lambert, source.signature.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.2, 0.4, 0.6, 1.0 }, source.signature.base_color_factor);
    try std.testing.expectEqual(texture_handle, source.signature.texture.handle.?);
    try std.testing.expectEqual(@as(u32, 4), source.signature.texture.width);
    try std.testing.expectEqual(@as(u32, 2), source.signature.texture.height);
}

test "material thumbnail preview scene mirrors source material resources" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewSyncTexture",
        .width = 2,
        .height = 2,
        .pixels = &[_]u8{
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://sync", "assets/textures/sync.png", "Sync Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewSyncMaterial",
        .shading = .unlit,
        .base_color_factor = .{ 0.9, 0.3, 0.1, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://sync", "assets/materials/sync.guava_material", "Sync Material"),
    );

    var preview = try MaterialThumbnailPreview.init(std.testing.allocator);
    defer preview.deinit();

    const source = resolveMaterialThumbnailSource(world.assets(), "material://sync").?;
    try preview.syncFromSource(source);

    const preview_material = preview.world.resources.material(preview.preview_material_handle).?;
    try std.testing.expectEqual(components.ShadingModel.unlit, preview_material.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.9, 0.3, 0.1, 1.0 }, preview_material.base_color_factor);
    try std.testing.expect(preview_material.base_color_texture != null);

    const preview_texture = preview.world.resources.texture(preview_material.base_color_texture.?).?;
    try std.testing.expectEqual(@as(u32, 2), preview_texture.width);
    try std.testing.expectEqual(@as(u32, 2), preview_texture.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
    }, preview_texture.pixels);
}
