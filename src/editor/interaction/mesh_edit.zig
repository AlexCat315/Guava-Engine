const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const state_mod = @import("../core/state.zig");
const history = @import("../actions/history.zig");
const camera = @import("camera.zig");
const manipulation = @import("manipulation.zig");

const EditorState = state_mod.EditorState;
pub const MeshElementSelectionMode = state_mod.MeshElementSelectionMode;

pub const Edge = struct {
    a: u32,
    b: u32,
};

pub const ActiveContext = struct {
    entity_id: engine.scene.EntityId,
    mesh_handle: engine.assets.MeshHandle,
    mesh: *const engine.assets.MeshResource,
    world_transform: engine.scene.Transform,
};

const EdgeEntry = struct {
    count: u32 = 0,
    directed_a: u32 = 0,
    directed_b: u32 = 0,
};

pub fn isEditModeActive(state: *const EditorState) bool {
    return state.mesh_edit_mode == .edit and state.mesh_edit_entity != null;
}

pub fn selectedElements(state: *const EditorState) []const u32 {
    return state.mesh_edit_selected_elements.items;
}

pub fn activeContext(state: *EditorState, layer_context: *engine.core.LayerContext) ?ActiveContext {
    if (!isEditModeActive(state)) {
        return null;
    }

    const entity_id = state.mesh_edit_entity orelse return null;
    const entity = layer_context.world.getEntityConst(entity_id) orelse return null;
    const mesh_component = entity.mesh orelse return null;
    const mesh_handle = mesh_component.handle orelse return null;
    const mesh = layer_context.world.assets().mesh(mesh_handle) orelse return null;
    const world_transform = layer_context.world.worldTransformConst(entity_id) orelse entity.local_transform;
    return .{
        .entity_id = entity_id,
        .mesh_handle = mesh_handle,
        .mesh = mesh,
        .world_transform = world_transform,
    };
}

pub fn canEnterEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) bool {
    _ = state;
    if (layer_context.renderer.selectedEntities().len != 1) {
        return false;
    }
    const entity_id = layer_context.renderer.selectedEntity() orelse return false;
    const entity = layer_context.world.getEntityConst(entity_id) orelse return false;
    if (entity.skinned_mesh != null) {
        return false;
    }
    const mesh_component = entity.mesh orelse return false;
    if (mesh_component.handle != null) {
        return true;
    }
    return mesh_component.primitive != .custom;
}

pub fn toggleEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (isEditModeActive(state)) {
        exitEditMode(state, layer_context);
        return true;
    }
    return enterEditMode(state, layer_context);
}

pub fn enterEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (!canEnterEditMode(state, layer_context)) {
        return false;
    }

    const entity_id = layer_context.renderer.selectedEntity() orelse return false;
    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const mesh_handle = try ensureEditableMeshResource(state, layer_context, entity) orelse return false;
    if (layer_context.world.assets().mesh(mesh_handle) == null) {
        return false;
    }

    state.mesh_edit_mode = .edit;
    state.mesh_edit_entity = entity_id;
    state.mesh_edit_selection_mode = .face;
    clearElementSelection(state);
    manipulation.clearTransformTool(state);
    manipulation.refreshGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
    return true;
}

pub fn exitEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    clearElementSelection(state);
    state.mesh_edit_mode = .object;
    state.mesh_edit_entity = null;
    manipulation.refreshGizmoState(state, layer_context);
}

pub fn setSelectionMode(state: *EditorState, mode: MeshElementSelectionMode) void {
    if (state.mesh_edit_selection_mode == mode) {
        return;
    }
    state.mesh_edit_selection_mode = mode;
    clearElementSelection(state);
}

