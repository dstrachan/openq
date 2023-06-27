const std = @import("std");

const Chunk = @import("Chunk.zig");
const OpCode = Chunk.OpCode;
const Node = @import("Node.zig");
const Parser = @import("Parser.zig");
const Scanner = @import("Scanner.zig");
const Token = @import("Token.zig");
const TokenType = Token.TokenType;
const Value = @import("Value.zig");
const ValueFunction = Value.ValueFunction;
const VM = @import("VM.zig");

const Self = @This();

const u8_count = std.math.maxInt(u8) + 1;

current: *Self = undefined,

vm: VM,
scanner: Scanner,
parser: Parser,
enclosing: ?*Self,
func: *ValueFunction,
function_type: FunctionType,
locals: [u8_count]Token = undefined,
local_count: u8 = 0,

const CompilerError = error{
    CompileError,
    ParseError,
};

const FunctionType = enum {
    Script,
    Lambda,
};

const Precedence = enum {
    None,
    Secondary,
    Primary,
};

const PrefixParseFn = *const fn (*Self) CompilerError!*Node;
const InfixParseFn = *const fn (*Self, *Node) CompilerError!*Node;

const ParseRule = struct {
    prefix: ?PrefixParseFn,
    infix: ?InfixParseFn,
    precedence: Precedence,
};

pub fn compile(source: []const u8, vm: VM) CompilerError!*Value {
    const scanner = Scanner.init(source);
    var compiler = Self.init(null, .Script, vm, scanner);
    errdefer compiler.func.deinit(vm.allocator);
    compiler.current = &compiler;

    compiler.parser.had_error = false;
    compiler.parser.panic_mode = false;

    compiler.advance();

    var top_node = try compiler.expression();
    {
        errdefer top_node.deinit(vm.allocator);
        while (!compiler.check(.Eof)) {
            const node = try compiler.expression();
            var rhs = &node.rhs;
            while (rhs.* != null) {
                rhs = &rhs.*.?.rhs;
            }
            rhs.* = top_node;
            top_node = node;
        }
    }

    compiler.consume(.Eof, "Expect eof.");

    const func = compiler.endCompiler(top_node);
    return if (compiler.parser.had_error) CompilerError.CompileError else compiler.current.vm.initValue(.{ .function = func });
}

fn init(enclosing: ?*Self, function_type: FunctionType, vm: VM, scanner: Scanner) Self {
    return .{
        .vm = vm,
        .scanner = scanner,
        .parser = Parser.init(vm),
        .enclosing = enclosing,
        .func = ValueFunction.init(vm.allocator),
        .function_type = function_type,
    };
}

fn endCompiler(self: *Self, node: *Node) *ValueFunction {
    const top_node: Node = .{
        .op_code = .Return,
        .lhs = if (node.op_code == .Pop) Node.init(.{ .op_code = .Nil }, self.vm.allocator) else null,
        .rhs = node,
    };
    self.traverse(top_node);
    node.deinit(self.vm.allocator);

    const func = self.current.func;
    func.local_count = self.current.local_count;
    if (self.current.enclosing) |enclosing| {
        self.current = enclosing;
    }

    return func;
}

fn traverse(self: *Self, node: Node) void {
    if (node.rhs) |rhs| self.traverse(rhs.*);
    if (node.lhs) |lhs| self.traverse(lhs.*);
    if (node.name) |name| {
        _ = name; // TODO: Variable resolution
    }
    self.emitInstruction(node.op_code);
    if (node.byte) |byte| self.emitByte(byte);
}

fn advance(self: *Self) void {
    self.parser.previous = self.parser.current;

    while (true) {
        self.parser.current = self.scanner.scanToken();
        std.debug.print("{}\n", .{self.parser.current});
        if (self.parser.current.token_type != .Error) break;

        self.errorAtCurrent(self.parser.current.lexeme);
    }
}

fn currentChunk(self: *Self) *Chunk {
    return self.current.func.chunk;
}

fn emitByte(self: *Self, byte: u8) void {
    self.currentChunk().write(byte, self.parser.previous);
}

fn emitInstruction(self: *Self, instruction: OpCode) void {
    self.emitByte(@intFromEnum(instruction));
}

fn consume(self: *Self, token_type: TokenType, message: []const u8) void {
    if (self.parser.current.token_type == token_type) {
        self.advance();
        return;
    }

    self.errorAtCurrent(message);
}

fn check(self: *Self, token_type: TokenType) bool {
    return self.parser.current.token_type == token_type;
}

fn errorAtCurrent(self: *Self, message: []const u8) void {
    self.errorAt(self.parser.current, message);
}

fn errorAtPrevious(self: *Self, message: []const u8) void {
    self.errorAt(self.parser.previous, message);
}

