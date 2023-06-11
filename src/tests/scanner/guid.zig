const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "guid tokens" {
    try testTokens("0ng", .{.guid});
    try testTokens("0Ng", .{.guid});
}
