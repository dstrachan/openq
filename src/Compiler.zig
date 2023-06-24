const std = @import("std");

const Node = @import("Node.zig");
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
parser: Parser = .{},
enclosing: ?*Self,
func: *ValueFunction,
function_type: FunctionType,
locals: [u8_count]Token = undefined,
local_count: u8 = 0,

const CompilerError = error{
    CompileError,
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

const Parser = struct {
    previous: Token = undefined,
    current: Token = undefined,
    had_error: bool = false,
    panic_mode: bool = false,
};

const PrefixParseFn = *const fn (*Self) CompilerError!Node;
const InfixParseFn = *const fn (*Self, Node) CompilerError!Node;

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
    _ = top_node;

    unreachable;
}

fn init(enclosing: ?*Self, function_type: FunctionType, vm: VM, scanner: Scanner) Self {
    return .{
        .vm = vm,
        .scanner = scanner,
        .enclosing = enclosing,
        .func = ValueFunction.init(vm.allocator),
        .function_type = function_type,
    };
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

fn expression(self: *Self) CompilerError!Node {
    return try self.parsePrecedence(.Secondary, true);
}

fn parsePrecedence(self: *Self, precedence: Precedence, should_advance: bool) CompilerError!Node {
    if (should_advance) self.advance();
    const prefixRule = getRule(self.parser.previous.token_type).prefix orelse {
        self.errorAtPrevious("Expect prefix expression.");
        return CompilerError.CompileError;
    };
    var node = try prefixRule(self);

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
        .LeftParen       => .{ .prefix = null, .infix = null, .precedence = .None },
        .RightParen      => .{ .prefix = null, .infix = null, .precedence = .None },
        .LeftBrace       => .{ .prefix = null, .infix = null, .precedence = .None },
        .RightBrace      => .{ .prefix = null, .infix = null, .precedence = .None },
        .LeftBracket     => .{ .prefix = null, .infix = null, .precedence = .None },
        .RightBracket    => .{ .prefix = null, .infix = null, .precedence = .None },
        .Semicolon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Colon           => .{ .prefix = null, .infix = null, .precedence = .None },
        .DoubleColon     => .{ .prefix = null, .infix = null, .precedence = .None },
        .Whitespace      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Plus            => .{ .prefix = null, .infix = null, .precedence = .None },
        .PlusColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Minus           => .{ .prefix = null, .infix = null, .precedence = .None },
        .MinusColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Star            => .{ .prefix = null, .infix = null, .precedence = .None },
        .StarColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Percent         => .{ .prefix = null, .infix = null, .precedence = .None },
        .PercentColon    => .{ .prefix = null, .infix = null, .precedence = .None },
        .Bang            => .{ .prefix = null, .infix = null, .precedence = .None },
        .BangColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Ampersand       => .{ .prefix = null, .infix = null, .precedence = .None },
        .AmpersandColon  => .{ .prefix = null, .infix = null, .precedence = .None },
        .Pipe            => .{ .prefix = null, .infix = null, .precedence = .None },
        .PipeColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Less            => .{ .prefix = null, .infix = null, .precedence = .None },
        .LessColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Greater         => .{ .prefix = null, .infix = null, .precedence = .None },
        .GreaterColon    => .{ .prefix = null, .infix = null, .precedence = .None },
        .Equal           => .{ .prefix = null, .infix = null, .precedence = .None },
        .EqualColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Tilde           => .{ .prefix = null, .infix = null, .precedence = .None },
        .TildeColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Comma           => .{ .prefix = null, .infix = null, .precedence = .None },
        .CommaColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Caret           => .{ .prefix = null, .infix = null, .precedence = .None },
        .CaretColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Hash            => .{ .prefix = null, .infix = null, .precedence = .None },
        .HashColon       => .{ .prefix = null, .infix = null, .precedence = .None },
        .Underscore      => .{ .prefix = null, .infix = null, .precedence = .None },
        .UnderscoreColon => .{ .prefix = null, .infix = null, .precedence = .None },
        .Dollar          => .{ .prefix = null, .infix = null, .precedence = .None },
        .DollarColon     => .{ .prefix = null, .infix = null, .precedence = .None },
        .Question        => .{ .prefix = null, .infix = null, .precedence = .None },
        .QuestionColon   => .{ .prefix = null, .infix = null, .precedence = .None },
        .At              => .{ .prefix = null, .infix = null, .precedence = .None },
        .AtColon         => .{ .prefix = null, .infix = null, .precedence = .None },
        .Dot             => .{ .prefix = null, .infix = null, .precedence = .None },
        .DotColon        => .{ .prefix = null, .infix = null, .precedence = .None },
        .Apostrophe      => .{ .prefix = null, .infix = null, .precedence = .None },
        .ApostropheColon => .{ .prefix = null, .infix = null, .precedence = .None },
        .Slash           => .{ .prefix = null, .infix = null, .precedence = .None },
        .SlashColon      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Backslash       => .{ .prefix = null, .infix = null, .precedence = .None },
        .BackslashColon  => .{ .prefix = null, .infix = null, .precedence = .None },
        .Number          => .{ .prefix = null, .infix = null, .precedence = .None },
        .Char            => .{ .prefix = null, .infix = null, .precedence = .None },
        .CharList        => .{ .prefix = null, .infix = null, .precedence = .None },
        .Symbol          => .{ .prefix = null, .infix = null, .precedence = .None },
        .SymbolList      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Identifier      => .{ .prefix = null, .infix = null, .precedence = .None },
        .Error           => .{ .prefix = null, .infix = null, .precedence = .None },
        .Eof             => .{ .prefix = null, .infix = null, .precedence = .None },
        // zig fmt: on
    };
}
