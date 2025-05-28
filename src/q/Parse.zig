const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const AstError = Ast.Error;
const Node = q.Node;
const Token = q.Token;
const TokenIndex = Ast.TokenIndex;
const ExtraIndex = Ast.ExtraIndex;
const OptionalTokenIndex = Ast.OptionalTokenIndex;
const Tokenizer = q.Tokenizer;

pub const Error = error{ParseError} || Allocator.Error;

const Parse = @This();

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
tok_i: TokenIndex,
errors: std.ArrayListUnmanaged(AstError),
nodes: Ast.NodeList,
extra_data: std.ArrayListUnmanaged(u32),
scratch: std.ArrayListUnmanaged(Node.Index),

fn tokenTag(p: *const Parse, token_index: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[token_index];
}

fn tokenStart(p: *const Parse, token_index: TokenIndex) Ast.ByteOffset {
    return p.tokens.items(.start)[token_index];
}

fn nodeTag(p: *const Parse, node: Node.Index) Node.Tag {
    return p.nodes.items(.tag)[@intFromEnum(node)];
}

fn nodeMainToken(p: *const Parse, node: Node.Index) TokenIndex {
    return p.nodes.items(.main_token)[@intFromEnum(node)];
}

fn nodeData(p: *const Parse, node: Node.Index) Node.Data {
    return p.nodes.items(.data)[@intFromEnum(node)];
}

fn tokenSlice(p: *const Parse, token_index: TokenIndex) []const u8 {
    const token_tag = p.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: Tokenizer = .{
        .buffer = p.source,
        .index = p.tokenStart(token_index),
        .next_is_minus = false,
    };
    const token = tokenizer.next();
    assert(token.tag == token_tag);
    return p.source[token.loc.start..token.loc.end];
}

const Statements = struct {
    len: usize,
    data: Node.Data,

    fn toSpan(self: Statements, p: *Parse) !Node.SubRange {
        return switch (self.len) {
            0 => p.listToSpan(&.{}),
            1 => p.listToSpan(&.{self.data.opt_node_and_opt_node[0].unwrap().?}),
            2 => p.listToSpan(&.{ self.data.opt_node_and_opt_node[0].unwrap().?, self.data.opt_node_and_opt_node[1].unwrap().? }),
            else => self.data.extra_range,
        };
    }
};

fn listToSpan(p: *Parse, list: []const Node.Index) !Node.SubRange {
    try p.extra_data.appendSlice(p.gpa, @ptrCast(list));
    return .{
        .start = @enumFromInt(p.extra_data.items.len - list.len),
        .end = @enumFromInt(p.extra_data.items.len),
    };
}
fn addNode(p: *Parse, elem: Ast.Node) Allocator.Error!Node.Index {
    const result: Node.Index = @enumFromInt(p.nodes.len);
    try p.nodes.append(p.gpa, elem);
    return result;
}

fn setNode(p: *Parse, i: usize, elem: Ast.Node) Node.Index {
    p.nodes.set(i, elem);
    return @enumFromInt(i);
}

fn reserveNode(p: *Parse, tag: Ast.Node.Tag) !usize {
    try p.nodes.resize(p.gpa, p.nodes.len + 1);
    p.nodes.items(.tag)[p.nodes.len - 1] = tag;
    return p.nodes.len - 1;
}

fn unreserveNode(p: *Parse, node_index: usize) void {
    if (p.nodes.len == node_index) {
        p.nodes.resize(p.gpa, p.nodes.len - 1) catch unreachable;
    } else {
        p.nodes.items(.tag)[node_index] = .no_op;
    }
}

fn addExtra(p: *Parse, extra: anytype) Allocator.Error!ExtraIndex {
    const fields = std.meta.fields(@TypeOf(extra));
    try p.extra_data.ensureUnusedCapacity(p.gpa, fields.len);
    const result: ExtraIndex = @enumFromInt(p.extra_data.items.len);
    inline for (fields) |field| {
        const data: u32 = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @intFromEnum(@field(extra, field.name)),
            TokenIndex,
            => @field(extra, field.name),
            else => @compileError("unexpected field type: " ++ @typeName(field.type)),
        };
        p.extra_data.appendAssumeCapacity(data);
    }
    return result;
}

