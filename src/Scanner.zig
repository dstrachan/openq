const std = @import("std");

const Token = @import("Token.zig");
const TokenType = Token.TokenType;

const Self = @This();

source: []const u8,
current: usize = 0,
start: usize = 0,
start_line: usize = 0,
start_column: usize = 0,
end_line: usize = 0,
end_column: usize = 0,

pub fn init(source: []const u8) Self {
    return .{
        .source = source,
    };
}

pub fn scanToken(self: *Self) Token {
    self.start = self.current;
    self.start_line = self.end_line;
    self.start_column = self.end_column;

    if (self.isAtEnd()) return self.makeToken(.Eof);

    const c = self.advance();
    if (isWhitespace(c)) return self.whitespace();
    if (c == '.') {
        if (isDigit(self.peek())) {
            _ = self.advance();
            return self.number();
        }

        if (isIdentifierStartingChar(self.peek())) {
            _ = self.advance();
            return self.identifier();
        }
    }
    if (isIdentifierStartingChar(c)) return self.identifier();
    if (isDigit(c)) return self.number();
    if (c == '-' and (isDigit(self.peek()) or (self.peek() == '.' and isDigit(self.peekNext())))) {
        _ = self.advance();
        return self.number();
    }

    return switch (c) {
        '(' => self.makeToken(.LeftParen),
        ')' => self.makeToken(.RightParen),
        '{' => self.makeToken(.LeftBrace),
        '}' => self.makeToken(.RightBrace),
        '[' => self.makeToken(.LeftBracket),
        ']' => self.makeToken(.RightBracket),
        ';' => self.makeToken(.Semicolon),
        ':' => if (self.match(':')) self.makeToken(.DoubleColon) else self.makeToken(.Colon),
        '+' => if (self.match(':')) self.makeToken(.PlusColon) else self.makeToken(.Plus),
        '-' => if (self.match(':')) self.makeToken(.MinusColon) else self.makeToken(.Minus),
        '*' => if (self.match(':')) self.makeToken(.StarColon) else self.makeToken(.Star),
        '%' => if (self.match(':')) self.makeToken(.PercentColon) else self.makeToken(.Percent),
        '!' => if (self.match(':')) self.makeToken(.BangColon) else self.makeToken(.Bang),
        '&' => if (self.match(':')) self.makeToken(.AmpersandColon) else self.makeToken(.Ampersand),
        '|' => if (self.match(':')) self.makeToken(.PipeColon) else self.makeToken(.Pipe),
        '<' => if (self.match(':')) self.makeToken(.LessColon) else self.makeToken(.Less),
        '>' => if (self.match(':')) self.makeToken(.GreaterColon) else self.makeToken(.Greater),
        '=' => if (self.match(':')) self.makeToken(.EqualColon) else self.makeToken(.Equal),
        '~' => if (self.match(':')) self.makeToken(.TildeColon) else self.makeToken(.Tilde),
        ',' => if (self.match(':')) self.makeToken(.CommaColon) else self.makeToken(.Comma),
        '^' => if (self.match(':')) self.makeToken(.CaretColon) else self.makeToken(.Caret),
        '#' => if (self.match(':')) self.makeToken(.HashColon) else self.makeToken(.Hash),
        '_' => if (self.match(':')) self.makeToken(.UnderscoreColon) else self.makeToken(.Underscore),
        '$' => if (self.match(':')) self.makeToken(.DollarColon) else self.makeToken(.Dollar),
        '?' => if (self.match(':')) self.makeToken(.QuestionColon) else self.makeToken(.Question),
        '@' => if (self.match(':')) self.makeToken(.AtColon) else self.makeToken(.At),
        '.' => if (self.match(':')) self.makeToken(.DotColon) else self.makeToken(.Dot),
        '\'' => if (self.match(':')) self.makeToken(.ApostropheColon) else self.makeToken(.Apostrophe),
        '/' => if (self.match(':')) self.makeToken(.SlashColon) else self.makeToken(.Slash),
        '\\' => if (self.match(':')) self.makeToken(.BackslashColon) else self.makeToken(.Backslash),
        '"' => self.string(),
        '`' => self.symbol(),
        else => self.makeToken(.Error),
    };
}

fn whitespace(self: *Self) Token {
    while (isWhitespace(self.peek())) _ = self.advance();

    return self.makeToken(.Whitespace);
}

fn number(self: *Self) Token {
    while (isNumberChar(self.peek())) _ = self.advance();

    return self.makeToken(.Number);
}

fn identifier(self: *Self) Token {
    while (isIdentifierChar(self.peek())) _ = self.advance();

    return self.makeToken(.Identifier);
}

fn string(self: *Self) Token {
    var len: usize = 0;
    var c = self.peek();
    while (c != 0 and c != '"') : (c = self.peek()) {
        if (c == '\\') _ = self.advance();
        _ = self.advance();
        len += 1;
    }

    if (c != '"') return self.makeToken(.Error);

    _ = self.advance();
    return self.makeToken(if (len == 1) .Char else .CharList);
}

fn symbol(self: *Self) Token {
    var len: usize = 1;
    while (self.match('`')) len += 1;
    var c = self.peek();
    while (c != 0 and !isWhitespace(c) and isSymbolStartingChar(c)) : (c = self.peek()) {
        _ = self.advance();
        if (c == ':') {
            while (isSymbolHandleChar(self.peek())) _ = self.advance();
        } else {
            while (isSymbolChar(self.peek())) _ = self.advance();
        }

        while (self.match('`')) len += 1;
    }

    return self.makeToken(if (len == 1) .Symbol else .SymbolList);
}

fn isAtEnd(self: *Self) bool {
    return self.current >= self.source.len;
}

fn makeToken(self: *Self, token_type: TokenType) Token {
    return .{
        .token_type = token_type,
        .lexeme = self.source[self.start..self.current],
        .line = self.start_line,
        .column = self.start_column,
    };
}

fn advance(self: *Self) u8 {
    if (self.isAtEnd()) return 0;

    const c = self.source[self.current];
    if (c == '\n') {
        self.end_line += 1;
        self.end_column = 0;
    } else {
        self.end_column += 1;
    }
    self.current += 1;
    return c;
}

fn peek(self: *Self) u8 {
    return if (self.isAtEnd()) 0 else self.source[self.current];
}

fn peekNext(self: *Self) u8 {
    return if (self.current >= self.source.len - 1) 0 else self.source[self.current + 1];
}

fn match(self: *Self, c: u8) bool {
    if (self.peek() == c) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

fn isIdentifierStartingChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        else => false,
    };
}

fn isNumberChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':' => true,
        else => false,
    };
}

fn isIdentifierChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_' => true,
        else => false,
    };
}

fn isSymbolStartingChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':' => true,
        else => false,
    };
}

fn isSymbolHandleChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':', '_', '/' => true,
        else => false,
    };
}

fn isSymbolChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':', '_' => true,
        else => false,
    };
}
