const Token = @import("token.zig");
const TokenType = @import("token.zig").TokenType;

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
    _ = c;
    return self.makeToken(.identifier);
}

fn isAtEnd(self: Self) bool {
    return self.current >= self.source.len;
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

fn makeToken(self: Self, token_type: TokenType) Token {
    return .{
        .token_type = token_type,
        .lexeme = self.getSlice(),
        .line = self.start_line,
        .column = self.start_column,
    };
}

fn getSlice(self: Self) []const u8 {
    return self.source[self.start..self.current];
}
