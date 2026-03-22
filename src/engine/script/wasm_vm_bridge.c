#include "wasm_export.h"

#include <stddef.h>
#include <stdint.h>

extern uint32_t guava_wasm_host_get_entity_id(void *userdata);
extern uint32_t guava_wasm_host_find_entity_by_name(void *userdata, const uint8_t *ptr, uint32_t len);
extern void guava_wasm_host_log(void *userdata, const uint8_t *ptr, uint32_t len);
extern uint32_t guava_wasm_host_set_local_transform(
    void *userdata,
    uint32_t entity_id,
    float tx,
    float ty,
    float tz,
    float rx,
    float ry,
    float rz,
    float rw,
    float sx,
    float sy,
    float sz
);
extern uint32_t guava_wasm_host_set_local_translation(void *userdata, uint32_t entity_id, float tx, float ty, float tz);
extern uint32_t guava_wasm_host_set_local_rotation(void *userdata, uint32_t entity_id, float rx, float ry, float rz, float rw);
extern uint32_t guava_wasm_host_set_local_scale(void *userdata, uint32_t entity_id, float sx, float sy, float sz);
extern uint32_t guava_wasm_host_set_visible(void *userdata, uint32_t entity_id, uint32_t visible);
extern void guava_wasm_host_report_panic(void *userdata, const uint8_t *ptr, uint32_t len);
extern void guava_wasm_host_report_panic_with_location(
    void *userdata,
    const uint8_t *msg_ptr,
    uint32_t msg_len,
    const uint8_t *file_ptr,
    uint32_t file_len,
    const uint8_t *func_ptr,
    uint32_t func_len,
    uint32_t line,
    uint32_t column
);
extern uint32_t guava_wasm_host_get_selection_count(void *userdata);
extern uint32_t guava_wasm_host_get_selection_entity(void *userdata, uint32_t index);
extern void guava_wasm_host_select_entity(void *userdata, uint32_t entity_id, uint32_t additive);
extern void guava_wasm_host_clear_selection(void *userdata);
extern uint32_t guava_wasm_host_ui_last_item_changed(void *userdata);
extern void guava_wasm_host_ui_text(void *userdata, const uint8_t *ptr, uint32_t len);
extern void guava_wasm_host_ui_text_wrapped(void *userdata, const uint8_t *ptr, uint32_t len);
extern void guava_wasm_host_ui_separator(void *userdata);
extern void guava_wasm_host_ui_same_line(void *userdata);
extern uint32_t guava_wasm_host_ui_button(void *userdata, const uint8_t *ptr, uint32_t len);
extern uint32_t guava_wasm_host_ui_checkbox(void *userdata, const uint8_t *ptr, uint32_t len, uint32_t value);
extern uint32_t guava_wasm_host_ui_drag_float_bits(
    void *userdata,
    const uint8_t *ptr,
    uint32_t len,
    uint32_t current_bits,
    float speed,
    float min_value,
    float max_value
);
extern void guava_wasm_host_ui_set_next_item_width(void *userdata, float width);
extern uint32_t guava_wasm_host_ui_begin_window(void *userdata, const uint8_t *ptr, uint32_t len);
extern void guava_wasm_host_ui_end_window(void *userdata);
extern uint32_t guava_wasm_host_ui_collapsing_header(void *userdata, const uint8_t *ptr, uint32_t len, uint32_t default_open);
extern uint32_t guava_wasm_host_ui_input_text(void *userdata, const uint8_t *label_ptr, uint32_t label_len, uint8_t *buffer_ptr, uint32_t buffer_len);
extern uint32_t guava_wasm_host_ui_drag_float3_bits(void *userdata, const uint8_t *ptr, uint32_t len, uint32_t x_bits, uint32_t y_bits, uint32_t z_bits, float speed, float min_value, float max_value);
extern void guava_wasm_host_ui_indent(void *userdata, float width);
extern void guava_wasm_host_ui_unindent(void *userdata, float width);
extern uint32_t guava_wasm_host_ui_begin_child(void *userdata, const uint8_t *ptr, uint32_t len, float width, float height, uint32_t border);
extern void guava_wasm_host_ui_end_child(void *userdata);
extern uint32_t guava_wasm_host_ui_is_item_clicked(void *userdata);
extern uint32_t guava_wasm_host_ui_is_item_hovered(void *userdata);
extern void guava_wasm_host_ui_set_tooltip(void *userdata, const uint8_t *ptr, uint32_t len);

