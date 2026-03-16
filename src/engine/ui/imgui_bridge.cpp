#include "imgui_bridge.h"

#include <filesystem>
#include <initializer_list>
#include <string>

#include "imgui.h"
#include "imgui_internal.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_sdlgpu3.h"

namespace {

std::string make_string(const char* text, size_t text_len) {
    return std::string(text, text_len);
}

bool g_imgui_initialized = false;
ImDrawData* g_draw_data = nullptr;
std::string g_ini_path;
ImGuiID g_dockspace_id = 0;

std::string first_existing_path(std::initializer_list<const char*> candidates) {
    for (const char* candidate : candidates) {
        if (candidate == nullptr || candidate[0] == '\0') {
            continue;
        }
        std::error_code ec;
        if (std::filesystem::exists(candidate, ec)) {
            return std::string(candidate);
        }
    }
    return {};
}

std::string find_ui_font_path() {
#if defined(__APPLE__)
    return first_existing_path({
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    });
#elif defined(_WIN32)
    return first_existing_path({
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/arial.ttf",
    });
#else
    return first_existing_path({
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    });
#endif
}

std::string find_cjk_font_path() {
#if defined(__APPLE__)
    return first_existing_path({
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
    });
#elif defined(_WIN32)
    return first_existing_path({
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/msyh.ttf",
        "C:/Windows/Fonts/simhei.ttf",
        "C:/Windows/Fonts/simsun.ttc",
    });
#else
    return first_existing_path({
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    });
#endif
}

void configure_fonts(float content_scale) {
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigDpiScaleFonts = false;
    io.Fonts->Clear();
    io.Fonts->Flags |= ImFontAtlasFlags_NoPowerOfTwoHeight;

    const float scale = content_scale > 0.0f ? content_scale : 1.0f;
    const float font_size = 16.0f * scale;

    ImFontConfig base_cfg = {};
    base_cfg.OversampleH = 2;
    base_cfg.OversampleV = 1;
    base_cfg.RasterizerMultiply = 1.1f;
    base_cfg.FontNo = 0;

    const std::string ui_font_path = find_ui_font_path();
    const std::string cjk_font_path = find_cjk_font_path();

    ImFont* primary_font = nullptr;
    if (!ui_font_path.empty()) {
        primary_font = io.Fonts->AddFontFromFileTTF(ui_font_path.c_str(), font_size, &base_cfg, io.Fonts->GetGlyphRangesDefault());
    }
    if (primary_font == nullptr && !cjk_font_path.empty()) {
        primary_font = io.Fonts->AddFontFromFileTTF(cjk_font_path.c_str(), font_size, &base_cfg, io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
    }
    if (primary_font == nullptr) {
        primary_font = io.Fonts->AddFontDefault();
    }

    if (!cjk_font_path.empty()) {
        ImFontConfig merge_cfg = base_cfg;
        merge_cfg.MergeMode = true;
        merge_cfg.FontNo = 0;
        merge_cfg.GlyphMinAdvanceX = font_size * 0.5f;
        io.Fonts->AddFontFromFileTTF(cjk_font_path.c_str(), font_size, &merge_cfg, io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
    }

    io.FontDefault = primary_font;
}

} // namespace

extern "C" bool guava_imgui_init(SDL_Window* window, SDL_GPUDevice* device, SDL_GPUTextureFormat color_target_format) {
    if (g_imgui_initialized) {
        return true;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;

    if (char* pref_path = SDL_GetPrefPath("Guava", "Editor")) {
        g_ini_path = std::string(pref_path) + "imgui.ini";
        io.IniFilename = g_ini_path.c_str();
        SDL_free(pref_path);
    } else {
        g_ini_path.clear();
        io.IniFilename = nullptr;
    }

    const float reported_scale = SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());
    const float main_scale = reported_scale > 0.0f ? reported_scale : 1.0f;
    configure_fonts(main_scale);

    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.ScaleAllSizes(main_scale);
    style.FontScaleDpi = 1.0f;

    if (!ImGui_ImplSDL3_InitForSDLGPU(window)) {
        ImGui::DestroyContext();
        return false;
    }

    ImGui_ImplSDLGPU3_InitInfo init_info = {};
    init_info.Device = device;
    init_info.ColorTargetFormat = color_target_format;
    init_info.MSAASamples = SDL_GPU_SAMPLECOUNT_1;
    init_info.SwapchainComposition = SDL_GPU_SWAPCHAINCOMPOSITION_SDR;
    init_info.PresentMode = SDL_GPU_PRESENTMODE_VSYNC;

    if (!ImGui_ImplSDLGPU3_Init(&init_info)) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return false;
    }

    g_imgui_initialized = true;
    return true;
}

extern "C" void guava_imgui_shutdown(void) {
    if (!g_imgui_initialized) {
        return;
    }

    ImGui_ImplSDLGPU3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    g_draw_data = nullptr;
    g_ini_path.clear();
    g_imgui_initialized = false;
}

extern "C" void guava_imgui_process_event(const SDL_Event* event) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui_ImplSDL3_ProcessEvent(event);
}

