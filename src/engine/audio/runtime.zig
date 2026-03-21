//! 音频系统运行时
//!
//! 提供高级音频管理 API，包括混音器、音效控制、3D 空间音效、
//! 以及与 ECS 系统的集成。

const std = @import("std");
const world_mod = @import("../scene/world.zig");
const soloud_bindings = @import("./soloud_bindings.zig");

// ============ 类型定义 ============

/// 音频剪辑 ID
pub const AudioClipHandle = u32;

/// 语音句柄（用于控制正在播放的声音）
pub const VoiceHandle = u32;

/// 混音器总线 ID
pub const BusId = enum(u8) {
    /// 主总线
    master = 0,
    /// 音乐总线
    music = 1,
    /// 音效总线
    sfx = 2,
};

/// 音频源播放状态
pub const PlayState = enum {
    stopped,
    playing,
    paused,
};

/// 音频剪辑信息
pub const AudioClipInfo = struct {
    name: []const u8,
    path: []const u8,
    duration_seconds: f32,
    channels: u8,
    sample_rate: u32,
};

/// 音频播放实例（运行中）
pub const PlayingInstance = struct {
    voice_handle: VoiceHandle,
    clip_id: AudioClipHandle,
    bus_id: BusId,
    pos: [3]f32 = .{ 0, 0, 0 },
    is_spatial: bool = false,
    state: PlayState = .playing,
};

/// 混音器信息快照
pub const MixerStatus = struct {
    master_volume: f32,
    music_volume: f32,
    sfx_volume: f32,
    active_voices: u32,
    music_playing: u32,
    sfx_playing: u32,
};

// ============ 全局音频系统 ============

/// 全局音频运行时实例
var audio_system: ?*AudioRuntime = null;

/// 获取全局音频系统
pub fn get() !*AudioRuntime {
    if (audio_system) |sys| {
        return sys;
    }
    return error.AudioSystemNotInitialized;
}

