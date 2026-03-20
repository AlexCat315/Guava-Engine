const std = @import("std");

pub const CompileResult = union(enum) {
    success: Artifact,
    compile_error: []u8,

    pub fn deinit(self: *CompileResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*artifact| artifact.deinit(allocator),
            .compile_error => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const Artifact = struct {
    bytecode: []u8,
    wrapper_source: []u8,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        allocator.free(self.wrapper_source);
        self.* = undefined;
    }
};

pub const CompileOptions = struct {
    source: []const u8,
    script_name: []const u8 = "ai_script",
};

pub fn compileZigSourceAlloc(
    allocator: std.mem.Allocator,
    options: CompileOptions,
) !CompileResult {
    const wrapper_source = try buildWrapperSourceAlloc(allocator, options.source);
    errdefer allocator.free(wrapper_source);

    const cache_dir_path = "zig-cache/guava/wasm_scripts";
    try std.fs.cwd().makePath(cache_dir_path);

    const stamp = std.time.microTimestamp();
    const safe_name = sanitizeName(options.script_name);
    const wrapper_path = try std.fmt.allocPrint(allocator, "{s}/{s}_{d}.zig", .{ cache_dir_path, safe_name, stamp });
    defer allocator.free(wrapper_path);
    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/{s}_{d}.wasm", .{ cache_dir_path, safe_name, stamp });
    defer allocator.free(wasm_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{wasm_path});
    defer allocator.free(emit_arg);

    try std.fs.cwd().writeFile(.{
        .sub_path = wrapper_path,
        .data = wrapper_source,
    });
    defer std.fs.cwd().deleteFile(wrapper_path) catch {};
    defer std.fs.cwd().deleteFile(wasm_path) catch {};

    const argv = [_][]const u8{
        "zig",
        "build-lib",
        wrapper_path,
        "-target",
        "wasm32-freestanding",
        "-dynamic",
        "-O",
        "ReleaseFast",
        emit_arg,
    };

    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) {
                return .{
                    .compile_error = try dupeDiagnosticsAlloc(allocator, run_result.stderr, run_result.stdout),
                };
            }
        },
        else => {
            return .{
                .compile_error = try dupeDiagnosticsAlloc(allocator, run_result.stderr, run_result.stdout),
            };
        },
    }

    const bytecode = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 8 * 1024 * 1024);
    return .{
        .success = .{
            .bytecode = bytecode,
            .wrapper_source = wrapper_source,
        },
    };
}