extern "C" void guava_imgui_new_frame(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui_ImplSDLGPU3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

extern "C" void guava_imgui_begin_dockspace(void) {
    if (!g_imgui_initialized) {
        return;
    }
    g_dockspace_id = ImGui::GetID("GuavaEditorDockspace");
    ImGui::DockSpaceOverViewport(g_dockspace_id, nullptr, ImGuiDockNodeFlags_PassthruCentralNode);
}

extern "C" void guava_imgui_reset_default_layout(void) {
    if (!g_imgui_initialized) {
        return;
    }

    ImGuiViewport* viewport = ImGui::GetMainViewport();
    if (viewport == nullptr) {
        return;
    }

    g_dockspace_id = ImGui::GetID("GuavaEditorDockspace");
    ImGui::DockBuilderRemoveNode(g_dockspace_id);
    ImGui::DockBuilderAddNode(g_dockspace_id, ImGuiDockNodeFlags_DockSpace | ImGuiDockNodeFlags_PassthruCentralNode);
    ImGui::DockBuilderSetNodeSize(g_dockspace_id, viewport->Size);

    ImGuiID dock_main = g_dockspace_id;
    ImGuiID dock_left = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Left, 0.22f, nullptr, &dock_main);
    ImGuiID dock_right = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Right, 0.28f, nullptr, &dock_main);
    ImGuiID dock_bottom = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Down, 0.28f, nullptr, &dock_main);
    ImGuiID dock_top = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Up, 0.08f, nullptr, &dock_main);
    ImGuiID dock_left_bottom = ImGui::DockBuilderSplitNode(dock_left, ImGuiDir_Down, 0.34f, nullptr, &dock_left);
    ImGuiID dock_right_bottom = ImGui::DockBuilderSplitNode(dock_right, ImGuiDir_Down, 0.42f, nullptr, &dock_right);

    ImGui::DockBuilderDockWindow("Viewport Toolbar###viewport_toolbar_panel", dock_top);
    ImGui::DockBuilderDockWindow("Viewport###viewport_panel", dock_main);
    ImGui::DockBuilderDockWindow("Scene###scene_panel", dock_left);
    ImGui::DockBuilderDockWindow("Settings###settings_panel", dock_left_bottom);
    ImGui::DockBuilderDockWindow("Details###details_panel", dock_right);
    ImGui::DockBuilderDockWindow("Asset Preview###asset_preview_panel", dock_right_bottom);
    ImGui::DockBuilderDockWindow("Stats###stats_panel", dock_right_bottom);
    ImGui::DockBuilderDockWindow("Content Browser###content_browser_panel", dock_bottom);

    ImGui::DockBuilderFinish(g_dockspace_id);
}