pub fn syncSession(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!isEditModeActive(state)) {
        return;
    }

    const entity_id = state.mesh_edit_entity orelse {
        exitEditMode(state, layer_context);
        return;
    };

    if (layer_context.renderer.selectedEntities().len != 1 or layer_context.renderer.selectedEntity() != entity_id) {
        exitEditMode(state, layer_context);
        return;
    }

    const entity = layer_context.world.getEntityConst(entity_id) orelse {
        exitEditMode(state, layer_context);
        return;
    };
    if (entity.skinned_mesh != null or entity.mesh == null) {
        exitEditMode(state, layer_context);
        return;
    }
    if ((entity.mesh.?.handle == null and entity.mesh.?.primitive == .custom) or activeContext(state, layer_context) == null) {
        exitEditMode(state, layer_context);
        return;
    }

    try pruneSelectionToCurrentMesh(state, layer_context);
}

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const input = layer_context.input;
    if (gui.wantsTextInput()) {
        return false;
    }

    if (input.wasKeyPressed(.tab) and !input.modifiers.shift and !input.modifiers.ctrl and !input.modifiers.alt) {
        if (isEditModeActive(state) or canEnterEditMode(state, layer_context)) {
            _ = try toggleEditMode(state, layer_context);
            return true;
        }
    }

    if (!isEditModeActive(state)) {
        return false;
    }

    if (input.modifiers.shift and input.wasKeyPressed(.tab)) {
        camera.toggleCameraMode(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.f)) {
        camera.focusSelection(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.one)) {
        setSelectionMode(state, .vertex);
        return true;
    }
    if (input.wasKeyPressed(.two)) {
        setSelectionMode(state, .edge);
        return true;
    }
    if (input.wasKeyPressed(.three)) {
        setSelectionMode(state, .face);
        return true;
    }
    if (input.wasKeyPressed(.delete) or input.wasKeyPressed(.backspace)) {
        _ = try deleteSelectedElements(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.e)) {
        _ = try extrudeSelectedFaces(state, layer_context);
        return true;
    }
    return false;
}

pub fn handleViewportSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    update_mode: engine.render.SelectionUpdateMode,
) !bool {
    if (!isEditModeActive(state)) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse {
        exitEditMode(state, layer_context);
        return true;
    };

    switch (state.mesh_edit_selection_mode) {
        .vertex => {
            const picked = pickVertexIndexOnScreen(state, layer_context, context);
            try applyPickedSelection(state, layer_context, update_mode, if (picked) |index| &[_]u32{index} else &.{});
        },
        .edge => {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const picked = try pickEdgeIndexOnScreen(allocator, state, layer_context, context);
            try applyPickedSelection(state, layer_context, update_mode, if (picked) |index| &[_]u32{index} else &.{});
        },
        .face => {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const picked_group = try pickFaceGroup(allocator, context, ray);
            defer if (picked_group) |group| allocator.free(group);
            try applyPickedSelection(state, layer_context, update_mode, if (picked_group) |group| group else &.{});
        },
    }

    return true;
}

pub fn buildEdgeList(allocator: std.mem.Allocator, mesh: *const engine.assets.MeshResource) ![]Edge {
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < mesh.indices.len) : (triangle_offset += 3) {
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset], mesh.indices[triangle_offset + 1]);
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset + 1], mesh.indices[triangle_offset + 2]);
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset + 2], mesh.indices[triangle_offset]);
    }

    return try edges.toOwnedSlice(allocator);
}

