#include "imgui_bridge.h"

#include <algorithm>
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

ImGuiWindowFlags to_imgui_window_flags(uint32_t flags) {
    ImGuiWindowFlags result = ImGuiWindowFlags_None;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_TITLE_BAR) != 0) result |= ImGuiWindowFlags_NoTitleBar;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_RESIZE) != 0) result |= ImGuiWindowFlags_NoResize;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_MOVE) != 0) result |= ImGuiWindowFlags_NoMove;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_SCROLLBAR) != 0) result |= ImGuiWindowFlags_NoScrollbar;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS) != 0) result |= ImGuiWindowFlags_NoSavedSettings;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_DOCKING) != 0) result |= ImGuiWindowFlags_NoDocking;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_COLLAPSE) != 0) result |= ImGuiWindowFlags_NoCollapse;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_BACKGROUND) != 0) result |= ImGuiWindowFlags_NoBackground;
    if ((flags & GUAVA_IMGUI_WINDOW_NO_DECORATION) != 0) result |= ImGuiWindowFlags_NoDecoration;
    if ((flags & GUAVA_IMGUI_WINDOW_ALWAYS_AUTO_RESIZE) != 0) result |= ImGuiWindowFlags_AlwaysAutoResize;
    return result;
}

ImGuiCol to_imgui_style_color(uint32_t slot) {
    switch (slot) {
        case GUAVA_IMGUI_STYLE_COLOR_TEXT:
            return ImGuiCol_Text;
        case GUAVA_IMGUI_STYLE_COLOR_BUTTON:
            return ImGuiCol_Button;
        case GUAVA_IMGUI_STYLE_COLOR_BUTTON_HOVERED:
            return ImGuiCol_ButtonHovered;
        case GUAVA_IMGUI_STYLE_COLOR_BUTTON_ACTIVE:
            return ImGuiCol_ButtonActive;
        default:
            return ImGuiCol_Text;
    }
}

ImGuiStyleVar to_imgui_style_var(uint32_t slot) {
    switch (slot) {
        case GUAVA_IMGUI_STYLE_VAR_ALPHA:
            return ImGuiStyleVar_Alpha;
        case GUAVA_IMGUI_STYLE_VAR_FRAME_PADDING:
            return ImGuiStyleVar_FramePadding;
        case GUAVA_IMGUI_STYLE_VAR_ITEM_SPACING:
            return ImGuiStyleVar_ItemSpacing;
        case GUAVA_IMGUI_STYLE_VAR_FRAME_ROUNDING:
            return ImGuiStyleVar_FrameRounding;
        case GUAVA_IMGUI_STYLE_VAR_WINDOW_MIN_SIZE:
            return ImGuiStyleVar_WindowMinSize;
        default:
            return ImGuiStyleVar_Alpha;
    }
}

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

ImVec4 make_color(int r, int g, int b, int a = 255) {
    constexpr float inv_255 = 1.0f / 255.0f;
    return ImVec4(
        static_cast<float>(r) * inv_255,
        static_cast<float>(g) * inv_255,
        static_cast<float>(b) * inv_255,
        static_cast<float>(a) * inv_255
    );
}

