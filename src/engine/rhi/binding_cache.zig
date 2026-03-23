const std = @import("std");

pub const PipelineLayoutCache = struct {
    const Key = struct {
        hash: u64,
    };

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Key, u32),
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) PipelineLayoutCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(Key, u32).init(allocator),
        };
    }

    pub fn deinit(self: *PipelineLayoutCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const PipelineLayoutCache, layout_ids: []const u32) ?u32 {
        return self.map.get(.{ .hash = hashLayoutIds(layout_ids) });
    }

    pub fn put(self: *PipelineLayoutCache, layout_ids: []const u32, pipeline_layout_id: u32) !void {
        try self.map.put(.{ .hash = hashLayoutIds(layout_ids) }, pipeline_layout_id);
    }

    pub fn nextSyntheticId(self: *PipelineLayoutCache) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn hashLayoutIds(layout_ids: []const u32) u64 {
        var h = std.hash.Wyhash.init(0);
        for (layout_ids) |id| {
            const bytes = std.mem.asBytes(&id);
            h.update(bytes);
        }
        return h.final();
    }
};
