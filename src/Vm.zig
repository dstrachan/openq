const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;
const Symbol = Value.Symbol;
const UnaryPrimitive = Value.UnaryPrimitive;
const Operator = Value.Operator;
const Iterator = Value.Iterator;
const Compiler = q.Compiler;

const Vm = @This();

const Error = Allocator.Error || std.fmt.ParseIntError || Io.Writer.Error;
const RunError = Error || std.zig.ErrorBundle.RenderToStderrError || error{
    assign,
    domain,
    identifier,
    length,
    nyi,
    os,
    parse,
    rank,
    type,
};

io: Io,
gpa: Allocator,
stdout: *Io.Writer,
tree: *const Ast = undefined,
string_bytes: std.ArrayList(u8) = .empty,
string_table: std.HashMapUnmanaged(
    u32,
    void,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
) = .empty,
stack: std.ArrayList(*Value) = .empty,
constants: [@typeInfo(Constant).@"enum".field_names.len]*Value = undefined,
unary_primitives: [@typeInfo(UnaryPrimitive).@"enum".field_names.len]*Value = undefined,
operators: [@typeInfo(Operator).@"enum".field_names.len]*Value = undefined,
iterators: [@typeInfo(Iterator).@"enum".field_names.len]*Value = undefined,
state: *Value = undefined,
/// The current namespace set by `\d`, as an interned path such as `.` or `.Q`.
namespace: Symbol = .empty,

const Constant = enum(u8) {
    empty_list,
    zero,
    one,
    semicolon,
    null_symbol,
};

pub fn init(io: Io, gpa: Allocator, stdout: *Io.Writer) !*Vm {
    const vm = try gpa.create(Vm);
    errdefer gpa.destroy(vm);
    vm.* = .{
        .io = io,
        .gpa = gpa,
        .stdout = stdout,
    };
    errdefer vm.string_table.deinit(gpa);
    errdefer vm.string_bytes.deinit(gpa);

    var constants_created: usize = 0;
    errdefer for (0..constants_created) |i| vm.constants[i].deref(vm.gpa);
    vm.constants[@backingInt(Constant.empty_list)] = try vm.allocValue(.list, 0);
    constants_created += 1;
    vm.constants[@backingInt(Constant.zero)] = try vm.createValue(.long, 0);
    constants_created += 1;
    vm.constants[@backingInt(Constant.one)] = try vm.createValue(.long, 1);
    constants_created += 1;
    vm.constants[@backingInt(Constant.semicolon)] = try vm.createValue(.char, ';');
    constants_created += 1;
    vm.constants[@backingInt(Constant.null_symbol)] = try vm.createValue(.symbol, try vm.intern(""));
    constants_created += 1;
    // The empty symbol must be interned first so that `Symbol.empty` names it.
    assert(vm.constants[@backingInt(Constant.null_symbol)].as.symbol == .empty);
    vm.namespace = try vm.intern(".");
    assert(vm.namespace == .dot);

    var unary_primitives_created: usize = 0;
    errdefer for (0..unary_primitives_created) |i| vm.unary_primitives[i].deref(vm.gpa);
    inline for (&vm.unary_primitives, 0..) |*unary_primitive, i| {
        unary_primitive.* = try vm.createValue(.unary_primitive, @fromBackingInt(@intCast(i)));
        unary_primitives_created += 1;
    }

    var operators_created: usize = 0;
    errdefer for (0..operators_created) |i| vm.operators[i].deref(vm.gpa);
    inline for (&vm.operators, 0..) |*operator, i| {
        operator.* = try vm.createValue(.operator, @fromBackingInt(@intCast(i)));
        operators_created += 1;
    }

    var iterators_created: usize = 0;
    errdefer for (0..iterators_created) |i| vm.iterators[i].deref(vm.gpa);
    inline for (&vm.iterators, 0..) |*iterator, i| {
        iterator.* = try vm.createValue(.iterator, @fromBackingInt(@intCast(i)));
        iterators_created += 1;
    }

    const keys = try vm.allocValue(.symbol_list, 1);
    defer keys.deref(gpa);
    keys.as.symbol_list[0] = .empty;

    vm.state = state: {
        const global_state = global_state: {
            const values = try vm.allocValue(.list, 1);
            values.as.list[0] = vm.getUnaryPrimitive(.identity);
            errdefer values.deref(gpa);

            const dict = try vm.createValue(.dict, .{ .keys = keys, .values = values });
            errdefer comptime unreachable;
            _ = dict.as.dict.keys.ref();
            break :global_state dict;
        };
        defer global_state.deref(gpa);

        const values = try vm.allocValue(.list, 1);
        values.as.list[0] = global_state.ref();
        errdefer values.deref(gpa);

        const dict = try vm.createValue(.dict, .{ .keys = keys, .values = values });
        errdefer comptime unreachable;
        _ = dict.as.dict.keys.ref();
        break :state dict;
    };
    errdefer vm.state.deref(gpa);

    try vm.seedKeywords();
    errdefer comptime unreachable;

    return vm;
}

/// Seeds `.q` with the keywords q.k defines as plain aliases of primitives (`neg:-:`,
/// `count:#:`, `parse:-5!`...), so they work before q.k itself can be loaded. Loading q.k
/// simply reassigns them. Names that q.k defines as lambdas are left for q.k.
fn seedKeywords(vm: *Vm) !void {
    const namespace = (try vm.namespaceAt(".q", true)).?;

    const unary = .{
        .{ "neg", UnaryPrimitive.neg },
        .{ "not", UnaryPrimitive.not },
        .{ "null", UnaryPrimitive.null },
        .{ "string", UnaryPrimitive.string },
        .{ "reciprocal", UnaryPrimitive.reciprocal },
        .{ "floor", UnaryPrimitive.lower },
        .{ "lower", UnaryPrimitive.lower },
        .{ "count", UnaryPrimitive.count },
        .{ "first", UnaryPrimitive.first },
        .{ "reverse", UnaryPrimitive.reverse },
        .{ "distinct", UnaryPrimitive.distinct },
        .{ "group", UnaryPrimitive.group },
        .{ "where", UnaryPrimitive.where },
        .{ "flip", UnaryPrimitive.flip },
        .{ "type", UnaryPrimitive.type },
        .{ "key", UnaryPrimitive.key },
        .{ "til", UnaryPrimitive.key },
        .{ "inv", UnaryPrimitive.key },
        .{ "iasc", UnaryPrimitive.asc },
        .{ "idesc", UnaryPrimitive.desc },
        .{ "value", UnaryPrimitive.value },
        .{ "get", UnaryPrimitive.value },
        .{ "read0", UnaryPrimitive.read_text },
        .{ "read1", UnaryPrimitive.read_binary },
    };
    inline for (unary) |entry| {
        const value = vm.getUnaryPrimitive(entry[1]);
        defer value.deref(vm.gpa);
        try vm.namespaceSet(namespace, try vm.intern(entry[0]), value);
    }

    const binary = .{
        .{ "and", Operator.@"and" },
        .{ "or", Operator.@"or" },
        .{ "mmu", Operator.cast },
        .{ "lsq", Operator.dict },
    };
    inline for (binary) |entry| {
        const value = vm.getOperator(entry[1]);
        defer value.deref(vm.gpa);
        try vm.namespaceSet(namespace, try vm.intern(entry[0]), value);
    }

    const internal = .{
        .{ "parse", -5 },
        .{ "eval", -6 },
        .{ "attr", -2 },
        .{ "hcount", -7 },
        .{ "md5", -15 },
    };
    inline for (internal) |entry| {
        const value = try vm.internalFunction(entry[1]);
        defer value.deref(vm.gpa);
        try vm.namespaceSet(namespace, try vm.intern(entry[0]), value);
    }
}

