const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    //Example
    {
        const lib = b.addSharedLibrary(.{.name = "jni_example", .root_source_file = .{ .path = "test/demo.zig"}, .target = target, .optimize = mode});

        if (@hasField(std.build.LibExeObjStep, "use_stage1"))
            lib.use_stage1 = true;

        lib.addModule("jui", b.addModule("jui", .{ .source_file = .{ .path = "src/jui.zig"}}));

        b.installArtifact(lib);
    }

    const java_home = b.env_map.get("JAVA_HOME") orelse @panic("JAVA_HOME not defined.");
    const libjvm_path = if (builtin.os.tag == .windows) "/lib" else "/lib/server";

    {
        const exe = b.addExecutable(.{.name = "class2zig", .root_source_file = .{ .path = "tools/class2zig.zig"}, .target = target, .optimize = mode});

        if (@hasField(std.build.LibExeObjStep, "use_stage1"))
            exe.use_stage1 = true;

        exe.addModule("jui", b.addModule("jui", .{ .source_file = .{ .path = "src/jui.zig"}}));
        exe.addModule("cf", b.addModule("jui", .{ .source_file = .{ .path = "dep/cf/cf.zig"}}));

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("class2zig", "Run class2zig tool");
        run_step.dependOn(&run_cmd.step);
    }

    //Example
    {
        const exe = b.addExecutable(.{.name = "guessing_game", .root_source_file = .{ .path = "examples/guessing-game/main.zig"}, .target = target, .optimize = mode});

        if (@hasField(std.build.LibExeObjStep, "use_stage1"))
            exe.use_stage1 = true;

        exe.addModule("jui", b.addModule("jui", .{ .source_file = .{ .path = "src/jui.zig"}}));

        exe.addLibraryPath(.{ .path = b.pathJoin(&.{ java_home, libjvm_path })});
        exe.linkSystemLibrary("jvm");
        exe.linkLibC();

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("guessing_game", "Run guessing game example");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests (it requires a JDK installed)
    {
        const main_tests = b.addTest(.{.root_source_file = .{.path = "src/jui.zig"}, .optimize = mode});

        if (@hasDecl(@TypeOf(main_tests.*), "addLibraryPath")) {
            main_tests.addLibraryPath(.{.path = b.pathJoin(&.{ java_home, libjvm_path })});
        } else {
            // Deprecated on zig 0.10
            main_tests.addLibPath(b.pathJoin(&.{ java_home, libjvm_path }));
        }

        main_tests.linkSystemLibrary("jvm");
        main_tests.linkLibC();

        // TODO: Depending on the JVM available to the distro:
        if (builtin.os.tag == .linux) {
            main_tests.target.abi = .gnu;
        }

        if (builtin.os.tag == .windows) {

            // Sets the DLL path:
            const setDllDirectory = struct {
                pub extern "kernel32" fn SetDllDirectoryA(path: [*:0]const u8) callconv(.C) std.os.windows.BOOL;
            }.SetDllDirectoryA;

            var java_bin_path = std.fs.path.joinZ(b.allocator, &.{ java_home, "\\bin" }) catch unreachable;
            defer b.allocator.free(java_bin_path);
            _ = setDllDirectory(java_bin_path);

            var java_bin_server_path = std.fs.path.joinZ(b.allocator, &.{ java_home, "\\bin\\server" }) catch unreachable;
            defer b.allocator.free(java_bin_server_path);
            _ = setDllDirectory(java_bin_server_path);

            // TODO: Define how we can disable the SEGV handler just for a single call:
            // The function `JNI_CreateJavaVM` tries to detect the stack size
            // and causes a SEGV that is handled by the Zig side
            // https://bugzilla.redhat.com/show_bug.cgi?id=1572811#c7
            //
            // The simplest workarround is just run the tests in "ReleaseFast" mode,
            // and for some reason it is not needed on Linux.
            main_tests.setBuildMode(.ReleaseFast);
        } else {
//             main_tests.setBuildMode(mode);
        }

        var test_step = b.step("test", "Run library tests");
        test_step.dependOn(&main_tests.step);

        const argv: []const []const u8 = &.{ b.pathJoin(&.{ java_home, "/bin/javac" ++ if (builtin.os.tag == .windows) ".exe" else "" }), "test/src/com/jui/TypesTest.java" };
        _ = b.execAllowFail(argv, undefined, .Inherit) catch |err| {
            std.debug.panic("Failed to compile Java test files: {}", .{err});
        };
    }
}