fn warnExpected(p: *Parse, expected_token: Token.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn warn(p: *Parse, error_tag: AstError.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{ .tag = error_tag, .token = p.tok_i });
}

fn warnMsg(p: *Parse, msg: Ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.errors.append(p.gpa, msg);
}

fn fail(p: *Parse, tag: Ast.Error.Tag) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    return p.failMsg(.{ .tag = tag, .token = p.tok_i });
}

fn failExpected(p: *Parse, expected_token: Token.Tag) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    return p.failMsg(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn failMsg(p: *Parse, msg: Ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try p.warnMsg(msg);
    return error.ParseError;
}

pub fn deinit(p: *Parse) void {
    p.errors.deinit(p.gpa);
    p.nodes.deinit(p.gpa);
    p.extra_data.deinit(p.gpa);
    p.scratch.deinit(p.gpa);
}

pub fn parseRoot(p: *Parse) !void {
    // Root node must be index 0.
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    const statements = try p.parseStatements();
    if (p.tokenTag(p.tok_i) != .eof) {
        try p.warnExpected(.eof);
    }
    p.nodes.items(.data)[0] = .{ .extra_range = try statements.toSpan(p) };
}

fn parseStatements(p: *Parse) !Statements {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.tokenTag(p.tok_i) != .eof) {
        const expr = p.parseExpression(null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                p.skipStatement();
                break :blk .none;
            },
        };
        if (expr.unwrap()) |node| try p.scratch.append(p.gpa, node);
        _ = p.eatToken(.semicolon);
        if (p.tokenTag(p.tok_i) != .eos and p.tokenTag(p.tok_i) != .eof) {
            try p.warn(.expected_expr);
            p.skipStatement();
        }
        _ = p.eatToken(.eos);
    }

    const items = p.scratch.items[scratch_top..];
    return .{
        .len = items.len,
        .data = switch (items.len) {
            0, 1, 2 => .{ .opt_node_and_opt_node = .{
                if (items.len >= 1) items[0].toOptional() else .none,
                if (items.len >= 2) items[1].toOptional() else .none,
            } },
            else => .{ .extra_range = try p.listToSpan(items) },
        },
    };
}

fn expectExpression(p: *Parse, comptime sql_identifier: ?SqlIdentifier) !Node.Index {
    const expr = try p.parseExpression(sql_identifier);
    return expr.unwrap() orelse p.fail(.expected_expr);
}

fn parseExpression(p: *Parse, comptime sql_identifier: ?SqlIdentifier) Error!Node.OptionalIndex {
    const noun = try p.parseNoun(sql_identifier);
    var node = noun.unwrap() orelse return .none;

    while (true) {
        const verb = try p.parseVerb(node, sql_identifier);
        node = verb.unwrap() orelse break;
    }

    return node.toOptional();
}

fn endsExpression(p: *Parse, comptime sql_identifier: ?SqlIdentifier) bool {
    if (sql_identifier) |sql_id| {
        if (p.tokenTag(p.tok_i) == .comma) return true;
        if (p.peekIdentifier(sql_id)) return true;
    }
    return switch (p.tokenTag(p.tok_i)) {
        .r_paren, .r_bracket, .r_brace, .semicolon, .eos, .eof => true,
        else => false,
    };
}

fn expectNoun(p: *Parse, comptime sql_identifier: ?SqlIdentifier) !Node.Index {
    const noun = try p.parseNoun(sql_identifier);
    return noun.unwrap() orelse p.fail(.expected_expr);
}