static void *
guava_get_userdata(wasm_exec_env_t exec_env) {
    wasm_module_inst_t module_inst = get_module_inst(exec_env);
    return wasm_runtime_get_custom_data(module_inst);
}

static uint32_t
host_get_entity_id(wasm_exec_env_t exec_env) {
    return guava_wasm_host_get_entity_id(guava_get_userdata(exec_env));
}

static uint32_t
host_find_entity_by_name(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    return guava_wasm_host_find_entity_by_name(guava_get_userdata(exec_env), ptr, len);
}

static void
host_log(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    guava_wasm_host_log(guava_get_userdata(exec_env), ptr, len);
}

static uint32_t
host_set_local_transform(
    wasm_exec_env_t exec_env,
    uint32_t entity_id,
    float tx,
    float ty,
    float tz,
    float rx,
    float ry,
    float rz,
    float rw,
    float sx,
    float sy,
    float sz
) {
    return guava_wasm_host_set_local_transform(
        guava_get_userdata(exec_env),
        entity_id,
        tx,
        ty,
        tz,
        rx,
        ry,
        rz,
        rw,
        sx,
        sy,
        sz
    );
}

static uint32_t
host_set_local_translation(wasm_exec_env_t exec_env, uint32_t entity_id, float tx, float ty, float tz) {
    return guava_wasm_host_set_local_translation(guava_get_userdata(exec_env), entity_id, tx, ty, tz);
}

static uint32_t
host_set_local_rotation(
    wasm_exec_env_t exec_env,
    uint32_t entity_id,
    float rx,
    float ry,
    float rz,
    float rw
) {
    return guava_wasm_host_set_local_rotation(guava_get_userdata(exec_env), entity_id, rx, ry, rz, rw);
}

static uint32_t
host_set_local_scale(wasm_exec_env_t exec_env, uint32_t entity_id, float sx, float sy, float sz) {
    return guava_wasm_host_set_local_scale(guava_get_userdata(exec_env), entity_id, sx, sy, sz);
}

static uint32_t
host_set_visible(wasm_exec_env_t exec_env, uint32_t entity_id, uint32_t visible) {
    return guava_wasm_host_set_visible(guava_get_userdata(exec_env), entity_id, visible);
}

static void
host_report_panic(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    guava_wasm_host_report_panic(guava_get_userdata(exec_env), ptr, len);
}

static void
host_report_panic_with_location(
    wasm_exec_env_t exec_env,
    const uint8_t *msg_ptr,
    uint32_t msg_len,
    const uint8_t *file_ptr,
    uint32_t file_len,
    const uint8_t *func_ptr,
    uint32_t func_len,
    uint32_t line,
    uint32_t column
) {
    guava_wasm_host_report_panic_with_location(
        guava_get_userdata(exec_env),
        msg_ptr,
        msg_len,
        file_ptr,
        file_len,
        func_ptr,
        func_len,
        line,
        column
    );
}

static uint32_t
host_get_selection_count(wasm_exec_env_t exec_env) {
    return guava_wasm_host_get_selection_count(guava_get_userdata(exec_env));
}

static uint32_t
host_get_selection_entity(wasm_exec_env_t exec_env, uint32_t index) {
    return guava_wasm_host_get_selection_entity(guava_get_userdata(exec_env), index);
}

static void
host_select_entity(wasm_exec_env_t exec_env, uint32_t entity_id, uint32_t additive) {
    guava_wasm_host_select_entity(guava_get_userdata(exec_env), entity_id, additive);
}

static void
host_clear_selection(wasm_exec_env_t exec_env) {
    guava_wasm_host_clear_selection(guava_get_userdata(exec_env));
}

