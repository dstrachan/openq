const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Chunk = q.Chunk;
const OpCode = q.OpCode;
const Value = q.Value;
const Node = Ast.Node;

const build_options = @import("build_options");

const Compiler = @This();

gpa: Allocator,
tree: Ast,
current_chunk: *Chunk,

pub const Error = Allocator.Error || error{
    NYI,
    Rank,
    Type,
    CompileError,
};

pub fn compile(gpa: Allocator, tree: Ast, chunk: *Chunk) !void {
    const compiler: Compiler = .{
        .gpa = gpa,
        .tree = tree,
        .current_chunk = chunk,
    };

    for (tree.rootStatements()) |node| {
        try compiler.compileNode(node);
    }

    try compiler.end();
}

fn emitByte(compiler: Compiler, byte: u8) !void {
    try compiler.current_chunk.write(compiler.gpa, byte, 123); // TODO: Line number
}

fn emitBytes(compiler: Compiler, byte1: u8, byte2: u8) !void {
    try compiler.emitByte(byte1);
    try compiler.emitByte(byte2);
}

fn emitReturn(compiler: Compiler) !void {
    try compiler.emitByte(@intFromEnum(OpCode.@"return"));
}

fn replaceByte(compiler: Compiler, index: OpCode.Index, byte: u8) void {
    compiler.current_chunk.replace(index, byte);
}

fn end(compiler: Compiler) !void {
    try compiler.emitReturn();
    if (build_options.print_code) {
        try compiler.current_chunk.disassemble("code");
    }
}

fn makeConstant(compiler: Compiler, value: Value) !u8 {
    const constant = try compiler.current_chunk.addConstant(compiler.gpa, value);
    if (constant > std.math.maxInt(u8)) return error.TooManyConstants;
    return @intCast(constant);
}

fn emitConstant(compiler: Compiler, value: Value) !void {
    const constant = try compiler.makeConstant(value);
    try compiler.emitBytes(@intFromEnum(OpCode.constant), constant);
}

fn getConstant(compiler: Compiler, index: OpCode.Index) Value {
    assert(compiler.current_chunk.opCode(index) == .constant);
    const constant_index = compiler.current_chunk.data.items(.code)[@intFromEnum(index) + 1];
    return compiler.current_chunk.constants.items[constant_index];
}

inline fn currentOffset(compiler: Compiler) OpCode.Index {
    return @enumFromInt(compiler.current_chunk.data.len);
}

fn number(compiler: Compiler, node: Node.Index) !void {
    const tree = compiler.tree;
    const bytes = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.startsWith(u8, bytes, "0x")) {
        return error.NYI;
    } else {
        try compiler.emitConstant(switch (bytes[bytes.len - 1]) {
            'b' => blk: {
                if (bytes.len > 2) return error.NYI;
                break :blk .boolean(bytes[0] == '1');
            },
            'h' => .short(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'i' => .int(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'j' => .long(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'e' => .real(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @floatFromInt(i),
                .float => std.fmt.parseFloat(f32, bytes[0 .. bytes.len - 1]) catch return error.Number,
                else => return error.Number,
            }),
            'f' => .float(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @floatFromInt(i),
                .float => std.fmt.parseFloat(f64, bytes[0 .. bytes.len - 1]) catch return error.Number,
                else => return error.Number,
            }),
            else => switch (std.zig.parseNumberLiteral(bytes)) {
                .int => |i| .long(@intCast(i)),
                .float => .float(std.fmt.parseFloat(f64, bytes) catch return error.Number),
                else => return error.Number,
            },
        });
    }
}

inline fn binary(compiler: Compiler, op_code: OpCode, args: []const Node.Index) !void {
    switch (args.len) {
        0, 1 => return error.NYI,
        2 => {
            if (compiler.tree.nodeTag(args[1]) == .no_op) return error.NYI;
            if (compiler.tree.nodeTag(args[0]) == .no_op) return error.NYI;

            try compiler.compileNode(args[1]);
            try compiler.compileNode(args[0]);
            try compiler.emitByte(@intFromEnum(op_code));
        },
        else => return error.Rank,
    }
}