void apply_guava_editor_style(float content_scale) {
    ImGuiStyle& style = ImGui::GetStyle();
    style = ImGuiStyle();

    style.WindowPadding = ImVec2(12.0f, 10.0f);
    style.FramePadding = ImVec2(10.0f, 6.0f);
    style.CellPadding = ImVec2(8.0f, 7.0f);
    style.ItemSpacing = ImVec2(8.0f, 7.0f);
    style.ItemInnerSpacing = ImVec2(6.0f, 4.0f);
    style.TouchExtraPadding = ImVec2(0.0f, 0.0f);
    style.IndentSpacing = 20.0f;
    style.ScrollbarSize = 14.0f;
    style.GrabMinSize = 10.0f;

    style.WindowBorderSize = 0.0f;
    style.ChildBorderSize = 0.0f;
    style.PopupBorderSize = 1.0f;
    style.FrameBorderSize = 0.0f;
    style.TabBorderSize = 0.0f;

    style.WindowRounding = 7.0f;
    style.ChildRounding = 6.0f;
    style.FrameRounding = 5.0f;
    style.PopupRounding = 6.0f;
    style.ScrollbarRounding = 8.0f;
    style.GrabRounding = 4.0f;
    style.TabRounding = 4.0f;

    style.WindowTitleAlign = ImVec2(0.02f, 0.5f);
    style.WindowMenuButtonPosition = ImGuiDir_None;
    style.ColorButtonPosition = ImGuiDir_Right;
    style.ButtonTextAlign = ImVec2(0.5f, 0.5f);
    style.SelectableTextAlign = ImVec2(0.0f, 0.5f);
    style.WindowMinSize = ImVec2(220.0f, 120.0f);

    ImVec4* colors = style.Colors;
    colors[ImGuiCol_Text] = make_color(220, 224, 231);
    colors[ImGuiCol_TextDisabled] = make_color(144, 153, 165);
    colors[ImGuiCol_WindowBg] = make_color(28, 30, 34);
    colors[ImGuiCol_ChildBg] = make_color(34, 37, 42);
    colors[ImGuiCol_PopupBg] = make_color(33, 35, 40, 250);
    colors[ImGuiCol_Border] = make_color(63, 70, 80, 110);
    colors[ImGuiCol_BorderShadow] = make_color(0, 0, 0, 0);

    colors[ImGuiCol_FrameBg] = make_color(52, 56, 63);
    colors[ImGuiCol_FrameBgHovered] = make_color(67, 74, 84);
    colors[ImGuiCol_FrameBgActive] = make_color(80, 89, 101);
    colors[ImGuiCol_TitleBg] = make_color(24, 26, 31);
    colors[ImGuiCol_TitleBgActive] = make_color(34, 37, 42);
    colors[ImGuiCol_TitleBgCollapsed] = make_color(24, 26, 31, 210);
    colors[ImGuiCol_MenuBarBg] = make_color(31, 34, 39);
    colors[ImGuiCol_ScrollbarBg] = make_color(23, 24, 27);
    colors[ImGuiCol_ScrollbarGrab] = make_color(77, 83, 93);
    colors[ImGuiCol_ScrollbarGrabHovered] = make_color(95, 103, 115);
    colors[ImGuiCol_ScrollbarGrabActive] = make_color(111, 121, 135);
    colors[ImGuiCol_CheckMark] = make_color(110, 167, 255);
    colors[ImGuiCol_SliderGrab] = make_color(108, 161, 246);
    colors[ImGuiCol_SliderGrabActive] = make_color(128, 184, 255);

    colors[ImGuiCol_Button] = make_color(58, 62, 70);
    colors[ImGuiCol_ButtonHovered] = make_color(74, 81, 91);
    colors[ImGuiCol_ButtonActive] = make_color(87, 96, 109);
    colors[ImGuiCol_Header] = make_color(58, 64, 72);
    colors[ImGuiCol_HeaderHovered] = make_color(75, 83, 95);
    colors[ImGuiCol_HeaderActive] = make_color(90, 99, 112);
    colors[ImGuiCol_Separator] = make_color(54, 60, 69, 170);
    colors[ImGuiCol_SeparatorHovered] = make_color(93, 140, 217, 210);
    colors[ImGuiCol_SeparatorActive] = make_color(109, 161, 246, 255);
    colors[ImGuiCol_ResizeGrip] = make_color(91, 101, 116, 70);
    colors[ImGuiCol_ResizeGripHovered] = make_color(109, 161, 246, 130);
    colors[ImGuiCol_ResizeGripActive] = make_color(128, 184, 255, 170);
    colors[ImGuiCol_Tab] = make_color(40, 43, 48);
    colors[ImGuiCol_TabHovered] = make_color(74, 81, 91);
    colors[ImGuiCol_TabActive] = make_color(60, 67, 76);
    colors[ImGuiCol_TabUnfocused] = make_color(34, 37, 42);
    colors[ImGuiCol_TabUnfocusedActive] = make_color(48, 52, 58);
    colors[ImGuiCol_DockingPreview] = make_color(110, 167, 255, 138);
    colors[ImGuiCol_DockingEmptyBg] = make_color(22, 24, 28);
    colors[ImGuiCol_PlotLines] = make_color(132, 142, 156);
    colors[ImGuiCol_PlotLinesHovered] = make_color(173, 197, 255);
    colors[ImGuiCol_PlotHistogram] = make_color(110, 167, 255);
    colors[ImGuiCol_PlotHistogramHovered] = make_color(132, 184, 255);
    colors[ImGuiCol_TableHeaderBg] = make_color(43, 47, 54);
    colors[ImGuiCol_TableBorderStrong] = make_color(64, 69, 78);
    colors[ImGuiCol_TableBorderLight] = make_color(47, 51, 58);
    colors[ImGuiCol_TableRowBg] = make_color(0, 0, 0, 0);
    colors[ImGuiCol_TableRowBgAlt] = make_color(255, 255, 255, 9);
    colors[ImGuiCol_TextSelectedBg] = make_color(94, 146, 227, 95);
    colors[ImGuiCol_DragDropTarget] = make_color(250, 199, 88);
    colors[ImGuiCol_NavCursor] = make_color(110, 167, 255);
    colors[ImGuiCol_NavWindowingHighlight] = make_color(255, 255, 255, 70);
    colors[ImGuiCol_NavWindowingDimBg] = make_color(0, 0, 0, 90);
    colors[ImGuiCol_ModalWindowDimBg] = make_color(0, 0, 0, 110);

    const float scale = content_scale > 0.0f ? content_scale : 1.0f;
    style.ScaleAllSizes(scale);
    style.FontScaleDpi = 1.0f;
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

void draw_window_control_icon(ImDrawList* draw_list, ImRect rect, uint32_t kind, bool toggled, ImU32 color) {
    const ImVec2 center = rect.GetCenter();
    const float half_w = rect.GetWidth() * 0.18f;
    const float half_h = rect.GetHeight() * 0.18f;
    const float thickness = 1.5f;

    switch (kind) {
        case GUAVA_IMGUI_WINDOW_CONTROL_MINIMIZE:
            draw_list->AddLine(
                ImVec2(center.x - half_w, center.y + half_h * 0.45f),
                ImVec2(center.x + half_w, center.y + half_h * 0.45f),
                color,
                thickness
            );
            break;
        case GUAVA_IMGUI_WINDOW_CONTROL_MAXIMIZE:
            if (toggled) {
                draw_list->AddRect(
                    ImVec2(center.x - half_w * 0.55f, center.y - half_h * 1.25f),
                    ImVec2(center.x + half_w * 1.05f, center.y + half_h * 0.35f),
                    color,
                    1.5f,
                    0,
                    thickness
                );
                draw_list->AddRect(
                    ImVec2(center.x - half_w * 1.05f, center.y - half_h * 0.35f),
                    ImVec2(center.x + half_w * 0.55f, center.y + half_h * 1.25f),
                    color,
                    1.5f,
                    0,
                    thickness
                );
            } else {
                draw_list->AddRect(
                    ImVec2(center.x - half_w, center.y - half_h),
                    ImVec2(center.x + half_w, center.y + half_h),
                    color,
                    1.5f,
                    0,
                    thickness
                );
            }
            break;
        case GUAVA_IMGUI_WINDOW_CONTROL_CLOSE:
            draw_list->AddLine(
                ImVec2(center.x - half_w, center.y - half_h),
                ImVec2(center.x + half_w, center.y + half_h),
                color,
                thickness
            );
            draw_list->AddLine(
                ImVec2(center.x - half_w, center.y + half_h),
                ImVec2(center.x + half_w, center.y - half_h),
                color,
                thickness
            );
            break;
        default:
            break;
    }
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
    io.ConfigDockingAlwaysTabBar = true;

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

    apply_guava_editor_style(main_scale);

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
    ImGuiID dock_bottom = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Down, 0.22f, nullptr, &dock_main);
    ImGuiID dock_left = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Left, 0.15f, nullptr, &dock_main);
    ImGuiID dock_right = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Right, 0.26f, nullptr, &dock_main);
    ImGuiID dock_top = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Up, 0.055f, nullptr, &dock_main);
    if (ImGuiDockNode* top_node = ImGui::DockBuilderGetNode(dock_top)) {
        top_node->LocalFlags |= ImGuiDockNodeFlags_NoTabBar | ImGuiDockNodeFlags_NoWindowMenuButton | ImGuiDockNodeFlags_NoCloseButton;
    }

    ImGui::DockBuilderDockWindow("Global Toolbar###global_toolbar_panel", dock_top);
    ImGui::DockBuilderDockWindow("Viewport###viewport_panel", dock_main);
    ImGui::DockBuilderDockWindow("Scene###scene_panel", dock_left);
    ImGui::DockBuilderDockWindow("Details###details_panel", dock_right);
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

