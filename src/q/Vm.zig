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
    for (vm.chunk.constants.items) |constant| {
        _ = constant.ref();
        assert(constant.ref_count == 2);
    }

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

                if (value.type != .nil) {
                    try stdout_bw.print("{f}", .{value});
                    try stdout_bw.flush();
                }

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

const add = @import("vm/add.zig").impl;
const subtract = @import("vm/subtract.zig").impl;
const multiply = @import("vm/multiply.zig").impl;
const divide = @import("vm/divide.zig").impl;
const concat = @import("vm/concat.zig").impl;
const match = @import("vm/match.zig").impl;
const apply = @import("vm/apply.zig").impl;

const flip = @import("vm/flip.zig").impl;
const negate = @import("vm/negate.zig").impl;
const first = @import("vm/first.zig").impl;
const reciprocal = @import("vm/reciprocal.zig").impl;
const enlist = @import("vm/enlist.zig").impl;
const not = @import("vm/not.zig").impl;
const @"type" = @import("vm/type.zig").impl;

pub inline fn createNil(vm: *Vm) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .nil, .as = .{ .nil = {} } };
    return v;
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

pub inline fn createSymbolList(vm: *Vm, value: [][]u8) *Value {
    const v = vm.gpa.create(Value) catch @panic("oom");
    v.* = .{ .type = .symbol_list, .as = .{ .symbol_list = value } };
    return v;
}
