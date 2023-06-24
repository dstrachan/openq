const std = @import("std");

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

const NumberType = enum {
    Boolean,
    BooleanList,
    Guid, // null only
    Byte,
    ByteList,
    Short,
    Int,
    Long,
    Real,
    Float,
    Char,
    Timestamp,
    Month,
    Date,
    Datetime,
    Timespan,
    Minute,
    Second,
    Time,
    Error,
};

const Number = union(NumberType) {
    Boolean: bool,
    BooleanList: []const bool,
    Guid,
    Byte: u8,
    ByteList: []const u8,
    Short: i16,
    Int: i32,
    Long: i64,
    Real: f32,
    Float: f64,
    Char: u8,
    Timestamp: i64,
    Month: i32,
    Date: i32,
    Datetime: f64,
    Timespan: i64,
    Minute: i32,
    Second: i32,
    Time: i32,
    Error,
};

pub fn fromString(str: []const u8) !Number {
    if (str[0] == '.') return realOrFloat(str, 1);
    if (str[0] == '-') return if (str[1] == '.') realOrFloat(str, 2) else number(str, 1);
    return number(str, 0);

    // return switch (str[0]) {
    //     '0' => switch (str.len) {
    //         1 => .{ .Long = 0 },
    //         2 => switch (str[1]) {
    //             'N' => .{ .Long = null_long },
    //             'W' => .{ .Long = inf_long },
    //             'n' => .{ .Float = null_float },
    //             'w' => .{ .Float = inf_float },
    //             'x' => .{ .ByteList = &[0]u8{} },
    //             else => number(str),
    //         },
    //         3 => switch (str[1]) {
    //             'N', 'n' => @"null"(str[2]),
    //             'W', 'w' => inf(str[2]),
    //             'x' => byte(str[2..]),
    //             else => number(str),
    //         },
    //         else => switch (str[1]) {
    //             'N', 'n', 'W', 'w' => .Error,
    //             'x' => byte(str[2..]),
    //             else => number(str),
    //         },
    //     },
    //     else => number(str),
    // };
}

fn realOrFloat(str: []const u8, index: usize) !Number {
    var i = index;
    while (i < str.len and isDigit(str[i])) : (i += 1) {}

    if (i == str.len) return .{ .Float = try std.fmt.parseFloat(f64, str) };

    return switch (str[i]) {
        'e' => .{ .Real = try std.fmt.parseFloat(f32, str[0 .. i - 1]) },
        'f' => .{ .Float = try std.fmt.parseFloat(f64, str[0 .. i - 1]) },
        'm' => month(str),
        '.' => dateOrTimestamp(str, i + 1),
        else => .Error,
    };
}

fn dateOrTimestamp(str: []const u8, index: usize) Number {
    _ = index;
    _ = str;
    unreachable;
}

fn @"null"(c: u8) Number {
    return switch (c) {
        'c' => .{ .Char = ' ' },
        'd' => .{ .Date = null_int },
        'e' => .{ .Real = null_real },
        'f' => .{ .Float = null_float },
        'g' => .Guid,
        'h' => .{ .Short = null_short },
        'i' => .{ .Int = null_int },
        'j' => .{ .Long = null_long },
        'm' => .{ .Month = null_int },
        'n' => .{ .Timespan = null_long },
        'p' => .{ .Timestamp = null_long },
        't' => .{ .Time = null_int },
        'u' => .{ .Minute = null_int },
        'v' => .{ .Second = null_int },
        'z' => .{ .Datetime = null_float },
        else => .Error,
    };
}

fn inf(c: u8) Number {
    return switch (c) {
        'c' => .{ .Char = ' ' },
        'd' => .{ .Date = inf_int },
        'e' => .{ .Real = inf_real },
        'f' => .{ .Float = inf_float },
        'h' => .{ .Short = inf_short },
        'i' => .{ .Int = inf_int },
        'j' => .{ .Long = inf_long },
        'm' => .{ .Month = inf_int },
        'n' => .{ .Timespan = inf_long },
        'p' => .{ .Timestamp = inf_long },
        't' => .{ .Time = inf_int },
        'u' => .{ .Minute = inf_int },
        'v' => .{ .Second = inf_int },
        'z' => .{ .Datetime = inf_float },
        else => .Error,
    };
}

fn number(str: []const u8, index: usize) !Number {
    var i = index;
    while (i < str.len and isDigit(str[i])) : (i += 1) {}

    if (i == str.len) return .{ .Long = try std.fmt.parseInt(i64, str, 10) };

    return switch (str[i]) {
        'b' => boolean(str),
        'h' => short(str),
        'i' => int(str),
        'j' => long(str),
        'e' => real(str),
        'f' => float(str),
        'c' => char(str),
        'p' => timestamp(str),
        'm' => month(str),
        'z' => datetime(str),
        'D', 'n' => timespan(str),
        't' => time(str),
        'u' => minute(str),
        'v' => second(str),
        '.' => realOrFloat(str, i + 1),
        else => unclear(str),
    };
}

fn unclear(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn boolean(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn byte(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn short(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn int(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn long(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn real(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn float(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn char(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn timestamp(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn month(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn date(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn datetime(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn timespan(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn minute(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn second(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn time(str: []const u8) Number {
    _ = str;
    unreachable;
}

fn isDigit(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}
