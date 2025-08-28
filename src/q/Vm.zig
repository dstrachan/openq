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

pub const stack_max = 256;
pub const locals_max = 256;

gpa: Allocator,
chunk: *Chunk,
ip: [*]u8,
stack: std.ArrayListUnmanaged(*Value),
locals: std.ArrayListUnmanaged(*Value),
symbols: std.StringHashMapUnmanaged(void) = .empty,
globals: std.StringHashMapUnmanaged(*Value) = .empty,

var stdio_buffer: [4096]u8 = undefined;

pub const Error = Allocator.Error || error{
    UndeclaredIdentifier,
    UndefinedGlobal,
};

pub fn init(vm: *Vm, gpa: Allocator) !void {
    const stack_buf = try gpa.alloc(*Value, stack_max);
    errdefer gpa.free(stack_buf);
    const locals_buf = try gpa.alloc(*Value, locals_max);
    errdefer comptime unreachable;

    vm.* = .{
        .gpa = gpa,
        .chunk = undefined,
        .ip = undefined,
        .stack = .initBuffer(stack_buf),
        .locals = .initBuffer(locals_buf),
    };
}

pub fn deinit(vm: *Vm) void {
    vm.stack.deinit(vm.gpa);
    vm.locals.deinit(vm.gpa);

    var it = vm.symbols.keyIterator();
    while (it.next()) |entry| vm.gpa.free(entry.*);
    vm.symbols.deinit(vm.gpa);

    var global_it = vm.globals.iterator();
    while (global_it.next()) |entry| {
        vm.gpa.free(entry.key_ptr.*);
        assert(entry.value_ptr.*.ref_count == 1);
        entry.value_ptr.*.deref(vm.gpa);
    }
    vm.globals.deinit(vm.gpa);
}

fn push(vm: *Vm, value: *Value) void {
    if (vm.stack.items.len == vm.stack.capacity) {
        // TODO: print stack trace.
        @panic("stack");
    }
    vm.stack.appendAssumeCapacity(value);
}

fn tryPeek(vm: *Vm) ?*Value {
    return vm.stack.getLastOrNull();
}

fn peek(vm: *Vm) *Value {
    return vm.stack.getLast();
}

fn tryPop(vm: *Vm) ?*Value {
    return vm.stack.pop();
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
            .get_local => vm.getLocal(),
            .set_local => try vm.setLocal(),
            .get_global => try vm.getGlobal(),
            .set_global => try vm.setGlobal(),

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

fn getGlobal(vm: *Vm) !void {
    const name_value = vm.readConstant();
    defer name_value.deref(vm.gpa); // TODO: intern string
    assert(name_value.type == .symbol);
    const name = name_value.as.symbol;

    if (vm.globals.get(name)) |value| {
        vm.push(value.ref());
    } else {
        return error.UndefinedGlobal;
    }
}

fn setGlobal(vm: *Vm) !void {
    const name_value = vm.readConstant();
    defer name_value.deref(vm.gpa); // TODO: intern string
    assert(name_value.type == .symbol);
    const name = name_value.as.symbol;

    const value = vm.peek();

    const duped_name = try vm.gpa.dupe(u8, name);
    errdefer vm.gpa.free(duped_name);
    const result = try vm.globals.getOrPut(vm.gpa, duped_name);
    if (result.found_existing) {
        vm.gpa.free(duped_name);
        result.value_ptr.*.deref(vm.gpa);
    }
    result.value_ptr.* = value.ref();
}

fn getLocal(vm: *Vm) void {
    const slot = vm.readByte();
    assert(slot < vm.locals.items.len);
    vm.push(vm.locals.items[slot].ref()); // TODO: Do we need to ref here?
}

fn setLocal(vm: *Vm) !void {
    const slot = vm.readByte();
    assert(slot < vm.locals.items.len);
    const value = vm.peek();
    vm.locals.items[slot] = value.ref(); // TODO: Do we need to ref here?
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

pub fn create(vm: *Vm, comptime value_type: Value.Type, value: anytype) !*Value {
    return switch (value_type) {
        .nil => vm.createNil(),
        .boolean => vm.createBoolean(value),
        .boolean_list => vm.createBooleanList(value),
        .guid => vm.createGuid(value),
        .guid_list => vm.createGuidList(value),
        .byte => vm.createByte(value),
        .byte_list => vm.createByteList(value),
        .short => vm.createShort(value),
        .short_list => vm.createShortList(value),
        .int => vm.createInt(value),
        .int_list => vm.createIntList(value),
        .long => vm.createLong(value),
        .long_list => vm.createLongList(value),
        .real => vm.createReal(value),
        .real_list => vm.createRealList(value),
        .float => vm.createFloat(value),
        .float_list => vm.createFloatList(value),
        .char => vm.createChar(value),
        .char_list => vm.createCharList(value),
        .symbol => vm.createSymbol(value),
        .symbol_list => vm.createSymbolList(value),
        else => comptime unreachable,
    };
}

pub inline fn createNil(vm: *Vm) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .nil, .as = .{ .nil = {} } };
    return v;
}

