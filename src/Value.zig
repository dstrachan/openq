const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Vm = q.Vm;

const Value = @This();

ref_count: u32 = 0,
as: Union,

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
            .long,
            .float,
            .char,
            .symbol,
            .unary_primitive,
            .operator,
            .iterator,
            => {},
            inline .boolean_list,
            .long_list,
            .float_list,
            .char_list,
            .symbol_list,
            => |list| gpa.free(list),
            .dict => |val| {
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
        }
        gpa.destroy(value);
    }
}

const Data = struct { value: *Value, vm: *Vm };

pub fn fmt(value: *Value, vm: *Vm) std.fmt.Alt(Data, format) {
    return .{ .data = .{ .value = value, .vm = vm } };
}

fn format(data: Data, w: *Io.Writer) Io.Writer.Error!void {
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
        .long => |value| {
            const long: Long = @enumFromInt(value);
            try w.print("{f}", .{long});
        },
        .float => |value| {
            if (std.math.isNan(value)) {
                try w.writeAll("0n");
            } else if (std.math.isNegativeInf(value)) {
                try w.writeAll("-0w");
            } else if (std.math.isPositiveInf(value)) {
                try w.writeAll("0w");
            } else if (std.math.floor(value) == value) {
                try w.print("{d}f", .{value});
            } else {
                try w.print("{d}", .{value});
            }
        },
        .operator => |value| try w.print("{f}", .{value}),
        inline else => |_, t| @panic("NYI " ++ @tagName(t)),
    }
}

pub const Type = enum(i8) {
    list = 0,
    boolean = -1,
    boolean_list = 1,
    // guid = -2,
    // guid_list = 2,
    // byte = -4,
    // byte_list = 4,
    // short = -5,
    // short_list = 5,
    // int = -6,
    // int_list = 6,
    long = -7,
    long_list = 7,
    // real = -8,
    // real_list = 8,
    float = -9,
    float_list = 9,
    char = -10,
    char_list = 10,
    symbol = -11,
    symbol_list = 11,
    // timestamp = -12,
    // timestamp_list = 12,
    // month = -13,
    // month_list = 13,
    // date = -14,
    // date_list = 14,
    // datetime = -15,
    // datetime_list = 15,
    // timespan = -16,
    // timespan_list = 16,
    // minute = -17,
    // minute_list = 17,
    // second = -18,
    // second_list = 18,
    // time = -19,
    // time_list = 19,
    // table = 98,
    dict = 99,
    lambda = 100,
    unary_primitive = 101,
    operator = 102,
    iterator = 103,
    projection = 104,
    // composition = 105,
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
    long: i64,
    long_list: []i64,
    float: f64,
    float_list: []f64,
    char: u8,
    char_list: []u8,
    symbol: Symbol,
    symbol_list: []Symbol,
    dict: Dictionary,
    lambda: Lambda,
    unary_primitive: UnaryPrimitive,
    operator: Operator,
    iterator: Iterator,
    projection: Projection,
    each: Each,
    over: Over,
    scan: Scan,
    each_prior: EachPrior,
    each_right: EachRight,
    each_left: EachLeft,
};

pub const Long = enum(i64) {
    null = std.math.minInt(i64),
    neg_inf = -std.math.maxInt(i64),
    inf = std.math.maxInt(i64),
    _,

    pub fn parseStrict(buf: []const u8) !Long {
        switch (buf.len) {
            2 => if (buf[0] == '0') switch (buf[1]) {
                'N' => return .null,
                'W' => return .inf,
                else => {},
            },
            3 => if (buf[0] == '-' and buf[1] == '0' and std.ascii.toLower(buf[2]) == 'w') return .neg_inf,
            else => {},
        }
        return @enumFromInt(try std.fmt.parseInt(i64, buf, 10));
    }

    pub fn format(long: Long, w: *Io.Writer) !void {
        switch (long) {
            .null => try w.writeAll("0N"),
            .neg_inf => try w.writeAll("-0W"),
            .inf => try w.writeAll("0W"),
            else => try w.print("{d}", .{@intFromEnum(long)}),
        }
    }
};

pub const Symbol = enum(u32) {
    empty = 0,
    _,
};

pub const Dictionary = struct {
    keys: *Value,
    values: *Value,
};

pub const Lambda = struct {
    bytecode: []const u8,
    params: []const Symbol,
    locals: []const Symbol,
    globals: []const Symbol,
    constants: []*Value,
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

pub const EachLeft = struct {
    value: *Value,
};