fn parseNoun(p: *Parse, comptime sql_identifier: ?SqlIdentifier) !Node.OptionalIndex {
    if (p.endsExpression(sql_identifier)) return .none;

    const noun = switch (p.tokenTag(p.tok_i)) {
        // Punctuation
        .l_paren => try p.parseGroup(),
        .r_paren => unreachable,
        .l_bracket => try p.parseBlock(),
        .r_bracket => unreachable,
        .l_brace => try p.parseFunction(),
        .r_brace => unreachable,
        .semicolon => unreachable,

        // Operators
        .bang => try p.addNoun(.bang),
        .bang_colon => try p.addNoun(.bang_colon),
        .hash => try p.addNoun(.hash),
        .hash_colon => try p.addNoun(.hash_colon),
        .dollar => try p.addNoun(.dollar),
        .dollar_colon => try p.addNoun(.dollar_colon),
        .percent => try p.addNoun(.percent),
        .percent_colon => try p.addNoun(.percent_colon),
        .ampersand => try p.addNoun(.ampersand),
        .ampersand_colon => try p.addNoun(.ampersand_colon),
        .asterisk => try p.addNoun(.asterisk),
        .asterisk_colon => try p.addNoun(.asterisk_colon),
        .plus => try p.addNoun(.plus),
        .plus_colon => try p.addNoun(.plus_colon),
        .comma => try p.addNoun(.comma),
        .comma_colon => try p.addNoun(.comma_colon),
        .minus => try p.addNoun(.minus),
        .minus_colon => try p.addNoun(.minus_colon),
        .dot => try p.addNoun(.dot),
        .dot_colon => try p.addNoun(.dot_colon),
        .colon => try p.addNoun(.colon),
        .colon_colon => try p.addNoun(.colon_colon),
        .l_angle_bracket => try p.addNoun(.l_angle_bracket),
        .l_angle_bracket_colon => try p.addNoun(.l_angle_bracket_colon),
        .equal => try p.addNoun(.equal),
        .equal_colon => try p.addNoun(.equal_colon),
        .r_angle_bracket => try p.addNoun(.r_angle_bracket),
        .r_angle_bracket_colon => try p.addNoun(.r_angle_bracket_colon),
        .question_mark => try p.addNoun(.question_mark),
        .question_mark_colon => try p.addNoun(.question_mark_colon),
        .at => try p.addNoun(.at),
        .at_colon => try p.addNoun(.at_colon),
        .caret => try p.addNoun(.caret),
        .caret_colon => try p.addNoun(.caret_colon),
        .underscore => try p.addNoun(.underscore),
        .underscore_colon => try p.addNoun(.underscore_colon),
        .pipe => try p.addNoun(.pipe),
        .pipe_colon => try p.addNoun(.pipe_colon),
        .tilde => try p.addNoun(.tilde),
        .tilde_colon => try p.addNoun(.tilde_colon),
        .zero_colon => try p.addNoun(.zero_colon),
        .zero_colon_colon => try p.addNoun(.zero_colon_colon),
        .one_colon => try p.addNoun(.one_colon),
        .one_colon_colon => try p.addNoun(.one_colon_colon),
        .two_colon => try p.addNoun(.two_colon),

        // Iterators
        .apostrophe => try p.addIterator(.apostrophe, .none),
        .apostrophe_colon => try p.addIterator(.apostrophe_colon, .none),
        .slash => try p.addIterator(.slash, .none),
        .slash_colon => try p.addIterator(.slash_colon, .none),
        .backslash => try p.addIterator(.backslash, .none),
        .backslash_colon => try p.addIterator(.backslash_colon, .none),

        // Literals
        .number_literal => try p.parseNumberLiteral(),
        .string_literal => try p.addNoun(.string_literal),
        .symbol_literal => try p.parseSymbolLiteral(),
        .identifier => try p.addNoun(.identifier),

        // Misc.
        .system => @panic("NYI"),
        .invalid => return p.fail(.expected_expr),
        .eos => unreachable,
        .eof => unreachable,

        // Keywords
        .keyword_select => try p.parseSelect(),
        .keyword_exec => @panic("NYI"),
        .keyword_update => @panic("NYI"),
        .keyword_delete => @panic("NYI"),
    };
    const call = try p.parseCall(noun);
    return if (call == .none) noun.toOptional() else call;
}

fn expectVerb(p: *Parse, lhs: Node.Index, comptime sql_identifier: ?SqlIdentifier) !Node.Index {
    const verb = try p.parseVerb(lhs, sql_identifier);
    return verb.unwrap() orelse p.fail(.expected_expr);
}

