const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Ast = q.Ast;
const Value = q.Value;
const Symbol = Value.Symbol;
const UnaryPrimitive = Value.UnaryPrimitive;
const Operator = Value.Operator;
const Iterator = Value.Iterator;
const Compiler = q.Compiler;
const parseNumber = q.parseNumber;
const parseLong = q.parseLong;
const parseFloat = q.parseFloat;

const Vm = @This();

const Error = Allocator.Error || std.fmt.ParseIntError;

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

pub fn evalTree(vm: *Vm, tree: *const Ast) !*Value {
    vm.tree = tree;
    return vm.parseNode(.root);
}

fn parseNode(vm: *Vm, node: Ast.Node.Index) Error!*Value {
    const tree = vm.tree;
    const gpa = vm.gpa;

    switch (tree.nodeTag(node)) {
        .root => {
            const nodes = tree.extraDataSlice(tree.nodeData(.root).extra_range, Ast.Node.Index);
            assert(nodes.len > 0);
            if (nodes.len == 1) return vm.parseNode(nodes[0]);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getConstant(.semicolon));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .empty => unreachable,

        .grouped_expression => return vm.parseNode(tree.nodeData(node).node_and_token[0]),
        .empty_list => unreachable,
        .list => unreachable,
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

        .call => unreachable,
        .apply_unary => unreachable,
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Ast.Node.Index = @enumFromInt(tree.nodeMainToken(node));

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

        .number_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
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
                'j' => return vm.createValue(.long, try parseLong(slice[0 .. slice.len - 1])),
                'f' => return vm.createValue(.float, try parseFloat(slice[0 .. slice.len - 1])),
                else => return switch (try parseNumber(slice)) {
                    .long => |v| vm.createValue(.long, v),
                    .float => |v| vm.createValue(.float, v),
                },
            }
        },
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
