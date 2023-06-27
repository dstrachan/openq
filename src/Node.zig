const std = @import("std");

const Chunk = @import("Chunk.zig");
const Compiler = @import("Compiler.zig");
const OpCode = Chunk.OpCode;
const Token = @import("Token.zig");

const Node = @This();

op_code: OpCode,
byte: ?u8 = null,
name: ?Token = null,
lhs: ?*Node = null,
rhs: ?*Node = null,

pub fn init(node: Node, allocator: std.mem.Allocator) *Node {
    const ptr = allocator.create(Node) catch std.debug.panic("Failed to create node.", .{});
    ptr.* = node;
    return ptr;
}

pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
    if (self.lhs) |lhs| lhs.deinit(allocator);
    if (self.rhs) |rhs| rhs.deinit(allocator);
    allocator.destroy(self);
}
