const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "char tokens" {
    try testTokens("\" \"", .{.char});
    try testTokens("\"a\"", .{.char});
    try testTokens("\"\\\"\"", .{.char});
    try testTokens("\"\\\\\"", .{.char});

    try testTokens("\"\\000\"", .{.char});
    try testTokens("\"\\888\"", .{.invalid});
}

test "char_list tokens" {
    try testTokens("\"\"", .{.char_list});
    try testTokens("\"ab\"", .{.char_list});
    try testTokens("\"\\\"test\\\"\"", .{.char_list});
    try testTokens("\"\\\"\\\\\\\"\"", .{.char_list});

    try testTokens("\"\\000\\123\"", .{.char_list});
    try testTokens("\"\\000\\888\"", .{.invalid});

    try testTokens("\"unterminated", .{.invalid});
}
