const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Index = enum(u32) {
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(opt_index: OptionalIndex) ?Index {
            if (opt_index == .none) return null;
            return @enumFromInt(@intFromEnum(opt_index));
        }

        pub fn fromIndex(index: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(index));
        }

        pub fn fromOptional(opt_index: ?Index) OptionalIndex {
            return if (opt_index) |index| @enumFromInt(index) else .none;
        }
    };

    pub const Offset = enum(i32) {
        zero = 0,
        _,

        pub fn init(base: Index, destination: Index) Offset {
            const base_i64: i64 = @intFromEnum(base);
            const destination_i64: i64 = @intFromEnum(destination);
            return @enumFromInt(destination_i64 - base_i64);
        }

        pub fn toOptional(offset: Offset) OptionalOffset {
            const result: OptionalOffset = @enumFromInt(@intFromEnum(offset));
            assert(result != .none);
            return result;
        }

        pub fn toAbsolute(offset: Offset, base: Index) Index {
            return @enumFromInt(@intFromEnum(base) + @intFromEnum(offset));
        }
    };

    pub const OptionalOffset = enum(i32) {
        none = std.math.maxInt(i32),
        _,

        pub fn unwrap(opt_offset: OptionalOffset) ?Offset {
            return if (opt_offset == .none) null else @enumFromInt(@intFromEnum(opt_offset));
        }
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        bang,
        hash,
        dollar,
        percent,
        ampersand,
        apostrophe,
        l_paren,
        r_paren,
        asterisk,
        plus,
        comma,
        minus,
        dot,
        slash,
        colon,
        semicolon,
        l_angle_bracket,
        equal,
        r_angle_bracket,
        question_mark,
        at,
        l_bracket,
        backslash,
        r_bracket,
        caret,
        underscore,
        l_brace,
        pipe,
        r_brace,
        tilde,

        string_literal,
        symbol_literal,
        number_literal,
        identifier,
        system,
        invalid,
        eof,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .bang => "!",
                .hash => "#",
                .dollar => "$",
                .percent => "%",
                .ampersand => "&",
                .apostrophe => "'",
                .l_paren => "(",
                .r_paren => ")",
                .asterisk => "*",
                .plus => "+",
                .comma => ",",
                .minus => "-",
                .dot => ".",
                .slash => "/",
                .colon => ":",
                .semicolon => ";",
                .l_angle_bracket => "<",
                .equal => "=",
                .r_angle_bracket => ">",
                .question_mark => "?",
                .at => "@",
                .l_bracket => "[",
                .backslash => "\\",
                .r_bracket => "]",
                .caret => "^",
                .underscore => "_",
                .l_brace => "{",
                .pipe => "|",
                .r_brace => "}",
                .tilde => "~",

                .string_literal,
                .symbol_literal,
                .number_literal,
                .identifier,
                .system,
                .invalid,
                .eof,
                => null,
            };
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{});

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    fn eof(index: usize) Token {
        return .{
            .tag = .eof,
            .loc = .{
                .start = index,
                .end = index,
            },
        };
    }
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present.
        return .{
            .buffer = buffer,
            .index = if (mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
        };
    }

    const SkipState = enum {
        start,
        skip_line,
        comment,
        block_comment,
        maybe_block_comment_end,
        block_comment_end,
    };

    pub fn skipComments(self: *Tokenizer) void {
        state: switch (SkipState.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {},
                '\r' => if (self.buffer[self.index + 1] == '\n') {
                    self.index += 2;
                    continue :state .start;
                },
                '\n' => {
                    self.index += 1;
                    continue :state .start;
                },
                ' ', '\t' => continue :state .skip_line,
                '/' => continue :state .comment,
                else => {},
            },

            .skip_line => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {},
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
                        continue :state .start;
                    },
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
                    else => continue :state .skip_line,
                }
            },

            .comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {},
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .block_comment;
                    },
                    '\n' => continue :state .block_comment,
                    ' ', '\t' => continue :state .comment,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
                    else => continue :state .skip_line,
                }
            },
            .block_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {},
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .maybe_block_comment_end;
                    },
                    '\n' => continue :state .maybe_block_comment_end,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
                    else => continue :state .block_comment,
                }
            },
            .maybe_block_comment_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {},
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .maybe_block_comment_end;
                    },
                    '\n' => continue :state .maybe_block_comment_end,
                    '\\' => continue :state .block_comment_end,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
                    else => continue :state .block_comment,
                }
            },
            .block_comment_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {},
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
                        continue :state .start;
                    },
                    ' ', '\t' => continue :state .block_comment_end,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {},
                    else => continue :state .block_comment,
                }
            },
        }
    }

    const State = enum {
        start,
        invalid,
        string_literal,
        string_literal_newline,
        string_literal_backslash,
        octal_char_two,
        octal_char_three,
        symbol_literal_start,
        symbol_literal,
        file_handle,
        number_literal,
        identifier,
        dot,
        slash,
        block_comment_start,
        block_comment,
        maybe_block_comment_end,
        block_comment_end,
        trailing_comment,
        maybe_system,
        skip_line,
        system,
    };

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => if (self.index != self.buffer.len) {
                    continue :state .invalid;
                } else return .eof(self.buffer.len),
                '\r' => if (self.buffer[self.index + 1] == '\n') {
                    self.index += 2;
                    result.loc.start = self.index;
                    continue :state .start;
                } else continue :state .invalid,
                ' ', '\n', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                '`' => {
                    result.tag = .symbol_literal;
                    continue :state .symbol_literal;
                },
                '0'...'9' => {
                    result.tag = .number_literal;
                    continue :state .number_literal;
                },
                'a'...'z', 'A'...'Z' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '!' => {
                    result.tag = .bang;
                    self.index += 1;
                },
                '#' => {
                    result.tag = .hash;
                    self.index += 1;
                },
                '$' => {
                    result.tag = .dollar;
                    self.index += 1;
                },
                '%' => {
                    result.tag = .percent;
                    self.index += 1;
                },
                '&' => {
                    result.tag = .ampersand;
                    self.index += 1;
                },
                '\'' => {
                    result.tag = .apostrophe;
                    self.index += 1;
                },
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '*' => {
                    result.tag = .asterisk;
                    self.index += 1;
                },
                '+' => {
                    result.tag = .plus;
                    self.index += 1;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                '-' => {
                    result.tag = .minus;
                    self.index += 1;
                },
                '.' => {
                    result.tag = .dot;
                    continue :state .dot;
                },
                '/' => continue :state .slash,
                ':' => {
                    result.tag = .colon;
                    self.index += 1;
                },
                ';' => {
                    result.tag = .semicolon;
                    self.index += 1;
                },
                '<' => {
                    result.tag = .l_angle_bracket;
                    self.index += 1;
                },
                '=' => {
                    result.tag = .equal;
                    self.index += 1;
                },
                '>' => {
                    result.tag = .r_angle_bracket;
                    self.index += 1;
                },
                '?' => {
                    result.tag = .question_mark;
                    self.index += 1;
                },
                '@' => {
                    result.tag = .at;
                    self.index += 1;
                },
                '[' => {
                    result.tag = .l_bracket;
                    self.index += 1;
                },
                '\\' => if (self.index == 0 or self.buffer[self.index - 1] == '\n')
                    continue :state .maybe_system
                else {
                    result.tag = .backslash;
                    self.index += 1;
                },
                ']' => {
                    result.tag = .r_bracket;
                    self.index += 1;
                },
                '^' => {
                    result.tag = .caret;
                    self.index += 1;
                },
                '_' => {
                    result.tag = .underscore;
                    self.index += 1;
                },
                '{' => {
                    result.tag = .l_brace;
                    self.index += 1;
                },
                '|' => {
                    result.tag = .pipe;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .r_brace;
                    self.index += 1;
                },
                '~' => {
                    result.tag = .tilde;
                    self.index += 1;
                },
                else => continue :state .invalid,
            },

            .string_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .string_literal_newline;
                    } else continue :state .invalid,
                    '\n' => continue :state .string_literal_newline,
                    '\\' => continue :state .string_literal_backslash,
                    '"' => self.index += 1,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .string_literal,
                }
            },
            .string_literal_newline => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .string_literal_newline;
                    } else continue :state .invalid,
                    '\n' => continue :state .string_literal_newline,
                    ' ', '\t' => continue :state .string_literal,
                    else => continue :state .invalid,
                }
            },
            .string_literal_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '"', '\\', 'n', 'r', 't' => continue :state .string_literal,
                    '0'...'9' => continue :state .octal_char_two,
                    else => continue :state .invalid,
                }
            },
            .octal_char_two => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '0'...'9' => continue :state .octal_char_three,
                    else => continue :state .invalid,
                }
            },
            .octal_char_three => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '0'...'9' => continue :state .string_literal,
                    else => continue :state .invalid,
                }
            },

            .symbol_literal_start => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '.' => continue :state .symbol_literal,
                    ':' => continue :state .file_handle,
                    else => {},
                }
            },
            .symbol_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '.', '_' => continue :state .symbol_literal,
                    ':' => continue :state .file_handle,
                    else => {},
                }
            },
            .file_handle => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '.', '/', ':', '_' => continue :state .file_handle,
                    else => {},
                }
            },

            .number_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '.', ':' => continue :state .number_literal,
                    else => {},
                }
            },

            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '.', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        const ident = self.buffer[result.loc.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .dot => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z' => {
                        result.tag = .identifier;
                        continue :state .identifier;
                    },
                    '0'...'9' => {
                        result.tag = .number_literal;
                        continue :state .number_literal;
                    },
                    else => {},
                }
            },

            .slash => if (self.index != 0) switch (self.buffer[self.index - 1]) {
                '\n' => continue :state .block_comment_start,
                ' ', '\t' => continue :state .skip_line,
                else => {
                    result.tag = .slash;
                    self.index += 1;
                },
            } else continue :state .block_comment_start,

            .block_comment_start => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    ' ', '\t' => continue :state .block_comment_start,
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .block_comment;
                    } else continue :state .invalid,
                    '\n' => continue :state .block_comment,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .skip_line,
                }
            },
            .block_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .maybe_block_comment_end;
                    } else continue :state .invalid,
                    '\n' => continue :state .maybe_block_comment_end,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .block_comment,
                }
            },
            .maybe_block_comment_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 1;
                        continue :state .maybe_block_comment_end;
                    } else continue :state .invalid,
                    '\n' => continue :state .maybe_block_comment_end,
                    '\\' => continue :state .block_comment_end,
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .block_comment,
                }
            },
            .block_comment_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    ' ', '\t' => continue :state .block_comment_end,
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        result.loc.start = self.index;
                        continue :state .start;
                    } else continue :state .invalid,
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .block_comment,
                }
            },
            .trailing_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    ' ', '\t' => continue :state .trailing_comment,
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\n' => return .eof(self.buffer.len),
                    else => continue :state .invalid,
                }
            },

            .maybe_system => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    ' ', '\t' => continue :state .trailing_comment,
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\n' => return .eof(self.buffer.len),
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => {
                        result.tag = .system;
                        continue :state .system;
                    },
                }
            },
            .system => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    },
                    '\r' => if (self.buffer[self.index + 1] != '\n') continue :state .invalid,
                    '\n' => {},
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .system,
                }
            },

            .skip_line => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\r' => if (self.buffer[self.index + 1] == '\n') {
                        self.index += 2;
                        result.loc.start = self.index;
                        continue :state .start;
                    } else continue :state .invalid,
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .skip_line,
                }
            },

            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else continue :state .invalid,
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