fn parseVerb(p: *Parse, lhs: Node.Index, comptime sql_identifier: ?SqlIdentifier) Error!Node.OptionalIndex {
    if (p.endsExpression(sql_identifier)) return .none;

    const verb = switch (p.tokenTag(p.tok_i)) {
        // Punctuation
        .l_paren => try p.parseUnary(lhs, sql_identifier),
        .r_paren => unreachable,
        .l_bracket => unreachable,
        .r_bracket => unreachable,
        .l_brace => try p.parseUnary(lhs, sql_identifier),
        .r_brace => unreachable,
        .semicolon => unreachable,

        // Operators
        .bang,
        .bang_colon,
        .hash,
        .hash_colon,
        .dollar,
        .dollar_colon,
        .percent,
        .percent_colon,
        .ampersand,
        .ampersand_colon,
        .asterisk,
        .asterisk_colon,
        .plus,
        .plus_colon,
        .comma,
        .comma_colon,
        .minus,
        .minus_colon,
        .dot,
        .dot_colon,
        .colon,
        .colon_colon,
        .l_angle_bracket,
        .l_angle_bracket_colon,
        .equal,
        .equal_colon,
        .r_angle_bracket,
        .r_angle_bracket_colon,
        .question_mark,
        .question_mark_colon,
        .at,
        .at_colon,
        .caret,
        .caret_colon,
        .underscore,
        .underscore_colon,
        .pipe,
        .pipe_colon,
        .tilde,
        .tilde_colon,
        .zero_colon,
        .zero_colon_colon,
        .one_colon,
        .one_colon_colon,
        .two_colon,
        => try p.parseBinary(lhs, sql_identifier),

        // Iterators
        .apostrophe => unreachable,
        .apostrophe_colon => unreachable,
        .slash => unreachable,
        .slash_colon => unreachable,
        .backslash => unreachable,
        .backslash_colon => unreachable,

        // Literals
        .number_literal,
        .string_literal,
        .symbol_literal,
        .identifier,
        => try p.parseUnary(lhs, sql_identifier),

        // Misc.
        .system => unreachable,
        .invalid => return p.fail(.expected_expr),
        .eos => unreachable,
        .eof => unreachable,

        // Keywords
        .keyword_select => @panic("NYI"),
        .keyword_exec => @panic("NYI"),
        .keyword_update => @panic("NYI"),
        .keyword_delete => @panic("NYI"),
    };
    return verb.toOptional();
}

fn parseCall(p: *Parse, lhs: Node.Index) !Node.OptionalIndex {
    if (p.tokenTag(p.tok_i) != .l_bracket) return p.parseIterator(lhs.toOptional());

    const l_bracket = p.assertToken(.l_bracket);

    const call_index = try p.reserveNode(.call);
    errdefer p.unreserveNode(call_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    try p.scratch.append(p.gpa, lhs);

    if (p.tokenTag(p.tok_i) != .r_bracket) {
        while (true) {
            const expr = try p.parseExpression(null);
            try p.scratch.append(p.gpa, expr.unwrap() orelse try p.noOp());
            _ = p.eatToken(.semicolon) orelse break;
        }
    }
    _ = try p.expectToken(.r_bracket);

    const args = p.scratch.items[scratch_top..];
    return p.parseCall(p.setNode(call_index, .{
        .tag = .call,
        .main_token = l_bracket,
        .data = .{ .extra_range = try p.listToSpan(args) },
    }));
}

fn parseIterator(p: *Parse, lhs: Node.OptionalIndex) Error!Node.OptionalIndex {
    const tag: Node.Tag = switch (p.tokenTag(p.tok_i)) {
        .apostrophe => .apostrophe,
        .apostrophe_colon => .apostrophe_colon,
        .slash => .slash,
        .slash_colon => .slash_colon,
        .backslash => .backslash,
        .backslash_colon => .backslash_colon,
        else => return .none,
    };
    const iterator = try p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = .{ .opt_node = lhs },
    });
    return p.parseCall(iterator);
}

fn parseUnary(p: *Parse, lhs: Node.Index, comptime sql_identifier: ?SqlIdentifier) !Node.Index {
    switch (p.nodeTag(lhs)) {
        .colon,
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

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => return p.fail(.expected_infix_expr),
        else => {},
    }

    const apply_index = try p.reserveNode(.apply_unary);
    errdefer p.unreserveNode(apply_index);

    const rhs = try p.expectNoun(sql_identifier);
    switch (p.nodeTag(rhs)) {
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => return p.setNode(apply_index, .{
            .tag = .apply_binary,
            .main_token = @intFromEnum(rhs),
            .data = .{
                .node_and_opt_node = .{
                    lhs,
                    try p.parseExpression(sql_identifier),
                },
            },
        }),
        else => return p.setNode(apply_index, .{
            .tag = .apply_unary,
            .main_token = undefined,
            .data = .{
                .node_and_node = .{
                    lhs,
                    try p.expectVerb(rhs, sql_identifier),
                },
            },
        }),
    }
}

