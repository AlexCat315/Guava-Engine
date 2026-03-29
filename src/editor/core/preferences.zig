const std = @import("std");
const gui = @import("../ui/gui.zig");
const provider_support = @import("../ui/panels/ai/provider_support.zig");
const state_mod = @import("state.zig");

const EditorState = state_mod.EditorState;
const AiProviderType = state_mod.AiProviderType;
const max_ai_providers = state_mod.max_ai_providers;

const prefs_file_name = "ai_provider_settings.json";
const max_prefs_file_size: usize = 256 * 1024;

const PersistedProvider = struct {
    provider_type: ?[]const u8 = null,
    name: []const u8 = "",
    endpoint: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
};

const PersistedPrefs = struct {
    version: u32 = 2,
    provider_type: []const u8 = "openai",
    active_provider: usize = 0,
    providers: []const PersistedProvider = &.{},
};

const ProviderDefaults = struct {
    endpoint: []const u8,
    model: []const u8,
};

const provider_defaults = [_]ProviderDefaults{
    .{ .endpoint = "https://api.openai.com/v1/responses", .model = "gpt-4o" },
    .{ .endpoint = "https://api.anthropic.com/v1/messages", .model = "claude-sonnet-4-20250514" },
    .{ .endpoint = "http://localhost:11434/api/chat", .model = "llama3.2" },
    .{ .endpoint = "", .model = "" },
};

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    return provider_support.fixedBufferSlice(buffer);
}

fn persistedFieldSlice(value: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
    return value[0..len];
}

fn writeFixedBuffer(buffer: []u8, value: []const u8) void {
    provider_support.writeFixedBuffer(buffer, value);
}

fn providerIsEmpty(provider: PersistedProvider) bool {
    return trimSpace(persistedFieldSlice(provider.name)).len == 0 and
        trimSpace(persistedFieldSlice(provider.endpoint)).len == 0 and
        trimSpace(persistedFieldSlice(provider.model)).len == 0 and
        trimSpace(persistedFieldSlice(provider.api_key)).len == 0;
}

fn trimSpace(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, " \t\r\n");
}

fn looksLikeGeneratedProviderName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(name, "new provider")) return true;
    if (std.ascii.eqlIgnoreCase(name, "openai")) return true;
    if (std.ascii.eqlIgnoreCase(name, "anthropic")) return true;
    if (std.ascii.eqlIgnoreCase(name, "ollama")) return true;
    if (std.ascii.eqlIgnoreCase(name, "custom")) return true;
    if (name.len >= 9 and std.ascii.eqlIgnoreCase(name[0..9], "provider ")) return true;
    if (std.mem.eql(u8, name, "新代理")) return true;
    if (std.mem.startsWith(u8, name, "代理 ")) return true;
    return false;
}

fn endpointLooksLikeAnyDefault(endpoint: []const u8) bool {
    if (endpoint.len == 0) return true;
    for (provider_defaults) |defaults| {
        if (defaults.endpoint.len == 0) continue;
        if (std.mem.eql(u8, endpoint, defaults.endpoint)) return true;
    }
    return false;
}

fn modelLooksLikeAnyDefault(model: []const u8) bool {
    if (model.len == 0) return true;
    for (provider_defaults) |defaults| {
        if (defaults.model.len == 0) continue;
        if (std.mem.eql(u8, model, defaults.model)) return true;
    }
    return false;
}

fn providerLooksLikePlaceholder(provider: PersistedProvider, provider_type: AiProviderType) bool {
    if (providerIsEmpty(provider)) return true;

    const name = trimSpace(persistedFieldSlice(provider.name));
    const endpoint = trimSpace(persistedFieldSlice(provider.endpoint));
    const model = trimSpace(persistedFieldSlice(provider.model));
    const api_key = trimSpace(persistedFieldSlice(provider.api_key));

    // Only treat as placeholder when ALL fields are truly empty or auto-generated.
    // A provider with a custom endpoint or model is user-configured and must be preserved.
    if (!looksLikeGeneratedProviderName(name)) return false;
    if (endpoint.len > 0 and !endpointLooksLikeAnyDefault(endpoint)) return false;
    if (model.len > 0 and !modelLooksLikeAnyDefault(model)) return false;

    _ = provider_type;
    return endpoint.len == 0 and model.len == 0 and api_key.len == 0;
}

fn providerHasCompleteConfig(provider: *const state_mod.AiProviderConfig, provider_type: AiProviderType) bool {
    const endpoint = trimSpace(fixedBufferSlice(provider.endpoint[0..]));
    const model = trimSpace(fixedBufferSlice(provider.model[0..]));
    const api_key = trimSpace(fixedBufferSlice(provider.api_key[0..]));

    if (endpoint.len == 0 or model.len == 0) return false;
    if (provider_type != .ollama and api_key.len == 0) return false;
    return true;
}

