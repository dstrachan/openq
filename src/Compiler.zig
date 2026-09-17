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
    const lambda = tree.extraData(extra_index, Node.Lambda);

    // A lambda made in k mode carries a `k)` prefix in its source, as q shows it
    // (`k){x+y}`), in `value` and in `-3!` alike.
    const text = tree.source[tree.tokenStart(l_brace) .. tree.tokenStart(r_brace) + 1];
    const source = if (lambda.k_mode) try std.mem.concat(vm.gpa, u8, &.{ "k)", text }) else try vm.gpa.dupe(u8, text);
    errdefer vm.gpa.free(source);

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
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            for (nodes, 0..) |n, i| {
                // `if`, `while` and `do` are control words, not globals.
                if (i == 0 and tree.nodeTag(node) == .call and c.controlWord(n) != null) continue;
                try c.scan(n);
            }
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try c.scan(lhs);
            try c.scan(rhs);
        },
        .apostrophe, .apostrophe_colon, .slash, .slash_colon, .backslash, .backslash_colon => {
            if (tree.nodeData(node).opt_node.unwrap()) |function| try c.scan(function);
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));
            const op_tag = tree.nodeTag(op);
            if (assignOperator(op_tag) != null and tree.nodeTag(lhs) == .identifier) {
                // Only a plain `x:v` makes a name a local. `x::v`, `x+:v` and `x[i]:v` modify
                // whatever the name already is: a parameter, a local, or otherwise a global.
                try c.noteName(tree.tokenSlice(tree.nodeMainToken(lhs)), op_tag == .colon);
            } else {
                try c.scan(lhs);
            }
            // The operator may be an expression of its own, as a derived function `f'`.
            try c.scan(op);
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
            // `$[c;a;b]` with three or more arguments is the conditional, and the control
            // words compile to jumps; none of them evaluates arguments ahead of time.
            if (tree.nodeTag(nodes[0]) == .dollar and args.len >= 3) return c.compileCond(args);
            if (c.controlWord(nodes[0])) |word| return switch (word) {
                .@"if" => c.compileIf(args),
                .@"while" => c.compileWhile(args),
                .do => c.compileDo(args),
            };
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
            // Applied to a function form, anything composes, as at the top level: the two
            // functions are pushed and `'` called on them (`{-_-:}` gives `-_-:`).
            if (Vm.isFunctionForm(tree, rhs)) {
                try c.compileOperand(rhs);
                try c.compileFunction(lhs);
                try c.emitConstant(vm.getIterator(.each));
                return c.emitCall(2);
            }
            try c.compileNode(rhs);
            // `'x` signals an error; `f'x` is the each of `f`.
            if (tree.nodeTag(lhs) == .apostrophe and tree.nodeData(lhs).opt_node == .none) return c.emitCode(.signal);
            // A primitive is an instruction of its own, as q compiles `neg x` to `neg`.
            if (try c.directOpcode(lhs, 1)) |code| {
                try c.emitCode(code);
                // `:x` is the identity followed by a return, as q compiles it.
                if (tree.nodeTag(lhs) == .colon) try c.emitCode(.@"return");
                return;
            }
            try c.compileFunction(lhs);
            try c.emitCode(.apply_at);
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));
            const op_tag = tree.nodeTag(op);
            if (assignOperator(op_tag)) |operator| {
                const rhs = maybe_rhs.unwrap() orelse return error.parse;
                switch (tree.nodeTag(lhs)) {
                    .identifier => {
                        try c.compileNode(rhs);
                        const name = tree.tokenSlice(tree.nodeMainToken(lhs));
                        if (operator == .assign) return c.compileAssign(name, op_tag == .colon_colon);
                        // `x+:v` amends the whole value: `.[`x;();+;v]`.
                        try c.emitCode(.empty_list);
                        return c.emitAmend(name, operator);
                    },
                    // A `.q` name cannot be assigned, not even a symbol alias (q 5.0; q 4.0
                    // assigned through the alias).
                    .keyword => return error.assign,
                    .call => {
                        // `x[i;j]:v` amends at an index list built by `enlist`, as q does.
                        const nodes = tree.extraDataSlice(tree.nodeData(lhs).extra_range, Node.Index);
                        if (tree.nodeTag(nodes[0]) != .identifier) return error.nyi;
                        try c.compileNode(rhs);
                        const indices = nodes[1..];
                        // An elided index, as in `a[;1]`, means every item: `::`.
                        var i = indices.len;
                        while (i > 0) {
                            i -= 1;
                            if (tree.nodeTag(indices[i]) == .empty) try c.emitCode(.nil) else try c.compileNode(indices[i]);
                        }
                        try c.emitConstant(vm.getUnaryPrimitive(.enlist));
                        if (indices.len == 1) try c.emitCode(.apply_at) else try c.emitCall(indices.len);
                        return c.emitAmend(tree.tokenSlice(tree.nodeMainToken(nodes[0])), operator);
                    },
                    else => return error.nyi,
                }
            }
            if (maybe_rhs.unwrap()) |rhs| {
                // A function form on the right composes with the projection on the left, as
                // q compiles `{1+-:}` to `-:`, `+[1]`, then `'` called on both.
                if (Vm.isFunctionForm(tree, rhs)) {
                    try c.compileNode(rhs);
                    try c.compileNode(lhs);
                    try c.compileOperand(op);
                    try c.emitCode(.apply_at);
                    try c.emitConstant(vm.getIterator(.each));
                    return c.emitCall(2);
                }
                try c.compileNode(rhs);
                try c.compileNode(lhs);
                // An operator is an instruction of its own, as q compiles `x+y` to `+`; a
                // derived function (`x+/y`) or a keyword is pushed and called.
                if (try c.directOpcode(op, 2)) |code| return c.emitCode(code);
                try c.compileOperand(op);
                return c.emitCall(2);
            }
            // A missing right operand projects, so `1+` is `+[1]`.
            try c.compileNode(lhs);
            try c.compileOperand(op);
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

        // An iterator on a function is the function followed by the iterator instruction,
        // as q compiles `x+/y` to push `+` then `over`; a bare iterator is a constant.
        .apostrophe, .apostrophe_colon, .slash, .slash_colon, .backslash, .backslash_colon => |tag| {
            const iterator = Vm.iteratorOf(tag);
            const function = tree.nodeData(node).opt_node.unwrap() orelse return c.emitConstant(vm.getIterator(iterator));
            try c.compileOperand(function);
            try c.emitCode(switch (iterator) {
                .each => .each,
                .over => .over,
                .scan => .scan,
                .each_prior => .each_prior,
                .each_right => .each_right,
                .each_left => .each_left,
            });
        },

        .system,
        .select,
        .exec,
        .update,
        .delete_rows,
        .delete_cols,
        => return error.nyi,

        // A symbol literal is a one-item list in a parse tree, so that evaluating it does
        // not look the name up; as a constant it is the atom itself.
        .symbol_literal => {
            const literal = try vm.parseNode(node);
            defer literal.deref(vm.gpa);
            assert(literal.as == .symbol_list and literal.as.symbol_list.len == 1);
            const atom = try vm.createValue(.symbol, literal.as.symbol_list[0]);
            errdefer atom.deref(vm.gpa);
            try c.emitConstant(atom);
        },
        // A symbol list literal is wrapped in a one-item list in a parse tree for the same
        // reason; the constant is the list itself.
        .symbol_list_literal => {
            const wrapped = try vm.parseNode(node);
            defer wrapped.deref(vm.gpa);
            assert(wrapped.as == .list and wrapped.as.list.len == 1);
            try c.emitConstant(wrapped.as.list[0].ref());
        },
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
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
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