/// The projection `n!`, which is how q.k defines `parse` (`-5!`) and `eval` (`-6!`).
pub fn internalFunction(vm: *Vm, n: i64) !*Value {
    const args = try vm.gpa.alloc(*Value, 1);
    errdefer vm.gpa.free(args);
    args[0] = try vm.createValue(.long, n);
    errdefer args[0].deref(vm.gpa);
    const callee = vm.getOperator(.dict);
    errdefer callee.deref(vm.gpa);
    return vm.createValue(.projection, .{ .callee = callee, .args = args });
}

/// The parser's view of `.q`, so that q resolves keywords the way kdb+ does.
pub fn resolver(vm: *Vm) Ast.Resolver {
    return .{ .context = vm, .valence = qValence };
}

fn qValence(context: *anyopaque, name: []const u8) ?usize {
    const vm: *Vm = @ptrCast(@alignCast(context));
    const entry = vm.qEntry(name) orelse return null;
    return entry.rank();
}

/// The `.q` entry called `name`, borrowed, or null when there is none.
pub fn qEntry(vm: *Vm, name: []const u8) ?*Value {
    const symbol = vm.lookupSymbol(name) orelse return null;
    const namespace = (vm.namespaceAt(".q", false) catch return null) orelse return null;
    const dict = namespace.as.dict;
    const index = std.mem.findScalar(Symbol, dict.keys.as.symbol_list, symbol) orelse return null;
    return dict.values.as.list[index];
}

pub fn deinit(vm: *Vm) void {
    vm.string_table.deinit(vm.gpa);
    vm.string_bytes.deinit(vm.gpa);
    vm.state.deref(vm.gpa);
    for (vm.constants) |v| v.deref(vm.gpa);
    for (vm.unary_primitives) |v| v.deref(vm.gpa);
    for (vm.operators) |v| v.deref(vm.gpa);
    for (vm.iterators) |v| v.deref(vm.gpa);
    assert(vm.stack.items.len == 0);
    vm.stack.deinit(vm.gpa);
    vm.gpa.destroy(vm);
}

pub fn getConstant(vm: *Vm, constant: Constant) *Value {
    return vm.constants[@backingInt(constant)].ref();
}

pub fn getUnaryPrimitive(vm: *Vm, unary_primitive: UnaryPrimitive) *Value {
    return vm.unary_primitives[@backingInt(unary_primitive)].ref();
}

pub fn getOperator(vm: *Vm, operator: Operator) *Value {
    return vm.operators[@backingInt(operator)].ref();
}

pub fn getIterator(vm: *Vm, iterator: Iterator) *Value {
    return vm.iterators[@backingInt(iterator)].ref();
}

fn parseTree(vm: *Vm, tree: *const Ast) !*Value {
    vm.tree = tree;
    return vm.parseNode(.root);
}

pub fn evalTree(vm: *Vm, tree: *const Ast) !*Value {
    const value = try vm.parseTree(tree);
    defer value.deref(vm.gpa);
    return vm.eval(value);
}

fn push(vm: *Vm, value: *Value) void {
    vm.stack.append(vm.gpa, value) catch @panic("oom");
}

fn applyImpl(vm: *Vm, func: *Value, args: []*Value) RunError!*Value {
    assert(args.len > 0);
    switch (func.as) {
        .list => unreachable,
        .boolean => unreachable,
        .boolean_list => unreachable,
        .long => unreachable,
        .long_list => unreachable,
        .float => unreachable,
        .float_list => unreachable,
        .char => unreachable,
        .char_list => unreachable,
        .symbol => unreachable,
        .symbol_list => unreachable,
        .dict => unreachable,
        .lambda => return error.nyi,
        .unary_primitive => |unary_primitive| {
            if (unary_primitive == .enlist and args.len > 1) return vm.enlist(args);
            if (args.len > 1) return error.rank;
            switch (unary_primitive) {
                ._unused => unreachable,
                .empty => return q.unary_primitives.identity(vm, args[0]),
                inline else => |t| return @field(q.unary_primitives, @tagName(t))(vm, args[0]),
            }
        },
        .operator => |operator| {
            if (args.len > 2) return error.rank;
            if (args.len == 1) {
                var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 1);
                defer values.deinit(vm.gpa);
                errdefer for (values.items) |v| v.deref(vm.gpa);

                values.appendAssumeCapacity(args[0].ref());

                const callee = func.ref();
                errdefer callee.deref(vm.gpa);

                return vm.createValue(.projection, .{
                    .callee = callee,
                    .args = values.toOwnedSliceAssert(),
                });
            }

            const is_first_empty = args[0].isEmpty();
            const is_second_empty = args[1].isEmpty();
            if (is_first_empty and is_second_empty) {
                return func.ref();
            } else if (is_first_empty or is_second_empty) {
                var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 2);
                defer values.deinit(vm.gpa);
                errdefer for (values.items) |v| v.deref(vm.gpa);

                values.appendAssumeCapacity(args[0].ref());
                values.appendAssumeCapacity(args[1].ref());

                const callee = func.ref();
                errdefer callee.deref(vm.gpa);

                return vm.createValue(.projection, .{
                    .callee = callee,
                    .args = values.toOwnedSliceAssert(),
                });
            } else {
                switch (operator) {
                    ._unused => unreachable,
                    inline else => |t| return @field(q.operators, @tagName(t))(vm, args[0], args[1]),
                }
            }
        },
        .iterator => unreachable,
        .projection => |projection| {
            const rank = projection.callee.rank();
            const args_len = len: {
                var len: usize = projection.args.len;
                for (projection.args) |a| {
                    if (a.isEmpty()) len -= 1;
                }
                break :len len;
            } + args.len;
            if (args_len > rank) return error.rank;

            var new_args: std.ArrayList(*Value) = try .initCapacity(vm.gpa, args_len);
            defer new_args.deinit(vm.gpa);

            var j: usize = 0;
            for (0..args_len) |i| {
                if (i < projection.args.len) {
                    if (projection.args[i].isEmpty()) {
                        new_args.appendAssumeCapacity(args[j]);
                        j += 1;
                    } else {
                        new_args.appendAssumeCapacity(projection.args[i]);
                    }
                } else {
                    new_args.appendAssumeCapacity(args[j]);
                    j += 1;
                }
            }

            return vm.applyImpl(projection.callee, new_args.items);
        },
        .each => unreachable,
        .over => unreachable,
        .scan => unreachable,
        .each_prior => unreachable,
        .each_right => unreachable,
        .each_left => unreachable,
    }
}