fn testTokenize(source: [:0]const u8, expected_values: []const struct { Token.Tag, []const u8 }) !void {
    const gpa = std.testing.allocator;
    const T = @typeInfo(@TypeOf(expected_values)).pointer.child;

    var actual: std.MultiArrayList(T) = .empty;
    defer actual.deinit(gpa);

    var tokenizer: Tokenizer = .init(source);
    tokenizer.skipComments();
    while (true) {
        const token = tokenizer.next();
        try actual.append(gpa, .{ token.tag, source[token.loc.start..token.loc.end] });
        if (token.tag == .eof) break;
    }

    var expected: std.MultiArrayList(T) = .empty;
    defer expected.deinit(gpa);
    try expected.ensureUnusedCapacity(gpa, expected_values.len + 1);
    for (expected_values) |e| expected.appendAssumeCapacity(e);
    expected.appendAssumeCapacity(.{ .eof, "" });

    inline for (@typeInfo(std.meta.FieldEnum(T)).@"enum".fields) |field| {
        try std.testing.expectEqualDeep(
            expected.items(@enumFromInt(field.value)),
            actual.items(@enumFromInt(field.value)),
        );
    }
}

// TODO: Unit tests
test {
    try testTokenize("this is a test", &.{
        .{ .identifier, "this" },
        .{ .identifier, "is" },
        .{ .identifier, "a" },
        .{ .identifier, "test" },
    });
}

