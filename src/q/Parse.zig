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
const OptionalTokenIndex = Token.OptionalIndex;

pub const Error = error{ParseError} || Allocator.Error;

const Parse = @This();

gpa: Allocator,
source: []const u8,
tokens: Ast.TokenList.Slice,
tok_i: TokenIndex,
errors: std.ArrayListUnmanaged(AstError),
nodes: Ast.NodeList,
extra_data: std.ArrayListUnmanaged(u32),
scratch: std.ArrayListUnmanaged(Node.Index),

fn tokenTag(p: *const Parse, token_index: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[@intFromEnum(token_index)];
}

fn tokenStart(p: *const Parse, token_index: TokenIndex) Ast.ByteOffset {
    return p.tokens.items(.start)[@intFromEnum(token_index)];
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
            else => @compileError("unexpected field type"),
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
        .main_token = .zero,
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
        const expr = p.parseExpression() catch |err| switch (err) {
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

fn parseExpression(p: *Parse) Error!Node.OptionalIndex {
    const noun = try p.parseNoun();
    var node = noun.unwrap() orelse return .none;

    while (true) {
        const verb = try p.parseVerb(node);
        node = verb.unwrap() orelse break;
    }

    return node.toOptional();
}

fn expectNoun(p: *Parse) !Node.Index {
    const noun = try p.parseNoun();
    return noun.unwrap() orelse p.fail(.expected_expr);
}

fn parseNoun(p: *Parse) !Node.OptionalIndex {
    const noun = switch (p.tokenTag(p.tok_i)) {
        .plus => try p.addNoun(.plus),
        .number_literal => try p.addNoun(.number_literal),
        .eos => return .none,
        .eof => unreachable,
        else => @panic(@tagName(p.tokenTag(p.tok_i))),
    };
    return noun.toOptional();
}

fn parseVerb(p: *Parse, node: Node.Index) !Node.OptionalIndex {
    const verb = switch (p.tokenTag(p.tok_i)) {
        .plus => try p.parseBinary(node),
        .number_literal => try p.parseUnary(node),
        .eos => return .none,
        .eof => return .none,
        else => @panic(@tagName(p.tokenTag(p.tok_i))),
    };
    return verb.toOptional();
}

fn parseUnary(p: *Parse, lhs: Node.Index) !Node.Index {
    switch (p.nodeTag(lhs)) {
        .plus => return p.fail(.expected_infix_expr),
        else => unreachable,
    }
}

fn parseBinary(p: *Parse, lhs: Node.Index) !Node.Index {
    const apply_index = try p.reserveNode(.apply_binary);
    errdefer p.unreserveNode(apply_index);

    const op = try p.expectNoun();

    return p.setNode(apply_index, .{
        .tag = .apply_binary,
        .main_token = @enumFromInt(@intFromEnum(op)),
        .data = .{ .node_and_opt_node = .{
            lhs,
            try p.parseExpression(),
        } },
    });
}

fn addNoun(p: *Parse, tag: Node.Tag) !Node.Index {
    return p.addNode(.{
        .tag = tag,
        .main_token = p.nextToken(),
        .data = undefined,
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
    if (@intFromEnum(p.tok_i) != p.tokens.len - 1) {
        p.tok_i = token.offset(1);
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