pub fn enlist(vm: *Vm, args: []*Value) !*Value {
    const is_vector = is_vector: {
        const first_type = switch (args[0].as) {
            .list,
            .boolean_list,
            .long_list,
            .float_list,
            .char_list,
            .symbol_list,
            .lambda,
            .unary_primitive,
            .operator,
            .iterator,
            .projection,
            .each,
            .over,
            .scan,
            .each_prior,
            .each_right,
            .each_left,
            => break :is_vector false,
            .boolean, .long, .float, .char, .symbol, .dict => @backingInt(args[0].as),
        };
        break :is_vector for (args[1..]) |a| {
            if (first_type != @backingInt(a.as)) break false;
        } else true;
    };
    if (is_vector) {
        switch (args[0].as) {
            .list,
            .boolean_list,
            .long_list,
            .float_list,
            .char_list,
            .symbol_list,
            .lambda,
            .unary_primitive,
            .operator,
            .iterator,
            .projection,
            .each,
            .over,
            .scan,
            .each_prior,
            .each_right,
            .each_left,
            => unreachable,
            .boolean => {
                const value = try vm.allocValue(.boolean_list, args.len);
                errdefer comptime unreachable;
                for (value.as.boolean_list, args) |*v, a| v.* = a.as.boolean;
                return value;
            },
            .long => {
                const value = try vm.allocValue(.long_list, args.len);
                errdefer comptime unreachable;
                for (value.as.long_list, args) |*v, a| v.* = a.as.long;
                return value;
            },
            .float => {
                const value = try vm.allocValue(.float_list, args.len);
                errdefer comptime unreachable;
                for (value.as.float_list, args) |*v, a| v.* = a.as.float;
                return value;
            },
            .char => {
                const value = try vm.allocValue(.char_list, args.len);
                errdefer comptime unreachable;
                for (value.as.char_list, args) |*v, a| v.* = a.as.char;
                return value;
            },
            .symbol => {
                const value = try vm.allocValue(.symbol_list, args.len);
                errdefer comptime unreachable;
                for (value.as.symbol_list, args) |*v, a| v.* = a.as.symbol;
                return value;
            },
            .dict => return error.nyi,
        }
    } else {
        const list = try vm.gpa.alloc(*Value, args.len);
        errdefer {
            for (list) |v| v.deref(vm.gpa);
            vm.gpa.free(list);
        }
        var is_projection = false;
        for (list, args) |*v, a| {
            if (!is_projection and a.isEmpty()) is_projection = true;
            v.* = a.ref();
        }

        if (is_projection) {
            return vm.createValue(.projection, .{
                .callee = vm.getUnaryPrimitive(.enlist),
                .args = list,
            });
        } else {
            return vm.createValue(.list, list);
        }
    }
}

pub fn parse(vm: *Vm, x: *Value) !*Value {
    if (x.as != .char_list) return error.type;

    const slice = try vm.gpa.dupeSentinel(u8, x.as.char_list, 0);
    defer vm.gpa.free(slice);

    return vm.parseSource(slice, .q, "<parse>");
}

fn parseSource(vm: *Vm, source: [:0]const u8, mode: Ast.Mode, path: []const u8) !*Value {
    var tree: Ast = try .parse(vm.gpa, source, .{
        .skip_comments = false,
        .mode = mode,
        .resolver = vm.resolver(),
    });
    defer tree.deinit(vm.gpa);
    if (tree.errors.len > 0) {
        try q.printAstErrorsToStderr(vm.gpa, vm.io, tree, path, .auto);
        return error.parse;
    }

    return vm.parseTree(&tree);
}

pub fn createCharList(vm: *Vm, comptime fmt: []const u8, args: anytype) !*Value {
    var buffer: Io.Writer.Allocating = .init(vm.gpa);
    defer buffer.deinit();

    try buffer.writer.print(fmt, args);
    const slice = try buffer.toOwnedSlice();
    errdefer vm.gpa.free(slice);

    return vm.createValue(.char_list, slice);
}

pub fn evalSource(vm: *Vm, source: [:0]const u8, mode: Ast.Mode, path: []const u8) RunError!*Value {
    const value = try vm.parseSource(source, mode, path);
    defer value.deref(vm.gpa);
    return vm.eval(value);
}

pub fn eval(vm: *Vm, x: *Value) RunError!*Value {
    std.log.debug("eval: ({t}) {f}", .{ x.as, x.fmt(vm) });
    switch (x.as) {
        .list => |value| {
            if (value.len == 0) return vm.getConstant(.empty_list);
            if (value.len == 1 and value[0].as == .symbol_list) return value[0].ref();

            if (value[0].as == .char and value[0].as.char == ';') {
                for (value[1 .. value.len - 1]) |val| {
                    const v = try vm.eval(val);
                    defer v.deref(vm.gpa);
                }
                return vm.eval(value[value.len - 1]);
            }

            if (value[0].as == .operator and value[0].as.operator == .assign) {
                if (value.len != 3 or value[2].isEmpty()) return error.rank;

                const v = try vm.eval(value[2]);
                errdefer v.deref(vm.gpa);

                return q.operators.assign(vm, value[1], v);
            }

            const stack_top = vm.stack.items.len;
            try vm.stack.ensureUnusedCapacity(vm.gpa, value.len);
            for (0..value.len) |_| vm.stack.appendAssumeCapacity(vm.getConstant(.empty_list));
            defer vm.stack.shrinkRetainingCapacity(stack_top);

            const stack = vm.stack.items[stack_top..];
            defer for (stack) |v| v.deref(vm.gpa);
            assert(stack.len == value.len);

            var it = std.mem.reverseIterator(value);
            var stack_it = std.mem.reverseIterator(stack);
            while (stack_it.nextPtr()) |entry| {
                const prev_entry = entry.*;
                entry.* = try vm.eval(it.next().?);
                prev_entry.deref(vm.gpa);
            }

            return vm.applyImpl(stack[0], stack[1..]);
        },
        .symbol => return q.unary_primitives.value(vm, x),
        .symbol_list => |value| {
            assert(value.len == 1);
            return vm.createValue(.symbol, value[0]);
        },
        else => return x.ref(),
    }
}

