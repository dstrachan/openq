const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const q = @import("q");
const Ast = q.Ast;
const Node = q.Node;
const AstGen = q.AstGen;
const Qir = q.Qir;

pub fn writeJsonNode(writer: *Writer, tree: Ast, node: Node.Index) !void {
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

            try writer.writeAll("]}\n");
        },
        .no_op => try writer.writeAll(
            \\{"no_op":""}
        ),

        .grouped_expression => {
            try writer.writeAll(
                \\{"grouped_expression":
            );

            try writeJsonNode(writer, tree, tree.nodeData(node).node_and_token[0]);

            try writer.writeAll("}");
        },

        .empty_list => try writer.writeAll(
            \\{"empty_list":[]}
        ),
        inline .list, .expr_block => |t| {
            try writer.writeAll("{\"" ++ @tagName(t) ++ "\":[");

            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);

            for (nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}");
        },

        .table_literal => {
            try writer.writeAll(
                \\{"table_literal":{"keys":[
            );

            const table = tree.extraData(tree.nodeData(node).extra_and_token[0], Node.Table);

            const keys = tree.extraDataSlice(.{
                .start = table.keys_start,
                .end = table.columns_start,
            }, Node.Index);
            for (keys, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < keys.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"columns":[
            );

            const columns = tree.extraDataSlice(.{
                .start = table.columns_start,
                .end = table.columns_end,
            }, Node.Index);
            for (columns, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < columns.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },

        .function => {
            try writer.writeAll(
                \\{"function":{"params":[
            );

            const function = tree.extraData(tree.nodeData(node).extra_and_token[0], Node.Function);

            const params = tree.extraDataSlice(.{
                .start = function.params_start,
                .end = function.body_start,
            }, Node.Index);
            for (params, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < params.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"body":[
            );

            const body = tree.extraDataSlice(.{
                .start = function.body_start,
                .end = function.body_end,
            }, Node.Index);
            for (body, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < body.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },

        inline .colon,
        .colon_colon,
        .plus,
        .plus_colon,
        .minus,
        .minus_colon,
        .asterisk,
        .asterisk_colon,
        .percent,
        .percent_colon,
        .ampersand,
        .ampersand_colon,
        .pipe,
        .pipe_colon,
        .caret,
        .caret_colon,
        .equal,
        .equal_colon,
        .l_angle_bracket,
        .l_angle_bracket_colon,
        .l_angle_bracket_equal,
        .l_angle_bracket_r_angle_bracket,
        .r_angle_bracket,
        .r_angle_bracket_colon,
        .r_angle_bracket_equal,
        .dollar,
        .dollar_colon,
        .comma,
        .comma_colon,
        .hash,
        .hash_colon,
        .underscore,
        .underscore_colon,
        .tilde,
        .tilde_colon,
        .bang,
        .bang_colon,
        .question_mark,
        .question_mark_colon,
        .at,
        .at_colon,
        .dot,
        .dot_colon,
        .zero_colon,
        .zero_colon_colon,
        .one_colon,
        .one_colon_colon,
        .two_colon,
        => |t| try writer.print(
            "{{\"" ++ @tagName(t) ++ "\":\"{s}\"}}",
            .{tree.tokenSlice(tree.nodeMainToken(node))},
        ),

        inline .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => |t| {
            try writer.writeAll("{\"" ++ @tagName(t) ++ "\":");

            const maybe_lhs = tree.nodeData(node).opt_node;
            if (maybe_lhs.unwrap()) |lhs| {
                try writeJsonNode(writer, tree, lhs);
            } else {
                try writer.writeAll("{}");
            }

            try writer.writeByte('}');
        },

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 0);

            try writer.writeAll(
                \\{"call":{"function":
            );

            try writeJsonNode(writer, tree, nodes[0]);
            try writer.writeAll(
                \\,"args":[
            );
            for (nodes[1..], 1..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;

            try writer.writeAll(
                \\{"apply_unary":[
            );

            try writeJsonNode(writer, tree, lhs);
            try writer.writeByte(',');
            try writeJsonNode(writer, tree, rhs);

            try writer.writeAll("]}");
        },
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

        inline .number_literal,
        .symbol_literal,
        .identifier,
        .builtin,
        => |t| try writer.print(
            "{{\"" ++ @tagName(t) ++ "\":\"{s}\"}}",
            .{tree.tokenSlice(tree.nodeMainToken(node))},
        ),
        .string_literal,
        => try writer.print(
            \\{{"string_literal":"{f}"}}
        , .{std.zig.fmtString(tree.tokenSlice(tree.nodeMainToken(node)))}),
        inline .number_list_literal,
        .symbol_list_literal,
        => |t| {
            try writer.writeAll("{\"" ++ @tagName(t) ++ "\":[");

            const first_token = tree.nodeMainToken(node);
            const last_token = tree.nodeData(node).token;
            for (first_token..last_token + 1) |tok_i| {
                try writer.print("\"{s}\"", .{tree.tokenSlice(@intCast(tok_i))});
                if (tok_i < last_token) try writer.writeByte(',');
            }

            try writer.writeAll("]}");
        },

        .select => {
            try writer.writeAll(
                \\{"select":{"select":[
            );

            const select = tree.extraData(tree.nodeData(node).extra, Node.Select);

            const select_nodes = tree.extraDataSlice(.{
                .start = select.select_start,
                .end = select.by_start,
            }, Node.Index);
            for (select_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < select_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"by":[
            );
            const by_nodes = tree.extraDataSlice(.{
                .start = select.by_start,
                .end = select.where_start,
            }, Node.Index);
            for (by_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < by_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"from":
            );
            try writeJsonNode(writer, tree, select.from);

            try writer.writeAll(
                \\,"where":[
            );
            const where_nodes = tree.extraDataSlice(.{
                .start = select.where_start,
                .end = select.where_end,
            }, Node.Index);
            for (where_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < where_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },
        .exec => {
            try writer.writeAll(
                \\{"exec":{"select":[
            );

            const exec = tree.extraData(tree.nodeData(node).extra, Node.Exec);

            const select_nodes = tree.extraDataSlice(.{
                .start = exec.select_start,
                .end = exec.by_start,
            }, Node.Index);
            for (select_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < select_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"by":[
            );
            const by_nodes = tree.extraDataSlice(.{
                .start = exec.by_start,
                .end = exec.where_start,
            }, Node.Index);
            for (by_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < by_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"from":
            );
            try writeJsonNode(writer, tree, exec.from);

            try writer.writeAll(
                \\,"where":[
            );
            const where_nodes = tree.extraDataSlice(.{
                .start = exec.where_start,
                .end = exec.where_end,
            }, Node.Index);
            for (where_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < where_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },
        .update => {
            try writer.writeAll(
                \\{"update":{"select":[
            );

            const update = tree.extraData(tree.nodeData(node).extra, Node.Update);

            const select_nodes = tree.extraDataSlice(.{
                .start = update.select_start,
                .end = update.by_start,
            }, Node.Index);
            for (select_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < select_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"by":[
            );
            const by_nodes = tree.extraDataSlice(.{
                .start = update.by_start,
                .end = update.where_start,
            }, Node.Index);
            for (by_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < by_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"from":
            );
            try writeJsonNode(writer, tree, update.from);

            try writer.writeAll(
                \\,"where":[
            );
            const where_nodes = tree.extraDataSlice(.{
                .start = update.where_start,
                .end = update.where_end,
            }, Node.Index);
            for (where_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < where_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },
        .delete_rows => {
            try writer.writeAll(
                \\{"delete_rows":{"from":
            );

            const delete_rows = tree.extraData(tree.nodeData(node).extra, Node.DeleteRows);

            try writeJsonNode(writer, tree, delete_rows.from);

            try writer.writeAll(
                \\,"where":[
            );
            const where_nodes = tree.extraDataSlice(.{
                .start = delete_rows.where_start,
                .end = delete_rows.where_end,
            }, Node.Index);
            for (where_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < where_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll("]}}");
        },
        .delete_cols => {
            try writer.writeAll(
                \\{"delete_cols":{"select":[
            );

            const delete_cols = tree.extraData(tree.nodeData(node).extra, Node.DeleteCols);

            const select_nodes = tree.extraDataSlice(.{
                .start = delete_cols.select_start,
                .end = delete_cols.select_end,
            }, Node.Index);
            for (select_nodes, 0..) |n, i| {
                try writeJsonNode(writer, tree, n);
                if (i < select_nodes.len - 1) try writer.writeByte(',');
            }

            try writer.writeAll(
                \\],"from":
            );
            try writeJsonNode(writer, tree, delete_cols.from);

            try writer.writeAll("}}");
        },
    }
}

pub fn printAstErrorsToStderr(gpa: Allocator, tree: Ast, path: []const u8, color: std.zig.Color) !void {
    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
    try wip_errors.init(gpa);
    defer wip_errors.deinit();

    try q.putAstErrorsIntoBundle(gpa, tree, path, &wip_errors);

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);
    error_bundle.renderToStdErr(color.renderOptions());
}

pub fn printQirErrorsToStderr(gpa: Allocator, qir: Qir, tree: Ast, path: []const u8, color: std.zig.Color) !void {
    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
    try wip_errors.init(gpa);
    defer wip_errors.deinit();

    try q.addQirErrorMessages(&wip_errors, qir, tree, path);

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);
    error_bundle.renderToStdErr(color.renderOptions());
}
