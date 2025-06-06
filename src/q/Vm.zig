const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;

const Vm = @This();

pub fn init() Vm {
    return .{};
}

pub fn deinit(vm: *Vm) void {
    _ = vm; // autofix
}

pub fn eval(vm: *Vm, tree: Ast) !Value {
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
        => return evalNode(vm, tree, tree.nodeData(node).node_and_token[0]),

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

            if (maybe_rhs.unwrap()) |rhs| {
                const rhs_value = try evalNode(vm, tree, rhs);
                const lhs_value = try evalNode(vm, tree, lhs);
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
            const long = std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)));
            switch (long) {
                .int => |v| return .init(.{ .long = @intCast(v) }),
                .big_int => unreachable,
                .float => unreachable,
                .failure => unreachable,
            }
        },
        .number_list_literal => @panic("NYI"),
        .string_literal => @panic("NYI"),
        .symbol_literal => @panic("NYI"),
        .symbol_list_literal => @panic("NYI"),
        .identifier => @panic("NYI"),
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