fn parseNode(vm: *Vm, node: Node.Index) Error!*Value {
    const tree = vm.tree;
    const gpa = vm.gpa;

    switch (tree.nodeTag(node)) {
        .root => {
            const nodes = tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
            assert(nodes.len > 0);
            if (nodes.len == 1) return vm.parseNode(nodes[0]);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getConstant(.semicolon));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            const list = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            list.as.list = values.toOwnedSliceAssert();
            return list;
        },
        .empty => return vm.getUnaryPrimitive(.empty),
        .system => {
            // `\d .Q` is `value"\\d .Q"`.
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            const command = try vm.allocValue(.char_list, slice.len);
            errdefer command.deref(vm.gpa);
            @memcpy(command.as.char_list, slice);

            const list = try vm.allocValue(.list, 2);
            errdefer comptime unreachable;
            list.as.list[0] = vm.getUnaryPrimitive(.value);
            list.as.list[1] = command;
            return list;
        },

        .grouped_expression => return vm.parseNode(tree.nodeData(node).node_and_token[0]),
        .empty_list => return vm.getConstant(.empty_list),
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 1);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getUnaryPrimitive(.enlist));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            const list = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            list.as.list = values.toOwnedSliceAssert();
            return list;
        },
        .table_literal => {
            const table = tree.extraData(tree.nodeData(node).extra_and_token[0], Node.Table);

            const table_keys = tree.extraDataSlice(.{
                .start = table.keys_start,
                .end = table.columns_start,
            }, Node.Index);
            const maybe_key_table = if (table_keys.len == 0) null else try vm.parseTable(table_keys);
            defer if (maybe_key_table) |key_table| key_table.deref(vm.gpa);

            const table_values = tree.extraDataSlice(.{
                .start = table.columns_start,
                .end = table.columns_end,
            }, Node.Index);
            assert(table_values.len > 0);
            const value_table = try vm.parseTable(table_values);
            defer value_table.deref(vm.gpa);

            if (maybe_key_table) |key_table| {
                var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 3);
                defer values.deinit(vm.gpa);
                errdefer for (values.items) |v| v.deref(vm.gpa);

                values.appendAssumeCapacity(vm.getOperator(.dict));
                values.appendAssumeCapacity(key_table.ref());
                values.appendAssumeCapacity(value_table.ref());

                const list = try vm.createValue(.list, &.{});
                errdefer comptime unreachable;
                list.as.list = values.toOwnedSliceAssert();
                return list;
            } else {
                return value_table.ref();
            }
        },

        .lambda => {
            var compiler: Compiler = .init(vm, tree);
            defer compiler.deinit();
            return compiler.compile(node);
        },

        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            if (nodes.len == 0) return vm.getUnaryPrimitive(.identity);

            var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, nodes.len + 1);
            defer list.deinit(vm.gpa);
            errdefer for (list.items) |v| v.deref(vm.gpa);

            list.appendAssumeCapacity(vm.getConstant(.semicolon));
            for (nodes) |n| list.appendAssumeCapacity(try vm.parseNode(n));

            const value = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            value.as.list = list.toOwnedSliceAssert();
            return value;
        },

        .colon => return vm.getOperator(.assign),
        .plus => return vm.getOperator(.add),
        .minus => return vm.getOperator(.subtract),
        .asterisk => return vm.getOperator(.multiply),
        .percent => return vm.getOperator(.divide),
        .ampersand => return vm.getOperator(.@"and"),
        .pipe => return vm.getOperator(.@"or"),
        .caret => return vm.getOperator(.fill),
        .equal => return vm.getOperator(.equal),
        .l_angle_bracket => return vm.getOperator(.less_than),
        .l_angle_bracket_equal => @panic("NYI"), // not greater
        .l_angle_bracket_r_angle_bracket => @panic("NYI"), // not equal
        .r_angle_bracket => return vm.getOperator(.greater_than),
        .r_angle_bracket_equal => @panic("NYI"), // not less
        .dollar => return vm.getOperator(.cast),
        .comma => return vm.getOperator(.join),
        .hash => return vm.getOperator(.take),
        .underscore => return vm.getOperator(.drop),
        .tilde => return vm.getOperator(.match),
        .bang => return vm.getOperator(.dict),
        .question_mark => return vm.getOperator(.find),
        .at => return vm.getOperator(.apply_at),
        .dot => return vm.getOperator(.apply),
        .zero_colon => return vm.getOperator(.file_text),
        .one_colon => return vm.getOperator(.file_binary),
        .two_colon => return vm.getOperator(.dynamic_load),

        .colon_colon => return vm.getUnaryPrimitive(.identity),
        .plus_colon => return vm.getUnaryPrimitive(.flip),
        .minus_colon => return vm.getUnaryPrimitive(.neg),
        .asterisk_colon => return vm.getUnaryPrimitive(.first),
        .percent_colon => return vm.getUnaryPrimitive(.reciprocal),
        .ampersand_colon => return vm.getUnaryPrimitive(.where),
        .pipe_colon => return vm.getUnaryPrimitive(.reverse),
        .caret_colon => return vm.getUnaryPrimitive(.null),
        .equal_colon => return vm.getUnaryPrimitive(.group),
        .l_angle_bracket_colon => return vm.getUnaryPrimitive(.asc),
        .r_angle_bracket_colon => return vm.getUnaryPrimitive(.desc),
        .dollar_colon => return vm.getUnaryPrimitive(.string),
        .comma_colon => return vm.getUnaryPrimitive(.list),
        .hash_colon => return vm.getUnaryPrimitive(.count),
        .underscore_colon => return vm.getUnaryPrimitive(.lower),
        .tilde_colon => return vm.getUnaryPrimitive(.not),
        .bang_colon => return vm.getUnaryPrimitive(.key),
        .question_mark_colon => return vm.getUnaryPrimitive(.distinct),
        .at_colon => return vm.getUnaryPrimitive(.type),
        .dot_colon => return vm.getUnaryPrimitive(.value),
        .zero_colon_colon => return vm.getUnaryPrimitive(.read_text),
        .one_colon_colon => return vm.getUnaryPrimitive(.read_binary),

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => unreachable,

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 1);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseNode(nodes[0]));
            if (nodes.len == 2 and tree.nodeTag(nodes[1]) == .empty) {
                values.appendAssumeCapacity(vm.getUnaryPrimitive(.identity));
            } else for (nodes[1..]) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, 2);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseUnaryNode(lhs));
            values.appendAssumeCapacity(try vm.parseNode(rhs));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, if (maybe_rhs == .none) 2 else 3);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseNode(op));
            values.appendAssumeCapacity(try vm.parseNode(lhs));
            // A missing right operand projects on the left one, so `1+` is `+[1]`.
            if (maybe_rhs.unwrap()) |rhs| values.appendAssumeCapacity(try vm.parseNode(rhs));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },

        // TODO: Improve error reporting
        .number_literal => return vm.createNumberLiteral(tree, node),
        .number_list_literal => return vm.createNumberListLiteral(tree, node),
        .string_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);

            const buffer = try vm.gpa.alloc(u8, slice.len - 2);
            defer vm.gpa.free(buffer);

            var fixed: Io.Writer = .fixed(buffer);
            const w = &fixed;

            var index: usize = 1;
            while (true) {
                const b = slice[index];
                switch (b) {
                    '\\' => {
                        switch (slice[index + 1]) {
                            't' => try w.writeByte('\t'),
                            'n' => try w.writeByte('\n'),
                            'r' => try w.writeByte('\r'),
                            '\\' => try w.writeByte('\\'),
                            else => unreachable,
                        }
                        index += 2;
                    },
                    '"' => break,
                    else => {
                        try w.writeByte(b);
                        index += 1;
                    },
                }
            }

            const buffered = fixed.buffered();
            if (buffered.len == 1) return vm.createValue(.char, buffered[0]);
            const char_list = try vm.allocValue(.char_list, buffered.len);
            errdefer comptime unreachable;
            @memcpy(char_list.as.char_list, buffered);
            return char_list;
        },
        .symbol_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const symbol = try vm.intern(slice[1..]);
            const symbol_list = try vm.allocValue(.symbol_list, 1);
            errdefer comptime unreachable;
            symbol_list.as.symbol_list[0] = symbol;
            return symbol_list;
        },
        .symbol_list_literal => {
            const first_token = tree.nodeMainToken(node);
            const last_token = tree.nodeData(node).token;
            const len = last_token - first_token + 1;

            const symbol_list = symbol_list: {
                var list: std.ArrayList(Symbol) = try .initCapacity(vm.gpa, len);
                defer list.deinit(vm.gpa);
                for (first_token..last_token + 1) |tok| {
                    const slice = tree.tokenSlice(@intCast(tok));
                    const symbol = try vm.intern(slice[1..]);
                    list.appendAssumeCapacity(symbol);
                }
                const symbol_list = try vm.createValue(.symbol_list, &.{});
                errdefer symbol_list.deref(vm.gpa);
                symbol_list.as.symbol_list = list.toOwnedSliceAssert();
                break :symbol_list symbol_list;
            };
            errdefer symbol_list.deref(vm.gpa);

            const list = try vm.allocValue(.list, 1);
            errdefer comptime unreachable;
            list.as.list[0] = symbol_list;
            return list;
        },
        .identifier => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const symbol = try vm.intern(slice);
            return vm.createValue(.symbol, symbol);
        },
        .keyword => {
            // q resolves keywords while parsing: `parse "neg 1"` holds `-:`, not `neg`. The
            // entry was there when the parser looked, so it is only missing if `.q` changed
            // since, in which case the name is left to run-time lookup.
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            if (vm.qEntry(slice)) |entry| return entry.ref();
            return vm.createValue(.symbol, try vm.intern(slice));
        },
        .builtin => {
            const builtin = std.meta.stringToEnum(Node.Builtin, tree.tokenSlice(tree.nodeMainToken(node))).?;
            switch (builtin) {
                inline else => |t| return if (comptime t.isDyadic())
                    vm.getOperator(@field(Operator, @tagName(t)))
                else
                    vm.getUnaryPrimitive(@field(UnaryPrimitive, @tagName(t))),
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

fn parseUnaryNode(vm: *Vm, node: Node.Index) !*Value {
    const tree = vm.tree;

    return switch (tree.nodeTag(node)) {
        .bang => vm.getUnaryPrimitive(.key),
        .hash => vm.getUnaryPrimitive(.count),
        .dollar => vm.getUnaryPrimitive(.string),
        .percent => vm.getUnaryPrimitive(.reciprocal),
        .ampersand => vm.getUnaryPrimitive(.where),
        .asterisk => vm.getUnaryPrimitive(.first),
        .plus => vm.getUnaryPrimitive(.flip),
        .comma => vm.getUnaryPrimitive(.list),
        .minus => vm.getUnaryPrimitive(.neg),
        .dot => vm.getUnaryPrimitive(.value),
        .colon => vm.getUnaryPrimitive(.identity),
        .l_angle_bracket => vm.getUnaryPrimitive(.asc),
        .equal => vm.getUnaryPrimitive(.group),
        .r_angle_bracket => vm.getUnaryPrimitive(.desc),
        .question_mark => vm.getUnaryPrimitive(.distinct),
        .at => vm.getUnaryPrimitive(.type),
        .caret => vm.getUnaryPrimitive(.null),
        .underscore => vm.getUnaryPrimitive(.lower),
        .pipe => vm.getUnaryPrimitive(.reverse),
        .tilde => vm.getUnaryPrimitive(.not),
        else => vm.parseNode(node),
    };
}

fn parseTable(vm: *Vm, nodes: []const Node.Index) !*Value {
    assert(nodes.len > 0);

    var keys: std.ArrayList(Symbol) = try .initCapacity(vm.gpa, nodes.len);
    defer keys.deinit(vm.gpa);

    var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, nodes.len);
    defer values.deinit(vm.gpa);
    errdefer for (values.items) |v| v.deref(vm.gpa);

    var i: usize = 0;
    for (nodes) |n| {
        const a = try vm.parseNode(n);
        defer a.deref(vm.gpa);

        switch (a.as) {
            .list => |list| if (list.len == 2 and list[1].as == .symbol) {
                keys.appendAssumeCapacity(list[1].as.symbol);
                values.appendAssumeCapacity(a.ref());
            } else if (list.len == 3 and list[1].as == .symbol) {
                keys.appendAssumeCapacity(list[1].as.symbol);
                values.appendAssumeCapacity(list[2].ref());
            } else unreachable,
            .symbol => {
                keys.appendAssumeCapacity(a.as.symbol);
                values.appendAssumeCapacity(a.ref());
            },
            else => {
                var buf: [8]u8 = undefined;
                const name = if (i > 0)
                    std.fmt.bufPrint(&buf, "x{d}", .{i}) catch "x"
                else
                    "x";
                i += 1;

                keys.appendAssumeCapacity(try vm.intern(name));
                values.appendAssumeCapacity(a.ref());
            },
        }
    }

    assert(keys.items.len == values.items.len);

    const keys_value = keys: {
        const symbol_list = try vm.createValue(.symbol_list, &.{});
        defer symbol_list.deref(vm.gpa);

        symbol_list.as.symbol_list = keys.toOwnedSliceAssert();

        var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 1);
        defer list.deinit(vm.gpa);
        errdefer for (list.items) |v| v.deref(vm.gpa);

        list.appendAssumeCapacity(symbol_list.ref());

        const value = try vm.createValue(.list, &.{});
        errdefer comptime unreachable;
        value.as.list = list.toOwnedSliceAssert();
        break :keys value;
    };
    defer keys_value.deref(vm.gpa);

    const values_value = values: {
        var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, values.items.len + 1);
        defer list.deinit(vm.gpa);
        errdefer for (list.items) |v| v.deref(vm.gpa);

        list.appendAssumeCapacity(vm.getUnaryPrimitive(.enlist));
        list.appendSliceAssumeCapacity(values.items);

        const value = try vm.createValue(.list, &.{});
        errdefer comptime unreachable;
        value.as.list = list.toOwnedSliceAssert();
        break :values value;
    };
    defer values_value.deref(vm.gpa);

    const dict = dict: {
        var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 3);
        defer list.deinit(vm.gpa);
        errdefer for (list.items) |v| v.deref(vm.gpa);

        list.appendAssumeCapacity(vm.getOperator(.dict));
        list.appendAssumeCapacity(keys_value.ref());
        list.appendAssumeCapacity(values_value.ref());

        const value = try vm.createValue(.list, &.{});
        errdefer comptime unreachable;
        value.as.list = list.toOwnedSliceAssert();
        break :dict value;
    };
    defer dict.deref(vm.gpa);

    const flip = flip: {
        var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 2);
        defer list.deinit(vm.gpa);
        errdefer for (list.items) |v| v.deref(vm.gpa);

        list.appendAssumeCapacity(vm.getUnaryPrimitive(.flip));
        list.appendAssumeCapacity(dict.ref());

        const value = try vm.createValue(.list, &.{});
        errdefer comptime unreachable;
        value.as.list = list.toOwnedSliceAssert();
        break :flip value;
    };
    errdefer comptime unreachable;
    return flip;
}

