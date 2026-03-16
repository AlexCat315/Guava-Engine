#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    GUAVA_IMGUI_WINDOW_NONE = 0,
    GUAVA_IMGUI_WINDOW_NO_TITLE_BAR = 1 << 0,
    GUAVA_IMGUI_WINDOW_NO_RESIZE = 1 << 1,
    GUAVA_IMGUI_WINDOW_NO_MOVE = 1 << 2,
    GUAVA_IMGUI_WINDOW_NO_SCROLLBAR = 1 << 3,
    GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS = 1 << 4,
    GUAVA_IMGUI_WINDOW_NO_DOCKING = 1 << 5,
    GUAVA_IMGUI_WINDOW_NO_COLLAPSE = 1 << 6,
    GUAVA_IMGUI_WINDOW_NO_BACKGROUND = 1 << 7,
    GUAVA_IMGUI_WINDOW_NO_DECORATION = 1 << 8,
};

bool guava_imgui_init(SDL_Window* window, SDL_GPUDevice* device, SDL_GPUTextureFormat color_target_format);
void guava_imgui_shutdown(void);
void guava_imgui_process_event(const SDL_Event* event);
void guava_imgui_new_frame(void);
void guava_imgui_begin_dockspace(void);
void guava_imgui_reset_default_layout(void);
void guava_imgui_prepare(SDL_GPUCommandBuffer* command_buffer);
void guava_imgui_render(SDL_GPUCommandBuffer* command_buffer, SDL_GPURenderPass* render_pass);
bool guava_imgui_want_capture_mouse(void);
bool guava_imgui_want_capture_keyboard(void);

bool guava_imgui_begin_window(const char* name, size_t name_len);
bool guava_imgui_begin_window_flags(const char* name, size_t name_len, uint32_t flags);
void guava_imgui_end_window(void);
bool guava_imgui_begin_main_menu_bar(void);
void guava_imgui_end_main_menu_bar(void);
bool guava_imgui_begin_menu(const char* label, size_t label_len);
void guava_imgui_end_menu(void);
bool guava_imgui_menu_item(const char* label, size_t label_len, const char* shortcut, size_t shortcut_len, bool selected, bool enabled);
bool guava_imgui_button(const char* label, size_t label_len);
void guava_imgui_same_line(void);
void guava_imgui_separator(void);
void guava_imgui_text(const char* text, size_t text_len);
void guava_imgui_label_text(const char* label, size_t label_len, const char* text, size_t text_len);
void guava_imgui_push_id_u64(uint64_t value);
void guava_imgui_pop_id(void);
bool guava_imgui_tree_node_entity(uint64_t id, const char* label, size_t label_len, bool selected, bool leaf, bool default_open);
void guava_imgui_tree_pop(void);
bool guava_imgui_is_item_clicked(void);
bool guava_imgui_is_item_hovered(void);
bool guava_imgui_is_item_deactivated_after_edit(void);
bool guava_imgui_input_text(const char* label, size_t label_len, char* buffer, size_t buffer_size);
bool guava_imgui_drag_float(const char* label, size_t label_len, float* value, float speed, float min_value, float max_value);
bool guava_imgui_drag_float3(const char* label, size_t label_len, float value[3], float speed, float min_value, float max_value);
bool guava_imgui_checkbox(const char* label, size_t label_len, bool* value);
bool guava_imgui_collapsing_header(const char* label, size_t label_len, bool default_open);
bool guava_imgui_drag_drop_source_u64(const char* payload_type, size_t payload_type_len, uint64_t value, const char* preview_text, size_t preview_text_len);
bool guava_imgui_accept_drag_drop_payload_u64(const char* payload_type, size_t payload_type_len, uint64_t* out_value);
bool guava_imgui_is_window_hovered(void);
bool guava_imgui_is_window_focused(void);
void guava_imgui_get_content_region_avail(float out_value[2]);
void guava_imgui_get_cursor_screen_pos(float out_value[2]);
void guava_imgui_image(SDL_GPUTexture* texture, float width, float height);

#ifdef __cplusplus
}
#endif
