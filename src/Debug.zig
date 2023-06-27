const std = @import("std");
const builtin = @import("builtin");

const Chunk = @import("Chunk.zig");
const OpCode = Chunk.OpCode;

pub const log_messages = builtin.mode == .Debug and !builtin.is_test;
pub const trace_execution = builtin.mode == .Debug and !builtin.is_test;
pub const show_memory_allocations = false;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (log_messages) std.debug.print(fmt, args);
}

pub fn disassembleChunk(chunk: *Chunk, name: []const u8) void {
    for (chunk.constants.items) |constant| {
        switch (constant.as) {
            .function => |function| disassembleChunk(function.chunk, function.name.?),
            else => {},
        }
    }

    print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
}

pub fn disassembleInstruction(chunk: *Chunk, offset: usize) usize {
    print("{d:0>4} ", .{offset});
    if (offset > 0 and chunk.tokens.items[offset].line == chunk.tokens.items[offset - 1].line) {
        print("   | ", .{});
    } else {
        print("{d:4} ", .{chunk.tokens.items[offset].line});
    }

    const instruction: OpCode = @enumFromInt(chunk.code.items[offset]);
    return switch (instruction) {
        .Nil => simpleInstruction(.Nil, offset),
        .Constant => constantInstruction(.Constant, chunk, offset),
        .Pop => simpleInstruction(.Pop, offset),
        .GetLocal => byteInstruction(.GetLocal, chunk, offset),
        .SetLocal => byteInstruction(.SetLocal, chunk, offset),
        .GetGlobal => constantInstruction(.GetGlobal, chunk, offset),
        .SetGlobal => constantInstruction(.SetGlobal, chunk, offset),
        .Add => simpleInstruction(.Add, offset),
        .Subtract => simpleInstruction(.Subtract, offset),
        .Multiply => simpleInstruction(.Multiply, offset),
        .Divide => simpleInstruction(.Divide, offset),
        .Call => byteInstruction(.Call, chunk, offset),
        .Return => simpleInstruction(.Return, offset),
    };
}

fn simpleInstruction(comptime instruction: OpCode, offset: usize) usize {
    print("{s}\n", .{@tagName(instruction)});
    return offset + 1;
}

fn constantInstruction(comptime instruction: OpCode, chunk: *Chunk, offset: usize) usize {
    const constant = chunk.code.items[offset + 1];
    const value = chunk.constants.items[constant];
    print("{s:<16} {d:4} {}\n", .{ @tagName(instruction), constant, value });
    return offset + 2;
}

fn byteInstruction(comptime instruction: OpCode, chunk: *Chunk, offset: usize) usize {
    const slot = chunk.code.items[offset + 1];
    print("{s:<16} {d:4}\n", .{ @tagName(instruction), slot });
    return offset + 2;
}
