const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Chunk = q.Chunk;
const OpCode = q.OpCode;
const Value = q.Value;
const Node = Ast.Node;
const Vm = q.Vm;

const build_options = @import("build_options");

const Compiler = @This();

gpa: Allocator,
tree: Ast,
vm: *Vm,
current_chunk: *Chunk,

pub const Error = Allocator.Error || error{
    NYI,
    Rank,
    Type,
    CompileError,
};

pub fn compile(gpa: Allocator, tree: Ast, vm: *Vm, chunk: *Chunk) !void {
    const compiler: Compiler = .{
        .gpa = gpa,
        .tree = tree,
        .vm = vm,
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
    if (!@import("builtin").is_test and build_options.print_code) {
        try compiler.current_chunk.disassemble(std.io.getStdOut().writer(), "code");
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
    const vm = compiler.vm;
    const tree = compiler.tree;

    const bytes = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.startsWith(u8, bytes, "0x")) {
        return error.NYI;
    } else {
        try compiler.emitConstant(switch (bytes[bytes.len - 1]) {
            'b' => blk: {
                if (bytes.len > 2) return error.NYI;
                break :blk vm.createBoolean(bytes[0] == '1');
            },
            'h' => vm.createShort(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'i' => vm.createInt(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'j' => vm.createLong(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @intCast(i),
                else => return error.Number,
            }),
            'e' => vm.createReal(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @floatFromInt(i),
                .float => std.fmt.parseFloat(f32, bytes[0 .. bytes.len - 1]) catch return error.Number,
                else => return error.Number,
            }),
            'f' => vm.createFloat(switch (std.zig.parseNumberLiteral(bytes[0 .. bytes.len - 1])) {
                .int => |i| @floatFromInt(i),
                .float => std.fmt.parseFloat(f64, bytes[0 .. bytes.len - 1]) catch return error.Number,
                else => return error.Number,
            }),
            else => switch (std.zig.parseNumberLiteral(bytes)) {
                .int => |i| vm.createLong(@intCast(i)),
                .float => vm.createFloat(std.fmt.parseFloat(f64, bytes) catch return error.Number),
                else => return error.Number,
            },
        });
    }
}

fn string(compiler: Compiler, node: Node.Index) !void {
    const vm = compiler.vm;
    const tree = compiler.tree;
    const gpa = compiler.gpa;
    assert(tree.nodeTag(node) == .string_literal);

    const token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(token);
    assert(bytes.len >= 2);
    if (bytes.len == 3) {
        try compiler.emitConstant(vm.createChar(bytes[1]));
    } else {
        const duped_slice = try gpa.dupe(u8, bytes[1 .. bytes.len - 1]);
        try compiler.emitConstant(vm.createCharList(duped_slice));
    }
}

fn symbol(compiler: Compiler, node: Node.Index) !void {
    const vm = compiler.vm;
    const tree = compiler.tree;
    const gpa = compiler.gpa;
    assert(tree.nodeTag(node) == .symbol_literal);

    const token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(token);
    assert(bytes.len >= 1);
    if (bytes.len == 1) {
        try compiler.emitConstant(vm.createSymbol(""));
    } else {
        const duped_slice = try gpa.dupe(u8, bytes[1..]);
        try compiler.emitConstant(vm.createSymbol(duped_slice));
    }
}

inline fn unary(compiler: Compiler, op_code: OpCode, x: Node.Index) !void {
    if (compiler.tree.nodeTag(x) == .no_op) return error.NYI;

    try compiler.compileNode(x);
    try compiler.emitByte(@intFromEnum(op_code));
}

inline fn binary(compiler: Compiler, op_code: OpCode, x: Node.Index, y: Node.Index) !void {
    if (compiler.tree.nodeTag(y) == .no_op) return error.NYI;
    if (compiler.tree.nodeTag(x) == .no_op) return error.NYI;

    try compiler.compileNode(y);
    try compiler.compileNode(x);
    try compiler.emitByte(@intFromEnum(op_code));
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
        .tilde_colon => try compiler.emitByte(@intFromEnum(OpCode.not)),
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
                .plus => switch (args.len) {
                    // 1 => try compiler.binary(.add, args[0], null),
                    2 => try compiler.binary(.add, args[0], args[1]),
                    else => return error.Rank,
                },
                .minus => switch (args.len) {
                    // 1 => try compiler.binary(.subtract, args[0], null),
                    2 => try compiler.binary(.subtract, args[0], args[1]),
                    else => return error.Rank,
                },
                .asterisk => switch (args.len) {
                    // 1 => try compiler.binary(.multiply, args[0], null),
                    2 => try compiler.binary(.multiply, args[0], args[1]),
                    else => return error.Rank,
                },
                .percent => switch (args.len) {
                    // 1 => try compiler.binary(.divide, args[0], null),
                    2 => try compiler.binary(.divide, args[0], args[1]),
                    else => return error.Rank,
                },
                .comma => switch (args.len) {
                    // 1 => try compiler.binary(.concat, args[0], null),
                    2 => try compiler.binary(.concat, args[0], args[1]),
                    else => return error.Rank,
                },
                .tilde_colon => switch (args.len) {
                    1 => try compiler.unary(.not, args[0]),
                    else => return error.Rank,
                },
                .at => switch (args.len) {
                    // 1 => try compiler.binary(.apply, args[0], null),
                    2 => try compiler.binary(.apply, args[0], args[1]),
                    else => return error.Rank,
                },
                .builtin => try compiler.builtin(func, args),
                inline else => |t| @panic("NYI " ++ @tagName(t)),
            }
        },
        .apply_unary => unreachable,
        .apply_binary => unreachable,

        .number_literal => compiler.number(node),
        .number_list_literal => @panic("NYI"),
        .string_literal => compiler.string(node),
        .symbol_literal => compiler.symbol(node),
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

