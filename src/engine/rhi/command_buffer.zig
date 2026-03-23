const std = @import("std");

pub const Error = error{
    OutOfMemory,
    InvalidOpcode,
    TruncatedStream,
};

pub const OpCode = enum(u8) {
    begin_render_pass,
    end_render_pass,
    begin_compute_pass,
    end_compute_pass,
    begin_copy_pass,
    end_copy_pass,
    set_binding_set,
    set_vertex_buffer,
    set_index_buffer,
    set_pipeline,
    draw_indexed,
    draw_indirect,
    dispatch,
    dispatch_indirect,
    pipeline_barrier,
};

pub const BeginRenderPassCmd = extern struct {
    color_target_id: u32,
    depth_target_id: u32,
    clear_mask: u32,
};

pub const BeginComputePassCmd = extern struct {
    reserved: u32 = 0,
};

pub const BeginCopyPassCmd = extern struct {
    reserved: u32 = 0,
};

pub const SetBindingSetCmd = extern struct {
    slot: u32,
    set_id: u32,
};

pub const SetVertexBufferCmd = extern struct {
    slot: u32,
    buffer_id: u32,
    offset: u32,
};

pub const SetIndexBufferCmd = extern struct {
    buffer_id: u32,
    offset: u32,
    format: u32, // 0 = u16, 1 = u32
};

pub const SetPipelineCmd = extern struct {
    pipeline_id: u32,
};

pub const DrawIndexedCmd = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const DrawIndirectCmd = extern struct {
    buffer_id: u32,
    offset: u32,
    draw_count: u32,
};

pub const DispatchCmd = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const DispatchIndirectCmd = extern struct {
    buffer_id: u32,
    offset: u32,
};

pub const PipelineBarrierCmd = extern struct {
    resource_id: u32,
    src_state_bits: u32,
    dst_state_bits: u32,
    src_queue: u8,
    dst_queue: u8,
    _padding: u16 = 0,
};

