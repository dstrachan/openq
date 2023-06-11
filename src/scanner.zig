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
    if (c == '-') {
        if (isDigit(self.peek())) {
            return self.negativeNumber(self.advance());
        } else if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();
            return self.realOrFloat();
        }
    }
    if (c == '.' and isDigit(self.peek())) {
        _ = self.advance();
        return self.realOrFloat();
    }
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
    if (c <= '1') return self.maybeBoolean();

    while (isDigit(self.peek())) _ = self.advance();

    return switch (self.peek()) {
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        'i' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.int);
        },
        'j' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.long);
        },
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        '.' => blk: {
            _ = self.advance();
            break :blk self.realOrFloat();
        },
        else => self.makeToken(.long),
    };
}

fn negativeNumber(self: *Self, c: u8) Token {
    if (c == '0') {
        const next_c = self.peek();
        switch (next_c) {
            'w', 'W' => {
                _ = self.advance();
                return self.infinity(next_c);
            },
            else => {},
        }
    }

    while (isDigit(self.peek())) _ = self.advance();

    return switch (self.peek()) {
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        'i' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.int);
        },
        'j' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.long);
        },
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        '.' => blk: {
            _ = self.advance();
            break :blk self.realOrFloat();
        },
        else => self.makeToken(.long),
    };
}

fn maybeBoolean(self: *Self) Token {
    while (isBooleanDigit(self.peek())) _ = self.advance();

    return switch (self.peek()) {
        'b' => {
            _ = self.advance();
            return self.makeToken(if (self.current - self.start > 2) .boolean_list else .boolean);
        },
        '.' => {
            _ = self.advance();
            return self.realOrFloat();
        },
        else => self.nonBooleanNumber(),
    };
}

fn realOrFloat(self: *Self) Token {
    while (isDigit(self.peek())) _ = self.advance();

    return switch (self.peek()) {
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        else => self.makeToken(.float),
    };
}

fn byte(self: *Self) Token {
    while (isHexDigit(self.peek())) _ = self.advance();

    return self.makeToken(switch (self.current - self.start) {
        3, 4 => .byte,
        else => .byte_list,
    });
}

fn nullNumber(self: *Self, c: u8) Token {
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
        'i' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.int);
        },
        'j' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.long);
        },
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        else => self.makeToken(if (c == 'N') .long else .float),
    };
}

fn infinity(self: *Self, c: u8) Token {
    const next_c = self.peek();
    return switch (next_c) {
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        'i' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.int);
        },
        'j' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.long);
        },
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        else => self.makeToken(if (c == 'W') .long else .float),
    };
}

fn nonBooleanNumber(self: *Self) Token {
    while (isDigit(self.peek())) _ = self.advance();

    return switch (self.peek()) {
        'h' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.short);
        },
        'i' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.int);
        },
        'j' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.long);
        },
        'e' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.real);
        },
        'f' => blk: {
            _ = self.advance();
            break :blk self.makeToken(.float);
        },
        else => self.makeToken(.long),
    };
}

fn identifier(self: *Self) Token {
    while (isAlphaNum(self.peek())) _ = self.advance();

    return self.makeToken(.identifier);
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

fn isBooleanDigit(c: u8) bool {
    return switch (c) {
        '0', '1' => true,
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
