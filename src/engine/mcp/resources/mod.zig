const std = @import("std");
const protocol = @import("../protocol.zig");
const scene_mod = @import("../../scene/scene.zig");
const components = @import("../../scene/components.zig");
const render_mod = @import("../../render/renderer.zig");

pub const resource_templates = [_]protocol.ResourceTemplateDescriptor{
    .{
        .uriTemplate = "entity://{id}",
        .name = "Entity Detail",
        .description = "Read-only snapshot for a specific entity id discovered from scene://hierarchy or selection://current.",
        .mimeType = "application/json",
    },
};

pub const SnapshotStore = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    ready: bool = false,
    entries: std.ArrayList(ResourceEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) SnapshotStore {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *SnapshotStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        freeEntriesOwned(self.allocator, self.entries.items);
        self.entries.deinit(self.allocator);
    }

    pub fn isReady(self: *const SnapshotStore) bool {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return mutable.ready;
    }

    pub fn replaceFromRenderer(self: *SnapshotStore, world: *const scene_mod.World, renderer: *const render_mod.Renderer) !void {
        try self.replaceFromSelection(world, renderer.selectedEntity(), renderer.selectedEntities());
    }

    pub fn replaceFromSelection(
        self: *SnapshotStore,
        world: *const scene_mod.World,
        primary_selection: ?scene_mod.EntityId,
        selected_entities: []const scene_mod.EntityId,
    ) !void {
        const next_entries = try buildResourceEntriesAlloc(self.allocator, world, primary_selection, selected_entities);
        errdefer {
            freeEntriesOwned(self.allocator, next_entries);
            self.allocator.free(next_entries);
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        freeEntriesOwned(self.allocator, self.entries.items);
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        try self.entries.appendSlice(self.allocator, next_entries);
        self.ready = true;

        self.allocator.free(next_entries);
    }

    pub fn listAlloc(self: *const SnapshotStore, allocator: std.mem.Allocator) ![]protocol.ResourceDescriptor {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        var resources = std.ArrayList(protocol.ResourceDescriptor).empty;
        errdefer {
            for (resources.items) |resource| {
                allocator.free(resource.uri);
                allocator.free(resource.name);
                if (resource.title) |title| {
                    allocator.free(title);
                }
                if (resource.description) |description| {
                    allocator.free(description);
                }
                if (resource.mimeType) |mime_type| {
                    allocator.free(mime_type);
                }
            }
            resources.deinit(allocator);
        }

        const listed_count = countListedResources(mutable.entries.items);
        try resources.ensureTotalCapacity(allocator, listed_count);
        for (mutable.entries.items) |entry| {
            if (!shouldListEntry(entry.uri)) {
                continue;
            }
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, entry.uri),
                .name = try allocator.dupe(u8, entry.name),
                .title = if (entry.title) |title| try allocator.dupe(u8, title) else null,
                .description = if (entry.description) |description| try allocator.dupe(u8, description) else null,
                .mimeType = if (entry.mime_type) |mime_type| try allocator.dupe(u8, mime_type) else null,
                .size = entry.text.len,
            });
        }

        return try resources.toOwnedSlice(allocator);
    }

    pub fn readAlloc(self: *const SnapshotStore, allocator: std.mem.Allocator, uri: []const u8) !?protocol.TextResourceContents {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        for (mutable.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.uri, uri)) {
                continue;
            }

            return .{
                .uri = try allocator.dupe(u8, entry.uri),
                .mimeType = if (entry.mime_type) |mime_type| try allocator.dupe(u8, mime_type) else null,
                .text = try allocator.dupe(u8, entry.text),
            };
        }

        return null;
    }
};

pub fn freeResourceDescriptors(allocator: std.mem.Allocator, resources: []protocol.ResourceDescriptor) void {
    for (resources) |resource| {
        allocator.free(resource.uri);
        allocator.free(resource.name);
        if (resource.title) |title| {
            allocator.free(title);
        }
        if (resource.description) |description| {
            allocator.free(description);
        }
        if (resource.mimeType) |mime_type| {
            allocator.free(mime_type);
        }
    }
    allocator.free(resources);
}

