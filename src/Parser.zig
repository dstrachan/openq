const std = @import("std");

const Token = @import("Token.zig");
const Value = @import("Value.zig");
const ValueUnion = Value.ValueUnion;
const VM = @import("VM.zig");

const Self = @This();

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

pub fn init(vm: VM) Self {
    return .{
        .vm = vm,
    };
}

pub fn parseNumber(self: *Self, str: []const u8) !*Value {
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
                'x' => self.byte(),
                '0', '1' => try self.maybeBoolean(2),
                else => try self.number(2),
            },
            else => switch (str[1]) {
                'N', 'n', 'W', 'w' => return ParserError.ParseError,
                'x' => self.byte(),
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

fn maybeBoolean(self: Self, index: usize) !ValueUnion {
    var i = index;
    while (i < self.str.len and isBooleanDigit(self.str[i])) : (i += 1) {}

    if (i == self.str.len) return .{ .long = try std.fmt.parseInt(i64, self.str, 10) };

    if (i == self.str.len - 1 and self.str[i] == 'b') {
        if (i == 1) {
            return .{ .boolean = self.str[0] == '1' };
        } else {
            const slice = self.vm.allocator.alloc(bool, i) catch std.debug.panic("Failed to allocate memory.", .{});
            for (self.str[0 .. i - 1], 0..) |c, idx| {
                slice[idx] = c == '1';
            }
            return .{ .boolean_list = slice };
        }
    }

    return self.number(i);
}

fn maybeFloat(self: Self, index: usize) !ValueUnion {
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

fn maybeDate(self: Self, index: usize) ValueUnion {
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

fn number(self: Self, index: usize) !ValueUnion {
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
        else => self.unclear(),
    };
}

fn unclear(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn byte(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn short(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn int(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn long(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn real(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn float(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn char(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn timestamp(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn month(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn date(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn datetime(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn timespan(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn minute(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn second(self: Self) ValueUnion {
    _ = self;
    unreachable;
}

fn time(self: Self) ValueUnion {
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
