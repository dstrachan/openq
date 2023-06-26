const std = @import("std");

const Token = @import("Token.zig");
const Value = @import("Value.zig");
const ValueType = Value.ValueType;
const ValueUnion = Value.ValueUnion;
const VM = @import("VM.zig");

const Parser = @This();

vm: VM,
previous: Token = undefined,
current: Token = undefined,
had_error: bool = false,
panic_mode: bool = false,
str: []const u8 = undefined,

pub const null_guid: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub const null_short = -32768;
pub const inf_short = 32767;

pub const null_int = -2147483648;
pub const inf_int = 2147483647;

pub const null_long = -9223372036854775808;
pub const inf_long = 9223372036854775807;

pub const null_real = std.math.nan(f32);
pub const inf_real = std.math.inf(f32);

pub const null_float = std.math.nan(f64);
pub const inf_float = std.math.inf(f64);

const ParserError = error{
    ParseError,
};

pub fn init(vm: VM) Parser {
    return .{
        .vm = vm,
    };
}

pub fn parseNumber(self: *Parser, str: []const u8) !*Value {
    self.str = str;
    return self.vm.initValue(switch (str[0]) {
        '0' => switch (str.len) {
            1 => .{ .long = 0 },
            2 => switch (str[1]) {
                'N' => .{ .long = null_long },
                'W' => .{ .long = inf_long },
                'n' => .{ .float = null_float },
                'w' => .{ .float = inf_float },
                'x' => .{ .byte_list = &[0]u8{} },
                'b' => .{ .boolean = false },
                else => try self.number(2),
            },
            3 => switch (str[1]) {
                'N', 'n' => try @"null"(str[2]),
                'W', 'w' => try inf(str[2]),
                'x' => try self.byte(),
                '0', '1' => try self.maybeBoolean(2),
                else => try self.number(2),
            },
            else => switch (str[1]) {
                'N', 'n', 'W', 'w' => return ParserError.ParseError,
                'x' => try self.byte(),
                '0', '1' => try self.maybeBoolean(2),
                else => try self.number(2),
            },
        },
        '1' => try self.maybeBoolean(1),
        '.' => try self.maybeFloat(1),
        '-' => try if (str[1] == '.') self.maybeFloat(2) else self.number(1),
        else => try self.number(0),
    });
}

fn maybeBoolean(self: Parser, index: usize) !ValueUnion {
    var i = index;
    while (i < self.str.len and isBooleanDigit(self.str[i])) : (i += 1) {}

    if (i == self.str.len) return .{ .long = try std.fmt.parseInt(i64, self.str, 10) };

    if (i == self.str.len - 1 and self.str[i] == 'b') {
        if (i == 1) {
            return .{ .boolean = self.str[0] == '1' };
        } else {
            const slice = self.vm.allocator.alloc(bool, i) catch std.debug.panic("Failed to allocate memory.", .{});
            for (self.str[0..i], slice) |c, *v| {
                v.* = c == '1';
            }
            return .{ .boolean_list = slice };
        }
    }

    return self.number(i);
}

fn maybeFloat(self: Parser, index: usize) !ValueUnion {
    var i = index;
    while (i < self.str.len and isDigit(self.str[i])) : (i += 1) {}

    if (i == self.str.len) return .{ .float = try std.fmt.parseFloat(f64, self.str) };

    return switch (self.str[i]) {
        'e' => .{ .real = try std.fmt.parseFloat(f32, self.str[0 .. i - 1]) },
        'f' => .{ .float = try std.fmt.parseFloat(f64, self.str[0 .. i - 1]) },
        'm' => self.month(),
        '.' => self.maybeDate(i + 1),
        else => ParserError.ParseError,
    };
}

fn maybeDate(self: Parser, index: usize) ValueUnion {
    _ = index;
    _ = self;
    unreachable;
}

