const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Value = q.Value;

const Chunk = @This();

data: std.MultiArrayList(struct { code: u8, line: u32 }) = .empty,
constants: std.ArrayListUnmanaged(*Value) = .empty,

pub const OpCode = enum(u8) {
    constant,

    add,
    subtract,
    multiply,
    divide,
    concat,
    match,
    apply,

    flip,
    negate,
    first,
    reciprocal,
    enlist,
    not,
    type,

    @"return",

    pub const Index = enum(u32) { _ };
};

pub const empty: Chunk = .{};

pub fn deinit(chunk: *Chunk, gpa: Allocator) void {
    chunk.data.deinit(gpa);
    for (chunk.constants.items) |constant| {
        assert(constant.ref_count == 1);
        constant.deref(gpa);
    }
    chunk.constants.deinit(gpa);
}

pub fn write(chunk: *Chunk, gpa: Allocator, byte: u8, line: u32) !void {
    try chunk.data.append(gpa, .{ .code = byte, .line = line });
}

pub fn replace(chunk: *Chunk, index: OpCode.Index, byte: u8) void {
    chunk.data.items(.code)[@intFromEnum(index)] = byte;
}

pub fn addConstant(chunk: *Chunk, gpa: Allocator, value: *Value) !usize {
    try chunk.constants.append(gpa, value);
    return chunk.constants.items.len - 1;
}

pub fn opCode(chunk: Chunk, index: OpCode.Index) OpCode {
    return @enumFromInt(chunk.data.items(.code)[@intFromEnum(index)]);
}

pub fn disassemble(chunk: Chunk, writer: *Writer, name: []const u8) !void {
    try writer.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < chunk.data.len) {
        offset = try chunk.disassembleInstruction(writer, offset);
    }
}

pub fn disassembleInstruction(chunk: Chunk, writer: *Writer, offset: usize) !usize {
    try writer.print("{d:04} ", .{offset});
    if (offset > 0 and chunk.data.items(.line)[offset] == chunk.data.items(.line)[offset - 1]) {
        try writer.writeAll("   | ");
    } else {
        try writer.print("{d:4} ", .{chunk.data.items(.line)[offset]});
    }

    switch (chunk.opCode(@enumFromInt(offset))) {
        .constant => return chunk.constantInstruction(writer, .constant, offset),

        .add,
        .subtract,
        .multiply,
        .divide,
        .concat,
        .match,
        .apply,

        .flip,
        .negate,
        .first,
        .reciprocal,
        .enlist,
        .not,
        .type,

        .@"return",
        => |t| return simpleInstruction(writer, t, offset),
    }
}

fn simpleInstruction(writer: *Writer, op_code: OpCode, offset: usize) !usize {
    try writer.print("{t}\n", .{op_code});
    return offset + 1;
}

fn constantInstruction(chunk: Chunk, writer: *Writer, op_code: OpCode, offset: usize) !usize {
    const constant = chunk.data.items(.code)[offset + 1];
    try writer.print("{t: <16} {d:4} '{f}'\n", .{ op_code, constant, chunk.constants.items[constant] });
    return offset + 2;
}
