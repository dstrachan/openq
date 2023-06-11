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
    minus,
    star,
    percent,
    bang,
    ampersand,
    pipe,
    less,
    greater,
    equal,
    tilde,
    comma,
    caret,
    hash,
    underscore,
    dollar,
    question,
    at,
    dot,

    // Literals.
    boolean,
    boolean_list,
    guid,
    byte,
    byte_list,
    short,
    int,
    long,
    real,
    float,
    char,
    symbol,
    timestamp,
    month,
    date,
    datetime,
    timespan,
    minute,
    second,
    time,
    identifier,

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
