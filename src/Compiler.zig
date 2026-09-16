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

const Error = Allocator.Error || std.fmt.ParseIntError || Io.Writer.Error || error{
    parse,
    nyi,
    assign,
};

vm: *Vm,
tree: *const Ast,
bytecode: std.ArrayList(u8) = .empty,
params: std.ArrayList(Symbol) = .empty,
locals: std.ArrayList(Symbol) = .empty,
globals: std.ArrayList(Symbol) = .empty,
constants: std.ArrayList(*Value) = .empty,
/// Every name the body mentions, in source order, from which the globals are numbered.
names: std.ArrayList(Symbol) = .empty,
/// Set when the lambda has no parameter list, so its parameters are the implicit `x`, `y`
/// and `z`, as many as the body uses.
implicit_params: bool = false,
implicit_valence: u8 = 0,

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
    c.names.deinit(c.vm.gpa);
    for (c.constants.items) |v| v.deref(c.vm.gpa);
    c.constants.deinit(c.vm.gpa);
}

/// Compiles a lambda node to bytecode. Parameters are the explicit list or the implicit
/// `x y z`; locals are the bare names assigned with `:` in the body; every other name is a
/// global, resolved when the lambda runs: (`\d .foo` then `{t0 x}` calls `.foo.t0`). Keywords are inlined as q does.
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
    // Names are classified before any code is emitted, so a local reads as a local even
    // ahead of its assignment, and the implicit valence is known.
    for (body) |n| try c.scan(n);
    if (c.implicit_params) {
        for ("xyz"[0..@max(1, c.implicit_valence)]) |letter| {
            try c.params.append(vm.gpa, try vm.intern(&.{letter}));
        }
    }
    // Globals are numbered by first appearance in the source, as q numbers them.
    for (c.names.items) |symbol| {
        if (std.mem.findScalar(Symbol, c.params.items, symbol) != null) continue;
        if (std.mem.findScalar(Symbol, c.locals.items, symbol) != null) continue;
        if (std.mem.findScalar(Symbol, c.globals.items, symbol) != null) continue;
        try c.globals.append(vm.gpa, symbol);
    }

    for (body, 0..) |n, i| {
        try c.compileNode(n);
        if (i + 1 < body.len or lambda.trailing_semicolon) try c.emitCode(.pop);
    }
    // An empty body or a trailing `;` returns `::`.
    if (body.len == 0 or lambda.trailing_semicolon) try c.emitCode(.nil);
    try c.emitCode(.@"return");

    try c.bytecode.shrinkToLen(vm.gpa);
    try c.params.shrinkToLen(vm.gpa);
    try c.locals.shrinkToLen(vm.gpa);
    try c.globals.shrinkToLen(vm.gpa);
    try c.constants.shrinkToLen(vm.gpa);

    return vm.createValue(.lambda, .{
        .bytecode = c.bytecode.toOwnedSliceAssert(),
        .params = c.params.toOwnedSliceAssert(),
        .locals = c.locals.toOwnedSliceAssert(),
        .globals = c.globals.toOwnedSliceAssert(),
        .constants = c.constants.toOwnedSliceAssert(),
        .namespace = vm.namespace,
        .source = source,
    });
}

fn compileParams(c: *Compiler, params: []const Node.Index) Error!void {
    const vm = c.vm;
    const tree = c.tree;

    if (params.len == 0) {
        c.implicit_params = true;
        return;
    }
    // Every lambda takes at least one argument: `{[]1}` has a single unnamed parameter,
    // so `{[]1}[1]` is 1 and `{[]1}[1;2]` a rank error, as in q.
    if (params.len == 1 and tree.nodeTag(params[0]) == .empty) return c.params.append(vm.gpa, .empty);
    // q allows eight parameters at most.
    if (params.len > 8) return error.parse;

    try c.params.ensureTotalCapacity(vm.gpa, params.len);
    for (params) |node| {
        if (tree.nodeTag(node) != .identifier) return error.parse;
        const symbol = try vm.intern(tree.tokenSlice(tree.nodeMainToken(node)));
        c.params.appendAssumeCapacity(symbol);
    }
}

