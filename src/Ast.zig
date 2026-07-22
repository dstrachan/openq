const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Token = q.Token;
const Parse = q.Parse;
const Tokenizer = q.Tokenizer;

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

/// Index into `tokens`.
pub const TokenIndex = u32;

/// Index into `tokens`, or null.
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oti: OptionalTokenIndex) ?TokenIndex {
        return if (oti == .none) null else @intFromEnum(oti);
    }

    pub fn fromToken(ti: TokenIndex) OptionalTokenIndex {
        return @enumFromInt(ti);
    }

    pub fn fromOptional(oti: ?TokenIndex) OptionalTokenIndex {
        return if (oti) |ti| @enumFromInt(ti) else .none;
    }
};

/// A relative token index.
pub const TokenOffset = enum(i32) {
    zero = 0,
    _,

    pub fn init(base: TokenIndex, destination: TokenIndex) TokenOffset {
        const base_i64: i64 = base;
        const destination_i64: i64 = destination;
        return @enumFromInt(destination_i64 - base_i64);
    }

    pub fn toOptional(to: TokenOffset) OptionalTokenOffset {
        const result: OptionalTokenOffset = @enumFromInt(@intFromEnum(to));
        assert(result != .none);
        return result;
    }

    pub fn toAbsolute(offset: TokenOffset, base: TokenIndex) TokenIndex {
        return @intCast(@as(i64, base) + @intFromEnum(offset));
    }
};

/// A relative token index, or null.
pub const OptionalTokenOffset = enum(i32) {
    none = std.math.maxInt(i32),
    _,

    pub fn unwrap(oto: OptionalTokenOffset) ?TokenOffset {
        return if (oto == .none) null else @enumFromInt(@intFromEnum(oto));
    }
};

pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[token_index];
}

pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[token_index];
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

pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

pub const Span = struct {
    start: u32,
    end: u32,
    main: u32,
};

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

pub const Mode = enum { k, q };
pub const ParseOptions = struct {
    skip_comments: bool = true,
    mode: Mode,
};

pub fn parse(gpa: Allocator, source: [:0]const u8, options: ParseOptions) Allocator.Error!Ast {
    var parser: Parse = .{
        .gpa = gpa,
        .source = source,
        .tok_i = 0,
        .tokenizer = .init(source, options.mode),
        .tokens = .empty,
        .errors = .empty,
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .mode = options.mode,
        .ends_expression = .empty,
    };
    defer parser.tokens.deinit(gpa);
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);
    defer parser.ends_expression.deinit(gpa);

    // TODO: Estimate tokens/nodes based on source len
    const estimated_token_count = (source.len + 2) / 2;
    try parser.tokens.ensureTotalCapacity(gpa, estimated_token_count);
    const estimated_node_count = (estimated_token_count + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    // Prime tokenizer
    if (options.skip_comments) parser.tokenizer.skipComments();
    const token = parser.tokenizer.next();
    parser.tokens.appendAssumeCapacity(.{
        .tag = token.tag,
        .start = @intCast(token.loc.start),
    });

    try parser.parse();

    try parser.extra_data.shrinkToLen(gpa);
    try parser.errors.shrinkToLen(gpa);

    return .{
        .source = source,
        .tokens = parser.tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = parser.extra_data.toOwnedSliceAssert(),
        .errors = parser.errors.toOwnedSliceAssert(),
    };
}

/// Returns an extra offset for column and byte offset of errors that
/// should point after the token in the error message.
pub fn errorOffset(tree: Ast, parse_error: Error) u32 {
    return if (parse_error.token_is_prev) @intCast(tree.tokenSlice(parse_error.token).len) else 0;
}