pub const DecodedCommand = union(OpCode) {
    begin_render_pass: BeginRenderPassCmd,
    end_render_pass: void,
    begin_compute_pass: BeginComputePassCmd,
    end_compute_pass: void,
    begin_copy_pass: BeginCopyPassCmd,
    end_copy_pass: void,
    set_binding_set: SetBindingSetCmd,
    set_vertex_buffer: SetVertexBufferCmd,
    set_index_buffer: SetIndexBufferCmd,
    set_pipeline: SetPipelineCmd,
    draw_indexed: DrawIndexedCmd,
    draw_indirect: DrawIndirectCmd,
    dispatch: DispatchCmd,
    dispatch_indirect: DispatchIndirectCmd,
    pipeline_barrier: PipelineBarrierCmd,
};

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    opcodes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.opcodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *CommandBuffer) void {
        self.opcodes.clearRetainingCapacity();
    }

    pub fn encodeBeginRenderPass(self: *CommandBuffer, cmd: BeginRenderPassCmd) Error!void {
        try self.writeOp(.begin_render_pass);
        try self.writeStruct(BeginRenderPassCmd, cmd);
    }

    pub fn encodeEndRenderPass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_render_pass);
    }

    pub fn encodeBeginComputePass(self: *CommandBuffer, cmd: BeginComputePassCmd) Error!void {
        try self.writeOp(.begin_compute_pass);
        try self.writeStruct(BeginComputePassCmd, cmd);
    }

    pub fn encodeEndComputePass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_compute_pass);
    }

    pub fn encodeBeginCopyPass(self: *CommandBuffer, cmd: BeginCopyPassCmd) Error!void {
        try self.writeOp(.begin_copy_pass);
        try self.writeStruct(BeginCopyPassCmd, cmd);
    }

    pub fn encodeEndCopyPass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_copy_pass);
    }

    pub fn encodeSetBindingSet(self: *CommandBuffer, cmd: SetBindingSetCmd) Error!void {
        try self.writeOp(.set_binding_set);
        try self.writeStruct(SetBindingSetCmd, cmd);
    }

    pub fn encodeSetVertexBuffer(self: *CommandBuffer, cmd: SetVertexBufferCmd) Error!void {
        try self.writeOp(.set_vertex_buffer);
        try self.writeStruct(SetVertexBufferCmd, cmd);
    }

    pub fn encodeSetIndexBuffer(self: *CommandBuffer, cmd: SetIndexBufferCmd) Error!void {
        try self.writeOp(.set_index_buffer);
        try self.writeStruct(SetIndexBufferCmd, cmd);
    }

    pub fn encodeSetPipeline(self: *CommandBuffer, cmd: SetPipelineCmd) Error!void {
        try self.writeOp(.set_pipeline);
        try self.writeStruct(SetPipelineCmd, cmd);
    }

    pub fn encodeDrawIndexed(self: *CommandBuffer, cmd: DrawIndexedCmd) Error!void {
        try self.writeOp(.draw_indexed);
        try self.writeStruct(DrawIndexedCmd, cmd);
    }

    pub fn encodeDrawIndirect(self: *CommandBuffer, cmd: DrawIndirectCmd) Error!void {
        try self.writeOp(.draw_indirect);
        try self.writeStruct(DrawIndirectCmd, cmd);
    }

    pub fn encodeDispatch(self: *CommandBuffer, cmd: DispatchCmd) Error!void {
        try self.writeOp(.dispatch);
        try self.writeStruct(DispatchCmd, cmd);
    }

    pub fn encodeDispatchIndirect(self: *CommandBuffer, cmd: DispatchIndirectCmd) Error!void {
        try self.writeOp(.dispatch_indirect);
        try self.writeStruct(DispatchIndirectCmd, cmd);
    }

    pub fn encodePipelineBarrier(self: *CommandBuffer, cmd: PipelineBarrierCmd) Error!void {
        try self.writeOp(.pipeline_barrier);
        try self.writeStruct(PipelineBarrierCmd, cmd);
    }

    pub fn decoder(self: *const CommandBuffer) Decoder {
        return Decoder.init(self.opcodes.items);
    }

    fn writeOp(self: *CommandBuffer, op: OpCode) Error!void {
        self.opcodes.append(self.allocator, @intFromEnum(op)) catch return error.OutOfMemory;
    }

    fn writeStruct(self: *CommandBuffer, comptime T: type, value: T) Error!void {
        const bytes = std.mem.asBytes(&value);
        self.opcodes.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Decoder) Error!?DecodedCommand {
        if (self.cursor >= self.bytes.len) return null;

        const raw_op = self.bytes[self.cursor];
        self.cursor += 1;
        const op = std.meta.intToEnum(OpCode, raw_op) catch return error.InvalidOpcode;

        return switch (op) {
            .begin_render_pass => .{ .begin_render_pass = try self.readStruct(BeginRenderPassCmd) },
            .end_render_pass => .{ .end_render_pass = {} },
            .begin_compute_pass => .{ .begin_compute_pass = try self.readStruct(BeginComputePassCmd) },
            .end_compute_pass => .{ .end_compute_pass = {} },
            .begin_copy_pass => .{ .begin_copy_pass = try self.readStruct(BeginCopyPassCmd) },
            .end_copy_pass => .{ .end_copy_pass = {} },
            .set_binding_set => .{ .set_binding_set = try self.readStruct(SetBindingSetCmd) },
            .set_vertex_buffer => .{ .set_vertex_buffer = try self.readStruct(SetVertexBufferCmd) },
            .set_index_buffer => .{ .set_index_buffer = try self.readStruct(SetIndexBufferCmd) },
            .set_pipeline => .{ .set_pipeline = try self.readStruct(SetPipelineCmd) },
            .draw_indexed => .{ .draw_indexed = try self.readStruct(DrawIndexedCmd) },
            .draw_indirect => .{ .draw_indirect = try self.readStruct(DrawIndirectCmd) },
            .dispatch => .{ .dispatch = try self.readStruct(DispatchCmd) },
            .dispatch_indirect => .{ .dispatch_indirect = try self.readStruct(DispatchIndirectCmd) },
            .pipeline_barrier => .{ .pipeline_barrier = try self.readStruct(PipelineBarrierCmd) },
        };
    }

    fn readStruct(self: *Decoder, comptime T: type) Error!T {
        const size = @sizeOf(T);
        const end = self.cursor + size;
        if (end > self.bytes.len) return error.TruncatedStream;
        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), self.bytes[self.cursor..end]);
        self.cursor = end;
        return value;
    }
};

test "decoder readStruct handles unaligned stream" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.append(std.testing.allocator, 0xFF); // intentional misalignment
    const cmd = DrawIndexedCmd{ .index_count = 3, .instance_count = 1, .first_index = 0, .vertex_offset = 0, .first_instance = 0 };
    try bytes.appendSlice(std.testing.allocator, std.mem.asBytes(&cmd));

    var d = Decoder.init(bytes.items[1..]);
    const decoded = try d.readStruct(DrawIndexedCmd);
    try std.testing.expectEqual(cmd.index_count, decoded.index_count);
}