pub fn deleteSelectedElements(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    if (state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    var triangle_remove = try allocator.alloc(bool, context.mesh.indices.len / 3);
    defer allocator.free(triangle_remove);
    @memset(triangle_remove, false);

    switch (state.mesh_edit_selection_mode) {
        .face => {
            for (state.mesh_edit_selected_elements.items) |face_index| {
                if (face_index < triangle_remove.len) {
                    triangle_remove[face_index] = true;
                }
            }
        },
        .vertex => {
            for (state.mesh_edit_selected_elements.items) |vertex_index| {
                var face_index: usize = 0;
                while (face_index < triangle_remove.len) : (face_index += 1) {
                    const triangle_offset = face_index * 3;
                    if (context.mesh.indices[triangle_offset] == vertex_index or
                        context.mesh.indices[triangle_offset + 1] == vertex_index or
                        context.mesh.indices[triangle_offset + 2] == vertex_index)
                    {
                        triangle_remove[face_index] = true;
                    }
                }
            }
        },
        .edge => {
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (state.mesh_edit_selected_elements.items) |edge_index| {
                if (edge_index >= edges.len) {
                    continue;
                }
                const edge = edges[edge_index];
                var face_index: usize = 0;
                while (face_index < triangle_remove.len) : (face_index += 1) {
                    const triangle_offset = face_index * 3;
                    if (triangleContainsEdge(
                        context.mesh.indices[triangle_offset],
                        context.mesh.indices[triangle_offset + 1],
                        context.mesh.indices[triangle_offset + 2],
                        edge.a,
                        edge.b,
                    )) {
                        triangle_remove[face_index] = true;
                    }
                }
            }
        },
    }

    const next_indices = try filteredIndicesWithoutTriangles(allocator, context.mesh.indices, triangle_remove);
    defer allocator.free(next_indices);
    const rebuilt = try compactMeshData(allocator, context.mesh.vertices, next_indices);
    defer allocator.free(rebuilt.vertices);
    defer allocator.free(rebuilt.indices);

    try applyMeshMutation(state, layer_context, context.mesh_handle, rebuilt.vertices, rebuilt.indices);
    clearElementSelection(state);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_delete_action),
        state.text(.mesh_edit_delete_action),
        .human,
    );
    return true;
}

pub fn extrudeSelectedFaces(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .face or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const result = try extrudeFaceRegion(
        allocator,
        context.mesh.vertices,
        context.mesh.indices,
        state.mesh_edit_selected_elements.items,
    );
    defer allocator.free(result.vertices);
    defer allocator.free(result.indices);
    defer allocator.free(result.selected_faces);

    try applyMeshMutation(state, layer_context, context.mesh_handle, result.vertices, result.indices);
    clearElementSelection(state);
    try state.mesh_edit_selected_elements.appendSlice(allocator, result.selected_faces);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_extrude_action),
        state.text(.mesh_edit_extrude_action),
        .human,
    );
    return true;
}

fn clearElementSelection(state: *EditorState) void {
    state.mesh_edit_selected_elements.clearRetainingCapacity();
}

fn pruneSelectionToCurrentMesh(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const context = activeContext(state, layer_context) orelse {
        clearElementSelection(state);
        return;
    };

    const max_index: usize = switch (state.mesh_edit_selection_mode) {
        .vertex => context.mesh.vertices.len,
        .face => context.mesh.indices.len / 3,
        .edge => blk: {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            break :blk edges.len;
        },
    };

    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < state.mesh_edit_selected_elements.items.len) : (read_index += 1) {
        const candidate = state.mesh_edit_selected_elements.items[read_index];
        if (candidate >= max_index) {
            continue;
        }
        state.mesh_edit_selected_elements.items[write_index] = candidate;
        write_index += 1;
    }
    state.mesh_edit_selected_elements.items.len = write_index;
}

fn applyPickedSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    update_mode: engine.render.SelectionUpdateMode,
    picked_elements: []const u32,
) !void {
    _ = layer_context;
    const allocator = state.allocator orelse return;
    switch (update_mode) {
        .replace => {
            clearElementSelection(state);
            try state.mesh_edit_selected_elements.appendSlice(allocator, picked_elements);
        },
        .toggle => {
            for (picked_elements) |element_index| {
                if (indexOfSelectedElement(state, element_index)) |selected_index| {
                    _ = state.mesh_edit_selected_elements.orderedRemove(selected_index);
                } else {
                    try state.mesh_edit_selected_elements.append(allocator, element_index);
                }
            }
        },
    }
}

