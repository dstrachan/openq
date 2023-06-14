const Token = @import("Token.zig");

const Self = @This();

source: []const u8,
current: usize,
start: usize,
start_line: usize,
start_column: usize,
end_line: usize,
end_column: usize,

pub fn init(source: []const u8) Self {
    return .{
        .source = source,
        .current = 0,
        .start = 0,
        .start_line = 0,
        .start_column = 0,
        .end_line = 0,
        .end_column = 0,
    };
}

pub fn nextToken(self: *Self) ?Token {
    if (self.isAtEnd()) return null;

    self.start = self.current;
    self.start_line = self.end_line;
    self.start_column = self.end_column;

    const c = self.advance();
    if (c == '.') {
        if (isDigit(self.peek())) {
            _ = self.advance();
            return self.number();
        }

        if (isIdentifierChar(self.peek())) {
            _ = self.advance();
            return self.identifier();
        }
    }
    if (isIdentifierStartingChar(c)) return self.identifier();
    if (isDigit(c)) return self.number();
    if (c == '-') {
        if (isDigit(self.peek())) {
            _ = self.advance();
            return self.number();
        } else if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();
            return self.number();
        }
    }

    return switch (c) {
        '(' => self.makeToken(.left_paren), // TODO: Needs matching paren
        ')' => self.makeToken(.right_paren),
        '{' => self.makeToken(.left_brace),
        '}' => self.makeToken(.right_brace),
        '[' => self.makeToken(.left_bracket),
        ']' => self.makeToken(.right_bracket),
        ';' => self.makeToken(.semicolon),
        ':' => self.makeToken(if (self.match(':')) .double_colon else .colon),
        '+' => self.makeToken(if (self.match(':')) .plus_colon else .plus),
        '-' => self.makeToken(if (self.match(':')) .minus_colon else .minus),
        '*' => self.makeToken(if (self.match(':')) .star_colon else .star),
        '%' => self.makeToken(if (self.match(':')) .percent_colon else .percent),
        '!' => self.makeToken(if (self.match(':')) .bang_colon else .bang),
        '&' => self.makeToken(if (self.match(':')) .ampersand_colon else .ampersand),
        '|' => self.makeToken(if (self.match(':')) .pipe_colon else .pipe),
        '<' => self.makeToken(if (self.match(':')) .less_colon else .less),
        '>' => self.makeToken(if (self.match(':')) .greater_colon else .greater),
        '=' => self.makeToken(if (self.match(':')) .equal_colon else .equal),
        '~' => self.makeToken(if (self.match(':')) .tilde_colon else .tilde),
        ',' => self.makeToken(if (self.match(':')) .comma_colon else .comma),
        '^' => self.makeToken(if (self.match(':')) .caret_colon else .caret),
        '#' => self.makeToken(if (self.match(':')) .hash_colon else .hash),
        '_' => self.makeToken(if (self.match(':')) .underscore_colon else .underscore),
        '$' => self.makeToken(if (self.match(':')) .dollar_colon else .dollar),
        '?' => self.makeToken(if (self.match(':')) .question_colon else .question),
        '@' => self.makeToken(if (self.match(':')) .at_colon else .at),
        '.' => self.makeToken(if (self.match(':')) .dot_colon else .dot),
        '\'' => self.makeToken(if (self.match(':')) .apostrophe_colon else .apostrophe),
        '/' => self.makeToken(if (self.match(':')) .forward_slash_colon else .forward_slash),
        '\\' => self.makeToken(if (self.match(':')) .back_slash_colon else .back_slash),
        '"' => self.string(),
        '`' => self.symbol(),
        else => self.makeToken(.invalid),
    };
}

fn number(self: *Self) Token {
    while (isNumberChar(self.peek())) _ = self.advance();

    return self.makeToken(.number);
}

fn identifier(self: *Self) Token {
    while (isIdentifierChar(self.peek())) _ = self.advance();

    return self.makeToken(.identifier);
}

fn string(self: *Self) Token {
    var len: usize = 0;
    var c = self.peek();
    while (c != 0 and c != '"') : (c = self.peek()) {
        if (c == '\\') {
            _ = self.advance();
            if (isDigit(self.peek())) {
                if (!isOctalDigit(self.advance()) or !isOctalDigit(self.advance()) or !isOctalDigit(self.advance())) {
                    var error_c = self.peek();
                    while (error_c != 0 and error_c != '"') : (error_c = self.peek()) {
                        if (error_c == '\\') {
                            _ = self.advance();
                        }
                        _ = self.advance();
                    }

                    _ = self.advance();
                    return self.makeToken(.invalid);
                }
            } else {
                _ = self.advance();
            }
        } else {
            _ = self.advance();
        }
        len += 1;
    }

    if (c != '"') return self.makeToken(.invalid);

    _ = self.advance();
    return self.makeToken(switch (len) {
        1 => .char,
        else => .char_list,
    });
}

fn symbol(self: *Self) Token {
    var len: usize = 1;
    var c: u8 = self.peek();
    while (c == '`') : (c = self.peek()) {
        _ = self.advance();
        len += 1;
    }
    while (c != 0 and !isWhitespace(c) and isSymbolStartingChar(c)) : (c = self.peek()) {
        _ = self.advance();
        if (c == ':') {
            while (isSymbolHandleChar(self.peek())) _ = self.advance();
        } else {
            while (isSymbolChar(self.peek())) _ = self.advance();
        }

        while (self.peek() == '`') {
            _ = self.advance();
            len += 1;
        }
    }

    return self.makeToken(if (len > 1) .symbol_list else .symbol);
}

fn symbolHandle(self: *Self) Token {
    while (isSymbolHandleChar(self.peek())) _ = self.advance();

    return self.makeToken(.symbol);
}

fn isAtEnd(self: Self) bool {
    return self.current >= self.source.len;
}

fn peek(self: Self) u8 {
    return if (self.isAtEnd()) 0 else self.source[self.current];
}

fn peekNext(self: Self) u8 {
    return if (self.current >= self.source.len - 1) 0 else self.source[self.current + 1];
}

fn advance(self: *Self) u8 {
    const c = self.peek();
    if (c == 0) return c;

    if (c == '\n') {
        self.end_line += 1;
        self.end_column = 0;
    } else {
        self.end_column += 1;
    }
    self.current += 1;
    return c;
}

fn match(self: *Self, c: u8) bool {
    if (self.peek() == c) {
        _ = self.advance();
        while (self.peek() == c) _ = self.advance();
        return true;
    }
    return false;
}

fn makeToken(self: Self, token_type: Token.TokenType) Token {
    return self.token(token_type, self.getSlice());
}

fn token(self: Self, token_type: Token.TokenType, lexeme: []const u8) Token {
    return .{
        .token_type = token_type,
        .lexeme = lexeme,
        .line = self.start_line,
        .column = self.start_column,
    };
}

fn getSlice(self: Self) []const u8 {
    return self.source[self.start..self.current];
}

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

fn isNumberChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':' => true,
        else => false,
    };
}

fn isOctalDigit(c: u8) bool {
    return switch (c) {
        '0'...'7' => true,
        else => false,
    };
}

fn isIdentifierStartingChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        else => false,
    };
}

fn isIdentifierChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_' => true,
        else => false,
    };
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

fn isSymbolStartingChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':' => true,
        else => false,
    };
}

fn isSymbolChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':', '_' => true,
        else => false,
    };
}

fn isSymbolHandleChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', ':', '_', '/' => true,
        else => false,
    };
}
