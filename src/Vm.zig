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
/// Significant digits shown for floats, set by `\P`; 0 means the full 17.
precision: u8 = 7,
/// The time zone of `.z.P` and the other local clock variables, read once at init.
local_zone: q.clock.LocalZone = .utc,

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
    // `.z` exists from the start so that `.z.ph:...` and friends have somewhere to go; the
    // clock variables are computed on every read rather than stored in it.
    _ = try vm.namespaceAt(".z", true);
    errdefer comptime unreachable;

    vm.local_zone = .load(io, gpa);
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
    vm.local_zone.deinit();
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
        .byte => unreachable,
        .byte_list => unreachable,
        .short => unreachable,
        .short_list => unreachable,
        .int => unreachable,
        .int_list => unreachable,
        .long => unreachable,
        .long_list => unreachable,
        .real => unreachable,
        .real_list => unreachable,
        .float => unreachable,
        .float_list => unreachable,
        .char => unreachable,
        .char_list => unreachable,
        .symbol => unreachable,
        .symbol_list => unreachable,
        .timestamp => unreachable,
        .timestamp_list => unreachable,
        .month => unreachable,
        .month_list => unreachable,
        .date => unreachable,
        .date_list => unreachable,
        .datetime => unreachable,
        .datetime_list => unreachable,
        .timespan => unreachable,
        .timespan_list => unreachable,
        .minute => unreachable,
        .minute_list => unreachable,
        .second => unreachable,
        .second_list => unreachable,
        .time => unreachable,
        .time_list => unreachable,
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
            .byte_list,
            .short_list,
            .int_list,
            .long_list,
            .real_list,
            .float_list,
            .char_list,
            .symbol_list,
            .timestamp_list,
            .month_list,
            .date_list,
            .datetime_list,
            .timespan_list,
            .minute_list,
            .second_list,
            .time_list,
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
            .boolean,
            .byte,
            .short,
            .int,
            .long,
            .real,
            .float,
            .char,
            .symbol,
            .timestamp,
            .month,
            .date,
            .datetime,
            .timespan,
            .minute,
            .second,
            .time,
            .dict,
            => @backingInt(args[0].as),
        };
        break :is_vector for (args[1..]) |a| {
            if (first_type != @backingInt(a.as)) break false;
        } else true;
    };
    if (is_vector) {
        switch (args[0].as) {
            .list,
            .boolean_list,
            .byte_list,
            .short_list,
            .int_list,
            .long_list,
            .real_list,
            .float_list,
            .char_list,
            .symbol_list,
            .timestamp_list,
            .month_list,
            .date_list,
            .datetime_list,
            .timespan_list,
            .minute_list,
            .second_list,
            .time_list,
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
            inline .boolean,
            .byte,
            .short,
            .int,
            .long,
            .real,
            .float,
            .char,
            .symbol,
            .timestamp,
            .month,
            .date,
            .datetime,
            .timespan,
            .minute,
            .second,
            .time,
            => |_, tag| {
                const list_tag = @field(Value.Type, @tagName(tag) ++ "_list");
                const value = try vm.allocValue(list_tag, args.len);
                errdefer comptime unreachable;
                for (@field(value.as, @tagName(list_tag)), args) |*v, a| v.* = @field(a.as, @tagName(tag));
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
                            '"' => try w.writeByte('"'),
                            '/' => try w.writeByte('/'),
                            // Three octal digits, as `"\001"`; the tokenizer checked them.
                            '0'...'3' => {
                                try w.writeByte(std.fmt.parseInt(u8, slice[index + 1 .. index + 4], 8) catch unreachable);
                                index += 2;
                            },
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
    if (std.mem.eql(u8, name, "P")) {
        if (args.len == 0) return vm.createValue(.int, vm.precision);
        const precision = std.fmt.parseInt(u8, args, 10) catch return error.domain;
        vm.precision = @min(precision, q.decimal.max_precision);
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

/// `.z.P` and the other clock variables, which q reads from the clock at every reference
/// rather than storing: `D` date, `P` timestamp, `T` time, `N` timespan since midnight and
/// `Z` datetime, in local time for the capital letter and UTC for the lowercase one. Null
/// for any other identifier.
pub fn clockVariable(vm: *Vm, identifier: Symbol) !?*Value {
    const string = vm.internedString(identifier);
    if (string.len != 4 or !std.mem.startsWith(u8, string, ".z.")) return null;
    const letter = string[3];
    if (std.mem.findScalar(u8, "DdPpTtNnZz", letter) == null) return null;

    const utc = q.clock.now(vm.io);
    const nanos = if (std.ascii.isUpper(letter)) local: {
        const unix_seconds = @divFloor(utc, q.literal.ns_per_second) + q.literal.epoch_days * 86_400;
        break :local utc + vm.local_zone.offset(unix_seconds) * q.literal.ns_per_second;
    } else utc;
    const day = @divFloor(nanos, q.literal.ns_per_day);
    const since_midnight = @mod(nanos, q.literal.ns_per_day);

    return switch (std.ascii.toLower(letter)) {
        'd' => try vm.createValue(.date, @intCast(day)),
        'p' => try vm.createValue(.timestamp, nanos),
        't' => try vm.createValue(.time, @intCast(@divFloor(since_midnight, 1_000_000))),
        'n' => try vm.createValue(.timespan, since_midnight),
        'z' => try vm.createValue(.datetime, @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(q.literal.ns_per_day))),
        else => unreachable,
    };
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
    if (slice.len >= 2 and slice[0] == '0' and slice[1] == 'x') return vm.createByteLiteral(slice[2..]);
    // `101b` is a boolean list in one token; every other literal is an atom.
    if (slice[slice.len - 1] == 'b' and slice.len > 2) {
        const boolean_list = try vm.allocValue(.boolean_list, slice.len - 1);
        errdefer comptime unreachable;
        for (boolean_list.as.boolean_list, slice[0 .. slice.len - 1]) |*b, c| b.* = c == '1';
        return boolean_list;
    }
    switch (try q.literal.parse(slice)) {
        inline else => |value, kind| return vm.createValue(comptime kind.atomType(), value),
    }
}

/// `0x0102` is a byte list, `0x01` a byte atom and `0x` the empty byte list.
fn createByteLiteral(vm: *Vm, hex: []const u8) !*Value {
    if (hex.len % 2 != 0) return error.InvalidCharacter;
    const len = hex.len / 2;
    if (len == 1) return vm.createValue(.byte, try std.fmt.parseInt(u8, hex, 16));
    const list = try vm.allocValue(.byte_list, len);
    errdefer list.deref(vm.gpa);
    for (list.as.byte_list, 0..) |*b, i| b.* = try std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16);
    return list;
}

/// A list literal takes its type from its last item, as `1 0Nh` or `2023.04.17 0Nd`; a list
/// of untyped numbers is long unless one of them needs to be a float.
pub fn createNumberListLiteral(vm: *Vm, tree: *const Ast, node: Node.Index) !*Value {
    assert(tree.nodeTag(node) == .number_list_literal);
    const first_token = tree.nodeMainToken(node);
    const last_token = tree.nodeData(node).token;

    switch (try q.literal.kindOf(tree.tokenSlice(last_token))) {
        .long => {
            // Any float-shaped item, including a lowercase `0n`, makes the whole list float.
            for (first_token..last_token) |tok| {
                if (try q.literal.kindOf(tree.tokenSlice(@intCast(tok))) == .float) {
                    return vm.createTypedList(tree, .float, first_token, last_token);
                }
            }
            return vm.createTypedList(tree, .long, first_token, last_token);
        },
        inline else => |kind| return vm.createTypedList(tree, kind, first_token, last_token),
    }
}

fn createTypedList(vm: *Vm, tree: *const Ast, comptime kind: q.literal.Kind, first_token: Ast.TokenIndex, last_token: Ast.TokenIndex) !*Value {
    const list = try vm.allocValue(comptime kind.listType(), last_token - first_token + 1);
    errdefer list.deref(vm.gpa);
    const items = @field(list.as, @tagName(kind.listType()));
    for (items, first_token..) |*item, tok| {
        item.* = @field(try q.literal.parseAs(kind, tree.tokenSlice(@intCast(tok))), @tagName(kind));
    }
    return list;
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
    try expectEval(vm, "type value \"\\\\echo hi\"", "0h");

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
    try expectEval(vm, "type value \"\\\\du -hs .\"", "0h");
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

test "short, int, real and byte literals display as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1h", "1h");
    try expectEval(vm, "-1h", "-1h");
    try expectEval(vm, "0Nh", "0Nh");
    try expectEval(vm, "0Wh", "0Wh");
    try expectEval(vm, "-0Wh", "-0Wh");
    try expectEval(vm, "32767h", "0Wh");
    try expectEval(vm, "1 2h", "1 2h");
    try expectEval(vm, "1 0Nh", "1 0Nh");
    try expectEval(vm, "0N 1h", "0N 1h");
    try expectEval(vm, "0W -0W 1h", "0W -0W 1h");
    try expectEval(vm, "enlist 1h", ",1h");

    try expectEval(vm, "1i", "1i");
    try expectEval(vm, "0Ni", "0Ni");
    try expectEval(vm, "0Wi", "0Wi");
    try expectEval(vm, "-0Wi", "-0Wi");
    try expectEval(vm, "1 2i", "1 2i");
    try expectEval(vm, "0N 1i", "0N 1i");
    try expectEval(vm, "enlist 1i", ",1i");

    try expectEval(vm, "1e", "1e");
    try expectEval(vm, "1.5e", "1.5e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "0Ne", "0Ne");
    try expectEval(vm, "0We", "0we");
    try expectEval(vm, "-0We", "-0we");
    try expectEval(vm, "1 2e", "1 2e");
    try expectEval(vm, "1 2.5e", "1 2.5e");
    try expectEval(vm, "1.5 2e", "1.5 2e");
    try expectEval(vm, "1 0Ne", "1 0Ne");
    try expectEval(vm, "0.1 0.2e", "0.1 0.2e");
    try expectEval(vm, "100000e", "100000e");
    try expectEval(vm, "1000000e", "1000000e");
    try expectEval(vm, "enlist 1e", ",1e");

    try expectEval(vm, "0x01", "0x01");
    try expectEval(vm, "0x00", "0x00");
    try expectEval(vm, "0xff", "0xff");
    try expectEval(vm, "0x0102", "0x0102");
    try expectEval(vm, "enlist 0x01", ",0x01");
    try expectEval(vm, "0x", "`byte$()");
    try expectEval(vm, "enlist 0x", ",`byte$()");

    try expectEval(vm, "-3!(1h;2i;3e;0x04)", "\"(1h;2i;3e;0x04)\"");
}

test "type returns a short" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "type 1b", "-1h");
    try expectEval(vm, "type 101b", "1h");
    try expectEval(vm, "type 0x01", "-4h");
    try expectEval(vm, "type 0x0102", "4h");
    try expectEval(vm, "type 1h", "-5h");
    try expectEval(vm, "type 1 2h", "5h");
    try expectEval(vm, "type 1i", "-6h");
    try expectEval(vm, "type 0N", "-7h");
    try expectEval(vm, "type 1e", "-8h");
    try expectEval(vm, "type 1.5", "-9h");
    try expectEval(vm, "type \"a\"", "-10h");
    try expectEval(vm, "type `a", "-11h");
    try expectEval(vm, "type ()", "0h");
    try expectEval(vm, "type `a`b!1 2", "99h");
    try expectEval(vm, "type type 1", "-5h");
}

