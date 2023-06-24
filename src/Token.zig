const std = @import("std");

const Self = @This();

token_type: TokenType,
lexeme: []const u8,
line: usize,
column: usize,

pub const TokenType = enum {
    // Punctuation.
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    Semicolon,
    Colon,
    DoubleColon,
    Whitespace,

    // Verbs.
    Plus,
    PlusColon,
    Minus,
    MinusColon,
    Star,
    StarColon,
    Percent,
    PercentColon,
    Bang,
    BangColon,
    Ampersand,
    AmpersandColon,
    Pipe,
    PipeColon,
    Less,
    LessColon,
    Greater,
    GreaterColon,
    Equal,
    EqualColon,
    Tilde,
    TildeColon,
    Comma,
    CommaColon,
    Caret,
    CaretColon,
    Hash,
    HashColon,
    Underscore,
    UnderscoreColon,
    Dollar,
    DollarColon,
    Question,
    QuestionColon,
    At,
    AtColon,
    Dot,
    DotColon,

    // Adverbs.
    Apostrophe,
    ApostropheColon,
    Slash,
    SlashColon,
    Backslash,
    BackslashColon,

    // Literals.
    Number,
    Char,
    CharList,
    Symbol,
    SymbolList,
    Identifier,

    Error,
    Eof,
};

pub fn format(value: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print(@typeName(Self) ++ "{{ .token_type = {s}, .lexeme = \"{s}\", .line = {d}, .column = {d} }}", .{
        @tagName(value.token_type),
        value.lexeme,
        value.line,
        value.column,
    });
}