fn parseBinary(p: *Parse, lhs: Node.Index, comptime sql_identifier: ?SqlIdentifier) !Node.Index {
    const apply_index = try p.reserveNode(.apply_binary);
    errdefer p.unreserveNode(apply_index);

    const op = try p.expectNoun(sql_identifier);

    return p.setNode(apply_index, .{
        .tag = .apply_binary,
        .main_token = @intFromEnum(op),
        .data = .{ .node_and_opt_node = .{
            lhs,
            try p.parseExpression(sql_identifier),
        } },
    });
}

fn parseGroup(p: *Parse) !Node.Index {
    const l_paren = p.assertToken(.l_paren);
    if (p.tokenTag(p.tok_i) == .l_bracket) return p.parseTable(l_paren);

    const group_index = try p.reserveNode(.grouped_expression);
    errdefer p.unreserveNode(group_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    if (p.tokenTag(p.tok_i) != .r_paren) {
        while (true) {
            const expr = try p.parseExpression(null);
            try p.scratch.append(p.gpa, expr.unwrap() orelse try p.noOp());
            _ = p.eatToken(.semicolon) orelse break;
        }
    }
    const r_paren = try p.expectToken(.r_paren);

    const list = p.scratch.items[scratch_top..];
    switch (list.len) {
        0 => return p.setNode(group_index, .{
            .tag = .empty_list,
            .main_token = l_paren,
            .data = .{ .token = r_paren },
        }),
        1 => return p.setNode(group_index, .{
            .tag = .grouped_expression,
            .main_token = l_paren,
            .data = .{ .node_and_token = .{
                list[0],
                r_paren,
            } },
        }),
        else => return p.setNode(group_index, .{
            .tag = .list,
            .main_token = l_paren,
            .data = .{ .extra_range = try p.listToSpan(list) },
        }),
    }
}

fn parseTable(p: *Parse, l_paren: TokenIndex) !Node.Index {
    _ = p.assertToken(.l_bracket);

    const table_index = try p.reserveNode(.table_literal);
    errdefer p.unreserveNode(table_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    const keys_top = p.scratch.items.len;
    if (p.tokenTag(p.tok_i) != .r_bracket) {
        while (true) {
            const expr = try p.expectExpression(null);
            try p.scratch.append(p.gpa, expr);
            _ = p.eatToken(.semicolon) orelse break;
        }
    }
    _ = try p.expectToken(.r_bracket);

    const columns_top = p.scratch.items.len;

    while (true) {
        const expr = try p.expectExpression(null);
        try p.scratch.append(p.gpa, expr);
        _ = p.eatToken(.semicolon) orelse break;
    }
    const r_paren = try p.expectToken(.r_paren);

    const keys = try p.listToSpan(p.scratch.items[keys_top..columns_top]);
    const columns = try p.listToSpan(p.scratch.items[columns_top..]);
    const table: Node.Table = .{
        .keys_start = keys.start,
        .columns_start = columns.start,
        .columns_end = columns.end,
    };
    return p.setNode(table_index, .{
        .tag = .table_literal,
        .main_token = l_paren,
        .data = .{ .extra_and_token = .{
            try p.addExtra(table),
            r_paren,
        } },
    });
}

fn parseBlock(p: *Parse) !Node.Index {
    const l_bracket = p.assertToken(.l_bracket);

    const block_index = try p.reserveNode(.expr_block);
    errdefer p.unreserveNode(block_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const expr = try p.parseExpression(null);
        if (expr.unwrap()) |node| try p.scratch.append(p.gpa, node);
        _ = p.eatToken(.semicolon) orelse break;
    }
    _ = try p.expectToken(.r_bracket);

    const nodes = p.scratch.items[scratch_top..];
    return p.setNode(block_index, .{
        .tag = .expr_block,
        .main_token = l_bracket,
        .data = .{ .extra_range = try p.listToSpan(nodes) },
    });
}

fn parseFunction(p: *Parse) !Node.Index {
    const l_brace = p.assertToken(.l_brace);

    const function_index = try p.reserveNode(.function);
    errdefer p.unreserveNode(function_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    const params_top = p.scratch.items.len;
    if (p.eatToken(.l_bracket)) |_| {
        if (p.tokenTag(p.tok_i) != .r_bracket) {
            while (true) {
                const expr = try p.expectExpression(null);
                try p.scratch.append(p.gpa, expr);
                _ = p.eatToken(.semicolon) orelse break;
            }
        }
        _ = try p.expectToken(.r_bracket);
    }

    const body_top = p.scratch.items.len;
    while (true) {
        const expr = try p.parseExpression(null);
        if (expr.unwrap()) |node| try p.scratch.append(p.gpa, node);
        _ = p.eatToken(.semicolon) orelse break;
    }
    const r_brace = try p.expectToken(.r_brace);

    const params = try p.listToSpan(p.scratch.items[params_top..body_top]);
    const body = try p.listToSpan(p.scratch.items[body_top..]);
    const function: Node.Function = .{
        .params_start = params.start,
        .body_start = body.start,
        .body_end = body.end,
    };
    return p.setNode(function_index, .{
        .tag = .function,
        .main_token = l_brace,
        .data = .{ .extra_and_token = .{
            try p.addExtra(function),
            r_brace,
        } },
    });
}

fn parseNumberLiteral(p: *Parse) !Node.Index {
    const number_literal = p.assertToken(.number_literal);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.tokenTag(p.tok_i) == .number_literal) {
        try p.scratch.append(p.gpa, @enumFromInt(p.nextToken()));
    }

    const items: []TokenIndex = @ptrCast(p.scratch.items[scratch_top..]);
    switch (items.len) {
        0 => return p.addNode(.{
            .tag = .number_literal,
            .main_token = number_literal,
            .data = undefined,
        }),
        else => return p.addNode(.{
            .tag = .number_list_literal,
            .main_token = number_literal,
            .data = .{ .token = items[items.len - 1] },
        }),
    }
}

fn parseSymbolLiteral(p: *Parse) !Node.Index {
    const symbol_literal = p.assertToken(.symbol_literal);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.tokenTag(p.tok_i) == .symbol_literal and
        !std.ascii.isWhitespace(p.source[p.tokenStart(p.tok_i) - 1]))
    {
        try p.scratch.append(p.gpa, @enumFromInt(p.nextToken()));
    }

    const items: []TokenIndex = @ptrCast(p.scratch.items[scratch_top..]);
    switch (items.len) {
        0 => return p.addNode(.{
            .tag = .symbol_literal,
            .main_token = symbol_literal,
            .data = undefined,
        }),
        else => return p.addNode(.{
            .tag = .symbol_list_literal,
            .main_token = symbol_literal,
            .data = .{ .token = items[items.len - 1] },
        }),
    }
}

fn parseSelect(p: *Parse) !Node.Index {
    const select_token = p.assertToken(.keyword_select);

    const select_index = try p.reserveNode(.select);
    errdefer p.unreserveNode(select_index);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    // Select phrase
    const select_top = p.scratch.items.len;
    if (!p.peekIdentifier(.{ .by = true, .from = true })) {
        while (true) {
            const expr = try p.expectExpression(.{ .by = true, .from = true });
            try p.scratch.append(p.gpa, expr);
            _ = p.eatToken(.comma) orelse break;
        }
    }

    // By phrase
    const by_top = p.scratch.items.len;
    if (p.eatIdentifier(.{ .by = true })) |_| {
        while (true) {
            const expr = try p.expectExpression(.{ .from = true });
            try p.scratch.append(p.gpa, expr);
            _ = p.eatToken(.comma) orelse break;
        }
    }

    // From phrase
    _ = try p.expectIdentifier(.{ .from = true });
    const from_expr = try p.expectExpression(.{ .where = true });

    // Where phrase
    const where_top = p.scratch.items.len;
    if (p.eatIdentifier(.{ .where = true })) |_| {
        while (true) {
            const expr = try p.expectExpression(.{});
            try p.scratch.append(p.gpa, expr);
            _ = p.eatToken(.comma) orelse break;
        }
    }

    const select = try p.listToSpan(p.scratch.items[select_top..by_top]);
    const by = try p.listToSpan(p.scratch.items[by_top..where_top]);
    const where = try p.listToSpan(p.scratch.items[where_top..]);
    const select_node: Node.Select = .{
        .select_start = select.start,
        .by_start = by.start,
        .from = from_expr,
        .where_start = where.start,
        .where_end = where.end,
    };
    return p.setNode(select_index, .{
        .tag = .select,
        .main_token = select_token,
        .data = .{ .extra = try p.addExtra(select_node) },
    });
}

const SqlIdentifier = packed struct(u8) {
    by: bool = false,
    from: bool = false,
    where: bool = false,
    _: u5 = 0,
};

fn peekIdentifier(p: *Parse, comptime sql_identifier: SqlIdentifier) bool {
    if (p.tokenTag(p.tok_i) == .identifier) {
        const slice = p.tokenSlice(p.tok_i);
        if (sql_identifier.by and std.mem.eql(u8, slice, "by")) return true;
        if (sql_identifier.from and std.mem.eql(u8, slice, "from")) return true;
        if (sql_identifier.where and std.mem.eql(u8, slice, "where")) return true;
    }
    return false;
}

fn eatIdentifier(p: *Parse, comptime sql_identifier: SqlIdentifier) ?TokenIndex {
    return if (p.peekIdentifier(sql_identifier)) p.nextToken() else null;
}

fn expectIdentifier(p: *Parse, comptime sql_identifier: SqlIdentifier) !TokenIndex {
    return p.eatIdentifier(sql_identifier) orelse p.failMsg(.{
        .tag = .expected_qsql_token,
        .token = p.tok_i,
        .extra = .{
            .expected_string = if (sql_identifier.by)
                "by"
            else if (sql_identifier.from)
                "from"
            else if (sql_identifier.where)
                "where",
        },
    });
}

fn noOp(p: *Parse) !Node.Index {
    return p.addNode(.{
        .tag = .no_op,
        .main_token = undefined,
        .data = undefined,
    });
}

fn addNoun(p: *Parse, tag: Node.Tag) !Node.Index {
    return p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = undefined,
    });
}

