const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Index = enum(u32) {
        zero = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }

        pub fn offset(i: Index, o: i32) Index {
            const base_i64: i64 = @intFromEnum(i);
            return @enumFromInt(base_i64 + o);
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

        string_literal,
        symbol_literal,
        number_literal,
        identifier,
        system,
        invalid,
        eos,
        eof,

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

                .string_literal,
                .symbol_literal,
                .number_literal,
                .identifier,
                .system,
                .invalid,
                .eos,
                .eof,
                => null,
            };
        }

        pub fn isNextMinus(tag: Tag) bool {
            return switch (tag) {
                .r_paren,
                .r_bracket,
                .r_brace,
                .string_literal,
                .symbol_literal,
                .number_literal,
                .identifier,
                .eos,
                => true,
                else => false,
            };
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{});

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    fn eos(index: usize) Token {
        return .{
            .tag = .eos,
            .loc = .{
                .start = index,
                .end = index + 1,
            },
        };
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
    next_is_minus: bool,
    next_token: ?Token = null,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present.
        return .{
            .buffer = buffer,
            .index = if (mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0,
            .next_is_minus = false,
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
        string_literal,
        string_literal_newline,
        string_literal_backslash,
        octal_char_two,
        octal_char_three,
        symbol_literal_start,
        symbol_literal,
        file_handle,
        zero,
        one,
        two,
        number_literal,
        identifier,
        bang,
        hash,
        dollar,
        percent,
        ampersand,
        apostrophe,
        asterisk,
        plus,
        comma,
        minus,
        dot,
        slash,
        colon,
        l_angle_bracket,
        equal,
        r_angle_bracket,
        question_mark,
        at,
        backslash,
        block_comment_start,
        block_comment,
        maybe_block_comment_end,
        block_comment_end,
        trailing_comment,
        maybe_system,
        system,
        caret,
        underscore,
        pipe,
        tilde,
        skip_line,
        invalid,
    };

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        if (self.next_token) |next_token| {
            self.next_token = null;
            result = next_token;
        } else {
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
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                    },
                    '[' => {
                        result.tag = .l_bracket;
                        self.index += 1;
                    },
                    ']' => {
                        result.tag = .r_bracket;
                        self.index += 1;
                    },
                    '{' => {
                        result.tag = .l_brace;
                        self.index += 1;
                    },
                    '}' => {
                        result.tag = .r_brace;
                        self.index += 1;
                    },
                    ';' => {
                        result.tag = .semicolon;
                        self.index += 1;
                    },
                    '"' => {
                        result.tag = .string_literal;
                        continue :state .string_literal;
                    },
                    '`' => {
                        result.tag = .symbol_literal;
                        continue :state .symbol_literal;
                    },
                    '0' => {
                        result.tag = .number_literal;
                        continue :state .zero;
                    },
                    '1' => {
                        result.tag = .number_literal;
                        continue :state .one;
                    },
                    '2' => {
                        result.tag = .number_literal;
                        continue :state .two;
                    },
                    '3'...'9' => {
                        result.tag = .number_literal;
                        continue :state .number_literal;
                    },
                    'a'...'z', 'A'...'Z' => {
                        result.tag = .identifier;
                        continue :state .identifier;
                    },
                    '!' => {
                        result.tag = .bang;
                        continue :state .bang;
                    },
                    '#' => {
                        result.tag = .hash;
                        continue :state .hash;
                    },
                    '$' => {
                        result.tag = .dollar;
                        continue :state .dollar;
                    },
                    '%' => {
                        result.tag = .percent;
                        continue :state .percent;
                    },
                    '&' => {
                        result.tag = .ampersand;
                        continue :state .ampersand;
                    },
                    '\'' => {
                        result.tag = .apostrophe;
                        continue :state .apostrophe;
                    },
                    '*' => {
                        result.tag = .asterisk;
                        continue :state .asterisk;
                    },
                    '+' => {
                        result.tag = .plus;
                        continue :state .plus;
                    },
                    ',' => {
                        result.tag = .comma;
                        continue :state .comma;
                    },
                    '-' => {
                        result.tag = .minus;
                        continue :state .minus;
                    },
                    '.' => {
                        result.tag = .dot;
                        continue :state .dot;
                    },
                    '/' => if (self.index != 0) switch (self.buffer[self.index - 1]) {
                        '\n' => continue :state .block_comment_start,
                        ' ', '\t' => continue :state .skip_line,
                        else => {
                            result.tag = .slash;
                            continue :state .slash;
                        },
                    } else continue :state .block_comment_start,
                    ':' => {
                        result.tag = .colon;
                        continue :state .colon;
                    },
                    '<' => {
                        result.tag = .l_angle_bracket;
                        continue :state .l_angle_bracket;
                    },
                    '=' => {
                        result.tag = .equal;
                        continue :state .equal;
                    },
                    '>' => {
                        result.tag = .r_angle_bracket;
                        continue :state .r_angle_bracket;
                    },
                    '?' => {
                        result.tag = .question_mark;
                        continue :state .question_mark;
                    },
                    '@' => {
                        result.tag = .at;
                        continue :state .at;
                    },
                    '\\' => if (self.index == 0 or self.buffer[self.index - 1] == '\n')
                        continue :state .maybe_system
                    else {
                        result.tag = .backslash;
                        continue :state .backslash;
                    },
                    '^' => {
                        result.tag = .caret;
                        continue :state .caret;
                    },
                    '_' => {
                        result.tag = .underscore;
                        continue :state .underscore;
                    },
                    '|' => {
                        result.tag = .pipe;
                        continue :state .pipe;
                    },
                    '~' => {
                        result.tag = .tilde;
                        continue :state .tilde;
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

                .zero => switch (self.buffer[self.index + 1]) {
                    ':' => switch (self.buffer[self.index + 2]) {
                        ':' => {
                            result.tag = .zero_colon_colon;
                            self.index += 3;
                        },
                        else => {
                            result.tag = .zero_colon;
                            self.index += 2;
                        },
                    },
                    else => continue :state .number_literal,
                },
                .one => switch (self.buffer[self.index + 1]) {
                    ':' => switch (self.buffer[self.index + 2]) {
                        ':' => {
                            result.tag = .one_colon_colon;
                            self.index += 3;
                        },
                        else => {
                            result.tag = .one_colon;
                            self.index += 2;
                        },
                    },
                    else => continue :state .number_literal,
                },
                .two => switch (self.buffer[self.index + 1]) {
                    ':' => {
                        result.tag = .two_colon;
                        self.index += 2;
                    },
                    else => continue :state .number_literal,
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

                .bang => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .bang_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .hash => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .hash_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .dollar => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .dollar_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .percent => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .percent_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .ampersand => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .ampersand_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .apostrophe => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .apostrophe_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .asterisk => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .asterisk_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .plus => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .plus_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .comma => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .comma_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .minus => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .minus_colon;
                            self.index += 1;
                        },
                        '.' => if (!self.next_is_minus or std.ascii.isWhitespace(self.buffer[self.index - 2])) {
                            switch (self.buffer[self.index + 1]) {
                                '0'...'9' => {
                                    self.index += 1;
                                    result.tag = .number_literal;
                                    continue :state .number_literal;
                                },
                                else => {},
                            }
                        },
                        '0'...'9' => if (!self.next_is_minus or std.ascii.isWhitespace(self.buffer[self.index - 2])) {
                            result.tag = .number_literal;
                            continue :state .number_literal;
                        },
                        else => {},
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
                        ':' => {
                            result.tag = .dot_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .slash => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .slash_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .colon => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .colon_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .l_angle_bracket => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .l_angle_bracket_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .equal => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .equal_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .r_angle_bracket => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .r_angle_bracket_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .question_mark => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .question_mark_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .at => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .at_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .backslash => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .backslash_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

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

                .caret => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .caret_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .underscore => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .underscore_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .pipe => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .pipe_colon;
                            self.index += 1;
                        },
                        else => {},
                    }
                },

                .tilde => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        ':' => {
                            result.tag = .tilde_colon;
                            self.index += 1;
                        },
                        else => {},
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

            if (result.loc.start != 0 and self.buffer[result.loc.start - 1] == '\n') {
                self.next_token = result;
                return .eos(result.loc.start - 1);
            }
        }

        self.next_is_minus = result.tag.isNextMinus();

        result.loc.end = self.index;
        return result;
    }
};

