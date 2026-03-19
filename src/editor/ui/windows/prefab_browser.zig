const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const utils = @import("../../common/utils.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");

/// Prefab 浏览器窗口
pub fn drawPrefabBrowserWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .prefab_browser, "prefab_browser_popup");
    var open = state.prefab_browser_open;
    _ = engine.ui.ImGui.beginWindowFlagsOpen(title, &open, engine.ui.ImGui.WindowFlags.no_docking);
    state.prefab_browser_open = open;
    defer engine.ui.ImGui.endWindow();

    if (!open) {
        return;
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    // 搜索框
    var search_buffer: [256]u8 = undefined;
    _ = engine.ui.ImGui.inputText("##search", &search_buffer, engine.ui.ImGui.InputTextFlagschars_no_blank);

    engine.ui.ImGui.separator();

    // 获取所有 Prefab
    const prefab_count = layer_context.world.prefab_library.count();
    if (prefab_count == 0) {
        engine.ui.ImGui.text(state.text(.no_prefabs));
        engine.ui.ImGui.separator();

        // 创建新 Prefab 按钮
        if (engine.ui.ImGui.button(state.text(.create_prefab), .{})) {
            // TODO: 打开创建 Prefab 对话框
        }
        return;
    }

    // Prefab 列表
    if (engine.ui.ImGui.beginChild("prefab_list", .{
        .height = engine.ui.ImGui.contentRegionAvail()[1] * 0.6,
    })) {
        defer engine.ui.ImGui.endChild();

        var it = layer_context.world.prefab_library.prefab_by_id.iterator();
        while (it.next()) |entry| {
            const prefab_id = entry.key_ptr.*;
            const index = entry.value_ptr.*;

            // 检查是否被选中
            const is_selected = state.selected_prefab_id != null and
                std.mem.eql(u8, state.selected_prefab_id.?, prefab_id);

            const prefab = &layer_context.world.prefab_library.prefabs.items[index];

            // 显示 Prefab 行
            if (engine.ui.ImGui.selectable(
                prefab.name[0..],
                is_selected,
                .{},
            )) {
                state.selected_prefab_id = prefab_id;
            }

            // 右键上下文菜单
            if (engine.ui.ImGui.beginPopupContextItem("prefab_context", .{})) {
                defer engine.ui.ImGui.endPopupContextItem();

                if (engine.ui.ImGui.menuItem(state.text(.instantiate_prefab), null, false, true)) {
                    _ = try layer_context.world.instantiatePrefab(prefab_id, .{
                        .name_prefix = "Instance",
                        .transform = .{
                            .translation = .{ 0.0, 0.0, 0.0 },
                            .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
                            .scale = .{ 1.0, 1.0, 1.0 },
                        },
                    });
                }

                if (engine.ui.ImGui.menuItem(state.text(.save_prefab), null, false, true)) {
                    // TODO: 保存 Prefab
                }

                engine.ui.ImGui.separator();

                if (engine.ui.ImGui.menuItem(state.text(.delete_prefab), null, false, true)) {
                    // TODO: 删除 Prefab 确认对话框
                }
            }
        }
    }

    engine.ui.ImGui.separator();

    // 选中 Prefab 的操作按钮
    if (state.selected_prefab_id) |selected_id| {
        engine.ui.ImGui.text(state.text(.selected_prefab));
        engine.ui.ImGui.sameLine();
        engine.ui.ImGui.text(selected_id);

        engine.ui.ImGui.separator();

        // 实例化按钮
        if (engine.ui.ImGui.button(state.text(.instantiate), .{})) {
            _ = try layer_context.world.instantiatePrefab(selected_id, .{
                .name_prefix = "Instance",
                .transform = .{
                    .translation = .{ 0.0, 0.0, 0.0 },
                    .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
                    .scale = .{ 1.0, 1.0, 1.0 },
                },
            });
        }

        engine.ui.ImGui.sameLine();

        // 编辑按钮
        if (engine.ui.ImGui.button(state.text(.edit_prefab), .{})) {
            state.editing_prefab_id = selected_id;
        }

        // 保存按钮
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button(state.text(.save_prefab), .{})) {
            // TODO: 保存到文件
        }
    }

    // 底部操作栏
    engine.ui.ImGui.separator();
    if (engine.ui.ImGui.button(state.text(.create_prefab), .{})) {
        // TODO: 创建新 Prefab
    }

    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button(state.text(.refresh_prefabs), .{})) {
        // TODO: 刷新 Prefab 列表
    }
}