fn addIterator(p: *Parse, tag: Node.Tag, lhs: Node.OptionalIndex) !Node.Index {
    return p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = .{ .opt_node = lhs },
    });
}

fn eatToken(p: *Parse, tag: Token.Tag) ?TokenIndex {
    return if (p.tokenTag(p.tok_i) == tag) p.nextToken() else null;
}

fn assertToken(p: *Parse, tag: Token.Tag) TokenIndex {
    const token = p.nextToken();
    assert(p.tokenTag(token) == tag);
    return token;
}

fn expectToken(p: *Parse, tag: Token.Tag) !TokenIndex {
    return if (p.tokenTag(p.tok_i) == tag) p.nextToken() else p.failExpected(tag);
}

fn nextToken(p: *Parse) TokenIndex {
    const token = p.tok_i;
    if (p.tok_i != p.tokens.len - 1) {
        p.tok_i += 1;
    }
    return token;
}

fn skipStatement(p: *Parse) void {
    while (p.tokenTag(p.tok_i) != .eof) {
        _ = p.nextToken();
    }
    _ = p.nextToken();
}

fn testParse(
    source: [:0]const u8,
    expected_tokens: []const Token.Tag,
    expected_nodes: []const Node.Tag,
    expected_errors: []const Ast.Error.Tag,
) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    try std.testing.expectEqualSlices(Token.Tag, expected_tokens, tree.tokens.items(.tag)[0 .. tree.tokens.len - 1]);
    try std.testing.expectEqualSlices(Node.Tag, expected_nodes, tree.nodes.items(.tag));

    const actual_errors = try gpa.alloc(Ast.Error.Tag, tree.errors.len);
    defer gpa.free(actual_errors);
    for (tree.errors, actual_errors) |err, *actual_error| actual_error.* = err.tag;
    try std.testing.expectEqualSlices(Ast.Error.Tag, expected_errors, actual_errors);
}