fn testTokenize(source: [:0]const u8, expected_values: []const struct { Token.Tag, []const u8 }) !void {
    const gpa = std.testing.allocator;

    var actual_tags: std.ArrayListUnmanaged(Token.Tag) = .empty;
    defer actual_tags.deinit(gpa);

    var actual_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer actual_bytes.deinit(gpa);

    var tokenizer: Tokenizer = .init(source);
    tokenizer.skipComments();
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .eos) continue;
        try actual_tags.append(gpa, token.tag);
        try actual_bytes.appendSlice(gpa, source[token.loc.start..token.loc.end]);
        try actual_bytes.append(gpa, 0);
    }

    var expected_tags: std.ArrayListUnmanaged(Token.Tag) = .empty;
    defer expected_tags.deinit(gpa);

    var expected_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer expected_bytes.deinit(gpa);

    for (expected_values) |e| {
        const tag, const slice = e;
        try expected_tags.append(gpa, tag);
        try expected_bytes.appendSlice(gpa, slice);
        try expected_bytes.append(gpa, 0);
    }

    try std.testing.expectEqualSlices(Token.Tag, expected_tags.items, actual_tags.items);
    try std.testing.expectEqualStrings(expected_bytes.items, actual_bytes.items);
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
    try testTokenize("-1", &.{.{ .number_literal, "-1" }});
    try testTokenize("-1i", &.{.{ .number_literal, "-1i" }});
    try testTokenize("-1abc", &.{.{ .number_literal, "-1abc" }});
    try testTokenize("-123", &.{.{ .number_literal, "-123" }});
    try testTokenize("-123i", &.{.{ .number_literal, "-123i" }});
    try testTokenize("-123abc", &.{.{ .number_literal, "-123abc" }});
    try testTokenize("-0D123:456:789.1234abc", &.{.{ .number_literal, "-0D123:456:789.1234abc" }});
    try testTokenize("-0.1", &.{.{ .number_literal, "-0.1" }});
    try testTokenize("-.1", &.{.{ .number_literal, "-.1" }});
}

