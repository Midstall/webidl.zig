//! JSON IR emitter: serialises a resolved WebIDL model to the stable JSON IR
//! consumed by the JS code-generator. Schema version 1.

const std = @import("std");
const model = @import("../model.zig");
const common = @import("common.zig");

// indent helper

fn ind(w: *std.Io.Writer, n: u32) common.Error!void {
    var i: u32 = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

// string escaping

/// Write a JSON-escaped string with surrounding double quotes.
fn writeStr(w: *std.Io.Writer, s: []const u8) common.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\x08' => try w.writeAll("\\b"),
            '\x0C' => try w.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// type serialiser

/// Write a model.Type as a compact JSON object (no extra whitespace).
fn writeType(w: *std.Io.Writer, t: model.Type) common.Error!void {
    switch (t) {
        .boolean, .byte, .octet, .bigint, .undefined, .any, .object, .symbol, .unsigned_short, .unsigned_long, .unsigned_long_long, .short, .long, .long_long, .float, .double, .unrestricted_float, .unrestricted_double, .dom_string, .byte_string, .usv_string => {
            try w.print("{{\"kind\":\"{s}\"}}", .{@tagName(t)});
        },
        .sequence => |inner| {
            try w.writeAll("{\"kind\":\"sequence\",\"element\":");
            try writeType(w, inner.*);
            try w.writeByte('}');
        },
        .record => |r| {
            try w.writeAll("{\"kind\":\"record\",\"key\":");
            try writeType(w, r.key.*);
            try w.writeAll(",\"value\":");
            try writeType(w, r.value.*);
            try w.writeByte('}');
        },
        .frozen_array => |inner| {
            try w.writeAll("{\"kind\":\"frozen_array\",\"inner\":");
            try writeType(w, inner.*);
            try w.writeByte('}');
        },
        .observable_array => |inner| {
            try w.writeAll("{\"kind\":\"observable_array\",\"inner\":");
            try writeType(w, inner.*);
            try w.writeByte('}');
        },
        .promise => |inner| {
            try w.writeAll("{\"kind\":\"promise\",\"inner\":");
            try writeType(w, inner.*);
            try w.writeByte('}');
        },
        .nullable => |inner| {
            try w.writeAll("{\"kind\":\"nullable\",\"inner\":");
            try writeType(w, inner.*);
            try w.writeByte('}');
        },
        .union_of => |members| {
            try w.writeAll("{\"kind\":\"union\",\"members\":[");
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try writeType(w, m);
            }
            try w.writeAll("]}");
        },
        .buffer => |kind| {
            try w.print("{{\"kind\":\"buffer\",\"buffer\":\"{s}\"}}", .{@tagName(kind)});
        },
        .named => |name| {
            try w.writeAll("{\"kind\":\"named\",\"name\":");
            try writeStr(w, name);
            try w.writeByte('}');
        },
    }
}

// literal serialiser

fn writeLiteral(w: *std.Io.Writer, v: model.ValueLiteral) common.Error!void {
    switch (v) {
        .boolean => |b| try w.print("{{\"kind\":\"boolean\",\"value\":{s}}}", .{if (b) "true" else "false"}),
        .integer => |i| try w.print("{{\"kind\":\"integer\",\"value\":{d}}}", .{i}),
        .decimal => |d| try w.print("{{\"kind\":\"decimal\",\"value\":{d}}}", .{d}),
        .string => |s| {
            try w.writeAll("{\"kind\":\"string\",\"value\":");
            try writeStr(w, s);
            try w.writeByte('}');
        },
        .null_value => try w.writeAll("{\"kind\":\"null\"}"),
        .undefined_value => try w.writeAll("{\"kind\":\"undefined\"}"),
        .empty_sequence => try w.writeAll("{\"kind\":\"empty_sequence\"}"),
        .empty_dict => try w.writeAll("{\"kind\":\"empty_dict\"}"),
        .positive_infinity => try w.writeAll("{\"kind\":\"positive_infinity\"}"),
        .negative_infinity => try w.writeAll("{\"kind\":\"negative_infinity\"}"),
        .nan => try w.writeAll("{\"kind\":\"nan\"}"),
    }
}

