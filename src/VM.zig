const std = @import("std");

const Compiler = @import("Compiler.zig");
const Value = @import("Value.zig");
const ValueUnion = Value.ValueUnion;

const Self = @This();

allocator: std.mem.Allocator,

const VMError = error{
    CompileError,
    RuntimeError,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: Self) void {
    _ = self;
}

pub fn interpret(self: Self, source: []const u8) VMError!void {
    const value = Compiler.compile(source, self) catch return VMError.CompileError;
    _ = value;

    return VMError.RuntimeError;
}

pub fn initValue(self: Self, data: ValueUnion) *Value {
    return Value.init(.{ .data = data }, self.allocator);
}