extern "C" bool guava_imgui_begin_window_flags(const char* name, size_t name_len, uint32_t flags) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string window_name = make_string(name, name_len);
    return ImGui::Begin(window_name.c_str(), nullptr, to_imgui_window_flags(flags));
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

extern "C" bool guava_imgui_begin_popup_context_item(const char* id, size_t id_len) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_id = id != nullptr ? make_string(id, id_len) : std::string{};
    return ImGui::BeginPopupContextItem(owned_id.empty() ? nullptr : owned_id.c_str());
}

extern "C" bool guava_imgui_begin_popup_context_window(const char* id, size_t id_len, bool open_over_items) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_id = id != nullptr ? make_string(id, id_len) : std::string{};
    ImGuiPopupFlags flags = ImGuiPopupFlags_MouseButtonRight;
    if (!open_over_items) {
        flags |= ImGuiPopupFlags_NoOpenOverItems;
    }
    return ImGui::BeginPopupContextWindow(owned_id.empty() ? nullptr : owned_id.c_str(), flags);
}

extern "C" void guava_imgui_end_popup(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::EndPopup();
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

extern "C" bool guava_imgui_button_ex(const char* label, size_t label_len, float width, float height) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    return ImGui::Button(owned_label.c_str(), ImVec2(width, height));
}