/// Runs a system command given as the text after its backslash, as `\d .Q` or `value "\\d"` would.
/// The command name is the text up to the first space; only exact names are built in, so
/// `\du -hs .` goes to the shell like any other unknown command.
pub fn system(vm: *Vm, command: []const u8) !*Value {
    const name_end = std.mem.findAny(u8, command, " \t") orelse command.len;
    const name = command[0..name_end];
    const args = std.mem.trim(u8, command[name_end..], " \t");

    if (std.mem.eql(u8, name, "d")) {
        if (args.len == 0) return vm.createValue(.symbol, vm.namespace);
        if (args[0] != '.') return error.domain;
        vm.namespace = try vm.intern(args);
        return vm.getUnaryPrimitive(.identity);
    }
    return vm.shell(command);
}

/// Runs `command` the way q does: as `sh -c "<command> ><file>"` with a temporary file, so
/// the redirection binds to the last simple command and overrides any stdout redirection
/// there, while stderr and the output of earlier commands go to the terminal. The file's
/// lines come back as a list of strings; a failing command is an `os` error.
fn shell(vm: *Vm, command: []const u8) !*Value {
    var random: [8]u8 = undefined;
    vm.io.random(&random);
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/tmp/openq{x:0>16}", .{
        std.mem.readInt(u64, &random, .little),
    }) catch unreachable;

    const dir: Io.Dir = .cwd();
    const file = dir.createFile(vm.io, path, .{ .exclusive = true }) catch return error.os;
    file.close(vm.io);
    defer dir.deleteFile(vm.io, path) catch {};

    const script = try std.fmt.allocPrint(vm.gpa, "{s} >{s}", .{ command, path });
    defer vm.gpa.free(script);

    // The child shares the terminal, so flush anything queued ahead of its output.
    try vm.stdout.flush();
    var child = std.process.spawn(vm.io, .{ .argv = &.{ "/bin/sh", "-c", script } }) catch return error.os;
    const term = child.wait(vm.io) catch return error.os;
    if (!term.success()) return error.os;

    const output = dir.readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch return error.os;
    defer vm.gpa.free(output);

    // One string per line; a trailing newline does not add an empty line.
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    const count = if (trimmed.len == 0) 0 else std.mem.countScalar(u8, trimmed, '\n') + 1;
    const lines = try vm.allocValue(.list, count);
    var filled: usize = 0;
    errdefer {
        for (lines.as.list[0..filled]) |line| line.deref(vm.gpa);
        vm.gpa.free(lines.as.list);
        vm.gpa.destroy(lines);
    }
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (filled == count) break;
        const string = try vm.allocValue(.char_list, line.len);
        @memcpy(string.as.char_list, line);
        lines.as.list[filled] = string;
        filled += 1;
    }
    return lines;
}

