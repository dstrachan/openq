const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
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

pub const Location = std.zig.Ast.Location;
pub const Span = std.zig.Ast.Span;

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
        .tok_i = 0,
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

pub fn normalize(tree: Ast, gpa: Allocator) !Ast {
    assert(tree.errors.len == 0);

    var tokens = try tree.tokens.toMultiArrayList().clone(gpa);
    errdefer tokens.deinit(gpa);

    var parser: Parse.Normalize = .{
        .gpa = gpa,
        .source = tree.source,
        .tokens = tokens.slice(),
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .tree = tree,
    };
    defer parser.deinit();

    // TODO: How many nodes can we reduce by?
    try parser.nodes.ensureTotalCapacity(gpa, tree.nodes.len);

    try parser.normalize();

    const extra_data = try parser.extra_data.toOwnedSlice(gpa);
    errdefer comptime unreachable;

    return .{
        .source = tree.source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = extra_data,
        .errors = &.{},
    };
}

pub fn nodeSlice(tree: Ast, node: Node.Index) []const u8 {
    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);
    return tree.source[tree.tokenStart(first_token) .. tree.tokenStart(last_token) + tree.tokenSlice(last_token).len];
}

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
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
        .next_is_minus = token_index != 0 and tree.tokenTag(token_index - 1).isNextMinus(),
    };
    const token = token: {
        const token = tokenizer.next();
        break :token if (token.tag == .eos) tokenizer.next() else token;
    };
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn extraDataSlice(tree: Ast, range: Node.SubRange, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
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

pub fn rootStatements(tree: Ast) []const Node.Index {
    return tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
}

pub fn renderError(tree: Ast, parse_error: Error, writer: *Writer) !void {
    switch (parse_error.tag) {
        .expected_expr => {
            return writer.print("expected expression, found '{s}'", .{
                tree.tokenTag(parse_error.token).symbol(),
            });
        },
        .expected_infix_expr => {
            return writer.print("expected infix expression, found '{s}'", .{
                tree.tokenTag(parse_error.token).symbol(),
            });
        },
        .expected_token => {
            const found_tag = tree.tokenTag(parse_error.token);
            const expected_symbol = parse_error.extra.expected_tag.symbol();
            switch (found_tag) {
                .invalid => return writer.print("expected '{s}', found invalid bytes", .{
                    expected_symbol,
                }),
                else => return writer.print("expected '{s}', found '{s}'", .{
                    expected_symbol, found_tag.symbol(),
                }),
            }
        },
        .expected_qsql_token => {
            const found_tag = tree.tokenTag(parse_error.token);
            const expected_string = parse_error.extra.expected_string;
            switch (found_tag) {
                .invalid => return writer.print("expected '{s}', found invalid bytes", .{
                    expected_string,
                }),
                else => return writer.print("expected '{s}', found '{s}'", .{
                    expected_string, found_tag.symbol(),
                }),
            }
        },
        .invalid_byte => {
            const tok_slice = tree.source[tree.tokenStart(parse_error.token)..];
            return writer.print("{s} contains invalid byte: '{f}'", .{
                switch (tok_slice[0]) {
                    '"' => "string literal",
                    '/' => "comment",
                    else => "token",
                },
                std.zig.fmtChar(tok_slice[parse_error.extra.offset]),
            });
        },
    }
}

pub fn firstToken(tree: Ast, node: Node.Index) TokenIndex {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .root => return 0,
        .no_op => unreachable,

        .grouped_expression,
        .empty_list,
        .list,
        .table_literal,
        .function,
        .expr_block,
        => return tree.nodeMainToken(n),

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
        => return tree.nodeMainToken(n),

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => n = tree.nodeData(n).opt_node.unwrap() orelse return tree.nodeMainToken(n),

        .call => n = tree.extraDataSlice(
            tree.nodeData(n).extra_range,
            Node.Index,
        )[@intFromBool(tree.tokenTag(tree.nodeMainToken(node)) == .eof)],
        .apply_unary => n = tree.nodeData(n).node_and_node[0],
        .apply_binary => n = tree.nodeData(n).node_and_opt_node[0],

        .number_literal,
        .number_list_literal,
        .string_literal,
        .symbol_literal,
        .symbol_list_literal,
        .identifier,
        .builtin,
        => return tree.nodeMainToken(n),

        .select,
        .exec,
        .update,
        .delete_rows,
        .delete_cols,
        => return tree.nodeMainToken(n),
    };
}

