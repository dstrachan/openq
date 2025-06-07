const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;

const Vm = @This();

gpa: Allocator,
error_buffer: std.ArrayListUnmanaged(u8) = .empty,
identifiers: std.StringHashMapUnmanaged(Value) = .empty,

pub const Error = Allocator.Error || error{
    UndeclaredIdentifier,
};

pub fn init(gpa: Allocator) Vm {
    return .{
        .gpa = gpa,
    };
}

pub fn deinit(vm: *Vm) void {
    var it = vm.identifiers.iterator();
    while (it.next()) |entry| {
        vm.gpa.free(entry.key_ptr.*);
        entry.value_ptr.deref();
    }
    vm.identifiers.deinit(vm.gpa);
    vm.error_buffer.deinit(vm.gpa);
}

pub fn eval(vm: *Vm, tree: Ast) !Value {
    vm.error_buffer.clearRetainingCapacity();

    const statements = tree.rootStatements();
    for (statements, 0..) |node, i| {
        const value = try vm.evalNode(tree, node);
        if (i == statements.len - 1) return value;
    }

    unreachable;
}

fn evalNode(vm: *Vm, tree: Ast, node: Node.Index) !Value {
    switch (tree.nodeTag(node)) {
        .root => @panic("NYI"),
        .no_op => @panic("NYI"),

        .grouped_expression,
        => return vm.evalNode(tree, tree.nodeData(node).node_and_token[0]),

        .empty_list => @panic("NYI"),
        .list => @panic("NYI"),
        .table_literal => @panic("NYI"),

        .function => @panic("NYI"),

        .expr_block => @panic("NYI"),

        .colon => @panic("NYI"),
        .colon_colon => @panic("NYI"),
        .plus => @panic("NYI"),
        .plus_colon => @panic("NYI"),
        .minus => @panic("NYI"),
        .minus_colon => @panic("NYI"),
        .asterisk => @panic("NYI"),
        .asterisk_colon => @panic("NYI"),
        .percent => @panic("NYI"),
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

        .call => @panic("NYI"),
        .apply_unary => @panic("NYI"),
        .apply_binary,
        => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @enumFromInt(tree.nodeMainToken(node));
            const op_tag = tree.nodeTag(op);
            if (op_tag == .colon) {
                assert(tree.nodeTag(lhs) == .identifier); // TODO: Validation layer
                const rhs = maybe_rhs.unwrap().?; // TODO: Validation layer
                var rhs_value = try vm.evalNode(tree, rhs);
                const identifier = tree.tokenSlice(tree.nodeMainToken(lhs));
                const gop = try vm.identifiers.getOrPut(vm.gpa, identifier);
                if (gop.found_existing) {
                    gop.value_ptr.deref();
                } else {
                    gop.key_ptr.* = try vm.gpa.dupe(u8, identifier);
                }

                gop.value_ptr.* = rhs_value;
                rhs_value.ref();

                return rhs_value;
            }

            if (maybe_rhs.unwrap()) |rhs| {
                const rhs_value = try vm.evalNode(tree, rhs);
                const lhs_value = try vm.evalNode(tree, lhs);
                switch (tree.nodeTag(op)) {
                    .plus => return add(lhs_value, rhs_value),
                    .minus => return subtract(lhs_value, rhs_value),
                    .asterisk => return multiply(lhs_value, rhs_value),
                    .percent => return divide(lhs_value, rhs_value),
                    else => @panic(@tagName(tree.nodeTag(node))),
                }
                return .{ .as = .{ .long = 1 } };
            } else @panic("NYI");
        },

        .number_literal,
        => {
            const number = std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)));
            switch (number) {
                .int => |int| return .init(.{ .long = @intCast(int) }),
                .big_int => unreachable,
                .float => unreachable,
                .failure => unreachable,
            }
        },
        .number_list_literal => @panic("NYI"),
        .string_literal => @panic("NYI"),
        .symbol_literal => @panic("NYI"),
        .symbol_list_literal => @panic("NYI"),
        .identifier => {
            const identifier = tree.tokenSlice(tree.nodeMainToken(node));
            if (vm.identifiers.get(identifier)) |value| {
                return value;
            }

            try vm.error_buffer.writer(vm.gpa).print("use of undeclared identifier '{s}'", .{identifier});
            return error.UndeclaredIdentifier;
        },
        .builtin => @panic("NYI"),

        .select => @panic("NYI"),
        .exec => @panic("NYI"),
        .update => @panic("NYI"),
        .delete_rows => @panic("NYI"),
        .delete_cols => @panic("NYI"),
    }
}

fn add(lhs: Value, rhs: Value) Value {
    return .init(switch (lhs.type) {
        .long => switch (rhs.type) {
            .long => .{ .long = lhs.as.long + rhs.as.long },
            .float => .{ .float = @as(f64, @floatFromInt(lhs.as.long)) + rhs.as.float },
        },
        .float => switch (rhs.type) {
            .long => .{ .float = lhs.as.float + @as(f64, @floatFromInt(rhs.as.long)) },
            .float => .{ .float = lhs.as.float + rhs.as.float },
        },
    });
}

fn subtract(lhs: Value, rhs: Value) Value {
    return .init(switch (lhs.type) {
        .long => switch (rhs.type) {
            .long => .{ .long = lhs.as.long - rhs.as.long },
            .float => .{ .float = @as(f64, @floatFromInt(lhs.as.long)) - rhs.as.float },
        },
        .float => switch (rhs.type) {
            .long => .{ .float = lhs.as.float - @as(f64, @floatFromInt(rhs.as.long)) },
            .float => .{ .float = lhs.as.float - rhs.as.float },
        },
    });
}

fn multiply(lhs: Value, rhs: Value) Value {
    return .init(switch (lhs.type) {
        .long => switch (rhs.type) {
            .long => .{ .long = lhs.as.long * rhs.as.long },
            .float => .{ .float = @as(f64, @floatFromInt(lhs.as.long)) * rhs.as.float },
        },
        .float => switch (rhs.type) {
            .long => .{ .float = lhs.as.float * @as(f64, @floatFromInt(rhs.as.long)) },
            .float => .{ .float = lhs.as.float * rhs.as.float },
        },
    });
}

fn divide(lhs: Value, rhs: Value) Value {
    return .init(switch (lhs.type) {
        .long => switch (rhs.type) {
            .long => .{ .float = @as(f64, @floatFromInt(lhs.as.long)) / @as(f64, @floatFromInt(rhs.as.long)) },
            .float => .{ .float = @as(f64, @floatFromInt(lhs.as.long)) / rhs.as.float },
        },
        .float => switch (rhs.type) {
            .long => .{ .float = lhs.as.float / @as(f64, @floatFromInt(rhs.as.long)) },
            .float => .{ .float = lhs.as.float / rhs.as.float },
        },
    });
}
