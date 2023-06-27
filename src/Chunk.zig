const std = @import("std");

const Value = @import("Value.zig");
const Token = @import("Token.zig");

const Chunk = @This();

allocator: std.mem.Allocator,
constants: std.ArrayList(*Value),
code: std.ArrayList(u8),
tokens: std.ArrayList(Token),

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

pub fn init(allocator: std.mem.Allocator) *Chunk {
    const self = allocator.create(Chunk) catch std.debug.panic("Failed to create chunk.", .{});
    self.* = .{
        .allocator = allocator,
        .constants = std.ArrayList(*Value).init(allocator),
        .code = std.ArrayList(u8).init(allocator),
        .tokens = std.ArrayList(Token).init(allocator),
    };
    return self;
}

pub fn deinit(self: *Chunk) void {
    for (self.constants.items) |constant| constant.deref(self.allocator);
    self.constants.deinit();
    self.code.deinit();
    self.tokens.deinit();
    self.allocator.destroy(self);
}

pub fn addConstant(self: *Chunk, value: *Value) usize {
    self.constants.append(value) catch std.debug.panic("Failed to add constant.", .{});
    return self.constants.items.len - 1;
}

pub fn write(self: *Chunk, byte: u8, token: Token) void {
    self.code.append(byte) catch std.debug.panic("Failed to write byte.", .{});
    self.tokens.append(token) catch std.debug.panic("Failed to write token.", .{});
}
