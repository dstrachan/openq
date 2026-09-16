//! Parsing of numeric and temporal literals, and the calendar arithmetic their display needs.

const std = @import("std");

const q = @import("root.zig");
const Value = q.Value;

pub const Kind = enum {
    boolean,
    byte,
    short,
    int,
    long,
    real,
    float,
    timestamp,
    month,
    date,
    datetime,
    timespan,
    minute,
    second,
    time,

    /// The type letter that may end a literal of this kind.
    pub fn suffix(kind: Kind) u8 {
        return switch (kind) {
            .boolean => 'b',
            .byte => 'x',
            .short => 'h',
            .int => 'i',
            .long => 'j',
            .real => 'e',
            .float => 'f',
            .timestamp => 'p',
            .month => 'm',
            .date => 'd',
            .datetime => 'z',
            .timespan => 'n',
            .minute => 'u',
            .second => 'v',
            .time => 't',
        };
    }

    pub fn atomType(kind: Kind) Value.Type {
        return @field(Value.Type, @tagName(kind));
    }

    pub fn listType(kind: Kind) Value.Type {
        return @field(Value.Type, @tagName(kind) ++ "_list");
    }
};

pub const Atom = union(Kind) {
    boolean: bool,
    byte: u8,
    short: i16,
    int: i32,
    long: i64,
    real: f32,
    float: f64,
    timestamp: i64,
    month: i32,
    date: i32,
    datetime: f64,
    timespan: i64,
    minute: i32,
    second: i32,
    time: i32,
};

pub const ns_per_second: i64 = 1_000_000_000;
pub const ns_per_day: i64 = 86_400 * ns_per_second;
pub const ms_per_day: i64 = 86_400_000;
/// Days from 1970.01.01 to q's epoch, 2000.01.01.
pub const epoch_days: i64 = 10957;

/// Parses a complete literal, using its type letter when it has one and its shape otherwise.
pub fn parse(slice: []const u8) !Atom {
    return parseAs(try kindOf(slice), slice);
}

/// The kind a literal denotes: its type letter, or failing that its shape (`12:34` is a
/// minute, `2023.04.17` a date, `0N` a long, `0n` a float).
pub fn kindOf(slice: []const u8) !Kind {
    if (slice.len == 0) return error.InvalidCharacter;
    switch (slice[slice.len - 1]) {
        'b' => return .boolean,
        'h' => return .short,
        'i' => return .int,
        'j' => return .long,
        'e' => return .real,
        'f' => return .float,
        'p' => return .timestamp,
        'm' => return .month,
        'd' => return .date,
        'z' => return .datetime,
        'n' => return .timespan,
        'u' => return .minute,
        'v' => return .second,
        't' => return .time,
        else => {},
    }
    if (isNull(slice) or isInfinity(slice)) return if (std.ascii.isUpper(slice[slice.len - 1])) .long else .float;
    if (std.mem.findScalar(u8, slice, 'D')) |i| return if (isDate(slice[0..i])) .timestamp else .timespan;
    if (std.mem.findScalar(u8, slice, 'T') != null) return .datetime;
    switch (std.mem.countScalar(u8, slice, ':')) {
        1 => return .minute,
        2 => {
            const dot = std.mem.findScalar(u8, slice, '.') orelse return .second;
            return if (slice.len - dot - 1 > 3) .timespan else .time;
        },
        else => {},
    }
    if (isDate(slice)) return .date;
    if (std.mem.findAny(u8, slice, ".eE") != null) return .float;
    return .long;
}

/// Parses a token as a given kind, tolerating a trailing type letter: `0N` and `0Nd` are
/// both the null date when the kind is date.
pub fn parseAs(kind: Kind, slice: []const u8) !Atom {
    const body = if (slice.len > 1 and slice[slice.len - 1] == kind.suffix()) slice[0 .. slice.len - 1] else slice;
    if (body.len == 0) return error.InvalidCharacter;
    return switch (kind) {
        .boolean => .{ .boolean = switch (body[0]) {
            '1' => true,
            '0' => false,
            else => return error.InvalidCharacter,
        } },
        .byte => .{ .byte = try std.fmt.parseInt(u8, body, 16) },
        .short => .{ .short = try q.parseInteger(Value.Short, body) },
        .int => .{ .int = try q.parseInteger(Value.Int, body) },
        .long => .{ .long = try q.parseInteger(Value.Long, body) },
        .real => .{ .real = try q.parseFloat(f32, body) },
        .float => .{ .float = try q.parseFloat(f64, body) },
        .timestamp => .{ .timestamp = try parseTimestamp(body) },
        .month => .{ .month = try parseMonth(body) },
        .date => .{ .date = try parseDate(body) },
        .datetime => .{ .datetime = try parseDatetime(body) },
        .timespan => .{ .timespan = try parseTimespan(body) },
        .minute => .{ .minute = try parseTimeOfDay(i32, body, 60 * ns_per_second) },
        .second => .{ .second = try parseTimeOfDay(i32, body, ns_per_second) },
        .time => .{ .time = try parseTimeOfDay(i32, body, 1_000_000) },
    };
}

fn isNull(s: []const u8) bool {
    return s.len == 2 and s[0] == '0' and (s[1] == 'N' or s[1] == 'n');
}

fn isInfinity(s: []const u8) bool {
    const body = if (s.len > 0 and s[0] == '-') s[1..] else s;
    return body.len == 2 and body[0] == '0' and (body[1] == 'W' or body[1] == 'w');
}