pub fn tokenLocation(self: Ast, start_offset: ByteOffset, token_index: TokenIndex) Location {
    var loc = Location{
        .line = 0,
        .column = 0,
        .line_start = start_offset,
        .line_end = self.source.len,
    };
    const token_start = self.tokenStart(token_index);

    // Scan to by line until we go past the token start
    while (std.mem.findScalarPos(u8, self.source, loc.line_start, '\n')) |i| {
        if (i >= token_start) {
            break; // Went past
        }
        loc.line += 1;
        loc.line_start = i + 1;
    }

    const offset = loc.line_start;
    for (self.source[offset..], 0..) |c, i| {
        if (i + offset == token_start) {
            loc.line_end = i + offset;
            while (loc.line_end < self.source.len and self.source[loc.line_end] != '\n') {
                loc.line_end += 1;
            }
            return loc;
        }
        if (c == '\n') {
            loc.line += 1;
            loc.column = 0;
            loc.line_start = i + 1;
        } else {
            loc.column += 1;
        }
    }
    return loc;
}

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    return tree.tokenSliceMode(token_index, .q);
}

pub fn tokenSliceMode(tree: Ast, token_index: TokenIndex, mode: Mode) []const u8 {
    const token_tag = tree.tokenTag(token_index);
    assert(token_tag != .eos);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: Tokenizer = .{
        .buffer = tree.source,
        .index = tree.tokenStart(token_index),
        .mode = mode,
        .next_is_minus = token_index != 0 and tree.tokenTag(token_index - 1).isNextMinus(),
    };
    const token = token: {
        const token = tokenizer.next();
        break :token if (token.tag == .eos) tokenizer.next() else token;
    };
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn nodeSlice(tree: Ast, node: Node.Index) []const u8 {
    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);

    const first_token_start = tree.tokenStart(first_token);
    const last_token_start = tree.tokenStart(last_token);
    const last_token_end = last_token_start + tree.tokenSlice(last_token).len;

    return tree.source[first_token_start..last_token_end];
}

pub fn extraDataSlice(tree: Ast, range: Node.SubRange, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn extraDataSliceWithLen(tree: Ast, start: ExtraIndex, len: u32, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(start)..][0..len]);
}

pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
            bool => tree.extra_data[@intFromEnum(index) + i] == 1,
            Node.Index,
            Node.OptionalIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @enumFromInt(tree.extra_data[@intFromEnum(index) + i]),
            TokenIndex => tree.extra_data[@intFromEnum(index) + i],
            else => @compileError("unexpected field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

pub fn rootDecls(tree: Ast) []const Node.Index {
    return tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
}

pub fn renderError(tree: Ast, parse_error: Error, w: *Io.Writer) Io.Writer.Error!void {
    switch (parse_error.tag) {
        .expected_expr => {
            return w.print("expected expression, found '{s}'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .expected_infix_expr => {
            return w.print("expected infix expression, found '{s}'", .{
                tree.tokenTag(parse_error.token).symbol(),
            });
        },
        .invalid_dsl => {
            return w.print("invalid DSL '{s}'", .{
                tree.tokenSlice(parse_error.token),
            });
        },
        .expected_token => {
            const found_tag = tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev));
            const expected_symbol = parse_error.extra.expected_tag.symbol();
            switch (found_tag) {
                .invalid => return w.print("expected '{s}', found invalid bytes", .{
                    expected_symbol,
                }),
                else => return w.print("expected '{s}', found '{s}'", .{
                    expected_symbol, found_tag.symbol(),
                }),
            }
        },
        .expected_qsql_token => {
            const found_tag = tree.tokenTag(parse_error.token);
            const expected_string = parse_error.extra.expected_string;
            switch (found_tag) {
                .invalid => return w.print("expected '{s}', found invalid bytes", .{
                    expected_string,
                }),
                else => return w.print("expected '{s}', found '{s}'", .{
                    expected_string, found_tag.symbol(),
                }),
            }
        },
        .invalid_byte => {
            const tok_slice = tree.source[tree.tokens.items(.start)[parse_error.token]..];
            return w.print("{s} contains invalid byte: '{f}'", .{
                switch (tok_slice[0]) {
                    '\'' => "character literal",
                    '"', '\\' => "string literal",
                    '/' => "comment",
                    else => unreachable,
                },
                std.zig.fmtChar(tok_slice[parse_error.extra.offset]),
            });
        },
    }
}