fn indexOfSelectedElement(state: *const EditorState, element_index: u32) ?usize {
    for (state.mesh_edit_selected_elements.items, 0..) |selected, index| {
        if (selected == element_index) {
            return index;
        }
    }
    return null;
}

fn pickVertexIndexOnScreen(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    context: ActiveContext,
) ?u32 {
    const mouse = layer_context.input.mouse_position;
    var best_distance = std.math.inf(f32);
    var best_index: ?u32 = null;

    for (context.mesh.vertices, 0..) |vertex, index| {
        const world_position = transformPoint(context.world_transform, vertex.position);
        const screen = projectWorldPointToViewport(state, layer_context, world_position) orelse continue;
        const distance = distance2d(mouse, screen);
        if (distance <= 12.0 and distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index);
        }
    }
    return best_index;
}

fn pickEdgeIndexOnScreen(
    allocator: std.mem.Allocator,
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    context: ActiveContext,
) !?u32 {
    const edges = try buildEdgeList(allocator, context.mesh);
    defer allocator.free(edges);

    const mouse = layer_context.input.mouse_position;
    var best_distance = std.math.inf(f32);
    var best_index: ?u32 = null;

    for (edges, 0..) |edge, index| {
        const a_world = transformPoint(context.world_transform, context.mesh.vertices[edge.a].position);
        const b_world = transformPoint(context.world_transform, context.mesh.vertices[edge.b].position);
        const a_screen = projectWorldPointToViewport(state, layer_context, a_world) orelse continue;
        const b_screen = projectWorldPointToViewport(state, layer_context, b_world) orelse continue;
        const distance = distancePointToSegment2d(mouse, a_screen, b_screen);
        if (distance <= 10.0 and distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index);
        }
    }

    return best_index;
}

fn pickFaceGroup(
    allocator: std.mem.Allocator,
    context: ActiveContext,
    ray: engine.scene.Ray,
) !?[]u32 {
    if (context.mesh.indices.len < 3) {
        return null;
    }

    var best_face_index: ?u32 = null;
    var best_distance = std.math.inf(f32);

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < context.mesh.indices.len) : (triangle_offset += 3) {
        const v0 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset]].position);
        const v1 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 1]].position);
        const v2 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 2]].position);
        const hit = rayTriangleIntersection(ray.origin, ray.direction, v0, v1, v2) orelse continue;
        if (hit.distance < best_distance) {
            best_distance = hit.distance;
            best_face_index = @intCast(triangle_offset / 3);
        }
    }

    const seed_face = best_face_index orelse return null;
    return try collectCoplanarFaceGroup(allocator, context.mesh, seed_face);
}

fn collectCoplanarFaceGroup(
    allocator: std.mem.Allocator,
    mesh: *const engine.assets.MeshResource,
    seed_face: u32,
) ![]u32 {
    const face_count = mesh.indices.len / 3;
    var visited = try allocator.alloc(bool, face_count);
    defer allocator.free(visited);
    @memset(visited, false);

    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(allocator);
    var group = std.ArrayList(u32).empty;
    defer group.deinit(allocator);

    const seed_normal = faceNormal(mesh, seed_face);
    const seed_point = mesh.vertices[mesh.indices[@as(usize, seed_face) * 3]].position;

    try queue.append(allocator, seed_face);
    visited[seed_face] = true;

    while (queue.items.len > 0) {
        const face_index = queue.pop().?;
        try group.append(allocator, face_index);

        var candidate: usize = 0;
        while (candidate < face_count) : (candidate += 1) {
            if (visited[candidate]) {
                continue;
            }
            if (!trianglesShareEdge(mesh, face_index, @intCast(candidate))) {
                continue;
            }
            const candidate_normal = faceNormal(mesh, @intCast(candidate));
            if (dot3(seed_normal, candidate_normal) < 0.999) {
                continue;
            }
            if (!triangleIsCoplanar(mesh, @intCast(candidate), seed_normal, seed_point)) {
                continue;
            }
            visited[candidate] = true;
            try queue.append(allocator, @intCast(candidate));
        }
    }

    return try group.toOwnedSlice(allocator);
}

