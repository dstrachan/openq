const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;
const Chunk = q.Chunk;
const OpCode = Chunk.OpCode;
const Qir = q.Qir;

const build_options = @import("build_options");

const Vm = @This();

pub const StackMax = 256;

gpa: Allocator,
chunk: *Chunk,
ip: [*]u8,
stack: std.ArrayListUnmanaged(*Value),
symbols: std.StringHashMapUnmanaged(void) = .empty,

var stdio_buffer: [4096]u8 = undefined;

pub const Error = Allocator.Error || error{
    UndeclaredIdentifier,
};

pub fn init(vm: *Vm, gpa: Allocator) !void {
    const buf = try gpa.alloc(*Value, StackMax);
    errdefer comptime unreachable;

    vm.* = .{
        .gpa = gpa,
        .chunk = undefined,
        .ip = undefined,
        .stack = .initBuffer(buf),
    };
}

pub fn deinit(vm: *Vm) void {
    vm.stack.deinit(vm.gpa);
    var it = vm.symbols.keyIterator();
    while (it.next()) |entry| vm.gpa.free(entry.*);
    vm.symbols.deinit(vm.gpa);
}

fn push(vm: *Vm, value: *Value) void {
    if (vm.stack.items.len == vm.stack.capacity) {
        // TODO: print stack trace.
        @panic("stack");
    }
    vm.stack.appendAssumeCapacity(value);
}

fn pop(vm: *Vm) *Value {
    return vm.stack.pop().?;
}

pub fn interpret(vm: *Vm, qir: *Qir) !void {
    assert(!qir.hasCompileErrors());

    vm.chunk = &qir.chunk;
    vm.ip = qir.chunk.data.items(.code).ptr;

    vm.run() catch return error.RunError;
}

fn run(vm: *Vm) !void {
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdio_buffer);
    const stdout_bw = &stdout_writer.interface;

    while (true) {
        if (build_options.trace_execution) {
            try stdout_bw.writeAll("          ");
            for (vm.stack.items) |slot| {
                try stdout_bw.print("[ {f} ({d}) ]", .{ slot, slot.ref_count });
            }
            try stdout_bw.writeByte('\n');
            _ = try vm.chunk.disassembleInstruction(stdout_bw, vm.ip - vm.chunk.data.items(.code).ptr);
        }
        try stdout_bw.flush();

        const instruction: OpCode = @enumFromInt(vm.readByte());
        switch (instruction) {
            .constant => vm.push(vm.readConstant()),

            .add => try vm.binary(add),
            .subtract => try vm.binary(subtract),
            .multiply => try vm.binary(multiply),
            .divide => try vm.binary(divide),
            .concat => try vm.binary(concat),
            .match => try vm.binary(match),
            .apply => try vm.binary(apply),

            .flip => try vm.unary(flip),
            .negate => try vm.unary(negate),
            .first => try vm.unary(first),
            .reciprocal => try vm.unary(reciprocal),
            .enlist => try vm.unary(enlist),
            .not => try vm.unary(not),
            .type => try vm.unary(@"type"),

            .@"return" => {
                var value = vm.pop();
                defer value.deref(vm.gpa);

                try stdout_bw.print("{f}", .{value});
                try stdout_bw.flush();
                return;
            },
        }
    }
}

inline fn readByte(vm: *Vm) u8 {
    const byte = vm.ip[0];
    vm.ip += 1;
    return byte;
}

inline fn readConstant(vm: *Vm) *Value {
    return vm.chunk.constants.items[vm.readByte()];
}

inline fn unary(vm: *Vm, f: *const fn (*Vm, *Value) anyerror!*Value) !void {
    var x = vm.pop();
    defer x.deref(vm.gpa);

    vm.push(try f(vm, x));
}

inline fn binary(vm: *Vm, f: *const fn (*Vm, *Value, *Value) anyerror!*Value) !void {
    var x = vm.pop();
    defer x.deref(vm.gpa);
    var y = vm.pop();
    defer y.deref(vm.gpa);

    vm.push(try f(vm, x, y));
}