pub const Home = struct {
    /// The namespace dictionary holding the name. Borrowed, not referenced.
    namespace: *Value,
    name: Symbol,
};

/// Finds the dictionary an identifier lives in and its bare name, as q does: a bare name
/// lives in the current namespace (`\d`), `.Q.qt` lives in the namespace `.Q`, and a
/// single-component name such as `.x` is an entry of the root directory `` ` `` beside the
/// namespaces, distinct from the bare global `x` whatever the current namespace. Missing
/// namespaces are created when `create` is set; otherwise null is returned.
pub fn identifierHome(vm: *Vm, identifier: Symbol, create: bool) !?Home {
    // Interning below may move the string bytes, so work on a copy.
    const string = try vm.gpa.dupe(u8, vm.internedString(identifier));
    defer vm.gpa.free(string);
    assert(string.len > 0);

    if (string[0] != '.') {
        assert(std.mem.findScalar(u8, string, '.') == null);
        const namespace = (try vm.namespaceAt(vm.internedString(vm.namespace), create)) orelse return null;
        return .{ .namespace = namespace, .name = identifier };
    }

    const last_dot = std.mem.findScalarLast(u8, string, '.').?;
    if (last_dot == 0) return .{ .namespace = vm.state, .name = try vm.intern(string[1..]) };
    const namespace = (try vm.namespaceAt(string[0..last_dot], create)) orelse return null;
    return .{ .namespace = namespace, .name = try vm.intern(string[last_dot + 1 ..]) };
}

/// The namespace dictionary at a dotted path, or null when it does not exist. `.` is the
/// root namespace of bare globals; `.Q` and `.a.b` are looked up from the root directory
/// `` ` ``, which holds the namespaces. With `create` set, missing levels are added the way
/// an assignment would. The returned value is borrowed, not referenced.
pub fn namespaceAt(vm: *Vm, path: []const u8, create: bool) !?*Value {
    assert(path.len > 0 and path[0] == '.');
    if (path.len == 1) return vm.state.as.dict.values.as.list[0];

    const owned = try vm.gpa.dupe(u8, path);
    defer vm.gpa.free(owned);

    var namespace = vm.state;
    var it = std.mem.splitScalar(u8, owned[1..], '.');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const symbol = try vm.intern(part);
        const dict = namespace.as.dict;
        if (std.mem.findScalar(Symbol, dict.keys.as.symbol_list, symbol)) |index| {
            namespace = dict.values.as.list[index];
            if (namespace.as != .dict) return error.type;
        } else {
            if (!create) return null;
            const child = try vm.createNamespace();
            defer child.deref(vm.gpa);
            try vm.namespaceSet(namespace, symbol, child);
            namespace = child;
        }
    }
    return namespace;
}

/// An empty namespace: a dictionary whose only entry maps the empty symbol to `::`.
fn createNamespace(vm: *Vm) !*Value {
    const keys = try vm.allocValue(.symbol_list, 1);
    errdefer keys.deref(vm.gpa);
    keys.as.symbol_list[0] = .empty;

    const values = try vm.allocValue(.list, 1);
    errdefer values.deref(vm.gpa);
    values.as.list[0] = vm.getUnaryPrimitive(.identity);

    return vm.createValue(.dict, .{ .keys = keys, .values = values });
}

/// Sets `name` to `value` in the namespace dictionary, replacing any existing entry.
pub fn namespaceSet(vm: *Vm, namespace: *Value, name: Symbol, value: *Value) !void {
    const dict = &namespace.as.dict;
    const keys = dict.keys.as.symbol_list;
    const values = dict.values.as.list;

    if (std.mem.findScalar(Symbol, keys, name)) |index| {
        if (dict.values.ref_count == 0) {
            const old = values[index];
            values[index] = value.ref();
            old.deref(vm.gpa);
        } else {
            // The value list is shared, so replace it rather than mutate it.
            const new_values = try vm.allocValue(.list, values.len);
            errdefer comptime unreachable;
            for (new_values.as.list, values, 0..) |*new_v, old_v, i| {
                new_v.* = if (i == index) value.ref() else old_v.ref();
            }
            dict.values.deref(vm.gpa);
            dict.values = new_values;
        }
        return;
    }

    const new_keys = try vm.allocValue(.symbol_list, keys.len + 1);
    errdefer new_keys.deref(vm.gpa);
    @memcpy(new_keys.as.symbol_list[0..keys.len], keys);
    new_keys.as.symbol_list[keys.len] = name;

    const new_values = try vm.allocValue(.list, values.len + 1);
    errdefer comptime unreachable;
    for (new_values.as.list[0..values.len], values) |*new_v, old_v| new_v.* = old_v.ref();
    new_values.as.list[values.len] = value.ref();

    dict.keys.deref(vm.gpa);
    dict.keys = new_keys;
    dict.values.deref(vm.gpa);
    dict.values = new_values;
}