/// 创建选中实体的 Prefab
pub fn createPrefabFromSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selected = layer_context.renderer.selectedEntity() orelse {
        return error.NoEntitySelected;
    };

    // 生成 Prefab ID
    var prefab_id_buffer: [256]u8 = undefined;
    const prefab_id = try std.fmt.bufPrint(
        &prefab_id_buffer,
        "prefab://{s}/v1",
        .{state.selected_prefab_id orelse "new_prefab"},
    );

    try layer_context.world.createPrefab(selected, prefab_id);
    state.selected_prefab_id = prefab_id;
}

/// 实例化 Prefab 到场景中
pub fn instantiatePrefabAtSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    _ = state;
    _ = layer_context.world.instantiatePrefab(prefab_id, .{
        .name_prefix = "Instance",
    });
}

/// 将选中的实体转换为 Prefab 实例
pub fn convertToPrefabInstance(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    const selected = layer_context.renderer.selectedEntity() orelse {
        return error.NoEntitySelected;
    };

    // 获取 Prefab
    const prefab = layer_context.world.getPrefab(prefab_id) orelse {
        return error.PrefabNotFound;
    };

    // 实例化 Prefab
    const instance_id = try layer_context.world.instantiatePrefab(prefab_id, .{
        .name_prefix = "",
    });

    // 标记为 Prefab 实例
    const entity = layer_context.world.getEntity(instance_id).?;
    entity.prefab_entity_id = 0; // 根实体
}

/// 显示 Prefab 覆盖编辑器
pub fn drawPrefabOverrideEditor(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.world.EntityId,
) !void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;

    if (entity.prefab_instance_override == null) {
        // 没有覆盖，显示"添加覆盖"按钮
        if (engine.ui.ImGui.button(state.text(.add_override), .{})) {
            // 创建新的覆盖数据
            var override = prefab_mod.PrefabInstanceOverride{
                .prefab_id = try state.allocator.dupe(u8, "prefab://unknown"),
                .prefab_version = 1,
                .root_prefab_entity_id = entity.prefab_entity_id orelse 0,
                .override_mask = .{},
            };
            entity.prefab_instance_override = override;
        }
        return;
    }

    const override = entity.prefab_instance_override.?;

    engine.ui.ImGui.text(state.text(.prefab_override));
    engine.ui.ImGui.text(override.prefab_id);

    engine.ui.ImGui.separator();

    // 变换覆盖
    if (engine.ui.ImGui.collapsingHeader(state.text(.transform), .{})) {
        const transform_changed = engine.ui.ImGui.dragFloat3(
            state.text(.translation),
            &entity.local_transform.translation,
            0.1,
        );

        var rotation: [3]f32 = undefined;
        // TODO: 从四元数转换欧拉角
        _ = engine.ui.ImGui.dragFloat3(state.text(.rotation), &rotation, 0.1);

        const scale_changed = engine.ui.ImGui.dragFloat3(
            state.text(.scale),
            &entity.local_transform.scale,
            0.1,
        );

        if (transform_changed or scale_changed) {
            override.override_mask.local_transform = true;
            override.local_transform_override = entity.local_transform;
        }
    }

    // 可见性覆盖
    if (engine.ui.ImGui.collapsingHeader(state.text(.visibility), .{})) {
        const visible_changed = engine.ui.ImGui.checkbox(
            state.text(.visible),
            &entity.visible,
        );

        if (visible_changed) {
            override.override_mask.visible = true;
            override.visible_override = entity.visible;
        }
    }

    engine.ui.ImGui.separator();

    // 恢复覆盖按钮
    if (engine.ui.ImGui.button(state.text(.revert_override), .{})) {
        try layer_context.world.revertPrefabOverride(entity_id);
    }
}
