const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "byte tokens" {
    try testTokens("0x0", .{.byte});
    try testTokens("0x00", .{.byte});
    try testTokens("0x1", .{.byte});
    try testTokens("0x01", .{.byte});
    try testTokens("0xF", .{.byte});
    try testTokens("0x0F", .{.byte});
    try testTokens("0xf", .{.byte});
    try testTokens("0x0f", .{.byte});
    try testTokens("0xFF", .{.byte});
    try testTokens("0xff", .{.byte});
    try testTokens("0x0g", .{ .byte, .identifier });
}

test "byte_list tokens" {
    try testTokens("0x000", .{.byte_list});
    try testTokens("0x0000", .{.byte_list});
    try testTokens("0x100", .{.byte_list});
    try testTokens("0x0100", .{.byte_list});
    try testTokens("0xF00", .{.byte_list});
    try testTokens("0x0F00", .{.byte_list});
    try testTokens("0xf00", .{.byte_list});
    try testTokens("0x0f00", .{.byte_list});
    try testTokens("0xFF00", .{.byte_list});
    try testTokens("0xff00", .{.byte_list});
    try testTokens("0xg", .{ .byte_list, .identifier });
}