extern "C" void guava_imgui_prepare(SDL_GPUCommandBuffer* command_buffer) {
    if (!g_imgui_initialized) {
        return;
    }

    g_draw_data = nullptr;
    ImGui::Render();
    g_draw_data = ImGui::GetDrawData();
    if (g_draw_data == nullptr || g_draw_data->DisplaySize.x <= 0.0f || g_draw_data->DisplaySize.y <= 0.0f) {
        return;
    }

    ImGui_ImplSDLGPU3_PrepareDrawData(g_draw_data, command_buffer);
}

extern "C" void guava_imgui_render(SDL_GPUCommandBuffer* command_buffer, SDL_GPURenderPass* render_pass) {
    if (!g_imgui_initialized || g_draw_data == nullptr || g_draw_data->DisplaySize.x <= 0.0f || g_draw_data->DisplaySize.y <= 0.0f) {
        return;
    }

    ImGui_ImplSDLGPU3_RenderDrawData(g_draw_data, command_buffer, render_pass);
}

extern "C" bool guava_imgui_want_capture_mouse(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::GetIO().WantCaptureMouse;
}

extern "C" bool guava_imgui_want_capture_keyboard(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::GetIO().WantCaptureKeyboard;
}

extern "C" bool guava_imgui_begin_window(const char* name, size_t name_len) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string window_name = make_string(name, name_len);
    return ImGui::Begin(window_name.c_str());
}

extern "C" void guava_imgui_end_window(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::End();
}

extern "C" bool guava_imgui_begin_main_menu_bar(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::BeginMainMenuBar();
}

extern "C" void guava_imgui_end_main_menu_bar(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::EndMainMenuBar();
}

extern "C" bool guava_imgui_begin_menu(const char* label, size_t label_len) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::BeginMenu(owned_label.c_str());
}

extern "C" void guava_imgui_end_menu(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::EndMenu();
}

extern "C" bool guava_imgui_menu_item(const char* label, size_t label_len, const char* shortcut, size_t shortcut_len, bool selected, bool enabled) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    const std::string owned_shortcut = shortcut != nullptr ? make_string(shortcut, shortcut_len) : std::string();
    return ImGui::MenuItem(
        owned_label.c_str(),
        shortcut != nullptr ? owned_shortcut.c_str() : nullptr,
        selected,
        enabled
    );
}

extern "C" bool guava_imgui_button(const char* label, size_t label_len) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::Button(owned_label.c_str());
}

extern "C" void guava_imgui_same_line(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SameLine();
}

extern "C" void guava_imgui_separator(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::Separator();
}

extern "C" void guava_imgui_text(const char* text, size_t text_len) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TextUnformatted(text, text + text_len);
}

extern "C" void guava_imgui_label_text(const char* label, size_t label_len, const char* text, size_t text_len) {
    if (!g_imgui_initialized) {
        return;
    }
    const std::string owned_label = make_string(label, label_len);
    const std::string owned_text = make_string(text, text_len);
    ImGui::LabelText(owned_label.c_str(), "%s", owned_text.c_str());
}

extern "C" void guava_imgui_push_id_u64(uint64_t value) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PushID(reinterpret_cast<void*>(static_cast<uintptr_t>(value)));
}

extern "C" void guava_imgui_pop_id(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PopID();
}

extern "C" bool guava_imgui_tree_node_entity(uint64_t id, const char* label, size_t label_len, bool selected, bool leaf, bool default_open) {
    if (!g_imgui_initialized) {
        return false;
    }

    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_OpenOnArrow | ImGuiTreeNodeFlags_SpanAvailWidth;
    if (selected) {
        flags |= ImGuiTreeNodeFlags_Selected;
    }
    if (leaf) {
        flags |= ImGuiTreeNodeFlags_Leaf | ImGuiTreeNodeFlags_NoTreePushOnOpen;
    }
    if (default_open) {
        flags |= ImGuiTreeNodeFlags_DefaultOpen;
    }

    const std::string owned_label = make_string(label, label_len);
    return ImGui::TreeNodeEx(reinterpret_cast<void*>(static_cast<uintptr_t>(id)), flags, "%s", owned_label.c_str());
}

extern "C" void guava_imgui_tree_pop(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TreePop();
}

