const std = @import("std");
const wasm_vm = @import("./wasm_vm.zig");

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
    parameter_schema: []u8,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        allocator.free(self.wrapper_source);
        allocator.free(self.parameter_schema);
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
    errdefer allocator.free(bytecode);
    const parameter_schema = wasm_vm.reflectParameterSchemaJsonAlloc(allocator, bytecode) catch |err| {
        return .{
            .compile_error = try std.fmt.allocPrint(allocator, "failed to reflect wasm public variables: {s}", .{@errorName(err)}),
        };
    };
    return .{
        .success = .{
            .bytecode = bytecode,
            .wrapper_source = wrapper_source,
            .parameter_schema = parameter_schema,
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
        \\const GuavaParamKind = enum(u8) {
        \\    float = 1,
        \\    boolean = 2,
        \\    integer = 3,
        \\};
        \\
        \\fn guavaSupportedParamKind(comptime decl_name: []const u8) ?GuavaParamKind {
        \\    const pointer_type = @TypeOf(&@field(user, decl_name));
        \\    const pointer_info = @typeInfo(pointer_type);
        \\    if (pointer_info != .pointer or pointer_info.pointer.is_const) {
        \\        return null;
        \\    }
        \\    const child = pointer_info.pointer.child;
        \\    return if (child == f32)
        \\        .float
        \\    else if (child == bool)
        \\        .boolean
        \\    else if (child == i32)
        \\        .integer
        \\    else
        \\        null;
        \\}
        \\
        \\fn guavaParamCount() comptime_int {
        \\    var count: comptime_int = 0;
        \\    inline for (comptime std.meta.declarations(user)) |decl| {
        \\        if (guavaSupportedParamKind(decl.name) != null) {
        \\            count += 1;
        \\        }
        \\    }
        \\    return count;
        \\}
        \\
        \\const guava_param_count_value = guavaParamCount();
        \\
        \\fn guavaParamName(comptime index: usize) []const u8 {
        \\    var current: comptime_int = 0;
        \\    inline for (comptime std.meta.declarations(user)) |decl| {
        \\        if (guavaSupportedParamKind(decl.name) != null) {
        \\            if (current == index) {
        \\                return decl.name;
        \\            }
        \\            current += 1;
        \\        }
        \\    }
        \\    unreachable;
        \\}
        \\
        \\fn guavaParamKindAt(comptime index: usize) GuavaParamKind {
        \\    var current: comptime_int = 0;
        \\    inline for (comptime std.meta.declarations(user)) |decl| {
        \\        if (guavaSupportedParamKind(decl.name)) |kind| {
        \\            if (current == index) {
        \\                return kind;
        \\            }
        \\            current += 1;
        \\        }
        \\    }
        \\    unreachable;
        \\}
        \\
        \\export fn guava_param_count() u32 {
        \\    return guava_param_count_value;
        \\}
        \\
        \\export fn guava_param_name_ptr(index: u32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index) {
        \\            return @as(u32, @intCast(@intFromPtr(guavaParamName(param_index).ptr)));
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_name_len(index: u32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index) {
        \\            return @as(u32, @intCast(guavaParamName(param_index).len));
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_kind(index: u32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index) {
        \\            return @intFromEnum(guavaParamKindAt(param_index));
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_get_f32(index: u32) f32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .float) {
        \\            return @field(user, guavaParamName(param_index));
        \\        }
        \\    }
        \\    return 0.0;
        \\}
        \\
        \\export fn guava_param_set_f32(index: u32, value: f32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .float) {
        \\            @field(user, guavaParamName(param_index)) = value;
        \\            return 1;
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_get_bool(index: u32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .boolean) {
        \\            return if (@field(user, guavaParamName(param_index))) 1 else 0;
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_set_bool(index: u32, value: u32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .boolean) {
        \\            @field(user, guavaParamName(param_index)) = value != 0;
        \\            return 1;
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_get_i32(index: u32) i32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .integer) {
        \\            return @field(user, guavaParamName(param_index));
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export fn guava_param_set_i32(index: u32, value: i32) u32 {
        \\    inline for (0..guava_param_count_value) |param_index| {
        \\        if (index == param_index and guavaParamKindAt(param_index) == .integer) {
        \\            @field(user, guavaParamName(param_index)) = value;
        \\            return 1;
        \\        }
        \\    }
        \\    return 0;
        \\}
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

test "wasm public vars reflect into schema and drive runtime parameters" {
    const script_source =
        \\pub var speed: f32 = 1.5;
        \\pub var enabled: bool = true;
        \\pub var count: i32 = 2;
        \\
        \\pub fn onUpdate(dt: f32) void {
        \\    if (!enabled) return;
        \\    const x = speed * @as(f32, @floatFromInt(count));
        \\    _ = guava.setEntityPosition(guava.entityId(), .{ x, dt, 0.0 });
        \\}
        \\
    ;

    var compile_result = try compileZigSourceAlloc(std.testing.allocator, .{
        .source = script_source,
        .script_name = "reflection_test",
    });
    defer compile_result.deinit(std.testing.allocator);

    const artifact = switch (compile_result) {
        .success => |*artifact| artifact,
        .compile_error => |message| {
            std.debug.print("unexpected wasm compile error: {s}\n", .{message});
            return error.UnexpectedCompileError;
        },
    };

    try std.testing.expect(std.mem.indexOf(u8, artifact.parameter_schema, "\"speed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.parameter_schema, "\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.parameter_schema, "\"count\"") != null);

    const script_resource_mod = @import("../assets/script_resource.zig");
    const command_queue_mod = @import("../core/command_queue.zig");
    const world_mod = @import("../scene/world.zig");
    const context_mod = @import("./context.zig");
    const types = @import("./types.zig");
    const vm_mod = @import("./vm.zig");

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    const entity_id = try world.createEntity(.{ .name = "WasmActor" });

    var queue = command_queue_mod.CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var resource = try script_resource_mod.clone(std.testing.allocator, .{
        .source = script_source,
        .language = .wasm,
        .user_data = artifact.parameter_schema,
    });
    defer script_resource_mod.deinit(&resource, std.testing.allocator);
    resource.bytecode = try std.testing.allocator.dupe(u8, artifact.bytecode);

    const script_vm = try vm_mod.createVM(.wasm, std.testing.allocator);
    defer {
        script_vm.deinit(std.testing.allocator);
        std.testing.allocator.destroy(script_vm);
    }
    try script_vm.load(&resource);

    var bootstrap_instance: types.ScriptInstance = undefined;
    var ctx = context_mod.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = &bootstrap_instance,
        .allocator = std.testing.allocator,
        .command_queue = &queue,
    };
    const instance = try script_vm.createInstance(&ctx);
    defer script_vm.destroyInstance(instance);
    ctx.instance = instance;

    try std.testing.expect(try wasm_vm.applyParameterPayload(
        std.testing.allocator,
        instance,
        artifact.parameter_schema,
        "{\"speed\":4.0,\"enabled\":true,\"count\":3}\n",
    ));

    try script_vm.callUpdate(instance, &ctx, 0.5);
    const first_results = try queue.executeAll(&world);
    defer std.testing.allocator.free(first_results);
    try std.testing.expectEqual(@as(usize, 1), first_results.len);

    const after_first = world.getEntityConst(entity_id).?;
    try std.testing.expectEqual(@as(f32, 12.0), after_first.local_transform.translation[0]);
    try std.testing.expectEqual(@as(f32, 0.5), after_first.local_transform.translation[1]);

    try std.testing.expect(try wasm_vm.applyParameterPayload(
        std.testing.allocator,
        instance,
        artifact.parameter_schema,
        "{\"speed\":9.0,\"enabled\":false,\"count\":8}\n",
    ));

    try script_vm.callUpdate(instance, &ctx, 1.0);
    const second_results = try queue.executeAll(&world);
    defer std.testing.allocator.free(second_results);
    try std.testing.expectEqual(@as(usize, 0), second_results.len);

    const after_second = world.getEntityConst(entity_id).?;
    try std.testing.expectEqual(@as(f32, 12.0), after_second.local_transform.translation[0]);
    try std.testing.expectEqual(@as(f32, 0.5), after_second.local_transform.translation[1]);
}
