const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Token = q.Token;
const Tokenizer = q.Tokenizer;

const Ast = @This();

source: [:0]const u8,
tokens: TokenList.Slice,
// nodes: NodeList.Slice,
// extra_data: []u32,
// errors: []const Error,

pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const TokenIndex = Token.Index;

pub const Node = struct {
    tag: Tag,

    pub const Tag = enum {};
};

pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[@intFromEnum(token_index)];
}

pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[@intFromEnum(token_index)];
}

pub fn nodeTag(tree: *const Ast, node: Node.Index) Node.Tag {
    return tree.nodes.items(.tag)[@intFromEnum(node)];
}

pub fn nodeMainToken(tree: *const Ast, node: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@intFromEnum(node)];
}

pub fn nodeData(tree: *const Ast, node: Node.Index) Node.Data {
    return tree.nodes.items(.data)[@intFromEnum(node)];
}

const Location = std.zig.Ast.Location;
const Span = std.zig.Ast.Span;

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

const RenderError = std.zig.Ast.RenderError;

pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast {
    var tokens: TokenList = .empty;
    defer tokens.deinit(gpa);

    const estimated_token_count = source.len / 8;
    try tokens.ensureTotalCapacity(gpa, estimated_token_count);

    var tokenizer: Tokenizer = .init(source);
    tokenizer.skipComments();
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{ .tag = token.tag, .start = @intCast(token.loc.start) });
        if (token.tag == .eof) break;
    }

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        // .nodes = nodes.toOwnedSlice(),
        // .extra_data = &.{},
        // .errors = &.{},
    };
}

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    const token_tag = tree.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: Tokenizer = .{
        .buffer = tree.source,
        .index = tree.tokenStart(token_index),
    };
    const token = tokenizer.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
    token: TokenIndex,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
        offset: u32,
    } = .{ .none = {} },

    pub const Tag = enum {
        /// `expected_tag` is populated.
        expected_token,

        /// `offset` is populated.
        invalid_byte,
    };
};