pub fn freeTextResourceContents(allocator: std.mem.Allocator, content: protocol.TextResourceContents) void {
    allocator.free(content.uri);
    if (content.mimeType) |mime_type| {
        allocator.free(mime_type);
    }
    allocator.free(content.text);
}

const ResourceEntry = struct {
    uri: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    text: []u8,
};

fn shouldListEntry(uri: []const u8) bool {
    return !std.mem.startsWith(u8, uri, "entity://");
}

fn countListedResources(entries: []const ResourceEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (shouldListEntry(entry.uri)) {
            count += 1;
        }
    }
    return count;
}

fn freeEntriesOwned(allocator: std.mem.Allocator, entries: []ResourceEntry) void {
    for (entries) |entry| {
        allocator.free(entry.uri);
        allocator.free(entry.name);
        if (entry.title) |title| {
            allocator.free(title);
        }
        if (entry.description) |description| {
            allocator.free(description);
        }
        if (entry.mime_type) |mime_type| {
            allocator.free(mime_type);
        }
        allocator.free(entry.text);
    }
}

fn buildResourceEntriesAlloc(
    allocator: std.mem.Allocator,
    world: *const scene_mod.World,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) ![]ResourceEntry {
    var entries = std.ArrayList(ResourceEntry).empty;
    errdefer {
        freeEntriesOwned(allocator, entries.items);
        entries.deinit(allocator);
    }

    try entries.append(allocator, try buildSceneHierarchyEntry(allocator, world));
    try entries.append(allocator, try buildSelectionEntry(allocator, primary_selection, selected_entities));

    for (world.entities.items) |entity| {
        try entries.append(allocator, try buildEntityEntry(allocator, world, entity.id));
    }

    return try entries.toOwnedSlice(allocator);
}

