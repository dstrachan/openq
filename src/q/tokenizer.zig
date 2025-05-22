const std = @import("std");
const mem = std.mem;

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

        pub fn unwrap(oi: OptionalIndex) ?Index {
            if (oi == .none) return null;
            return @enumFromInt(@intFromEnum(oi));
        }

        pub fn fromIndex(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
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
        backtick,
        l_brace,
        pipe,
        r_brace,
        tilde,

        string_literal,
        number_literal,
        identifier,
        system,
        invalid,
        eof,
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

    const State = enum {
        start,
        invalid,
        string_literal,
        string_literal_backslash,
        number_literal,
        identifier,
        dot,
        slash,
        line_comment,
        block_comment_start,
        block_comment,
        maybe_block_comment_end,
        block_comment_end,
        trailing_comment,
        maybe_system,
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
                '\r' => if (self.buffer[self.index + 1] != '\n')
                    continue :state .invalid
                else {
                    self.index += 2;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                ' ', '\n', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
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
                '`' => {
                    result.tag = .backtick;
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
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else {
                        result.tag = .invalid;
                    },
                    '\n' => {
                        if (std.ascii.isWhitespace(self.buffer[self.index + 1])) {
                            self.index += 1;
                            continue :state .string_literal;
                        }
                        result.tag = .invalid;
                    },
                    '\\' => continue :state .string_literal_backslash,
                    '"' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },
            .string_literal_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .string_literal,
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

            .slash => if (self.index > 0) switch (self.buffer[self.index - 1]) {
                '\n' => continue :state .block_comment_start,
                ' ', '\t' => continue :state .line_comment,
                else => {
                    result.tag = .slash;
                    self.index += 1;
                },
            } else continue :state .block_comment_start,

            .line_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    else => continue :state .line_comment,
                }
            },
            .block_comment_start => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    ' ', '\t' => continue :state .block_comment_start,
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    } else {
                        self.index += 1;
                        continue :state .block_comment;
                    },
                    '\n' => continue :state .block_comment,
                    else => continue :state .line_comment,
                }
            },
            .block_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    } else {
                        self.index += 1;
                        continue :state .maybe_block_comment_end;
                    },
                    '\n' => continue :state .maybe_block_comment_end,
                    else => continue :state .block_comment,
                }
            },
            .maybe_block_comment_end => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index != self.buffer.len) {
                        continue :state .invalid;
                    } else return .eof(self.buffer.len),
                    '\\' => continue :state .block_comment_end,
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
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    } else {
                        self.index += 2;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
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
                    '\n' => {},
                    else => continue :state .system,
                }
            },

            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
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