extern "C" bool guava_imgui_image_button(
    const char* id,
    size_t id_len,
    SDL_GPUTexture* texture,
    float width,
    float height,
    float bg_r,
    float bg_g,
    float bg_b,
    float bg_a,
    float tint_r,
    float tint_g,
    float tint_b,
    float tint_a
) {
    if (!g_imgui_initialized || texture == nullptr) {
        return false;
    }
    const std::string owned_id = make_string(id, id_len);
    return ImGui::ImageButton(
        owned_id.c_str(),
        reinterpret_cast<ImTextureID>(texture),
        ImVec2(width, height),
        ImVec2(0.0f, 0.0f),
        ImVec2(1.0f, 1.0f),
        ImVec4(bg_r, bg_g, bg_b, bg_a),
        ImVec4(tint_r, tint_g, tint_b, tint_a)
    );
}

extern "C" bool guava_imgui_invisible_button(const char* id, size_t id_len, float width, float height) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_id = make_string(id, id_len);
    return ImGui::InvisibleButton(owned_id.c_str(), ImVec2(width, height));
}

extern "C" bool guava_imgui_window_control_button(uint32_t kind, bool toggled) {
    if (!g_imgui_initialized) {
        return false;
    }

    const float height = ImGui::GetFrameHeight();
    const ImVec2 size(height * 1.42f, height * 0.9f);
    const float rounding = 6.0f;
    ImGui::PushID(static_cast<int>(kind));
    const bool clicked = ImGui::InvisibleButton("##window_control", size);

    const bool hovered = ImGui::IsItemHovered();
    const bool active = ImGui::IsItemActive();
    const ImRect rect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    ImU32 bg_color = IM_COL32(0, 0, 0, 0);
    ImU32 border_color = IM_COL32(136, 150, 172, 42);
    if (kind == GUAVA_IMGUI_WINDOW_CONTROL_CLOSE) {
        if (active) {
            bg_color = IM_COL32(172, 44, 49, 255);
            border_color = IM_COL32(217, 111, 116, 110);
        } else if (hovered) {
            bg_color = IM_COL32(208, 64, 72, 245);
            border_color = IM_COL32(242, 149, 152, 120);
        }
    } else {
        if (active) {
            bg_color = IM_COL32(82, 92, 112, 176);
            border_color = IM_COL32(168, 180, 198, 92);
        } else if (hovered) {
            bg_color = IM_COL32(60, 71, 88, 132);
            border_color = IM_COL32(160, 174, 194, 88);
        } else {
            bg_color = IM_COL32(255, 255, 255, 8);
        }
    }

    if ((bg_color & IM_COL32_A_MASK) != 0) {
        draw_list->AddRectFilled(rect.Min, rect.Max, bg_color, rounding);
    }
    if ((border_color & IM_COL32_A_MASK) != 0) {
        draw_list->AddRect(rect.Min, rect.Max, border_color, rounding);
    }

    const ImU32 icon_color = hovered || active
        ? IM_COL32(245, 247, 250, 255)
        : IM_COL32(176, 188, 207, 212);
    draw_window_control_icon(draw_list, rect, kind, toggled, icon_color);

    ImGui::PopID();
    return clicked;
}

