const std = @import("std");

const Chunk = @import("Chunk.zig");
const Compiler = @import("Compiler.zig");
const Debug = @import("Debug.zig");
const OpCode = Chunk.OpCode;
const Value = @import("Value.zig");
const ValueUnion = Value.ValueUnion;

const VM = @This();

allocator: std.mem.Allocator,
frame: *CallFrame = undefined,
frames: [frames_max]CallFrame = undefined,
frame_count: usize = 0,
stack: [stack_max]*Value = undefined,
stack_top: usize = 0,

const frames_max = 64;
const stack_max = frames_max * 256;

const VMError = error{
    CompileError,
    RuntimeError,
};

const CallFrame = struct {
    value: *Value,
    ip: usize,
    slots: []*Value,
};

pub fn init(allocator: std.mem.Allocator) VM {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: VM) void {
    _ = self;
}

pub fn interpret(self: *VM, source: []const u8) VMError!*Value {
    const value = Compiler.compile(source, self) catch return VMError.CompileError;
    defer value.deref(self.allocator);
    std.debug.print("{}\n", .{value});

    Debug.disassembleChunk(value.as.function.chunk, "script");

    try self.call(value, std.bit_set.IntegerBitSet(8).initEmpty());
    return self.run() catch |e| {
        self.reset();
        return e;
    };
}

pub fn initValue(self: VM, data: ValueUnion) *Value {
    return Value.init(.{ .data = data }, self.allocator);
}

fn reset(self: *VM) void {
    while (self.stack_top > 0) {
        self.pop().deref(self.allocator);
    }

    while (self.frame_count > 0) : (self.frame_count -= 1) {
        self.frames[self.frame_count - 1].value.deref(self.allocator);
    }
}

fn push(self: *VM, value: *Value) VMError!void {
    if (self.stack_top == stack_max) return self.runtimeError("Stack overflow.", .{});

    self.stack[self.stack_top] = value;
    self.stack_top += 1;
}

fn pop(self: *VM) *Value {
    self.stack_top -= 1;
    return self.stack[self.stack_top];
}

fn call(self: *VM, value: *Value, arg_indices: std.bit_set.IntegerBitSet(8)) !void {
    const function = value.as.function;
    const arg_count = arg_indices.count();
    if (arg_count < function.arity) {
        unreachable; // TODO: Projection
    }

    errdefer value.deref(self.allocator);
    if (arg_count != function.arity) return self.runtimeError("Expected {d} arguments but got {d}.", .{ function.arity, arg_count });
    if (self.frame_count == frames_max) return self.runtimeError("Stack overflow.", .{});

    const extra_values_needed = function.local_count - arg_count;
    if (extra_values_needed > 0) {
        unreachable; // TODO: Local variables
    }

    self.frames[self.frame_count] = .{
        .value = value,
        .ip = 0,
        .slots = self.stack[self.stack_top - function.local_count .. self.stack_top],
    };
    self.frame_count += 1;
}

fn runtimeError(self: *VM, comptime fmt: []const u8, args: anytype) VMError {
    const stderr = std.io.getStdErr().writer();
    stderr.print(fmt ++ "\n", args) catch {};

    var i = self.frame_count;
    while (i > 0) {
        i -= 1;
        var frame = self.frames[i];
        const token = frame.value.as.function.chunk.tokens.items[frame.ip];
        stderr.print("[line {d}] in {}\n", .{ token.line, frame.value }) catch {};
        if (i > 0) stderr.print("at '{s}'\n", .{token.lexeme}) catch {};
    }

    self.reset();

    return VMError.RuntimeError;
}

fn printStack(self: *VM) void {
    Debug.print("          ", .{});
    for (self.stack[0..self.stack_top]) |slot| {
        Debug.print("[ {} ]", .{slot});
    }
    Debug.print("\n", .{});
}

fn readByte(self: *VM) u8 {
    defer self.frame.ip += 1;
    return self.frame.value.as.function.chunk.code.items[self.frame.ip];
}

fn readConstant(self: *VM) *Value {
    return self.frame.value.as.function.chunk.constants.items[self.readByte()];
}

fn run(self: *VM) VMError!*Value {
    while (true) {
        self.frame = &self.frames[self.frame_count - 1];
        if (comptime Debug.trace_execution) {
            self.printStack();
            _ = Debug.disassembleInstruction(self.frame.value.as.function.chunk, self.frame.ip);
        }

        const instruction: OpCode = @enumFromInt(self.readByte());
        switch (instruction) {
            .Nil => try self.opNil(),
            .Constant => try self.opConstant(),
            .Pop => try self.opPop(),
            .GetLocal => unreachable,
            .SetLocal => unreachable,
            .GetGlobal => unreachable,
            .SetGlobal => unreachable,
            .Add => try self.opAdd(),
            .Subtract => unreachable,
            .Multiply => unreachable,
            .Divide => unreachable,
            .Call => unreachable,
            .Return => if (try self.opReturn()) |value| return value,
        }
    }
}

fn opNil(self: *VM) VMError!void {
    const value = self.initValue(.nil);
    try self.push(value);
}

fn opConstant(self: *VM) VMError!void {
    const constant = self.readConstant();
    try self.push(constant.ref());
}

fn opPop(self: *VM) VMError!void {
    self.pop().deref(self.allocator);
}

fn opAdd(self: *VM) VMError!void {
    const x = self.pop();
    defer x.deref(self.allocator);
    const y = self.pop();
    defer y.deref(self.allocator);

    const value = switch (x.as) {
        .long => |long_x| switch (y.as) {
            .long => |long_y| self.initValue(.{ .long = long_x + long_y }),
            else => return self.runtimeError("Can only add long values.", .{}),
        },
        else => return self.runtimeError("Can only add long values.", .{}),
    };
    try self.push(value);
}

fn opReturn(self: *VM) VMError!?*Value {
    const result = self.pop();

    self.frame.value.deref(self.allocator);

    self.frame_count -= 1;
    if (self.frame_count == 0) return result;

    for (self.frame.slots) |value| value.deref(self.allocator);
    self.stack_top -= self.frame.slots.len;

    try self.push(result);
    return null;
}
