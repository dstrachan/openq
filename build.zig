const std = @import("std");

const openq_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("openq", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("q", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "openq",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_options = b.addOptions();
    lib.root_module.addOptions("build_options", lib_options);

    lib_options.addOption(bool, "trace_execution", optimize == .Debug);
    lib_options.addOption(bool, "print_code", optimize == .Debug);

    const exe = b.addExecutable(.{
        .name = "openq",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

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
        }, &code, .Ignore) catch break :v version_string;
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
                        "OpenQ version '{}' must be greater than tagged ancestor '{}'",
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
    const version = try b.allocator.dupeZ(u8, version_slice);
    exe_options.addOption([:0]const u8, "version", version);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
