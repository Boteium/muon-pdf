const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default ReleaseSmall)",
    ) orelse .ReleaseSmall;
    // Default to dynamic: system gtk4/mupdf are usually only available as
    // shared libs, and zig 0.16+ errors out (instead of silently falling
    // back) when linkage is static but a needed lib is shared-only.
    const static_link = b.option(bool, "static", "Prefer static linking") orelse false;

    const exe = b.addExecutable(.{
        .name = "muon-pdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.linkage = if (static_link) .static else .dynamic;
    exe.root_module.strip = true;
    exe.root_module.addIncludePath(b.path("src"));

    exe.root_module.linkSystemLibrary("gtk4", .{
        .needed = true,
        .preferred_link_mode = if (static_link) .static else .dynamic,
        .use_pkg_config = .force,
    });
    exe.root_module.linkSystemLibrary("mupdf", .{
        .needed = true,
        .preferred_link_mode = if (static_link) .static else .dynamic,
        .use_pkg_config = .force,
    });
    exe.root_module.linkSystemLibrary("m", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run muon-pdf");
    run_step.dependOn(&run_cmd.step);
}
