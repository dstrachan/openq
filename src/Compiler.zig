const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Vm = q.Vm;
const Value = q.Value;
const Symbol = Value.Symbol;

const Compiler = @This();

vm: *Vm,
tree: *const Ast,
bytecode: std.ArrayList(u8) = .empty,
params: std.ArrayList(Symbol) = .empty,
locals: std.ArrayList(Symbol) = .empty,
globals: std.ArrayList(Symbol) = .empty,
constants: std.ArrayList(*Value) = .empty,

pub fn init(vm: *Vm, tree: *const Ast) Compiler {
    return .{
        .vm = vm,
        .tree = tree,
    };
}

pub fn deinit(c: *Compiler) void {
    c.bytecode.deinit(c.vm.gpa);
    c.params.deinit(c.vm.gpa);
    c.locals.deinit(c.vm.gpa);
    c.globals.deinit(c.vm.gpa);
    for (c.constants.items) |v| v.deref(c.vm.gpa);
    c.constants.deinit(c.vm.gpa);
}

pub fn compile(c: *Compiler, node: Node.Index) !*Value {
    const vm = c.vm;
    const tree = c.tree;
    assert(tree.nodeTag(node) == .lambda);

    const l_brace = tree.nodeMainToken(node);
    const extra_index, const r_brace = tree.nodeData(node).extra_and_token;
    const source = try vm.gpa.dupe(u8, tree.source[tree.tokenStart(l_brace) .. tree.tokenStart(r_brace) + 1]);
    errdefer vm.gpa.free(source);

    const lambda = tree.extraData(extra_index, Node.Lambda);

    const params = tree.extraDataSlice(
        .{ .start = lambda.params_start, .end = lambda.body_start },
        Node.Index,
    );
    try c.compileParams(params);

    const body = tree.extraDataSlice(
        .{ .start = lambda.body_start, .end = lambda.body_end },
        Node.Index,
    );
    for (body) |n| try c.compileNode(n);
    if (lambda.trailing_semicolon) unreachable; // TODO: Trailing semicolon

    try c.bytecode.shrinkToLen(vm.gpa);
    try c.params.shrinkToLen(vm.gpa);
    try c.locals.shrinkToLen(vm.gpa);
    try c.globals.shrinkToLen(vm.gpa);
    try c.constants.shrinkToLen(vm.gpa);

    return vm.createValue(.lambda, .{
        .bytecode = c.bytecode.toOwnedSliceAssert(),
        .params = c.params.toOwnedSliceAssert(),
        .locals = c.params.toOwnedSliceAssert(),
        .globals = c.globals.toOwnedSliceAssert(),
        .constants = c.constants.toOwnedSliceAssert(),
        .source = source,
    });
}

fn compileParams(c: *Compiler, params: []const Node.Index) !void {
    const vm = c.vm;
    const tree = c.tree;

    if (params.len == 0) unreachable; // TODO: Implicit params
    if (params.len == 1 and tree.nodeTag(params[0]) == .empty) return;

    try c.params.ensureTotalCapacity(vm.gpa, params.len);
    for (params) |node| {
        assert(tree.nodeTag(node) == .identifier); // TODO: Handle errors
        const main_token = tree.nodeMainToken(node);
        const bytes = tree.tokenSlice(main_token);
        const symbol = try vm.intern(bytes);
        c.params.appendAssumeCapacity(symbol);
    }
}

fn compileNode(c: *Compiler, node: Node.Index) !void {
    const vm = c.vm;
    _ = vm; // autofix
    const tree = c.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .empty => try c.emitCode(.empty),

        .grouped_expression,
        .empty_list,
        .list,
        .table_literal,
        => unreachable,

        .lambda => unreachable,

        .expr_block => unreachable,

        .call,
        .apply_unary,
        .apply_binary,
        => unreachable,

        .colon => unreachable,
        .plus => unreachable,
        .minus => unreachable,
        .asterisk => unreachable,
        .percent => unreachable,
        .ampersand => unreachable,
        .pipe => unreachable,
        .caret => unreachable,
        .equal => unreachable,
        .l_angle_bracket => unreachable,
        .l_angle_bracket_equal => unreachable,
        .l_angle_bracket_r_angle_bracket => unreachable,
        .r_angle_bracket => unreachable,
        .r_angle_bracket_equal => unreachable,
        .dollar => unreachable,
        .comma => unreachable,
        .hash => unreachable,
        .underscore => unreachable,
        .tilde => unreachable,
        .bang => unreachable,
        .question_mark => unreachable,
        .at => unreachable,
        .dot => unreachable,
        .zero_colon => unreachable,
        .one_colon => unreachable,
        .two_colon => unreachable,

        .colon_colon => unreachable,
        .plus_colon => unreachable,
        .minus_colon => unreachable,
        .asterisk_colon => unreachable,
        .percent_colon => unreachable,
        .ampersand_colon => unreachable,
        .pipe_colon => unreachable,
        .caret_colon => unreachable,
        .equal_colon => unreachable,
        .l_angle_bracket_colon => unreachable,
        .r_angle_bracket_colon => unreachable,
        .dollar_colon => unreachable,
        .comma_colon => unreachable,
        .hash_colon => unreachable,
        .underscore_colon => unreachable,
        .tilde_colon => unreachable,
        .bang_colon => unreachable,
        .question_mark_colon => unreachable,
        .at_colon => unreachable,
        .dot_colon => unreachable,
        .zero_colon_colon => unreachable,
        .one_colon_colon => unreachable,

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => unreachable,

        .number_literal,
        .number_list_literal,
        .string_literal,
        .symbol_literal,
        .symbol_list_literal,
        .identifier,
        .builtin,
        => unreachable,

        .select,
        .exec,
        .update,
        .delete_rows,
        .delete_cols,
        => unreachable,
    }
}

fn emitCode(c: *Compiler, code: ByteCode) !void {
    try c.emitByte(@intFromEnum(code));
}

fn emitByte(c: *Compiler, byte: u8) !void {
    try c.bytecode.append(c.vm.gpa, byte);
}

pub const ByteCode = enum(u8) {
    empty_list = 11,
    zero = 12,
    one = 13,
    comma = 14,
    null_symbol = 15,
    nil = 16,
    empty = 17,
};
