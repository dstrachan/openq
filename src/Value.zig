const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Vm = q.Vm;

const Value = @This();

ref_count: u32 = 0,
/// The attribute `` `s#x `` and its kin set: sorted, unique, parted or grouped, shown as a
/// prefix (`` `s#1 2 3 ``) and read back by `-2!`. Fresh values have none.
attr: Attr = .none,
as: Union,

pub const Attr = enum(u8) { none, s, u, p, g };

pub fn ref(value: *Value) *Value {
    value.ref_count += 1;
    return value;
}

pub fn deref(value: *Value, gpa: Allocator) void {
    if (value.ref_count > 0) {
        value.ref_count -= 1;
    } else {
        switch (value.as) {
            .list => |list| {
                for (list) |v| v.deref(gpa);
                gpa.free(list);
            },
            .boolean,
            .byte,
            .short,
            .int,
            .long,
            .real,
            .float,
            .char,
            .symbol,
            .timestamp,
            .month,
            .date,
            .datetime,
            .timespan,
            .minute,
            .second,
            .time,
            .unary_primitive,
            .operator,
            .iterator,
            => {},
            inline .boolean_list,
            .byte_list,
            .short_list,
            .int_list,
            .long_list,
            .real_list,
            .float_list,
            .char_list,
            .symbol_list,
            .timestamp_list,
            .month_list,
            .date_list,
            .datetime_list,
            .timespan_list,
            .minute_list,
            .second_list,
            .time_list,
            => |list| gpa.free(list),
            .dict, .table => |val| {
                val.keys.deref(gpa);
                val.values.deref(gpa);
            },
            .lambda => |val| {
                gpa.free(val.bytecode);
                gpa.free(val.params);
                gpa.free(val.locals);
                gpa.free(val.globals);
                for (val.constants) |v| v.deref(gpa);
                gpa.free(val.constants);
                gpa.free(val.source);
            },
            .projection => |val| {
                val.callee.deref(gpa);
                for (val.args) |v| v.deref(gpa);
                gpa.free(val.args);
            },
            inline .each,
            .over,
            .scan,
            .each_prior,
            .each_right,
            .each_left,
            => |val| val.value.deref(gpa),
            .composition => |val| {
                val.f.deref(gpa);
                val.g.deref(gpa);
            },
        }
        gpa.destroy(value);
    }
}

pub fn isList(value: *const Value) bool {
    return switch (value.as) {
        .list,
        .boolean_list,
        .byte_list,
        .short_list,
        .int_list,
        .long_list,
        .real_list,
        .float_list,
        .char_list,
        .symbol_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .datetime_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
        => true,
        else => false,
    };
}

pub fn isEmpty(self: *const Value) bool {
    return self.as == .unary_primitive and self.as.unary_primitive == .empty;
}