test "atom arithmetic promotes as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1+2", "3");
    try expectEval(vm, "1+0.5", "1.5");
    try expectEval(vm, "1.5+1", "2.5");
    try expectEval(vm, "2*1.5", "3f");

    // Booleans, bytes and shorts compute as ints; wider operands win.
    try expectEval(vm, "1h+1h", "2i");
    try expectEval(vm, "1h-2h", "-1i");
    try expectEval(vm, "1h*2h", "2i");
    try expectEval(vm, "1b+1b", "2i");
    try expectEval(vm, "1b+1h", "2i");
    try expectEval(vm, "1b*2h", "2i");
    try expectEval(vm, "0x01+0x01", "2i");
    try expectEval(vm, "0x02*3h", "6i");
    try expectEval(vm, "1i+1h", "2i");
    try expectEval(vm, "2h*3i", "6i");
    try expectEval(vm, "1h+1", "2");
    try expectEval(vm, "1i+1", "2");
    try expectEval(vm, "2h*3", "6");
    try expectEval(vm, "2h-3", "-1");
    try expectEval(vm, "0x01+1", "2");
    try expectEval(vm, "2e*3", "6e");
    try expectEval(vm, "2e*3f", "6f");
    try expectEval(vm, "1h+1f", "2f");

    // Nulls propagate into the result kind; infinities are ordinary values that wrap.
    try expectEval(vm, "0Nh+1h", "0Ni");
    try expectEval(vm, "0Nh*2", "0N");
    try expectEval(vm, "0Ni+1", "0N");
    try expectEval(vm, "0Wh+1h", "32768i");
    try expectEval(vm, "32767h+1h", "32768i");
    try expectEval(vm, "0Wi+1i", "0Ni");

    // Division is always float.
    try expectEval(vm, "1h%2h", "0.5");
    try expectEval(vm, "1%2", "0.5");
    try expectEval(vm, "1e%2e", "0.5");
    try expectEval(vm, "1i%2", "0.5");
    try expectEval(vm, "2i%4i", "0.5");
    try expectEval(vm, "2%0", "0w");
    try expectEval(vm, "-2%0", "-0w");
    try expectEval(vm, "0%0", "0n");
    try expectEval(vm, "1h%0", "0w");

    try testing.expectError(error.type, vm.evalSource("`a+1", .q, "<test>"));
    try expectEval(vm, "1 2+3", "4 5");
}

test "neg, first, enlist and match on the numeric types" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "neg 1h", "-1h");
    try expectEval(vm, "neg 0Nh", "0Nh");
    try expectEval(vm, "neg 1e", "-1e");
    try expectEval(vm, "neg 0x01", "-1i");
    try expectEval(vm, "neg 1b", "-1i");
    try expectEval(vm, "neg 1 2h", "-1 -2h");
    try expectEval(vm, "neg 1 2e", "-1 -2e");
    try expectEval(vm, "neg 0N 1i", "0N -1i");
    try expectEval(vm, "neg 0x0102", "-1 -2i");
    try expectEval(vm, "neg 101b", "-1 0 -1i");

    try expectEval(vm, "first 1 2h", "1h");
    try expectEval(vm, "first 1 2e", "1e");
    try expectEval(vm, "first 0x0102", "0x01");
    try expectEval(vm, "first 101b", "1b");

    try expectEval(vm, "(1h;2h)", "1 2h");
    try expectEval(vm, "(1e;2e)", "1 2e");
    try expectEval(vm, "(0x01;0x02)", "0x0102");
    try expectEval(vm, "(1h;2i)", "(1h;2i)");
    try expectEval(vm, "(1e;2f)", "(1e;2f)");
    try expectEval(vm, "(1b;1h)", "(1b;1h)");
    try expectEval(vm, "(0x01;1h)", "(0x01;1h)");

    try expectEval(vm, "1h~1h", "1b");
    try expectEval(vm, "1h~1", "0b");
    try expectEval(vm, "1 2h!3 4", "1 2h!3 4");
}