fn compileNode(compiler: Compiler, node: Node.Index) Error!void {
    const tree = compiler.tree;
    (switch (tree.nodeTag(node)) {
        .root => @panic("NYI"),
        .no_op => @panic("NYI"),

        .grouped_expression => try compiler.compileNode(tree.nodeData(node).node_and_token[0]),
        .empty_list => @panic("NYI"),
        .list => @panic("NYI"),
        .table_literal => @panic("NYI"),

        .function => @panic("NYI"),

        .expr_block => @panic("NYI"),

        .colon => @panic("NYI"),
        .colon_colon => @panic("NYI"),
        .plus => try compiler.emitByte(@intFromEnum(OpCode.add)),
        .plus_colon => @panic("NYI"),
        .minus => try compiler.emitByte(@intFromEnum(OpCode.subtract)),
        .minus_colon => try compiler.emitByte(@intFromEnum(OpCode.negate)),
        .asterisk => try compiler.emitByte(@intFromEnum(OpCode.multiply)),
        .asterisk_colon => @panic("NYI"),
        .percent => try compiler.emitByte(@intFromEnum(OpCode.divide)),
        .percent_colon => @panic("NYI"),
        .ampersand => @panic("NYI"),
        .ampersand_colon => @panic("NYI"),
        .pipe => @panic("NYI"),
        .pipe_colon => @panic("NYI"),
        .caret => @panic("NYI"),
        .caret_colon => @panic("NYI"),
        .equal => @panic("NYI"),
        .equal_colon => @panic("NYI"),
        .l_angle_bracket => @panic("NYI"),
        .l_angle_bracket_colon => @panic("NYI"),
        .l_angle_bracket_equal => @panic("NYI"),
        .l_angle_bracket_r_angle_bracket => @panic("NYI"),
        .r_angle_bracket => @panic("NYI"),
        .r_angle_bracket_colon => @panic("NYI"),
        .r_angle_bracket_equal => @panic("NYI"),
        .dollar => @panic("NYI"),
        .dollar_colon => @panic("NYI"),
        .comma => @panic("NYI"),
        .comma_colon => @panic("NYI"),
        .hash => @panic("NYI"),
        .hash_colon => @panic("NYI"),
        .underscore => @panic("NYI"),
        .underscore_colon => @panic("NYI"),
        .tilde => @panic("NYI"),
        .tilde_colon => @panic("NYI"),
        .bang => @panic("NYI"),
        .bang_colon => @panic("NYI"),
        .question_mark => @panic("NYI"),
        .question_mark_colon => @panic("NYI"),
        .at => @panic("NYI"),
        .at_colon => @panic("NYI"),
        .dot => @panic("NYI"),
        .dot_colon => @panic("NYI"),
        .zero_colon => @panic("NYI"),
        .zero_colon_colon => @panic("NYI"),
        .one_colon => @panic("NYI"),
        .one_colon_colon => @panic("NYI"),
        .two_colon => @panic("NYI"),

        .apostrophe => @panic("NYI"),
        .apostrophe_colon => @panic("NYI"),
        .slash => @panic("NYI"),
        .slash_colon => @panic("NYI"),
        .backslash => @panic("NYI"),
        .backslash_colon => @panic("NYI"),

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 0);

            const func = nodes[0];
            const args = nodes[1..];

            switch (tree.nodeTag(func)) {
                .plus => try compiler.binary(.add, args),
                .minus => try compiler.binary(.subtract, args),
                .asterisk => try compiler.binary(.multiply, args),
                .percent => try compiler.binary(.divide, args),
                inline else => |t| @panic("NYI " ++ @tagName(t)),
            }
        },
        .apply_unary => {
            const op, const x = tree.nodeData(node).node_and_node;

            try compiler.compileNode(x);
            const op_index = compiler.currentOffset();
            try compiler.compileNode(op);
            switch (compiler.current_chunk.opCode(op_index)) {
                .add => compiler.replaceByte(op_index, @intFromEnum(OpCode.flip)),
                .subtract => compiler.replaceByte(op_index, @intFromEnum(OpCode.negate)),
                .multiply => compiler.replaceByte(op_index, @intFromEnum(OpCode.first)),
                .divide => compiler.replaceByte(op_index, @intFromEnum(OpCode.reciprocal)),
                else => try compiler.emitByte(@intFromEnum(OpCode.apply)),
            }
        },
        .apply_binary => {
            const x, const maybe_y = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @enumFromInt(tree.nodeMainToken(node));

            if (maybe_y.unwrap()) |y| {
                switch (tree.nodeTag(op)) {
                    .plus => try compiler.binary(.add, &.{ x, y }),
                    .minus => try compiler.binary(.subtract, &.{ x, y }),
                    .asterisk => try compiler.binary(.multiply, &.{ x, y }),
                    .percent => try compiler.binary(.divide, &.{ x, y }),
                    .at => try compiler.binary(.apply, &.{ x, y }),
                    inline else => |t| @panic("NYI " ++ @tagName(t)),
                }
            } else @panic("NYI");
        },

        .number_literal => compiler.number(node),
        .number_list_literal => @panic("NYI"),
        .string_literal => @panic("NYI"),
        .symbol_literal => @panic("NYI"),
        .symbol_list_literal => @panic("NYI"),
        .identifier => @panic("NYI"),
        .builtin => @panic("NYI"),

        .select => @panic("NYI"),
        .exec => @panic("NYI"),
        .update => @panic("NYI"),
        .delete_rows => @panic("NYI"),
        .delete_cols => @panic("NYI"),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyConstants => return compiler.fail(node, "Too many constants in one chunk"),
        error.Number => return compiler.fail(node, "TODO"),
        error.NYI => return compiler.fail(node, "nyi"),
    };
}

fn fail(compiler: Compiler, node: Node.Index, message: []const u8) error{CompileError} {
    std.io.getStdErr().writer().print("[line {d}] Error at '{s}': {s}\n", .{
        123, // TODO: Line number
        compiler.tree.tokenSlice(compiler.tree.nodeMainToken(node)),
        message,
    }) catch {};
    return error.CompileError;
}
