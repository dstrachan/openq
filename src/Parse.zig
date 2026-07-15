const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Token = q.Token;
const Tokenizer = q.Tokenizer;
const Ast = q.Ast;
const TokenIndex = Ast.TokenIndex;
const AstError = Ast.Error;
const Node = Ast.Node;
const Mode = Ast.Mode;
const ExtraIndex = Ast.ExtraIndex;
const OptionalTokenIndex = Ast.OptionalTokenIndex;

const Parse = @This();

pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
source: [:0]const u8,
tok_i: TokenIndex,
tokenizer: Tokenizer,
tokens: Ast.TokenList,
errors: std.ArrayList(AstError),
nodes: Ast.NodeList,
extra_data: std.ArrayList(u32),
scratch: std.ArrayList(Node.Index),
mode: Mode,
recover: bool,

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

const SmallSpan = union(enum) {
    zero_or_one: Node.OptionalIndex,
    multi: Node.SubRange,
};

const Exprs = struct {
    len: usize,
    data: Node.Data,
    trailing: bool,

    fn toSpan(self: Exprs, p: *Parse) !Node.SubRange {
        return switch (self.len) {
            0 => p.listToSpan(&.{}),
            1 => p.listToSpan(&.{self.data.opt_node_and_opt_node[0].unwrap().?}),
            2 => p.listToSpan(&.{ self.data.opt_node_and_opt_node[0].unwrap().?, self.data.opt_node_and_opt_node[1].unwrap().? }),
            else => self.data.extra_range,
        };
    }
};

fn listToSpan(p: *Parse, list: []const Node.Index) Allocator.Error!Node.SubRange {
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
        // There is zombie node left in the tree, let's make it as inoffensive as possible
        // (sadly there's no no-op node)
        p.nodes.items(.tag)[node_index] = .unreachable_literal;
        p.nodes.items(.main_token)[node_index] = p.tok_i;
    }
}

fn addExtra(p: *Parse, extra: anytype) Allocator.Error!ExtraIndex {
    const info = @typeInfo(@TypeOf(extra)).@"struct";
    try p.extra_data.ensureUnusedCapacity(p.gpa, info.field_names.len);
    const result: ExtraIndex = @enumFromInt(p.extra_data.items.len);
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        const data: u32 = switch (field_type) {
            Node.Index,
            Node.OptionalIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @intFromEnum(@field(extra, field_name)),
            TokenIndex,
            => @field(extra, field_name),
            else => @compileError("unexpected field type"),
        };
        p.extra_data.appendAssumeCapacity(data);
    }
    return result;
}

fn warnExpected(p: *Parse, expected_token: Token.Tag) Error!void {
    @branchHint(.cold);
    try p.warnMsg(.{
        .tag = .expected_token,
        .token = p.tok_i,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn warn(p: *Parse, error_tag: AstError.Tag) Error!void {
    @branchHint(.cold);
    try p.warnMsg(.{ .tag = error_tag, .token = p.tok_i });
}

fn warnMsg(p: *Parse, msg: Ast.Error) Error!void {
    @branchHint(.cold);
    switch (msg.tag) {
        .expected_expr,
        => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
            var copy = msg;
            copy.token_is_prev = true;
            copy.token -= 1;
            try p.errors.append(p.gpa, copy);
        } else {
            try p.errors.append(p.gpa, msg);
        },
        else => try p.errors.append(p.gpa, msg),
    }
    if (!p.recover) return error.ParseError;
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

pub fn parse(p: *Parse) Allocator.Error!void {
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    const root_exprs = p.parseExprs() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseError => {
            assert(p.errors.items.len > 0);
            return;
        },
    };
    if (p.tokenTag(p.tok_i) != .eof) {
        p.warnExpected(.eof) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseError => {
                assert(p.errors.items.len > 0);
                return;
            },
        };
    }
    p.nodes.items(.data)[0] = .{ .extra_range = try root_exprs.toSpan(p) };
}

fn parseExprs(p: *Parse) Error!Exprs {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const token = try p.nextToken();
        std.log.debug("{t}", .{token.tag});
        if (token.tag == .eof) break;
    }

    return .{
        .len = 0,
        .data = undefined,
        .trailing = false,
    };
}

fn nextToken(p: *Parse) !Token {
    const token = p.tokenizer.next();
    try p.tokens.append(p.gpa, .{
        .tag = token.tag,
        .start = @intCast(token.loc.start),
    });
    p.tok_i += 1;
    return token;
}

fn tokensOnSameLine(p: *Parse, token1: TokenIndex, token2: TokenIndex) bool {
    return std.mem.findScalar(u8, p.source[p.tokenStart(token1)..p.tokenStart(token2)], '\n') == null;
}