test "temporal literals display as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "2023.04.17", "2023.04.17");
    try expectEval(vm, "2000.01.01", "2000.01.01");
    try expectEval(vm, "1999.12.31", "1999.12.31");
    try expectEval(vm, "2023.04.17d", "2023.04.17");
    try expectEval(vm, "0Nd", "0Nd");
    try expectEval(vm, "0Wd", "0Wd");
    try expectEval(vm, "-0Wd", "-0Wd");
    try expectEval(vm, "2023.04.17 2023.04.18", "2023.04.17 2023.04.18");
    try expectEval(vm, "2023.04.17 0Nd", "2023.04.17 0N");
    try expectEval(vm, "enlist 2023.04.17", ",2023.04.17");

    try expectEval(vm, "2023.04m", "2023.04m");
    try expectEval(vm, "2000.01m", "2000.01m");
    try expectEval(vm, "0Nm", "0Nm");
    try expectEval(vm, "0Wm", "0Wm");
    try expectEval(vm, "2023.04 2023.05m", "2023.04 2023.05m");

    try expectEval(vm, "2023.04.17D12:34:56.123456789", "2023.04.17D12:34:56.123456789");
    try expectEval(vm, "2023.04.17D12:34:56", "2023.04.17D12:34:56.000000000");
    try expectEval(vm, "2023.04.17D12:34", "2023.04.17D12:34:00.000000000");
    try expectEval(vm, "2023.04.17D", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:34:56p", "2023.04.17D12:34:56.000000000");
    try expectEval(vm, "0Np", "0Np");
    try expectEval(vm, "0Wp", "0Wp");
    try expectEval(vm, "-0Wp", "-0Wp");
    try expectEval(vm, "2023.04.17D12:34:56.123456789 0Np", "2023.04.17D12:34:56.123456789 0N");

    try expectEval(vm, "2023.04.17T12:34:56.123", "2023.04.17T12:34:56.123");
    try expectEval(vm, "2023.04.17T12:34:56", "2023.04.17T12:34:56.000");
    try expectEval(vm, "0Nz", "0Nz");
    try expectEval(vm, "0Wz", "0wz");
    try expectEval(vm, "-0Wz", "-0wz");
    try expectEval(vm, "2023.04.17T12:34:56.123 0Nz", "2023.04.17T12:34:56.123 0N");

    try expectEval(vm, "0D12:34:56.123456789", "0D12:34:56.123456789");
    try expectEval(vm, "1D12:34:56", "1D12:34:56.000000000");
    try expectEval(vm, "0D00:00:01", "0D00:00:01.000000000");
    try expectEval(vm, "0D00:00", "0D00:00:00.000000000");
    try expectEval(vm, "100D00:00:00", "100D00:00:00.000000000");
    try expectEval(vm, "12:34:56.123456789n", "0D12:34:56.123456789");
    try expectEval(vm, "0Nn", "0Nn");
    try expectEval(vm, "0Wn", "0Wn");
    try expectEval(vm, "-0Wn", "-0Wn");
    try expectEval(vm, "0D12:34:56.123456789 0Nn", "0D12:34:56.123456789 0N");

    try expectEval(vm, "12:34", "12:34");
    try expectEval(vm, "12:34u", "12:34");
    try expectEval(vm, "25:00", "25:00");
    try expectEval(vm, "0Nu", "0Nu");
    try expectEval(vm, "0Wu", "0Wu");
    try expectEval(vm, "-0Wu", "-0Wu");
    try expectEval(vm, "12:34 12:35", "12:34 12:35");
    try expectEval(vm, "12:34 0Nu", "12:34 0N");

    try expectEval(vm, "12:34:56", "12:34:56");
    try expectEval(vm, "12:34:56v", "12:34:56");
    try expectEval(vm, "0Nv", "0Nv");
    try expectEval(vm, "0Wv", "0Wv");
    try expectEval(vm, "12:34:56 0Nv", "12:34:56 0N");

    try expectEval(vm, "12:34:56.123", "12:34:56.123");
    try expectEval(vm, "12:34:56.123t", "12:34:56.123");
    try expectEval(vm, "12:34:56t", "12:34:56.000");
    try expectEval(vm, "0Nt", "0Nt");
    try expectEval(vm, "0Wt", "0Wt");
    try expectEval(vm, "-0Wt", "-0Wt");
    try expectEval(vm, "12:34:56.123 0Nt", "12:34:56.123 0N");

    try expectEval(vm, "type 2023.04.17", "-14h");
    try expectEval(vm, "type 2023.04.17 2023.04.18", "14h");
    try expectEval(vm, "type 2023.04m", "-13h");
    try expectEval(vm, "type 2023.04.17D12:34:56", "-12h");
    try expectEval(vm, "type 2023.04.17T12:34:56", "-15h");
    try expectEval(vm, "type 0D00:00:01", "-16h");
    try expectEval(vm, "type 12:34", "-17h");
    try expectEval(vm, "type 12:34:56", "-18h");
    try expectEval(vm, "type 12:34:56.123", "-19h");
}

