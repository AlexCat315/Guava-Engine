#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── View Cube ────────────────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_VIEW_CUBE_NONE = 0,
  GUAVA_IMGUI_VIEW_CUBE_FRONT = 1,
  GUAVA_IMGUI_VIEW_CUBE_BACK = 2,
  GUAVA_IMGUI_VIEW_CUBE_LEFT = 3,
  GUAVA_IMGUI_VIEW_CUBE_RIGHT = 4,
  GUAVA_IMGUI_VIEW_CUBE_TOP = 5,
  GUAVA_IMGUI_VIEW_CUBE_BOTTOM = 6,
  GUAVA_IMGUI_VIEW_CUBE_HOVERED = 1 << 8,
  GUAVA_IMGUI_VIEW_CUBE_ACTIVE = 1 << 9,
  GUAVA_IMGUI_VIEW_CUBE_DRAGGING = 1 << 10,
};

uint32_t guava_imgui_draw_view_cube(const float view[16], float x, float y,
                                    float size, float out_drag_delta[2]);

// ── Tree Node Entity ─────────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_TREE_NODE_OPEN = 1 << 0,
  GUAVA_IMGUI_TREE_NODE_CLICKED = 1 << 1,
  GUAVA_IMGUI_TREE_NODE_RENAME_COMMITTED = 1 << 2,
  GUAVA_IMGUI_TREE_NODE_RENAME_FINISHED = 1 << 3,
};

uint32_t guava_imgui_tree_node_entity(uint64_t id, const char *label,
                                      size_t label_len, void *icon_texture,
                                      float icon_size, bool selected, bool leaf,
                                      bool default_open, char *rename_buffer,
                                      size_t rename_buffer_size,
                                      bool request_rename_focus);

// ── Window Control Button ────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_WINDOW_CONTROL_MINIMIZE = 0,
  GUAVA_IMGUI_WINDOW_CONTROL_MAXIMIZE = 1,
  GUAVA_IMGUI_WINDOW_CONTROL_CLOSE = 2,
};

bool guava_imgui_window_control_button(uint32_t kind, bool toggled);

#ifdef __cplusplus
}
#endif
