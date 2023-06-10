const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "boolean tokens" {
    try testTokens("0b", &[_]Token.TokenType{.boolean});
    try testTokens("1b", &[_]Token.TokenType{.boolean});
}

test "boolean_list tokens" {
    try testTokens("0000b", &[_]Token.TokenType{.boolean_list});
    try testTokens("1111b", &[_]Token.TokenType{.boolean_list});
    try testTokens("0101b", &[_]Token.TokenType{.boolean_list});
    try testTokens("1010b", &[_]Token.TokenType{.boolean_list});
}