test "temporal arithmetic follows q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // An integer keeps the type; the same type subtracted gives an int for dates and months.
    try expectEval(vm, "2023.04.17+1", "2023.04.18");
    try expectEval(vm, "2023.04.17+1h", "2023.04.18");
    try expectEval(vm, "2023.04.17+1i", "2023.04.18");
    try expectEval(vm, "1+2023.04.17", "2023.04.18");
    try expectEval(vm, "2023.04.17-1", "2023.04.16");
    try expectEval(vm, "2023.04.17-2023.04.16", "1i");
    try expectEval(vm, "2023.04.17-2000.01.01", "8507i");
    try expectEval(vm, "2023.04.17+2023.04.17", "17014i");
    try expectEval(vm, "2023.04.17*2", "2046.08.01");
    try expectEval(vm, "2023.04.17%2", "4253.5");
    try expectEval(vm, "neg 2023.04.17", "1976.09.16");
    try expectEval(vm, "2023.04m+1", "2023.05m");
    try expectEval(vm, "2023.04m-1", "2023.03m");
    try expectEval(vm, "2023.04m-2023.01m", "3i");
    try expectEval(vm, "2023.04m+0.5", "279.5");

    // Times of day combine at the finer resolution and stay temporal when subtracted.
    try expectEval(vm, "12:34+1", "12:35");
    try expectEval(vm, "12:35-12:34", "00:01");
    try expectEval(vm, "12:34+12:34", "25:08");
    try expectEval(vm, "12:34:56+1", "12:34:57");
    try expectEval(vm, "12:34:57-12:34:56", "00:00:01");
    try expectEval(vm, "12:34:56.123+1", "12:34:56.124");
    try expectEval(vm, "12:34:56.124-12:34:56.123", "00:00:00.001");
    try expectEval(vm, "12:34+12:34:56", "25:08:56");
    try expectEval(vm, "12:34:56+12:34:56.123", "25:09:52.123");
    try expectEval(vm, "0D00:00:01+1", "0D00:00:01.000000001");
    try expectEval(vm, "0D00:00:02-0D00:00:01", "0D00:00:01.000000000");
    try expectEval(vm, "0D00:00:01*2", "0D00:00:02.000000000");
    // `0D00:00:02%2` is the float 1e9, whose q display needs the pending %g formatting.
    try expectEval(vm, "0D00:00:01+12:00", "0D12:00:01.000000000");
    try expectEval(vm, "neg 0D00:00:01", "-0D00:00:01.000000000");

    // A date-like value plus a time of day is a timestamp; a fraction of a day is a datetime.
    try expectEval(vm, "2023.04.17+12:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+12:00:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+12:00:00.000", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+0D12:00:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "1899.12.31+0D12:00:00", "1899.12.31D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+0.5", "2023.04.17T12:00:00.000");
    try expectEval(vm, "2023.04.17D12:00:00+1", "2023.04.17D12:00:00.000000001");
    try expectEval(vm, "2023.04.17D12:00:01-2023.04.17D12:00:00", "0D00:00:01.000000000");
    try expectEval(vm, "2023.04.17D12:00:00+0D01:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "0D01:00:00+2023.04.17D12:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:00:00-0D01:00:00", "2023.04.17D11:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:00:00+12:00", "2023.04.18D00:00:00.000000000");
    try expectEval(vm, "2023.04.17T12:00:00+1", "2023.04.18T12:00:00.000");
    try expectEval(vm, "2023.04.17T12:00:00+0.5", "2023.04.18T00:00:00.000");
    try expectEval(vm, "2023.04.17T12:00:00-2023.04.17T00:00:00", "0.5");
    try expectEval(vm, "2023.04.17T12:00:00+0D01:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "2023.04.17T12:00:00.000+0D00:00:00.5", "2023.04.17D12:00:00.500000000");
    try testing.expectError(error.type, vm.evalSource("2023.04.17+2023.04m", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2023.04.17D12:00:00-2023.04.17", .q, "<test>"));

    // Nulls propagate and infinities wrap.
    try expectEval(vm, "0Nd+1", "0Nd");
    try expectEval(vm, "0Wd+1", "0Nd");
    try expectEval(vm, "0Nd-0Nd", "0Ni");

    try expectEval(vm, "(2023.04.17;2023.04.18)", "2023.04.17 2023.04.18");
    try expectEval(vm, "(2023.04.17;12:00)", "(2023.04.17;12:00)");
    try expectEval(vm, "first 2023.04.17 2023.04.18", "2023.04.17");
    try expectEval(vm, "2023.04.17~2023.04.17", "1b");
    try expectEval(vm, "12:00 12:01!1 2", "12:00 12:01!1 2");
}

test "\\P sets the float display precision" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\P", "7i");
    try expectEval(vm, "value \"\\\\P\"", "7i");
    try expectEval(vm, "type value \"\\\\P\"", "-6h");

    // Seven significant digits, C's %.7g: trailing zeros go, exponent form past the precision.
    try expectEval(vm, "1%3", "0.3333333");
    try expectEval(vm, "2%3", "0.6666667");
    try expectEval(vm, "1.23456789", "1.234568");
    try expectEval(vm, "123456789.0", "1.234568e+08");
    try expectEval(vm, "1234567.5", "1234568f");
    try expectEval(vm, "12345678.5", "1.234568e+07");
    try expectEval(vm, "0.0001", "0.0001");
    try expectEval(vm, "0.00001", "1e-05");
    try expectEval(vm, "1e7", "1e+07");
    try expectEval(vm, "1e6", "1000000f");
    try expectEval(vm, "9e15", "9e+15");
    try expectEval(vm, "0.1", "0.1");
    try expectEval(vm, "100000.5", "100000.5");
    try expectEval(vm, "1.5e-7", "1.5e-07");
    try expectEval(vm, "0D00:00:02%2", "1e+09");
    try expectEval(vm, "1e300", "1e+300");
    try expectEval(vm, "-0f", "-0f");
    try expectEval(vm, "3.14159265358979", "3.141593");
    try expectEval(vm, "1 2.5 1e10", "1 2.5 1e+10");
    try expectEval(vm, "0.5 0.25", "0.5 0.25");
    try expectEval(vm, "-3!1.23456789", "\"1.234568\"");

    // Reals display through the same rule from their double value.
    try expectEval(vm, "1.23456789e", "1.234568e");
    try expectEval(vm, "123456789e", "1.234568e+08e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "1e10e", "1e+10e");

    try expectEval(vm, "\\P 3", "::");
    try expectEval(vm, "\\P", "3i");
    try expectEval(vm, "1%3", "0.333");
    try expectEval(vm, "1.23456789", "1.23");
    try expectEval(vm, "1234.5", "1.23e+03");
    try expectEval(vm, "12345.0", "1.23e+04");
    try expectEval(vm, "1000f", "1e+03");
    try expectEval(vm, "0.001234", "0.00123");
    try expectEval(vm, "1.23456789e", "1.23e");
    try expectEval(vm, "1234e", "1.23e+03e");
    try expectEval(vm, "1 2.5 1234.5", "1 2.5 1.23e+03");

    try expectEval(vm, "\\P 10", "::");
    try expectEval(vm, "1%3", "0.3333333333");
    try expectEval(vm, "1.23456789", "1.23456789");
    try expectEval(vm, "1.23456789e", "1.234567881e");
    try expectEval(vm, "1234567890123.0", "1.23456789e+12");
    try expectEval(vm, "0.1e", "0.1000000015e");
    try expectEval(vm, "1.5e", "1.5e");
    try expectEval(vm, "123456789e", "123456792e");

    // 17 digits expand the binary value exactly.
    try expectEval(vm, "\\P 17", "::");
    try expectEval(vm, "1%3", "0.33333333333333331");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try expectEval(vm, "1.23456789", "1.2345678899999999");
    try expectEval(vm, "1.23456789e", "1.2345678806304932e");
    try expectEval(vm, "0.1e", "0.10000000149011612e");

    // \P 0 is 17 digits for floats but the shortest round trip for reals; above 17 clamps.
    try expectEval(vm, "\\P 0", "::");
    try expectEval(vm, "\\P", "0i");
    try expectEval(vm, "1%3", "0.33333333333333331");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try expectEval(vm, "1e7", "10000000f");
    try expectEval(vm, "1e16", "10000000000000000f");
    try expectEval(vm, "1e17", "1e+17");
    try expectEval(vm, "123456789.0", "123456789f");
    try expectEval(vm, "1e-5", "1.0000000000000001e-05");
    try expectEval(vm, "1.23456789e", "1.2345679e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "1e10e", "1e+10e");
    try expectEval(vm, "\\P 1", "::");
    try expectEval(vm, "1.5", "2f");
    try expectEval(vm, "12.5", "1e+01");
    try expectEval(vm, "0.15", "0.1");
    try expectEval(vm, "\\P 20", "::");
    try expectEval(vm, "\\P", "17i");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try testing.expectError(error.domain, vm.evalSource("\\P x", .q, "<test>"));
}

test "take repeats, cycles and makes typed empties" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "0#0", "`long$()");
    try expectEval(vm, "0#1 2", "`long$()");
    try expectEval(vm, "0#1.5", "`float$()");
    try expectEval(vm, "0#\"a\"", "\"\"");
    try expectEval(vm, "0#\"ab\"", "\"\"");
    try expectEval(vm, "0#`a", "`symbol$()");
    try expectEval(vm, "0#`a`b", "`symbol$()");
    try expectEval(vm, "0#1b", "`boolean$()");
    try expectEval(vm, "0#0x01", "`byte$()");
    try expectEval(vm, "0#1h", "`short$()");
    try expectEval(vm, "0#1i", "`int$()");
    try expectEval(vm, "0#1e", "`real$()");
    try expectEval(vm, "0#2023.04.17", "`date$()");
    try expectEval(vm, "0#12:00", "`minute$()");
    try expectEval(vm, "0#()", "()");
    try expectEval(vm, "0#(1;\"a\")", "()");
    try expectEval(vm, "0#0N", "`long$()");
    try expectEval(vm, "0#enlist 1", "`long$()");
    try expectEval(vm, "0#0#0", "`long$()");
    try expectEval(vm, "type 0#0", "7h");
    try expectEval(vm, "count 0#0", "0");

    try expectEval(vm, "2#1", "1 1");
    try expectEval(vm, "1#1", ",1");
    try expectEval(vm, "-1#1", ",1");
    try expectEval(vm, "3#1 2", "1 2 1");
    try expectEval(vm, "2#1 2 3", "1 2");
    try expectEval(vm, "-2#1 2 3", "2 3");
    try expectEval(vm, "5#1 2", "1 2 1 2 1");
    try expectEval(vm, "-5#1 2", "2 1 2 1 2");
    try expectEval(vm, "4#1 2 3", "1 2 3 1");
    try expectEval(vm, "-4#1 2 3", "3 1 2 3");
    try expectEval(vm, "-3#1 2 3", "1 2 3");
    try expectEval(vm, "2#\"ab\"", "\"ab\"");
    try expectEval(vm, "3#\"a\"", "\"aaa\"");
    try expectEval(vm, "2#`a", "`a`a");
    try expectEval(vm, "1#`a`b", ",`a");
    try expectEval(vm, "-2#`a`b`c", "`b`c");
    try expectEval(vm, "2#1b", "11b");
    try expectEval(vm, "2#0N", "0N 0N");
    try expectEval(vm, "2#1.5", "1.5 1.5");
    try expectEval(vm, "2#0x01", "0x0101");
    try expectEval(vm, "3#0x0102", "0x010201");
    try expectEval(vm, "2#2023.04.17", "2023.04.17 2023.04.17");
    try expectEval(vm, "2#2023.04m", "2023.04 2023.04m");
    try expectEval(vm, "2#enlist 1", "1 1");
    try expectEval(vm, "2#(1;\"a\")", "(1;\"a\")");
    try expectEval(vm, "3#(1;\"a\")", "(1;\"a\";1)");
    try expectEval(vm, "2#(1;\"a\";`b)", "(1;\"a\")");
    try expectEval(vm, "2#(+)", "(+;+)");
    try expectEval(vm, "2#{[x]1}", "({[x]1};{[x]1})");
    try expectEval(vm, "2h#1 2", "1 2");
    try expectEval(vm, "2i#1 2", "1 2");

    // Taking from an empty list fills with nulls.
    try expectEval(vm, "2#()", "(();())");
    try expectEval(vm, "1#()", ",()");
    try expectEval(vm, "2#`long$()", "0N 0N");
    try expectEval(vm, "2#\"\"", "\"  \"");
    try expectEval(vm, "2#`symbol$()", "``");

    try testing.expectError(error.type, vm.evalSource("0N#1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1.5#1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"a\"#1 2", .q, "<test>"));
}

test "cast makes typed empties and converts between types" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "`long$()", "`long$()");
    try expectEval(vm, "`float$()", "`float$()");
    try expectEval(vm, "`symbol$()", "`symbol$()");
    try expectEval(vm, "`char$()", "\"\"");
    try expectEval(vm, "`boolean$()", "`boolean$()");
    try expectEval(vm, "`byte$()", "`byte$()");
    try expectEval(vm, "`short$()", "`short$()");
    try expectEval(vm, "`int$()", "`int$()");
    try expectEval(vm, "`real$()", "`real$()");
    try expectEval(vm, "`date$()", "`date$()");
    try expectEval(vm, "`month$()", "`month$()");
    try expectEval(vm, "`timestamp$()", "`timestamp$()");
    try expectEval(vm, "`datetime$()", "`datetime$()");
    try expectEval(vm, "`timespan$()", "`timespan$()");
    try expectEval(vm, "`minute$()", "`minute$()");
    try expectEval(vm, "`second$()", "`second$()");
    try expectEval(vm, "`time$()", "`time$()");
    try expectEval(vm, "`$()", "`symbol$()");
    try expectEval(vm, "`long$`long$()", "`long$()");
    try expectEval(vm, "\"j\"$()", "`long$()");
    try expectEval(vm, "\"c\"$()", "\"\"");
    try expectEval(vm, "\"d\"$()", "`date$()");
    try expectEval(vm, "\"s\"$()", "`symbol$()");
    try expectEval(vm, "\"b\"$()", "`boolean$()");
    try expectEval(vm, "`long$\"\"", "`long$()");
    try expectEval(vm, "type `long$()", "7h");
    try expectEval(vm, "type \"j\"$()", "7h");

    // Numbers round half away from zero; shorts and ints saturate, bytes wrap.
    try expectEval(vm, "`long$enlist 1", ",1");
    try expectEval(vm, "`long$1 2h", "1 2");
    try expectEval(vm, "`float$1 2", "1 2f");
    try expectEval(vm, "`int$1.7", "2i");
    try expectEval(vm, "\"j\"$1.9", "2");
    try expectEval(vm, "\"j\"$2.5", "3");
    try expectEval(vm, "\"j\"$-2.5", "-3");
    try expectEval(vm, "\"j\"$0.5", "1");
    try expectEval(vm, "`long$1b", "1");
    try expectEval(vm, "`boolean$1 0", "10b");
    try expectEval(vm, "`boolean$0.5", "1b");
    try expectEval(vm, "`boolean$2", "1b");
    try expectEval(vm, "`boolean$0N", "1b");
    try expectEval(vm, "`short$70000", "0Wh");
    try expectEval(vm, "`short$-70000", "-0Wh");
    try expectEval(vm, "`short$32767", "0Wh");
    try expectEval(vm, "`int$0W", "0Wi");
    try expectEval(vm, "`int$-0W", "-0Wi");
    try expectEval(vm, "`int$3000000000", "0Wi");
    try expectEval(vm, "`long$0W", "0W");
    try expectEval(vm, "`byte$255", "0xff");
    try expectEval(vm, "`byte$256", "0x00");
    try expectEval(vm, "`byte$-1", "0xff");
    try expectEval(vm, "`byte$0N", "0x00");
    try expectEval(vm, "\"x\"$65", "0x41");
    try expectEval(vm, "\"x\"$1.7", "0x02");
    try expectEval(vm, "`real$1%3", "0.3333333e");
    try expectEval(vm, "\"f\"$1", "1f");
    try expectEval(vm, "\"h\"$1", "1h");
    try expectEval(vm, "\"i\"$1", "1i");
    try expectEval(vm, "\"e\"$1", "1e");
    try expectEval(vm, "\"b\"$0", "0b");
    try expectEval(vm, "`long$0x41", "65");
    try expectEval(vm, "`float$0x41", "65f");

    // Nulls stay null except into booleans and bytes.
    try expectEval(vm, "`long$0Nh", "0N");
    try expectEval(vm, "`int$0N", "0Ni");
    try expectEval(vm, "`short$0N", "0Nh");
    try expectEval(vm, "`short$0W", "0Wh");
    try expectEval(vm, "`short$-0W", "-0Wh");
    try expectEval(vm, "`long$0Wi", "2147483647");
    try expectEval(vm, "`long$0Wh", "32767");
    try expectEval(vm, "`real$0Nh", "0Ne");
    try expectEval(vm, "`float$0N", "0n");
    try expectEval(vm, "`long$0n", "0N");
    try expectEval(vm, "`long$0N", "0N");
    try expectEval(vm, "0n", "0n");
    try expectEval(vm, "0w", "0w");
    try expectEval(vm, "-0w", "-0w");
    try expectEval(vm, "0Nn", "0Nn");
    try expectEval(vm, "1 0n 2", "1 0n 2");

    // Chars and symbols.
    try expectEval(vm, "`char$65", "\"A\"");
    try expectEval(vm, "\"c\"$65", "\"A\"");
    try expectEval(vm, "\"c\"$65 66", "\"AB\"");
    try expectEval(vm, "\"c\"$0x41", "\"A\"");
    try expectEval(vm, "`char$\"a\"", "\"a\"");
    try expectEval(vm, "`char$1b", "\"\\001\"");
    try expectEval(vm, "\"a\\nb\"", "\"a\\nb\"");
    try expectEval(vm, "\"\\t\"", "\"\\t\"");
    try expectEval(vm, "\"\\\\\"", "\"\\\\\"");
    try expectEval(vm, "`char$0 27 65", "\"\\000\\033A\"");
    try expectEval(vm, "`long$\"12\"", "49 50");
    try expectEval(vm, "`long$\"a\"", "97");
    try expectEval(vm, "`boolean$\"a\"", "1b");
    try expectEval(vm, "`$\"abc\"", "`abc");
    try expectEval(vm, "`$\"\"", "`");
    try expectEval(vm, "`$\"a b\"", "`a b");
    try expectEval(vm, "`symbol$`a", "`a");
    try expectEval(vm, "`long$(1;2.5)", "1 3");
    try testing.expectError(error.type, vm.evalSource("`symbol$\"abc\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`long$`a", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("`xyz$1", .q, "<test>"));

    // Temporal conversions go by days and nanoseconds.
    try expectEval(vm, "`long$2023.04.17", "8507");
    try expectEval(vm, "`float$2023.04.17", "8507f");
    try expectEval(vm, "`long$12:34", "754");
    try expectEval(vm, "`long$0D00:00:01", "1000000000");
    try expectEval(vm, "`float$2023.04.17T12:00", "8507.5");
    try expectEval(vm, "`date$8507", "2023.04.17");
    try expectEval(vm, "`date$0", "2000.01.01");
    try expectEval(vm, "`date$1.5", "2000.01.03");
    try expectEval(vm, "`date$0N", "0Nd");
    try expectEval(vm, "`date$0Nz", "0Nd");
    try expectEval(vm, "`date$2023.04.17D12:00", "2023.04.17");
    try expectEval(vm, "`date$2023.04.17T12:00", "2023.04.17");
    try expectEval(vm, "`date$2023.04m", "2023.04.01");
    try expectEval(vm, "`month$2023.04.17", "2023.04m");
    try expectEval(vm, "`month$2023.04.17D12:00", "2023.04m");
    try expectEval(vm, "`month$1", "2000.02m");
    try expectEval(vm, "`timestamp$1", "2000.01.01D00:00:00.000000001");
    try expectEval(vm, "`timestamp$1.5", "2000.01.01D00:00:00.000000002");
    try expectEval(vm, "`timestamp$2023.04.17", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "`timestamp$2023.04.17T12:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "`timestamp$2023.04m", "2023.04.01D00:00:00.000000000");
    try expectEval(vm, "`datetime$2023.04.17", "2023.04.17T00:00:00.000");
    try expectEval(vm, "`datetime$2023.04.17D12:00", "2023.04.17T12:00:00.000");
    try expectEval(vm, "`minute$1", "00:01");
    try expectEval(vm, "`minute$12:34:56", "12:34");
    try expectEval(vm, "`minute$0D12:34:56", "12:34");
    try expectEval(vm, "`minute$12:34:56.123", "12:34");
    try expectEval(vm, "`second$12:34", "12:34:00");
    try expectEval(vm, "`second$12:34:56.789", "12:34:56");
    try expectEval(vm, "`time$12:34:56", "12:34:56.000");
    try expectEval(vm, "`time$0D12:34:56.123456789", "12:34:56.123");
    try expectEval(vm, "`timespan$1", "0D00:00:00.000000001");
    try expectEval(vm, "`timespan$12:34", "0D12:34:00.000000000");
    try expectEval(vm, "`timespan$12:34:56.123", "0D12:34:56.123000000");
    try testing.expectError(error.type, vm.evalSource("`date$12:00", .q, "<test>"));
}

test "capital cast letters parse text as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\"J\"$\"12\"", "12");
    try expectEval(vm, "\"J\"$\" 12 \"", "12");
    try expectEval(vm, "\"J\"$\"-5\"", "-5");
    try expectEval(vm, "\"J\"$\"+5\"", "5");
    try expectEval(vm, "\"J\"$\"0N\"", "0N");
    try expectEval(vm, "\"J\"$\"0W\"", "0W");
    try expectEval(vm, "\"J\"$\"1.5\"", "0N");
    try expectEval(vm, "\"J\"$\"1e3\"", "0N");
    try expectEval(vm, "\"J\"$\"12abc\"", "0N");
    try expectEval(vm, "\"J\"$\"abc\"", "0N");
    try expectEval(vm, "\"J\"$\"\"", "0N");
    try expectEval(vm, "\"J\"$\"1\"", "1");
    try expectEval(vm, "\"J\"$\"1 2\"", "0N");
    try expectEval(vm, "\"J\"$(\"1\";\"2\")", "12");
    try expectEval(vm, "\"J\"$(\"1\";\"23\")", "1 23");
    try expectEval(vm, "\"J\"$((\"1\";\"2\");\"3\")", "12 3");
    try expectEval(vm, "\"J\"$(\"1\";\"x\")", "0N");
    try expectEval(vm, "\"J\"$(\"1\";\"xy\")", "1 0N");
    try expectEval(vm, "\"J\"$()", "`long$()");
    try expectEval(vm, "type \"J\"$\"12\"", "-7h");
    try testing.expectError(error.type, vm.evalSource("\"J\"$`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"J\"$1", .q, "<test>"));

    try expectEval(vm, "\"I\"$\"12\"", "12i");
    try expectEval(vm, "\"I\"$\"3000000000\"", "0Ni");
    try expectEval(vm, "\"H\"$\"12\"", "12h");
    try expectEval(vm, "\"H\"$\"70000\"", "0Nh");
    try expectEval(vm, "\"F\"$\"1.5\"", "1.5");
    try expectEval(vm, "\"F\"$\"1e3\"", "1000f");
    try expectEval(vm, "\"F\"$\"abc\"", "0n");
    try expectEval(vm, "\"F\"$\"\"", "0n");
    try expectEval(vm, "\"F\"$\"1\"", "1f");
    try expectEval(vm, "\"E\"$\"1.5\"", "1.5e");
    try expectEval(vm, "\"E\"$\"abc\"", "0Ne");
    try expectEval(vm, "\"B\"$\"1\"", "1b");
    try expectEval(vm, "\"B\"$\"0\"", "0b");
    try expectEval(vm, "\"B\"$\"t\"", "1b");
    try expectEval(vm, "\"B\"$\"Y\"", "1b");
    try expectEval(vm, "\"B\"$\"x\"", "1b");
    try expectEval(vm, "\"B\"$\"true\"", "0b");
    try expectEval(vm, "\"B\"$\"\"", "0b");
    try expectEval(vm, "\"B\"$\"101\"", "0b");
    try expectEval(vm, "\"X\"$\"41\"", "0x41");
    try expectEval(vm, "\"X\"$\"ff\"", "0xff");
    try expectEval(vm, "\"X\"$\"FF\"", "0xff");
    try expectEval(vm, "\"X\"$\"1\"", "0x01");
    try expectEval(vm, "\"X\"$\"xyz\"", "0x00");
    try expectEval(vm, "\"X\"$\"\"", "0x00");
    try expectEval(vm, "\"X\"$\"4142\"", "0x00");
    try expectEval(vm, "\"S\"$\"ab\"", "`ab");
    try expectEval(vm, "\"S\"$\"\"", "`");
    try expectEval(vm, "\"S\"$\" ab \"", "`ab");
    try expectEval(vm, "\"S\"$\"a b\"", "`a b");
    try expectEval(vm, "\"S\"$(\"a\";\"b\")", "`ab");
    try expectEval(vm, "\"S\"$(\"a\";\"bc\")", "`a`bc");
    try expectEval(vm, "\"C\"$\"ab\"", "\" \"");
    try expectEval(vm, "\"C\"$\"a\"", "\"a\"");

    try expectEval(vm, "\"D\"$\"2023.04.17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"20230417\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"2023/04/17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"2023-04-17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"04/17/2023\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"17/04/2023\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2024.02.29\"", "2024.02.29");
    try expectEval(vm, "\"D\"$\"2023.02.29\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.02.30\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.04.31\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.13.01\"", "0Nd");
    try expectEval(vm, "\"J\"$\"9223372036854775807\"", "0W");
    try expectEval(vm, "\"J\"$\"9223372036854775808\"", "0N");
    try expectEval(vm, "\"H\"$\"-32768\"", "0Nh");
    try expectEval(vm, "\"F\"$\".5\"", "0.5");
    try expectEval(vm, "\"U\"$\"25:00\"", "25:00");
    try expectEval(vm, "\"D\"$\"abc\"", "0Nd");
    try expectEval(vm, "\"D\"$\"\"", "0Nd");
    try expectEval(vm, "\"M\"$\"2023.04\"", "2023.04m");
    try expectEval(vm, "\"M\"$\"202304\"", "2023.04m");
    try expectEval(vm, "\"M\"$\"2023.04m\"", "0Nm");
    try expectEval(vm, "\"M\"$\"2023.04.17\"", "0Nm");
    try expectEval(vm, "\"P\"$\"2023.04.17D12:34:56.123456789\"", "2023.04.17D12:34:56.123456789");
    try expectEval(vm, "\"P\"$\"2023.04.17\"", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023.04.17T12:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023.04.17 12:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023-04-17T12:00:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"Z\"$\"2023.04.17T12:00:00.000\"", "2023.04.17T12:00:00.000");
    try expectEval(vm, "\"Z\"$\"2023.04.17\"", "2023.04.17T00:00:00.000");
    try expectEval(vm, "\"Z\"$\"2023.04.17D12:00\"", "2023.04.17T12:00:00.000");
    try expectEval(vm, "\"N\"$\"0D12:34:56.123456789\"", "0D12:34:56.123456789");
    try expectEval(vm, "\"N\"$\"12:34:56.123456789\"", "0D12:34:56.123456789");
    try expectEval(vm, "\"N\"$\"12:34\"", "0D12:34:00.000000000");
    try expectEval(vm, "\"N\"$\"1D\"", "1D00:00:00.000000000");
    try expectEval(vm, "\"U\"$\"12:34\"", "12:34");
    try expectEval(vm, "\"U\"$\"12:34:56\"", "12:34");
    try expectEval(vm, "\"U\"$\"1234\"", "12:34");
    try expectEval(vm, "\"U\"$\"12\"", "12:00");
    try expectEval(vm, "\"V\"$\"12:34:56\"", "12:34:56");
    try expectEval(vm, "\"V\"$\"12:34\"", "12:34:00");
    try expectEval(vm, "\"V\"$\"123456\"", "12:34:56");
    try expectEval(vm, "\"T\"$\"12:34:56.123\"", "12:34:56.123");
    try expectEval(vm, "\"T\"$\"12:34:56\"", "12:34:56.000");
    try expectEval(vm, "\"T\"$\"12:34\"", "12:34:00.000");
    try expectEval(vm, "\"T\"$\"123456123\"", "12:34:56.123");
    try expectEval(vm, "\"T\"$\"abc\"", "0Nt");
    try testing.expectError(error.domain, vm.evalSource("\"Q\"$\"1\"", .q, "<test>"));
}