/// The function under an iterator: a glyph is its dyadic operator, as `+/` folds with `+`;
/// anything else compiles.
fn compileOperand(c: *Compiler, node: Node.Index) Error!void {
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
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => try c.compileNode(node),
        else => try c.compileConstantNode(node),
    }
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
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
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
    try c.emitAmend(name, .assign);
}

/// `amend target op`: the index list is on top of the stack and the value below it. The
/// target is a slot for a parameter or local and `global` plus an index otherwise.
fn emitAmend(c: *Compiler, name: []const u8, operator: Value.Operator) Error!void {
    try c.emitCode(.amend);
    if (name[0] != '.') {
        const symbol = try c.vm.intern(name);
        if (std.mem.findScalar(Symbol, c.params.items, symbol)) |i| {
            try c.emitByte(@intCast(paramSlot(i)));
            return c.emitByte(@backingInt(operator));
        }
        if (std.mem.findScalar(Symbol, c.locals.items, symbol)) |i| {
            try c.emitByte(std.math.cast(u8, localSlot(i)) orelse return error.nyi);
            return c.emitByte(@backingInt(operator));
        }
    }
    try c.emitByte(try c.globalByte(name));
    try c.emitByte(@backingInt(operator));
}

/// The operator an assignment glyph applies: `:` and `::` assign, `+:` adds and so on.
pub fn assignOperator(tag: Node.Tag) ?Value.Operator {
    return switch (tag) {
        .colon, .colon_colon => .assign,
        .plus_colon => .add,
        .minus_colon => .subtract,
        .asterisk_colon => .multiply,
        .percent_colon => .divide,
        .ampersand_colon => .@"and",
        .pipe_colon => .@"or",
        .caret_colon => .fill,
        .equal_colon => .equal,
        .l_angle_bracket_colon => .less_than,
        .r_angle_bracket_colon => .greater_than,
        .dollar_colon => .cast,
        .comma_colon => .join,
        .hash_colon => .take,
        .underscore_colon => .drop,
        .tilde_colon => .match,
        .bang_colon => .dict,
        .question_mark_colon => .find,
        .at_colon => .apply_at,
        .dot_colon => .apply,
        else => null,
    };
}