fn @"null"(c: u8) !ValueUnion {
    return switch (c) {
        'c' => .{ .char = ' ' },
        'd' => .{ .date = null_int },
        'e' => .{ .real = null_real },
        'f' => .{ .float = null_float },
        'g' => .{ .guid = null_guid },
        'h' => .{ .short = null_short },
        'i' => .{ .int = null_int },
        'j' => .{ .long = null_long },
        'm' => .{ .month = null_int },
        'n' => .{ .timespan = null_long },
        'p' => .{ .timestamp = null_long },
        't' => .{ .time = null_int },
        'u' => .{ .minute = null_int },
        'v' => .{ .second = null_int },
        'z' => .{ .datetime = null_float },
        else => ParserError.ParseError,
    };
}

fn inf(c: u8) !ValueUnion {
    return switch (c) {
        'c' => .{ .char = ' ' },
        'd' => .{ .date = inf_int },
        'e' => .{ .real = inf_real },
        'f' => .{ .float = inf_float },
        'h' => .{ .short = inf_short },
        'i' => .{ .int = inf_int },
        'j' => .{ .long = inf_long },
        'm' => .{ .month = inf_int },
        'n' => .{ .timespan = inf_long },
        'p' => .{ .timestamp = inf_long },
        't' => .{ .time = inf_int },
        'u' => .{ .minute = inf_int },
        'v' => .{ .second = inf_int },
        'z' => .{ .datetime = inf_float },
        else => ParserError.ParseError,
    };
}

fn number(self: Parser, index: usize) !ValueUnion {
    var i = index;
    while (i < self.str.len and isDigit(self.str[i])) : (i += 1) {}

    if (i == self.str.len) return .{ .long = try std.fmt.parseInt(i64, self.str, 10) };

    return switch (self.str[i]) {
        'h' => self.short(),
        'i' => self.int(),
        'j' => self.long(),
        'e' => self.real(),
        'f' => self.float(),
        'c' => self.char(),
        'p' => self.timestamp(),
        'm' => self.month(),
        'z' => self.datetime(),
        'D', 'n' => self.timespan(),
        't' => self.time(),
        'u' => self.minute(),
        'v' => self.second(),
        '.' => self.maybeFloat(i + 1),
        else => try self.unclear(),
    };
}

fn unclear(self: Parser) !ValueUnion {
    _ = self;
    return ParserError.ParseError;
}

fn byte(self: Parser) !ValueUnion {
    if (self.str.len < 5) {
        const c1 = try std.fmt.charToDigit(self.str[2], 16);
        if (self.str.len == 4) {
            const c2 = try std.fmt.charToDigit(self.str[3], 16);
            return .{ .byte = c1 * 16 + c2 };
        }
        return .{ .byte = c1 };
    }

    var i: usize = 2;
    var list = std.ArrayList(u8).init(self.vm.allocator);
    defer list.deinit();
    while (i < self.str.len) : (i += 2) {
        const c1 = try std.fmt.charToDigit(self.str[i], 16);
        if (i + 1 < self.str.len) {
            const c2 = try std.fmt.charToDigit(self.str[i + 1], 16);
            try list.append(c1 * 16 + c2);
        } else {
            try list.append(c1);
        }
    }

    return .{ .byte_list = try list.toOwnedSlice() };
}