static uint32_t
host_ui_last_item_changed(wasm_exec_env_t exec_env) {
    return guava_wasm_host_ui_last_item_changed(guava_get_userdata(exec_env));
}

static void
host_ui_text(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    guava_wasm_host_ui_text(guava_get_userdata(exec_env), ptr, len);
}

static void
host_ui_text_wrapped(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    guava_wasm_host_ui_text_wrapped(guava_get_userdata(exec_env), ptr, len);
}

static void
host_ui_separator(wasm_exec_env_t exec_env) {
    guava_wasm_host_ui_separator(guava_get_userdata(exec_env));
}

static void
host_ui_same_line(wasm_exec_env_t exec_env) {
    guava_wasm_host_ui_same_line(guava_get_userdata(exec_env));
}

static uint32_t
host_ui_button(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    return guava_wasm_host_ui_button(guava_get_userdata(exec_env), ptr, len);
}

static uint32_t
host_ui_checkbox(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len, uint32_t value) {
    return guava_wasm_host_ui_checkbox(guava_get_userdata(exec_env), ptr, len, value);
}

static uint32_t
host_ui_drag_float_bits(
    wasm_exec_env_t exec_env,
    const uint8_t *ptr,
    uint32_t len,
    uint32_t current_bits,
    float speed,
    float min_value,
    float max_value
) {
    return guava_wasm_host_ui_drag_float_bits(
        guava_get_userdata(exec_env),
        ptr,
        len,
        current_bits,
        speed,
        min_value,
        max_value
    );
}

static void
host_ui_set_next_item_width(wasm_exec_env_t exec_env, float width) {
    guava_wasm_host_ui_set_next_item_width(guava_get_userdata(exec_env), width);
}

static uint32_t
host_ui_begin_window(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    return guava_wasm_host_ui_begin_window(guava_get_userdata(exec_env), ptr, len);
}

static void
host_ui_end_window(wasm_exec_env_t exec_env) {
    guava_wasm_host_ui_end_window(guava_get_userdata(exec_env));
}

static uint32_t
host_ui_collapsing_header(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len, uint32_t default_open) {
    return guava_wasm_host_ui_collapsing_header(guava_get_userdata(exec_env), ptr, len, default_open);
}

static uint32_t
host_ui_input_text(
    wasm_exec_env_t exec_env,
    const uint8_t *label_ptr,
    uint32_t label_len,
    uint8_t *buffer_ptr,
    uint32_t buffer_len
) {
    return guava_wasm_host_ui_input_text(
        guava_get_userdata(exec_env),
        label_ptr,
        label_len,
        buffer_ptr,
        buffer_len
    );
}

static uint32_t
host_ui_drag_float3_bits(
    wasm_exec_env_t exec_env,
    const uint8_t *ptr,
    uint32_t len,
    uint32_t x_bits,
    uint32_t y_bits,
    uint32_t z_bits,
    float speed,
    float min_value,
    float max_value
) {
    return guava_wasm_host_ui_drag_float3_bits(
        guava_get_userdata(exec_env),
        ptr,
        len,
        x_bits,
        y_bits,
        z_bits,
        speed,
        min_value,
        max_value
    );
}

static void
host_ui_indent(wasm_exec_env_t exec_env, float width) {
    guava_wasm_host_ui_indent(guava_get_userdata(exec_env), width);
}

static void
host_ui_unindent(wasm_exec_env_t exec_env, float width) {
    guava_wasm_host_ui_unindent(guava_get_userdata(exec_env), width);
}

static uint32_t
host_ui_begin_child(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len, float width, float height, uint32_t border) {
    return guava_wasm_host_ui_begin_child(guava_get_userdata(exec_env), ptr, len, width, height, border);
}

static void
host_ui_end_child(wasm_exec_env_t exec_env) {
    guava_wasm_host_ui_end_child(guava_get_userdata(exec_env));
}

static uint32_t
host_ui_is_item_clicked(wasm_exec_env_t exec_env) {
    return guava_wasm_host_ui_is_item_clicked(guava_get_userdata(exec_env));
}

