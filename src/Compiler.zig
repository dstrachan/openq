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

const Error = Allocator.Error || std.fmt.ParseIntError;

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

pub fn compile(c: *Compiler, node: Node.Index) Error!*Value {
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
    const tree = c.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .empty => try c.emitCode(.empty),

        .grouped_expression,
        .empty_list,
        .list,
        .table_literal,
        => unreachable,

        .lambda => {
            var compiler: Compiler = .init(vm, tree);
            defer compiler.deinit();
            const value = try compiler.compile(node);
            errdefer value.deref(c.vm.gpa);
            try c.emitConstant(value);
        },

        .expr_block => unreachable,

        .call => unreachable,
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try c.compileNode(rhs);
            try c.compileNode(lhs);
        },
        .apply_binary => unreachable,

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

        .number_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            if (slice.len == 1 or (slice.len == 2 and slice[1] == 'j')) {
                switch (slice[0]) {
                    '0' => return c.emitCode(.zero),
                    '1' => return c.emitCode(.one),
                    else => {},
                }
            }
            const number_literal = try vm.createNumberLiteralSlice(slice);
            errdefer number_literal.deref(vm.gpa);
            try c.emitConstant(number_literal);
        },
        .number_list_literal => {
            const number_list_literal = try vm.createNumberListLiteral(tree, node);
            errdefer number_list_literal.deref(vm.gpa);
            try c.emitConstant(number_list_literal);
        },
        .string_literal => unreachable,
        .symbol_literal => unreachable,
        .symbol_list_literal => unreachable,
        .identifier => unreachable,
        .builtin => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const builtin = std.meta.stringToEnum(Node.Builtin, slice).?;
            switch (builtin) {
                .flip => unreachable,
                .neg => unreachable,
                // .first => try c.emitCode(.first),
                .first => unreachable,
                .reciprocal => unreachable,
                .where => unreachable,
                .reverse => unreachable,
                .null => unreachable,
                .group => unreachable,
                .asc => unreachable,
                .desc => unreachable,
                .string => unreachable,
                .enlist => unreachable,
                .count => unreachable,
                .lower => unreachable,
                .not => unreachable,
                .key => unreachable,
                .distinct => unreachable,
                .type => unreachable,
                .value => try c.emitCode(.value),

                .parse => unreachable,
            }
        },

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

fn emitConstant(c: *Compiler, value: *Value) !void {
    for (c.constants.items, 0..) |constant, i| {
        if (value.eql(constant)) {
            defer value.deref(c.vm.gpa);
            return c.emitByte(@intCast(@intFromEnum(ByteCode.constant) + i));
        }
    }
    try c.constants.append(c.vm.gpa, value);
    try c.emitByte(@intCast(@intFromEnum(ByteCode.constant) + c.constants.items.len - 1));
}

pub const ByteCode = enum(u8) {
    @"return" = 0,
    print = 1,
    pop = 2,
    assign = 3,
    amend = 4,
    call = 10,

    // builtins
    empty_list = 11,
    zero = 12,
    one = 13,
    comma = 14,
    null_symbol = 15,
    nil = 16,
    empty = 17,

    // iterators
    each = 18,
    over = 19,
    scan = 20,
    each_prior = 21,
    each_right = 22,
    each_left = 23,

    // unary primitives
    identity = 32,
    flip = 33,
    neg = 34,
    first = 35,
    reciprocal = 36,
    where = 37,
    reverse = 38,
    null = 39,
    group = 40,
    asc = 41,
    desc = 42,
    string = 43,
    list = 44,
    count = 45,
    lower = 46,
    not = 47,
    key = 48,
    distinct = 49,
    type = 50,
    value = 51,
    read_text = 52,
    read_binary = 53,
    _unused_unary_primitive = 54,
    avg = 55,
    last = 56,
    sum = 57,
    prd = 58,
    min = 59,
    max = 60,
    exit = 61,
    getenv = 62,
    abs = 63,

    // operators
    _unused_operator = 64,
    add = 65,
    subtract = 66,
    multiply = 67,
    divide = 68,
    @"and" = 69,
    @"or" = 70,
    fill = 71,
    equals = 72,
    less_than = 73,
    greater_than = 74,
    cast = 75,
    join = 76,
    take = 77,
    drop = 78,
    match = 79,
    dict = 80,
    find = 81,
    apply_at = 82,
    apply = 83,
    file_text = 84,
    file_binary = 85,
    dynamic_load = 86,
    in = 87,
    within = 88,
    like = 89,
    bin = 90,
    ss = 91,
    insert = 92,
    wsum = 93,
    wavg = 94,
    div = 95,

    self = 96,

    param_1 = 97,
    param_2 = 98,
    param_3 = 99,
    param_4 = 100,
    param_5 = 101,
    param_6 = 102,
    param_7 = 103,
    param_8 = 104,

    local_1 = 105,
    local_2 = 106,
    local_3 = 107,
    local_4 = 108,
    local_5 = 109,
    local_6 = 110,
    local_7 = 111,
    local_8 = 112,
    local_9 = 113,
    local_10 = 114,
    local_11 = 115,
    local_12 = 116,
    local_13 = 117,
    local_14 = 118,
    local_15 = 119,
    local_16 = 120,
    local_17 = 121,
    local_18 = 122,
    local_19 = 123,
    local_20 = 124,
    local_21 = 125,
    local_22 = 126,
    local_wide = 127,

    global = 129,

    constant = 160,
};
