const std = @import("std");

const VM = @import("VM.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var vm = VM.init(allocator);
    defer vm.deinit();

    switch (args.len) {
        1 => repl(&vm),
        else => {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Usage: {s} [path]\n", .{args[0]});
            std.process.exit(1);
        },
    }
}

fn repl(vm: *VM) void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const stream = fbs.writer();

    while (true) {
        stdout.writeAll(">") catch std.process.exit(1);
        stdin.streamUntilDelimiter(stream, '\n', buffer.len) catch std.process.exit(1);
        if (fbs.pos == 0) continue;

        const line = fbs.getWritten();
        if (std.mem.eql(u8, line, "\\\\")) break;
        fbs.reset();

        const value = vm.interpret(line) catch |e| {
            stderr.print("ERROR: {s}\n", .{@errorName(e)}) catch std.process.exit(1);
            continue;
        };
        defer value.deref(vm.allocator);
        stdout.print("{}\n", .{value}) catch std.process.exit(1);
    }
}