test "tokenize symbols" {
    try testTokenize("`", &.{.{ .symbol_literal, "`" }});
    try testTokenize("`a", &.{.{ .symbol_literal, "`a" }});
    try testTokenize("`symbol", &.{.{ .symbol_literal, "`symbol" }});
    try testTokenize("`1", &.{.{ .symbol_literal, "`1" }});
    try testTokenize("`UPPERCASE", &.{.{ .symbol_literal, "`UPPERCASE" }});
    try testTokenize("`symbol.with.dot", &.{.{ .symbol_literal, "`symbol.with.dot" }});
    try testTokenize("`.symbol.with.leading.dot", &.{.{ .symbol_literal, "`.symbol.with.leading.dot" }});
    try testTokenize("`symbol/with/slash", &.{
        .{ .symbol_literal, "`symbol" },
        .{ .slash, "/" },
        .{ .identifier, "with" },
        .{ .slash, "/" },
        .{ .identifier, "slash" },
    });
    try testTokenize("`:handle/with/slash", &.{.{ .symbol_literal, "`:handle/with/slash" }});
    try testTokenize("`symbol:with/slash/after/colon", &.{.{ .symbol_literal, "`symbol:with/slash/after/colon" }});
    try testTokenize("`symbol/with/slash:before/colon", &.{
        .{ .symbol_literal, "`symbol" },
        .{ .slash, "/" },
        .{ .identifier, "with" },
        .{ .slash, "/" },
        .{ .identifier, "slash" },
        .{ .colon, ":" },
        .{ .identifier, "before" },
        .{ .slash, "/" },
        .{ .identifier, "colon" },
    });
}