pub inline fn createBoolean(vm: *Vm, value: bool) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .boolean, .as = .{ .boolean = value } };
    return v;
}

pub inline fn createBooleanList(vm: *Vm, value: []bool) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .boolean_list, .as = .{ .boolean_list = value } };
    return v;
}

pub inline fn createGuid(vm: *Vm, value: [16]u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .guid, .as = .{ .guid = value } };
    return v;
}

pub inline fn createGuidList(vm: *Vm, value: [][16]u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .guid_list, .as = .{ .guid_list = value } };
    return v;
}

pub inline fn createByte(vm: *Vm, value: u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .byte, .as = .{ .byte = value } };
    return v;
}

pub inline fn createByteList(vm: *Vm, value: []u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .byte_list, .as = .{ .byte_list = value } };
    return v;
}

pub inline fn createShort(vm: *Vm, value: i16) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .short, .as = .{ .short = value } };
    return v;
}

pub inline fn createShortList(vm: *Vm, value: []i16) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .short_list, .as = .{ .short_list = value } };
    return v;
}

pub inline fn createInt(vm: *Vm, value: i32) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .int, .as = .{ .int = value } };
    return v;
}

pub inline fn createIntList(vm: *Vm, value: []i32) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .int_list, .as = .{ .int_list = value } };
    return v;
}

pub inline fn createLong(vm: *Vm, value: i64) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .long, .as = .{ .long = value } };
    return v;
}

pub inline fn createLongList(vm: *Vm, value: []i64) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .long_list, .as = .{ .long_list = value } };
    return v;
}

pub inline fn createReal(vm: *Vm, value: f32) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .real, .as = .{ .real = value } };
    return v;
}

pub inline fn createRealList(vm: *Vm, value: []f32) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .real_list, .as = .{ .real_list = value } };
    return v;
}

pub inline fn createFloat(vm: *Vm, value: f64) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .float, .as = .{ .float = value } };
    return v;
}

pub inline fn createFloatList(vm: *Vm, value: []f64) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .float_list, .as = .{ .float_list = value } };
    return v;
}

pub inline fn createChar(vm: *Vm, value: u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .char, .as = .{ .char = value } };
    return v;
}

pub inline fn createCharList(vm: *Vm, value: []u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .char_list, .as = .{ .char_list = value } };
    return v;
}

pub inline fn createSymbol(vm: *Vm, value: []u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .symbol, .as = .{ .symbol = value } };
    return v;
}

pub inline fn createSymbolList(vm: *Vm, value: [][]u8) !*Value {
    const v = try vm.gpa.create(Value);
    v.* = .{ .type = .symbol_list, .as = .{ .symbol_list = value } };
    return v;
}

test {
    std.testing.refAllDecls(@This());
}