test ".z clock variables read the clock in local time and UTC" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "type .z.D", "-14h");
    try expectEval(vm, "type .z.d", "-14h");
    try expectEval(vm, "type .z.P", "-12h");
    try expectEval(vm, "type .z.p", "-12h");
    try expectEval(vm, "type .z.T", "-19h");
    try expectEval(vm, "type .z.t", "-19h");
    try expectEval(vm, "type .z.N", "-16h");
    try expectEval(vm, "type .z.n", "-16h");
    try expectEval(vm, "type .z.Z", "-15h");
    try expectEval(vm, "type .z.z", "-15h");
    try expectEvalMode(vm, .k, "@.z.p", "-12h");

    // UTC now agrees with the clock module to within a second.
    const utc = try vm.evalSource(".z.p", .q, "<test>");
    defer utc.deref(vm.gpa);
    const now = q.clock.now(vm.io);
    try testing.expect(now - utc.as.timestamp >= 0 and now - utc.as.timestamp < q.literal.ns_per_second);

    // The date, time, timespan and datetime are the timestamp's parts. A list is evaluated
    // right to left, so each item is read no later than the one before it.
    try expectEval(vm, "(`date$.z.p)-.z.d", "0i");
    try expectEval(vm, "(`date$.z.P)-.z.D", "0i");
    const parts = try vm.evalSource("(.z.p;.z.n;.z.t;.z.z)", .q, "<test>");
    defer parts.deref(vm.gpa);
    const stamp = parts.as.list[0].as.timestamp;
    const since_midnight = parts.as.list[1].as.timespan;
    try testing.expect(since_midnight <= @mod(stamp, q.literal.ns_per_day));
    try testing.expect(@mod(stamp, q.literal.ns_per_day) - since_midnight < q.literal.ns_per_second);
    try testing.expect(parts.as.list[2].as.time <= @divFloor(since_midnight, 1_000_000));
    const days = @as(f64, @floatFromInt(stamp)) / @as(f64, @floatFromInt(q.literal.ns_per_day));
    try testing.expect(parts.as.list[3].as.datetime <= days and days - parts.as.list[3].as.datetime < 1.0 / 86_400.0);

    // Local time is UTC shifted by the zone's offset, a whole number of minutes; `.z.p` is
    // read first, so the difference is the offset plus a few microseconds.
    const shift = try vm.evalSource(".z.P-.z.p", .q, "<test>");
    defer shift.deref(vm.gpa);
    const unix_seconds = @divFloor(now, q.literal.ns_per_second) + q.literal.epoch_days * 86_400;
    const expected_shift = vm.local_zone.offset(unix_seconds) * q.literal.ns_per_second;
    try testing.expect(shift.as.timespan >= expected_shift and shift.as.timespan - expected_shift < q.literal.ns_per_second);

    // `.z` is a namespace that accepts other entries; the clock names cannot be replaced.
    try expectEval(vm, ".z.foo:1", "1");
    try expectEval(vm, ".z.foo", "1");
    try expectEval(vm, ".z.D:1", "1");
    try expectEval(vm, "type .z.D", "-14h");
}

