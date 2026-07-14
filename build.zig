const std = @import("std");

const openq_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

const IoMode = enum { threaded, evented };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(bool, "single-threaded", "Build artifacts that run in single threaded mode");
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable thread-sanitization");
    const strip = b.option(bool, "strip", "Omit debug information");
    const valgrind = b.option(bool, "valgrind", "Enable valgrind integration");
    const debug_gpa = b.option(bool, "debug-allocator", "Force the runtime to use SafeAllocator") orelse false;
    const io_mode = b.option(IoMode, "io-mode", "How the runtime performs IO") orelse .threaded;
    const mem_leak_frames = b.option(u32, "mem-leak-frames", "How many stack frames to print when a memory leak occurs. Tests get 2x this amount.") orelse blk: {
        if (strip == true) break :blk 0;
        if (optimize != .Debug) break :blk @as(u32, 0);
        break :blk 4;
    };

    const exe = b.addExecutable(.{
        .name = "openq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .sanitize_thread = sanitize_thread,
            .single_threaded = single_threaded,
            .valgrind = valgrind,
        }),
    });
    b.installArtifact(exe);

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

    exe_options.addOption(u32, "mem_leak_frames", mem_leak_frames);
    exe_options.addOption(bool, "debug_gpa", debug_gpa);
    exe_options.addOption(IoMode, "io_mode", io_mode);

    const opt_version_string = b.option(
        []const u8,
        "version-string",
        "Override OpenQ version string. Default is to find out with git.",
    );
    const version_slice = if (opt_version_string) |version| version else v: {
        if (!std.process.can_spawn) {
            std.process.fatal(
                "version info cannot be retrieved from git. OpenQ version must be provided using -Dversion-string",
                .{},
            );
        }
        const version_string = b.fmt(
            "{d}.{d}.{d}",
            .{ openq_version.major, openq_version.minor, openq_version.patch },
        );

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
            "git",
            "-C", b.build_root.path orelse ".", // affects the --git-dir argument
            "--git-dir", ".git", // affected by the -C argument
            "describe", "--match",    "*.*.*", //
            "--tags",   "--abbrev=9",
        }, &code, .ignore) catch break :v version_string;
        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.process.fatal(
                        "OpenQ version '{s}' does not match git tag '{s}'",
                        .{ version_string, git_describe },
                    );
                }
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
                var it = std.mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                if (openq_version.order(ancestor_ver) != .gt) {
                    std.process.fatal(
                        "OpenQ version '{f}' must be greater than tagged ancestor '{f}'",
                        .{ openq_version, ancestor_ver },
                    );
                }

                // Check that the commit hash is prefixed with a 'g' (a git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.log.warn("Unexpected `git describe` output: {s}", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.log.warn("Unexpected `git describe` output: {s}", .{git_describe});
                break :v version_string;
            },
        }
    };
    const version = try b.allocator.dupeSentinel(u8, version_slice, 0);
    exe_options.addOption([:0]const u8, "version", version);

    const semver: std.SemanticVersion = try .parse(version);
    exe_options.addOption(std.SemanticVersion, "semver", semver);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