test "parse end of statement" {
    try testParse(
        "1+2",
        &.{ .number_literal, .plus, .number_literal },
        &.{ .root, .number_literal, .apply_binary, .plus, .number_literal },
        &.{},
    );
    try testParse(
        \\1+
        \\ 2
    ,
        &.{ .number_literal, .plus, .number_literal },
        &.{ .root, .number_literal, .apply_binary, .plus, .number_literal },
        &.{},
    );
    try testParse(
        \\1
        \\ +2
    ,
        &.{ .number_literal, .plus, .number_literal },
        &.{ .root, .number_literal, .apply_binary, .plus, .number_literal },
        &.{},
    );
    try testParse(
        \\1
        \\ +
        \\ 2
    ,
        &.{ .number_literal, .plus, .number_literal },
        &.{ .root, .number_literal, .apply_binary, .plus, .number_literal },
        &.{},
    );

    try testParse(
        \\1
        \\+2
    ,
        &.{ .number_literal, .eos, .plus, .number_literal },
        &.{ .root, .number_literal, .plus },
        &.{.expected_infix_expr},
    );
    try testParse(
        \\1
        \\+
        \\ 2
    ,
        &.{ .number_literal, .eos, .plus, .number_literal },
        &.{ .root, .number_literal, .plus },
        &.{.expected_infix_expr},
    );

    try testParse(
        \\1
        \\+
        \\2
    ,
        &.{ .number_literal, .eos, .plus, .eos, .number_literal },
        &.{ .root, .number_literal, .plus, .number_literal },
        &.{},
    );
}