fn writeOptLiteral(w: *std.Io.Writer, v: ?model.ValueLiteral) common.Error!void {
    if (v) |lit| try writeLiteral(w, lit) else try w.writeAll("null");
}

// generic array writer

/// Write an array of T using writeFn for each element.
/// `key_ind` is the number of spaces that precede the `[` on the same line.
/// The closing `]` is emitted at the same indent.
fn writeGenericArray(
    w: *std.Io.Writer,
    comptime T: type,
    items: []const T,
    key_ind: u32,
    comptime writeFn: fn (*std.Io.Writer, T, u32) common.Error!void,
) common.Error!void {
    if (items.len == 0) {
        try w.writeAll("[]");
        return;
    }
    try w.writeAll("[\n");
    for (items, 0..) |item, i| {
        try writeFn(w, item, key_ind + 2);
        if (i + 1 < items.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try ind(w, key_ind);
    try w.writeByte(']');
}

// string-array writer (for enum values)

fn writeStrArray(w: *std.Io.Writer, values: []const []const u8, key_ind: u32) common.Error!void {
    if (values.len == 0) {
        try w.writeAll("[]");
        return;
    }
    try w.writeAll("[\n");
    for (values, 0..) |v, i| {
        try ind(w, key_ind + 2);
        try writeStr(w, v);
        if (i + 1 < values.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try ind(w, key_ind);
    try w.writeByte(']');
}

// member-level writers

fn writeConst(w: *std.Io.Writer, c: model.Constant, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, c.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"type\": ");
    try writeType(w, c.type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"value\": ");
    try writeLiteral(w, c.value);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeAttr(w: *std.Io.Writer, a: model.Attribute, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, a.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"type\": ");
    try writeType(w, a.type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.print("\"readonly\": {s},\n", .{if (a.readonly) "true" else "false"});
    try ind(w, base + 2);
    try w.print("\"static\": {s}\n", .{if (a.is_static) "true" else "false"});
    try ind(w, base);
    try w.writeByte('}');
}

fn writeArg(w: *std.Io.Writer, arg: model.Argument, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, arg.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"type\": ");
    try writeType(w, arg.type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.print("\"optional\": {s},\n", .{if (arg.optional) "true" else "false"});
    try ind(w, base + 2);
    try w.print("\"variadic\": {s},\n", .{if (arg.variadic) "true" else "false"});
    try ind(w, base + 2);
    try w.writeAll("\"default\": ");
    try writeOptLiteral(w, arg.default);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeOp(w: *std.Io.Writer, op: model.Operation, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    if (op.name) |name| try writeStr(w, name) else try w.writeAll("null");
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"special\": ");
    if (op.special) |sp| {
        const tag = switch (sp) {
            .getter => "getter",
            .setter => "setter",
            .deleter => "deleter",
            .legacy_caller => "legacy_caller",
        };
        try w.writeByte('"');
        try w.writeAll(tag);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.print("\"static\": {s},\n", .{if (op.is_static) "true" else "false"});
    try ind(w, base + 2);
    try w.writeAll("\"returnType\": ");
    try writeType(w, op.return_type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"args\": ");
    try writeGenericArray(w, model.Argument, op.args, base + 2, writeArg);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeCtor(w: *std.Io.Writer, ctor: model.Constructor, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"args\": ");
    try writeGenericArray(w, model.Argument, ctor.args, base + 2, writeArg);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeDictMember(w: *std.Io.Writer, m: model.DictMember, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, m.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"type\": ");
    try writeType(w, m.type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.print("\"required\": {s},\n", .{if (m.required) "true" else "false"});
    try ind(w, base + 2);
    try w.writeAll("\"default\": ");
    try writeOptLiteral(w, m.default);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

// top-level definition writers

fn writeInterface(w: *std.Io.Writer, iface: model.Interface, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, iface.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"inherits\": ");
    if (iface.inherits) |h| try writeStr(w, h) else try w.writeAll("null");
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.print("\"mixin\": {s},\n", .{if (iface.mixin) "true" else "false"});
    try ind(w, base + 2);
    try w.writeAll("\"constants\": ");
    try writeGenericArray(w, model.Constant, iface.constants, base + 2, writeConst);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"attributes\": ");
    try writeGenericArray(w, model.Attribute, iface.attributes, base + 2, writeAttr);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"operations\": ");
    try writeGenericArray(w, model.Operation, iface.operations, base + 2, writeOp);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"constructors\": ");
    try writeGenericArray(w, model.Constructor, iface.constructors, base + 2, writeCtor);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeDict(w: *std.Io.Writer, dict: model.Dictionary, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, dict.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"inherits\": ");
    if (dict.inherits) |h| try writeStr(w, h) else try w.writeAll("null");
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"members\": ");
    try writeGenericArray(w, model.DictMember, dict.members, base + 2, writeDictMember);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeEnum(w: *std.Io.Writer, en: model.Enum, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, en.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"values\": ");
    try writeStrArray(w, en.values, base + 2);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeCallback(w: *std.Io.Writer, cb: model.Callback, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, cb.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"returnType\": ");
    try writeType(w, cb.return_type);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"args\": ");
    try writeGenericArray(w, model.Argument, cb.args, base + 2, writeArg);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

fn writeNamespace(w: *std.Io.Writer, ns: model.Namespace, base: u32) common.Error!void {
    try ind(w, base);
    try w.writeAll("{\n");
    try ind(w, base + 2);
    try w.writeAll("\"name\": ");
    try writeStr(w, ns.name);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"constants\": ");
    try writeGenericArray(w, model.Constant, ns.constants, base + 2, writeConst);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"attributes\": ");
    try writeGenericArray(w, model.Attribute, ns.attributes, base + 2, writeAttr);
    try w.writeAll(",\n");
    try ind(w, base + 2);
    try w.writeAll("\"operations\": ");
    try writeGenericArray(w, model.Operation, ns.operations, base + 2, writeOp);
    try w.writeByte('\n');
    try ind(w, base);
    try w.writeByte('}');
}