fn add(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createLong(x.as.long + y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(@as(f64, @floatFromInt(x.as.long)) + y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createFloat(x.as.float + @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(x.as.float + y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn subtract(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createLong(x.as.long - y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(@as(f64, @floatFromInt(x.as.long)) - y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createFloat(x.as.float - @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(x.as.float - y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn multiply(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createLong(x.as.long * y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(@as(f64, @floatFromInt(x.as.long)) * y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createFloat(x.as.float * @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(x.as.float * y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn divide(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createFloat(@as(f64, @floatFromInt(x.as.long)) / @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(@as(f64, @floatFromInt(x.as.long)) / y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => vm.createFloat(x.as.float / @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => vm.createFloat(x.as.float / y.as.float),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn concat(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => @panic("NYI"),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => @panic("NYI"),
        .float_list => @panic("NYI"),
        .char => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => blk: {
                const bytes = try vm.gpa.alloc(u8, 2);
                bytes[0] = x.as.char;
                bytes[1] = y.as.char;
                break :blk vm.createCharList(bytes);
            },
            .char_list => blk: {
                const bytes = try vm.gpa.alloc(u8, 1 + y.as.char_list.len);
                bytes[0] = x.as.char;
                @memcpy(bytes[1..], y.as.char_list);
                break :blk vm.createCharList(bytes);
            },
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .char_list => switch (y.type) {
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => blk: {
                const bytes = try vm.gpa.alloc(u8, x.as.char_list.len + 1);
                @memcpy(bytes[0..x.as.char_list.len], x.as.char_list);
                bytes[x.as.char_list.len] = y.as.char;
                break :blk vm.createCharList(bytes);
            },
            .char_list => blk: {
                const bytes = try vm.gpa.alloc(u8, x.as.char_list.len + y.as.char_list.len);
                @memcpy(bytes[0..x.as.char_list.len], x.as.char_list);
                @memcpy(bytes[x.as.char_list.len..], y.as.char_list);
                break :blk vm.createCharList(bytes);
            },
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn match(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.NYI;
}

fn apply(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.NYI;
}

fn flip(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.NYI;
}

fn negate(vm: *Vm, x: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => vm.createLong(-x.as.long),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => vm.createFloat(-x.as.float),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn first(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.NYI;
}

fn reciprocal(vm: *Vm, x: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => vm.createFloat(1 / @as(f64, @floatFromInt(x.as.long))),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => vm.createFloat(1 / x.as.float),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn enlist(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.NYI;
}

fn not(vm: *Vm, x: *Value) !*Value {
    return switch (x.type) {
        .mixed_list => @panic("NYI"),
        .boolean => vm.createBoolean(!x.as.boolean),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => vm.createBoolean(x.as.long == 0),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => @panic("NYI"),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn @"type"(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.NYI;
}

pub inline fn createBoolean(vm: *Vm, value: bool) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .boolean, .as = .{ .boolean = value } };
    return v;
}

pub inline fn createGuid(vm: *Vm, value: [16]u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .guid, .as = .{ .guid = value } };
    return v;
}

pub inline fn createByte(vm: *Vm, value: u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .byte, .as = .{ .byte = value } };
    return v;
}

pub inline fn createShort(vm: *Vm, value: i16) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .short, .as = .{ .short = value } };
    return v;
}

pub inline fn createInt(vm: *Vm, value: i32) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .int, .as = .{ .int = value } };
    return v;
}

pub inline fn createLong(vm: *Vm, value: i64) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .long, .as = .{ .long = value } };
    return v;
}

pub inline fn createReal(vm: *Vm, value: f32) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .real, .as = .{ .real = value } };
    return v;
}

pub inline fn createFloat(vm: *Vm, value: f64) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .float, .as = .{ .float = value } };
    return v;
}

pub inline fn createChar(vm: *Vm, value: u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .char, .as = .{ .char = value } };
    return v;
}

pub inline fn createCharList(vm: *Vm, value: []u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .char_list, .as = .{ .char_list = value } };
    return v;
}

pub inline fn createSymbol(vm: *Vm, value: []u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .symbol, .as = .{ .symbol = value } };
    return v;
}
