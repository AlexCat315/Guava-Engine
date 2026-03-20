#include "wasm3.h"

#include <stdio.h>
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

m3ApiRawFunction(guava_host_get_entity_id_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiReturn(guava_wasm_host_get_entity_id(_ctx->userdata));
}

m3ApiRawFunction(guava_host_find_entity_by_name_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArgMem(const uint8_t *, ptr)
    m3ApiGetArg(uint32_t, len)
    m3ApiCheckMem(ptr, len)
    m3ApiReturn(guava_wasm_host_find_entity_by_name(_ctx->userdata, ptr, len));
}

m3ApiRawFunction(guava_host_log_raw) {
    m3ApiGetArgMem(const uint8_t *, ptr)
    m3ApiGetArg(uint32_t, len)
    m3ApiCheckMem(ptr, len)
    guava_wasm_host_log(_ctx->userdata, ptr, len);
    m3ApiSuccess();
}

m3ApiRawFunction(guava_host_set_local_transform_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, entity_id)
    m3ApiGetArg(float, tx)
    m3ApiGetArg(float, ty)
    m3ApiGetArg(float, tz)
    m3ApiGetArg(float, rx)
    m3ApiGetArg(float, ry)
    m3ApiGetArg(float, rz)
    m3ApiGetArg(float, rw)
    m3ApiGetArg(float, sx)
    m3ApiGetArg(float, sy)
    m3ApiGetArg(float, sz)
    m3ApiReturn(guava_wasm_host_set_local_transform(_ctx->userdata, entity_id, tx, ty, tz, rx, ry, rz, rw, sx, sy, sz));
}

m3ApiRawFunction(guava_host_set_local_translation_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, entity_id)
    m3ApiGetArg(float, tx)
    m3ApiGetArg(float, ty)
    m3ApiGetArg(float, tz)
    m3ApiReturn(guava_wasm_host_set_local_translation(_ctx->userdata, entity_id, tx, ty, tz));
}

m3ApiRawFunction(guava_host_set_local_rotation_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, entity_id)
    m3ApiGetArg(float, rx)
    m3ApiGetArg(float, ry)
    m3ApiGetArg(float, rz)
    m3ApiGetArg(float, rw)
    m3ApiReturn(guava_wasm_host_set_local_rotation(_ctx->userdata, entity_id, rx, ry, rz, rw));
}

m3ApiRawFunction(guava_host_set_local_scale_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, entity_id)
    m3ApiGetArg(float, sx)
    m3ApiGetArg(float, sy)
    m3ApiGetArg(float, sz)
    m3ApiReturn(guava_wasm_host_set_local_scale(_ctx->userdata, entity_id, sx, sy, sz));
}

m3ApiRawFunction(guava_host_set_visible_raw) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, entity_id)
    m3ApiGetArg(uint32_t, visible)
    m3ApiReturn(guava_wasm_host_set_visible(_ctx->userdata, entity_id, visible));
}

m3ApiRawFunction(guava_host_report_panic_raw) {
    m3ApiGetArgMem(const uint8_t *, ptr)
    m3ApiGetArg(uint32_t, len)
    m3ApiCheckMem(ptr, len)
    guava_wasm_host_report_panic(_ctx->userdata, ptr, len);
    m3ApiSuccess();
}

const char *guava_wasm_link_host_functions(IM3Module module, void *userdata) {
    M3Result result = m3_LinkRawFunctionEx(module, "env", "host_get_entity_id", "i()", guava_host_get_entity_id_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_find_entity_by_name", "i(*i)", guava_host_find_entity_by_name_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_log", "v(*i)", guava_host_log_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_set_local_transform", "i(iffffffffff)", guava_host_set_local_transform_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_set_local_translation", "i(ifff)", guava_host_set_local_translation_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_set_local_rotation", "i(iffff)", guava_host_set_local_rotation_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_set_local_scale", "i(ifff)", guava_host_set_local_scale_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_set_visible", "i(ii)", guava_host_set_visible_raw, userdata);
    if (result) return result;
    result = m3_LinkRawFunctionEx(module, "env", "host_report_panic", "v(*i)", guava_host_report_panic_raw, userdata);
    return result;
}

const char *guava_wasm_call_0(IM3Function function) {
    return m3_CallArgv(function, 0, NULL);
}

const char *guava_wasm_call_f32(IM3Function function, float value) {
    char arg0[64];
    snprintf(arg0, sizeof(arg0), "%.9g", value);
    const char *argv[] = { arg0 };
    return m3_CallArgv(function, 1, argv);
}