// top-level emit

/// Emit `defs` as the JSON IR to `w`. Version is 1.
/// Top-level collections are sorted by name; member order is preserved.
pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, defs: model.Definitions) common.Error!void {
    const interfaces = try common.sortedCopy(model.Interface, gpa, defs.interfaces);
    defer gpa.free(interfaces);
    const dicts = try common.sortedCopy(model.Dictionary, gpa, defs.dictionaries);
    defer gpa.free(dicts);
    const enums = try common.sortedCopy(model.Enum, gpa, defs.enums);
    defer gpa.free(enums);
    const callbacks = try common.sortedCopy(model.Callback, gpa, defs.callbacks);
    defer gpa.free(callbacks);
    const namespaces = try common.sortedCopy(model.Namespace, gpa, defs.namespaces);
    defer gpa.free(namespaces);

    try w.writeAll("{\n");
    try w.writeAll("  \"version\": 1,\n");

    try w.writeAll("  \"interfaces\": ");
    try writeGenericArray(w, model.Interface, interfaces, 2, writeInterface);
    try w.writeAll(",\n");

    try w.writeAll("  \"dictionaries\": ");
    try writeGenericArray(w, model.Dictionary, dicts, 2, writeDict);
    try w.writeAll(",\n");

    try w.writeAll("  \"enums\": ");
    try writeGenericArray(w, model.Enum, enums, 2, writeEnum);
    try w.writeAll(",\n");

    try w.writeAll("  \"callbacks\": ");
    try writeGenericArray(w, model.Callback, callbacks, 2, writeCallback);
    try w.writeAll(",\n");

    try w.writeAll("  \"namespaces\": ");
    try writeGenericArray(w, model.Namespace, namespaces, 2, writeNamespace);
    try w.writeByte('\n');

    try w.writeAll("}\n");
}

// tests

