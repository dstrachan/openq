const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "guid tokens" {
    try testTokens("0Ng", .{.guid});
    try testTokens("0ng", .{.guid});
}

test "guid_list tokens" {
    try testTokens("0N 0Ng", .{.guid_list});
    try testTokens("0N 0ng", .{.guid_list});
    try testTokens("0n 0Ng", .{.guid_list});
    try testTokens("0n 0ng", .{.guid_list});
}