fn triangleIsCoplanar(
    mesh: *const engine.assets.MeshResource,
    face_index: u32,
    plane_normal: [3]f32,
    plane_point: [3]f32,
) bool {
    const triangle_offset = @as(usize, face_index) * 3;
    const epsilon: f32 = 0.0005;
    return @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset]].position, plane_point), plane_normal)) <= epsilon and
        @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset + 1]].position, plane_point), plane_normal)) <= epsilon and
        @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset + 2]].position, plane_point), plane_normal)) <= epsilon;
}

fn trianglesShareEdge(mesh: *const engine.assets.MeshResource, lhs_face: u32, rhs_face: u32) bool {
    const lhs_offset = @as(usize, lhs_face) * 3;
    const rhs_offset = @as(usize, rhs_face) * 3;
    const lhs = [3]u32{
        mesh.indices[lhs_offset],
        mesh.indices[lhs_offset + 1],
        mesh.indices[lhs_offset + 2],
    };
    const rhs = [3]u32{
        mesh.indices[rhs_offset],
        mesh.indices[rhs_offset + 1],
        mesh.indices[rhs_offset + 2],
    };

    var shared: u32 = 0;
    for (lhs) |lhs_vertex| {
        for (rhs) |rhs_vertex| {
            if (lhs_vertex == rhs_vertex) {
                shared += 1;
                break;
            }
        }
    }
    return shared >= 2;
}

fn faceNormal(mesh: *const engine.assets.MeshResource, face_index: u32) [3]f32 {
    const triangle_offset = @as(usize, face_index) * 3;
    const v0 = mesh.vertices[mesh.indices[triangle_offset]].position;
    const v1 = mesh.vertices[mesh.indices[triangle_offset + 1]].position;
    const v2 = mesh.vertices[mesh.indices[triangle_offset + 2]].position;
    return normalize3(cross3(sub3(v1, v0), sub3(v2, v0)));
}

const CompactedMeshData = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
};

fn filteredIndicesWithoutTriangles(
    allocator: std.mem.Allocator,
    indices: []const u32,
    triangle_remove: []const bool,
) ![]u32 {
    var kept_indices = std.ArrayList(u32).empty;
    defer kept_indices.deinit(allocator);

    var face_index: usize = 0;
    while (face_index < triangle_remove.len) : (face_index += 1) {
        if (triangle_remove[face_index]) {
            continue;
        }
        const triangle_offset = face_index * 3;
        try kept_indices.appendSlice(allocator, indices[triangle_offset .. triangle_offset + 3]);
    }

    return try kept_indices.toOwnedSlice(allocator);
}

fn compactMeshData(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
) !CompactedMeshData {
    var used = try allocator.alloc(bool, vertices.len);
    defer allocator.free(used);
    @memset(used, false);

    for (indices) |index| {
        if (index < used.len) {
            used[index] = true;
        }
    }

    var remap = try allocator.alloc(u32, vertices.len);
    defer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));

    var compacted_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    errdefer compacted_vertices.deinit(allocator);
    for (vertices, 0..) |vertex, index| {
        if (!used[index]) {
            continue;
        }
        remap[index] = @intCast(compacted_vertices.items.len);
        try compacted_vertices.append(allocator, vertex);
    }

    const compacted_indices = try allocator.alloc(u32, indices.len);
    errdefer allocator.free(compacted_indices);
    for (indices, 0..) |index, dst_index| {
        compacted_indices[dst_index] = remap[index];
    }

    recalculateVertexNormals(compacted_vertices.items, compacted_indices);

    return .{
        .vertices = try compacted_vertices.toOwnedSlice(allocator),
        .indices = compacted_indices,
    };
}

const ExtrudeResult = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
    selected_faces: []u32,
};

