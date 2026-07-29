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
constants: [std.meta.fields(Constant).len]*Value = undefined,
unary_primitives: [std.meta.fields(UnaryPrimitive).len]*Value = undefined,
operators: [std.meta.fields(Operator).len]*Value = undefined,
iterators: [std.meta.fields(Iterator).len]*Value = undefined,
state: *Value = undefined,

const Constant = enum(u8) {
    empty_list,
    zero,
    one,
    semicolon,
    null_symbol,
};

pub fn init(io: Io, gpa: Allocator, stdout: *Io.Writer) !*Vm {
    const vm = try gpa.create(Vm);
    errdefer vm.deinit();
    vm.* = .{
        .io = io,
        .gpa = gpa,
        .stdout = stdout,
    };

    var constants_created: usize = 0;
    errdefer for (0..constants_created) |i| vm.constants[i].deref(vm.gpa);
    vm.constants[@intFromEnum(Constant.empty_list)] = try vm.allocValue(.list, 0);
    constants_created += 1;
    vm.constants[@intFromEnum(Constant.zero)] = try vm.createValue(.long, 0);
    constants_created += 1;
    vm.constants[@intFromEnum(Constant.one)] = try vm.createValue(.long, 1);
    constants_created += 1;
    vm.constants[@intFromEnum(Constant.semicolon)] = try vm.createValue(.char, ';');
    constants_created += 1;
    vm.constants[@intFromEnum(Constant.null_symbol)] = try vm.createValue(.symbol, try vm.intern(""));
    constants_created += 1;

    var unary_primitives_created: usize = 0;
    errdefer for (0..unary_primitives_created) |i| vm.unary_primitives[i].deref(vm.gpa);
    inline for (&vm.unary_primitives, 0..) |*unary_primitive, i| {
        unary_primitive.* = try vm.createValue(.unary_primitive, @enumFromInt(i));
        unary_primitives_created += 1;
    }

    var operators_created: usize = 0;
    errdefer for (0..operators_created) |i| vm.operators[i].deref(vm.gpa);
    inline for (&vm.operators, 0..) |*operator, i| {
        operator.* = try vm.createValue(.operator, @enumFromInt(i));
        operators_created += 1;
    }

    var iterators_created: usize = 0;
    errdefer for (0..iterators_created) |i| vm.iterators[i].deref(vm.gpa);
    inline for (&vm.iterators, 0..) |*iterator, i| {
        iterator.* = try vm.createValue(.iterator, @enumFromInt(i));
        iterators_created += 1;
    }

    const keys = try vm.allocValue(.symbol_list, 1);
    errdefer keys.deref(gpa);
    keys.as.symbol_list[0] = .empty;

    const values = try vm.allocValue(.list, 1);
    errdefer values.deref(gpa);
    values.as.list[0] = vm.getUnaryPrimitive(.identity);

    const dict = try vm.createValue(.dict, .{ .keys = keys, .values = values });
    errdefer comptime unreachable;

    vm.state = dict;

    return vm;
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

fn getConstant(vm: *Vm, constant: Constant) *Value {
    return vm.constants[@intFromEnum(constant)].ref();
}

fn getUnaryPrimitive(vm: *Vm, unary_primitive: UnaryPrimitive) *Value {
    return vm.unary_primitives[@intFromEnum(unary_primitive)].ref();
}

fn getOperator(vm: *Vm, operator: Operator) *Value {
    return vm.operators[@intFromEnum(operator)].ref();
}

fn getIterator(vm: *Vm, iterator: Iterator) *Value {
    return vm.iterators[@intFromEnum(iterator)].ref();
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

fn applyImpl(vm: *Vm, func: *Value, args: []*Value) !*Value {
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
            if (unary_primitive == .list and args.len > 1) return vm.enlist(args);
            if (args.len > 1) return error.rank;
            switch (unary_primitive) {
                .empty => unreachable, // TODO: This might not be unreachable.
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
            .boolean, .long, .float, .char, .symbol, .dict => @intFromEnum(args[0].as),
        };
        break :is_vector for (args[1..]) |a| {
            if (first_type != @intFromEnum(a.as)) break false;
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
                .callee = vm.getUnaryPrimitive(.list),
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

    var tree: Ast = try .parse(vm.gpa, slice, .{
        .skip_comments = false,
        .mode = .q,
    });
    defer tree.deinit(vm.gpa);
    if (tree.errors.len > 0) {
        try q.printAstErrorsToStderr(vm.gpa, vm.io, tree, "<parse>", .auto);
        return error.parse;
    }

    return vm.parseTree(&tree);
}

fn eval(vm: *Vm, x: *Value) !*Value {
    std.log.debug("eval: {f}", .{x.fmt(vm)});
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

            if (value[0].as == .operator and value[0].as.operator == .assign) unreachable;

            var it = std.mem.reverseIterator(value);
            while (it.next()) |entry| vm.push(try vm.eval(entry));

            const stack = vm.stack.items[vm.stack.items.len - value.len ..];
            defer vm.stack.shrinkRetainingCapacity(vm.stack.items.len - value.len);
            defer for (stack) |v| v.deref(vm.gpa);

            // TODO: Remove reverse
            std.mem.reverse(*Value, stack);
            const func = stack[0];
            const args = stack[1..];

            return vm.applyImpl(func, args);
        },
        .symbol => |identifier| {
            // TODO: Namespaces
            if (std.mem.findScalar(Symbol, vm.state.as.dict.keys.as.symbol_list, identifier)) |index| {
                return vm.state.as.dict.values.as.list[index].ref();
            } else return error.identifier; // TODO: Improve error message
        },
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

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .empty => return vm.getUnaryPrimitive(.empty),

        .grouped_expression => return vm.parseNode(tree.nodeData(node).node_and_token[0]),
        .empty_list => return vm.getConstant(.empty_list),
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 1);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getUnaryPrimitive(.list));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .table_literal => unreachable,

        .lambda => {
            var compiler: Compiler = .init(vm, tree);
            defer compiler.deinit();
            return compiler.compile(node);
        },

        .expr_block => unreachable,

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
            const op: Node.Index = @enumFromInt(tree.nodeMainToken(node));

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, 3);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseNode(op));
            values.appendAssumeCapacity(try vm.parseNode(lhs));
            values.appendAssumeCapacity(if (maybe_rhs.unwrap()) |rhs|
                try vm.parseNode(rhs)
            else
                vm.getUnaryPrimitive(.empty));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },

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
        .symbol_list_literal => unreachable,
        .identifier => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const symbol = try vm.intern(slice);
            return vm.createValue(.symbol, symbol);
        },
        .builtin => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const builtin = std.meta.stringToEnum(Node.Builtin, slice).?;
            return switch (builtin) {
                .flip => unreachable,
                .neg => unreachable,
                .first => vm.getUnaryPrimitive(.first),
                .reciprocal => unreachable,
                .where => unreachable,
                .reverse => unreachable,
                .null => unreachable,
                .group => unreachable,
                .asc => unreachable,
                .desc => unreachable,
                .string => unreachable,
                .enlist => vm.getUnaryPrimitive(.list),
                .count => unreachable,
                .lower => unreachable,
                .not => unreachable,
                .key => unreachable,
                .distinct => unreachable,
                .type => unreachable,
                .value => vm.getUnaryPrimitive(.value),

                .parse => blk: {
                    var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 1);
                    defer values.deinit(vm.gpa);

                    const neg_five = try vm.createValue(.long, -5);
                    errdefer neg_five.deref(vm.gpa);

                    values.appendAssumeCapacity(neg_five);

                    break :blk vm.createValue(.projection, .{
                        .callee = vm.getOperator(.dict),
                        .args = values.toOwnedSliceAssert(),
                    });
                },
            };
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
        return @enumFromInt(gop.key_ptr.*);
    } else {
        gop.key_ptr.* = str_index;
        try vm.string_bytes.append(vm.gpa, 0);
        return @enumFromInt(str_index);
    }
}

pub fn internedString(vm: *Vm, index: Symbol) [:0]const u8 {
    const slice = vm.string_bytes.items[@intFromEnum(index)..];
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
    unreachable;
}
