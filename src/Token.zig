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
    guid_list,
    byte,
    byte_list,
    short,
    short_list,
    int,
    int_list,
    long,
    long_list,
    real,
    real_list,
    float,
    float_list,
    char,
    char_list,
    symbol,
    symbol_list,
    timestamp,
    timestamp_list,
    month,
    month_list,
    date,
    date_list,
    datetime,
    datetime_list,
    timespan,
    timespan_list,
    minute,
    minute_list,
    second,
    second_list,
    time,
    time_list,
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