extern "C" bool guava_imgui_is_item_clicked(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsItemClicked();
}

extern "C" bool guava_imgui_is_item_hovered(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsItemHovered();
}

extern "C" bool guava_imgui_is_item_deactivated_after_edit(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsItemDeactivatedAfterEdit();
}

extern "C" bool guava_imgui_input_text(const char* label, size_t label_len, char* buffer, size_t buffer_size) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::InputText(owned_label.c_str(), buffer, buffer_size);
}

extern "C" bool guava_imgui_drag_float(const char* label, size_t label_len, float* value, float speed, float min_value, float max_value) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::DragFloat(owned_label.c_str(), value, speed, min_value, max_value);
}

extern "C" bool guava_imgui_drag_float3(const char* label, size_t label_len, float value[3], float speed, float min_value, float max_value) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::DragFloat3(owned_label.c_str(), value, speed, min_value, max_value);
}

extern "C" bool guava_imgui_checkbox(const char* label, size_t label_len, bool* value) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::Checkbox(owned_label.c_str(), value);
}

extern "C" bool guava_imgui_collapsing_header(const char* label, size_t label_len, bool default_open) {
    if (!g_imgui_initialized) {
        return false;
    }
    ImGuiTreeNodeFlags flags = default_open ? ImGuiTreeNodeFlags_DefaultOpen : ImGuiTreeNodeFlags_None;
    const std::string owned_label = make_string(label, label_len);
    return ImGui::CollapsingHeader(owned_label.c_str(), flags);
}

extern "C" bool guava_imgui_drag_drop_source_u64(const char* payload_type, size_t payload_type_len, uint64_t value, const char* preview_text, size_t preview_text_len) {
    if (!g_imgui_initialized) {
        return false;
    }
    if (!ImGui::BeginDragDropSource()) {
        return false;
    }

    const std::string owned_type = make_string(payload_type, payload_type_len);
    ImGui::SetDragDropPayload(owned_type.c_str(), &value, sizeof(value));
    if (preview_text != nullptr and preview_text_len > 0) {
        ImGui::TextUnformatted(preview_text, preview_text + preview_text_len);
    }
    ImGui::EndDragDropSource();
    return true;
}

extern "C" bool guava_imgui_accept_drag_drop_payload_u64(const char* payload_type, size_t payload_type_len, uint64_t* out_value) {
    if (!g_imgui_initialized || out_value == nullptr) {
        return false;
    }
    if (!ImGui::BeginDragDropTarget()) {
        return false;
    }

    bool accepted = false;
    const std::string owned_type = make_string(payload_type, payload_type_len);
    if (const ImGuiPayload* payload = ImGui::AcceptDragDropPayload(owned_type.c_str())) {
        if (payload->Data != nullptr && payload->DataSize == static_cast<int>(sizeof(uint64_t))) {
            *out_value = *static_cast<const uint64_t*>(payload->Data);
            accepted = true;
        }
    }

    ImGui::EndDragDropTarget();
    return accepted;
}

extern "C" bool guava_imgui_is_window_hovered(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
}

extern "C" bool guava_imgui_is_window_focused(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows);
}

extern "C" void guava_imgui_get_content_region_avail(float out_value[2]) {
    if (!g_imgui_initialized || out_value == nullptr) {
        return;
    }
    const ImVec2 value = ImGui::GetContentRegionAvail();
    out_value[0] = value.x;
    out_value[1] = value.y;
}

extern "C" void guava_imgui_get_cursor_screen_pos(float out_value[2]) {
    if (!g_imgui_initialized || out_value == nullptr) {
        return;
    }
    const ImVec2 value = ImGui::GetCursorScreenPos();
    out_value[0] = value.x;
    out_value[1] = value.y;
}

extern "C" void guava_imgui_image(SDL_GPUTexture* texture, float width, float height) {
    if (!g_imgui_initialized || texture == nullptr) {
        return;
    }
    ImGui::Image((ImTextureID)(intptr_t)texture, ImVec2(width, height));
}
