const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Token = q.Token;
const Tokenizer = q.Tokenizer;
const Parse = q.Parse;

const Ast = @This();

source: [:0]const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,
extra_data: []u32,
errors: []const Error,

pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub const TokenIndex = Token.Index;
pub const OptionalTokenIndex = Token.OptionalIndex;

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

    var parser: Parse = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens.slice(),
        .errors = .empty,
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .tok_i = .zero,
    };
    defer parser.deinit();

    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    try parser.parseRoot();

    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(extra_data);
    const errors = try parser.errors.toOwnedSlice(gpa);
    errdefer gpa.free(errors);

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = errors,
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
        .next_is_minus = @intFromEnum(token_index) != 0 and tree.tokenTag(token_index.offset(-1)).isNextMinus(),
    };
    const token = tokenizer.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

/// Index into `extra_data`.
pub const ExtraIndex = enum(u32) {
    _,
};

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// Index into `nodes`.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
            assert(result != .none);
            return result;
        }

        pub fn toOffset(base: Index, destination: Index) Offset {
            const base_i64: i64 = @intFromEnum(base);
            const destination_i64: i64 = @intFromEnum(destination);
            return @enumFromInt(destination_i64 - base_i64);
        }
    };

    /// Index into `nodes`, or null.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }

        pub fn fromOptional(oi: ?Index) OptionalIndex {
            return if (oi) |i| i.toOptional() else .none;
        }
    };

    /// A relative node index.
    pub const Offset = enum(i32) {
        zero = 0,
        _,

        pub fn toOptional(o: Offset) OptionalOffset {
            const result: OptionalOffset = @enumFromInt(@intFromEnum(o));
            assert(result != .none);
            return result;
        }

        pub fn toAbsolute(offset: Offset, base: Index) Index {
            return @enumFromInt(@as(i64, @intFromEnum(base)) + @intFromEnum(offset));
        }
    };

    /// A relative node index, or null.
    pub const OptionalOffset = enum(i32) {
        none = std.math.maxInt(i32),
        _,

        pub fn unwrap(oo: OptionalOffset) ?Offset {
            return if (oo == .none) null else @enumFromInt(@intFromEnum(oo));
        }
    };

    comptime {
        assert(@sizeOf(Tag) == 1);
    }

    pub const Tag = enum {
        /// The root node which is guaranteed to be at `Node.Index.root`.
        ///
        /// The `main_token` field is the first token for the source file.
        root,
        /// The `data` field is unused.
        ///
        /// The `main_token` field is the next token.
        empty,

        no_op,

        apply_binary,

        plus,
        number_literal,
    };

    pub const Data = union {
        node: Index,
        // opt_node: OptionalIndex,
        token: TokenIndex,
        // opt_token: OptionalTokenIndex,
        // node_and_node: struct { Index, Index },
        node_and_opt_node: struct { Index, OptionalIndex },
        // node_and_token: struct { Index, TokenIndex },
        // node_and_opt_token: struct { Index, OptionalTokenIndex },
        // node_and_extra: struct { Index, ExtraIndex },
        // opt_node_and_node: struct { OptionalIndex, Index },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        // opt_node_and_token: struct { OptionalIndex, TokenIndex },
        // opt_node_and_opt_token: struct { OptionalIndex, OptionalTokenIndex },
        // opt_node_and_extra: struct { OptionalIndex, ExtraIndex },
        // token_and_node: struct { TokenIndex, Index },
        // token_and_opt_node: struct { TokenIndex, OptionalIndex },
        // token_and_token: struct { TokenIndex, TokenIndex },
        // token_and_opt_token: struct { TokenIndex, OptionalTokenIndex },
        // token_and_extra: struct { TokenIndex, ExtraIndex },
        // opt_token_and_node: struct { OptionalTokenIndex, Index },
        // opt_token_and_opt_node: struct { OptionalTokenIndex, OptionalIndex },
        // opt_token_and_token: struct { OptionalTokenIndex, TokenIndex },
        // opt_token_and_opt_token: struct { OptionalTokenIndex, OptionalTokenIndex },
        // opt_token_and_extra: struct { OptionalTokenIndex, ExtraIndex },
        // extra_and_node: struct { ExtraIndex, Index },
        // extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        // extra_and_token: struct { ExtraIndex, TokenIndex },
        // extra_and_opt_token: struct { ExtraIndex, OptionalTokenIndex },
        // extra_and_extra: struct { ExtraIndex, ExtraIndex },

        extra_range: SubRange,
    };

    pub const SubRange = struct {
        start: ExtraIndex,
        end: ExtraIndex,
    };
};

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
        expected_expr,
        expected_infix_expr,

        /// `expected_tag` is populated.
        expected_token,

        /// `offset` is populated.
        invalid_byte,
    };
};

test {
    const gpa = std.testing.allocator;
    var tree: Ast = try .parse(gpa, "3*4+5");
    defer tree.deinit(gpa);
}
