//! Model-style emitter: emits plain Zig type definitions from a resolved
//! WebIDL model. No dispatch, no JS interop, no method bodies.
//! Skips mixin interfaces (they are folded into their includers by the resolver).

const std = @import("std");
const model = @import("../model.zig");
const naming = @import("../naming.zig");
const common = @import("common.zig");

/// Emit all definitions in `defs` as model-style Zig source to `w`.
/// Definitions are sorted alphabetically by name within each section.
/// Order: enums, callbacks, dictionaries, interfaces (non-mixin), namespaces.
pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, defs: model.Definitions) common.Error!void {
    try common.header(w, .model);

    const enums = try common.sortedCopy(model.Enum, gpa, defs.enums);
    defer gpa.free(enums);
    const callbacks = try common.sortedCopy(model.Callback, gpa, defs.callbacks);
    defer gpa.free(callbacks);
    const dicts = try common.sortedCopy(model.Dictionary, gpa, defs.dictionaries);
    defer gpa.free(dicts);
    const ifaces = try common.sortedCopy(model.Interface, gpa, defs.interfaces);
    defer gpa.free(ifaces);
    const namespaces = try common.sortedCopy(model.Namespace, gpa, defs.namespaces);
    defer gpa.free(namespaces);

    var first = true;

    for (enums) |en| {
        if (!first) try w.writeByte('\n');
        first = false;
        try common.emitEnum(w, gpa, en);
    }
    for (callbacks) |cb| {
        if (!first) try w.writeByte('\n');
        first = false;
        try common.emitCallback(w, gpa, cb);
    }
    for (dicts) |d| {
        if (!first) try w.writeByte('\n');
        first = false;
        try common.emitDictionary(w, gpa, d);
    }
    for (ifaces) |iface| {
        if (iface.mixin) continue;
        if (!first) try w.writeByte('\n');
        first = false;
        try emitInterface(w, gpa, iface);
    }
    for (namespaces) |ns| {
        if (!first) try w.writeByte('\n');
        first = false;
        try emitNamespace(w, gpa, ns);
    }
}

fn emitInterface(w: *std.Io.Writer, gpa: std.mem.Allocator, iface: model.Interface) common.Error!void {
    const ident = naming.zigIdent(gpa, iface.name) catch return error.OutOfMemory;
    defer gpa.free(ident);
    if (iface.inherits) |base| {
        try w.print("/// Inherits: {s}\n", .{base});
    }
    if (iface.attributes.len > 0) {
        try w.writeAll("/// Attributes:");
        for (iface.attributes) |attr| {
            try w.print(" {s}", .{attr.name});
        }
        try w.writeByte('\n');
    }
    const has_named_ops = blk: {
        for (iface.operations) |op| {
            if (op.name != null) break :blk true;
        }
        break :blk false;
    };
    if (has_named_ops) {
        try w.writeAll("/// Operations:");
        for (iface.operations) |op| {
            if (op.name) |n| try w.print(" {s}", .{n});
        }
        try w.writeByte('\n');
    }
    try w.print("pub const {s} = struct {{\n", .{ident});
    for (iface.constants) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }
    try w.writeAll("};\n");
}

fn emitNamespace(w: *std.Io.Writer, gpa: std.mem.Allocator, ns: model.Namespace) common.Error!void {
    const ident = naming.zigIdent(gpa, ns.name) catch return error.OutOfMemory;
    defer gpa.free(ident);
    if (ns.attributes.len > 0) {
        try w.writeAll("/// Attributes:");
        for (ns.attributes) |attr| try w.print(" {s}", .{attr.name});
        try w.writeByte('\n');
    }
    if (ns.operations.len > 0) {
        try w.writeAll("/// Operations:");
        for (ns.operations) |op| {
            if (op.name) |n| try w.print(" {s}", .{n});
        }
        try w.writeByte('\n');
    }
    try w.print("pub const {s} = struct {{\n", .{ident});
    for (ns.constants) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }
    try w.writeAll("};\n");
}

// Unit tests

const testing = std.testing;

test "emitEnum: basic enum sorted" {
    const en = model.Enum{ .name = "State", .values = &.{ "open", "closed", "pending" } };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try common.emitEnum(&aw.writer, testing.allocator, en);
    try testing.expectEqualStrings(
        \\pub const State = enum {
        \\    closed,
        \\    open,
        \\    pending,
        \\};
        \\
    , aw.writer.buffered());
}