fn errorAt(self: *Self, token: Token, message: []const u8) void {
    if (self.parser.panic_mode) return;
    self.parser.panic_mode = true;
    std.debug.print("[line {d}] Error", .{token.line});

    if (token.token_type == .Eof) {
        std.debug.print(" at end", .{});
    } else if (token.token_type != .Error) {
        std.debug.print(" at '{s}'", .{token.lexeme});
    }

    std.debug.print(": {s}\n", .{message});
    std.debug.print("{}\n", .{token});
    self.parser.had_error = true;
}

fn makeConstant(self: *Self, value: *Value) u8 {
    const constant = self.currentChunk().addConstant(value);
    if (constant > std.math.maxInt(u8)) {
        self.errorAtPrevious("Too many constants in one chunk.");
        return 0;
    }

    return @intCast(constant);
}

fn expression(self: *Self) CompilerError!*Node {
    return try self.parsePrecedence(.Secondary, true);
}

fn parsePrecedence(self: *Self, precedence: Precedence, should_advance: bool) CompilerError!*Node {
    if (should_advance) self.advance();
    const prefixRule = getRule(self.parser.previous.token_type).prefix orelse {
        self.errorAtPrevious("Expect prefix expression.");
        return CompilerError.CompileError;
    };
    var node = try prefixRule(self);
    errdefer node.deinit(self.vm.allocator);

    while (@intFromEnum(precedence) <= @intFromEnum(getRule(self.parser.current.token_type).precedence)) {
        self.advance();
        const infixRule = getRule(self.parser.previous.token_type).infix orelse {
            self.errorAtPrevious("Expect infix expression.");
            return CompilerError.CompileError;
        };
        node = try infixRule(self, node);
    }

    return node;
}

fn getRule(token_type: TokenType) ParseRule {
    return switch (token_type) {
        // zig fmt: off
        .LeftParen       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .RightParen      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .LeftBrace       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .RightBrace      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .LeftBracket     => .{ .prefix = null,   .infix = null, .precedence = .None },
        .RightBracket    => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Semicolon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Colon           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .DoubleColon     => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Whitespace      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Plus            => .{ .prefix = null,   .infix = add,  .precedence = .Secondary },
        .PlusColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Minus           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .MinusColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Star            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .StarColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Percent         => .{ .prefix = null,   .infix = null, .precedence = .None },
        .PercentColon    => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Bang            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .BangColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Ampersand       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .AmpersandColon  => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Pipe            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .PipeColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Less            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .LessColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Greater         => .{ .prefix = null,   .infix = null, .precedence = .None },
        .GreaterColon    => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Equal           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .EqualColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Tilde           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .TildeColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Comma           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .CommaColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Caret           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .CaretColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Hash            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .HashColon       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Underscore      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .UnderscoreColon => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Dollar          => .{ .prefix = null,   .infix = null, .precedence = .None },
        .DollarColon     => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Question        => .{ .prefix = null,   .infix = null, .precedence = .None },
        .QuestionColon   => .{ .prefix = null,   .infix = null, .precedence = .None },
        .At              => .{ .prefix = null,   .infix = null, .precedence = .None },
        .AtColon         => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Dot             => .{ .prefix = null,   .infix = null, .precedence = .None },
        .DotColon        => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Apostrophe      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .ApostropheColon => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Slash           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .SlashColon      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Backslash       => .{ .prefix = null,   .infix = null, .precedence = .None },
        .BackslashColon  => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Number          => .{ .prefix = number, .infix = null, .precedence = .None },
        .Char            => .{ .prefix = null,   .infix = null, .precedence = .None },
        .CharList        => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Symbol          => .{ .prefix = null,   .infix = null, .precedence = .None },
        .SymbolList      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Identifier      => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Error           => .{ .prefix = null,   .infix = null, .precedence = .None },
        .Eof             => .{ .prefix = null,   .infix = null, .precedence = .None },
        // zig fmt: on
    };
}

fn number(self: *Self) CompilerError!*Node {
    const value = self.parser.parseNumber(self.parser.previous.lexeme) catch {
        return CompilerError.ParseError;
    };
    std.debug.print("number: {}\n", .{value});
    return Node.init(.{
        .op_code = .Constant,
        .byte = self.makeConstant(value),
    }, self.vm.allocator);
}

fn add(self: *Self, node: *Node) CompilerError!*Node {
    return Node.init(.{
        .op_code = .Add,
        .lhs = node,
        .rhs = try self.parsePrecedence(getRule(self.parser.previous.token_type).precedence, true),
    }, self.vm.allocator);
}