pub fn eql(a: *Value, b: *Value) bool {
    if (@as(Type, a.as) != @as(Type, b.as)) return false;
    switch (a.as) {
        .list => |a_list| {
            if (a_list.len != b.as.list.len) return false;
            for (a_list, b.as.list) |a_val, b_val| {
                if (!a_val.eql(b_val)) return false;
            }
            return true;
        },
        .boolean => |a_val| return a_val == b.as.boolean,
        .boolean_list => |a_val| return std.mem.eql(bool, a_val, b.as.boolean_list),
        .byte => |a_val| return a_val == b.as.byte,
        .byte_list => |a_val| return std.mem.eql(u8, a_val, b.as.byte_list),
        .short => |a_val| return a_val == b.as.short,
        .short_list => |a_val| return std.mem.eql(i16, a_val, b.as.short_list),
        .int => |a_val| return a_val == b.as.int,
        .int_list => |a_val| return std.mem.eql(i32, a_val, b.as.int_list),
        .long => |a_val| return a_val == b.as.long,
        .long_list => |a_val| return std.mem.eql(i64, a_val, b.as.long_list),
        .real => |a_val| return a_val == b.as.real,
        .real_list => |a_val| return std.mem.eql(f32, a_val, b.as.real_list),
        .float => |a_val| return a_val == b.as.float,
        .float_list => |a_val| return std.mem.eql(f64, a_val, b.as.float_list),
        .char => |a_val| return a_val == b.as.char,
        .char_list => |a_val| return std.mem.eql(u8, a_val, b.as.char_list),
        .symbol => |a_val| return a_val == b.as.symbol,
        .symbol_list => |a_val| return std.mem.eql(Symbol, a_val, b.as.symbol_list),
        .timestamp => |a_val| return a_val == b.as.timestamp,
        .timestamp_list => |a_val| return std.mem.eql(i64, a_val, b.as.timestamp_list),
        .month => |a_val| return a_val == b.as.month,
        .month_list => |a_val| return std.mem.eql(i32, a_val, b.as.month_list),
        .date => |a_val| return a_val == b.as.date,
        .date_list => |a_val| return std.mem.eql(i32, a_val, b.as.date_list),
        .datetime => |a_val| return a_val == b.as.datetime,
        .datetime_list => |a_val| return std.mem.eql(f64, a_val, b.as.datetime_list),
        .timespan => |a_val| return a_val == b.as.timespan,
        .timespan_list => |a_val| return std.mem.eql(i64, a_val, b.as.timespan_list),
        .minute => |a_val| return a_val == b.as.minute,
        .minute_list => |a_val| return std.mem.eql(i32, a_val, b.as.minute_list),
        .second => |a_val| return a_val == b.as.second,
        .second_list => |a_val| return std.mem.eql(i32, a_val, b.as.second_list),
        .time => |a_val| return a_val == b.as.time,
        .time_list => |a_val| return std.mem.eql(i32, a_val, b.as.time_list),

        .dict => |a_val| return a_val.keys.eql(b.as.dict.keys) and a_val.values.eql(b.as.dict.values),
        .table => |a_val| return a_val.keys.eql(b.as.table.keys) and a_val.values.eql(b.as.table.values),
        .lambda => |a_val| return std.mem.eql(u8, a_val.source, b.as.lambda.source),
        .unary_primitive => |a_val| return a_val == b.as.unary_primitive,
        .operator => |a_val| return a_val == b.as.operator,
        .iterator => |a_val| return a_val == b.as.iterator,
        .projection => |a_val| {
            if (!a_val.callee.eql(b.as.projection.callee)) return false;
            if (a_val.args.len != b.as.projection.args.len) return false;
            for (a_val.args, b.as.projection.args) |a_v, b_v| {
                if (!a_v.eql(b_v)) return false;
            }
            return true;
        },
        .each => |a_val| return a_val.value.eql(b.as.each.value),
        .over => |a_val| return a_val.value.eql(b.as.over.value),
        .scan => |a_val| return a_val.value.eql(b.as.scan.value),
        .each_prior => |a_val| return a_val.value.eql(b.as.each_prior.value),
        .each_right => |a_val| return a_val.value.eql(b.as.each_right.value),
        .each_left => |a_val| return a_val.value.eql(b.as.each_left.value),
        .composition => |a_val| return a_val.f.eql(b.as.composition.f) and a_val.g.eql(b.as.composition.g),
    }
}

const FmtOptions = struct {
    skip_empty: bool,
};
const Data = struct { value: *Value, vm: *Vm, options: FmtOptions };

pub fn fmt(value: *Value, vm: *Vm) std.fmt.Alt(Data, format) {
    return fmtOptions(value, vm, .{ .skip_empty = false });
}

pub fn fmtOptions(value: *Value, vm: *Vm, options: FmtOptions) std.fmt.Alt(Data, format) {
    return .{ .data = .{ .value = value, .vm = vm, .options = options } };
}