fn buildSceneHierarchyEntry(allocator: std.mem.Allocator, world: *const scene_mod.World) !ResourceEntry {
    const text = try buildHierarchyJsonAlloc(allocator, world);
    errdefer allocator.free(text);

    return .{
        .uri = try allocator.dupe(u8, "scene://hierarchy"),
        .name = try allocator.dupe(u8, "Scene Hierarchy"),
        .description = try allocator.dupe(u8, "Current entity tree and scene summary."),
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildSelectionEntry(
    allocator: std.mem.Allocator,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) !ResourceEntry {
    const text = try buildSelectionJsonAlloc(allocator, primary_selection, selected_entities);
    errdefer allocator.free(text);

    return .{
        .uri = try allocator.dupe(u8, "selection://current"),
        .name = try allocator.dupe(u8, "Current Selection"),
        .description = try allocator.dupe(u8, "Primary selection and ordered selected entities."),
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildEntityEntry(allocator: std.mem.Allocator, world: *const scene_mod.World, entity_id: scene_mod.EntityId) !ResourceEntry {
    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    const text = try buildEntityDetailJsonAlloc(allocator, world, entity_id);
    errdefer allocator.free(text);

    const uri = try std.fmt.allocPrint(allocator, "entity://{d}", .{entity_id});
    errdefer allocator.free(uri);

    const description = try std.fmt.allocPrint(allocator, "Snapshot of entity '{s}' ({d}).", .{ entity.name, entity_id });
    errdefer allocator.free(description);

    return .{
        .uri = uri,
        .name = try allocator.dupe(u8, entity.name),
        .description = description,
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildHierarchyJsonAlloc(allocator: std.mem.Allocator, world: *const scene_mod.World) ![]u8 {
    const HierarchyEntity = struct {
        id: scene_mod.EntityId,
        name: []const u8,
        parent: ?scene_mod.EntityId = null,
        children: []const scene_mod.EntityId,
        visible: bool,
        editor_only: bool,
        is_folder: bool,
    };
    const HierarchySnapshot = struct {
        roots: []const scene_mod.EntityId,
        entities: []const HierarchyEntity,
        summary: scene_mod.Summary,
    };

    var roots = std.ArrayList(scene_mod.EntityId).empty;
    defer roots.deinit(allocator);
    var entities = std.ArrayList(HierarchyEntity).empty;
    defer entities.deinit(allocator);

    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            try roots.append(allocator, entity.id);
        }
        try entities.append(allocator, .{
            .id = entity.id,
            .name = entity.name,
            .parent = entity.parent,
            .children = entity.children.items,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
        });
    }

    return stringifyAlloc(allocator, HierarchySnapshot{
        .roots = roots.items,
        .entities = entities.items,
        .summary = world.summary(),
    });
}

fn buildSelectionJsonAlloc(
    allocator: std.mem.Allocator,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) ![]u8 {
    const SelectionSnapshot = struct {
        primary: ?scene_mod.EntityId = null,
        entities: []const scene_mod.EntityId,
    };

    return stringifyAlloc(allocator, SelectionSnapshot{
        .primary = primary_selection,
        .entities = selected_entities,
    });
}

fn buildEntityDetailJsonAlloc(allocator: std.mem.Allocator, world: *const scene_mod.World, entity_id: scene_mod.EntityId) ![]u8 {
    const MeshView = struct {
        handle: ?u32 = null,
        primitive: components.Primitive = .custom,
    };
    const SkinnedMeshView = struct {
        mesh_handle: ?u32 = null,
        primitive: components.Primitive = .custom,
        skeleton_handle: ?u32 = null,
        skin_handle: ?u32 = null,
    };
    const AnimatorView = struct {
        skeleton_handle: ?u32 = null,
        default_clip_handle: ?u32 = null,
        time_seconds: f32 = 0.0,
        next_clip_handle: ?u32 = null,
        next_time_seconds: f32 = 0.0,
        blend_duration_seconds: f32 = 0.0,
        blend_time_seconds: f32 = 0.0,
        speed: f32 = 1.0,
        playing: bool = true,
        looping: bool = true,
    };
    const MaterialView = struct {
        handle: ?u32 = null,
        shading: components.ShadingModel = .pbr_metallic_roughness,
        base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
        metallic_factor: f32 = 1.0,
        roughness_factor: f32 = 1.0,
        alpha_cutoff: f32 = 0.5,
        double_sided: bool = false,
    };
    const ScriptView = struct {
        script_handle: ?u32 = null,
        language: components.ScriptLanguage = .zig,
        instance_id: ?u64 = null,
        enabled: bool = true,
        parameters: []const u8 = "",
    };
    const BoundsView = struct {
        min: [3]f32,
        max: [3]f32,
    };
    const ComponentsView = struct {
        camera: ?components.Camera = null,
        mesh: ?MeshView = null,
        skinned_mesh: ?SkinnedMeshView = null,
        animator: ?AnimatorView = null,
        rigidbody: ?components.Rigidbody = null,
        box_collider: ?components.BoxCollider = null,
        sphere_collider: ?components.SphereCollider = null,
        mesh_collider: ?components.MeshCollider = null,
        constraint: ?components.Constraint = null,
        material: ?MaterialView = null,
        light: ?components.Light = null,
        vfx: ?components.Vfx = null,
        script: ?ScriptView = null,
    };
    const EntityDetail = struct {
        id: scene_mod.EntityId,
        name: []const u8,
        parent: ?scene_mod.EntityId = null,
        children: []const scene_mod.EntityId,
        visible: bool,
        editor_only: bool,
        is_folder: bool,
        dirty: bool,
        local_transform: components.Transform,
        world_transform: components.Transform,
        world_matrix: [16]f32,
        world_bounds: ?BoundsView = null,
        components: ComponentsView,
    };

    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    const world_transform = world.worldTransformConst(entity_id) orelse entity.local_transform;
    const world_bounds = if (world.worldBoundsConst(entity_id)) |bounds| BoundsView{
        .min = bounds.min,
        .max = bounds.max,
    } else null;

    return stringifyAlloc(allocator, EntityDetail{
        .id = entity.id,
        .name = entity.name,
        .parent = entity.parent,
        .children = entity.children.items,
        .visible = entity.visible,
        .editor_only = entity.editor_only,
        .is_folder = entity.is_folder,
        .dirty = entity.dirty,
        .local_transform = entity.local_transform,
        .world_transform = world_transform,
        .world_matrix = entity.world_matrix_cache,
        .world_bounds = world_bounds,
        .components = .{
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh| .{
                .handle = optionalHandleValue(mesh.handle),
                .primitive = mesh.primitive,
            } else null,
            .skinned_mesh = if (entity.skinned_mesh) |skinned_mesh| .{
                .mesh_handle = optionalHandleValue(skinned_mesh.mesh_handle),
                .primitive = skinned_mesh.primitive,
                .skeleton_handle = optionalHandleValue(skinned_mesh.skeleton_handle),
                .skin_handle = optionalHandleValue(skinned_mesh.skin_handle),
            } else null,
            .animator = if (entity.animator) |animator| .{
                .skeleton_handle = optionalHandleValue(animator.skeleton_handle),
                .default_clip_handle = optionalHandleValue(animator.default_clip_handle),
                .time_seconds = animator.time_seconds,
                .next_clip_handle = optionalHandleValue(animator.next_clip_handle),
                .next_time_seconds = animator.next_time_seconds,
                .blend_duration_seconds = animator.blend_duration_seconds,
                .blend_time_seconds = animator.blend_time_seconds,
                .speed = animator.speed,
                .playing = animator.playing,
                .looping = animator.looping,
            } else null,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .constraint = entity.constraint,
            .material = if (entity.material) |material| .{
                .handle = optionalHandleValue(material.handle),
                .shading = material.shading,
                .base_color_factor = material.base_color_factor,
                .emissive_factor = material.emissive_factor,
                .metallic_factor = material.metallic_factor,
                .roughness_factor = material.roughness_factor,
                .alpha_cutoff = material.alpha_cutoff,
                .double_sided = material.double_sided,
            } else null,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = if (entity.script) |script| .{
                .script_handle = optionalHandleValue(script.script_handle),
                .language = script.language,
                .instance_id = script.instance_id,
                .enabled = script.enabled,
                .parameters = script.parameters,
            } else null,
        },
    });
}

fn optionalHandleValue(handle: anytype) ?u32 {
    if (handle) |resolved| {
        const raw = @intFromEnum(resolved);
        if (raw == 0) {
            return null;
        }
        return @intCast(raw);
    }
    return null;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    return try output.toOwnedSlice(allocator);
}

test "SnapshotStore publishes read-only hierarchy, selection, and entity snapshots" {
    var store = SnapshotStore.init(std.testing.allocator);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "Root",
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = root,
        .visible = false,
    });
    world.updateHierarchy();

    try store.replaceFromSelection(&world, root, &.{ root, child });
    try std.testing.expect(store.isReady());

    const listed = try store.listAlloc(std.testing.allocator);
    defer freeResourceDescriptors(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("scene://hierarchy", listed[0].uri);
    try std.testing.expectEqualStrings("selection://current", listed[1].uri);

    const selection = (try store.readAlloc(std.testing.allocator, "selection://current")).?;
    defer freeTextResourceContents(std.testing.allocator, selection);
    try std.testing.expect(std.mem.indexOf(u8, selection.text, "\"primary\": 1") != null);

    const entity = (try store.readAlloc(std.testing.allocator, "entity://2")).?;
    defer freeTextResourceContents(std.testing.allocator, entity);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"name\": \"Child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"visible\": false") != null);
}

test "resource templates advertise dynamic entity snapshots" {
    try std.testing.expectEqual(@as(usize, 1), resource_templates.len);
    try std.testing.expectEqualStrings("entity://{id}", resource_templates[0].uriTemplate);
    try std.testing.expectEqualStrings("application/json", resource_templates[0].mimeType.?);
}
