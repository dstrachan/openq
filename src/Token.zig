const std = @import("std");

const Self = @This();

token_type: TokenType,
lexeme: []const u8,
line: usize,
column: usize,

pub const TokenType = enum {
    // Punctuation.
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    semicolon,
    colon,
    double_colon,
    whitespace,

    // Verbs.
    plus,
    plus_colon,
    minus,
    minus_colon,
    star,
    star_colon,
    percent,
    percent_colon,
    bang,
    bang_colon,
    ampersand,
    ampersand_colon,
    pipe,
    pipe_colon,
    less,
    less_colon,
    greater,
    greater_colon,
    equal,
    equal_colon,
    tilde,
    tilde_colon,
    comma,
    comma_colon,
    caret,
    caret_colon,
    hash,
    hash_colon,
    underscore,
    underscore_colon,
    dollar,
    dollar_colon,
    question,
    question_colon,
    at,
    at_colon,
    dot,
    dot_colon,

    // Adverbs.
    apostrophe,
    apostrophe_colon,
    forward_slash,
    forward_slash_colon,
    back_slash,
    back_slash_colon,

    // Literals.
    number,
    char,
    char_list,
    symbol,
    symbol_list,
    identifier,

    invalid,
    eof,
};

pub fn format(value: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print(@typeName(Self) ++ "{{ .token_type = {s}, .lexeme = \"{s}\", .line = {d}, .column = {d} }}", .{
        @tagName(value.token_type),
        value.lexeme,
        value.line,
        value.column,
    });
}
