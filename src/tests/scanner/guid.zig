const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "guid tokens" {
    try testTokens("0Ng", &[_]Token.TokenType{.guid});
    try testTokens("0ng", &[_]Token.TokenType{.guid});
}

test "guid_list tokens" {
    try testTokens("0N 0Ng", &[_]Token.TokenType{.guid_list});
    try testTokens("0N 0ng", &[_]Token.TokenType{.guid_list});
    try testTokens("0n 0Ng", &[_]Token.TokenType{.guid_list});
    try testTokens("0n 0ng", &[_]Token.TokenType{.guid_list});
}
