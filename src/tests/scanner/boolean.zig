const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "boolean tokens" {
    try testTokens("0b", .{.boolean});
    try testTokens("1b", .{.boolean});
}

test "boolean_list tokens" {
    try testTokens("0000b", .{.boolean_list});
    try testTokens("1111b", .{.boolean_list});
    try testTokens("0101b", .{.boolean_list});
    try testTokens("1010b", .{.boolean_list});
}