fn extrudeFaceRegion(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
    selected_faces: []const u32,
) !ExtrudeResult {
    var selected_face_mask = try allocator.alloc(bool, indices.len / 3);
    defer allocator.free(selected_face_mask);
    @memset(selected_face_mask, false);
    for (selected_faces) |face_index| {
        if (face_index < selected_face_mask.len) {
            selected_face_mask[face_index] = true;
        }
    }

    var average_normal = [3]f32{ 0.0, 0.0, 0.0 };
    for (selected_faces) |face_index| {
        average_normal = add3(average_normal, faceNormalFromRaw(vertices, indices, face_index));
    }
    average_normal = normalize3(average_normal);
    if (length3(average_normal) <= 0.0001) {
        average_normal = .{ 0.0, 1.0, 0.0 };
    }

    var used_vertices = std.AutoHashMap(u32, u32).init(allocator);
    defer used_vertices.deinit();
    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, vertices);

    for (selected_faces) |_| {}
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        var local_vertex: usize = 0;
        while (local_vertex < 3) : (local_vertex += 1) {
            const vertex_index = indices[triangle_offset + local_vertex];
            const gop = try used_vertices.getOrPut(vertex_index);
            if (gop.found_existing) {
                continue;
            }

            var extruded_vertex = vertices[vertex_index];
            extruded_vertex.position = add3(extruded_vertex.position, scale3(average_normal, 0.5));
            gop.value_ptr.* = @intCast(next_vertices.items.len);
            try next_vertices.append(allocator, extruded_vertex);
        }
    }

    var edge_entries = std.AutoHashMap(u64, EdgeEntry).init(allocator);
    defer edge_entries.deinit();
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        try recordDirectedEdge(&edge_entries, indices[triangle_offset], indices[triangle_offset + 1]);
        try recordDirectedEdge(&edge_entries, indices[triangle_offset + 1], indices[triangle_offset + 2]);
        try recordDirectedEdge(&edge_entries, indices[triangle_offset + 2], indices[triangle_offset]);
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);
    try next_indices.appendSlice(allocator, indices);

    const top_face_start: u32 = @intCast(next_indices.items.len / 3);
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset]).?);
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset + 1]).?);
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset + 2]).?);
    }

    var boundary_iterator = edge_entries.iterator();
    while (boundary_iterator.next()) |entry| {
        if (entry.value_ptr.count != 1) {
            continue;
        }
        const a = entry.value_ptr.directed_a;
        const b = entry.value_ptr.directed_b;
        const a_top = used_vertices.get(a).?;
        const b_top = used_vertices.get(b).?;
        try next_indices.appendSlice(allocator, &[_]u32{
            a,
            b,
            b_top,
            a,
            b_top,
            a_top,
        });
    }

    recalculateVertexNormals(next_vertices.items, next_indices.items);

    const next_selected_faces = try allocator.alloc(u32, selected_faces.len);
    for (selected_faces, 0..) |_, index| {
        next_selected_faces[index] = top_face_start + @as(u32, @intCast(index));
    }

    return .{
        .vertices = try next_vertices.toOwnedSlice(allocator),
        .indices = try allocator.dupe(u32, next_indices.items),
        .selected_faces = next_selected_faces,
    };
}

fn recordDirectedEdge(entries: *std.AutoHashMap(u64, EdgeEntry), a: u32, b: u32) !void {
    const edge_min = @min(a, b);
    const edge_max = @max(a, b);
    const key = (@as(u64, edge_min) << 32) | @as(u64, edge_max);
    const gop = try entries.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .count = 1,
            .directed_a = a,
            .directed_b = b,
        };
        return;
    }
    gop.value_ptr.count += 1;
}