/// `YYYY.MM.DD`.
fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '.' or s[7] != '.') return false;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    return true;
}

/// A null or infinite integer of the given enum type, or null when the text is neither.
fn specialInteger(comptime I: type, s: []const u8) ?@typeInfo(I).@"enum".tag_type {
    if (isNull(s)) return @backingInt(I.null);
    if (isInfinity(s)) return @backingInt(if (s[0] == '-') I.neg_inf else I.inf);
    return null;
}

fn specialFloat(s: []const u8) ?f64 {
    if (isNull(s)) return std.math.nan(f64);
    if (isInfinity(s)) return if (s[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    return null;
}

fn parseDate(s: []const u8) !i32 {
    if (specialInteger(Value.Int, s)) |v| return v;
    if (!isDate(s)) return error.InvalidCharacter;
    const y = try std.fmt.parseInt(i64, s[0..4], 10);
    const m = try std.fmt.parseInt(i64, s[5..7], 10);
    const d = try std.fmt.parseInt(i64, s[8..10], 10);
    if (m < 1 or m > 12 or d < 1 or d > 31) return error.InvalidCharacter;
    return @intCast(daysFromCivil(y, m, d) - epoch_days);
}

fn parseMonth(s: []const u8) !i32 {
    if (specialInteger(Value.Int, s)) |v| return v;
    if (s.len != 7 or s[4] != '.') return error.InvalidCharacter;
    const y = try std.fmt.parseInt(i32, s[0..4], 10);
    const m = try std.fmt.parseInt(i32, s[5..7], 10);
    if (m < 1 or m > 12) return error.InvalidCharacter;
    return (y - 2000) * 12 + m - 1;
}

/// `YYYY.MM.DD`, optionally followed by `D` and a time of day.
fn parseTimestamp(s: []const u8) !i64 {
    if (specialInteger(Value.Long, s)) |v| return v;
    const d = std.mem.findScalar(u8, s, 'D') orelse s.len;
    const days: i64 = try parseDate(s[0..d]);
    const nanos: i64 = if (d + 1 < s.len) try parseTimeOfDay(i64, s[d + 1 ..], 1) else 0;
    return days * ns_per_day + nanos;
}

/// `YYYY.MM.DD`, optionally followed by `T` and a time of day, as fractional days.
fn parseDatetime(s: []const u8) !f64 {
    if (specialFloat(s)) |v| return v;
    const t = std.mem.findScalar(u8, s, 'T') orelse s.len;
    const days: f64 = @floatFromInt(try parseDate(s[0..t]));
    const nanos: i64 = if (t + 1 < s.len) try parseTimeOfDay(i64, s[t + 1 ..], 1) else 0;
    return days + @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(ns_per_day));
}

/// `[-]NDhh:mm:ss.nnnnnnnnn`, or a time of day with more than three fractional digits.
fn parseTimespan(s: []const u8) !i64 {
    if (specialInteger(Value.Long, s)) |v| return v;
    const negative = s.len > 0 and s[0] == '-';
    const body = if (negative) s[1..] else s;
    var days: i64 = 0;
    var tod = body;
    if (std.mem.findScalar(u8, body, 'D')) |d| {
        days = try std.fmt.parseInt(i64, body[0..d], 10);
        tod = body[d + 1 ..];
    }
    const nanos: i64 = if (tod.len > 0) try parseTimeOfDay(i64, tod, 1) else 0;
    const total = days * ns_per_day + nanos;
    return if (negative) -total else total;
}

/// `hh[:mm[:ss[.fraction]]]` in units of `unit` nanoseconds; hours may exceed 24.
fn parseTimeOfDay(comptime T: type, s: []const u8, unit: i64) !T {
    if (specialInteger(if (T == i64) Value.Long else Value.Int, s)) |v| return v;
    const negative = s.len > 0 and s[0] == '-';
    var it = std.mem.splitScalar(u8, if (negative) s[1..] else s, ':');
    var nanos: i64 = 0;
    const hours = it.next() orelse return error.InvalidCharacter;
    nanos += try std.fmt.parseInt(i64, hours, 10) * 3600 * ns_per_second;
    if (it.next()) |minutes| nanos += try std.fmt.parseInt(i64, minutes, 10) * 60 * ns_per_second;
    if (it.next()) |seconds| {
        const dot = std.mem.findScalar(u8, seconds, '.') orelse seconds.len;
        nanos += try std.fmt.parseInt(i64, seconds[0..dot], 10) * ns_per_second;
        if (dot < seconds.len) {
            const fraction = seconds[dot + 1 ..];
            if (fraction.len == 0 or fraction.len > 9) return error.InvalidCharacter;
            var scaled = try std.fmt.parseInt(i64, fraction, 10);
            for (fraction.len..9) |_| scaled *= 10;
            nanos += scaled;
        }
    }
    if (it.next() != null) return error.InvalidCharacter;
    const units = @divTrunc(nanos, unit);
    return @intCast(if (negative) -units else units);
}

/// Days since 1970.01.01 of a proleptic Gregorian date.
pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: i64, day: i64 };

/// The proleptic Gregorian date of a day count since 1970.01.01.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

test "civil round trip" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(epoch_days, daysFromCivil(2000, 1, 1));
    try std.testing.expectEqual(@as(i64, 8507), daysFromCivil(2023, 4, 17) - epoch_days);
    var d: i64 = -800_000;
    while (d < 800_000) : (d += 997) {
        const c = civilFromDays(d);
        try std.testing.expectEqual(d, daysFromCivil(c.year, c.month, c.day));
    }
}
