const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webidl = b.addModule("webidl", .{
        .root_source_file = b.path("webidl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "webidl2zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/webidl2zig.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webidl", .module = webidl },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run webidl2zig");
    run_step.dependOn(&run_cmd.step);

    const step_test = b.step("test", "Run all unit tests");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("webidl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    step_test.dependOn(&run_unit_tests.step);

    // For each style, generate over the fixture then compile the output to prove it is
    // valid Zig. Client code imports "webidl" for the runtime, so wire that module in.
    inline for (.{ "model", "host", "client" }) |style| {
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "--style", style });
        gen.addFileArg(b.path("test/fixtures/minimal.webidl"));
        gen.addArg("-o");
        const out = gen.addOutputFileArg(style ++ ".zig");

        const gen_mod = b.createModule(.{
            .root_source_file = out,
            .target = target,
            .optimize = optimize,
        });
        if (comptime std.mem.eql(u8, style, "client")) {
            gen_mod.addImport("webidl", webidl);
        }

        const compile_test = b.addTest(.{
            .name = "compile-" ++ style,
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/compile_harness.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "generated", .module = gen_mod }},
            }),
        });
        const run_compile = b.addRunArtifact(compile_test);
        step_test.dependOn(&run_compile.step);
    }

    // Compile-check the coverage fixture in all three styles.
    inline for (.{ "model", "host", "client" }) |style| {
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "--style", style });
        gen.addFileArg(b.path("test/fixtures/coverage.webidl"));
        gen.addArg("-o");
        const out = gen.addOutputFileArg("coverage-" ++ style ++ ".zig");

        const gen_mod = b.createModule(.{
            .root_source_file = out,
            .target = target,
            .optimize = optimize,
        });
        if (comptime std.mem.eql(u8, style, "client")) {
            gen_mod.addImport("webidl", webidl);
        }

        const compile_test = b.addTest(.{
            .name = "compile-coverage-" ++ style,
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/compile_harness.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "generated", .module = gen_mod }},
            }),
        });
        const run_compile = b.addRunArtifact(compile_test);
        step_test.dependOn(&run_compile.step);
    }

    // JSON IR golden byte-compare: generate IR and diff against committed golden.
    inline for (.{ "minimal", "coverage", "ir_types" }) |fixture| {
        const gen_ir = b.addRunArtifact(exe);
        gen_ir.addArg("--emit");
        gen_ir.addArg("json");
        gen_ir.addFileArg(b.path("test/fixtures/" ++ fixture ++ ".webidl"));
        gen_ir.addArg("-o");
        const ir_out = gen_ir.addOutputFileArg(fixture ++ ".json");

        const diff = b.addSystemCommand(&.{"diff"});
        diff.addFileArg(b.path("test/golden/ir/" ++ fixture ++ ".json"));
        diff.addFileArg(ir_out);
        step_test.dependOn(&diff.step);
    }
}

// Consumer API

/// Output style for generated Zig bindings.
pub const Style = enum { model, host, client };

/// Options for generateModule.
pub const GenerateOptions = struct {
    /// Module name (also used as the output filename stem).
    name: []const u8,
    /// Path to the input .webidl file.
    idl: std.Build.LazyPath,
    /// Desired output style.
    style: Style = .model,
};

/// Generate Zig bindings from a WebIDL file as a build step, returning the
/// generated file as a module a consumer can import.
///
/// Usage from a consumer's build.zig:
///
///     const webidl = @import("webidl");
///     const api = webidl.generateModule(b, webidl_dep, .{
///         .name = "api",
///         .idl = b.path("api.webidl"),
///         .style = .model,
///     });
///     exe.root_module.addImport("api", api);
///
/// For the client style, the module imports the webidl package as "webidl" so
/// generated code reaches the runtime via webidl.rt without extra wiring.
pub fn generateModule(
    b: *std.Build,
    dep: *std.Build.Dependency,
    opts: GenerateOptions,
) *std.Build.Module {
    const run = b.addRunArtifact(dep.artifact("webidl2zig"));
    run.addArg("--style");
    run.addArg(@tagName(opts.style));
    run.addFileArg(opts.idl);
    run.addArg("-o");
    const out = run.addOutputFileArg(b.fmt("{s}.zig", .{opts.name}));
    const mod = b.createModule(.{ .root_source_file = out });
    if (opts.style == .client) {
        mod.addImport("webidl", dep.module("webidl"));
    }
    return mod;
}