test "emitDictionary: required and optional with default" {
    var members = [_]model.DictMember{
        .{ .name = "url", .type = .dom_string, .required = true, .default = null },
        .{ .name = "timeout", .type = .long, .required = false, .default = .{ .integer = 5000 } },
    };
    const dict = model.Dictionary{ .name = "Init", .inherits = null, .members = &members };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try common.emitDictionary(&aw.writer, testing.allocator, dict);
    try testing.expectEqualStrings(
        \\pub const Init = struct {
        \\    url: []const u8,
        \\    timeout: i32 = 5000,
        \\};
        \\
    , aw.writer.buffered());
}

test "emitDictionary: optional with no default gets nullable" {
    var members = [_]model.DictMember{
        .{ .name = "flag", .type = .boolean, .required = false, .default = null },
    };
    const dict = model.Dictionary{ .name = "Opts", .inherits = null, .members = &members };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try common.emitDictionary(&aw.writer, testing.allocator, dict);
    try testing.expectEqualStrings(
        \\pub const Opts = struct {
        \\    flag: ?bool = null,
        \\};
        \\
    , aw.writer.buffered());
}

test "emitInterface: constant emitted" {
    var constants = [_]model.Constant{
        .{ .name = "MAX", .type = .unsigned_short, .value = .{ .integer = 65535 } },
    };
    const iface = model.Interface{
        .name = "Limits",
        .inherits = null,
        .constants = &constants,
        .attributes = &.{},
        .operations = &.{},
        .constructors = &.{},
        .mixin = false,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitInterface(&aw.writer, testing.allocator, iface);
    try testing.expectEqualStrings(
        \\pub const Limits = struct {
        \\    pub const MAX: u16 = 65535;
        \\};
        \\
    , aw.writer.buffered());
}

test "emitCallback: function type" {
    var args = [_]model.Argument{
        .{ .name = "code", .type = .long, .optional = false, .variadic = false, .default = null },
    };
    const cb = model.Callback{ .name = "OnDone", .return_type = .undefined, .args = &args };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try common.emitCallback(&aw.writer, testing.allocator, cb);
    try testing.expectEqualStrings(
        "pub const OnDone = *const fn (code: i32) void;\n",
        aw.writer.buffered(),
    );
}

test "emit: mixin interface is skipped" {
    var interfaces = [_]model.Interface{.{
        .name = "Hidden",
        .inherits = null,
        .constants = &.{},
        .attributes = &.{},
        .operations = &.{},
        .constructors = &.{},
        .mixin = true,
    }};
    var empty_dicts: [0]model.Dictionary = .{};
    var empty_enums: [0]model.Enum = .{};
    var empty_cbs: [0]model.Callback = .{};
    var empty_nss: [0]model.Namespace = .{};
    const defs = model.Definitions{
        .interfaces = &interfaces,
        .dictionaries = &empty_dicts,
        .enums = &empty_enums,
        .callbacks = &empty_cbs,
        .namespaces = &empty_nss,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    try testing.expectEqualStrings(
        "//! Generated by webidl2zig (model style). Do not edit.\n\n",
        aw.writer.buffered(),
    );
}

test "golden: model/minimal" {
    const fixture = @embedFile("../../test/fixtures/minimal.webidl");
    const expected = @embedFile("../../test/golden/model/minimal.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .model, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "golden: model/coverage" {
    const fixture = @embedFile("../../test/fixtures/coverage.webidl");
    const expected = @embedFile("../../test/golden/model/coverage.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .model, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "emit: sorted by name across sections" {
    var enums = [_]model.Enum{
        .{ .name = "Zeta", .values = &.{"z"} },
        .{ .name = "Alpha", .values = &.{"a"} },
    };
    var empty_cbs: [0]model.Callback = .{};
    var empty_dicts: [0]model.Dictionary = .{};
    var empty_ifaces: [0]model.Interface = .{};
    var empty_nss: [0]model.Namespace = .{};
    const defs = model.Definitions{
        .interfaces = &empty_ifaces,
        .dictionaries = &empty_dicts,
        .enums = &enums,
        .callbacks = &empty_cbs,
        .namespaces = &empty_nss,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    const out = aw.writer.buffered();
    const alpha_pos = std.mem.indexOf(u8, out, "Alpha") orelse return error.TestFailure;
    const zeta_pos = std.mem.indexOf(u8, out, "Zeta") orelse return error.TestFailure;
    try testing.expect(alpha_pos < zeta_pos);
}