/// 音频系统运行时
pub const AudioRuntime = struct {
    allocator: std.mem.Allocator,
    soloud: *soloud_bindings.Soloud,

    // 混音器总线
    bus_master: ?*soloud_bindings.Bus = null,
    bus_music: ?*soloud_bindings.Bus = null,
    bus_sfx: ?*soloud_bindings.Bus = null,

    // 加载的音频剪辑缓存
    clips: std.AutoHashMap(u32, AudioClip),
    next_clip_id: u32 = 1,

    // 正在播放的实例追踪
    playing_instances: std.ArrayList(PlayingInstance),

    // 混音器音量状态
    master_volume: f32 = 1.0,
    music_volume: f32 = 0.8,
    sfx_volume: f32 = 1.0,

    // 3D 音效参数
    listener_pos: [3]f32 = .{ 0, 0, 0 },
    listener_vel: [3]f32 = .{ 0, 0, 0 },
    sound_speed: f32 = 340.29, // 音速（米/秒）

    /// 初始化音频系统
    pub fn init(allocator: std.mem.Allocator) !*AudioRuntime {
        // 创建 SoLoud 引擎
        const soloud = try soloud_bindings.create();
        errdefer soloud_bindings.destroy(soloud);

        // 初始化 SoLoud
        soloud_bindings.init(soloud) catch |err| {
            std.debug.print("[ERROR] Failed to initialize SoLoud: {}\n", .{err});
            return err;
        };

        // 创建混音器总线
        const bus_master = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_master);

        const bus_music = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_music);

        const bus_sfx = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_sfx);

        // 分配运行时结构
        const runtime = try allocator.create(AudioRuntime);
        errdefer allocator.destroy(runtime);

        runtime.* = .{
            .allocator = allocator,
            .soloud = soloud,
            .bus_master = bus_master,
            .bus_music = bus_music,
            .bus_sfx = bus_sfx,
            .clips = std.AutoHashMap(u32, AudioClip).init(allocator),
            .playing_instances = .empty,
        };

        audio_system = runtime;

        // 输出初始化成功消息
        std.debug.print("[INF] audio: Audio system initialized successfully\n", .{});

        return runtime;
    }

    /// 反初始化音频系统
    pub fn deinit(runtime: *AudioRuntime) void {
        // 停止所有播放
        soloud_bindings.stopAll(runtime.soloud);

        // 销毁所有音频剪辑
        var iter = runtime.clips.valueIterator();
        while (iter.next()) |clip| {
            clip.deinit(runtime.allocator);
        }
        runtime.clips.deinit();

        // 销毁混音器总线
        if (runtime.bus_sfx) |bus| soloud_bindings.busDestroy(bus);
        if (runtime.bus_music) |bus| soloud_bindings.busDestroy(bus);
        if (runtime.bus_master) |bus| soloud_bindings.busDestroy(bus);

        // 反初始化并销毁 SoLoud
        soloud_bindings.deinit(runtime.soloud);
        soloud_bindings.destroy(runtime.soloud);

        // 清理实例列表
        runtime.playing_instances.deinit(runtime.allocator);

        // 销毁运行时结构
        runtime.allocator.destroy(runtime);
        audio_system = null;

        std.debug.print("[INF] audio: Audio system deinitialized\n", .{});
    }

    /// 加载音频剪辑
    pub fn loadClip(
        runtime: *AudioRuntime,
        name: []const u8,
        path: [:0]const u8,
    ) !AudioClipHandle {
        const clip_id = runtime.next_clip_id;
        runtime.next_clip_id += 1;

        const clip = try AudioClip.load(runtime.allocator, name, path);
        try runtime.clips.put(clip_id, clip);

        std.debug.print("[INF] audio: Loaded audio clip '{s}' (id={d})\n", .{ name, clip_id });
        return clip_id;
    }

    /// 卸载音频剪辑
    pub fn unloadClip(runtime: *AudioRuntime, clip_id: AudioClipHandle) void {
        if (runtime.clips.fetchRemove(clip_id)) |kv| {
            kv.value.deinit(runtime.allocator);
            std.debug.print("[INF] audio: Unloaded audio clip (id={d})\n", .{clip_id});
        }
    }

    /// 播放音效 2D（无空间音效）
    pub fn playClip2d(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        volume: f32,
        loop: bool,
    ) !VoiceHandle {
        const clip = runtime.clips.get(clip_id) orelse return error.ClipNotFound;

        const wav = clip.wav;
        soloud_bindings.wavSetLooping(wav, loop);
        soloud_bindings.wavSetAutoStop(wav, !loop);

        const voice = soloud_bindings.playEx(
            runtime.soloud,
            @ptrCast(wav),
            volume,
            0.0, // no pan
            false,
            @intFromEnum(BusId.sfx),
        );

        const instance: PlayingInstance = .{
            .voice_handle = voice,
            .clip_id = clip_id,
            .bus_id = .sfx,
            .is_spatial = false,
        };
        try runtime.playing_instances.append(runtime.allocator, instance);

        return voice;
    }

    /// 播放音效 3D（带空间音效）
    pub fn playClip3d(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        pos: [3]f32,
        volume: f32,
        loop: bool,
    ) !VoiceHandle {
        const clip = runtime.clips.get(clip_id) orelse return error.ClipNotFound;

        const wav = clip.wav;
        soloud_bindings.wavSetLooping(wav, loop);
        soloud_bindings.wavSetAutoStop(wav, !loop);

        const voice = soloud_bindings.play3dEx(
            runtime.soloud,
            @ptrCast(wav),
            pos[0],
            pos[1],
            pos[2],
            0,
            0,
            0, // velocity
            volume,
            false, // not paused
            @intFromEnum(BusId.sfx),
        );

        // 配置 3D 参数
        soloud_bindings.set3dSourceMinMaxDistance(runtime.soloud, voice, 1.0, 100.0);
        soloud_bindings.set3dSourceAttenuation(runtime.soloud, voice, 0, 1.0);

        const instance: PlayingInstance = .{
            .voice_handle = voice,
            .clip_id = clip_id,
            .bus_id = .sfx,
            .pos = pos,
            .is_spatial = true,
        };
        try runtime.playing_instances.append(runtime.allocator, instance);

        return voice;
    }

    /// 停止播放
    pub fn stopVoice(runtime: *AudioRuntime, voice_handle: VoiceHandle) void {
        soloud_bindings.stop(runtime.soloud, voice_handle);

        // 从实例列表中移除
        for (runtime.playing_instances.items, 0..) |instance, i| {
            if (instance.voice_handle == voice_handle) {
                _ = runtime.playing_instances.orderedRemove(i);
                break;
            }
        }
    }

    /// 停止所有播放
    pub fn stopAll(runtime: *AudioRuntime) void {
        soloud_bindings.stopAll(runtime.soloud);
        runtime.playing_instances.clearRetainingCapacity();
    }

    /// 设置语音音量
    pub fn setVoiceVolume(runtime: *AudioRuntime, voice_handle: VoiceHandle, volume: f32) void {
        soloud_bindings.setVolume(runtime.soloud, voice_handle, volume);
    }

    /// 暂停语音
    pub fn pauseVoice(runtime: *AudioRuntime, voice_handle: VoiceHandle, paused: bool) void {
        soloud_bindings.setPause(runtime.soloud, voice_handle, paused);
    }

    /// 设置混音器音量
    pub fn setMixerVolume(runtime: *AudioRuntime, bus_id: BusId, volume: f32) void {
        const bus = switch (bus_id) {
            .master => runtime.bus_master,
            .music => runtime.bus_music,
            .sfx => runtime.bus_sfx,
        };

        if (bus) |b| {
            soloud_bindings.busSetVolume(b, volume);
        }

        switch (bus_id) {
            .master => runtime.master_volume = volume,
            .music => runtime.music_volume = volume,
            .sfx => runtime.sfx_volume = volume,
        }
    }

    /// 获取混音器音量
    pub fn getMixerVolume(runtime: *AudioRuntime, bus_id: BusId) f32 {
        return switch (bus_id) {
            .master => runtime.master_volume,
            .music => runtime.music_volume,
            .sfx => runtime.sfx_volume,
        };
    }

    /// 设置 3D 监听器位置（相机位置）
    pub fn setListenerPosition(runtime: *AudioRuntime, pos: [3]f32, vel: [3]f32) void {
        runtime.listener_pos = pos;
        runtime.listener_vel = vel;

        soloud_bindings.set3dListenerParameters(
            runtime.soloud,
            pos[0],
            pos[1],
            pos[2],
            pos[0],
            pos[1],
            pos[2] - 1, // 向前看
            0,
            1,
            0, // 向上
        );
        soloud_bindings.set3dListenerVelocity(runtime.soloud, vel[0], vel[1], vel[2]);
    }

    /// 更新语音 3D 位置
    pub fn updateVoice3dPosition(
        runtime: *AudioRuntime,
        voice_handle: VoiceHandle,
        pos: [3]f32,
        vel: [3]f32,
    ) void {
        soloud_bindings.set3dSourcePosition(runtime.soloud, voice_handle, pos[0], pos[1], pos[2]);
        soloud_bindings.set3dSourceVelocity(runtime.soloud, voice_handle, vel[0], vel[1], vel[2]);
    }

    /// 从 ECS 世界更新音频（每帧调用）
    pub fn updateFromWorld(runtime: *AudioRuntime, world: *const world_mod.World) void {
        // 更新监听器位置（从相机）
        if (world.primaryCameraEntity()) |camera_id| {
            if (world.getEntityConst(camera_id)) |entity| {
                runtime.setListenerPosition(entity.local_transform.translation, .{ 0, 0, 0 });
            }
        }

        // 更新 3D 音源位置
        for (runtime.playing_instances.items) |*instance| {
            if (instance.is_spatial) {
                // 可以从实体获取位置更新
                // 这里简化处理 - 实际应用中可以关联 AudioSource 实体
                runtime.updateVoice3dPosition(instance.voice_handle, instance.pos, .{ 0, 0, 0 });
            }
        }

        // 更新 3D 音频处理
        soloud_bindings.update3dAudio(runtime.soloud);

        // 清理已停止的语音
        var i: usize = 0;
        while (i < runtime.playing_instances.items.len) {
            const instance = runtime.playing_instances.items[i];
            if (!soloud_bindings.isValidVoiceHandle(runtime.soloud, instance.voice_handle)) {
                _ = runtime.playing_instances.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 获取混音器状态快照
    pub fn getMixerStatus(runtime: *AudioRuntime) MixerStatus {
        const active_voices = soloud_bindings.getActiveVoiceCount(runtime.soloud);

        var music_playing: u32 = 0;
        var sfx_playing: u32 = 0;
        for (runtime.playing_instances.items) |instance| {
            if (soloud_bindings.isValidVoiceHandle(runtime.soloud, instance.voice_handle)) {
                switch (instance.bus_id) {
                    .master => {},
                    .music => music_playing += 1,
                    .sfx => sfx_playing += 1,
                }
            }
        }

        return .{
            .master_volume = runtime.master_volume,
            .music_volume = runtime.music_volume,
            .sfx_volume = runtime.sfx_volume,
            .active_voices = active_voices,
            .music_playing = music_playing,
            .sfx_playing = sfx_playing,
        };
    }
};

// ============ 音频剪辑 ============

/// 音频剪辑封装
pub const AudioClip = struct {
    name: []const u8,
    path: []const u8,
    wav: *soloud_bindings.Wav,

    /// 从文件加载音频剪辑
    pub fn load(
        allocator: std.mem.Allocator,
        name: []const u8,
        path: [:0]const u8,
    ) !AudioClip {
        const wav = try soloud_bindings.wavCreate();
        errdefer soloud_bindings.wavDestroy(wav);

        soloud_bindings.wavLoad(wav, path) catch |err| {
            std.debug.print("[ERROR] Failed to load audio file '{s}': {}\n", .{ path, err });
            return err;
        };

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        return .{
            .name = name_copy,
            .path = path_copy,
            .wav = wav,
        };
    }

    /// 销毁音频剪辑
    pub fn deinit(clip: *const AudioClip, allocator: std.mem.Allocator) void {
        soloud_bindings.wavDestroy(clip.wav);
        allocator.free(clip.name);
        allocator.free(clip.path);
    }
};
