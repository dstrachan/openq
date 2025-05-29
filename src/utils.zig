const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const AnyWriter = std.io.AnyWriter;

const q = @import("q");
const Ast = q.Ast;
const Node = q.Node;

pub fn writeJsonNode(writer: AnyWriter, tree: Ast, node: Node.Index) !void {
    switch (tree.nodeTag(node)) {
        .root => {
            try writer.writeAll(
                \\{"root":[
            );

            const statements = tree.rootStatements();
            for (statements, 0..) |statement, i| {
                try writeJsonNode(writer, tree, statement);
                if (i < statements.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}");
        },
        .no_op => unreachable,

        .grouped_expression => unreachable,

        .empty_list => unreachable,
        .list => unreachable,

        .table_literal => unreachable,

        .function => unreachable,

        .expr_block => unreachable,

        .colon => unreachable,
        .colon_colon => unreachable,
        .plus => try writer.print(
            \\{{"{s}":"{s}"}}
        , .{ @tagName(tree.nodeTag(node)), tree.tokenSlice(tree.nodeMainToken(node)) }),
        .plus_colon => unreachable,
        .minus => unreachable,
        .minus_colon => unreachable,
        .asterisk => try writer.print(
            \\{{"{s}":"{s}"}}
        , .{ @tagName(tree.nodeTag(node)), tree.tokenSlice(tree.nodeMainToken(node)) }),
        .asterisk_colon => unreachable,
        .percent => unreachable,
        .percent_colon => unreachable,
        .ampersand => unreachable,
        .ampersand_colon => unreachable,
        .pipe => unreachable,
        .pipe_colon => unreachable,
        .caret => unreachable,
        .caret_colon => unreachable,
        .equal => unreachable,
        .equal_colon => unreachable,
        .l_angle_bracket => unreachable,
        .l_angle_bracket_colon => unreachable,
        .l_angle_bracket_equal => unreachable,
        .l_angle_bracket_r_angle_bracket => unreachable,
        .r_angle_bracket => unreachable,
        .r_angle_bracket_colon => unreachable,
        .r_angle_bracket_equal => unreachable,
        .dollar => unreachable,
        .dollar_colon => unreachable,
        .comma => unreachable,
        .comma_colon => unreachable,
        .hash => unreachable,
        .hash_colon => unreachable,
        .underscore => unreachable,
        .underscore_colon => unreachable,
        .tilde => unreachable,
        .tilde_colon => unreachable,
        .bang => unreachable,
        .bang_colon => unreachable,
        .question_mark => unreachable,
        .question_mark_colon => unreachable,
        .at => unreachable,
        .at_colon => unreachable,
        .dot => unreachable,
        .dot_colon => unreachable,
        .zero_colon => unreachable,
        .zero_colon_colon => unreachable,
        .one_colon => unreachable,
        .one_colon_colon => unreachable,
        .two_colon => unreachable,

        .apostrophe => unreachable,
        .apostrophe_colon => unreachable,
        .slash => unreachable,
        .slash_colon => unreachable,
        .backslash => unreachable,
        .backslash_colon => unreachable,

        .call => unreachable,
        .apply_unary => unreachable,
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @enumFromInt(tree.nodeMainToken(node));

            try writer.writeAll(
                \\{"apply_binary":[
            );

            try writeJsonNode(writer, tree, op);
            try writer.writeByte(',');
            try writeJsonNode(writer, tree, lhs);
            if (maybe_rhs.unwrap()) |rhs| {
                try writer.writeByte(',');
                try writeJsonNode(writer, tree, rhs);
            }
            try writer.writeAll("]}");
        },

        .number_literal => {
            try writer.print(
                \\{{"number_literal":"{s}"}}
            , .{tree.tokenSlice(tree.nodeMainToken(node))});
        },
        .number_list_literal => unreachable,
        .string_literal => unreachable,
        .symbol_literal => unreachable,
        .symbol_list_literal => unreachable,
        .identifier => unreachable,
        .builtin => unreachable,

        .select => unreachable,
        .exec => unreachable,
        .update => unreachable,
        .delete_rows => unreachable,
        .delete_cols => unreachable,
    }
}