fn format(data: Data, w: *Io.Writer) Io.Writer.Error!void {
    if (data.options.skip_empty and data.value.isEmpty()) return;
    if (data.value.attr != .none) try w.print("`{t}#", .{data.value.attr});

    switch (data.value.as) {
        .list => |value| switch (value.len) {
            0 => try w.writeAll("()"),
            1 => try w.print(",{f}", .{value[0].fmt(data.vm)}),
            else => {
                try w.writeByte('(');
                try w.print("{f}", .{value[0].fmt(data.vm)});
                for (value[1..]) |v| try w.print(";{f}", .{v.fmt(data.vm)});
                try w.writeByte(')');
            },
        },
        .boolean => |value| try w.writeAll(if (value) "1b" else "0b"),
        .boolean_list => |value| {
            if (value.len == 0) return w.writeAll("`boolean$()");
            if (value.len == 1) try w.writeByte(',');
            for (value) |b| try w.writeByte(if (b) '1' else '0');
            try w.writeByte('b');
        },
        .byte => |value| try w.print("0x{x:0>2}", .{value}),
        .byte_list => |value| {
            if (value.len == 0) return w.writeAll("`byte$()");
            if (value.len == 1) try w.writeByte(',');
            try w.writeAll("0x");
            for (value) |v| try w.print("{x:0>2}", .{v});
        },
        .short => |value| try w.print("{f}h", .{Short.from(value)}),
        .short_list => |value| try formatIntegers(Short, w, value, "`short$()", 'h'),
        .int => |value| try w.print("{f}i", .{Int.from(value)}),
        .int_list => |value| try formatIntegers(Int, w, value, "`int$()", 'i'),
        .long => |value| {
            const long: Long = @fromBackingInt(@intCast(value));
            try w.print("{f}", .{long});
        },
        .long_list => |value| switch (value.len) {
            0 => try w.writeAll("`long$()"),
            1 => try w.print(",{f}", .{@as(Long, @fromBackingInt(@intCast(value[0])))}),
            else => {
                try w.print("{f}", .{@as(Long, @fromBackingInt(@intCast(value[0])))});
                for (value[1..]) |v| try w.print(" {f}", .{@as(Long, @fromBackingInt(@intCast(v)))});
            },
        },
        .real => |value| {
            try formatReal(w, value, data.vm.precision);
            try w.writeByte('e');
        },
        .real_list => |value| {
            if (value.len == 0) return w.writeAll("`real$()");
            if (value.len == 1) try w.writeByte(',');
            for (value, 0..) |v, i| {
                if (i > 0) try w.writeByte(' ');
                try formatReal(w, v, data.vm.precision);
            }
            try w.writeByte('e');
        },
        .float => |value| _ = try formatFloat(w, value, data.vm.precision, true),
        .float_list => |value| {
            if (value.len == 0) return w.writeAll("`float$()");
            if (value.len == 1) try w.writeByte(',');
            // The list takes an f suffix only when every item looks integral.
            var integral = true;
            for (value, 0..) |v, i| {
                if (i > 0) try w.writeByte(' ');
                const is_integral = try formatFloat(w, v, data.vm.precision, false);
                integral = integral and is_integral;
            }
            if (integral) try w.writeByte('f');
        },
        .char => |value| try formatChars(w, &.{value}),
        .char_list => |value| {
            if (value.len == 1) try w.writeByte(',');
            try formatChars(w, value);
        },
        .symbol => |value| try w.print("`{s}", .{data.vm.internedString(value)}),
        .symbol_list => |value| {
            if (value.len == 0) return w.writeAll("`symbol$()");
            if (value.len == 1) try w.writeByte(',');
            for (value) |v| try w.print("`{s}", .{data.vm.internedString(v)});
        },
        .timestamp => |value| try formatTemporal(.timestamp, w, value, false),
        .timestamp_list => |value| try formatTemporalList(.timestamp, w, value),
        .month => |value| try formatTemporal(.month, w, value, false),
        .month_list => |value| try formatTemporalList(.month, w, value),
        .date => |value| try formatTemporal(.date, w, value, false),
        .date_list => |value| try formatTemporalList(.date, w, value),
        .datetime => |value| try formatTemporal(.datetime, w, value, false),
        .datetime_list => |value| try formatTemporalList(.datetime, w, value),
        .timespan => |value| try formatTemporal(.timespan, w, value, false),
        .timespan_list => |value| try formatTemporalList(.timespan, w, value),
        .minute => |value| try formatTemporal(.minute, w, value, false),
        .minute_list => |value| try formatTemporalList(.minute, w, value),
        .second => |value| try formatTemporal(.second, w, value, false),
        .second_list => |value| try formatTemporalList(.second, w, value),
        .time => |value| try formatTemporal(.time, w, value, false),
        .time_list => |value| try formatTemporalList(.time, w, value),
        .dict => |value| try w.print("{f}", .{value.fmt(data.vm)}),
        // A table shows as the flip of its column dictionary: `+`a`b!(1 2;3 4)`.
        .table => |value| try w.print("+{f}", .{value.fmt(data.vm)}),
        .lambda => |value| try w.print("{s}", .{value.source}),
        .unary_primitive => |value| try w.print("{f}", .{value}),
        .operator => |value| try w.print("{f}", .{value}),
        .projection => |value| {
            try w.print("{f}[{f}", .{
                value.callee.fmt(data.vm),
                value.args[0].fmtOptions(data.vm, .{ .skip_empty = true }),
            });
            for (value.args[1..]) |v| try w.print(";{f}", .{v.fmtOptions(data.vm, .{ .skip_empty = true })});
            try w.writeByte(']');
        },
        .iterator => |value| try w.print("{f}", .{value}),
        // A derived function is its function followed by the iterator: `+/`, `{x}'`.
        .each => |d| try w.print("{f}'", .{d.value.fmt(data.vm)}),
        .over => |d| try w.print("{f}/", .{d.value.fmt(data.vm)}),
        .scan => |d| try w.print("{f}\\", .{d.value.fmt(data.vm)}),
        .each_prior => |d| try w.print("{f}':", .{d.value.fmt(data.vm)}),
        .each_right => |d| try w.print("{f}/:", .{d.value.fmt(data.vm)}),
        .each_left => |d| try w.print("{f}\\:", .{d.value.fmt(data.vm)}),
        .composition => |c| {
            // The left function drops its trailing colon, as q shows `-_-:`, `#-:`, `@+[1]`.
            if (c.f.as == .unary_primitive) {
                var buffer: [16]u8 = undefined;
                var fixed: Io.Writer = .fixed(&buffer);
                try c.f.as.unary_primitive.format(&fixed);
                const text = fixed.buffered();
                try w.writeAll(if (text.len > 0 and text[text.len - 1] == ':') text[0 .. text.len - 1] else text);
            } else {
                try w.print("{f}", .{c.f.fmt(data.vm)});
            }
            try w.print("{f}", .{c.g.fmt(data.vm)});
        },
    }
}

