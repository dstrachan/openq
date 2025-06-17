const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;
const Chunk = q.Chunk;
const OpCode = Chunk.OpCode;
const Compiler = q.Compiler;

const build_options = @import("build_options");

const Vm = @This();

pub const StackMax = 256;

gpa: Allocator,
chunk: *Chunk,
ip: [*]u8,
stack: [StackMax]Value,
stack_top: [*]Value,
symbols: std.StringHashMapUnmanaged(void) = .empty,

pub const Error = Allocator.Error || error{
    UndeclaredIdentifier,
};

pub fn init(gpa: Allocator) !*Vm {
    const vm = try gpa.create(Vm);
    vm.* = .{
        .gpa = gpa,
        .chunk = undefined,
        .ip = undefined,
        .stack = undefined,
        .stack_top = undefined,
    };
    vm.resetStack();
    return vm;
}

pub fn deinit(vm: *Vm) void {
    var it = vm.symbols.keyIterator();
    while (it.next()) |entry| vm.gpa.free(entry.*);
    vm.symbols.deinit(vm.gpa);
    vm.gpa.destroy(vm);
}

fn resetStack(vm: *Vm) void {
    vm.stack_top = &vm.stack;
}

fn push(vm: *Vm, value: Value) void {
    vm.stack_top[0] = value;
    vm.stack_top += 1;
}

fn pop(vm: *Vm) Value {
    vm.stack_top -= 1;
    return vm.stack_top[0];
}

pub fn interpret(vm: *Vm, tree: Ast) !void {
    assert(tree.errors.len == 0);

    var chunk: Chunk = .empty;
    defer chunk.deinit(vm.gpa);

    Compiler.compile(vm.gpa, tree, vm, &chunk) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NYI => return error.NYI,
        error.Rank => return error.Rank,
        error.Type => return error.Type,
        else => return error.CompileError,
    };

    vm.chunk = &chunk;
    vm.ip = chunk.data.items(.code).ptr;

    vm.run() catch return error.RunError;
}

fn run(vm: *Vm) !void {
    const stdout = std.io.getStdOut().writer();

    while (true) {
        if (build_options.trace_execution) {
            try stdout.writeAll("          ");
            var slot: [*]Value = &vm.stack;
            while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += 1) {
                try stdout.writeAll("[ ");
                try slot[0].print();
                try stdout.print(" ({d}) ]", .{slot[0].ref_count});
            }
            try stdout.writeByte('\n');
            _ = try vm.chunk.disassembleInstruction(vm.ip - vm.chunk.data.items(.code).ptr);
        }

        const instruction: OpCode = @enumFromInt(vm.readByte());
        switch (instruction) {
            .constant => vm.push(vm.readConstant()),

            .add => try vm.binary(add),
            .subtract => try vm.binary(subtract),
            .multiply => try vm.binary(multiply),
            .divide => try vm.binary(divide),
            .apply => @panic("NYI"),
            .concat => try vm.binary(concat),

            .flip => @panic("NYI"),
            .negate => try vm.unary(negate),
            .first => @panic("NYI"),
            .reciprocal => try vm.unary(reciprocal),

            .@"return" => {
                var value = vm.pop();
                defer value.deref(vm.gpa);

                try value.print();
                try stdout.writeByte('\n');
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

inline fn readConstant(vm: *Vm) Value {
    return vm.chunk.constants.items[vm.readByte()];
}

inline fn unary(vm: *Vm, f: *const fn (*Vm, *Value) anyerror!Value) !void {
    var x = vm.pop();
    defer x.deref(vm.gpa);

    vm.push(try f(vm, &x));
}

inline fn binary(vm: *Vm, f: *const fn (*Vm, *Value, *Value) anyerror!Value) !void {
    var x = vm.pop();
    defer x.deref(vm.gpa);
    var y = vm.pop();
    defer y.deref(vm.gpa);

    vm.push(try f(vm, &x, &y));
}

fn add(vm: *Vm, x: *Value, y: *Value) !Value {
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

fn subtract(vm: *Vm, x: *Value, y: *Value) !Value {
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

fn multiply(vm: *Vm, x: *Value, y: *Value) !Value {
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

fn divide(vm: *Vm, x: *Value, y: *Value) !Value {
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

fn concat(vm: *Vm, x: *Value, y: *Value) !Value {
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

fn negate(vm: *Vm, x: *Value) !Value {
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

fn reciprocal(vm: *Vm, x: *Value) !Value {
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

pub inline fn createBoolean(vm: *Vm, value: bool) Value {
    _ = vm; // autofix
    return .{ .type = .boolean, .as = .{ .boolean = value } };
}

pub inline fn createGuid(vm: *Vm, value: [16]u8) Value {
    _ = vm; // autofix
    return .{ .type = .guid, .as = .{ .guid = value } };
}

pub inline fn createByte(vm: *Vm, value: u8) Value {
    _ = vm; // autofix
    return .{ .type = .byte, .as = .{ .byte = value } };
}

pub inline fn createShort(vm: *Vm, value: i16) Value {
    _ = vm; // autofix
    return .{ .type = .short, .as = .{ .short = value } };
}

pub inline fn createInt(vm: *Vm, value: i32) Value {
    _ = vm; // autofix
    return .{ .type = .int, .as = .{ .int = value } };
}

pub inline fn createLong(vm: *Vm, value: i64) Value {
    _ = vm; // autofix
    return .{ .type = .long, .as = .{ .long = value } };
}

pub inline fn createReal(vm: *Vm, value: f32) Value {
    _ = vm; // autofix
    return .{ .type = .real, .as = .{ .real = value } };
}

pub inline fn createFloat(vm: *Vm, value: f64) Value {
    _ = vm; // autofix
    return .{ .type = .float, .as = .{ .float = value } };
}

pub inline fn createChar(vm: *Vm, value: u8) Value {
    _ = vm; // autofix
    return .{ .type = .char, .as = .{ .char = value } };
}

pub inline fn createCharList(vm: *Vm, value: []u8) Value {
    _ = vm; // autofix
    return .{ .type = .char_list, .as = .{ .char_list = value } };
}

pub inline fn createSymbol(vm: *Vm, value: []u8) Value {
    _ = vm; // autofix
    return .{ .type = .symbol, .as = .{ .symbol = value } };
}