pub fn firstToken(tree: Ast, node: Node.Index) TokenIndex {
    var n = node;
    var end_offset: u32 = 0;
    _ = &end_offset;
    while (true) switch (tree.nodeTag(n)) {
        .root => return 0,
        .empty => return tree.nodeMainToken(n) - end_offset,

        .grouped_expression,
        .empty_list,
        .list,
        .table_literal,
        => return tree.nodeMainToken(n) - end_offset,

        .lambda => return tree.nodeMainToken(n) - end_offset,

        .expr_block => return tree.nodeMainToken(n) - end_offset,

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
        => return tree.nodeMainToken(n) - end_offset,

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => n = tree.nodeData(n).opt_node.unwrap() orelse return tree.nodeMainToken(n) - end_offset,

        .call => n = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index)[0],
        .apply_unary => n = tree.nodeData(n).node_and_node[0],
        .apply_binary => n = tree.nodeData(n).node_and_opt_node[0],

        .number_literal,
        .number_list_literal,
        .string_literal,
        .symbol_literal,
        .symbol_list_literal,
        .identifier,
        .builtin,
        => return tree.nodeMainToken(n) - end_offset,

        .select,
        .exec,
        .update,
        .delete_rows,
        .delete_cols,
        => return tree.nodeMainToken(n) - end_offset,
    };
}

pub fn lastToken(tree: Ast, node: Node.Index) TokenIndex {
    var n = node;
    var end_offset: u32 = 0;
    while (true) switch (tree.nodeTag(n)) {
        .root => return @intCast(tree.tokens.len - 1),
        .empty => return tree.nodeMainToken(n) + end_offset,

        .grouped_expression => return tree.nodeData(n).node_and_token[1] + end_offset,
        .empty_list => return tree.nodeData(n).token + end_offset,
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            n = nodes[nodes.len - 1];
            end_offset += 1; // )
        },
        .table_literal => return tree.nodeData(n).extra_and_token[1] + end_offset,

        .lambda => return tree.nodeData(n).extra_and_token[1] + end_offset,

        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            n = nodes[nodes.len - 1];
            end_offset += 1; // ]
        },

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
        => return tree.nodeMainToken(n) + end_offset,

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => return tree.nodeMainToken(n) + end_offset,

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            n = nodes[nodes.len - 1];
            if (nodes.len == 1) {
                end_offset += 2; // []
            } else {
                end_offset += 1; // ]
            }
        },
        .apply_unary => n = tree.nodeData(n).node_and_node[1],
        .apply_binary => n = tree.nodeData(n).node_and_opt_node[1].unwrap() orelse @enumFromInt(tree.nodeMainToken(n)),

        .number_literal => return tree.nodeMainToken(n) + end_offset,
        .number_list_literal => return tree.nodeData(n).token + end_offset,
        .string_literal => return tree.nodeMainToken(n) + end_offset,
        .symbol_literal => return tree.nodeMainToken(n) + end_offset,
        .symbol_list_literal => return tree.nodeData(n).token + end_offset,
        .identifier => return tree.nodeMainToken(n) + end_offset,
        .builtin => return tree.nodeMainToken(n) + end_offset,

        inline .select, .exec, .update, .delete_rows => |t| {
            const sql = tree.extraData(tree.nodeData(n).extra, switch (t) {
                .select => Node.Select,
                .exec => Node.Exec,
                .update => Node.Update,
                .delete_rows => Node.DeleteRows,
                else => unreachable,
            });
            n = if (sql.where_end != sql.where_start) blk: {
                const nodes = tree.extraDataSlice(.{
                    .start = sql.where_start,
                    .end = sql.where_end,
                }, Node.Index);
                break :blk nodes[nodes.len - 1];
            } else sql.from;
        },
        .delete_cols => n = tree.extraData(tree.nodeData(n).extra, Node.DeleteCols).from,
    };
}