/// Finds the names the body uses: implicit parameters and locals. Nested lambdas are their
/// own scope, as q has no closures, so they are not entered.
fn scan(c: *Compiler, node: Node.Index) Error!void {
    const tree = c.tree;
    switch (tree.nodeTag(node)) {
        .identifier => try c.noteName(tree.tokenSlice(tree.nodeMainToken(node)), false),
        .keyword => if (c.aliasOf(node)) |name| try c.noteName(name, false),
        .grouped_expression => try c.scan(tree.nodeData(node).node_and_token[0]),
        .list, .call, .expr_block => {
            for (tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index)) |n| try c.scan(n);
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try c.scan(lhs);
            try c.scan(rhs);
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));
            if (tree.nodeTag(op) == .colon and tree.nodeTag(lhs) == .identifier) {
                try c.noteName(tree.tokenSlice(tree.nodeMainToken(lhs)), true);
            } else {
                try c.scan(lhs);
            }
            if (maybe_rhs.unwrap()) |rhs| try c.scan(rhs);
        },
        else => {},
    }
}

fn noteName(c: *Compiler, name: []const u8, assigned: bool) Error!void {
    if (c.implicit_params and name.len == 1) {
        switch (name[0]) {
            'x' => c.implicit_valence = @max(c.implicit_valence, 1),
            'y' => c.implicit_valence = @max(c.implicit_valence, 2),
            'z' => c.implicit_valence = @max(c.implicit_valence, 3),
            else => {},
        }
        if (name[0] == 'x' or name[0] == 'y' or name[0] == 'z') return;
    }
    // `.z.s` is the lambda itself, not a global.
    if (std.mem.eql(u8, name, ".z.s")) return;
    const symbol = try c.vm.intern(name);
    if (std.mem.findScalar(Symbol, c.names.items, symbol) == null) try c.names.append(c.vm.gpa, symbol);
    // Only a bare name assigned with `:` is a local; a dotted name is always global.
    if (!assigned or name[0] == '.') return;
    if (std.mem.findScalar(Symbol, c.params.items, symbol) != null) return;
    if (std.mem.findScalar(Symbol, c.locals.items, symbol) != null) return;
    try c.locals.append(c.vm.gpa, symbol);
}

fn compileNode(c: *Compiler, node: Node.Index) Error!void {
    const vm = c.vm;
    const tree = c.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .empty => try c.emitCode(.empty),
        .grouped_expression => try c.compileNode(tree.nodeData(node).node_and_token[0]),

        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            try c.compileArgs(nodes);
            try c.emitConstant(vm.getUnaryPrimitive(.enlist));
            try c.emitCall(nodes.len);
        },
        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            if (nodes.len == 0) return c.emitCode(.nil);
            for (nodes, 0..) |n, i| {
                try c.compileNode(n);
                if (i + 1 < nodes.len) try c.emitCode(.pop);
            }
        },
        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            const args = nodes[1..];
            // `f[]` applies `f` to `::`.
            if (args.len == 1 and tree.nodeTag(args[0]) == .empty) {
                try c.emitCode(.nil);
            } else {
                try c.compileArgs(args);
            }
            try c.compileNode(nodes[0]);
            // One argument applies with `@`, as q compiles `x[1]`; more need `call n`.
            if (args.len == 1) try c.emitCode(.apply_at) else try c.emitCall(args.len);
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try c.compileNode(rhs);
            // A primitive is an instruction of its own, as q compiles `neg x` to `neg`.
            if (try c.directOpcode(lhs, 1)) |code| return c.emitCode(code);
            try c.compileFunction(lhs);
            try c.emitCode(.apply_at);
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));
            const op_tag = tree.nodeTag(op);
            if ((op_tag == .colon or op_tag == .colon_colon) and tree.nodeTag(lhs) == .identifier) {
                const rhs = maybe_rhs.unwrap() orelse return error.parse;
                try c.compileNode(rhs);
                return c.compileAssign(tree.tokenSlice(tree.nodeMainToken(lhs)), op_tag == .colon_colon);
            }
            // A `.q` name cannot be assigned, not even a symbol alias (q 5.0; q 4.0 assigned
            // through the alias).
            if ((op_tag == .colon or op_tag == .colon_colon) and tree.nodeTag(lhs) == .keyword) return error.assign;
            // Indexed and compound assignment are still to come.
            if (op_tag == .colon) return error.nyi;
            if (maybe_rhs.unwrap()) |rhs| {
                try c.compileNode(rhs);
                try c.compileNode(lhs);
                // An operator is an instruction of its own, as q compiles `x+y` to `+`.
                if (try c.directOpcode(op, 2)) |code| return c.emitCode(code);
                try c.compileConstantNode(op);
                return c.emitCall(2);
            }
            // A missing right operand projects, so `1+` is `+[1]`.
            try c.compileNode(lhs);
            try c.compileConstantNode(op);
            try c.emitCode(.apply_at);
        },

        .identifier => try c.compileIdentifier(tree.tokenSlice(tree.nodeMainToken(node))),
        .keyword => {
            // Keywords are inlined while compiling, as q does: `f:{neg x}` keeps `-:` even
            // if `.q.neg` changes later. A missing entry is left to run-time lookup.
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            if (c.aliasOf(node)) |name| return c.compileIdentifier(name);
            if (vm.qEntry(slice)) |entry| try c.emitConstant(entry.ref()) else try c.compileGlobal(slice);
        },

        .system,
        .select,
        .exec,
        .update,
        .delete_rows,
        .delete_cols,
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => return error.nyi,

        // `0` and `1` have instructions of their own; every other literal is a constant.
        .number_literal => {
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            if (slice.len == 1 or (slice.len == 2 and slice[1] == 'j')) switch (slice[0]) {
                '0' => return c.emitCode(.zero),
                '1' => return c.emitCode(.one),
                else => {},
            };
            try c.compileConstantNode(node);
        },

        // Literals, nested lambdas and the glyphs are values that need no evaluation.
        else => try c.compileConstantNode(node),
    }
}

