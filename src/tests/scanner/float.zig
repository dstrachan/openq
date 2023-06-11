const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "float tokens" {
    try testTokens("0f", .{.float});
    try testTokens("2f", .{.float});
    try testTokens("-2f", .{.float});

    try testTokens("0.", .{.float});
    try testTokens("0.f", .{.float});
    try testTokens("2.", .{.float});
    try testTokens("2.f", .{.float});
    try testTokens("-2.", .{.float});
    try testTokens("-2.f", .{.float});

    try testTokens("0.1", .{.float});
    try testTokens("0.1f", .{.float});
    try testTokens("2.2", .{.float});
    try testTokens("2.2f", .{.float});
    try testTokens("-2.3", .{.float});
    try testTokens("-2.3f", .{.float});

    try testTokens(".1", .{.float});
    try testTokens(".1f", .{.float});
    try testTokens(".2", .{.float});
    try testTokens(".2f", .{.float});
    try testTokens("-.3", .{.float});
    try testTokens("-.3f", .{.float});

    try testTokens("0n", .{.float});
    try testTokens("0nf", .{.float});
    try testTokens("0Nf", .{.float});
    try testTokens("-0w", .{.float});
    try testTokens("-0wf", .{.float});
    try testTokens("-0Wf", .{.float});
    try testTokens("0w", .{.float});
    try testTokens("0wf", .{.float});
    try testTokens("0Wf", .{.float});
}