static uint32_t
host_ui_is_item_hovered(wasm_exec_env_t exec_env) {
    return guava_wasm_host_ui_is_item_hovered(guava_get_userdata(exec_env));
}

static void
host_ui_set_tooltip(wasm_exec_env_t exec_env, const uint8_t *ptr, uint32_t len) {
    guava_wasm_host_ui_set_tooltip(guava_get_userdata(exec_env), ptr, len);
}

extern uint32_t guava_wasm_host_audio_play(void *userdata, uint32_t entity_id);
extern void guava_wasm_host_audio_stop(void *userdata, uint32_t entity_id);
extern void guava_wasm_host_audio_set_volume(void *userdata, uint32_t entity_id, float volume);

extern uint32_t guava_wasm_host_physics_raycast(
    void *userdata,
    float ox, float oy, float oz,
    float dx, float dy, float dz,
    float max_dist,
    float *out_ptr
);
extern uint32_t guava_wasm_host_physics_overlap_aabb(
    void *userdata,
    float min_x, float min_y, float min_z,
    float max_x, float max_y, float max_z,
    uint32_t *out_ptr, uint32_t max_count
);
extern uint32_t guava_wasm_host_physics_overlap_sphere(
    void *userdata,
    float cx, float cy, float cz,
    float radius,
    uint32_t *out_ptr, uint32_t max_count
);

extern uint32_t guava_wasm_host_get_game_state(void *userdata);
extern void guava_wasm_host_set_game_state(void *userdata, uint32_t state);
extern float guava_wasm_host_get_time_scale(void *userdata);
extern void guava_wasm_host_set_time_scale(void *userdata, float scale);

static uint32_t
host_audio_play(wasm_exec_env_t exec_env, uint32_t entity_id) {
    return guava_wasm_host_audio_play(guava_get_userdata(exec_env), entity_id);
}

static void
host_audio_stop(wasm_exec_env_t exec_env, uint32_t entity_id) {
    guava_wasm_host_audio_stop(guava_get_userdata(exec_env), entity_id);
}

static void
host_audio_set_volume(wasm_exec_env_t exec_env, uint32_t entity_id, float volume) {
    guava_wasm_host_audio_set_volume(guava_get_userdata(exec_env), entity_id, volume);
}

static uint32_t
host_physics_raycast(
    wasm_exec_env_t exec_env,
    float ox, float oy, float oz,
    float dx, float dy, float dz,
    float max_dist,
    float *out_ptr
) {
    return guava_wasm_host_physics_raycast(
        guava_get_userdata(exec_env),
        ox, oy, oz, dx, dy, dz, max_dist, out_ptr
    );
}

static uint32_t
host_physics_overlap_aabb(
    wasm_exec_env_t exec_env,
    float min_x, float min_y, float min_z,
    float max_x, float max_y, float max_z,
    uint32_t *out_ptr, uint32_t max_count
) {
    return guava_wasm_host_physics_overlap_aabb(
        guava_get_userdata(exec_env),
        min_x, min_y, min_z, max_x, max_y, max_z,
        out_ptr, max_count
    );
}

static uint32_t
host_physics_overlap_sphere(
    wasm_exec_env_t exec_env,
    float cx, float cy, float cz,
    float radius,
    uint32_t *out_ptr, uint32_t max_count
) {
    return guava_wasm_host_physics_overlap_sphere(
        guava_get_userdata(exec_env),
        cx, cy, cz, radius,
        out_ptr, max_count
    );
}

static uint32_t
host_get_game_state(wasm_exec_env_t exec_env) {
    return guava_wasm_host_get_game_state(guava_get_userdata(exec_env));
}

static void
host_set_game_state(wasm_exec_env_t exec_env, uint32_t state) {
    guava_wasm_host_set_game_state(guava_get_userdata(exec_env), state);
}

static float
host_get_time_scale(wasm_exec_env_t exec_env) {
    return guava_wasm_host_get_time_scale(guava_get_userdata(exec_env));
}

