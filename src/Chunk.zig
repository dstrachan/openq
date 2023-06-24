const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,

pub const OpCode = enum {
    Nil,
    Constant,
    Pop,
    GetLocal,
    SetLocal,
    GetGlobal,
    SetGlobal,
    Add,
    Subtract,
    Multiply,
    Divide,
    Call,
    Return,
};

pub fn init(allocator: std.mem.Allocator) *Self {
    const self = allocator.create(Self) catch std.debug.panic("Failed to create chunk.", .{});
    self.* = .{
        .allocator = allocator,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.allocator.destroy(self);
}