/// The name a keyword stands for when its `.q` entry is a symbol: with `.q.a:`alias`, `a`
/// reads as `alias` wherever it appears, be that a parameter, a local or a global, as q
/// does. Null for a keyword whose entry is anything else.
fn aliasOf(c: *Compiler, node: Node.Index) ?[]const u8 {
    const entry = c.vm.qEntry(c.tree.tokenSlice(c.tree.nodeMainToken(node))) orelse return null;
    return if (entry.as == .symbol) c.vm.internedString(entry.as.symbol) else null;
}

/// The instruction that applies the primitive or operator a node stands for, or null when
/// the node is not one (a lambda, a name, an expression) or the primitive has no opcode.
/// Only the opcodes between `identity` and `self` apply a value this way.
fn directOpcode(c: *Compiler, node: Node.Index, arity: u8) Error!?ByteCode {
    const tree = c.tree;
    const value: *Value = switch (tree.nodeTag(node)) {
        .keyword => (c.vm.qEntry(tree.tokenSlice(tree.nodeMainToken(node))) orelse return null).ref(),
        .identifier,
        .call,
        .grouped_expression,
        .apply_unary,
        .apply_binary,
        .list,
        .expr_block,
        .lambda,
        => return null,
        else => if (arity == 1) try c.vm.parseUnaryNode(node) else try c.vm.parseNode(node),
    };
    defer value.deref(c.vm.gpa);
    const name = switch (value.as) {
        .unary_primitive => |p| if (arity == 1) @tagName(p) else return null,
        .operator => |o| if (arity == 2) @tagName(o) else return null,
        else => return null,
    };
    const code = std.meta.stringToEnum(ByteCode, name) orelse return null;
    return if (@backingInt(code) >= @backingInt(ByteCode.identity) and @backingInt(code) < @backingInt(ByteCode.self)) code else null;
}

/// The function of `f x`: a glyph is its monadic form, as `-:`; anything else compiles.
fn compileFunction(c: *Compiler, node: Node.Index) Error!void {
    switch (c.tree.nodeTag(node)) {
        .identifier,
        .keyword,
        .builtin,
        .call,
        .grouped_expression,
        .apply_unary,
        .apply_binary,
        .list,
        .expr_block,
        .lambda,
        => try c.compileNode(node),
        else => {
            const value = try c.vm.parseUnaryNode(node);
            errdefer value.deref(c.vm.gpa);
            try c.emitConstant(value);
        },
    }
}

/// Arguments are pushed last to first so the first is on top when the function is called.
fn compileArgs(c: *Compiler, nodes: []const Node.Index) Error!void {
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        try c.compileNode(nodes[i]);
    }
}

fn compileConstantNode(c: *Compiler, node: Node.Index) Error!void {
    const value = try c.vm.parseNode(node);
    errdefer value.deref(c.vm.gpa);
    try c.emitConstant(value);
}