pub fn lastToken(tree: Ast, node: Node.Index) TokenIndex {
    var n = node;
    var end_offset: u32 = 0;
    while (true) switch (tree.nodeTag(n)) {
        .root => return @intCast(tree.tokens.len - 1),
        .no_op => unreachable,

        .grouped_expression => return tree.nodeData(n).node_and_token[1] + end_offset,
        .empty_list => return tree.nodeData(n).token + end_offset,

        .list,
        => {
            end_offset += 1; // r_paren
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            var it = std.mem.reverseIterator(nodes[1..]);
            n = while (it.next()) |expr| {
                if (tree.nodeTag(expr) == .no_op) {
                    end_offset += 1; // semicolon
                    continue;
                }
                break expr;
            } else if (tree.nodeTag(nodes[0]) != .no_op) nodes[0] else return tree.nodeMainToken(n) + end_offset;
        },

        .table_literal,
        .function,
        => return tree.nodeData(n).extra_and_token[1] + end_offset,

        .expr_block,
        => {
            end_offset += 1; // r_bracket
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            if (nodes.len == 0) return tree.nodeMainToken(n) + end_offset;
            var it = std.mem.reverseIterator(nodes[1..]);
            n = while (it.next()) |expr| {
                if (tree.nodeTag(expr) == .no_op) {
                    end_offset += 1; // semicolon
                    continue;
                }
                break expr;
            } else if (tree.nodeTag(nodes[0]) != .no_op) nodes[0] else return tree.nodeMainToken(n) + end_offset;
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
            if (tree.tokenTag(tree.nodeMainToken(node)) == .eof) {
                const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
                n = switch (nodes.len) {
                    2 => unreachable, // TODO: Test
                    3 => if (tree.nodeTag(nodes[2]) == .no_op) nodes[0] else nodes[2],
                    else => unreachable,
                };
                continue;
            }

            end_offset += 1; // r_bracket
            const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Node.Index);
            if (nodes.len == 1) return tree.nodeMainToken(n) + end_offset;
            var it = std.mem.reverseIterator(nodes[2..]);
            n = while (it.next()) |expr| {
                if (tree.nodeTag(expr) == .no_op) {
                    end_offset += 1; // semicolon
                    continue;
                }
                break expr;
            } else if (tree.nodeTag(nodes[1]) != .no_op) nodes[1] else return tree.nodeMainToken(n) + end_offset;
        },
        .apply_unary => n = tree.nodeData(n).node_and_node[1],
        .apply_binary => n = tree.nodeData(n).node_and_opt_node[1].unwrap() orelse @enumFromInt(tree.nodeMainToken(n)),

        .number_literal,
        .string_literal,
        .symbol_literal,
        .identifier,
        .builtin,
        => return tree.nodeMainToken(n) + end_offset,

        .number_list_literal,
        .symbol_list_literal,
        => return tree.nodeData(n).token + end_offset,

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
    return std.mem.indexOfScalar(u8, source, '\n') == null;
}

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
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
        assert(@sizeOf(Tag) == 1);
    }

    pub const Tag = enum {
        /// The root node which is guaranteed to be at `Node.Index.root`.
        ///
        /// The `main_token` field is the first token for the source file.
        root,
        /// The `data` field is unused.
        ///
        /// The `main_token` field is unused.
        no_op,

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
        ///   1. a `ExtraIndex` to a `Function`.
        ///   2. a `TokenIndex` to the `}` token.
        ///
        /// The `main_token` field is the `{` token.
        function,

        /// `[expr]`.
        ///
        /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        /// each element.
        ///
        /// The `main_token` field is the `[` token.
        expr_block,

        /// The `main_token` field is the `:` token.
        colon,
        /// The `main_token` field is the `::` token.
        colon_colon,
        /// The `main_token` field is the `+` token.
        plus,
        /// The `main_token` field is the `+:` token.
        plus_colon,
        /// The `main_token` field is the `-` token.
        minus,
        /// The `main_token` field is the `-:` token.
        minus_colon,
        /// The `main_token` field is the `*` token.
        asterisk,
        /// The `main_token` field is the `*:` token.
        asterisk_colon,
        /// The `main_token` field is the `%` token.
        percent,
        /// The `main_token` field is the `%:` token.
        percent_colon,
        /// The `main_token` field is the `&` token.
        ampersand,
        /// The `main_token` field is the `&:` token.
        ampersand_colon,
        /// The `main_token` field is the `|` token.
        pipe,
        /// The `main_token` field is the `|:` token.
        pipe_colon,
        /// The `main_token` field is the `^` token.
        caret,
        /// The `main_token` field is the `^:` token.
        caret_colon,
        /// The `main_token` field is the `=` token.
        equal,
        /// The `main_token` field is the `=:` token.
        equal_colon,
        /// The `main_token` field is the `<` token.
        l_angle_bracket,
        /// The `main_token` field is the `<:` token.
        l_angle_bracket_colon,
        /// The `main_token` field is the `<=` token.
        l_angle_bracket_equal,
        /// The `main_token` field is the `<>` token.
        l_angle_bracket_r_angle_bracket,
        /// The `main_token` field is the `>` token.
        r_angle_bracket,
        /// The `main_token` field is the `>:` token.
        r_angle_bracket_colon,
        /// The `main_token` field is the `>=` token.
        r_angle_bracket_equal,
        /// The `main_token` field is the `$` token.
        dollar,
        /// The `main_token` field is the `$:` token.
        dollar_colon,
        /// The `main_token` field is the `,` token.
        comma,
        /// The `main_token` field is the `,:` token.
        comma_colon,
        /// The `main_token` field is the `#` token.
        hash,
        /// The `main_token` field is the `#:` token.
        hash_colon,
        /// The `main_token` field is the `_` token.
        underscore,
        /// The `main_token` field is the `_:` token.
        underscore_colon,
        /// The `main_token` field is the `~` token.
        tilde,
        /// The `main_token` field is the `~:` token.
        tilde_colon,
        /// The `main_token` field is the `!` token.
        bang,
        /// The `main_token` field is the `!:` token.
        bang_colon,
        /// The `main_token` field is the `?` token.
        question_mark,
        /// The `main_token` field is the `?:` token.
        question_mark_colon,
        /// The `main_token` field is the `@` token.
        at,
        /// The `main_token` field is the `@:` token.
        at_colon,
        /// The `main_token` field is the `.` token.
        dot,
        /// The `main_token` field is the `.:` token.
        dot_colon,
        /// The `main_token` field is the `0:` token.
        zero_colon,
        /// The `main_token` field is the `0::` token.
        zero_colon_colon,
        /// The `main_token` field is the `1:` token.
        one_colon,
        /// The `main_token` field is the `1::` token.
        one_colon_colon,
        /// The `main_token` field is the `2:` token.
        two_colon,

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
        // opt_token: OptionalTokenIndex,
        extra: ExtraIndex,
        node_and_node: struct { Index, Index },
        node_and_opt_node: struct { Index, OptionalIndex },
        node_and_token: struct { Index, TokenIndex },
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
        extra_and_token: struct { ExtraIndex, TokenIndex },
        // extra_and_opt_token: struct { ExtraIndex, OptionalTokenIndex },
        // extra_and_extra: struct { ExtraIndex, ExtraIndex },
        extra_range: SubRange,
    };

    pub const SubRange = struct {
        start: ExtraIndex,
        end: ExtraIndex,
    };

    pub const Function = struct {
        params_start: ExtraIndex,
        body_start: ExtraIndex,
        body_end: ExtraIndex,
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
    return tree.tokensToSpan(
        tree.firstToken(node),
        tree.lastToken(node),
        if (tree.nodeTag(node) == .call) tree.firstToken(node) else tree.nodeMainToken(node),
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
    return .{ .start = start_off, .end = end_off, .main = tree.tokenStart(main) };
}

fn testFirstLast(source: [:0]const u8, node: Node.Index, expected_tag: Node.Tag) !void {
    const gpa = std.testing.allocator;
    var orig_tree: Ast = try .parse(gpa, source);
    defer orig_tree.deinit(gpa);
    var tree = try orig_tree.normalize(gpa);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(expected_tag, tree.nodeTag(node));

    try std.testing.expectEqualStrings(source[0..1], tree.tokenSlice(tree.firstToken(node)));
    try std.testing.expectEqualStrings(source[source.len - 1 ..], tree.tokenSlice(tree.lastToken(node)));
    try std.testing.expectEqualStrings(source, tree.nodeSlice(node));
}

test "first/last token call" {
    try testFirstLast("f[]", @enumFromInt(1), .call);

    try testFirstLast("f[x]", @enumFromInt(1), .call);

    try testFirstLast("f[x;y]", @enumFromInt(1), .call);
    try testFirstLast("f[x; ]", @enumFromInt(1), .call);
    try testFirstLast("f[ ;y]", @enumFromInt(1), .call);
    try testFirstLast("f[ ; ]", @enumFromInt(1), .call);
}

test "first/last token list" {
    try testFirstLast("(x;y)", @enumFromInt(1), .list);
    try testFirstLast("(x; )", @enumFromInt(1), .list);
    try testFirstLast("( ;y)", @enumFromInt(1), .list);
    try testFirstLast("( ; )", @enumFromInt(1), .list);
    try testFirstLast("(x;y)", @enumFromInt(1), .list);
    try testFirstLast("(x; )", @enumFromInt(1), .list);
    try testFirstLast("( ;y)", @enumFromInt(1), .list);
    try testFirstLast("( ; )", @enumFromInt(1), .list);

    try testFirstLast("(x;y;z)", @enumFromInt(1), .list);
    try testFirstLast("(x;y; )", @enumFromInt(1), .list);
    try testFirstLast("(x; ;z)", @enumFromInt(1), .list);
    try testFirstLast("(x; ; )", @enumFromInt(1), .list);
    try testFirstLast("( ;y;z)", @enumFromInt(1), .list);
    try testFirstLast("( ;y; )", @enumFromInt(1), .list);
    try testFirstLast("( ; ;z)", @enumFromInt(1), .list);
    try testFirstLast("( ; ; )", @enumFromInt(1), .list);
}
