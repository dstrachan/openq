const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "real tokens" {
    try testTokens("0e", .{.real});
    try testTokens("12e", .{.real});
    try testTokens("2e", .{.real});
    try testTokens("-2e", .{.real});

    try testTokens("0.e", .{.real});
    try testTokens("12.e", .{.real});
    try testTokens("2.e", .{.real});
    try testTokens("-2.e", .{.real});

    try testTokens("0.1e", .{.real});
    try testTokens("12.1e", .{.real});
    try testTokens("2.2e", .{.real});
    try testTokens("-2.3e", .{.real});

    try testTokens(".1e", .{.real});
    try testTokens(".2e", .{.real});
    try testTokens("-.3e", .{.real});

    try testTokens("0ne", .{.real});
    try testTokens("0Ne", .{.real});
    try testTokens("-0we", .{.real});
    try testTokens("-0We", .{.real});
    try testTokens("0we", .{.real});
    try testTokens("0We", .{.real});
}
