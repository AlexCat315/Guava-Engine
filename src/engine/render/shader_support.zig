const generated_shaders = @import("../generated/shaders.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");

pub const ProgramStages = struct {
    vertex: rhi_mod.ShaderModule,
    fragment: rhi_mod.ShaderModule,

    pub fn deinit(self: *ProgramStages, device: *rhi_mod.RhiDevice) void {
        device.releaseShaderModule(&self.fragment);
        device.releaseShaderModule(&self.vertex);
        self.* = undefined;
    }
};

pub fn loadProgramStages(device: *rhi_mod.RhiDevice, name: []const u8) !ProgramStages {
    const program = generated_shaders.findProgram(name) orelse return error.MissingShaderProgram;
    const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return error.UnsupportedShaderBackend;
    const fragment_variant = program.stageForBackend(device.api, .fragment) orelse return error.UnsupportedShaderBackend;

    const vertex = try device.createShaderModule(.{
        .code = vertex_variant.code,
        .stage = .vertex,
        .format = vertex_variant.format,
        .entry_point = vertex_variant.entry_point,
        .num_samplers = vertex_variant.reflection.num_samplers,
        .num_storage_textures = vertex_variant.reflection.num_storage_textures,
        .num_storage_buffers = vertex_variant.reflection.num_storage_buffers,
        .num_uniform_buffers = vertex_variant.reflection.num_uniform_buffers,
    });
    errdefer {
        var shader = vertex;
        device.releaseShaderModule(&shader);
    }

    const fragment = try device.createShaderModule(.{
        .code = fragment_variant.code,
        .stage = .fragment,
        .format = fragment_variant.format,
        .entry_point = fragment_variant.entry_point,
        .num_samplers = fragment_variant.reflection.num_samplers,
        .num_storage_textures = fragment_variant.reflection.num_storage_textures,
        .num_storage_buffers = fragment_variant.reflection.num_storage_buffers,
        .num_uniform_buffers = fragment_variant.reflection.num_uniform_buffers,
    });
    errdefer {
        var shader = fragment;
        device.releaseShaderModule(&shader);
    }

    return .{
        .vertex = vertex,
        .fragment = fragment,
    };
}
