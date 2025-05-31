const std = @import("std");
const Allocator = std.mem.Allocator;

const q = @import("../root.zig");
const Ast = q.Ast;
const Qir = q.Qir;

pub fn generate(gpa: Allocator, tree: Ast) !Qir {
    _ = gpa; // autofix
    _ = tree; // autofix
    unreachable;
}
