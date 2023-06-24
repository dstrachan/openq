const std = @import("std");

const Chunk = @import("Chunk.zig");
const OpCode = Chunk.OpCode;
const Token = @import("Token.zig");

const Self = @This();

op_code: OpCode,
byte: ?u8 = null,
name: ?Token = null,