fn builtin(compiler: Compiler, node: Node.Index, args: []const Node.Index) !void {
    const tree = compiler.tree;
    const token = tree.nodeMainToken(node);
    const slice = tree.tokenSlice(token);
    const tag = std.meta.stringToEnum(Node.Builtin, slice) orelse unreachable;
    switch (tag) {
        .not => switch (args.len) {
            1 => try compiler.unary(.not, args[0]),
            else => return error.Rank,
        },
    }
}

fn fail(compiler: Compiler, node: Node.Index, message: []const u8) error{CompileError} {
    std.io.getStdErr().writer().print("[line {d}] Error at '{s}': {s}\n", .{
        123, // TODO: Line number
        compiler.tree.tokenSlice(compiler.tree.nodeMainToken(node)),
        message,
    }) catch {};
    return error.CompileError;
}

fn testCompile(source: [:0]const u8, expected_constants: []const Value, expected_data: []const u8) !void {
    const gpa = std.testing.allocator;

    var orig_tree: Ast = try .parse(gpa, source);
    defer orig_tree.deinit(gpa);
    try std.testing.expect(orig_tree.errors.len == 0);

    var tree = try orig_tree.normalize(gpa);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    var qir = try q.AstGen.generate(gpa, tree);
    defer qir.deinit(gpa);
    try std.testing.expect(!qir.hasCompileErrors());

    var vm: Vm = undefined;
    try vm.init(gpa);
    defer vm.deinit();

    var actual_chunk: Chunk = .empty;
    defer actual_chunk.deinit(gpa);
    try compile(gpa, tree, &vm, &actual_chunk);
    for (actual_chunk.data.items(.line)) |*line| line.* = 1;

    var actual: std.ArrayListUnmanaged(u8) = .empty;
    defer actual.deinit(gpa);
    try actual_chunk.disassemble(actual.writer(gpa), "test");

    var expected_chunk: Chunk = .empty;
    defer expected_chunk.deinit(gpa);
    for (expected_constants) |constant| _ = try expected_chunk.addConstant(gpa, constant);
    for (expected_data) |code| try expected_chunk.data.append(gpa, .{ .code = code, .line = 1 });

    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(gpa);
    try expected_chunk.disassemble(expected.writer(gpa), "test");

    try std.testing.expectEqualStrings(expected.items, actual.items);
}

const utils = struct {
    fn simple(op_code: OpCode) []const u8 {
        return &.{@intFromEnum(op_code)};
    }

    fn constant(index: u8) []const u8 {
        return simple(.constant) ++ [_]u8{index};
    }
};

test {
    try testCompile(
        "1.2",
        &.{.{ .type = .float, .as = .{ .float = 1.2 } }},
        comptime utils.constant(0) ++ utils.simple(.@"return"),
    );
    try testCompile(
        "3*4+5",
        &.{
            .{ .type = .long, .as = .{ .long = 5 } },
            .{ .type = .long, .as = .{ .long = 4 } },
            .{ .type = .long, .as = .{ .long = 3 } },
        },
        comptime utils.constant(0) ++ utils.constant(1) ++ utils.simple(.add) ++
            utils.constant(2) ++ utils.simple(.multiply) ++
            utils.simple(.@"return"),
    );
    try testCompile(
        "not 0",
        &.{
            .{ .type = .long, .as = .{ .long = 0 } },
        },
        comptime utils.constant(0) ++ utils.simple(.not) ++ utils.simple(.@"return"),
    );
}