/// Writes a short or int list: the items, then the type letter, as `1 0Nh`.
fn formatIntegers(comptime I: type, w: *Io.Writer, list: anytype, empty: []const u8, suffix: u8) Io.Writer.Error!void {
    if (list.len == 0) return w.writeAll(empty);
    if (list.len == 1) try w.writeByte(',');
    for (list, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{f}", .{I.from(v)});
    }
    try w.writeByte(suffix);
}

/// Writes chars in double quotes the way q displays them: `"` and `\` are backslashed,
/// newline, tab and return are `\n`, `\t` and `\r`, and other control characters are
/// three-digit octal escapes such as `\001`, and so do bytes above 127 (`"\310"`).
fn formatChars(w: *Io.Writer, chars: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (chars) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...31, 127...255 => try w.print("\\{o:0>3}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Writes a float with `precision` significant digits, as q's `\P` shows it, or `0n`, `0w`
/// and `-0w`. Returns whether the text looks integral, in which case q marks an atom with an
/// `f` suffix; the suffix is written here only when `suffix` is set.
fn formatFloat(w: *Io.Writer, value: f64, precision: u8, suffix: bool) Io.Writer.Error!bool {
    if (std.math.isNan(value)) {
        try w.writeAll("0n");
        return false;
    }
    if (std.math.isInf(value)) {
        try w.writeAll(if (value < 0) "-0w" else "0w");
        return false;
    }
    const integral = try q.decimal.formatG(w, value, precision);
    if (integral and suffix) try w.writeByte('f');
    return integral;
}

/// Writes one real without its `e` suffix. Reals follow `\P` through their double value,
/// except that `\P 0` shows the shortest text that reads back as the same real, and a null
/// real prints as `0N`.
fn formatReal(w: *Io.Writer, value: f32, precision: u8) Io.Writer.Error!void {
    if (std.math.isNan(value)) {
        try w.writeAll("0N");
    } else if (std.math.isNegativeInf(value)) {
        try w.writeAll("-0w");
    } else if (std.math.isPositiveInf(value)) {
        try w.writeAll("0w");
    } else if (precision == 0) {
        try q.decimal.formatShortestReal(w, value);
    } else {
        _ = try q.decimal.formatG(w, value, precision);
    }
}

const literal = q.literal;

fn formatTemporalList(comptime tag: Type, w: *Io.Writer, list: anytype) Io.Writer.Error!void {
    if (list.len == 0) return w.print("`{s}$()", .{@tagName(tag)});
    if (list.len == 1) try w.writeByte(',');
    for (list, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try formatTemporal(tag, w, v, true);
    }
    // Months are the one temporal type whose letter is part of every atom, so a list of
    // them ends in a single `m`, as `2023.04 2023.05m`.
    if (tag == .month) try w.writeByte('m');
}

/// Writes a temporal atom the way q displays it. Nulls and infinities carry the type letter
/// as atoms (`0Nd`, `0Wp`) but print bare (`0N`, `0W`) as items of a list.
fn formatTemporal(comptime tag: Type, w: *Io.Writer, value: anytype, in_list: bool) Io.Writer.Error!void {
    const letter: u8 = switch (tag) {
        .timestamp => 'p',
        .month => 'm',
        .date => 'd',
        .datetime => 'z',
        .timespan => 'n',
        .minute => 'u',
        .second => 'v',
        .time => 't',
        else => comptime unreachable,
    };
    const special: ?[]const u8 = if (@TypeOf(value) == f64)
        (if (std.math.isNan(value)) "0N" else if (std.math.isPositiveInf(value)) "0w" else if (std.math.isNegativeInf(value)) "-0w" else null)
    else switch (Integer(@TypeOf(value)).from(value)) {
        .null => "0N",
        .inf => "0W",
        .neg_inf => "-0W",
        else => null,
    };
    if (special) |text| {
        try w.writeAll(text);
        if (!in_list) try w.writeByte(letter);
        return;
    }
    switch (tag) {
        .date => try formatDate(w, value),
        .month => {
            const months: i64 = value;
            try w.print("{d:0>4}.{d:0>2}", .{
                @as(u64, @intCast(2000 + @divFloor(months, 12))),
                @as(u64, @intCast(@mod(months, 12) + 1)),
            });
            if (!in_list) try w.writeByte('m');
        },
        .timestamp => {
            try formatDate(w, @divFloor(value, literal.ns_per_day));
            try w.writeByte('D');
            try formatTimeOfDay(w, @mod(value, literal.ns_per_day), .nano);
        },
        .datetime => {
            const millis: i64 = @intFromFloat(@round(value * @as(f64, @floatFromInt(literal.ms_per_day))));
            try formatDate(w, @divFloor(millis, literal.ms_per_day));
            try w.writeByte('T');
            try formatTimeOfDay(w, @mod(millis, literal.ms_per_day) * 1_000_000, .milli);
        },
        .timespan => {
            const nanos: i64 = value;
            if (nanos < 0) try w.writeByte('-');
            const magnitude = @abs(nanos);
            try w.print("{d}D", .{magnitude / @as(u64, @intCast(literal.ns_per_day))});
            try formatTimeOfDay(w, @intCast(magnitude % @as(u64, @intCast(literal.ns_per_day))), .nano);
        },
        .minute => try formatTimeOfDay(w, @as(i64, value) * 60 * literal.ns_per_second, .minute),
        .second => try formatTimeOfDay(w, @as(i64, value) * literal.ns_per_second, .second),
        .time => try formatTimeOfDay(w, @as(i64, value) * 1_000_000, .milli),
        else => comptime unreachable,
    }
}

/// `YYYY.MM.DD` of a day count since 2000.01.01.
fn formatDate(w: *Io.Writer, days: i64) Io.Writer.Error!void {
    const civil = literal.civilFromDays(days + literal.epoch_days);
    // Zero padding of a signed integer prints its sign, so format the (positive) fields unsigned.
    try w.print("{d:0>4}.{d:0>2}.{d:0>2}", .{
        @as(u64, @intCast(civil.year)),
        @as(u64, @intCast(civil.month)),
        @as(u64, @intCast(civil.day)),
    });
}

const TimePrecision = enum { minute, second, milli, nano };

/// `hh:mm`, `hh:mm:ss`, `hh:mm:ss.mmm` or `hh:mm:ss.nnnnnnnnn` of a (possibly negative)
/// nanosecond count. Hours are not wrapped at 24, so `25:08` is a valid minute.
fn formatTimeOfDay(w: *Io.Writer, nanos: i64, precision: TimePrecision) Io.Writer.Error!void {
    if (nanos < 0) try w.writeByte('-');
    const total: u64 = @abs(nanos);
    const ns_per_second: u64 = @intCast(literal.ns_per_second);
    const seconds = total / ns_per_second;
    try w.print("{d:0>2}:{d:0>2}", .{ seconds / 3600, seconds / 60 % 60 });
    switch (precision) {
        .minute => {},
        .second => try w.print(":{d:0>2}", .{seconds % 60}),
        .milli => try w.print(":{d:0>2}.{d:0>3}", .{ seconds % 60, total % ns_per_second / 1_000_000 }),
        .nano => try w.print(":{d:0>2}.{d:0>9}", .{ seconds % 60, total % ns_per_second }),
    }
}

pub fn rank(value: *Value) usize {
    // TODO: Should non-applicable values return 'type?
    return switch (value.as) {
        .list => 1,
        .boolean => 1,
        .boolean_list => 1,
        .byte => 1,
        .byte_list => 1,
        .short => 1,
        .short_list => 1,
        .int => 1,
        .int_list => 1,
        .long => 1,
        .long_list => 1,
        .real => 1,
        .real_list => 1,
        .float => 1,
        .float_list => 1,
        .char => 1,
        .char_list => 1,
        .symbol => 1,
        .symbol_list => 1,
        .timestamp => 1,
        .timestamp_list => 1,
        .month => 1,
        .month_list => 1,
        .date => 1,
        .date_list => 1,
        .datetime => 1,
        .datetime_list => 1,
        .timespan => 1,
        .timespan_list => 1,
        .minute => 1,
        .minute_list => 1,
        .second => 1,
        .second_list => 1,
        .time => 1,
        .time_list => 1,
        .dict => 1,
        .table => 1,
        .lambda => |lambda| lambda.params.len,
        .unary_primitive => 1,
        // `.` and `@` also have their amend and trap forms of three and four arguments.
        .operator => |o| if (o == .apply or o == .apply_at) 4 else 2,
        .iterator => 1,
        // A projection still needs the arguments its holes and the callee's remaining
        // parameters stand for: `+[1]` takes one.
        .projection => |projection| rank: {
            var filled: usize = 0;
            for (projection.args) |a| filled += @intFromBool(!a.isEmpty());
            // A projection of `enlist` has as many slots as it was given, so it still
            // needs its holes; anything else needs what its callee has left.
            const variadic = projection.callee.as == .unary_primitive and projection.callee.as.unary_primitive == .enlist;
            break :rank if (variadic) projection.args.len - filled else projection.callee.rank() -| filled;
        },
        // Each takes what its function takes. A fold takes a seed and one list per remaining
        // parameter, so as many arguments as its function, and at least two for a monadic
        // function (`f/[n;x]`). The others take one or two arguments.
        .each => |d| d.value.rank(),
        .over => |d| @max(2, d.value.rank()),
        .scan => |d| @max(2, d.value.rank()),
        .each_prior => 2,
        // With data on the left (`" "\:`) the derived function takes one argument.
        inline .each_right, .each_left => |d| if (Vm.isFunction(d.value)) 2 else 1,
        // The right function takes the arguments.
        .composition => |c| c.g.rank(),
    };
}

/// The rows of a table: the count of its first column, none without columns.
pub fn rows(table: Dictionary) usize {
    const columns = table.values.as.list;
    return if (columns.len == 0) 0 else columns[0].count();
}

pub fn count(value: *Value) usize {
    return switch (value.as) {
        .list => |v| v.len,
        .boolean => 1,
        .boolean_list => |v| v.len,
        .byte => 1,
        .byte_list => |v| v.len,
        .short => 1,
        .short_list => |v| v.len,
        .int => 1,
        .int_list => |v| v.len,
        .long => 1,
        .long_list => |v| v.len,
        .real => 1,
        .real_list => |v| v.len,
        .float => 1,
        .float_list => |v| v.len,
        .char => 1,
        .char_list => |v| v.len,
        .symbol => 1,
        .symbol_list => |v| v.len,
        .timestamp => 1,
        .timestamp_list => |v| v.len,
        .month => 1,
        .month_list => |v| v.len,
        .date => 1,
        .date_list => |v| v.len,
        .datetime => 1,
        .datetime_list => |v| v.len,
        .timespan => 1,
        .timespan_list => |v| v.len,
        .minute => 1,
        .minute_list => |v| v.len,
        .second => 1,
        .second_list => |v| v.len,
        .time => 1,
        .time_list => |v| v.len,
        .dict => |v| v.keys.count(),
        .table => |v| rows(v),
        .lambda => 1,
        .unary_primitive => 1,
        .operator => 1,
        .iterator => 1,
        .projection => 1,
        .each => 1,
        .over => 1,
        .scan => 1,
        .each_prior => 1,
        .each_right => 1,
        .each_left => 1,
        .composition => 1,
    };
}

pub const Type = enum(i8) {
    list = 0,
    boolean = -1,
    boolean_list = 1,
    // guid = -2,
    // guid_list = 2,
    byte = -4,
    byte_list = 4,
    short = -5,
    short_list = 5,
    int = -6,
    int_list = 6,
    long = -7,
    long_list = 7,
    real = -8,
    real_list = 8,
    float = -9,
    float_list = 9,
    char = -10,
    char_list = 10,
    symbol = -11,
    symbol_list = 11,
    timestamp = -12,
    timestamp_list = 12,
    month = -13,
    month_list = 13,
    date = -14,
    date_list = 14,
    datetime = -15,
    datetime_list = 15,
    timespan = -16,
    timespan_list = 16,
    minute = -17,
    minute_list = 17,
    second = -18,
    second_list = 18,
    time = -19,
    time_list = 19,
    table = 98,
    dict = 99,
    lambda = 100,
    unary_primitive = 101,
    operator = 102,
    iterator = 103,
    projection = 104,
    composition = 105,
    each = 106,
    over = 107,
    scan = 108,
    each_prior = 109,
    each_right = 110,
    each_left = 111,
};

pub const Union = union(Type) {
    list: []*Value,
    boolean: bool,
    boolean_list: []bool,
    byte: u8,
    byte_list: []u8,
    short: i16,
    short_list: []i16,
    int: i32,
    int_list: []i32,
    long: i64,
    long_list: []i64,
    real: f32,
    real_list: []f32,
    float: f64,
    float_list: []f64,
    char: u8,
    char_list: []u8,
    symbol: Symbol,
    symbol_list: []Symbol,
    timestamp: i64,
    timestamp_list: []i64,
    month: i32,
    month_list: []i32,
    date: i32,
    date_list: []i32,
    datetime: f64,
    datetime_list: []f64,
    timespan: i64,
    timespan_list: []i64,
    minute: i32,
    minute_list: []i32,
    second: i32,
    second_list: []i32,
    time: i32,
    time_list: []i32,
    /// Column names (a symbol list) and columns (a general list of lists of one length),
    /// the flip of a column dictionary.
    table: Dictionary,
    dict: Dictionary,
    lambda: Lambda,
    unary_primitive: UnaryPrimitive,
    operator: Operator,
    iterator: Iterator,
    projection: Projection,
    composition: Composition,
    each: Each,
    over: Over,
    scan: Scan,
    each_prior: EachPrior,
    each_right: EachRight,
    each_left: EachLeft,
};

/// A signed integer type with q's null and infinities at its extremes: `0N` is the minimum,
/// `0W` the maximum and `-0W` its negation.
pub fn Integer(comptime T: type) type {
    return enum(T) {
        null = std.math.minInt(T),
        neg_inf = -std.math.maxInt(T),
        inf = std.math.maxInt(T),
        _,

        const Self = @This();

        pub fn from(value: T) Self {
            return @fromBackingInt(value);
        }

        pub fn parseStrict(buf: []const u8) !Self {
            switch (buf.len) {
                2 => if (buf[0] == '0') switch (buf[1]) {
                    'N' => return .null,
                    'W' => return .inf,
                    else => {},
                },
                3 => if (buf[0] == '-' and buf[1] == '0' and std.ascii.toLower(buf[2]) == 'w') return .neg_inf,
                else => {},
            }
            return @fromBackingInt(@intCast(try std.fmt.parseInt(T, buf, 10)));
        }

        /// Writes the value without any type suffix.
        pub fn format(self: Self, w: *Io.Writer) !void {
            switch (self) {
                .null => try w.writeAll("0N"),
                .neg_inf => try w.writeAll("-0W"),
                .inf => try w.writeAll("0W"),
                else => try w.print("{d}", .{@backingInt(self)}),
            }
        }
    };
}

pub const Short = Integer(i16);
pub const Int = Integer(i32);
pub const Long = Integer(i64);

pub const Symbol = enum(u32) {
    empty = 0,
    dot = 1,
    _,
};

pub const Dictionary = struct {
    keys: *Value,
    values: *Value,

    const Data = struct { dict: Dictionary, vm: *Vm };

    pub fn fmt(self: Dictionary, vm: *Vm) std.fmt.Alt(Dictionary.Data, Dictionary.format) {
        return .{ .data = .{ .dict = self, .vm = vm } };
    }

    fn format(data: Dictionary.Data, w: *Io.Writer) !void {
        // q parenthesises keys whose display would not read as one operand: a typed empty
        // (`` (`symbol$())!`long$() ``) or a typed singleton (`` (,`a)!,1 ``). A general
        // list brings its own parentheses and a singleton general list stays bare.
        const keys = data.dict.keys;
        const wrap = keys.as == .table or (keys.isList() and keys.as != .list and keys.count() < 2);
        if (wrap) try w.writeByte('(');
        try w.print("{f}", .{keys.fmt(data.vm)});
        if (wrap) try w.writeByte(')');
        try w.print("!{f}", .{data.dict.values.fmt(data.vm)});
    }
};

pub const Lambda = struct {
    bytecode: []const u8,
    params: []const Symbol,
    locals: []const Symbol,
    globals: []const Symbol,
    constants: []*Value,
    namespace: Symbol,
    source: []const u8,
};

pub const UnaryPrimitive = enum {
    identity, // ::
    flip, // +:
    neg, // -:
    first, // *:
    reciprocal, // %:
    where, // &:
    reverse, // |:
    null, // ^:
    group, // =:
    asc, // <:
    desc, // >:
    string, // $:
    list, // ,:
    count, // #:
    lower, // _:
    not, // ~:
    key, // !:
    distinct, // ?:
    type, // @:
    value, // .:
    read_text, // 0::
    read_binary, // 1::

    _unused,

    // Natives of `.Q.res`, which print by name.
    avg,
    last,
    sum,
    prd,
    min,
    max,
    exit,
    getenv,
    abs,
    sqrt,
    log,
    exp,
    sin,
    asin,
    cos,
    acos,
    tan,
    atan,
    enlist,
    @"var",
    dev,
    hopen,

    empty,

    pub fn format(self: UnaryPrimitive, w: *Io.Writer) !void {
        switch (self) {
            .identity, .empty => try w.writeAll("::"),
            .flip => try w.writeAll("+:"),
            .neg => try w.writeAll("-:"),
            .first => try w.writeAll("*:"),
            .reciprocal => try w.writeAll("%:"),
            .where => try w.writeAll("&:"),
            .reverse => try w.writeAll("|:"),
            .null => try w.writeAll("^:"),
            .group => try w.writeAll("=:"),
            .asc => try w.writeAll("<:"),
            .desc => try w.writeAll(">:"),
            .string => try w.writeAll("$:"),
            .list => try w.writeAll(",:"),
            .count => try w.writeAll("#:"),
            .lower => try w.writeAll("_:"),
            .not => try w.writeAll("~:"),
            .key => try w.writeAll("!:"),
            .distinct => try w.writeAll("?:"),
            .type => try w.writeAll("@:"),
            .value => try w.writeAll(".:"),
            .read_text => try w.writeAll("0::"),
            .read_binary => try w.writeAll("1::"),

            ._unused => unreachable,

            inline .avg,
            .last,
            .sum,
            .prd,
            .min,
            .max,
            .exit,
            .getenv,
            .abs,
            .sqrt,
            .log,
            .exp,
            .sin,
            .asin,
            .cos,
            .acos,
            .tan,
            .atan,
            .enlist,
            .@"var",
            .dev,
            .hopen,
            => |t| try w.writeAll(@tagName(t)),
        }
    }
};

pub const Operator = enum {
    assign, // :
    add, // +
    subtract, // -
    multiply, // *
    divide, // %
    @"and", // &
    @"or", // |
    fill, // ^
    equal, // =
    less_than, // <
    greater_than, // >
    cast, // $
    join, // ,
    take, // #
    drop, // _
    match, // ~
    dict, // !
    find, // ?
    apply_at, // @
    apply, // .
    file_text, // 0:
    file_binary, // 1:
    dynamic_load, // 2:

    // Named operators: the dyadic natives of `.Q.res`.
    in,
    within,
    like,
    bin,
    ss,
    insert,
    wsum,
    wavg,
    div,
    xexp,
    setenv,
    binr,
    cov,
    cor,

    pub fn format(self: Operator, w: *Io.Writer) !void {
        switch (self) {
            .assign => try w.writeByte(':'),
            .add => try w.writeByte('+'),
            .subtract => try w.writeByte('-'),
            .multiply => try w.writeByte('*'),
            .divide => try w.writeByte('%'),
            .@"and" => try w.writeByte('&'),
            .@"or" => try w.writeByte('|'),
            .fill => try w.writeByte('^'),
            .equal => try w.writeByte('='),
            .less_than => try w.writeByte('<'),
            .greater_than => try w.writeByte('>'),
            .cast => try w.writeByte('$'),
            .join => try w.writeByte(','),
            .take => try w.writeByte('#'),
            .drop => try w.writeByte('_'),
            .match => try w.writeByte('~'),
            .dict => try w.writeByte('!'),
            .find => try w.writeByte('?'),
            .apply_at => try w.writeByte('@'),
            .apply => try w.writeByte('.'),
            .file_text => try w.writeAll("0:"),
            .file_binary => try w.writeAll("1:"),
            .dynamic_load => try w.writeAll("2:"),

            inline .in,
            .within,
            .like,
            .bin,
            .ss,
            .insert,
            .wsum,
            .wavg,
            .div,
            .xexp,
            .setenv,
            .binr,
            .cov,
            .cor,
            => |t| try w.writeAll(@tagName(t)),
        }
    }
};

pub const Iterator = enum {
    each, // '
    over, // /
    scan, // \
    each_prior, // ':
    each_right, // /:
    each_left, // \:

    pub fn format(self: Iterator, w: *Io.Writer) !void {
        switch (self) {
            .each => try w.writeByte('\''),
            .over => try w.writeByte('/'),
            .scan => try w.writeByte('\\'),
            .each_prior => try w.writeAll("':"),
            .each_right => try w.writeAll("/:"),
            .each_left => try w.writeAll("\\:"),
        }
    }
};

pub const Projection = struct {
    callee: *Value,
    args: []const *Value,
};

pub const Each = struct {
    value: *Value,
};

pub const Over = struct {
    value: *Value,
};

pub const Scan = struct {
    value: *Value,
};

pub const EachPrior = struct {
    value: *Value,
};

pub const EachRight = struct {
    value: *Value,
};

/// `f g` composed: `g` takes the arguments and `f` its result, as `-_-:` rounds up.
pub const Composition = struct {
    f: *Value,
    g: *Value,
};

pub const EachLeft = struct {
    value: *Value,
};