static void
host_set_time_scale(wasm_exec_env_t exec_env, float scale) {
    guava_wasm_host_set_time_scale(guava_get_userdata(exec_env), scale);
}

#define GUAVA_NATIVE_SYMBOL_COUNT 45

static NativeSymbol guava_native_symbols[GUAVA_NATIVE_SYMBOL_COUNT] = {
    EXPORT_WASM_API_WITH_SIG(host_get_entity_id, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_find_entity_by_name, "(*~)i"),
    EXPORT_WASM_API_WITH_SIG(host_log, "(*~)"),
    EXPORT_WASM_API_WITH_SIG(host_set_local_transform, "(iffffffffff)i"),
    EXPORT_WASM_API_WITH_SIG(host_set_local_translation, "(ifff)i"),
    EXPORT_WASM_API_WITH_SIG(host_set_local_rotation, "(iffff)i"),
    EXPORT_WASM_API_WITH_SIG(host_set_local_scale, "(ifff)i"),
    EXPORT_WASM_API_WITH_SIG(host_set_visible, "(ii)i"),
    EXPORT_WASM_API_WITH_SIG(host_report_panic, "(*~)"),
    EXPORT_WASM_API_WITH_SIG(host_report_panic_with_location, "(*~*~*~ii)"),
    EXPORT_WASM_API_WITH_SIG(host_get_selection_count, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_get_selection_entity, "(i)i"),
    EXPORT_WASM_API_WITH_SIG(host_select_entity, "(ii)"),
    EXPORT_WASM_API_WITH_SIG(host_clear_selection, "()"),
    EXPORT_WASM_API_WITH_SIG(host_ui_last_item_changed, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_text, "(*~)"),
    EXPORT_WASM_API_WITH_SIG(host_ui_text_wrapped, "(*~)"),
    EXPORT_WASM_API_WITH_SIG(host_ui_separator, "()"),
    EXPORT_WASM_API_WITH_SIG(host_ui_same_line, "()"),
    EXPORT_WASM_API_WITH_SIG(host_ui_button, "(*~)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_checkbox, "(*~i)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_drag_float_bits, "(*~ifff)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_set_next_item_width, "(f)"),
    EXPORT_WASM_API_WITH_SIG(host_ui_begin_window, "(*~)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_end_window, "()"),
    EXPORT_WASM_API_WITH_SIG(host_ui_collapsing_header, "(*~i)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_input_text, "(*~*~)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_drag_float3_bits, "(*~iiifff)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_indent, "(f)"),
    EXPORT_WASM_API_WITH_SIG(host_ui_unindent, "(f)"),
    EXPORT_WASM_API_WITH_SIG(host_ui_begin_child, "(*~ffi)i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_end_child, "()"),
    EXPORT_WASM_API_WITH_SIG(host_ui_is_item_clicked, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_is_item_hovered, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_ui_set_tooltip, "(*~)"),
    EXPORT_WASM_API_WITH_SIG(host_audio_play, "(i)i"),
    EXPORT_WASM_API_WITH_SIG(host_audio_stop, "(i)"),
    EXPORT_WASM_API_WITH_SIG(host_audio_set_volume, "(if)"),
    EXPORT_WASM_API_WITH_SIG(host_physics_raycast, "(fffffff*)i"),
    EXPORT_WASM_API_WITH_SIG(host_physics_overlap_aabb, "(ffffff*i)i"),
    EXPORT_WASM_API_WITH_SIG(host_physics_overlap_sphere, "(ffff*i)i"),
    EXPORT_WASM_API_WITH_SIG(host_get_game_state, "()i"),
    EXPORT_WASM_API_WITH_SIG(host_set_game_state, "(i)"),
    EXPORT_WASM_API_WITH_SIG(host_get_time_scale, "()F"),
    EXPORT_WASM_API_WITH_SIG(host_set_time_scale, "(f)"),
};

NativeSymbol *
guava_wamr_native_symbols(void) {
    return guava_native_symbols;
}

uint32_t
guava_wamr_native_symbol_count(void) {
    return GUAVA_NATIVE_SYMBOL_COUNT;
}