pub fn createValue(vm: *Vm, comptime tag: Value.Type, value: @FieldType(Value.Union, @tagName(tag))) !*Value {
    const self = try vm.gpa.create(Value);
    errdefer comptime unreachable;
    self.* = .{ .as = @unionInit(Value.Union, @tagName(tag), value) };
    return self;
}

pub fn allocValue(vm: *Vm, comptime tag: Value.Type, len: usize) !*Value {
    const T = @typeInfo(@FieldType(Value.Union, @tagName(tag))).pointer.child;
    const value = try vm.gpa.alloc(T, len);
    errdefer vm.gpa.free(value);
    return vm.createValue(tag, value);
}

pub fn intern(vm: *Vm, bytes: []const u8) !Symbol {
    const str_index: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.appendSlice(vm.gpa, bytes);
    const gop = try vm.string_table.getOrPutContextAdapted(
        vm.gpa,
        vm.string_bytes.items[str_index..],
        std.hash_map.StringIndexAdapter{ .bytes = &vm.string_bytes },
        std.hash_map.StringIndexContext{ .bytes = &vm.string_bytes },
    );
    if (gop.found_existing) {
        vm.string_bytes.shrinkRetainingCapacity(str_index);
        return @fromBackingInt(@intCast(gop.key_ptr.*));
    } else {
        gop.key_ptr.* = str_index;
        try vm.string_bytes.append(vm.gpa, 0);
        return @fromBackingInt(@intCast(str_index));
    }
}

/// The symbol for `bytes` if it has been interned, without interning it.
pub fn lookupSymbol(vm: *Vm, bytes: []const u8) ?Symbol {
    const index = vm.string_table.getKeyAdapted(
        bytes,
        std.hash_map.StringIndexAdapter{ .bytes = &vm.string_bytes },
    ) orelse return null;
    return @fromBackingInt(@intCast(index));
}

pub fn internedString(vm: *Vm, index: Symbol) [:0]const u8 {
    const slice = vm.string_bytes.items[@backingInt(index)..];
    return slice[0..std.mem.findScalar(u8, slice, 0).? :0];
}

pub fn createNumberLiteral(vm: *Vm, tree: *const Ast, node: Node.Index) !*Value {
    assert(tree.nodeTag(node) == .number_literal);
    const main_token = tree.nodeMainToken(node);
    const slice = tree.tokenSlice(main_token);
    return vm.createNumberLiteralSlice(slice);
}

pub fn createNumberLiteralSlice(vm: *Vm, slice: []const u8) !*Value {
    switch (slice[slice.len - 1]) {
        'b' => switch (slice.len - 1) {
            0 => unreachable,
            1 => return vm.createValue(.boolean, slice[0] == '1'),
            else => {
                const boolean_list = try vm.allocValue(.boolean_list, slice.len - 1);
                errdefer comptime unreachable;
                for (boolean_list.as.boolean_list, slice[0 .. slice.len - 1]) |*b, c| b.* = c == '1';
                return boolean_list;
            },
        },
        'j' => return vm.createValue(.long, try q.parseLong(slice[0 .. slice.len - 1])),
        'f' => return vm.createValue(.float, try q.parseFloat(slice[0 .. slice.len - 1])),
        else => return switch (try q.parseNumber(slice)) {
            .long => |v| vm.createValue(.long, v),
            .float => |v| vm.createValue(.float, v),
        },
    }
}

pub fn createNumberListLiteral(vm: *Vm, tree: *const Ast, node: Node.Index) !*Value {
    assert(tree.nodeTag(node) == .number_list_literal);
    const first_token = tree.nodeMainToken(node);
    const last_token = tree.nodeData(node).token;
    const len = last_token - first_token + 1;

    const last_slice = tree.tokenSlice(last_token);
    switch (last_slice[last_slice.len - 1]) {
        'j' => {
            var list: std.ArrayList(i64) = try .initCapacity(vm.gpa, len);
            defer list.deinit(vm.gpa);
            for (first_token..last_token) |tok| {
                const slice = tree.tokenSlice(@intCast(tok));
                list.appendAssumeCapacity(try q.parseLong(slice));
            }
            list.appendAssumeCapacity(try q.parseLong(last_slice[0 .. last_slice.len - 1]));
            return vm.createValue(.long_list, list.toOwnedSliceAssert());
        },
        'f', '.' => {
            var list: std.ArrayList(f64) = try .initCapacity(vm.gpa, len);
            defer list.deinit(vm.gpa);
            for (first_token..last_token) |tok| {
                const slice = tree.tokenSlice(@intCast(tok));
                list.appendAssumeCapacity(try q.parseFloat(slice));
            }
            list.appendAssumeCapacity(try q.parseFloat(last_slice[0 .. last_slice.len - 1]));
            return vm.createValue(.float_list, list.toOwnedSliceAssert());
        },
        '0'...'9' => {
            long: {
                var list: std.ArrayList(i64) = try .initCapacity(vm.gpa, len);
                defer list.deinit(vm.gpa);
                for (first_token..last_token + 1) |tok| {
                    const slice = tree.tokenSlice(@intCast(tok));
                    const number = q.parseNumber(slice) catch break :long;
                    switch (number) {
                        .long => |j| list.appendAssumeCapacity(j),
                        else => break :long,
                    }
                }
                return vm.createValue(.long_list, list.toOwnedSliceAssert());
            }
            var list: std.ArrayList(f64) = try .initCapacity(vm.gpa, len);
            defer list.deinit(vm.gpa);
            for (first_token..last_token + 1) |tok| {
                const slice = tree.tokenSlice(@intCast(tok));
                list.appendAssumeCapacity(try q.parseFloat(slice));
            }
            return vm.createValue(.float_list, list.toOwnedSliceAssert());
        },
        else => |c| std.debug.panic("NYI: {c}", .{c}),
    }
}

const testing = std.testing;

fn expectEval(vm: *Vm, source: [:0]const u8, expected: []const u8) !void {
    const value = try vm.evalSource(source, .q, "<test>");
    defer value.deref(vm.gpa);

    var buffer: Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try buffer.writer.print("{f}", .{value.fmt(vm)});
    try testing.expectEqualStrings(expected, buffer.written());
}

test "\\d sets the namespace for bare names" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\d", "`.");
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "\\d", "`.Q");
    try expectEval(vm, "qt:1", "1");
    try expectEval(vm, "qt", "1");
    try expectEval(vm, ".Q.qt", "1");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "\\d", "`.");
    try expectEval(vm, ".Q.qt", "1");
    try testing.expectError(error.identifier, vm.evalSource("qt", .q, "<test>"));

    // Root names are not visible from inside a namespace.
    try expectEval(vm, "x:2", "2");
    try expectEval(vm, "\\d .Q", "::");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "x", "2");

    // Several statements in one source, as in a script.
    try expectEval(vm, "\\d .Q\nw:7\n\\d .\n.Q.w", "7");
    try expectEval(vm, "\\d", "`.");
}

