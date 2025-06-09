const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Value = q.Value;

const Chunk = @This();

data: std.MultiArrayList(struct { code: u8, line: u32 }) = .empty,
constants: std.ArrayListUnmanaged(Value) = .empty,

pub const OpCode = enum(u8) {
    constant,

    add,
    subtract,
    multiply,
    divide,
    concat,
    apply,

    flip,
    negate,
    first,
    reciprocal,

    @"return",

    pub const Index = enum(u32) { _ };
};

pub const empty: Chunk = .{};

pub fn deinit(chunk: *Chunk, gpa: Allocator) void {
    chunk.data.deinit(gpa);
    chunk.constants.deinit(gpa);
}

pub fn write(chunk: *Chunk, gpa: Allocator, byte: u8, line: u32) !void {
    try chunk.data.append(gpa, .{ .code = byte, .line = line });
}

pub fn replace(chunk: *Chunk, index: OpCode.Index, byte: u8) void {
    chunk.data.items(.code)[@intFromEnum(index)] = byte;
}

pub fn addConstant(chunk: *Chunk, gpa: Allocator, value: Value) !usize {
    try chunk.constants.append(gpa, value);
    return chunk.constants.items.len - 1;
}

pub fn opCode(chunk: Chunk, index: OpCode.Index) OpCode {
    return @enumFromInt(chunk.data.items(.code)[@intFromEnum(index)]);
}

pub fn disassemble(chunk: Chunk, name: []const u8) !void {
    try std.io.getStdOut().writer().print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.data.len) {
        offset = try chunk.disassembleInstruction(offset);
    }
}

pub fn disassembleInstruction(chunk: Chunk, offset: usize) !usize {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d:04} ", .{offset});
    if (offset > 0 and chunk.data.items(.line)[offset] == chunk.data.items(.line)[offset - 1]) {
        try stdout.writeAll("   | ");
    } else {
        try stdout.print("{d:4} ", .{chunk.data.items(.line)[offset]});
    }

    switch (chunk.opCode(@enumFromInt(offset))) {
        .constant => return chunk.constantInstruction(@tagName(.constant), offset),

        .add,
        .subtract,
        .multiply,
        .divide,
        .concat,
        .apply,
        => |t| return simpleInstruction(@tagName(t), offset),

        .flip,
        .negate,
        .first,
        .reciprocal,
        => |t| return simpleInstruction(@tagName(t), offset),

        .@"return" => return simpleInstruction(@tagName(.@"return"), offset),
    }
}

fn simpleInstruction(name: []const u8, offset: usize) !usize {
    try std.io.getStdOut().writer().print("{s}\n", .{name});
    return offset + 1;
}

fn constantInstruction(chunk: Chunk, name: []const u8, offset: usize) !usize {
    const stdout = std.io.getStdOut().writer();
    const constant = chunk.data.items(.code)[offset + 1];
    try stdout.print("{s: <16} {d:4} '", .{ name, constant });
    try chunk.constants.items[constant].print();
    try stdout.writeAll("'\n");
    return offset + 2;
}