const testing = std.testing;

test "emit: version field is 1" {
    const defs = model.Definitions{
        .interfaces = &.{},
        .dictionaries = &.{},
        .enums = &.{},
        .callbacks = &.{},
        .namespaces = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "\"version\": 1") != null);
}

test "emit: interface with constant and named-return operation" {
    var consts = [_]model.Constant{
        .{ .name = "MAX", .type = .unsigned_short, .value = .{ .integer = 65535 } },
    };
    var args0 = [_]model.Argument{};
    var ops = [_]model.Operation{.{
        .name = "doThing",
        .return_type = .undefined,
        .args = &args0,
        .special = null,
        .is_static = false,
        .stringifier = false,
    }};
    var ifaces = [_]model.Interface{.{
        .name = "Foo",
        .inherits = null,
        .constants = &consts,
        .attributes = &.{},
        .operations = &ops,
        .constructors = &.{},
        .mixin = false,
    }};
    const defs = model.Definitions{
        .interfaces = &ifaces,
        .dictionaries = &.{},
        .enums = &.{},
        .callbacks = &.{},
        .namespaces = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"name\": \"Foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\": \"MAX\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\": \"doThing\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{\"kind\":\"unsigned_short\"}") != null);
}

test "emit: nested nullable sequence type" {
    var inner: model.Type = .long;
    var seq: model.Type = .{ .sequence = &inner };
    var attrs = [_]model.Attribute{.{
        .name = "items",
        .type = .{ .nullable = &seq },
        .readonly = false,
        .is_static = false,
        .stringifier = false,
        .inherit = false,
    }};
    var ifaces = [_]model.Interface{.{
        .name = "Container",
        .inherits = null,
        .constants = &.{},
        .attributes = &attrs,
        .operations = &.{},
        .constructors = &.{},
        .mixin = false,
    }};
    const defs = model.Definitions{
        .interfaces = &ifaces,
        .dictionaries = &.{},
        .enums = &.{},
        .callbacks = &.{},
        .namespaces = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"nullable\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"sequence\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"long\"") != null);
}

test "emit: named type reference in arg" {
    var args = [_]model.Argument{.{
        .name = "target",
        .type = .{ .named = "EventTarget" },
        .optional = false,
        .variadic = false,
        .default = null,
    }};
    var ops = [_]model.Operation{.{
        .name = "attach",
        .return_type = .undefined,
        .args = &args,
        .special = null,
        .is_static = false,
        .stringifier = false,
    }};
    var ifaces = [_]model.Interface{.{
        .name = "Bar",
        .inherits = null,
        .constants = &.{},
        .attributes = &.{},
        .operations = &ops,
        .constructors = &.{},
        .mixin = false,
    }};
    const defs = model.Definitions{
        .interfaces = &ifaces,
        .dictionaries = &.{},
        .enums = &.{},
        .callbacks = &.{},
        .namespaces = &.{},
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit(&aw.writer, testing.allocator, defs);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"named\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"EventTarget\"") != null);
}

test "golden: ir/minimal" {
    const fixture = @embedFile("../../test/fixtures/minimal.webidl");
    const expected = @embedFile("../../test/golden/ir/minimal.json");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generateIr(testing.allocator, fixture, &aw.writer);

    const out = aw.writer.buffered();
    try testing.expectEqualStrings(expected, out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
}

test "golden: ir/coverage" {
    const fixture = @embedFile("../../test/fixtures/coverage.webidl");
    const expected = @embedFile("../../test/golden/ir/coverage.json");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generateIr(testing.allocator, fixture, &aw.writer);

    const out = aw.writer.buffered();
    try testing.expectEqualStrings(expected, out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
}

test "golden: ir/ir_types" {
    const fixture = @embedFile("../../test/fixtures/ir_types.webidl");
    const expected = @embedFile("../../test/golden/ir/ir_types.json");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generateIr(testing.allocator, fixture, &aw.writer);

    const out = aw.writer.buffered();
    try testing.expectEqualStrings(expected, out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
}
