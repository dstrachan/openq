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
    // `0n` is the null float and `0w` its infinity, not a timespan or a real, so the
    // special spellings take precedence over the type letter.
    if (isNull(slice) or isInfinity(slice)) return if (std.ascii.isUpper(slice[slice.len - 1])) .long else .float;
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

/// Whether a token ends in a type letter, as `1h`, `1e` or `0Nd` do and `0N`, `0n`, `1e3`
/// and `0D01` do not. q allows the letter only on the last token of a list literal, so
/// `0N 0W -0Wh` is a short list but `0Nh 0N` is an error.
pub fn hasSuffix(slice: []const u8) bool {
    if (slice.len < 2 or isNull(slice) or isInfinity(slice)) return false;
    return switch (slice[slice.len - 1]) {
        'b', 'h', 'i', 'j', 'e', 'f', 'p', 'm', 'd', 'z', 'n', 'u', 'v', 't' => true,
        else => false,
    };
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
        .real => .{ .real = @floatCast(try q.parseFloat(body)) },
        .float => .{ .float = try q.parseFloat(body) },
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

/// `YYYY.MM.DD`, optionally followed by `D` and a time of day. A bare integer counts hours
/// from 2000.01.01, as q reads `1p` and `3600p`.
fn parseTimestamp(s: []const u8) !i64 {
    if (specialInteger(Value.Long, s)) |v| return v;
    const d = std.mem.findScalar(u8, s, 'D') orelse s.len;
    if (d == s.len and !isDate(s)) return parseTimespan(s);
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
    const body = if (negative) s[1..] else s;
    if (allDigits(body)) {
        // Bare digits are a compact clock time, as q reads them: `1` and `25` are hours,
        // `100` and `12345` are hours and minutes (`1:00`, `123:45`) and `123456` is
        // `12:34:56`. q gives seven or more digits other meanings that are not copied.
        const compact: i64 = switch (body.len) {
            1, 2 => try std.fmt.parseInt(i64, body, 10) * 3600,
            3, 4, 5 => try std.fmt.parseInt(i64, body[0 .. body.len - 2], 10) * 3600 + try std.fmt.parseInt(i64, body[body.len - 2 ..], 10) * 60,
            6 => try std.fmt.parseInt(i64, body[0..2], 10) * 3600 + try std.fmt.parseInt(i64, body[2..4], 10) * 60 + try std.fmt.parseInt(i64, body[4..6], 10),
            else => return error.InvalidCharacter,
        };
        const compact_units = @divTrunc(compact * ns_per_second, unit);
        return @intCast(if (negative) -compact_units else compact_units);
    }
    var it = std.mem.splitScalar(u8, body, ':');
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

/// The kind a capital cast letter parses text into, as `"J"$"12"`; null for `S` and `C`,
/// which are not literal kinds, and for letters that are not casts.
pub fn kindOfCapital(letter: u8) ?Kind {
    return switch (letter) {
        'B' => .boolean,
        'X' => .byte,
        'H' => .short,
        'I' => .int,
        'J' => .long,
        'E' => .real,
        'F' => .float,
        'P' => .timestamp,
        'M' => .month,
        'D' => .date,
        'Z' => .datetime,
        'N' => .timespan,
        'U' => .minute,
        'V' => .second,
        'T' => .time,
        else => null,
    };
}

/// q's forgiving text parsing behind the capital cast letters: spaces are trimmed, integers
/// take an optional sign and their null and infinity spellings, dates accept `2023.04.17`,
/// `20230417`, `2023/04/17`, `2023-04-17` and `04/17/2023`, times accept compact digits
/// (`1234` is `12:34`), and anything unparsable, including an out-of-range integer, is the
/// null of the kind. A boolean is true for a single character other than `0`.
pub fn parseLoose(kind: Kind, text_in: []const u8) Atom {
    const text = std.mem.trim(u8, text_in, " ");
    return switch (kind) {
        .boolean => .{ .boolean = text.len == 1 and text[0] != '0' },
        .byte => .{ .byte = if (text.len == 1 or text.len == 2) std.fmt.parseInt(u8, text, 16) catch 0 else 0 },
        .short => .{ .short = looseInteger(Value.Short, text) },
        .int => .{ .int = looseInteger(Value.Int, text) },
        .long => .{ .long = looseInteger(Value.Long, text) },
        .real => .{ .real = @floatCast(looseFloat(text)) },
        .float => .{ .float = looseFloat(text) },
        .timestamp => .{ .timestamp = looseTimestamp(text) orelse @backingInt(Value.Long.null) },
        .month => .{ .month = looseMonth(text) orelse @backingInt(Value.Int.null) },
        .date => .{ .date = looseDate(text) orelse @backingInt(Value.Int.null) },
        .datetime => .{ .datetime = if (looseTimestamp(text)) |nanos| @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(ns_per_day)) else std.math.nan(f64) },
        .timespan => .{ .timespan = if (text.len == 0) @backingInt(Value.Long.null) else parseTimespan(text) catch @backingInt(Value.Long.null) },
        .minute => .{ .minute = looseTimeOfDay(text, 60 * ns_per_second, 4) orelse @backingInt(Value.Int.null) },
        .second => .{ .second = looseTimeOfDay(text, ns_per_second, 6) orelse @backingInt(Value.Int.null) },
        .time => .{ .time = looseTimeOfDay(text, 1_000_000, 9) orelse @backingInt(Value.Int.null) },
    };
}

fn looseInteger(comptime I: type, text: []const u8) @typeInfo(I).@"enum".tag_type {
    const T = @typeInfo(I).@"enum".tag_type;
    if (specialInteger(I, text)) |v| return v;
    if (text.len == 0) return @backingInt(I.null);
    const digits = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (digits.len == 0) return @backingInt(I.null);
    for (digits) |c| if (!std.ascii.isDigit(c)) return @backingInt(I.null);
    const value = std.fmt.parseInt(i128, text, 10) catch return @backingInt(I.null);
    if (value > std.math.maxInt(T) or value < -@as(i128, std.math.maxInt(T))) return @backingInt(I.null);
    return @intCast(value);
}

fn looseFloat(text: []const u8) f64 {
    if (specialFloat(text)) |v| return v;
    if (text.len == 0 or !(std.ascii.isDigit(text[0]) or text[0] == '+' or text[0] == '-' or text[0] == '.')) return std.math.nan(f64);
    return q.parseFloat(text) catch std.math.nan(f64);
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Days since 2000.01.01 of a date in one of the layouts q accepts, or null.
fn looseDate(text: []const u8) ?i32 {
    var y: i64 = undefined;
    var m: i64 = undefined;
    var d: i64 = undefined;
    if (text.len == 8 and allDigits(text)) {
        y = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
        m = std.fmt.parseInt(i64, text[4..6], 10) catch return null;
        d = std.fmt.parseInt(i64, text[6..8], 10) catch return null;
    } else {
        var parts: [3][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitAny(u8, text, "./-");
        while (it.next()) |part| : (count += 1) {
            if (count == 3 or !allDigits(part)) return null;
            parts[count] = part;
        }
        if (count != 3) return null;
        // Year first, or month/day/year as q reads `04/17/2023` by default.
        const ymd = if (parts[0].len == 4) parts else if (parts[2].len == 4) [3][]const u8{ parts[2], parts[0], parts[1] } else return null;
        y = std.fmt.parseInt(i64, ymd[0], 10) catch return null;
        m = std.fmt.parseInt(i64, ymd[1], 10) catch return null;
        d = std.fmt.parseInt(i64, ymd[2], 10) catch return null;
    }
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    return @intCast(daysFromCivil(y, m, d) - epoch_days);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        4, 6, 9, 11 => 30,
        2 => if (@rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0)) 29 else 28,
        else => 31,
    };
}

/// Months since 2000.01 of `YYYY.MM` or `YYYYMM`, or null.
fn looseMonth(text: []const u8) ?i32 {
    const y_text, const m_text = if (text.len == 7 and text[4] == '.')
        .{ text[0..4], text[5..7] }
    else if (text.len == 6 and allDigits(text))
        .{ text[0..4], text[4..6] }
    else
        return null;
    if (!allDigits(y_text) or !allDigits(m_text)) return null;
    const y = std.fmt.parseInt(i32, y_text, 10) catch return null;
    const m = std.fmt.parseInt(i32, m_text, 10) catch return null;
    if (m < 1 or m > 12) return null;
    return (y - 2000) * 12 + m - 1;
}

/// Nanoseconds since 2000.01.01 of a date optionally followed by `D`, `T` or a space and a
/// time of day, or null.
fn looseTimestamp(text: []const u8) ?i64 {
    const split = std.mem.findAny(u8, text, "DT ") orelse text.len;
    const days: i64 = looseDate(text[0..split]) orelse return null;
    const nanos: i64 = if (split + 1 < text.len) parseTimeOfDay(i64, text[split + 1 ..], 1) catch return null else 0;
    return days * ns_per_day + nanos;
}

/// A time of day in units of `unit` nanoseconds, from `hh[:mm[:ss[.fff]]]` or from
/// `compact_digits` bare digits (`1234` for a minute, `123456123` for a time), or null.
fn looseTimeOfDay(text: []const u8, unit: i64, compact_digits: usize) ?i32 {
    if (text.len == compact_digits and allDigits(text)) {
        var nanos: i64 = (std.fmt.parseInt(i64, text[0..2], 10) catch return null) * 3600 * ns_per_second;
        nanos += (std.fmt.parseInt(i64, text[2..4], 10) catch return null) * 60 * ns_per_second;
        if (compact_digits >= 6) nanos += (std.fmt.parseInt(i64, text[4..6], 10) catch return null) * ns_per_second;
        if (compact_digits == 9) nanos += (std.fmt.parseInt(i64, text[6..9], 10) catch return null) * 1_000_000;
        return @intCast(@divTrunc(nanos, unit));
    }
    if (text.len == 0) return null;
    const nanos = parseTimeOfDay(i64, text, 1) catch return null;
    return @intCast(@divTrunc(nanos, unit));
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