extern "C" void guava_imgui_dummy(float width, float height) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::Dummy(ImVec2(width, height));
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

extern "C" void guava_imgui_set_next_item_width(float width) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetNextItemWidth(width);
}

extern "C" void guava_imgui_set_next_window_pos(float x, float y) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetNextWindowPos(ImVec2(x, y));
}

extern "C" void guava_imgui_set_next_window_size(float width, float height) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetNextWindowSize(ImVec2(width, height));
}

extern "C" void guava_imgui_push_style_color(uint32_t slot, float r, float g, float b, float a) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PushStyleColor(to_imgui_style_color(slot), ImVec4(r, g, b, a));
}

extern "C" void guava_imgui_pop_style_color(int32_t count) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PopStyleColor(count);
}

extern "C" void guava_imgui_push_style_var_float(uint32_t slot, float value) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PushStyleVar(to_imgui_style_var(slot), value);
}

extern "C" void guava_imgui_push_style_var_vec2(uint32_t slot, float x, float y) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PushStyleVar(to_imgui_style_var(slot), ImVec2(x, y));
}

extern "C" void guava_imgui_pop_style_var(int32_t count) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PopStyleVar(count);
}

extern "C" bool guava_imgui_begin_child(const char* id, size_t id_len, float width, float height, bool border) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_id = make_string(id, id_len);
    return ImGui::BeginChild(owned_id.c_str(), ImVec2(width, height), border);
}

extern "C" void guava_imgui_end_child(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::EndChild();
}

extern "C" bool guava_imgui_begin_table(const char* id, size_t id_len, int32_t columns) {
    if (!g_imgui_initialized || columns <= 0) {
        return false;
    }
    const std::string owned_id = make_string(id, id_len);
    constexpr ImGuiTableFlags flags =
        ImGuiTableFlags_RowBg |
        ImGuiTableFlags_SizingStretchProp |
        ImGuiTableFlags_Resizable;
    return ImGui::BeginTable(owned_id.c_str(), columns, flags);
}

extern "C" void guava_imgui_end_table(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::EndTable();
}

extern "C" void guava_imgui_table_setup_column(const char* label, size_t label_len, bool stretch, float init_width_or_weight) {
    if (!g_imgui_initialized) {
        return;
    }
    const std::string owned_label = make_string(label, label_len);
    const ImGuiTableColumnFlags flags = stretch ? ImGuiTableColumnFlags_WidthStretch : ImGuiTableColumnFlags_WidthFixed;
    ImGui::TableSetupColumn(owned_label.c_str(), flags, init_width_or_weight);
}

extern "C" void guava_imgui_table_headers_row(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TableHeadersRow();
}

extern "C" void guava_imgui_table_next_row(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TableNextRow();
}

extern "C" void guava_imgui_table_next_column(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TableNextColumn();
}