fn buildWrapperSourceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return try std.mem.concat(allocator, u8, &.{
        \\const std = @import("std");
        \\
        \\extern "env" fn host_get_entity_id() u32;
        \\extern "env" fn host_find_entity_by_name(ptr: [*]const u8, len: u32) u32;
        \\extern "env" fn host_log(ptr: [*]const u8, len: u32) void;
        \\extern "env" fn host_set_local_transform(entity_id: u32, tx: f32, ty: f32, tz: f32, rx: f32, ry: f32, rz: f32, rw: f32, sx: f32, sy: f32, sz: f32) u32;
        \\extern "env" fn host_set_local_translation(entity_id: u32, tx: f32, ty: f32, tz: f32) u32;
        \\extern "env" fn host_set_local_rotation(entity_id: u32, rx: f32, ry: f32, rz: f32, rw: f32) u32;
        \\extern "env" fn host_set_local_scale(entity_id: u32, sx: f32, sy: f32, sz: f32) u32;
        \\extern "env" fn host_set_visible(entity_id: u32, visible: u32) u32;
        \\extern "env" fn host_report_panic(ptr: [*]const u8, len: u32) void;
        \\
        \\pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
        \\    host_report_panic(msg.ptr, @as(u32, @intCast(msg.len)));
        \\    unreachable;
        \\}
        \\
        \\pub const GuavaApi = struct {
        \\    pub const Transform = struct {
        \\        translation: [3]f32 = .{ 0.0, 0.0, 0.0 },
        \\        rotation: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
        \\        scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
        \\    };
        \\
        \\    pub fn entityId() u32 {
        \\        return host_get_entity_id();
        \\    }
        \\
        \\    pub fn findEntityByName(name: []const u8) ?u32 {
        \\        const found = host_find_entity_by_name(name.ptr, @as(u32, @intCast(name.len)));
        \\        return if (found == 0) null else found;
        \\    }
        \\
        \\    pub fn log(message: []const u8) void {
        \\        host_log(message.ptr, @as(u32, @intCast(message.len)));
        \\    }
        \\
        \\    pub fn setLocalTransform(entity_id: u32, transform: Transform) bool {
        \\        return host_set_local_transform(
        \\            entity_id,
        \\            transform.translation[0],
        \\            transform.translation[1],
        \\            transform.translation[2],
        \\            transform.rotation[0],
        \\            transform.rotation[1],
        \\            transform.rotation[2],
        \\            transform.rotation[3],
        \\            transform.scale[0],
        \\            transform.scale[1],
        \\            transform.scale[2],
        \\        ) != 0;
        \\    }
        \\
        \\    pub fn setPosition(position: [3]f32) bool {
        \\        return setEntityPosition(entityId(), position);
        \\    }
        \\
        \\    pub fn setEntityPosition(entity_id: u32, position: [3]f32) bool {
        \\        return host_set_local_translation(entity_id, position[0], position[1], position[2]) != 0;
        \\    }
        \\
        \\    pub fn setRotation(rotation: [4]f32) bool {
        \\        return setEntityRotation(entityId(), rotation);
        \\    }
        \\
        \\    pub fn setEntityRotation(entity_id: u32, rotation: [4]f32) bool {
        \\        return host_set_local_rotation(entity_id, rotation[0], rotation[1], rotation[2], rotation[3]) != 0;
        \\    }
        \\
        \\    pub fn setScale(scale: [3]f32) bool {
        \\        return setEntityScale(entityId(), scale);
        \\    }
        \\
        \\    pub fn setEntityScale(entity_id: u32, scale: [3]f32) bool {
        \\        return host_set_local_scale(entity_id, scale[0], scale[1], scale[2]) != 0;
        \\    }
        \\
        \\    pub fn setVisible(visible: bool) bool {
        \\        return setEntityVisible(entityId(), visible);
        \\    }
        \\
        \\    pub fn setEntityVisible(entity_id: u32, visible: bool) bool {
        \\        return host_set_visible(entity_id, if (visible) 1 else 0) != 0;
        \\    }
        \\};
        \\
        \\const user = struct {
        \\    const guava = GuavaApi;
        \\
        ,
        source,
        \\
        \\};
        \\
        \\export fn guava_on_init() void {
        \\    if (@hasDecl(user, "onInit")) {
        \\        user.onInit();
        \\    }
        \\}
        \\
        \\export fn guava_on_update(dt: f32) void {
        \\    if (@hasDecl(user, "onUpdate")) {
        \\        user.onUpdate(dt);
        \\    }
        \\}
        \\
        \\export fn guava_on_destroy() void {
        \\    if (@hasDecl(user, "onDestroy")) {
        \\        user.onDestroy();
        \\    }
        \\}
        \\
    });
}

fn sanitizeName(name: []const u8) []const u8 {
    if (name.len == 0) {
        return "ai_script";
    }
    return name;
}

fn dupeDiagnosticsAlloc(allocator: std.mem.Allocator, stderr_bytes: []const u8, stdout_bytes: []const u8) ![]u8 {
    const stderr_trimmed = std.mem.trim(u8, stderr_bytes, "\r\n\t ");
    if (stderr_trimmed.len != 0) {
        return try allocator.dupe(u8, stderr_trimmed);
    }
    const stdout_trimmed = std.mem.trim(u8, stdout_bytes, "\r\n\t ");
    if (stdout_trimmed.len != 0) {
        return try allocator.dupe(u8, stdout_trimmed);
    }
    return try allocator.dupe(u8, "unknown wasm compilation failure");
}
