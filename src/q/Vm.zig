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
error_buffer: std.ArrayListUnmanaged(u8) = .empty,

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
    vm.error_buffer.deinit(vm.gpa);
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
    var chunk: Chunk = .empty;
    defer chunk.deinit(vm.gpa);

    Compiler.compile(vm.gpa, tree, &chunk) catch |err| switch (err) {
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

            .add => vm.binary(add),
            .subtract => vm.binary(subtract),
            .multiply => vm.binary(multiply),
            .divide => vm.binary(divide),
            .apply => @panic("NYI"),

            .flip => @panic("NYI"),
            .negate => vm.unary(negate),
            .first => @panic("NYI"),
            .reciprocal => vm.unary(reciprocal),

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

inline fn unary(vm: *Vm, f: *const fn (*Value) Value) void {
    var x = vm.pop();
    defer x.deref(vm.gpa);

    vm.push(f(&x));
}

inline fn binary(vm: *Vm, f: *const fn (*Value, *Value) Value) void {
    var x = vm.pop();
    defer x.deref(vm.gpa);
    var y = vm.pop();
    defer y.deref(vm.gpa);

    vm.push(f(&x, &y));
}

fn add(x: *Value, y: *Value) Value {
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
            .long => .long(x.as.long + y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(@as(f64, @floatFromInt(x.as.long)) + y.as.float),
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
            .long => .float(x.as.float + @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(x.as.float + y.as.float),
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

fn subtract(x: *Value, y: *Value) Value {
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
            .long => .long(x.as.long - y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(@as(f64, @floatFromInt(x.as.long)) - y.as.float),
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
            .long => .float(x.as.float - @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(x.as.float - y.as.float),
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

fn multiply(x: *Value, y: *Value) Value {
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
            .long => .long(x.as.long * y.as.long),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(@as(f64, @floatFromInt(x.as.long)) * y.as.float),
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
            .long => .float(x.as.float * @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(x.as.float * y.as.float),
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

fn divide(x: *Value, y: *Value) Value {
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
            .long => .float(@as(f64, @floatFromInt(x.as.long)) / @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(@as(f64, @floatFromInt(x.as.long)) / y.as.float),
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
            .long => .float(x.as.float / @as(f64, @floatFromInt(y.as.long))),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => .float(x.as.float / y.as.float),
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

fn negate(x: *Value) Value {
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
        .long => .long(-x.as.long),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => .float(-x.as.float),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}

fn reciprocal(x: *Value) Value {
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
        .long => .float(1 / @as(f64, @floatFromInt(x.as.long))),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => .float(1 / x.as.float),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => @panic("NYI"),
        .symbol_list => @panic("NYI"),
    };
}
