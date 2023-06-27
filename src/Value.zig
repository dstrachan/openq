const std = @import("std");

const Chunk = @import("Chunk.zig");

const Self = @This();
const Value = Self;

reference_count: usize,
as: ValueUnion,

pub const ValueType = enum {
    nil,
    boolean,
    boolean_list,
    guid,
    byte,
    byte_list,
    short,
    int,
    long,
    real,
    float,
    char,
    symbol,
    timestamp,
    month,
    date,
    datetime,
    timespan,
    minute,
    second,
    time,

    function,
};

pub const ValueUnion = union(ValueType) {
    nil,

    boolean: bool,
    boolean_list: []bool,

    guid: [16]u8,

    byte: u8,
    byte_list: []u8,
    char: u8,

    short: i16,

    int: i32,
    month: i32,
    date: i32,
    minute: i32,
    second: i32,
    time: i32,

    long: i64,
    timestamp: i64,
    timespan: i64,

    real: f32,

    float: f64,
    datetime: f64,

    symbol: []const u8,

    function: *ValueFunction,
};

const Config = struct {
    reference_count: u32 = 1,
    data: ValueUnion,
};

pub fn init(config: Config, allocator: std.mem.Allocator) *Self {
    const self = allocator.create(Self) catch std.debug.panic("Failed to create value.", .{});
    self.* = .{
        .reference_count = config.reference_count,
        .as = config.data,
    };
    return self;
}

pub fn ref(self: *Self) *Self {
    self.reference_count += 1;
    return self;
}

pub fn deref(self: *Self, allocator: std.mem.Allocator) void {
    self.reference_count -= 1;
    if (self.reference_count == 0) {
        switch (self.as) {
            .nil,
            .boolean,
            .guid,
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
            => {},
            .boolean_list => |list| allocator.free(list),
            .byte_list => |list| allocator.free(list),
            .function => |function| function.deinit(allocator),
        }
        allocator.destroy(self);
    }
}

pub const ValueFunction = struct {
    arity: u8,
    local_count: u8,
    chunk: *Chunk,
    name: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) *ValueFunction {
        const self = allocator.create(ValueFunction) catch std.debug.panic("Failed to create function.", .{});
        self.* = .{
            .arity = 0,
            .local_count = 0,
            .chunk = Chunk.init(allocator),
            .name = null,
        };
        return self;
    }

    pub fn deinit(self: *ValueFunction, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.chunk.deinit();
        allocator.destroy(self);
    }
};