fn short(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn int(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn long(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn real(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn float(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn char(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn timestamp(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn month(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn date(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn datetime(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn timespan(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn minute(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn second(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn time(self: Parser) ValueUnion {
    _ = self;
    unreachable;
}

fn isBooleanDigit(c: u8) bool {
    return switch (c) {
        '0', '1' => true,
        else => false,
    };
}

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

fn testParser(input: []const u8, comptime expected_type: ValueType, comptime expected_value: anytype) !void {
    const vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    var parser = Parser.init(vm);
    const value = try parser.parseNumber(input);
    defer value.deref(vm.allocator);

    try std.testing.expectEqual(expected_type, value.as);

    const actual_value = @field(value.as, @tagName(expected_type));
    const actual = if (@typeInfo(@TypeOf(actual_value)) == .Array) &actual_value else actual_value;
    switch (@typeInfo(@TypeOf(expected_value))) {
        .Array => |type_info| {
            try std.testing.expectEqualSlices(type_info.child, &expected_value, actual);
        },
        .Pointer => |type_info| {
            try std.testing.expectEqualSlices(@typeInfo(type_info.child).Array.child, expected_value, actual);
        },
        .Struct => |type_info| {
            const fields_info = type_info.fields;
            const T = if (fields_info.len > 0) fields_info[0].type else @typeInfo(@TypeOf(actual)).Pointer.child;
            const expected = try std.testing.allocator.alloc(T, fields_info.len);
            defer std.testing.allocator.free(expected);
            inline for (fields_info, 0..) |field, i| {
                expected[i] = @field(expected_value, field.name);
            }
            try std.testing.expectEqualSlices(T, expected, actual);
        },
        else => {
            try std.testing.expectEqual(expected_value, actual);
        },
    }
}

fn testParserError(input: []const u8, expected: anyerror) !void {
    const vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    var parser = Parser.init(vm);
    const value = parser.parseNumber(input) catch |e| {
        try std.testing.expectEqual(expected, e);
        return;
    };
    defer value.deref(vm.allocator);

    return error.UnexpectedResult;
}

test "valid boolean inputs" {
    try testParser("0b", .boolean, false);
    try testParser("1b", .boolean, true);

    try testParser("00b", .boolean_list, .{ false, false });
    try testParser("01b", .boolean_list, .{ false, true });
    try testParser("10b", .boolean_list, .{ true, false });
    try testParser("11b", .boolean_list, .{ true, true });

    try testParser("000b", .boolean_list, .{ false, false, false });
    try testParser("001b", .boolean_list, .{ false, false, true });
    try testParser("010b", .boolean_list, .{ false, true, false });
    try testParser("011b", .boolean_list, .{ false, true, true });
    try testParser("100b", .boolean_list, .{ true, false, false });
    try testParser("101b", .boolean_list, .{ true, false, true });
    try testParser("110b", .boolean_list, .{ true, true, false });
    try testParser("111b", .boolean_list, .{ true, true, true });
}

test "invalid boolean inputs" {
    try testParserError("2b", ParserError.ParseError);
    try testParserError(".b", ParserError.ParseError);
    try testParserError(".1b", ParserError.ParseError);
    try testParserError("1.b", ParserError.ParseError);
    try testParserError("1.1b", ParserError.ParseError);
    try testParserError("1b0", ParserError.ParseError);
    try testParserError("10b0", ParserError.ParseError);
}

test "valid guid inputs" {
    try testParser("0ng", .guid, null_guid);
    try testParser("0Ng", .guid, null_guid);
}

test "invalid guid inputs" {
    try testParserError("00000000-0000-0000-0000-000000000000", ParserError.ParseError);
}

test "valid byte inputs" {
    try testParser("0x0", .byte, @as(u8, 0));
    try testParser("0x00", .byte, @as(u8, 0));
    try testParser("0x1", .byte, @as(u8, 1));
    try testParser("0x01", .byte, @as(u8, 1));
    try testParser("0xf", .byte, @as(u8, 15));
    try testParser("0x0f", .byte, @as(u8, 15));
    try testParser("0xF", .byte, @as(u8, 15));
    try testParser("0x0F", .byte, @as(u8, 15));
    try testParser("0x10", .byte, @as(u8, 16));
    try testParser("0xf0", .byte, @as(u8, 240));
    try testParser("0xF0", .byte, @as(u8, 240));
    try testParser("0xff", .byte, @as(u8, 255));
    try testParser("0xFF", .byte, @as(u8, 255));

    try testParser("0x", .byte_list, .{});
}

test "invalid byte inputs" {
    try testParserError("0X", error.InvalidCharacter);
    try testParserError("0xg", error.InvalidCharacter);
    try testParserError("0xG", error.InvalidCharacter);
    try testParserError("0xgg", error.InvalidCharacter);
    try testParserError("0xGG", error.InvalidCharacter);
}