test "tokenize identifiers" {
    try testTokenize("a", &.{.{ .identifier, "a" }});
    try testTokenize("identifier", &.{.{ .identifier, "identifier" }});
    try testTokenize("test123", &.{.{ .identifier, "test123" }});
    try testTokenize("UPPERCASE", &.{.{ .identifier, "UPPERCASE" }});
    try testTokenize("identifier.with.dot", &.{.{ .identifier, "identifier.with.dot" }});
    try testTokenize("identifier.with.leading.dot", &.{.{ .identifier, "identifier.with.leading.dot" }});
    try testTokenize("identifier_with_underscore", &.{.{ .identifier, "identifier_with_underscore" }});
    try testTokenize("_identifier_with_leading_underscore", &.{
        .{ .underscore, "_" },
        .{ .identifier, "identifier_with_leading_underscore" },
    });
}

test "tokenize strings" {
    try testTokenize("\"this is a string\"", &.{.{ .string_literal, "\"this is a string\"" }});
    try testTokenize(
        \\"this is a string\"with\\embedded\nescape\rchars\t"
    , &.{.{
        .string_literal,
        \\"this is a string\"with\\embedded\nescape\rchars\t"
    }});
    try testTokenize("\"Zürich\"", &.{.{ .string_literal, "\"Zürich\"" }});
    try testTokenize(
        \\"this is \a string with bad ch\ars"
    , &.{.{
        .invalid,
        \\"this is \a string with bad ch\ars"
    }});
    const a = 'ü';
    _ = a; // autofix
    try testTokenize("\"\\012\"", &.{.{ .string_literal, "\"\\012\"" }});
    try testTokenize("\"\t\"", &.{.{ .string_literal, "\"\t\"" }});
    try testTokenize("\"\n \"", &.{.{ .string_literal, "\"\n \"" }});
    try testTokenize("\"\n\t\"", &.{.{ .string_literal, "\"\n\t\"" }});
    try testTokenize("\"\n\n \"", &.{.{ .string_literal, "\"\n\n \"" }});
    try testTokenize("\"\n\"", &.{.{ .invalid, "\"\n\"" }});
    try testTokenize("\"\n\n\"", &.{.{ .invalid, "\"\n\n\"" }});
    try testTokenize("\"\r\n \"", &.{.{ .string_literal, "\"\r\n \"" }});
    try testTokenize("\"\r\"", &.{.{ .invalid, "\"\r\"" }});
    try testTokenize("\"\r\n\"", &.{.{ .invalid, "\"\r\n\"" }});
    try testTokenize("\"\r\na\"", &.{.{ .invalid, "\"\r\na\"" }});
}

