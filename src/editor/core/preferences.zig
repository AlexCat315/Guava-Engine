const std = @import("std");
const gui = @import("../ui/gui.zig");
const state_mod = @import("state.zig");

const EditorState = state_mod.EditorState;
const AiProviderType = state_mod.AiProviderType;
const max_ai_providers = state_mod.max_ai_providers;

const prefs_file_name = "ai_provider_settings.json";
const max_prefs_file_size: usize = 256 * 1024;

const PersistedProvider = struct {
    name: []const u8 = "",
    endpoint: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
};

const PersistedPrefs = struct {
    version: u32 = 1,
    provider_type: []const u8 = "openai",
    active_provider: usize = 0,
    providers: []const PersistedProvider = &.{},
};

const ProviderDefaults = struct {
    endpoint: []const u8,
    model: []const u8,
};

const provider_defaults = [_]ProviderDefaults{
    .{ .endpoint = "https://api.openai.com/v1/chat/completions", .model = "gpt-4o" },
    .{ .endpoint = "https://api.anthropic.com/v1/messages", .model = "claude-sonnet-4-20250514" },
    .{ .endpoint = "http://localhost:11434/api/chat", .model = "llama3.2" },
    .{ .endpoint = "", .model = "" },
};

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..len];
}

fn writeFixedBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) return;
    const copy_len = @min(buffer.len - 1, value.len);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
}

fn providerIsEmpty(provider: PersistedProvider) bool {
    return provider.name.len == 0 and
        provider.endpoint.len == 0 and
        provider.model.len == 0 and
        provider.api_key.len == 0;
}

fn trimSpace(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, " \t\r\n");
}

fn looksLikeGeneratedProviderName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(name, "new provider")) return true;
    return std.mem.startsWith(u8, name, "Provider ");
}

fn providerLooksLikePlaceholder(provider: PersistedProvider, provider_type: AiProviderType) bool {
    if (providerIsEmpty(provider)) return true;

    const name = trimSpace(provider.name);
    const endpoint = trimSpace(provider.endpoint);
    const model = trimSpace(provider.model);
    const api_key = trimSpace(provider.api_key);
    const defaults = provider_defaults[@intFromEnum(provider_type)];

    const endpoint_is_default_or_empty = endpoint.len == 0 or std.mem.eql(u8, endpoint, defaults.endpoint);
    const model_is_default_or_empty = model.len == 0 or std.mem.eql(u8, model, defaults.model);

    return looksLikeGeneratedProviderName(name) and
        endpoint_is_default_or_empty and
        model_is_default_or_empty and
        api_key.len == 0;
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

    for (persisted_providers, 0..) |*provider, index| {
        const source = state.ai_providers[index];
        provider.* = .{
            .name = fixedBufferSlice(source.name[0..]),
            .endpoint = fixedBufferSlice(source.endpoint[0..]),
            .model = fixedBufferSlice(source.model[0..]),
            .api_key = fixedBufferSlice(source.api_key[0..]),
        };
    }

    const payload = PersistedPrefs{
        .provider_type = @tagName(state.ai_provider_type),
        .active_provider = @min(state.ai_active_provider, provider_count - 1),
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
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(output.items);
}

fn loadAiProviderSettingsFromPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return error.AllocatorNotInitialized;

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, max_prefs_file_size) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PersistedPrefs, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const doc = parsed.value;
    const parsed_type = std.meta.stringToEnum(AiProviderType, doc.provider_type) orelse .openai;
    state.ai_provider_type = parsed_type;

    @memset(&state.ai_providers, .{});
    state.ai_provider_count = 0;

    const persisted_count = @min(doc.providers.len, max_ai_providers);
    var meaningful_count: usize = 0;
    for (doc.providers[0..persisted_count]) |provider| {
        if (!providerLooksLikePlaceholder(provider, parsed_type)) {
            meaningful_count += 1;
        }
    }
    const collapse_placeholder_tail = meaningful_count == 0 and persisted_count > 1;

    var resolved_active_provider: usize = 0;
    var resolved_active_found = false;
    for (doc.providers[0..persisted_count], 0..) |provider, source_index| {
        if (collapse_placeholder_tail and providerLooksLikePlaceholder(provider, parsed_type) and state.ai_provider_count > 0) {
            continue;
        }
        if (state.ai_provider_count >= max_ai_providers) break;
        const index = state.ai_provider_count;
        writeFixedBuffer(state.ai_providers[index].name[0..], provider.name);
        writeFixedBuffer(state.ai_providers[index].endpoint[0..], provider.endpoint);
        writeFixedBuffer(state.ai_providers[index].model[0..], provider.model);
        writeFixedBuffer(state.ai_providers[index].api_key[0..], provider.api_key);
        if (source_index == doc.active_provider) {
            resolved_active_provider = index;
            resolved_active_found = true;
        }
        state.ai_provider_count += 1;
    }

    if (state.ai_provider_count == 0) {
        state.ai_provider_count = 1;
    }
    if (resolved_active_found) {
        state.ai_active_provider = resolved_active_provider;
    } else {
        state.ai_active_provider = @min(doc.active_provider, state.ai_provider_count - 1);
    }
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