test "parse select" {
    try testParse(
        "select a,b by a,b from x where a,b",
        &.{
            .keyword_select, .identifier, .comma, .identifier, // select
            .identifier, .identifier, .comma, .identifier, // by
            .identifier, .identifier, // from
            .identifier, .identifier, .comma, .identifier, // where
        },
        &.{
            .root, .select, .identifier, .identifier, // select
            .identifier, .identifier, // by
            .identifier, // from
            .identifier, .identifier, // where
        },
        &.{},
    );
    try testParse(
        "select(a,b),(c,d)by(a,b),(c,d)from x where(a,b),(c,d)",
        &.{
            .keyword_select, .l_paren, .identifier, .comma, .identifier, .r_paren, .comma, .l_paren, .identifier, .comma, .identifier, .r_paren, // select
            .identifier, .l_paren, .identifier, .comma, .identifier, .r_paren, .comma, .l_paren, .identifier, .comma, .identifier, .r_paren, // by
            .identifier, .identifier, // from
            .identifier, .l_paren, .identifier, .comma, .identifier, .r_paren, .comma, .l_paren, .identifier, .comma, .identifier, .r_paren, // where
        },
        &.{
            .root, .select, .grouped_expression, .identifier, .apply_binary, .comma, .identifier, .grouped_expression, .identifier, .apply_binary, .comma, .identifier, // select
            .grouped_expression, .identifier, .apply_binary, .comma, .identifier, .grouped_expression, .identifier, .apply_binary, .comma, .identifier, // by
            .identifier, // from
            .grouped_expression, .identifier, .apply_binary, .comma, .identifier, .grouped_expression, .identifier, .apply_binary, .comma, .identifier, // where
        },
        &.{},
    );
    try testParse(
        "select f[a,b;c],d by f[a,b;c],d from x where f[a,b;c],d",
        &.{
            .keyword_select, .identifier, .l_bracket, .identifier, .comma, .identifier, .semicolon, .identifier, .r_bracket, .comma, .identifier, // select
            .identifier, .identifier, .l_bracket, .identifier, .comma, .identifier, .semicolon, .identifier, .r_bracket, .comma, .identifier, // by
            .identifier, .identifier, // from
            .identifier, .identifier, .l_bracket, .identifier, .comma, .identifier, .semicolon, .identifier, .r_bracket, .comma, .identifier, // where
        },
        &.{
            .root, .select, .identifier, .call, .identifier, .apply_binary, .comma, .identifier, .identifier, .identifier, // select
            .identifier, .call, .identifier, .apply_binary, .comma, .identifier, .identifier, .identifier, // by
            .identifier, // from
            .identifier, .call, .identifier, .apply_binary, .comma, .identifier, .identifier, .identifier, // where
        },
        &.{},
    );
}