extern "C" bool guava_imgui_selectable(const char* label, size_t label_len, bool selected, bool span_all_columns, float width, float height) {
    if (!g_imgui_initialized) {
        return false;
    }
    const std::string owned_label = make_string(label, label_len);
    ImGuiSelectableFlags flags = ImGuiSelectableFlags_None;
    if (span_all_columns) {
        flags |= ImGuiSelectableFlags_SpanAllColumns;
    }
    return ImGui::Selectable(owned_label.c_str(), selected, flags, ImVec2(width, height));
}

extern "C" void guava_imgui_text(const char* text, size_t text_len) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::TextUnformatted(text, text + text_len);
}

extern "C" void guava_imgui_text_wrapped(const char* text, size_t text_len) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(text, text + text_len);
    ImGui::PopTextWrapPos();
}

extern "C" void guava_imgui_label_text(const char* label, size_t label_len, const char* text, size_t text_len) {
    if (!g_imgui_initialized) {
        return;
    }
    const std::string owned_label = make_string(label, label_len);
    const std::string owned_text = make_string(text, text_len);
    ImGui::TextUnformatted(owned_label.c_str());
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.7f, 0.7f, 0.7f, 1.0f));
    ImGui::TextWrapped("%s", owned_text.c_str());
    ImGui::PopStyleColor();
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

