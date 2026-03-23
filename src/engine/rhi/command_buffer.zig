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
    barrier_count: u32,
};

pub const DecodedCommand = union(OpCode) {
    begin_render_pass: BeginRenderPassCmd,
    end_render_pass: void,
    begin_compute_pass: BeginComputePassCmd,
    end_compute_pass: void,
    begin_copy_pass: BeginCopyPassCmd,
    end_copy_pass: void,
    set_binding_set: SetBindingSetCmd,
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
        const value: *const T = @ptrCast(@alignCast(self.bytes[self.cursor..end].ptr));
        self.cursor = end;
        return value.*;
    }
};
