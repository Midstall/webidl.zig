//! Client / Wasm-frontend emitter: turns the normalized model into Zig handle
//! wrappers that call into JS through the runtime `webidl.rt` (wasm-bindgen style).
//! Skips mixin interfaces (they are folded into their includers by the resolver).
//!
//! Generated file layout:
//!   const webidl = @import("webidl");  (reach the runtime via webidl.rt)
//!   pub const <Enum>   = enum { ... };
//!   pub const <Dict>   = struct { ... };    (plain data, same as model style)
//!   pub const <Iface>  = struct {           (handle wrapper)
//!       handle: webidl.rt.Handle,
//!       pub const NAME: T = value;          (WebIDL constants)
//!       pub fn get_attr(self) T { ... }     (attribute getters)
//!       pub fn set_attr(self, v: T) void {} (attribute setters, non-readonly only)
//!       pub fn method(self, args...) T { }  (operations)
//!   };
//!
//! String ownership: getters and operations that return `[]const u8` hand back
//! OWNED memory allocated by the JS host via `webidl_rt_alloc`. Callers must
//! free the slice with `webidl.rt.freeStr` when done.

const std = @import("std");
const model = @import("../model.zig");
const naming = @import("../naming.zig");
const common = @import("common.zig");

/// Emit all definitions in `defs` as client-style Zig source to `w`.
/// Definitions within each section are sorted alphabetically by name.
/// Order: enums, callbacks, dictionaries, interfaces (non-mixin), namespaces.
pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, defs: model.Definitions) common.Error!void {
    try common.header(w, .client);
    try w.writeAll("const webidl = @import(\"webidl\");\n\n");

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

// Interface (handle wrapper)

fn emitInterface(w: *std.Io.Writer, gpa: std.mem.Allocator, iface: model.Interface) common.Error!void {
    const ident = naming.zigIdent(gpa, iface.name) catch return error.OutOfMemory;
    defer gpa.free(ident);

    try w.print("pub const {s} = struct {{\n", .{ident});
    try w.writeAll("    handle: webidl.rt.Handle,\n");

    // Constants (sorted)
    const consts = gpa.dupe(model.Constant, iface.constants) catch return error.OutOfMemory;
    defer gpa.free(consts);
    std.mem.sort(model.Constant, consts, {}, struct {
        fn less(_: void, a: model.Constant, b: model.Constant) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (consts) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }

    // Attributes: getter (and setter if non-readonly), sorted
    const attrs = gpa.dupe(model.Attribute, iface.attributes) catch return error.OutOfMemory;
    defer gpa.free(attrs);
    std.mem.sort(model.Attribute, attrs, {}, struct {
        fn less(_: void, a: model.Attribute, b: model.Attribute) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (attrs) |attr| {
        if (attr.is_static) continue; // handled below
        try emitAttrGetter(w, gpa, ident, attr);
        if (!attr.readonly) try emitAttrSetter(w, gpa, ident, attr);
    }

    // Operations (instance: named or special, sorted)
    const ops = gpa.dupe(model.Operation, iface.operations) catch return error.OutOfMemory;
    defer gpa.free(ops);
    std.mem.sort(model.Operation, ops, {}, struct {
        fn less(_: void, a: model.Operation, b: model.Operation) bool {
            const an = a.name orelse (if (a.special) |s| common.specialOpName(s) else return true);
            const bn = b.name orelse (if (b.special) |s| common.specialOpName(s) else return false);
            return std.mem.lessThan(u8, an, bn);
        }
    }.less);
    for (ops) |op| {
        if (op.is_static) continue; // handled below
        if (op.name == null and op.special == null) continue;
        const raw_name = op.name orelse (if (op.special) |s| common.specialOpName(s) else continue);
        try emitOperation(w, gpa, ident, op, raw_name);
    }

    // Static attributes
    for (attrs) |attr| {
        if (!attr.is_static) continue;
        try emitStaticAttrGetter(w, gpa, iface.name, attr);
        if (!attr.readonly) try emitStaticAttrSetter(w, gpa, iface.name, attr);
    }

    // Static operations
    for (ops) |op| {
        if (!op.is_static) continue;
        if (op.name == null and op.special == null) continue;
        const raw_name = op.name orelse (if (op.special) |s| common.specialOpName(s) else continue);
        try emitStaticOperation(w, gpa, iface.name, op, raw_name);
    }

    // Constructors
    for (iface.constructors, 0..) |ctor, ci| {
        const ctor_fn = if (ci == 0) @as([]const u8, "init") else try std.fmt.allocPrint(gpa, "init{d}", .{ci});
        defer if (ci > 0) gpa.free(ctor_fn);
        try w.print("    pub fn {s}(", .{ctor_fn});
        var first = true;
        for (ctor.args) |arg| {
            if (!first) try w.writeAll(", ");
            first = false;
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try w.print("{s}: ", .{arg_ident});
            try common.zigArgType(w, gpa, arg);
        }
        try w.print(") {s} {{\n", .{ident});
        try w.print("        return .{{ .handle = webidl.rt.construct(\"{s}\", &[_]webidl.rt.Handle{{", .{iface.name});
        first = true;
        for (ctor.args) |arg| {
            if (arg.variadic) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try emitTypeToHandle(w, gpa, arg.type, arg_ident);
        }
        try w.writeAll("}) };\n    }\n");
    }

    // Reference counting: retain/release the JS handle in the host table.
    try w.print("    pub fn ref(self: {s}) void {{\n        webidl.rt.retain(self.handle);\n    }}\n", .{ident});
    try w.print("    pub fn unref(self: {s}) void {{\n        webidl.rt.release(self.handle);\n    }}\n", .{ident});

    try w.writeAll("};\n");
}

fn emitAttrGetter(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_ident: []const u8,
    attr: model.Attribute,
) common.Error!void {
    const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
    defer gpa.free(getter_raw);
    const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
    defer gpa.free(getter_ident);
    try w.print("    pub fn {s}(self: {s}) ", .{ getter_ident, iface_ident });
    try common.zigType(w, gpa, attr.type);
    try w.writeAll(" {\n");
    try w.print("        const _h = webidl.rt.getAttr(self.handle, \"{s}\");\n", .{attr.name});
    try w.writeAll("        return ");
    try emitHandleToType(w, gpa, attr.type, "_h");
    try w.writeAll(";\n    }\n");
}

fn emitAttrSetter(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_ident: []const u8,
    attr: model.Attribute,
) common.Error!void {
    const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
    defer gpa.free(setter_raw);
    const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
    defer gpa.free(setter_ident);
    try w.print("    pub fn {s}(self: {s}, value: ", .{ setter_ident, iface_ident });
    try common.zigType(w, gpa, attr.type);
    try w.writeAll(") void {\n");
    try w.print("        webidl.rt.setAttr(self.handle, \"{s}\", ", .{attr.name});
    try emitTypeToHandle(w, gpa, attr.type, "value");
    try w.writeAll(");\n    }\n");
}

fn emitOperation(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_ident: []const u8,
    op: model.Operation,
    op_name: []const u8,
) common.Error!void {
    const op_ident = naming.zigIdent(gpa, op_name) catch return error.OutOfMemory;
    defer gpa.free(op_ident);

    // Signature: pub fn <op>(self: <Iface>, arg0: T0, ...) RetT {
    try w.print("    pub fn {s}(self: {s}", .{ op_ident, iface_ident });
    for (op.args) |arg| {
        try w.writeAll(", ");
        const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
        defer gpa.free(arg_ident);
        try w.print("{s}: ", .{arg_ident});
        try common.zigArgType(w, gpa, arg);
    }
    try w.writeAll(") ");
    try common.zigType(w, gpa, op.return_type);
    try w.writeAll(" {\n");

    // Emit a comment for any variadic arg (cannot auto-spread into Handle array)
    for (op.args) |arg| {
        if (arg.variadic) {
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try w.print("        // variadic arg '{s}': custom JS marshaling needed\n", .{arg.name});
            try w.print("        _ = {s};\n", .{arg_ident});
            break;
        }
    }

    // Body: inline Handle array, then dispatch via webidl.rt.callMethod
    const is_void = op.return_type == .undefined;

    if (is_void) {
        try w.writeAll("        _ = webidl.rt.callMethod(self.handle, \"");
    } else {
        try w.writeAll("        const _h = webidl.rt.callMethod(self.handle, \"");
    }
    try w.writeAll(op_name);
    try w.writeAll("\", &[_]webidl.rt.Handle{");

    var first_arg = true;
    for (op.args) |arg| {
        if (arg.variadic) continue; // variadic: see comment above
        if (!first_arg) try w.writeAll(", ");
        first_arg = false;
        const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
        defer gpa.free(arg_ident);
        try emitTypeToHandle(w, gpa, arg.type, arg_ident);
    }

    if (is_void) {
        try w.writeAll("});\n    }\n");
    } else {
        try w.writeAll("});\n");
        try w.writeAll("        return ");
        try emitHandleToType(w, gpa, op.return_type, "_h");
        try w.writeAll(";\n    }\n");
    }
}

// Static attribute / operation helpers (interface-level, no instance handle)

fn emitStaticAttrGetter(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_name: []const u8,
    attr: model.Attribute,
) common.Error!void {
    const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
    defer gpa.free(getter_raw);
    const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
    defer gpa.free(getter_ident);
    try w.print("    pub fn {s}() ", .{getter_ident});
    try common.zigType(w, gpa, attr.type);
    try w.writeAll(" {\n");
    try w.print("        const _h = webidl.rt.getStaticAttr(\"{s}\", \"{s}\");\n", .{ iface_name, attr.name });
    try w.writeAll("        return ");
    try emitHandleToType(w, gpa, attr.type, "_h");
    try w.writeAll(";\n    }\n");
}

fn emitStaticAttrSetter(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_name: []const u8,
    attr: model.Attribute,
) common.Error!void {
    const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
    defer gpa.free(setter_raw);
    const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
    defer gpa.free(setter_ident);
    try w.print("    pub fn {s}(value: ", .{setter_ident});
    try common.zigType(w, gpa, attr.type);
    try w.writeAll(") void {\n");
    try w.print("        webidl.rt.setStaticAttr(\"{s}\", \"{s}\", ", .{ iface_name, attr.name });
    try emitTypeToHandle(w, gpa, attr.type, "value");
    try w.writeAll(");\n    }\n");
}

fn emitStaticOperation(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    iface_name: []const u8,
    op: model.Operation,
    op_name: []const u8,
) common.Error!void {
    const op_ident = naming.zigIdent(gpa, op_name) catch return error.OutOfMemory;
    defer gpa.free(op_ident);
    const is_void = op.return_type == .undefined;
    try w.print("    pub fn {s}(", .{op_ident});
    var first = true;
    for (op.args) |arg| {
        if (!first) try w.writeAll(", ");
        first = false;
        const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
        defer gpa.free(arg_ident);
        try w.print("{s}: ", .{arg_ident});
        try common.zigArgType(w, gpa, arg);
    }
    try w.writeAll(") ");
    try common.zigType(w, gpa, op.return_type);
    try w.writeAll(" {\n");
    for (op.args) |arg| {
        if (arg.variadic) {
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try w.print("        // variadic arg '{s}': custom JS marshaling needed\n", .{arg.name});
            try w.print("        _ = {s};\n", .{arg_ident});
            break;
        }
    }
    if (is_void) {
        try w.print("        _ = webidl.rt.callStaticMethod(\"{s}\", \"{s}\", &[_]webidl.rt.Handle{{", .{ iface_name, op_name });
    } else {
        try w.print("        const _h = webidl.rt.callStaticMethod(\"{s}\", \"{s}\", &[_]webidl.rt.Handle{{", .{ iface_name, op_name });
    }
    first = true;
    for (op.args) |arg| {
        if (arg.variadic) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
        defer gpa.free(arg_ident);
        try emitTypeToHandle(w, gpa, arg.type, arg_ident);
    }
    if (is_void) {
        try w.writeAll("});\n    }\n");
    } else {
        try w.writeAll("});\n        return ");
        try emitHandleToType(w, gpa, op.return_type, "_h");
        try w.writeAll(";\n    }\n");
    }
}

// Namespace (static: operations and attributes emitted via static helpers)

fn emitNamespace(w: *std.Io.Writer, gpa: std.mem.Allocator, ns: model.Namespace) common.Error!void {
    const ident = naming.zigIdent(gpa, ns.name) catch return error.OutOfMemory;
    defer gpa.free(ident);
    try w.print("pub const {s} = struct {{\n", .{ident});

    const consts = gpa.dupe(model.Constant, ns.constants) catch return error.OutOfMemory;
    defer gpa.free(consts);
    std.mem.sort(model.Constant, consts, {}, struct {
        fn less(_: void, a: model.Constant, b: model.Constant) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (consts) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }

    // Namespace attributes (all static by WebIDL spec)
    const attrs = gpa.dupe(model.Attribute, ns.attributes) catch return error.OutOfMemory;
    defer gpa.free(attrs);
    std.mem.sort(model.Attribute, attrs, {}, struct {
        fn less(_: void, a: model.Attribute, b: model.Attribute) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (attrs) |attr| {
        try emitStaticAttrGetter(w, gpa, ns.name, attr);
        if (!attr.readonly) try emitStaticAttrSetter(w, gpa, ns.name, attr);
    }

    // Namespace operations (all static by WebIDL spec)
    const ops = gpa.dupe(model.Operation, ns.operations) catch return error.OutOfMemory;
    defer gpa.free(ops);
    std.mem.sort(model.Operation, ops, {}, struct {
        fn less(_: void, a: model.Operation, b: model.Operation) bool {
            const an = a.name orelse "";
            const bn = b.name orelse "";
            return std.mem.lessThan(u8, an, bn);
        }
    }.less);
    for (ops) |op| {
        const raw_name = op.name orelse continue;
        try emitStaticOperation(w, gpa, ns.name, op, raw_name);
    }

    try w.writeAll("};\n");
}

// Type-marshaling helpers (emit Zig expressions for the Wasm/JS boundary)

/// Emit an expression that converts a Zig value `val_ident` of model type `t`
/// into a `webidl.rt.Handle` suitable for passing across the JS boundary.
fn emitTypeToHandle(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    t: model.Type,
    val_ident: []const u8,
) common.Error!void {
    switch (t) {
        .boolean => try w.print("webidl.rt.fromBool({s})", .{val_ident}),
        .byte, .short => try w.print("webidl.rt.fromI32(@as(i32, {s}))", .{val_ident}),
        .long => try w.print("webidl.rt.fromI32({s})", .{val_ident}),
        .octet, .unsigned_short => try w.print("webidl.rt.fromU32(@as(u32, {s}))", .{val_ident}),
        .unsigned_long => try w.print("webidl.rt.fromU32({s})", .{val_ident}),
        .long_long => try w.print("webidl.rt.fromI64({s})", .{val_ident}),
        .unsigned_long_long => try w.print("webidl.rt.fromU64({s})", .{val_ident}),
        .bigint => try w.print("webidl.rt.fromI64(@intCast({s}))", .{val_ident}),
        .float, .unrestricted_float => try w.print("webidl.rt.fromF64(@as(f64, {s}))", .{val_ident}),
        .double, .unrestricted_double => try w.print("webidl.rt.fromF64({s})", .{val_ident}),
        .dom_string, .byte_string, .usv_string => try w.print("webidl.rt.fromStr({s})", .{val_ident}),
        .named => try w.print("{s}.handle", .{val_ident}),
        .nullable => |inner| {
            try w.print("if ({s}) |__v| ", .{val_ident});
            try emitTypeToHandle(w, gpa, inner.*, "__v");
            try w.writeAll(" else webidl.rt.nullHandle()");
        },
        .promise => |inner| try emitTypeToHandle(w, gpa, inner.*, val_ident),
        else => try w.writeAll("@compileError(\"webidl2zig: marshaling not yet implemented for this type\")"),
    }
}

/// Emit an expression that converts a `webidl.rt.Handle` stored in `h_ident` into
/// the Zig type corresponding to model type `t`.
fn emitHandleToType(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    t: model.Type,
    h_ident: []const u8,
) common.Error!void {
    switch (t) {
        .boolean => try w.print("webidl.rt.toBool({s})", .{h_ident}),
        .byte => try w.print("@as(i8, @intCast(webidl.rt.toI32({s})))", .{h_ident}),
        .short => try w.print("@as(i16, @intCast(webidl.rt.toI32({s})))", .{h_ident}),
        .long => try w.print("webidl.rt.toI32({s})", .{h_ident}),
        .octet => try w.print("@as(u8, @intCast(webidl.rt.toU32({s})))", .{h_ident}),
        .unsigned_short => try w.print("@as(u16, @intCast(webidl.rt.toU32({s})))", .{h_ident}),
        .unsigned_long => try w.print("webidl.rt.toU32({s})", .{h_ident}),
        .long_long => try w.print("webidl.rt.toI64({s})", .{h_ident}),
        .unsigned_long_long => try w.print("webidl.rt.toU64({s})", .{h_ident}),
        .bigint => try w.print("@as(i128, webidl.rt.toI64({s}))", .{h_ident}),
        .float, .unrestricted_float => try w.print("@as(f32, @floatCast(webidl.rt.toF64({s})))", .{h_ident}),
        .double, .unrestricted_double => try w.print("webidl.rt.toF64({s})", .{h_ident}),
        .dom_string, .byte_string, .usv_string => try w.print("webidl.rt.toStr({s})", .{h_ident}),
        .named => |name| {
            const n = naming.zigIdent(gpa, name) catch return error.OutOfMemory;
            defer gpa.free(n);
            try w.print("{s}{{ .handle = {s} }}", .{ n, h_ident });
        },
        .nullable => |inner| {
            try w.print("if ({s} != 0) ", .{h_ident});
            try emitHandleToType(w, gpa, inner.*, h_ident);
            try w.writeAll(" else null");
        },
        .promise => |inner| try emitHandleToType(w, gpa, inner.*, h_ident),
        else => try w.writeAll("@compileError(\"webidl2zig: marshaling not yet implemented for this type\")"),
    }
}

// Unit tests

const testing = std.testing;

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
        "//! Generated by webidl2zig (client style). Do not edit.\n\nconst webidl = @import(\"webidl\");\n\n",
        aw.writer.buffered(),
    );
}

test "emit: handle wrapper with constant and getter" {
    var constants = [_]model.Constant{
        .{ .name = "MAX", .type = .unsigned_short, .value = .{ .integer = 255 } },
    };
    var attrs = [_]model.Attribute{
        .{ .name = "value", .type = .long, .readonly = true, .is_static = false, .stringifier = false, .inherit = false },
    };
    const iface = model.Interface{
        .name = "Foo",
        .inherits = null,
        .constants = &constants,
        .attributes = &attrs,
        .operations = &.{},
        .constructors = &.{},
        .mixin = false,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitInterface(&aw.writer, testing.allocator, iface);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "handle: webidl.rt.Handle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const MAX: u16 = 255;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn get_value") != null);
    try testing.expect(std.mem.indexOf(u8, out, "webidl.rt.getAttr") != null);
    // No setter because readonly
    try testing.expect(std.mem.indexOf(u8, out, "pub fn set_value") == null);
}

test "emit: non-readonly attr gets setter" {
    var attrs = [_]model.Attribute{
        .{ .name = "count", .type = .long, .readonly = false, .is_static = false, .stringifier = false, .inherit = false },
    };
    const iface = model.Interface{
        .name = "Counter",
        .inherits = null,
        .constants = &.{},
        .attributes = &attrs,
        .operations = &.{},
        .constructors = &.{},
        .mixin = false,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitInterface(&aw.writer, testing.allocator, iface);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "pub fn set_count") != null);
    try testing.expect(std.mem.indexOf(u8, out, "webidl.rt.setAttr") != null);
}

test "emit: operation with dom_string arg" {
    var args = [_]model.Argument{
        .{ .name = "type", .type = .dom_string, .optional = false, .variadic = false, .default = null },
    };
    var ops = [_]model.Operation{
        .{ .name = "addEventListener", .return_type = .undefined, .args = &args, .special = null, .is_static = false, .stringifier = false },
    };
    const iface = model.Interface{
        .name = "EventTarget",
        .inherits = null,
        .constants = &.{},
        .attributes = &.{},
        .operations = &ops,
        .constructors = &.{},
        .mixin = false,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitInterface(&aw.writer, testing.allocator, iface);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "webidl.rt.callMethod") != null);
    try testing.expect(std.mem.indexOf(u8, out, "webidl.rt.fromStr") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@\"type\"") != null);
}

test "client emitInterface: attribute named 'type' gets valid getter" {
    var attrs = [_]model.Attribute{
        .{ .name = "type", .type = .dom_string, .readonly = true, .is_static = false, .stringifier = false, .inherit = false },
    };
    const iface = model.Interface{
        .name = "Input",
        .inherits = null,
        .constants = &.{},
        .attributes = &attrs,
        .operations = &.{},
        .constructors = &.{},
        .mixin = false,
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitInterface(&aw.writer, testing.allocator, iface);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "pub fn get_type") != null);
    try testing.expect(std.mem.indexOf(u8, out, "get_@") == null);
}