fn applyMeshMutation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    handle: engine.assets.MeshHandle,
    next_vertices: []const engine.assets.MeshVertex,
    next_indices: []const u32,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const mesh = layer_context.world.assets().meshMutable(handle) orelse return error.MeshNotFound;

    allocator.free(mesh.vertices);
    allocator.free(mesh.indices);
    mesh.vertices = try allocator.dupe(engine.assets.MeshVertex, next_vertices);
    mesh.indices = try allocator.dupe(u32, next_indices);
    mesh.local_bounds = engine.assets.computeMeshLocalBounds(mesh.vertices);

    layer_context.renderer.invalidateMainWorldMeshResource(handle);
    layer_context.world.noteMeshResourceChanged(handle);
    layer_context.world.updateHierarchy();
}

fn ensureEditableMeshResource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !?engine.assets.MeshHandle {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const mesh_component = if (entity.mesh) |*mesh| mesh else return null;

    if (mesh_component.handle == null and mesh_component.primitive != .custom) {
        mesh_component.handle = try layer_context.world.assets().ensurePrimitiveMesh(mesh_component.primitive);
    }
    const mesh_handle = mesh_component.handle orelse return null;

    if (meshUsageCount(layer_context.world, mesh_handle) <= 1 and !meshHandleRequiresEditableInstance(layer_context.world, mesh_handle)) {
        return mesh_handle;
    }

    const source = layer_context.world.assets().mesh(mesh_handle) orelse return null;
    const instance_name = try std.fmt.allocPrint(allocator, "{s} Mesh", .{entity.name});
    defer allocator.free(instance_name);

    const new_handle = try layer_context.world.assets().createMesh(.{
        .name = instance_name,
        .vertices = source.vertices,
        .indices = source.indices,
        .primitive_type = source.primitive_type,
    });
    mesh_component.handle = new_handle;
    mesh_component.primitive = .custom;
    layer_context.world.noteEntityRenderableChanged(entity.id);
    layer_context.world.updateHierarchy();
    return new_handle;
}

fn meshHandleRequiresEditableInstance(world: *engine.scene.World, handle: engine.assets.MeshHandle) bool {
    const asset_id = world.assets().meshAssetId(handle) orelse return false;
    const record = world.assets().assetRecordById(asset_id) orelse return true;
    return !std.mem.startsWith(u8, record.source_path, "scene://embedded/");
}

fn meshUsageCount(world: *const engine.scene.World, handle: engine.assets.MeshHandle) usize {
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.mesh) |mesh_component| {
            if (mesh_component.handle == handle) {
                count += 1;
            }
        }
        if (entity.skinned_mesh) |skinned_mesh_component| {
            if (skinned_mesh_component.mesh_handle == handle) {
                count += 1;
            }
        }
    }
    return count;
}

fn appendUniqueEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    seen: *std.AutoHashMap(u64, void),
    a: u32,
    b: u32,
) !void {
    const edge_min = @min(a, b);
    const edge_max = @max(a, b);
    const key = (@as(u64, edge_min) << 32) | @as(u64, edge_max);
    const gop = try seen.getOrPut(key);
    if (gop.found_existing) {
        return;
    }
    try edges.append(allocator, .{ .a = a, .b = b });
}

fn triangleContainsEdge(a: u32, b: u32, c: u32, edge_a: u32, edge_b: u32) bool {
    return (a == edge_a or b == edge_a or c == edge_a) and
        (a == edge_b or b == edge_b or c == edge_b);
}

fn recalculateVertexNormals(vertices: []engine.assets.MeshVertex, indices: []const u32) void {
    for (vertices) |*vertex| {
        vertex.normal = .{ 0.0, 0.0, 0.0 };
    }

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < indices.len) : (triangle_offset += 3) {
        const a = indices[triangle_offset];
        const b = indices[triangle_offset + 1];
        const c = indices[triangle_offset + 2];
        const face_normal = normalize3(cross3(
            sub3(vertices[b].position, vertices[a].position),
            sub3(vertices[c].position, vertices[a].position),
        ));
        vertices[a].normal = add3(vertices[a].normal, face_normal);
        vertices[b].normal = add3(vertices[b].normal, face_normal);
        vertices[c].normal = add3(vertices[c].normal, face_normal);
    }

    for (vertices) |*vertex| {
        if (length3(vertex.normal) <= 0.0001) {
            vertex.normal = .{ 0.0, 1.0, 0.0 };
        } else {
            vertex.normal = normalize3(vertex.normal);
        }
        if (vertex.tangent[0] == 0.0 and vertex.tangent[1] == 0.0 and vertex.tangent[2] == 0.0) {
            vertex.tangent = .{ 1.0, 0.0, 0.0, 1.0 };
        }
    }
}

