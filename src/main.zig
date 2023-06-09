const std = @import("std");

const VM = @import("vm.zig");

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
            try vm.stderr.print("Usage: {s} [path]\n", .{args[0]});
            std.process.exit(1);
        },
    }
}

fn repl(vm: *VM) void {
    const stdin = std.io.getStdIn().reader();

    var buffered_reader = std.io.bufferedReader(stdin);
    const reader = buffered_reader.reader();
    var buf: [2048]u8 = undefined;
    while (true) {
        vm.stdout.writeAll("q)") catch std.process.exit(1);
        const line = reader.readUntilDelimiterOrEof(&buf, '\n') catch std.process.exit(1) orelse {
            vm.stdout.writeAll("\n") catch std.process.exit(1);
            break;
        };

        var i = line.len;
        while (i > 0) {
            switch (line[i - 1]) {
                ' ', '\t', '\r', '\n' => i -= 1,
                else => break,
            }
        }

        if (std.mem.eql(u8, "\\\\", line[0..i])) {
            break;
        }

        vm.interpret(line) catch |e| {
            if (vm.error_message) |error_message| {
                vm.stderr.print("ERROR: {s} - {s}\n", .{ @errorName(e), error_message }) catch std.process.exit(1);
            } else {
                vm.stderr.print("ERROR: {s}\n", .{@errorName(e)}) catch std.process.exit(1);
            }
        };
    }
}
