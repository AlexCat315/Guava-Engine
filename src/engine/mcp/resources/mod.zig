const std = @import("std");
const collaboration_mod = @import("../collaboration.zig");
const protocol = @import("../protocol.zig");
const script_runtime_mod = @import("../../script/runtime.zig");
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

const schema_components_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://components",
    .name = "Component Schema",
    .title = "Component Schema",
    .description = "Stable JSON contract for entity fields, vector conventions, enums, and component payloads accepted by Guava Engine.",
    .mimeType = "application/json",
    .size = null,
};

pub const SnapshotStore = struct {
    allocator: std.mem.Allocator,
    collaboration: ?*const collaboration_mod.Store = null,
    script_runtime: ?*const script_runtime_mod.ScriptRuntime = null,
    mutex: std.Thread.Mutex = .{},
    ready: bool = false,
    entries: std.ArrayList(ResourceEntry) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        collaboration: ?*const collaboration_mod.Store,
        script_runtime: ?*const script_runtime_mod.ScriptRuntime,
    ) SnapshotStore {
        return .{
            .allocator = allocator,
            .collaboration = collaboration,
            .script_runtime = script_runtime,
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

        const listed_count = countListedResources(mutable.entries.items) +
            1 +
            @as(usize, if (mutable.collaboration != null) 3 else 0) +
            @as(usize, if (mutable.script_runtime != null) 1 else 0);
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

        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_components_descriptor));

        if (mutable.collaboration) |_| {
            try collaboration_mod.Store.appendResourceDescriptorsAlloc(allocator, &resources);
        }
        if (mutable.script_runtime != null) {
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, "script://runtime-status"),
                .name = try allocator.dupe(u8, "Script Runtime Status"),
                .title = try allocator.dupe(u8, "Script Runtime Status"),
                .description = try allocator.dupe(u8, "Recent compile, load, and runtime errors reported by the script system."),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .size = null,
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

        if (std.mem.eql(u8, uri, "schema://components")) {
            return .{
                .uri = try allocator.dupe(u8, schema_components_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildComponentsSchemaJsonAlloc(allocator),
            };
        }

        if (mutable.collaboration) |collaboration| {
            return try collaboration.readResourceAlloc(allocator, uri);
        }

        if (mutable.script_runtime != null and std.mem.eql(u8, uri, "script://runtime-status")) {
            return .{
                .uri = try allocator.dupe(u8, "script://runtime-status"),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try mutable.script_runtime.?.buildStatusJsonAlloc(allocator),
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

fn copyResourceDescriptorAlloc(
    allocator: std.mem.Allocator,
    descriptor: protocol.ResourceDescriptor,
) !protocol.ResourceDescriptor {
    return .{
        .uri = try allocator.dupe(u8, descriptor.uri),
        .name = try allocator.dupe(u8, descriptor.name),
        .title = if (descriptor.title) |title| try allocator.dupe(u8, title) else null,
        .description = if (descriptor.description) |description| try allocator.dupe(u8, description) else null,
        .mimeType = if (descriptor.mimeType) |mime_type| try allocator.dupe(u8, mime_type) else null,
        .size = descriptor.size,
    };
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

fn buildComponentsSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const TypeSchema = struct {
        name: []const u8,
        encoding: []const u8,
        example: ?[]const f32 = null,
    };
    const EnumSchema = struct {
        name: []const u8,
        values: []const []const u8,
    };
    const FieldSchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const SectionSchema = struct {
        name: []const u8,
        description: []const u8,
        fields: []const FieldSchema,
    };
    const ContractSchema = struct {
        version: []const u8,
        conventions: struct {
            vectors_are_arrays: bool,
            arrays_not_objects: bool,
            notes: []const []const u8,
        },
        shared_types: []const TypeSchema,
        enums: []const EnumSchema,
        entity_fields: []const FieldSchema,
        components: []const SectionSchema,
    };

    const vec2_example = [_]f32{ 0.0, 0.0 };
    const vec3_example = [_]f32{ 0.0, 0.0, 0.0 };
    const quat_example = [_]f32{ 0.0, 0.0, 0.0, 1.0 };
    const color4_example = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const primitive_values = [_][]const u8{ "cube", "sphere", "plane", "custom" };
    const shading_values = [_][]const u8{ "unlit", "lambert", "pbr_metallic_roughness" };
    const light_values = [_][]const u8{ "directional", "point", "spot" };
    const vfx_values = [_][]const u8{ "fountain", "orbit" };
    const script_language_values = [_][]const u8{ "zig", "csharp", "wasm" };
    const rigidbody_motion_values = [_][]const u8{ "static", "dynamic", "kinematic" };
    const constraint_values = [_][]const u8{ "point_to_point", "hinge", "slider", "distance" };
    const entity_fields = [_]FieldSchema{
        .{ .name = "name", .type = "string", .description = "Entity display name.", .required = true },
        .{ .name = "parent", .type = "entity_id|null", .description = "Parent entity id or null for a root." },
        .{ .name = "local_transform", .type = "Transform", .description = "Local transform, always encoded with array vectors." },
        .{ .name = "visible", .type = "bool", .description = "Entity visibility flag." },
        .{ .name = "editor_only", .type = "bool", .description = "Whether the entity is editor-only." },
        .{ .name = "is_folder", .type = "bool", .description = "Hierarchy organization flag." },
    };
    const camera_fields = [_]FieldSchema{
        .{ .name = "is_primary", .type = "bool", .description = "Marks the primary scene camera." },
        .{ .name = "projection", .type = "CameraProjection", .description = "Either { perspective = ... } or { orthographic = ... }." },
    };
    const mesh_fields = [_]FieldSchema{
        .{ .name = "handle", .type = "asset_handle|null", .description = "Optional mesh asset handle." },
        .{ .name = "primitive", .type = "Primitive", .description = "Fallback primitive when no mesh handle is bound." },
    };
    const skinned_mesh_fields = [_]FieldSchema{
        .{ .name = "mesh_handle", .type = "asset_handle|null", .description = "Optional mesh asset handle." },
        .{ .name = "primitive", .type = "Primitive", .description = "Fallback primitive when no mesh handle is bound." },
        .{ .name = "skeleton_handle", .type = "asset_handle|null", .description = "Skeleton asset handle." },
        .{ .name = "skin_handle", .type = "asset_handle|null", .description = "Skin asset handle." },
    };
    const animator_fields = [_]FieldSchema{
        .{ .name = "skeleton_handle", .type = "asset_handle|null", .description = "Skeleton asset handle." },
        .{ .name = "default_clip_handle", .type = "asset_handle|null", .description = "Default animation clip handle." },
        .{ .name = "time_seconds", .type = "f32", .description = "Current animation time." },
        .{ .name = "next_clip_handle", .type = "asset_handle|null", .description = "Pending next clip handle." },
        .{ .name = "next_time_seconds", .type = "f32", .description = "Time in the pending next clip." },
        .{ .name = "blend_duration_seconds", .type = "f32", .description = "Blend duration in seconds." },
        .{ .name = "blend_time_seconds", .type = "f32", .description = "Current blend progress." },
        .{ .name = "speed", .type = "f32", .description = "Playback speed multiplier." },
        .{ .name = "playing", .type = "bool", .description = "Animation playing flag." },
        .{ .name = "looping", .type = "bool", .description = "Animation looping flag." },
    };
    const rigidbody_fields = [_]FieldSchema{
        .{ .name = "motion_type", .type = "RigidbodyMotionType", .description = "Motion mode for physics integration." },
        .{ .name = "mass", .type = "f32", .description = "Mass in kilograms." },
        .{ .name = "linear_velocity", .type = "Vec3", .description = "Linear velocity vector." },
        .{ .name = "angular_velocity", .type = "Vec3", .description = "Angular velocity vector." },
        .{ .name = "gravity_scale", .type = "f32", .description = "Gravity multiplier." },
        .{ .name = "linear_damping", .type = "f32", .description = "Linear damping coefficient." },
        .{ .name = "angular_damping", .type = "f32", .description = "Angular damping coefficient." },
        .{ .name = "allow_sleep", .type = "bool", .description = "Whether the rigidbody may sleep." },
    };
    const box_collider_fields = [_]FieldSchema{
        .{ .name = "half_extents", .type = "Vec3", .description = "Half extents of the box." },
        .{ .name = "center", .type = "Vec3", .description = "Local center offset." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const sphere_collider_fields = [_]FieldSchema{
        .{ .name = "radius", .type = "f32", .description = "Sphere radius." },
        .{ .name = "center", .type = "Vec3", .description = "Local center offset." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const mesh_collider_fields = [_]FieldSchema{
        .{ .name = "use_attached_mesh", .type = "bool", .description = "Use the attached mesh as the collision source." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const constraint_fields = [_]FieldSchema{
        .{ .name = "constraint_type", .type = "ConstraintType", .description = "Constraint kind." },
        .{ .name = "entity_a", .type = "entity_id", .description = "First constrained entity.", .required = true },
        .{ .name = "entity_b", .type = "entity_id", .description = "Second constrained entity.", .required = true },
        .{ .name = "pivot_a", .type = "Vec3", .description = "Constraint pivot on entity A." },
        .{ .name = "pivot_b", .type = "Vec3", .description = "Constraint pivot on entity B." },
        .{ .name = "axis_a", .type = "Vec3", .description = "Constraint axis on entity A." },
        .{ .name = "axis_b", .type = "Vec3", .description = "Constraint axis on entity B." },
        .{ .name = "min_limit", .type = "f32", .description = "Minimum distance or angle limit." },
        .{ .name = "max_limit", .type = "f32", .description = "Maximum distance or angle limit." },
        .{ .name = "is_enabled", .type = "bool", .description = "Constraint enabled flag." },
    };
    const material_fields = [_]FieldSchema{
        .{ .name = "handle", .type = "asset_handle|null", .description = "Optional material asset handle." },
        .{ .name = "shading", .type = "ShadingModel", .description = "Shading model enum." },
        .{ .name = "base_color_factor", .type = "Vec4", .description = "RGBA base color multiplier." },
        .{ .name = "emissive_factor", .type = "Vec3", .description = "RGB emissive multiplier." },
        .{ .name = "metallic_factor", .type = "f32", .description = "Metalness factor." },
        .{ .name = "roughness_factor", .type = "f32", .description = "Roughness factor." },
        .{ .name = "alpha_cutoff", .type = "f32", .description = "Alpha cutoff threshold." },
        .{ .name = "double_sided", .type = "bool", .description = "Double-sided rendering flag." },
    };
    const light_fields = [_]FieldSchema{
        .{ .name = "kind", .type = "LightKind", .description = "Light type enum." },
        .{ .name = "color", .type = "Vec3", .description = "RGB light color." },
        .{ .name = "intensity", .type = "f32", .description = "Light intensity multiplier." },
        .{ .name = "range", .type = "f32", .description = "Point/spot light range." },
    };
    const vfx_fields = [_]FieldSchema{
        .{ .name = "kind", .type = "VfxKind", .description = "Built-in VFX preset enum." },
        .{ .name = "looping", .type = "bool", .description = "Loop playback flag." },
        .{ .name = "emission_rate", .type = "f32", .description = "Particles per second." },
        .{ .name = "particle_lifetime", .type = "f32", .description = "Lifetime in seconds." },
        .{ .name = "speed", .type = "f32", .description = "Initial particle speed." },
        .{ .name = "max_particles", .type = "u16", .description = "Maximum living particles." },
        .{ .name = "radius", .type = "f32", .description = "Spawn radius." },
        .{ .name = "spread", .type = "f32", .description = "Emission spread." },
        .{ .name = "size", .type = "f32", .description = "Particle size." },
        .{ .name = "color", .type = "Vec3", .description = "RGB particle color." },
    };
    const script_fields = [_]FieldSchema{
        .{ .name = "script_handle", .type = "asset_handle|null", .description = "Script resource handle." },
        .{ .name = "language", .type = "ScriptLanguage", .description = "Script language enum." },
        .{ .name = "instance_id", .type = "u64|null", .description = "Runtime script instance id." },
        .{ .name = "enabled", .type = "bool", .description = "Script enabled flag." },
        .{ .name = "parameters", .type = "string", .description = "Serialized script parameter payload." },
    };

    return stringifyAlloc(allocator, ContractSchema{
        .version = "1",
        .conventions = .{
            .vectors_are_arrays = true,
            .arrays_not_objects = true,
            .notes = &.{
                "Vec2, Vec3, Quat, and Vec4 values must be JSON arrays, not keyed objects.",
                "Optional handles and parent ids use null when absent.",
                "Enum fields must use the exact lowercase strings declared in this schema.",
            },
        },
        .shared_types = &.{
            .{ .name = "Vec2", .encoding = "array<f32,2>", .example = &vec2_example },
            .{ .name = "Vec3", .encoding = "array<f32,3>", .example = &vec3_example },
            .{ .name = "Quat", .encoding = "array<f32,4>", .example = &quat_example },
            .{ .name = "Vec4", .encoding = "array<f32,4>", .example = &color4_example },
            .{ .name = "Transform", .encoding = "{ translation: Vec3, rotation: Quat, scale: Vec3 }" },
            .{ .name = "CameraProjection", .encoding = "{ perspective: {...} } | { orthographic: {...} }" },
        },
        .enums = &.{
            .{ .name = "Primitive", .values = &primitive_values },
            .{ .name = "ShadingModel", .values = &shading_values },
            .{ .name = "LightKind", .values = &light_values },
            .{ .name = "VfxKind", .values = &vfx_values },
            .{ .name = "ScriptLanguage", .values = &script_language_values },
            .{ .name = "RigidbodyMotionType", .values = &rigidbody_motion_values },
            .{ .name = "ConstraintType", .values = &constraint_values },
        },
        .entity_fields = &entity_fields,
        .components = &.{
            .{ .name = "camera", .description = "Camera component payload.", .fields = &camera_fields },
            .{ .name = "mesh", .description = "Mesh component payload.", .fields = &mesh_fields },
            .{ .name = "skinned_mesh", .description = "Skinned mesh component payload.", .fields = &skinned_mesh_fields },
            .{ .name = "animator", .description = "Animator component payload.", .fields = &animator_fields },
            .{ .name = "rigidbody", .description = "Rigidbody component payload.", .fields = &rigidbody_fields },
            .{ .name = "box_collider", .description = "Box collider component payload.", .fields = &box_collider_fields },
            .{ .name = "sphere_collider", .description = "Sphere collider component payload.", .fields = &sphere_collider_fields },
            .{ .name = "mesh_collider", .description = "Mesh collider component payload.", .fields = &mesh_collider_fields },
            .{ .name = "constraint", .description = "Constraint component payload.", .fields = &constraint_fields },
            .{ .name = "material", .description = "Material component payload.", .fields = &material_fields },
            .{ .name = "light", .description = "Light component payload.", .fields = &light_fields },
            .{ .name = "vfx", .description = "VFX component payload.", .fields = &vfx_fields },
            .{ .name = "script", .description = "Script component payload.", .fields = &script_fields },
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
    var store = SnapshotStore.init(std.testing.allocator, null, null);
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
    try std.testing.expectEqual(@as(usize, 3), listed.len);
    try std.testing.expectEqualStrings("scene://hierarchy", listed[0].uri);
    try std.testing.expectEqualStrings("selection://current", listed[1].uri);
    try std.testing.expectEqualStrings("schema://components", listed[2].uri);

    const selection = (try store.readAlloc(std.testing.allocator, "selection://current")).?;
    defer freeTextResourceContents(std.testing.allocator, selection);
    try std.testing.expect(std.mem.indexOf(u8, selection.text, "\"primary\": 1") != null);

    const entity = (try store.readAlloc(std.testing.allocator, "entity://2")).?;
    defer freeTextResourceContents(std.testing.allocator, entity);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"name\": \"Child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"visible\": false") != null);
}

test "SnapshotStore exposes collaboration context and preview resources" {
    var collaboration = collaboration_mod.Store.init(std.testing.allocator);
    defer collaboration.deinit();

    var store = SnapshotStore.init(std.testing.allocator, &collaboration, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try store.replaceFromSelection(&world, null, &.{});
    try collaboration.updateContext(.{
        .selected_entities = &.{},
        .viewport_size = .{ 1920, 1080 },
        .camera_transform = .{},
        .camera_projection = .{},
    });

    const listed = try store.listAlloc(std.testing.allocator);
    defer freeResourceDescriptors(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 6), listed.len);
    try std.testing.expectEqualStrings("scene://hierarchy", listed[0].uri);
    try std.testing.expectEqualStrings("selection://current", listed[1].uri);
    try std.testing.expectEqualStrings("schema://components", listed[2].uri);
    try std.testing.expectEqualStrings("editor://context", listed[3].uri);
    try std.testing.expectEqualStrings("editor://intent-log", listed[4].uri);
    try std.testing.expectEqualStrings("preview://staged", listed[5].uri);

    const context = (try store.readAlloc(std.testing.allocator, "editor://context")).?;
    defer freeTextResourceContents(std.testing.allocator, context);
    try std.testing.expect(std.mem.indexOf(u8, context.text, "\"viewport\"") != null);

    const preview = (try store.readAlloc(std.testing.allocator, "preview://staged")).?;
    defer freeTextResourceContents(std.testing.allocator, preview);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "\"active\": false") != null);
}

test "resource templates advertise dynamic entity snapshots" {
    try std.testing.expectEqual(@as(usize, 1), resource_templates.len);
    try std.testing.expectEqualStrings("entity://{id}", resource_templates[0].uriTemplate);
    try std.testing.expectEqualStrings("application/json", resource_templates[0].mimeType.?);
}

test "SnapshotStore exposes schema resource for AI-facing component contracts" {
    var store = SnapshotStore.init(std.testing.allocator, null, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try store.replaceFromSelection(&world, null, &.{});

    const schema = (try store.readAlloc(std.testing.allocator, "schema://components")).?;
    defer freeTextResourceContents(std.testing.allocator, schema);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"vectors_are_arrays\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"name\": \"material\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"name\": \"ScriptLanguage\"") != null);
}