fn compileIdentifier(c: *Compiler, name: []const u8) Error!void {
    if (std.mem.eql(u8, name, ".z.s")) return c.emitCode(.self);
    if (name[0] != '.') {
        const symbol = try c.vm.intern(name);
        if (std.mem.findScalar(Symbol, c.params.items, symbol)) |i| return c.emitParam(i);
        if (std.mem.findScalar(Symbol, c.locals.items, symbol)) |i| return c.emitLocal(i);
    }
    try c.compileGlobal(name);
}

/// A global is one byte, `global` plus its index, as q numbers them.
fn compileGlobal(c: *Compiler, name: []const u8) Error!void {
    try c.emitByte(try c.globalByte(name));
}

/// Assigns the value on top of the stack, which stays there as the expression's value.
/// A parameter or local is `assign` with its slot; a global is `amend` on `()` with the
/// `:` operator, which is how q compiles `x::v` (`.[`x;();:;v]`). `x::v` reaches the
/// global unless `x` is a parameter or local, as in q.
fn compileAssign(c: *Compiler, name: []const u8, global: bool) Error!void {
    if (name[0] != '.') {
        const symbol = try c.vm.intern(name);
        if (std.mem.findScalar(Symbol, c.params.items, symbol)) |i| return c.emitAssign(paramSlot(i));
        if (std.mem.findScalar(Symbol, c.locals.items, symbol)) |i| return c.emitAssign(localSlot(i));
        assert(global);
    }
    try c.emitCode(.empty_list);
    try c.emitCode(.amend);
    try c.emitByte(try c.globalByte(name));
    try c.emitByte(@backingInt(Value.Operator.assign));
}

/// The byte naming a global in an instruction: `global` plus its index, at most 30.
fn globalByte(c: *Compiler, name: []const u8) Error!u8 {
    const symbol = try c.vm.intern(name);
    const index = std.mem.findScalar(Symbol, c.globals.items, symbol) orelse index: {
        try c.globals.append(c.vm.gpa, symbol);
        break :index c.globals.items.len - 1;
    };
    if (index >= @as(usize, @backingInt(ByteCode.constant)) - @backingInt(ByteCode.global)) return error.nyi;
    return @intCast(@backingInt(ByteCode.global) + index);
}

/// q numbers slots from 1: parameters take 1 to 8 and locals start at 9.
fn paramSlot(index: usize) usize {
    return index + 1;
}

fn localSlot(index: usize) usize {
    return index + 9;
}

fn emitParam(c: *Compiler, index: usize) Error!void {
    if (index >= 8) return error.nyi;
    try c.emitByte(@intCast(@backingInt(ByteCode.param_1) + index));
}

fn emitLocal(c: *Compiler, index: usize) Error!void {
    if (index < 22) return c.emitByte(@intCast(@backingInt(ByteCode.local_1) + index));
    try c.emitCode(.local_wide);
    try c.emitByte(std.math.cast(u8, localSlot(index)) orelse return error.nyi);
}

fn emitAssign(c: *Compiler, slot: usize) Error!void {
    try c.emitCode(.assign);
    try c.emitByte(std.math.cast(u8, slot) orelse return error.nyi);
}

fn emitCall(c: *Compiler, args: usize) Error!void {
    try c.emitCode(.call);
    try c.emitByte(std.math.cast(u8, args) orelse return error.nyi);
}

fn emitCode(c: *Compiler, code: ByteCode) Error!void {
    try c.emitByte(@backingInt(code));
}

fn emitByte(c: *Compiler, byte: u8) Error!void {
    try c.bytecode.append(c.vm.gpa, byte);
}

fn emitConstant(c: *Compiler, value: *Value) Error!void {
    for (c.constants.items, 0..) |constant, i| {
        if (value.eql(constant)) {
            defer value.deref(c.vm.gpa);
            return c.emitByte(@intCast(@backingInt(ByteCode.constant) + i));
        }
    }
    if (c.constants.items.len >= @as(usize, 256) - @backingInt(ByteCode.constant)) return error.nyi;
    try c.constants.append(c.vm.gpa, value);
    try c.emitByte(@intCast(@backingInt(ByteCode.constant) + c.constants.items.len - 1));
}

/// q's instruction set. Most instructions are one byte: a primitive or operator between
/// `identity` and `self` applies to the value(s) on the stack, `param_n`, `local_n`,
/// `global` plus an index and `constant` plus an index push, `call` takes the argument
/// count, `assign` takes a slot (parameters 1 to 8, locals from 9), `local_wide` a slot,
/// and `amend` a target (a slot, or `global` plus an index) and an operator index.
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
    equal = 72,
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