test "\\d creates a namespace only on assignment" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\d .bar", "::");
    try expectEval(vm, "\\d", "`.bar");
    try expectEval(vm, "\\d .", "::");
    try testing.expectError(error.identifier, vm.evalSource(".bar", .q, "<test>"));

    try expectEval(vm, "\\d .bar", "::");
    try expectEval(vm, "y:3", "3");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, ".bar.y", "3");
    try expectEval(vm, ".bar", "``y!(::;3)");
    try expectEval(vm, ".a.b.c:4", "4");
    try expectEval(vm, ".a.b", "``c!(::;4)");
}

test ".x is a root directory entry, not the global x" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, ".x:1", "1");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, "x:2", "2");
    try expectEval(vm, ".x", "1");
    try expectEval(vm, "x", "2");
    try expectEval(vm, ".x~x", "0b");

    // The root directory is reached the same way from inside a namespace.
    try expectEval(vm, "\\d .foo", "::");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, ".x", "1");
    try expectEval(vm, "x:3", "3");
    try expectEval(vm, ".x", "1");
    try expectEval(vm, ".foo.x", "3");
    try expectEval(vm, ".z:5", "5");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "x", "2");
    try expectEval(vm, ".z", "5");
    try expectEval(vm, ".foo.x", "3");
    try expectEval(vm, ".foo", "``x!(::;3)");

    // Namespaces are not visible as bare globals of the root namespace.
    try testing.expectError(error.identifier, vm.evalSource("foo", .q, "<test>"));
}

fn expectEvalMode(vm: *Vm, mode: Ast.Mode, source: [:0]const u8, expected: []const u8) !void {
    const value = try vm.evalSource(source, mode, "<test>");
    defer value.deref(vm.gpa);

    var buffer: Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try buffer.writer.print("{f}", .{value.fmt(vm)});
    try testing.expectEqualStrings(expected, buffer.written());
}

test "keywords are .q entries resolved while parsing q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // The seeded aliases behave as q.k defines them, and only in q mode, as in kdb+.
    try expectEval(vm, "neg 1", "-1");
    try expectEval(vm, "neg", "-:");
    try expectEval(vm, ".q.neg", "-:");
    try expectEval(vm, "parse \"neg 1\"", "(-:;1)");
    try expectEval(vm, "-5!\"neg 1\"", "(-:;1)");
    try expectEval(vm, "first 1 2", "1");
    try expectEval(vm, "1+", "+[1]");
    try expectEval(vm, "til 3", "0 1 2");
    try expectEval(vm, "1 and", "&[1]");
    try testing.expectError(error.identifier, vm.evalSource("neg 1", .k, "<test>"));
    try expectEvalMode(vm, .k, "-:1", "-1");

    // A valence-2 function placed in .q is infix from the next statement on, not in the same one.
    try expectEval(vm, ".q.p:+", "+");
    try expectEval(vm, "1 p 2", "3");
    try expectEval(vm, "1 p", "+[1]");
    try expectEval(vm, "p", "+");
    try expectEval(vm, "parse \"1 p 2\"", "(+;1;2)");
    try testing.expectError(error.identifier, vm.evalSource("1 p 2", .k, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource(".q.p2:+;1 p2 2", .q, "<test>"));

    // Entries of other valence are inlined as nouns.
    try expectEval(vm, ".q.v:5", "5");
    try expectEval(vm, "v", "5");
    try expectEval(vm, "v+1", "6");

    // Keyword names cannot be assigned bare, in any namespace; k mode still can, as q.k does.
    try testing.expectError(error.assign, vm.evalSource("neg:1", .q, "<test>"));
    try expectEval(vm, "\\d .foo", "::");
    try testing.expectError(error.assign, vm.evalSource("p:1", .q, "<test>"));
    try expectEval(vm, "\\d .", "::");
    try expectEvalMode(vm, .k, "\\d .q", "::");
    try expectEvalMode(vm, .k, "neg:-:", "-:");
    try expectEvalMode(vm, .k, "\\d .", "::");
    try expectEval(vm, "neg 1", "-1");
}

test "natives from .Q.res work in both modes" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "enlist 1", ",1");
    try expectEvalMode(vm, .k, "enlist 1", ",1");
    try expectEval(vm, "enlist", "enlist");
    try expectEvalMode(vm, .k, ",:", ",:");
    try expectEval(vm, "abs", "abs");
    try testing.expectError(error.nyi, vm.evalSource("abs[-1]", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("abs[-1]", .k, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("count[1 2]", .k, "<test>"));

    try expectEval(vm, "in", "in");
    try expectEval(vm, "1 in", "in[1]");
    try expectEvalMode(vm, .k, "1 in", "in[1]");
    try expectEval(vm, "2 xexp", "xexp[2]");
    try expectEval(vm, "(1 in;2 bin)", "(in[1];bin[2])");
    try testing.expectError(error.nyi, vm.evalSource("1 in 1 2", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("(*1 2)in 1 4", .k, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("(n:1 2)bin 2", .k, "<test>"));
}

test "system commands through value" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "value \"\\\\d\"", "`.");
    try expectEval(vm, "value \"\\\\d .Q\"", "::");
    try expectEval(vm, "value \"\\\\d\"", "`.Q");
    try expectEval(vm, "value \"1+2\"", "3");
    try expectEval(vm, "value \"\"", "::");
    try testing.expectError(error.domain, vm.evalSource("\\d Q", .q, "<test>"));
}

test "unknown system commands run in the shell" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\echo hi", ",\"hi\"");
    try expectEval(vm, "\\printf 'a\\nb\\n'", "(,\"a\";,\"b\")");
    try expectEval(vm, "\\printf 'a\\nb'", "(,\"a\";,\"b\")");
    try expectEval(vm, "\\true", "()");
    try expectEval(vm, "value \"\\\\echo hi\"", ",\"hi\"");
    try expectEval(vm, "type value \"\\\\echo hi\"", "0");

    // As in q, the command runs as `sh -c "<command> >file"`: the capture binds to the last
    // simple command and wins over its own stdout redirection, and stderr is not captured.
    try expectEval(vm, "\\echo err >/dev/null", ",\"err\"");
    try expectEval(vm, "\\echo err 1>&2", ",\"err\"");
    try expectEval(vm, "\\echo A >/dev/null; echo D", ",,\"D\"");
    try expectEval(vm, "\\printf x >/dev/null; printf y", ",,\"y\"");
    try expectEval(vm, "\\(echo err 1>&2) 2>/dev/null", "()");

    // Only the exact name `d` is the namespace command.
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "\\d", "`.Q");
    try expectEval(vm, "type value \"\\\\du -hs .\"", "0");
    try testing.expectError(error.os, vm.evalSource("\\dx 2>/dev/null", .q, "<test>"));
    try testing.expectError(error.os, vm.evalSource("\\false", .q, "<test>"));
    try testing.expectError(error.os, vm.evalSource("\\nonexistent_cmd_xyz 2>/dev/null", .q, "<test>"));
}

test "assignment replaces an existing global" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "z:1", "1");
    try expectEval(vm, "z:5", "5");
    try expectEval(vm, "z", "5");
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "z:`a", "`a");
    try expectEval(vm, "z:`b", "`b");
    try expectEval(vm, ".Q.z", "`b");
}