fn rayTriangleIntersection(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?struct { distance: f32 } {
    const epsilon: f32 = 0.00001;
    const edge1 = sub3(v1, v0);
    const edge2 = sub3(v2, v0);
    const pvec = cross3(ray_direction, edge2);
    const determinant = dot3(edge1, pvec);
    if (@abs(determinant) <= epsilon) {
        return null;
    }

    const inverse_determinant = 1.0 / determinant;
    const tvec = sub3(ray_origin, v0);
    const u = dot3(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) {
        return null;
    }

    const qvec = cross3(tvec, edge1);
    const v = dot3(ray_direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) {
        return null;
    }

    const distance = dot3(edge2, qvec) * inverse_determinant;
    if (distance <= epsilon) {
        return null;
    }
    return .{ .distance = distance };
}

fn projectWorldPointToViewport(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world_position: [3]f32,
) ?[2]f32 {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0 or state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return null;
    }

    const view = camera.activeCameraViewMatrix(state, layer_context);
    const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));
    const projection = engine.math.mat4.projectionForCamera(camera.activeCameraComponent(state, layer_context), aspect);
    const view_projection = engine.math.mat4.mul(projection, view);
    const clip = transformPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
    if (@abs(clip[3]) <= 0.00001 or clip[3] <= 0.0) {
        return null;
    }

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    if (ndc_x < -1.15 or ndc_x > 1.15 or ndc_y < -1.15 or ndc_y > 1.15) {
        return null;
    }

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn transformPoint(transform: engine.scene.Transform, point: [3]f32) [3]f32 {
    return add3(
        transform.translation,
        engine.math.quat.rotateVec3(transform.rotation, mul3(transform.scale, point)),
    );
}

fn transformPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
}

fn distancePointToSegment2d(point: [2]f32, segment_a: [2]f32, segment_b: [2]f32) f32 {
    const ab = .{ segment_b[0] - segment_a[0], segment_b[1] - segment_a[1] };
    const ap = .{ point[0] - segment_a[0], point[1] - segment_a[1] };
    const ab_len_sq = ab[0] * ab[0] + ab[1] * ab[1];
    if (ab_len_sq <= 0.00001) {
        return distance2d(point, segment_a);
    }

    const t = std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / ab_len_sq, 0.0, 1.0);
    const projected = .{ segment_a[0] + ab[0] * t, segment_a[1] + ab[1] * t };
    return distance2d(point, projected);
}

fn distance2d(a: [2]f32, b: [2]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return @sqrt(dx * dx + dy * dy);
}

fn faceNormalFromRaw(vertices: []const engine.assets.MeshVertex, indices: []const u32, face_index: u32) [3]f32 {
    const triangle_offset = @as(usize, face_index) * 3;
    const a = indices[triangle_offset];
    const b = indices[triangle_offset + 1];
    const c = indices[triangle_offset + 2];
    return normalize3(cross3(sub3(vertices[b].position, vertices[a].position), sub3(vertices[c].position, vertices[a].position)));
}

fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mul3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

fn scale3(v: [3]f32, scalar: f32) [3]f32 {
    return .{ v[0] * scalar, v[1] * scalar, v[2] * scalar };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn length3(v: [3]f32) f32 {
    return @sqrt(dot3(v, v));
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = length3(v);
    if (len <= 0.00001) {
        return .{ 0.0, 0.0, 0.0 };
    }
    return scale3(v, 1.0 / len);
}