test "pad and cast by type number" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "5$\"ab\"", "\"ab   \"");
    try expectEval(vm, "-5$\"ab\"", "\"   ab\"");
    try expectEval(vm, "1$\"abc\"", ",\"a\"");
    try expectEval(vm, "0$\"abc\"", "\"\"");
    try expectEval(vm, "5$(\"ab\";\"cde\")", "(\"ab   \";\"cde  \")");
    try expectEval(vm, "5$\"\"", "\"     \"");
    try expectEval(vm, "5$()", "\"     \"");
    try expectEval(vm, "5$enlist \"a\"", "\"a    \"");
    try expectEval(vm, "-3$\"abcdef\"", "\"def\"");
    try expectEval(vm, "3$\"abcdef\"", "\"abc\"");
    try testing.expectError(error.type, vm.evalSource("5$\"a\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$`ab", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5i$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5f$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$(\"ab\";\"c\")", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("0N$\"ab\"", .q, "<test>"));

    try expectEval(vm, "5h$\"abc\"", "97 98 99h");
    try expectEval(vm, "5h$1.5", "2h");
    try expectEval(vm, "7h$1.5", "2");
    try expectEval(vm, "-5h$\"12\"", "12h");
    try expectEval(vm, "-7h$\"1\"", "1");
    try expectEval(vm, "0h$\"abc\"", "\"abc\"");
    try expectEval(vm, "0h$1 2", "1 2");
    try expectEval(vm, "10h$1 2", "\"\\001\\002\"");
    try testing.expectError(error.type, vm.evalSource("20h$1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("11h$\"abc\"", .q, "<test>"));
}

test "reshape cuts a list into rows as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "2 3#til 6", "(0 1 2;3 4 5)");
    try expectEval(vm, "2 3#1", "(1 1 1;1 1 1)");
    try expectEval(vm, "2 3#5", "(5 5 5;5 5 5)");
    try expectEval(vm, "2 3#til 4", "(0 1 2;3 0 1)");
    try expectEval(vm, "2 3#1 2 3 4 5 6 7 8", "(1 2 3;4 5 6)");
    try expectEval(vm, "2 0N#til 6", "(0 1 2;3 4 5)");
    try expectEval(vm, "0N 2#til 6", "(0 1;2 3;4 5)");
    try expectEval(vm, "0N 4#til 6", "(0 1 2 3;4 5)");
    try expectEval(vm, "0N 3#til 7", "(0 1 2;3 4 5;,6)");
    try expectEval(vm, "3 0N#til 7", "(0 1;2 3;4 5 6)");
    try expectEval(vm, "2 0N#til 7", "(0 1 2;3 4 5 6)");
    try expectEval(vm, "0N 2#()", "()");
    try expectEval(vm, "2 3 4#til 24", "((0 1 2 3;4 5 6 7;8 9 10 11);(12 13 14 15;16 17 18 19;20 21 22 23))");
    try expectEval(vm, "2 3#\"abcdef\"", "(\"abc\";\"def\")");
    try expectEval(vm, "2 3#`a`b", "(`a`b`a;`b`a`b)");
    try expectEval(vm, "3 3#`a", "(`a`a`a;`a`a`a;`a`a`a)");
    try expectEval(vm, "2 3#()", "((();();());(();();()))");
    try expectEval(vm, "2 3#til 0", "(0N 0N 0N;0N 0N 0N)");
    try expectEval(vm, "2 2#(1;2)", "(1 2;1 2)");
    try expectEval(vm, "2 3#enlist 1 2 3", "((1 2 3;1 2 3;1 2 3);(1 2 3;1 2 3;1 2 3))");
    try expectEval(vm, "2 3#(1;2;`a)", "((1;2;`a);(1;2;`a))");
    try expectEval(vm, "2 3#(1 2;3)", "((1 2;3;1 2);(3;1 2;3))");
    try expectEval(vm, "3 2#(1;2;3;4;5;6)", "(1 2;3 4;5 6)");
    try expectEval(vm, "1 2#1", ",1 1");
    try expectEval(vm, "2 3#0 1 2 3 4 5 6 7 8f", "(0 1 2f;3 4 5f)");
    try expectEval(vm, "2 2#2 3#til 6", "((0 1 2;3 4 5);(0 1 2;3 4 5))");
    try testing.expectError(error.length, vm.evalSource("0 3#til 6", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("-2 3#til 6", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3h#til 6", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("0N 2 3#til 12", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("0N 0N#til 6", .q, "<test>"));
}

test "take on a dictionary selects entries by count or by key" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "`a`c#`a`b`c!1 2 3", "`a`c!1 3");
    try expectEval(vm, "`a`x#`a`b`c!1 2 3", "`a`x!1 0N");
    try expectEval(vm, "`x`a#`a`b`c!(1;\"x\";`s)", "`x`a!0N 1");
    try expectEval(vm, "`a`c#`a`b`c!(1;\"x\";`s)", "`a`c!(1;`s)");
    try expectEval(vm, "`a`x#`a`b!(\"ab\";\"cd\")", "`a`x!(\"ab\";\"\")");
    try expectEval(vm, "`a`x#`a`b`c!1 2 3f", "`a`x!1 0n");
    try expectEval(vm, "`a`b#(`a`b`c)!(1 2;3;`x)", "`a`b!(1 2;3)");
    try expectEval(vm, "1 2#1 2 3!4 5 6", "1 2!4 5");
    try expectEval(vm, "1 9#1 2 3!4 5 6", "1 9!4 0N");
    try expectEval(vm, "2#`a`b`c!1 2 3", "`a`b!1 2");
    try expectEval(vm, "-2#`a`b`c!1 2 3", "`b`c!2 3");
    try expectEval(vm, "0#`a`b`c!1 2 3", "(`symbol$())!`long$()");
    try expectEval(vm, "(`symbol$())#`a`b!1 2", "(`symbol$())!`long$()");
    try expectEval(vm, "5#`a`b`c!1 2 3", "`a`b`c`a`b!1 2 3 1 2");
    try expectEval(vm, "2#`a`b!(1;\"x\")", "`a`b!(1;\"x\")");
    try expectEval(vm, "type `a`c#`a`b`c!1 2 3", "99h");
    try expectEval(vm, "(enlist `a)!enlist 1", "(,`a)!,1");
    try expectEval(vm, "(enlist \"a\")!enlist 1", "(,\"a\")!,1");
    try expectEval(vm, "(enlist \"ab\")!enlist 1", ",\"ab\"!,1");
    try expectEval(vm, "(`long$())!()", "(`long$())!()");
    try expectEval(vm, "\"ab\"!1 2", "\"ab\"!1 2");
    try expectEval(vm, "(1 2;3)!4 5", "(1 2;3)!4 5");
    try testing.expectError(error.type, vm.evalSource("`a#`a`b`c!1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3#`a`b!1 2", .q, "<test>"));
}

test "arithmetic over lists pairs items and unifies the results" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1 2 3+1", "2 3 4");
    try expectEval(vm, "1+1 2 3", "2 3 4");
    try expectEval(vm, "1 2 3+1 2 3", "2 4 6");
    try expectEval(vm, "1 2 3+(1;2;3)", "2 4 6");
    try expectEval(vm, "1 2 3+1 2 3i", "2 4 6");
    try expectEval(vm, "1 2 3h+1 2 3h", "2 4 6i");
    try expectEval(vm, "1 2 3-1 2 3h", "0 0 0");
    try expectEval(vm, "1 2 3*2.5", "2.5 5 7.5");
    try expectEval(vm, "1 2 3%2", "0.5 1 1.5");
    try expectEval(vm, "1 2 3+0N 1 2", "0N 3 5");
    try expectEval(vm, "01b+1", "1 2");
    try expectEval(vm, "0x01+1 2", "2 3");
    try expectEval(vm, "2023.04.17 2023.04.18+1", "2023.04.18 2023.04.19");
    try expectEval(vm, "(1 2;3 4)+1", "(2 3;4 5)");
    try expectEval(vm, "(1 2;3 4)+1 2", "(2 3;5 6)");
    try expectEval(vm, "1+(1 2;3 4)", "(2 3;4 5)");
    try expectEval(vm, "(1 2;3)+(1;2 3)", "(2 3;5 6)");
    try expectEval(vm, "()+1", "()");
    try expectEval(vm, "1+`long$()", "`long$()");
    try expectEval(vm, "()+()", "()");
    try testing.expectError(error.length, vm.evalSource("1 2 3+1 2", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("1 2 3+()", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(1;2;`a)+1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"ab\"+1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x0102+1", .q, "<test>"));
}

test "string literal escapes decode as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\"\\001\"", "\"\\001\"");
    try expectEval(vm, "count \"\\001\"", "1");
    try expectEval(vm, "`long$\"\\123\"", "83");
    try expectEval(vm, "`long$\"\\1234\"", "83 52");
    try expectEval(vm, "`long$\"\\377\"", "255");
    try expectEval(vm, "`long$\"\\/\"", "47");
    try expectEval(vm, "`long$\"\\\"\"", "34");
    try expectEval(vm, "`long$\"\\\\\"", "92");
    try expectEval(vm, "`long$\"\\n\\t\\r\"", "10 9 13");
    try expectEval(vm, "\"a\\\"b\"", "\"a\\\"b\"");
    try testing.expectError(error.parse, vm.evalSource("\"\\q\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\1\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\12\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\400\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\8\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\x41\"", .q, "<test>"));
}
