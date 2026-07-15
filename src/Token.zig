const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @This();

tag: Tag,
loc: Loc,

pub const Loc = struct {
    start: usize,
    end: usize,
};

pub const keywords: std.StaticStringMap(Tag) = .initComptime(.{
    .{ "select", .keyword_select },
    .{ "exec", .keyword_exec },
    .{ "update", .keyword_update },
    .{ "delete", .keyword_delete },
});

pub fn getKeyword(bytes: []const u8) ?Tag {
    return keywords.get(bytes);
}

pub const Tag = enum {
    // Punctuation
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    semicolon,

    // Operators
    bang,
    bang_colon,
    hash,
    hash_colon,
    dollar,
    dollar_colon,
    percent,
    percent_colon,
    ampersand,
    ampersand_colon,
    asterisk,
    asterisk_colon,
    plus,
    plus_colon,
    comma,
    comma_colon,
    minus,
    minus_colon,
    dot,
    dot_colon,
    colon,
    colon_colon,
    l_angle_bracket,
    l_angle_bracket_colon,
    equal,
    equal_colon,
    r_angle_bracket,
    r_angle_bracket_colon,
    question_mark,
    question_mark_colon,
    at,
    at_colon,
    caret,
    caret_colon,
    underscore,
    underscore_colon,
    pipe,
    pipe_colon,
    tilde,
    tilde_colon,
    zero_colon,
    zero_colon_colon,
    one_colon,
    one_colon_colon,
    two_colon,

    // Iterators
    apostrophe,
    apostrophe_colon,
    slash,
    slash_colon,
    backslash,
    backslash_colon,

    // Literals
    number_literal,
    string_literal,
    symbol_literal,
    identifier,

    // Misc.
    system,
    invalid,
    eos,
    eof,

    // Keywords,
    keyword_select,
    keyword_exec,
    keyword_update,
    keyword_delete,

    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .l_brace => "{",
            .r_brace => "}",
            .semicolon => ";",

            .bang => "!",
            .bang_colon => "!:",
            .hash => "#",
            .hash_colon => "#:",
            .dollar => "$",
            .dollar_colon => "$:",
            .percent => "%",
            .percent_colon => "%:",
            .ampersand => "&",
            .ampersand_colon => "&:",
            .asterisk => "*",
            .asterisk_colon => "*:",
            .plus => "+",
            .plus_colon => "+:",
            .comma => ",",
            .comma_colon => ",:",
            .minus => "-",
            .minus_colon => "-:",
            .dot => ".",
            .dot_colon => ".:",
            .colon => ":",
            .colon_colon => "::",
            .l_angle_bracket => "<",
            .l_angle_bracket_colon => "<:",
            .equal => "=",
            .equal_colon => "=:",
            .r_angle_bracket => ">",
            .r_angle_bracket_colon => ">:",
            .question_mark => "?",
            .question_mark_colon => "?:",
            .at => "@",
            .at_colon => "@:",
            .caret => "^",
            .caret_colon => "^:",
            .underscore => "_",
            .underscore_colon => "_:",
            .pipe => "|",
            .pipe_colon => "|:",
            .tilde => "~",
            .tilde_colon => "~:",
            .zero_colon => "0:",
            .zero_colon_colon => "0::",
            .one_colon => "1:",
            .one_colon_colon => "1::",
            .two_colon => "2:",

            .apostrophe => "'",
            .apostrophe_colon => "':",
            .slash => "/",
            .slash_colon => "/:",
            .backslash => "\\",
            .backslash_colon => "\\:",

            .number_literal,
            .string_literal,
            .symbol_literal,
            .identifier,
            => null,

            .system,
            .invalid,
            .eos,
            .eof,
            => null,

            .keyword_select => "select",
            .keyword_exec => "exec",
            .keyword_update => "update",
            .keyword_delete => "delete",
        };
    }

    pub fn symbol(tag: Tag) []const u8 {
        return tag.lexeme() orelse switch (tag) {
            .number_literal => "a number literal",
            .string_literal => "string literal",
            .symbol_literal => "symbol literal",
            .identifier => "identifier",
            .system => "system command",
            .invalid => "invalid token",
            .eos => "end of statement",
            .eof => "end of file",
            else => unreachable,
        };
    }

    pub fn isNextMinus(tag: Tag) bool {
        return switch (tag) {
            .r_paren,
            .r_bracket,
            .r_brace,
            .number_literal,
            .string_literal,
            .symbol_literal,
            .identifier,
            .eos,
            => true,
            else => false,
        };
    }
};

pub fn eos(index: usize) Token {
    return .{
        .tag = .eos,
        .loc = .{ .start = index, .end = index + 1 },
    };
}

pub fn eof(index: usize) Token {
    return .{
        .tag = .eof,
        .loc = .{ .start = index, .end = index },
    };
}