test "tokenize numbers" {
    try testTokenize("1", &.{.{ .number_literal, "1" }});
    try testTokenize("1i", &.{.{ .number_literal, "1i" }});
    try testTokenize("1abc", &.{.{ .number_literal, "1abc" }});
    try testTokenize("123", &.{.{ .number_literal, "123" }});
    try testTokenize("123i", &.{.{ .number_literal, "123i" }});
    try testTokenize("123abc", &.{.{ .number_literal, "123abc" }});
    try testTokenize("0D123:456:789.1234abc", &.{.{ .number_literal, "0D123:456:789.1234abc" }});
    try testTokenize("0.1", &.{.{ .number_literal, "0.1" }});
    try testTokenize(".1", &.{.{ .number_literal, ".1" }});
    try testTokenize("-1", &.{ .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("-1i", &.{ .{ .minus, "-" }, .{ .number_literal, "1i" } });
    try testTokenize("-1abc", &.{ .{ .minus, "-" }, .{ .number_literal, "1abc" } });
    try testTokenize("-123", &.{ .{ .minus, "-" }, .{ .number_literal, "123" } });
    try testTokenize("-123i", &.{ .{ .minus, "-" }, .{ .number_literal, "123i" } });
    try testTokenize("-123abc", &.{ .{ .minus, "-" }, .{ .number_literal, "123abc" } });
    try testTokenize("-0D123:456:789.1234abc", &.{ .{ .minus, "-" }, .{ .number_literal, "0D123:456:789.1234abc" } });
    try testTokenize("-0.1", &.{ .{ .minus, "-" }, .{ .number_literal, "0.1" } });
    try testTokenize("-.1", &.{ .{ .minus, "-" }, .{ .number_literal, ".1" } });
}

test "tokenize starting comment" {
    try testTokenize(
        \\ this is a starting
        \\ comment that spans
        \\ multiple lines
        \\/ and has some comments
        \\/
        \\inside.
        \\\
        \\ it also continues after
        \\ some comments and ends
        \\here
    , &.{.{ .identifier, "here" }});
    try testTokenize(
        \\ this is a starting
        \\ comment that spans
        \\ multiple lines
        \\\
        \\trailing comment
    , &.{});
    try testTokenize(
        \\ this is a starting
        \\ comment that spans
        \\ multiple lines
        \\\system
        \\not a trailing comment
    , &.{
        .{ .system, "\\system" },
        .{ .identifier, "not" },
        .{ .identifier, "a" },
        .{ .identifier, "trailing" },
        .{ .identifier, "comment" },
    });
    try testTokenize(
        \\ this is a starting
        \\ comment that spans
        \\ multiple lines
        \\\d .
        \\identifier
    , &.{ .{ .system, "\\d ." }, .{ .identifier, "identifier" } });
    try testTokenize(
        \\ this is a starting
        \\ comment that spans
        \\ multiple lines
        \\\ d .
        \\identifier
    , &.{ .{ .invalid, "\\ d ." }, .{ .identifier, "identifier" } });
}

test "tokenize line comment" {
    try testTokenize("/line comment", &.{});
    try testTokenize("1 /line comment", &.{.{ .number_literal, "1" }});
    try testTokenize("1 / line comment", &.{.{ .number_literal, "1" }});
    try testTokenize("1/not a line comment", &.{
        .{ .number_literal, "1" },
        .{ .slash, "/" },
        .{ .identifier, "not" },
        .{ .identifier, "a" },
        .{ .identifier, "line" },
        .{ .identifier, "comment" },
    });
    try testTokenize("1/ not a line comment", &.{
        .{ .number_literal, "1" },
        .{ .slash, "/" },
        .{ .identifier, "not" },
        .{ .identifier, "a" },
        .{ .identifier, "line" },
        .{ .identifier, "comment" },
    });
    try testTokenize(
        "1 /:line comment",
        &.{.{ .number_literal, "1" }},
    );
    try testTokenize(
        \\1 /line comment 1
        \\/line comment 2
        \\2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\1 /line comment 1
        \\ /line comment 2
        \\2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\1 /line comment 1
        \\/line comment 2
        \\ 2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\1 /line comment 1
        \\ /line comment 2
        \\ 2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\(1; /line comment 1
        \\/line comment 2
        \\2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
    try testTokenize(
        \\(1; /line comment 1
        \\ /line comment 2
        \\2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
    try testTokenize(
        \\(1; /line comment 1
        \\/line comment 2
        \\ 2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
    try testTokenize(
        \\(1; /line comment 1
        \\ /line comment 2
        \\ 2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
}

test "tokenize block comment" {
    try testTokenize(
        \\1
        \\/
        \\block comment 1
        \\\
        \\/
        \\block comment 2
        \\\
        \\2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\1
        \\/
        \\block comment 1
        \\\
        \\/
        \\block comment 2
        \\\
        \\ 2
    , &.{ .{ .number_literal, "1" }, .{ .number_literal, "2" } });
    try testTokenize(
        \\(1;
        \\/
        \\block comment 1
        \\\
        \\/
        \\block comment 2
        \\\
        \\2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
    try testTokenize(
        \\(1;
        \\/
        \\block comment 1
        \\\
        \\/
        \\block comment 2
        \\\
        \\ 2)
    , &.{
        .{ .l_paren, "(" },
        .{ .number_literal, "1" },
        .{ .semicolon, ";" },
        .{ .number_literal, "2" },
        .{ .r_paren, ")" },
    });
}

test "tokenize trailing comment" {
    try testTokenize(
        \\1
        \\\
        \\this is a
        \\trailing comment
    , &.{.{ .number_literal, "1" }});
    try testTokenize(
        \\1
        \\\ this is not a trailing comment
        \\2
    , &.{
        .{ .number_literal, "1" },
        .{ .invalid, "\\ this is not a trailing comment" },
        .{ .number_literal, "2" },
    });
}