test "golden: client/minimal" {
    const fixture = @embedFile("../../test/fixtures/minimal.webidl");
    const expected = @embedFile("../../test/golden/client/minimal.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .client, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "golden: client/coverage" {
    const fixture = @embedFile("../../test/fixtures/coverage.webidl");
    const expected = @embedFile("../../test/golden/client/coverage.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .client, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "client emitTypeToHandle: bigint uses intCast not @as" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitTypeToHandle(&aw.writer, testing.allocator, .bigint, "myval");
    const out = aw.writer.buffered();
    // Must use @intCast, not @as which would be illegal narrowing
    try testing.expect(std.mem.indexOf(u8, out, "@intCast") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@as(i64") == null);
}

test "client emitTypeToHandle: nullable wraps with if/else" {
    var inner: model.Type = .long;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitTypeToHandle(&aw.writer, testing.allocator, .{ .nullable = &inner }, "opt_val");
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "if (opt_val)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "nullHandle") != null);
}

test "client emitHandleToType: promise recurses to inner type" {
    var inner: model.Type = .dom_string;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitHandleToType(&aw.writer, testing.allocator, .{ .promise = &inner }, "_h");
    const out = aw.writer.buffered();
    // Promise<DOMString> -> toStr like DOMString
    try testing.expect(std.mem.indexOf(u8, out, "toStr") != null);
}

// Pull the runtime module into the test graph so it is type-checked.
test {
    _ = @import("../runtime/client.zig");
}
