const std = @import("std");

fn create_build_step(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    single_threaded: bool,
    modules_name: []const []const u8,
    modules: []const *std.Build.Module,
    comptime emit_bin: bool,
    step: *std.Build.Step,
    sanitize: bool,
) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .link_libc = true,
    });
    // AddressSanitizer + UBSan (ASAN). talyn's heap allocations go through
    // std.heap.c_allocator (malloc/free), so ASAN intercepts them and catches
    // the connection-creation double-free / use-after-free regressions
    // (BUG-118, BUG-119, BUG-120).
    if (sanitize) {
        root_module.sanitize_c = .full;
    }
    for (modules_name, modules) |module_name, module| {
        root_module.addImport(module_name, module);
    }

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = root_module,
    });

    // Enable Link-Time Optimization and section garbage collection for release builds
    if (optimize != .Debug) {
        lib.lto = .thin;
        lib.link_gc_sections = true;
    }

    if (emit_bin) {
        const compile_python_lib = b.addInstallArtifact(lib, .{});
        step.dependOn(&compile_python_lib.step);
    } else {
        step.dependOn(&lib.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const asan = b.option(bool, "asan", "Build with AddressSanitizer + UBSan (malloc-backed allocations; catches heap double-free/UAF)") orelse false;

    // Memory-safety checker build: swap talyn's heap allocator for
    // std.heap.DebugAllocator(.{ .safety = true }), which detects double-free,
    // invalid frees and leaks at runtime. Zig 0.16 has no AddressSanitizer
    // (only -fsanitize-c / UBSan and -fsanitize-thread / TSan), so this is the
    // Zig-native equivalent for catching the connection-creation regressions
    // (BUG-118, BUG-119, BUG-120).
    const debug_alloc = b.option(
        bool,
        "debug-alloc",
        "Use std.heap.DebugAllocator (safety) for talyn's heap — catches double-free / leaks / UAF at runtime",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug_alloc", debug_alloc);
    const build_options_module = build_options.createModule();

    if (target.result.os.tag != .linux) {
        @panic("Only Linux is supported");
    }
    if (target.result.os.isAtLeast(.linux, .{ .major = 5, .minor = 11, .patch = 0 })) |is_at_least| {
        if (!is_at_least) {
            @panic("Only Linux >= 5.11.0 is supported");
        }
    }

    const python_include_dir = b.option([]const u8, "python-include-dir", "Path to python include directory")
        orelse "/usr/include/python3.13";

    const python_lib_dir = b.option([]const u8, "python-lib-dir", "Path to python library directory");

    const python_lib = b.option([]const u8, "python-lib", "Path to the python shared library");

    const python_is_gil_disabled = b.option(bool, "python-gil-disabled", "Is GIL disabled")
        orelse false;

    const python_c_module = b.addModule("python_c", .{
        .root_source_file = b.path("src/python_c.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = !python_is_gil_disabled,
        .link_libc = true,
    });

    if (python_is_gil_disabled) {
        python_c_module.addCMacro("Py_GIL_DISABLED", "1");
    }

    python_c_module.addIncludePath(.{
        .cwd_relative = python_include_dir,
    });

    if (python_lib_dir) |dir| {
        python_c_module.addLibraryPath(.{
            .cwd_relative = dir,
        });
    }

    if (python_lib) |lib| {
        python_c_module.addObjectFile(.{
            .cwd_relative = lib,
        });
    }

    const utils_module = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = !python_is_gil_disabled,
        .link_libc = true,
    });
    utils_module.addImport("python_c", python_c_module);
    utils_module.addImport("build_options", build_options_module);

    const callback_manager_module = b.addModule("callback_manager", .{
        .root_source_file = b.path("src/callback_manager.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = !python_is_gil_disabled,
    });
    callback_manager_module.addImport("python_c", python_c_module);
    callback_manager_module.addImport("utils", utils_module);

    const talyn_module = b.addModule("talyn", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = !python_is_gil_disabled,
    });
    talyn_module.addImport("python_c", python_c_module);
    talyn_module.addImport("utils", utils_module);
    talyn_module.addImport("callback_manager", callback_manager_module);

    const modules_name = .{ "talyn", "python_c", "utils" };
    const modules = .{ talyn_module, python_c_module, utils_module };
    const install_step = b.getInstallStep();

    create_build_step(
        b, "talyn", "src/lib.zig", target, optimize, !python_is_gil_disabled,
        &modules_name, &modules, true, install_step, asan,
    );

    const check_step = b.step("check", "Run checking for ZLS");
    create_build_step(
        b, "talyn", "src/lib.zig", target, optimize, true,
        &modules_name, &modules, false, check_step, asan,
    );

    const talyn_module_unit_tests = b.addTest(.{
        .name = "talyn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = !python_is_gil_disabled,
            .imports = &.{
                .{ .name = "callback_manager", .module = callback_manager_module },
                .{ .name = "python_c", .module = python_c_module },
                .{ .name = "utils", .module = utils_module },
            },
        }),
    });

    const utils_unit_tests = b.addTest(.{
        .name = "utils",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = !python_is_gil_disabled,
            .imports = &.{
                .{ .name = "python_c", .module = python_c_module },
                .{ .name = "utils", .module = utils_module },
            },
        }),
    });

    const callback_manager_unit_tests = b.addTest(.{
        .name = "callback_manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/callback_manager.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = !python_is_gil_disabled,
            .imports = &.{
                .{ .name = "python_c", .module = python_c_module },
                .{ .name = "utils", .module = utils_module },
            },
        }),
    });

    const run_talyn_module_unit_tests = b.addRunArtifact(talyn_module_unit_tests);
    const run_callback_manager_unit_tests = b.addRunArtifact(callback_manager_unit_tests);
    const run_utils_unit_tests = b.addRunArtifact(utils_unit_tests);

    if (asan) {
        talyn_module_unit_tests.root_module.sanitize_c = .full;
        callback_manager_unit_tests.root_module.sanitize_c = .full;
        utils_unit_tests.root_module.sanitize_c = .full;
    }

    if (python_lib) |lib| {
        talyn_module_unit_tests.root_module.addObjectFile(.{ .cwd_relative = lib });
        callback_manager_unit_tests.root_module.addObjectFile(.{ .cwd_relative = lib });
        utils_unit_tests.root_module.addObjectFile(.{ .cwd_relative = lib });

        talyn_module_unit_tests.linker_allow_shlib_undefined = true;
        callback_manager_unit_tests.linker_allow_shlib_undefined = true;
        utils_unit_tests.linker_allow_shlib_undefined = true;
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_talyn_module_unit_tests.step);
    test_step.dependOn(&run_callback_manager_unit_tests.step);
    test_step.dependOn(&run_utils_unit_tests.step);


}
