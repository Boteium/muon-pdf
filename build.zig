const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default ReleaseSmall)",
    ) orelse .ReleaseSmall;
    const static_link = b.option(bool, "static", "Prefer static linking") orelse true;

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

    exe.linkSystemLibrary2("gtk4", .{
        .needed = true,
        .preferred_link_mode = if (static_link) .static else .dynamic,
        .use_pkg_config = .force,
    });
    exe.linkSystemLibrary2("mupdf", .{
        .needed = true,
        .preferred_link_mode = if (static_link) .static else .dynamic,
        .use_pkg_config = .force,
    });
    exe.linkSystemLibrary("m");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run muon-pdf");
    run_step.dependOn(&run_cmd.step);
}