fn persistedProviderType(provider: PersistedProvider, fallback: AiProviderType) AiProviderType {
    const resolved = provider.provider_type orelse return fallback;
    return std.meta.stringToEnum(AiProviderType, resolved) orelse fallback;
}

fn prefsPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const pref_path = try gui.editorPrefPathAlloc(allocator);
    defer allocator.free(pref_path);
    return std.fs.path.join(allocator, &.{ pref_path, prefs_file_name });
}

fn saveAiProviderSettingsToPath(state: *const EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const provider_count = @max(@as(usize, 1), @min(state.ai_provider_count, max_ai_providers));
    const persisted_providers = try allocator.alloc(PersistedProvider, provider_count);
    defer allocator.free(persisted_providers);

    var has_meaningful_provider = false;
    for (persisted_providers, 0..) |*provider, index| {
        const source = state.ai_providers[index];
        provider.* = .{
            .provider_type = @tagName(source.provider_type),
            .name = fixedBufferSlice(source.name[0..]),
            .endpoint = fixedBufferSlice(source.endpoint[0..]),
            .model = fixedBufferSlice(source.model[0..]),
            .api_key = fixedBufferSlice(source.api_key[0..]),
        };
        if (!providerLooksLikePlaceholder(provider.*, source.provider_type)) {
            has_meaningful_provider = true;
        }
    }

    if (!has_meaningful_provider) {
        return;
    }

    const active_provider_index = @min(state.ai_active_provider, provider_count - 1);
    const active_provider_type = state.ai_providers[active_provider_index].provider_type;

    const payload = PersistedPrefs{
        .provider_type = @tagName(active_provider_type),
        .active_provider = active_provider_index,
        .providers = persisted_providers,
    };

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();

    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(output.items);
    file.sync() catch {};

    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(tmp_path, path);
}

fn loadAiProviderSettingsFromPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_prefs_file_size);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PersistedPrefs, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const doc = parsed.value;
    const parsed_type = std.meta.stringToEnum(AiProviderType, doc.provider_type) orelse .openai;

    @memset(&state.ai_providers, .{});
    state.ai_provider_count = 0;

    const persisted_count = @min(doc.providers.len, max_ai_providers);
    var meaningful_count: usize = 0;
    for (doc.providers[0..persisted_count]) |provider| {
        const provider_type = persistedProviderType(provider, parsed_type);
        if (!providerLooksLikePlaceholder(provider, provider_type)) {
            meaningful_count += 1;
        }
    }
    const collapse_placeholder_tail = meaningful_count == 0 and persisted_count > 1;

    var resolved_active_provider: usize = 0;
    var resolved_active_found = false;
    for (doc.providers[0..persisted_count], 0..) |provider, source_index| {
        const provider_type = persistedProviderType(provider, parsed_type);
        if (collapse_placeholder_tail and providerLooksLikePlaceholder(provider, provider_type) and state.ai_provider_count > 0) {
            continue;
        }
        if (state.ai_provider_count >= max_ai_providers) break;
        const index = state.ai_provider_count;
        state.ai_providers[index].provider_type = provider_type;
        writeFixedBuffer(state.ai_providers[index].name[0..], persistedFieldSlice(provider.name));
        writeFixedBuffer(state.ai_providers[index].endpoint[0..], persistedFieldSlice(provider.endpoint));
        writeFixedBuffer(state.ai_providers[index].model[0..], persistedFieldSlice(provider.model));
        writeFixedBuffer(state.ai_providers[index].api_key[0..], persistedFieldSlice(provider.api_key));
        if (source_index == doc.active_provider) {
            resolved_active_provider = index;
            resolved_active_found = true;
        }
        state.ai_provider_count += 1;
    }

    if (state.ai_provider_count == 0) {
        state.ai_provider_count = 1;
        state.ai_providers[0].provider_type = parsed_type;
    }
    if (resolved_active_found) {
        state.ai_active_provider = resolved_active_provider;
    } else {
        state.ai_active_provider = @min(doc.active_provider, state.ai_provider_count - 1);
    }

    if (!providerHasCompleteConfig(
        &state.ai_providers[state.ai_active_provider],
        state.ai_providers[state.ai_active_provider].provider_type,
    )) {
        for (0..state.ai_provider_count) |index| {
            if (providerHasCompleteConfig(&state.ai_providers[index], state.ai_providers[index].provider_type)) {
                state.ai_active_provider = index;
                break;
            }
        }
    }

    state.ai_provider_type = state.ai_providers[state.ai_active_provider].provider_type;
}

pub fn loadAiProviderSettings(state: *EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator);
    defer allocator.free(path);
    try loadAiProviderSettingsFromPath(state, path);
}

pub fn saveAiProviderSettings(state: *const EditorState) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;
    const path = try prefsPathAlloc(allocator);
    defer allocator.free(path);
    try saveAiProviderSettingsToPath(state, path);
}