extern "C" uint32_t guava_imgui_tree_node_entity(
    uint64_t id,
    const char* label,
    size_t label_len,
    SDL_GPUTexture* icon_texture,
    float icon_size,
    bool selected,
    bool leaf,
    bool default_open,
    char* rename_buffer,
    size_t rename_buffer_size,
    bool request_rename_focus
) {
    if (!g_imgui_initialized) {
        return 0;
    }

    const ImVec2 cursor = ImGui::GetCursorScreenPos();
    const ImGuiStyle& style = ImGui::GetStyle();
    const float row_height = ImGui::GetFrameHeight();
    const float row_pitch = row_height + style.ItemSpacing.y;
    const float window_top = ImGui::GetWindowPos().y + style.WindowPadding.y;
    const int row_index = static_cast<int>((cursor.y - window_top) / (row_pitch > 0.0f ? row_pitch : 1.0f));
    const ImVec2 row_min(ImGui::GetWindowPos().x + ImGui::GetWindowContentRegionMin().x, cursor.y);
    const ImVec2 row_max(ImGui::GetWindowPos().x + ImGui::GetWindowContentRegionMax().x, cursor.y + row_height);
    if ((row_index & 1) != 0) {
        ImGui::GetWindowDrawList()->AddRectFilled(row_min, row_max, IM_COL32(255, 255, 255, 8), 4.0f);
    }

    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_OpenOnArrow | ImGuiTreeNodeFlags_OpenOnDoubleClick | ImGuiTreeNodeFlags_SpanFullWidth | ImGuiTreeNodeFlags_FramePadding;
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
    const bool is_open = ImGui::TreeNodeEx(reinterpret_cast<void*>(static_cast<uintptr_t>(id)), flags, "%s", "");
    uint32_t result = 0;
    if (is_open) {
        result |= GUAVA_IMGUI_TREE_NODE_OPEN;
    }
    if (ImGui::IsItemClicked()) {
        result |= GUAVA_IMGUI_TREE_NODE_CLICKED;
    }
    const ImRect rect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    const float label_x = rect.Min.x + ImGui::GetTreeNodeToLabelSpacing();
    float text_x = label_x;
    if (icon_texture != nullptr && icon_size > 0.0f) {
        const float draw_size = (std::min)(icon_size, rect.GetHeight() - 4.0f);
        const ImVec2 icon_min(label_x, rect.Min.y + (rect.GetHeight() - draw_size) * 0.5f);
        const ImVec2 icon_max(icon_min.x + draw_size, icon_min.y + draw_size);
        ImGui::GetWindowDrawList()->AddImage(reinterpret_cast<ImTextureID>(icon_texture), icon_min, icon_max);
        text_x += draw_size + 6.0f;
    }
    if (rename_buffer != nullptr && rename_buffer_size > 0) {
        const ImVec2 input_pos(text_x - 4.0f, rect.Min.y + 1.0f);
        const float input_width = (std::max)(rect.Max.x - input_pos.x - style.FramePadding.x, 72.0f);
        ImGui::SetCursorScreenPos(input_pos);
        ImGui::SetNextItemWidth(input_width);
        ImGui::PushID(reinterpret_cast<void*>(static_cast<uintptr_t>(id)));
        if (request_rename_focus) {
            ImGui::SetKeyboardFocusHere();
        }
        const bool submitted = ImGui::InputText(
            "##rename",
            rename_buffer,
            rename_buffer_size,
            ImGuiInputTextFlags_AutoSelectAll | ImGuiInputTextFlags_EnterReturnsTrue
        );
        const bool deactivated_after_edit = ImGui::IsItemDeactivatedAfterEdit();
        const bool rename_finished = submitted || ImGui::IsItemDeactivated();
        if (submitted || deactivated_after_edit) {
            result |= GUAVA_IMGUI_TREE_NODE_RENAME_COMMITTED;
        }
        if (rename_finished) {
            result |= GUAVA_IMGUI_TREE_NODE_RENAME_FINISHED;
        }
        ImGui::PopID();
    } else {
        const float text_y = rect.Min.y + (rect.GetHeight() - ImGui::GetFontSize()) * 0.5f;
        ImGui::GetWindowDrawList()->AddText(
            ImVec2(text_x, text_y),
            ImGui::GetColorU32(ImGuiCol_Text),
            owned_label.c_str()
        );
    }
    if (selected) {
        const float pulse = 0.5f + 0.5f * std::sin(ImGui::GetTime() * 3.8f);
        const int glow_alpha = 68 + static_cast<int>(pulse * 72.0f);
        ImGui::GetWindowDrawList()->AddRect(
            rect.Min,
            rect.Max,
            IM_COL32(114, 170, 255, glow_alpha),
            4.0f,
            0,
            1.6f
        );
        ImGui::GetWindowDrawList()->AddRect(
            ImVec2(rect.Min.x - 1.0f, rect.Min.y - 1.0f),
            ImVec2(rect.Max.x + 1.0f, rect.Max.y + 1.0f),
            IM_COL32(88, 144, 255, glow_alpha / 2),
            5.0f,
            0,
            2.2f
        );
    }
    return result;
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

extern "C" bool guava_imgui_is_item_active(void) {
    if (!g_imgui_initialized) {
        return false;
    }
    return ImGui::IsItemActive();
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

extern "C" void guava_imgui_set_cursor_pos(float x, float y) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetCursorPos(ImVec2(x, y));
}

extern "C" void guava_imgui_set_cursor_pos_y(float y) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetCursorPosY(y);
}

extern "C" void guava_imgui_align_text_to_frame_padding(void) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::AlignTextToFramePadding();
}

extern "C" void guava_imgui_get_window_size(float out_value[2]) {
    if (!g_imgui_initialized) {
        out_value[0] = 0.0f;
        out_value[1] = 0.0f;
        return;
    }
    const ImVec2 value = ImGui::GetWindowSize();
    out_value[0] = value.x;
    out_value[1] = value.y;
}

extern "C" float guava_imgui_get_frame_height(void) {
    if (!g_imgui_initialized) {
        return 0.0f;
    }
    return ImGui::GetFrameHeight();
}

extern "C" float guava_imgui_get_time(void) {
    if (!g_imgui_initialized) {
        return 0.0f;
    }
    return static_cast<float>(ImGui::GetTime());
}

extern "C" void guava_imgui_set_scroll_here_y(float center_y_ratio) {
    if (!g_imgui_initialized) {
        return;
    }
    ImGui::SetScrollHereY(center_y_ratio);
}

extern "C" void guava_imgui_image(SDL_GPUTexture* texture, float width, float height) {
    if (!g_imgui_initialized || texture == nullptr) {
        return;
    }
    ImGui::Image((ImTextureID)(intptr_t)texture, ImVec2(width, height));
}
