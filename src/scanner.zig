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
    if (isAlpha(c)) return self.identifier();
    if (isDigit(c)) return self.number(c);
    if (c == '-') return self.negativeNumber();
    return self.makeToken(.identifier);
}

fn number(self: *Self, c: u8) Token {
    if (c == '0') {
        const next_c = self.peek();
        switch (next_c) {
            'x' => {
                _ = self.advance();
                return self.byte();
            },
            'n', 'N' => {
                _ = self.advance();
                return self.nullNumber(next_c);
            },
            'w', 'W' => {
                _ = self.advance();
                return self.infinity(next_c);
            },
            else => {},
        }
    }
    if (c <= '1') return self.boolean();

    while (!self.isAtEnd()) {
        if (!isDigit(self.peek())) break;
        _ = self.advance();
    }

    const next_c = self.peek();
    if (next_c == 'h') {
        _ = self.advance();
        return self.makeToken(.short);
    }

    return self.makeToken(.long);
}

fn negativeNumber(self: *Self) Token {
    while (!self.isAtEnd()) {
        if (!isDigit(self.peek())) break;
        _ = self.advance();
    }

    var next_c = self.peek();
    switch (next_c) {
        'w', 'W' => {
            _ = self.advance();
            return self.infinity(next_c);
        },
        else => {},
    }

    next_c = self.peek();
    if (next_c == 'h') {
        _ = self.advance();
        return self.makeToken(.short);
    }

    return self.makeToken(.long);
}

fn boolean(self: *Self) Token {
    while (!self.isAtEnd()) {
        const c = self.peek();
        if (isDigit(c)) {
            _ = self.advance();
            if (c > '1') return self.nonBooleanNumber();
        } else if (c == 'b') {
            _ = self.advance();
            return self.makeToken(if (self.current - self.start > 2) .boolean_list else .boolean);
        } else if (c == 'h') {
            _ = self.advance();
            return self.makeToken(.short);
        } else {
            break;
        }
    }
    return self.nonBooleanNumber();
}

fn byte(self: *Self) Token {
    while (!self.isAtEnd()) {
        const c = self.peek();
        if (isHexDigit(c)) {
            _ = self.advance();
        } else {
            break;
        }
    }
    const len = self.current - self.start;
    return self.makeToken(switch (len) {
        3, 4 => .byte,
        else => .byte_list,
    });
}

fn nullNumber(self: *Self, c: u8) Token {
    _ = c;
    const next_c = self.peek();
    return switch (next_c) {
        'g' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.guid);
        },
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        else => self.makeToken(.long),
    };
}

fn infinity(self: *Self, c: u8) Token {
    _ = c;
    const next_c = self.peek();
    return switch (next_c) {
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        else => self.makeToken(.long),
    };
}

fn nonBooleanNumber(self: *Self) Token {
    return self.makeToken(.long);
}

fn nonByteNumber(self: *Self) Token {
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

fn isHexDigit(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
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

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}
