//! webidl2zig CLI: read a WebIDL file, generate Zig bindings in the requested
//! style, write to a file (`-o`) or stdout.

const std = @import("std");
const webidl = @import("webidl");

const usage =
    \\usage: webidl2zig [--style model|host|client] [--emit json] <input.webidl>... [-o output]
    \\
    \\  --style <s>   output style (default: model)
    \\  --emit json   emit JSON IR instead of Zig (mutually exclusive with --style)
    \\  --mozilla     accept Mozilla/Gecko WebIDL extensions (forward decls,
    \\                string/integer-valued extended attributes)
    \\  -o <path>     write to file instead of stdout
    \\  -h, --help    show this help
    \\
;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        report(init.io, err);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    var style: webidl.emit.common.Style = .model;
    var style_explicit = false;
    var emit_json = false;
    var mozilla = false;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    var output: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mozilla")) {
            mozilla = true;
        } else if (std.mem.eql(u8, arg, "--style")) {
            const v = args.next() orelse return fatal(io, "--style requires a value");
            style = std.meta.stringToEnum(webidl.emit.common.Style, v) orelse
                return fatal(io, "unknown style (expected model, host, or client)");
            style_explicit = true;
        } else if (std.mem.eql(u8, arg, "--emit")) {
            const v = args.next() orelse return fatal(io, "--emit requires a value");
            if (!std.mem.eql(u8, v, "json"))
                return fatal(io, "unknown emit target (expected json)");
            emit_json = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            output = args.next() orelse return fatal(io, "-o requires a value");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printStderr(io, usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fatal(io, "unknown flag");
        } else {
            try inputs.append(gpa, arg);
        }
    }

    if (emit_json and style_explicit) {
        return fatal(io, "--emit json and --style are mutually exclusive");
    }

    if (inputs.items.len == 0) {
        try printStderr(io, usage);
        return error.MissingInput;
    }

    // Concatenate all inputs into one source so references resolve across the whole set.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (inputs.items) |in_path| {
        const file_bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .unlimited);
        defer gpa.free(file_bytes);
        try src.appendSlice(gpa, file_bytes);
        try src.append(gpa, '\n');
    }
    const bytes = src.items;

    var err_buf: [4096]u8 = undefined;
    var err_sw = std.Io.File.stderr().writer(io, &err_buf);
    // Flush diagnostics on every path, including when generate* returns an error.
    defer err_sw.interface.flush() catch {};

    var out_buf: [4096]u8 = undefined;
    if (emit_json) {
        if (output) |out_path| {
            var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);
            var fw = file.writer(io, &out_buf);
            try webidl.emit.common.generateIrChecked(gpa, bytes, &fw.interface, &err_sw.interface, mozilla);
            try fw.interface.flush();
        } else {
            var sw = std.Io.File.stdout().writer(io, &out_buf);
            try webidl.emit.common.generateIrChecked(gpa, bytes, &sw.interface, &err_sw.interface, mozilla);
            try sw.interface.flush();
        }
    } else {
        if (output) |out_path| {
            var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);
            var fw = file.writer(io, &out_buf);
            try webidl.emit.common.generateChecked(gpa, bytes, style, &fw.interface, &err_sw.interface, mozilla);
            try fw.interface.flush();
        } else {
            var sw = std.Io.File.stdout().writer(io, &out_buf);
            try webidl.emit.common.generateChecked(gpa, bytes, style, &sw.interface, &err_sw.interface, mozilla);
            try sw.interface.flush();
        }
    }
}

fn fatal(io: std.Io, msg: []const u8) error{InvalidArgs} {
    printStderr(io, msg) catch {};
    printStderr(io, "\n") catch {};
    return error.InvalidArgs;
}

/// Print a clean one-line diagnostic for a failure (no stack trace).
/// Argument errors and HasDiagnostics already printed their own message, so they are silent here.
fn report(io: std.Io, err: anyerror) void {
    const msg: []const u8 = switch (err) {
        error.InvalidArgs, error.MissingInput, error.HasDiagnostics => return,
        error.FileNotFound => "input file not found",
        error.AccessDenied => "permission denied",
        else => @errorName(err),
    };
    printStderr(io, "webidl2zig: error: ") catch {};
    printStderr(io, msg) catch {};
    printStderr(io, "\n") catch {};
}

fn printStderr(io: std.Io, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    var sw = std.Io.File.stderr().writer(io, &buf);
    try sw.interface.writeAll(msg);
    try sw.interface.flush();
}
