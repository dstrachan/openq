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
    if (isDigit(c)) return self.number();
    if (isAlpha(c)) return self.identifier();
    return self.makeToken(.identifier);
}

fn number(self: *Self) Token {
    while (!self.isAtEnd()) {
        if (!isDigit(self.peek())) break;
        _ = self.advance();
    }
    return self.makeToken(.long);
}

fn identifier(self: *Self) Token {
    while (!self.isAtEnd()) {
        if (!isAlphaNum(self.peek())) break;
        _ = self.advance();
    }
    return self.makeToken(.identifier);
}

fn isAtEnd(self: Self) bool {
    return self.current >= self.source.len;
}

fn peek(self: Self) u8 {
    return self.source[self.current];
}

fn advance(self: *Self) u8 {
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

fn isAlpha(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        else => false,
    };
}

fn isAlphaNum(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        else => false,
    };
}