test "tokenize negative numbers/minus" {
    try testTokenize("x-1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("x-.1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("x- 1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("x- .1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("x -1", &.{ .{ .identifier, "x" }, .{ .number_literal, "-1" } });
    try testTokenize("x -.1", &.{ .{ .identifier, "x" }, .{ .number_literal, "-.1" } });
    try testTokenize("x - 1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("x - .1", &.{ .{ .identifier, "x" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("1-2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, "2" } });
    try testTokenize("1-.2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, ".2" } });
    try testTokenize("1- 2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, "2" } });
    try testTokenize("1- .2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, ".2" } });
    try testTokenize("1 -2", &.{ .{ .number_literal, "1" }, .{ .number_literal, "-2" } });
    try testTokenize("1 -.2", &.{ .{ .number_literal, "1" }, .{ .number_literal, "-.2" } });
    try testTokenize("1 - 2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, "2" } });
    try testTokenize("1 - .2", &.{ .{ .number_literal, "1" }, .{ .minus, "-" }, .{ .number_literal, ".2" } });
    try testTokenize("]-1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("]-.1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("]- 1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("]- .1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("] -1", &.{ .{ .r_bracket, "]" }, .{ .number_literal, "-1" } });
    try testTokenize("] -.1", &.{ .{ .r_bracket, "]" }, .{ .number_literal, "-.1" } });
    try testTokenize("] - 1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("] - .1", &.{ .{ .r_bracket, "]" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize(")-1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize(")-.1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize(")- 1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize(")- .1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize(") -1", &.{ .{ .r_paren, ")" }, .{ .number_literal, "-1" } });
    try testTokenize(") -.1", &.{ .{ .r_paren, ")" }, .{ .number_literal, "-.1" } });
    try testTokenize(") - 1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize(") - .1", &.{ .{ .r_paren, ")" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("}-1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("}-.1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("}- 1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("}- .1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("} -1", &.{ .{ .r_brace, "}" }, .{ .number_literal, "-1" } });
    try testTokenize("} -.1", &.{ .{ .r_brace, "}" }, .{ .number_literal, "-.1" } });
    try testTokenize("} - 1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, "1" } });
    try testTokenize("} - .1", &.{ .{ .r_brace, "}" }, .{ .minus, "-" }, .{ .number_literal, ".1" } });
    try testTokenize("-.(", &.{ .{ .minus, "-" }, .{ .dot, "." }, .{ .l_paren, "(" } });
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

test "tokenize punctuation/operators/iterators" {
    try testTokenize("()[]{};", &.{
        .{ .l_paren, "(" },
        .{ .r_paren, ")" },
        .{ .l_bracket, "[" },
        .{ .r_bracket, "]" },
        .{ .l_brace, "{" },
        .{ .r_brace, "}" },
        .{ .semicolon, ";" },
    });

    try testTokenize("!#$%&*+,-. :<=>?@^_|~0:1:2:", &.{
        .{ .bang, "!" },
        .{ .hash, "#" },
        .{ .dollar, "$" },
        .{ .percent, "%" },
        .{ .ampersand, "&" },
        .{ .asterisk, "*" },
        .{ .plus, "+" },
        .{ .comma, "," },
        .{ .minus, "-" },
        .{ .dot, "." },
        .{ .colon, ":" },
        .{ .l_angle_bracket, "<" },
        .{ .equal, "=" },
        .{ .r_angle_bracket, ">" },
        .{ .question_mark, "?" },
        .{ .at, "@" },
        .{ .caret, "^" },
        .{ .underscore, "_" },
        .{ .pipe, "|" },
        .{ .tilde, "~" },
        .{ .zero_colon, "0:" },
        .{ .one_colon, "1:" },
        .{ .two_colon, "2:" },
    });
    try testTokenize("!:#:$:%:&:*:+:,:-:.:::<:=:>:?:@:^:_:|:~:0::1::", &.{
        .{ .bang_colon, "!:" },
        .{ .hash_colon, "#:" },
        .{ .dollar_colon, "$:" },
        .{ .percent_colon, "%:" },
        .{ .ampersand_colon, "&:" },
        .{ .asterisk_colon, "*:" },
        .{ .plus_colon, "+:" },
        .{ .comma_colon, ",:" },
        .{ .minus_colon, "-:" },
        .{ .dot_colon, ".:" },
        .{ .colon_colon, "::" },
        .{ .l_angle_bracket_colon, "<:" },
        .{ .equal_colon, "=:" },
        .{ .r_angle_bracket_colon, ">:" },
        .{ .question_mark_colon, "?:" },
        .{ .at_colon, "@:" },
        .{ .caret_colon, "^:" },
        .{ .underscore_colon, "_:" },
        .{ .pipe_colon, "|:" },
        .{ .tilde_colon, "~:" },
        .{ .zero_colon_colon, "0::" },
        .{ .one_colon_colon, "1::" },
    });

    try testTokenize("'/\\", &.{
        .{ .apostrophe, "'" },
        .{ .slash, "/" },
        .{ .backslash, "\\" },
    });
    try testTokenize("':/:\\:", &.{
        .{ .apostrophe_colon, "':" },
        .{ .slash_colon, "/:" },
        .{ .backslash_colon, "\\:" },
    });
}

test "fuzz" {
    const gpa = std.testing.allocator;
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context; // autofix
            const source0 = try gpa.dupeZ(u8, input);
            defer gpa.free(source0);
            var tokenizer: Tokenizer = .init(source0);
            var tokenizer_failed = false;
            while (true) {
                const token = tokenizer.next();

                try std.testing.expect(token.loc.end >= token.loc.start);

                switch (token.tag) {
                    .invalid => {
                        tokenizer_failed = true;

                        // Invalid token ends with newline or null byte.
                        try std.testing.expect(source0[token.loc.end] == '\n' or source0[token.loc.end] == 0);
                    },
                    .eof => {
                        // EOF token is always 0 length and at end of source.
                        try std.testing.expectEqual(source0.len, token.loc.start);
                        try std.testing.expectEqual(source0.len, token.loc.end);
                        break;
                    },
                    else => {
                        try std.testing.expect(source0[token.loc.end] != '\n');
                    },
                }
            }

            if (source0.len != 0) for (source0, source0[1..][0..source0.len]) |cur, next| {
                // No null byte allowed except at end.
                if (cur == 0) {
                    try std.testing.expect(tokenizer_failed);
                }
                // No ASCII control characters other than '\n' and '\t' are allowed.
                if (std.ascii.isControl(cur) and cur != '\n' and cur != '\t') {
                    try std.testing.expect(tokenizer_failed);
                }
                // All '\r' must be followed by '\n'.
                if (cur == '\r' and next != '\n') {
                    try std.testing.expect(tokenizer_failed);
                }
            };
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