const ControlWord = enum { @"if", @"while", do };

fn controlWord(c: *Compiler, node: Node.Index) ?ControlWord {
    if (c.tree.nodeTag(node) != .identifier) return null;
    return std.meta.stringToEnum(ControlWord, c.tree.tokenSlice(c.tree.nodeMainToken(node)));
}

/// `$[c1;a1;c2;a2;...;b]`: each condition jumps past its branch when false, each branch
/// jumps to the end, and a missing final branch is `::`. An empty branch is `::` too.
fn compileCond(c: *Compiler, args: []const Node.Index) Error!void {
    var end_jumps: std.ArrayList(usize) = .empty;
    defer end_jumps.deinit(c.vm.gpa);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        try c.compileNode(args[i]);
        const skip = try c.emitJump(.jump_if_false);
        try c.compileBranch(args[i + 1]);
        try end_jumps.append(c.vm.gpa, try c.emitJump(.jump));
        try c.patchJump(skip);
    }
    if (i < args.len) try c.compileBranch(args[i]) else try c.emitCode(.nil);
    for (end_jumps.items) |jump| try c.patchJump(jump);
}

fn compileBranch(c: *Compiler, node: Node.Index) Error!void {
    if (c.tree.nodeTag(node) == .empty) return c.emitCode(.nil);
    try c.compileNode(node);
}

/// `if[c;s1;s2...]` runs the statements when `c` holds and is `::`.
fn compileIf(c: *Compiler, args: []const Node.Index) Error!void {
    if (args.len == 0) return error.parse;
    try c.compileNode(args[0]);
    const skip = try c.emitJump(.jump_if_false);
    try c.compileStatements(args[1..]);
    try c.patchJump(skip);
    try c.emitCode(.nil);
}

/// `while[c;s1;s2...]` runs the statements as long as `c` holds and is `::`.
fn compileWhile(c: *Compiler, args: []const Node.Index) Error!void {
    if (args.len == 0) return error.parse;
    const top = c.bytecode.items.len;
    try c.compileNode(args[0]);
    const exit = try c.emitJump(.jump_if_false);
    try c.compileStatements(args[1..]);
    try c.emitJumpBack(top);
    try c.patchJump(exit);
    try c.emitCode(.nil);
}

/// `do[n;s1;s2...]` runs the statements `n` times and is `::`.
fn compileDo(c: *Compiler, args: []const Node.Index) Error!void {
    if (args.len == 0) return error.parse;
    try c.compileNode(args[0]);
    try c.emitCode(.do_init);
    const top = c.bytecode.items.len;
    const exit = try c.emitJump(.do_step);
    try c.compileStatements(args[1..]);
    try c.emitJumpBack(top);
    try c.patchJump(exit);
    try c.emitCode(.nil);
}

/// Statements inside a control word: each is run and its value dropped.
fn compileStatements(c: *Compiler, nodes: []const Node.Index) Error!void {
    for (nodes) |n| {
        if (c.tree.nodeTag(n) == .empty) continue;
        try c.compileNode(n);
        try c.emitCode(.pop);
    }
}

/// Emits a forward jump with a placeholder offset and returns where the offset lives.
fn emitJump(c: *Compiler, code: ByteCode) Error!usize {
    try c.emitCode(code);
    const operand = c.bytecode.items.len;
    try c.emitByte(0);
    try c.emitByte(0);
    return operand;
}

/// Points the jump whose offset lives at `operand` to the next instruction.
fn patchJump(c: *Compiler, operand: usize) Error!void {
    const offset = std.math.cast(u16, c.bytecode.items.len - operand) orelse return error.nyi;
    std.mem.writeInt(u16, c.bytecode.items[operand..][0..2], offset, .little);
}

fn emitJumpBack(c: *Compiler, target: usize) Error!void {
    try c.emitCode(.jump_back);
    const operand = c.bytecode.items.len;
    const offset = std.math.cast(u16, operand - target) orelse return error.nyi;
    try c.emitByte(@truncate(offset));
    try c.emitByte(@truncate(offset >> 8));
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
    /// `'x`: raises the value on the stack as an error.
    signal = 1,
    pop = 2,
    assign = 3,
    amend = 4,
    /// The jumps take a two-byte little-endian offset relative to the operand's own
    /// position: forward for `jump` and `jump_if_false` (which pops its condition) and
    /// backward for `jump_back`. `do_init` pops the count and `do_step` counts it down,
    /// jumping forward when it is spent.
    jump = 5,
    jump_if_false = 6,
    do_init = 7,
    do_step = 8,
    jump_back = 9,
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
