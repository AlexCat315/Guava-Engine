pub const MeshHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const MaterialHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const TextureHandle = enum(u32) {
    invalid = 0,
    _,
};

pub fn isValid(handle: anytype) bool {
    return @intFromEnum(handle) != 0;
}

pub fn indexOf(handle: anytype) usize {
    return @intFromEnum(handle) - 1;
}

pub fn meshHandle(index: usize) MeshHandle {
    return @enumFromInt(index + 1);
}

pub fn materialHandle(index: usize) MaterialHandle {
    return @enumFromInt(index + 1);
}

pub fn textureHandle(index: usize) TextureHandle {
    return @enumFromInt(index + 1);
}