pub fn tokensOnSameLine(tree: Ast, token1: TokenIndex, token2: TokenIndex) bool {
    const source = tree.source[tree.tokenStart(token1)..tree.tokenStart(token2)];
    return std.mem.findScalar(u8, source, '\n') == null;
}

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
    /// True if `token` points to the token before the token causing an issue.
    token_is_prev: bool = false,
    token: TokenIndex,
    extra: union {
        none: void,
        expected_tag: Token.Tag,
        expected_string: []const u8,
        offset: usize,
    } = .{ .none = {} },

    pub const Tag = enum {
        expected_expr,
        expected_infix_expr,

        invalid_dsl,

        /// `expected_tag` is populated.
        expected_token,

        /// `expected_string` is populated.
        expected_qsql_token,

        /// `offset` is populated
        invalid_byte,
    };
};

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
        // Goal is to keep this under one byte for efficiency.
        assert(@sizeOf(Tag) == 1);

        if (!std.debug.runtime_safety) {
            assert(@sizeOf(Data) == 8);
        }
    }

    pub const Tag = enum {
        /// The root node which is guaranteed to be at `Node.Index.root`.
        ///
        /// The `main_token` field is the first token for the source file.
        root,
        /// The `data` field is unused.
        ///
        /// The `main_token` field is the previous token.
        empty,

        /// `(expr)`.
        ///
        /// The `data` field is a `.node_and_token`:
        ///   1. a `Node.Index` to the sub-expression.
        ///   2. a `TokenIndex` to the `)` token.
        ///
        /// The `main_token` field is the `(` token.
        grouped_expression,
        /// `()`.
        ///
        /// The `data` field is a `.token` of the `)`.
        ///
        /// The `main_token` field is the `(` token.
        empty_list,
        /// `(a;b;...)`.
        ///
        /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        /// each element.
        ///
        /// The `main_token` field is the `(` token.
        list,
        /// `([]a;b;...)`.
        ///
        /// The `data` field is a `.extra_and_token`:
        ///   1. a `ExtraIndex` to a `Table`.
        ///   2. a `TokenIndex` to the `)` token.
        ///
        /// The `main_token` field is the `(` token.
        table_literal,

        /// `{[]expr}`.
        ///
        /// The `data` field is a `.extra_and_token`:
        ///   1. a `ExtraIndex` to a `Lambda`.
        ///   2. a `TokenIndex` to the `}` token.
        ///
        /// The `main_token` field is the `{` token.
        lambda,

        /// `[expr]`.
        ///
        /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        /// each element.
        ///
        /// The `main_token` field is the `[` token.
        expr_block,

        /// The `main_token` field is the `:` token.
        colon,
        /// The `main_token` field is the `+` token.
        plus,
        /// The `main_token` field is the `-` token.
        minus,
        /// The `main_token` field is the `*` token.
        asterisk,
        /// The `main_token` field is the `%` token.
        percent,
        /// The `main_token` field is the `&` token.
        ampersand,
        /// The `main_token` field is the `|` token.
        pipe,
        /// The `main_token` field is the `^` token.
        caret,
        /// The `main_token` field is the `=` token.
        equal,
        /// The `main_token` field is the `<` token.
        l_angle_bracket,
        /// The `main_token` field is the `<=` token.
        l_angle_bracket_equal,
        /// The `main_token` field is the `<>` token.
        l_angle_bracket_r_angle_bracket,
        /// The `main_token` field is the `>` token.
        r_angle_bracket,
        /// The `main_token` field is the `>=` token.
        r_angle_bracket_equal,
        /// The `main_token` field is the `$` token.
        dollar,
        /// The `main_token` field is the `,` token.
        comma,
        /// The `main_token` field is the `#` token.
        hash,
        /// The `main_token` field is the `_` token.
        underscore,
        /// The `main_token` field is the `~` token.
        tilde,
        /// The `main_token` field is the `!` token.
        bang,
        /// The `main_token` field is the `?` token.
        question_mark,
        /// The `main_token` field is the `@` token.
        at,
        /// The `main_token` field is the `.` token.
        dot,
        /// The `main_token` field is the `0:` token.
        zero_colon,
        /// The `main_token` field is the `1:` token.
        one_colon,
        /// The `main_token` field is the `2:` token.
        two_colon,

        /// The `main_token` field is the `::` token.
        colon_colon,
        /// The `main_token` field is the `+:` token.
        plus_colon,
        /// The `main_token` field is the `-:` token.
        minus_colon,
        /// The `main_token` field is the `*:` token.
        asterisk_colon,
        /// The `main_token` field is the `%:` token.
        percent_colon,
        /// The `main_token` field is the `&:` token.
        ampersand_colon,
        /// The `main_token` field is the `|:` token.
        pipe_colon,
        /// The `main_token` field is the `^:` token.
        caret_colon,
        /// The `main_token` field is the `=:` token.
        equal_colon,
        /// The `main_token` field is the `<:` token.
        l_angle_bracket_colon,
        /// The `main_token` field is the `>:` token.
        r_angle_bracket_colon,
        /// The `main_token` field is the `$:` token.
        dollar_colon,
        /// The `main_token` field is the `,:` token.
        comma_colon,
        /// The `main_token` field is the `#:` token.
        hash_colon,
        /// The `main_token` field is the `_:` token.
        underscore_colon,
        /// The `main_token` field is the `~:` token.
        tilde_colon,
        /// The `main_token` field is the `!:` token.
        bang_colon,
        /// The `main_token` field is the `?:` token.
        question_mark_colon,
        /// The `main_token` field is the `@:` token.
        at_colon,
        /// The `main_token` field is the `.:` token.
        dot_colon,
        /// The `main_token` field is the `0::` token.
        zero_colon_colon,
        /// The `main_token` field is the `1::` token.
        one_colon_colon,

        /// `expr'`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `'` token.
        apostrophe,
        /// `expr':`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `':` token.
        apostrophe_colon,
        /// `expr/`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `/` token.
        slash,
        /// `expr/:`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `/:` token.
        slash_colon,
        /// `expr\`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `\` token.
        backslash,
        /// `expr\:`.
        ///
        /// The `data` field is a `.opt_node`.
        ///
        /// The `main_token` field is the `\:` token.
        backslash_colon,

        /// `expr[a;b;...]`.
        ///
        /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        /// each element.
        ///
        /// The `main_token` field is the `[` token.
        call,
        /// `expr expr`.
        ///
        /// The `data` field is a `.node_and_node`.
        ///
        /// The `main_token` field is unused.
        apply_unary,
        /// `expr op expr`.
        ///
        /// The `data` field is a `.node_and_opt_node`.
        ///
        /// The `main_token` field is the operator node.
        apply_binary,

        /// The `main_token` field is the number literal token.
        number_literal,
        /// `1 2 ...`.
        ///
        /// The `data` field is a `.token` that stores the last number literal token.
        ///
        /// The `main_token` field is the first number literal token.
        number_list_literal,
        /// The `main_token` field is the string literal token.
        string_literal,
        /// The `main_token` field is the symbol literal token.
        symbol_literal,
        /// `` `a`b...``.
        ///
        /// The `data` field is a `.token` that stores the last symbol literal token.
        ///
        /// The `main_token` field is the first symbol literal token.
        symbol_list_literal,
        /// The `main_token` field is the identifier token.
        identifier,
        /// The `main_token` field is the builtin token.
        builtin,

        /// `select ...`.
        ///
        /// The `data` field is a `.extra` to a `Select`.
        ///
        /// The `main_token` field is the `select` token.
        select,
        /// `exec ...`.
        ///
        /// The `data` field is a `.extra` to a `Exec`.
        ///
        /// The `main_token` field is the `exec` token.
        exec,
        /// `update ...`.
        ///
        /// The `data` field is a `.extra` to a `Update`.
        ///
        /// The `main_token` field is the `update` token.
        update,
        /// `delete ...`.
        ///
        /// The `data` field is a `.extra` to a `DeleteRows`.
        ///
        /// The `main_token` field is the `delete` token.
        delete_rows,
        /// `delete ...`.
        ///
        /// The `data` field is a `.extra` to a `DeleteCols`.
        ///
        /// The `main_token` field is the `delete` token.
        delete_cols,
    };

    pub const Data = union {
        node: Index,
        opt_node: OptionalIndex,
        token: TokenIndex,
        extra: ExtraIndex,
        node_and_node: struct { Index, Index },
        node_and_token: struct { Index, TokenIndex },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        node_and_opt_node: struct { Index, OptionalIndex },
        extra_and_token: struct { ExtraIndex, TokenIndex },
        extra_range: SubRange,
    };

    pub const SubRange = struct {
        /// Index into extra_data.
        start: ExtraIndex,
        /// Index into extra_data.
        end: ExtraIndex,
    };

    pub const Lambda = struct {
        params_start: ExtraIndex,
        body_start: ExtraIndex,
        body_end: ExtraIndex,
        trailing_semicolon: bool,
    };

    pub const Table = struct {
        keys_start: ExtraIndex,
        columns_start: ExtraIndex,
        columns_end: ExtraIndex,
    };

    pub const Select = struct {
        select_start: ExtraIndex,
        by_start: ExtraIndex,
        from: Index,
        where_start: ExtraIndex,
        where_end: ExtraIndex,
    };

    pub const Exec = struct {
        select_start: ExtraIndex,
        by_start: ExtraIndex,
        from: Index,
        where_start: ExtraIndex,
        where_end: ExtraIndex,
    };

    pub const Update = struct {
        select_start: ExtraIndex,
        by_start: ExtraIndex,
        from: Index,
        where_start: ExtraIndex,
        where_end: ExtraIndex,
    };

    pub const DeleteRows = struct {
        from: Index,
        where_start: ExtraIndex,
        where_end: ExtraIndex,
    };

    pub const DeleteCols = struct {
        select_start: ExtraIndex,
        select_end: ExtraIndex,
        from: Index,
    };

    pub const Builtin = enum {
        flip,
        neg,
        first,
        reciprocal,
        enlist,
        not,
        type,
    };
};

pub fn nodeToSpan(tree: *const Ast, node: Ast.Node.Index) Span {
    return tokensToSpan(
        tree,
        tree.firstToken(node),
        tree.lastToken(node),
        tree.nodeMainToken(node),
    );
}

pub fn tokenToSpan(tree: *const Ast, token: Ast.TokenIndex) Span {
    return tokensToSpan(tree, token, token, token);
}

pub fn tokensToSpan(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, main: Ast.TokenIndex) Span {
    var start_tok = start;
    var end_tok = end;

    if (tree.tokensOnSameLine(start, end)) {
        // do nothing
    } else if (tree.tokensOnSameLine(start, main)) {
        end_tok = main;
    } else if (tree.tokensOnSameLine(main, end)) {
        start_tok = main;
    } else {
        start_tok = main;
        end_tok = main;
    }
    const start_off = tree.tokenStart(start_tok);
    const end_off = tree.tokenStart(end_tok) + @as(u32, @intCast(tree.tokenSlice(end_tok).len));
    return Span{ .start = start_off, .end = end_off, .main = tree.tokenStart(main) };
}
