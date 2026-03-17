const std = @import("std");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

pub const RenderCamera = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    camera: components.Camera,
};

pub const RenderLight = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    light: components.Light,
};

pub const RenderLightArray = struct {
    directional: std.ArrayList(RenderLight),
    point: std.ArrayList(RenderLight),
    spot: std.ArrayList(RenderLight),

    pub fn init(allocator: std.mem.Allocator) RenderLightArray {
        return .{
            .directional = std.ArrayList(RenderLight).init(allocator),
            .point = std.ArrayList(RenderLight).init(allocator),
            .spot = std.ArrayList(RenderLight).init(allocator),
        };
    }

    pub fn deinit(self: *RenderLightArray) void {
        self.directional.deinit();
        self.point.deinit();
        self.spot.deinit();
    }

    pub fn clear(self: *RenderLightArray) void {
        self.directional.clearRetainingCapacity();
        self.point.clearRetainingCapacity();
        self.spot.clearRetainingCapacity();
    }

    pub fn add(self: *RenderLightArray, render_light: RenderLight) !void {
        const kind = render_light.light.kind;
        if (kind == .directional) {
            try self.directional.append(render_light);
        } else if (kind == .point) {
            try self.point.append(render_light);
        } else if (kind == .spot) {
            try self.spot.append(render_light);
        }
    }

    pub fn len(self: *const RenderLightArray) usize {
        return self.directional.items.len + self.point.items.len + self.spot.items.len;
    }
};

pub const AlphaMode = enum {
    opaque,
    masked,
    transparent,
};

pub const RenderMesh = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    mesh: components.Mesh,
    material: ?components.Material,
    selected: bool = false,
    alpha_mode: AlphaMode = .opaque,
};

pub const RenderVfx = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    vfx: components.Vfx,
    selected: bool = false,
};

pub const RenderEntity = struct {
    id: scene_mod.EntityId,
    parent: ?scene_mod.EntityId,
    world_transform: components.Transform,
};

pub const RenderScene = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(RenderEntity),
    cameras: std.ArrayList(RenderCamera),
    lights: RenderLightArray,
    meshes: std.ArrayList(RenderMesh),
    vfxs: std.ArrayList(RenderVfx),

    pub fn init(allocator: std.mem.Allocator) RenderScene {
        return .{
            .allocator = allocator,
            .entities = std.ArrayList(RenderEntity).init(allocator),
            .cameras = std.ArrayList(RenderCamera).init(allocator),
            .lights = RenderLightArray.init(allocator),
            .meshes = std.ArrayList(RenderMesh).init(allocator),
            .vfxs = std.ArrayList(RenderVfx).init(allocator),
        };
    }

    pub fn deinit(self: *RenderScene) void {
        self.entities.deinit();
        self.cameras.deinit();
        self.lights.deinit();
        self.meshes.deinit();
        self.vfxs.deinit();
    }

    pub fn clear(self: *RenderScene) void {
        self.entities.clearRetainingCapacity();
        self.cameras.clearRetainingCapacity();
        self.lights.clear();
        self.meshes.clearRetainingCapacity();
        self.vfxs.clearRetainingCapacity();
    }
};

pub fn extractScene(
    scene: *const scene_mod.Scene,
    render_scene: *RenderScene,
    primary_selection: ?scene_mod.EntityId,
    selection_list: []const scene_mod.EntityId,
) !void {
    render_scene.clear();

    for (scene.entities.items) |entity| {
        const world_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;

        try render_scene.entities.append(.{
            .id = entity.id,
            .parent = entity.parent,
            .world_transform = world_transform,
        });

        if (!entity.visible) {
            continue;
        }

        const is_selected = isEntitySelected(entity.id, primary_selection, selection_list);

        if (entity.camera) |camera| {
            try render_scene.cameras.append(.{
                .entity_id = entity.id,
                .transform = world_transform,
                .camera = camera,
            });
        }

        if (entity.light) |light| {
            try render_scene.lights.add(.{
                .entity_id = entity.id,
                .transform = world_transform,
                .light = light,
            });
        }

        if (entity.mesh) |mesh| {
            const alpha_mode = determineAlphaMode(entity.material);
            try render_scene.meshes.append(.{
                .entity_id = entity.id,
                .transform = world_transform,
                .mesh = mesh,
                .material = entity.material,
                .selected = is_selected,
                .alpha_mode = alpha_mode,
            });
        }

        if (entity.vfx) |vfx| {
            try render_scene.vfxs.append(.{
                .entity_id = entity.id,
                .transform = world_transform,
                .vfx = vfx,
                .selected = is_selected,
            });
        }
    }
}

fn isEntitySelected(
    id: scene_mod.EntityId,
    primary_selection: ?scene_mod.EntityId,
    selection_list: []const scene_mod.EntityId,
) bool {
    if (primary_selection != null and primary_selection.? == id) {
        return true;
    }
    for (selection_list) |selected_id| {
        if (selected_id == id) {
            return true;
        }
    }
    return false;
}

fn determineAlphaMode(material: ?components.Material) AlphaMode {
    const material_value = material orelse return .opaque;
    const factor = material_value.base_color_factor;
    if (factor[3] < 1.0) {
        return .transparent;
    }
    return .opaque;
}
