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

#define GUAVA_NATIVE_SYMBOL_COUNT 9

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
};

NativeSymbol *
guava_wamr_native_symbols(void) {
    return guava_native_symbols;
}

uint32_t
guava_wamr_native_symbol_count(void) {
    return GUAVA_NATIVE_SYMBOL_COUNT;
}
