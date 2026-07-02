//! Host / implementation-side emitter: turns the normalized model into Zig
//! interface skeletons meant to be implemented natively (struct + VTable +
//! thin wrappers). The implementer fills in a VTable struct and calls the
//! wrappers.
//!
//! Rules:
//!   - Mixin interfaces are skipped (folded in by the resolver).
//!   - All definition lists are sorted by name for deterministic output.
//!   - Enums and dictionaries are emitted the same way as model_only.zig.
//!   - Callbacks are emitted as function-pointer type aliases.
//!   - Each concrete interface becomes a struct with:
//!       - pub const fields for IDL constants
//!       - a `vtable: *const VTable` field (recover the impl with @fieldParentPtr)
//!       - a nested `pub const VTable` with fn-pointer fields for every
//!         attribute getter/setter and every named operation
//!       - thin pub wrapper methods that forward to the vtable

const std = @import("std");
const model = @import("../model.zig");
const naming = @import("../naming.zig");
const common = @import("common.zig");

/// Emit all definitions in `defs` as host-style Zig source to `w`.
pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, defs: model.Definitions) common.Error!void {
    try common.header(w, .host);

    // Constructors reference std.Io and std.mem.Allocator, so pull in std.
    var needs_std = false;
    for (defs.interfaces) |iface| {
        if (!iface.mixin and iface.constructors.len > 0) needs_std = true;
    }
    if (needs_std) try w.writeAll("const std = @import(\"std\");\n\n");

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

/// Interface: host-style with impl/vtable fields and thin wrapper methods.
fn emitInterface(w: *std.Io.Writer, gpa: std.mem.Allocator, iface: model.Interface) common.Error!void {
    const ident = naming.zigIdent(gpa, iface.name) catch return error.OutOfMemory;
    defer gpa.free(ident);

    if (iface.inherits) |base| {
        try w.print("/// Inherits: {s}\n", .{base});
    }
    try w.print("pub const {s} = struct {{\n", .{ident});

    // IDL constants
    for (iface.constants) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }

    // Sorted attributes: all attrs sorted, but static vs instance treated differently
    const sorted_attrs = gpa.dupe(model.Attribute, iface.attributes) catch return error.OutOfMemory;
    defer gpa.free(sorted_attrs);
    std.mem.sort(model.Attribute, sorted_attrs, {}, struct {
        fn less(_: void, a: model.Attribute, b: model.Attribute) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);

    // Collect and sort instance operations (named or special, not static)
    var ops_list: std.ArrayList(model.Operation) = .empty;
    defer ops_list.deinit(gpa);
    var static_ops_list: std.ArrayList(model.Operation) = .empty;
    defer static_ops_list.deinit(gpa);
    for (iface.operations) |op| {
        if (op.is_static) {
            if (op.name != null or op.special != null) {
                static_ops_list.append(gpa, op) catch return error.OutOfMemory;
            }
        } else if (op.name != null or op.special != null) {
            ops_list.append(gpa, op) catch return error.OutOfMemory;
        }
    }
    const named_ops = ops_list.items;
    std.mem.sort(model.Operation, named_ops, {}, struct {
        fn less(_: void, a: model.Operation, b_op: model.Operation) bool {
            const an = a.name orelse (if (a.special) |s| common.specialOpName(s) else "");
            const bn = b_op.name orelse (if (b_op.special) |s| common.specialOpName(s) else "");
            return std.mem.lessThan(u8, an, bn);
        }
    }.less);

    // Count instance attrs for vtable check (exclude static)
    var instance_attrs_count: usize = 0;
    for (sorted_attrs) |attr| {
        if (!attr.is_static) instance_attrs_count += 1;
    }
    const has_vtable = instance_attrs_count > 0 or named_ops.len > 0 or iface.constructors.len > 0;

    if (has_vtable) {
        if (iface.constants.len > 0) try w.writeByte('\n');
        try w.writeAll("    vtable: *const VTable,\n");
        try w.writeAll("    refs: usize = 1,\n");
        try w.writeByte('\n');

        // VTable definition: instance attrs first (sorted), then instance ops (sorted)
        try w.writeAll("    pub const VTable = struct {\n");
        for (sorted_attrs) |attr| {
            if (attr.is_static) continue; // static attrs are emitted as bare fns below
            const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
            defer gpa.free(getter_raw);
            const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
            defer gpa.free(getter_ident);
            try w.print("        {s}: *const fn (self: *{s}) ", .{ getter_ident, ident });
            try common.zigType(w, gpa, attr.type);
            try w.writeAll(",\n");
            if (!attr.readonly) {
                const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
                defer gpa.free(setter_raw);
                const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
                defer gpa.free(setter_ident);
                try w.print("        {s}: *const fn (self: *{s}, value: ", .{ setter_ident, ident });
                try common.zigType(w, gpa, attr.type);
                try w.writeAll(") void,\n");
            }
        }
        for (named_ops) |op| {
            const raw_name = op.name orelse (if (op.special) |s| common.specialOpName(s) else continue);
            const op_ident = naming.zigIdent(gpa, raw_name) catch return error.OutOfMemory;
            defer gpa.free(op_ident);
            try w.print("        {s}: *const fn (self: *{s}", .{ op_ident, ident });
            for (op.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}: ", .{arg_ident});
                if (arg.optional and arg.default == null) {
                    try w.writeByte('?');
                }
                try common.zigArgType(w, gpa, arg);
            }
            try w.writeAll(") ");
            try common.zigType(w, gpa, op.return_type);
            try w.writeAll(",\n");
        }
        // Constructor fn-pointers in VTable
        for (iface.constructors, 0..) |ctor, ci| {
            const ctor_name = if (ci == 0) @as([]const u8, "construct") else try std.fmt.allocPrint(gpa, "construct{d}", .{ci});
            defer if (ci > 0) gpa.free(ctor_name);
            try w.print("        {s}: *const fn (gpa: std.mem.Allocator, io: std.Io", .{ctor_name});
            for (ctor.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}: ", .{arg_ident});
                try common.zigArgType(w, gpa, arg);
            }
            try w.print(") *{s},\n", .{ident});
        }
        // Destructor fn-pointer: impl frees its own storage when refs hit zero.
        try w.print("        destroy: *const fn (self: *{s}) void,\n", .{ident});
        try w.writeAll("    };\n");

        // Thin wrapper methods for instance attrs
        for (sorted_attrs) |attr| {
            if (attr.is_static) continue; // handled below
            const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
            defer gpa.free(getter_raw);
            const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
            defer gpa.free(getter_ident);
            try w.writeByte('\n');
            try w.print("    pub fn {s}(self: *{s}) ", .{ getter_ident, ident });
            try common.zigType(w, gpa, attr.type);
            try w.writeAll(" {\n");
            try w.print("        return self.vtable.{s}(self);\n", .{getter_ident});
            try w.writeAll("    }\n");
            if (!attr.readonly) {
                const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
                defer gpa.free(setter_raw);
                const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
                defer gpa.free(setter_ident);
                try w.writeByte('\n');
                try w.print("    pub fn {s}(self: *{s}, value: ", .{ setter_ident, ident });
                try common.zigType(w, gpa, attr.type);
                try w.writeAll(") void {\n");
                try w.print("        self.vtable.{s}(self, value);\n", .{setter_ident});
                try w.writeAll("    }\n");
            }
        }

        // Thin wrapper methods for instance ops (named and special)
        for (named_ops) |op| {
            const raw_name = op.name orelse (if (op.special) |s| common.specialOpName(s) else continue);
            const op_ident = naming.zigIdent(gpa, raw_name) catch return error.OutOfMemory;
            defer gpa.free(op_ident);
            try w.writeByte('\n');
            try w.print("    pub fn {s}(self: *{s}", .{ op_ident, ident });
            for (op.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}: ", .{arg_ident});
                if (arg.optional and arg.default == null) {
                    try w.writeByte('?');
                }
                try common.zigArgType(w, gpa, arg);
            }
            try w.writeAll(") ");
            try common.zigType(w, gpa, op.return_type);
            try w.writeAll(" {\n");
            try w.print("        return self.vtable.{s}(self", .{op_ident});
            for (op.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}", .{arg_ident});
            }
            try w.writeAll(");\n");
            try w.writeAll("    }\n");
        }

        // Constructor wrapper methods
        for (iface.constructors, 0..) |ctor, ci| {
            const ctor_name = if (ci == 0) @as([]const u8, "construct") else try std.fmt.allocPrint(gpa, "construct{d}", .{ci});
            defer if (ci > 0) gpa.free(ctor_name);
            try w.writeByte('\n');
            try w.print("    pub fn {s}(gpa: std.mem.Allocator, io: std.Io, vtable: *const {s}.VTable", .{ ctor_name, ident });
            for (ctor.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}: ", .{arg_ident});
                try common.zigArgType(w, gpa, arg);
            }
            try w.print(") *{s} {{\n", .{ident});
            try w.print("        return vtable.{s}(gpa, io", .{ctor_name});
            for (ctor.args) |arg| {
                const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
                defer gpa.free(arg_ident);
                try w.print(", {s}", .{arg_ident});
            }
            try w.writeAll(");\n    }\n");
        }

        // Reference counting: atomic refs, destroy via vtable at zero.
        try w.print("\n    pub fn ref(self: *{s}) void {{\n", .{ident});
        try w.writeAll("        _ = @atomicRmw(usize, &self.refs, .Add, 1, .monotonic);\n    }\n");
        try w.print("\n    pub fn unref(self: *{s}) void {{\n", .{ident});
        try w.writeAll("        if (@atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel) == 1) self.vtable.destroy(self);\n    }\n");
    }

    // Static attributes: emitted as bare pub fns (no self, no vtable)
    for (sorted_attrs) |attr| {
        if (!attr.is_static) continue;
        const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
        defer gpa.free(getter_raw);
        const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
        defer gpa.free(getter_ident);
        try w.writeByte('\n');
        try w.print("    pub fn {s}() ", .{getter_ident});
        try common.zigType(w, gpa, attr.type);
        try w.writeAll(" { unreachable; }\n");
        if (!attr.readonly) {
            const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
            defer gpa.free(setter_raw);
            const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
            defer gpa.free(setter_ident);
            try w.writeByte('\n');
            try w.print("    pub fn {s}(value: ", .{setter_ident});
            try common.zigType(w, gpa, attr.type);
            try w.writeAll(") void { _ = value; unreachable; }\n");
        }
    }

    // Static operations: emitted as bare pub fns (no self, no vtable)
    for (static_ops_list.items) |op| {
        const raw_name = op.name orelse (if (op.special) |s| common.specialOpName(s) else continue);
        const op_ident = naming.zigIdent(gpa, raw_name) catch return error.OutOfMemory;
        defer gpa.free(op_ident);
        try w.writeByte('\n');
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
        try w.writeAll(" {");
        for (op.args) |arg| {
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try w.print(" _ = {s};", .{arg_ident});
        }
        try w.writeAll(" unreachable; }\n");
    }

    try w.writeAll("};\n");
}

/// Namespace: struct with constants, attributes, and operations (all static).
fn emitNamespace(w: *std.Io.Writer, gpa: std.mem.Allocator, ns: model.Namespace) common.Error!void {
    const ident = naming.zigIdent(gpa, ns.name) catch return error.OutOfMemory;
    defer gpa.free(ident);
    try w.print("pub const {s} = struct {{\n", .{ident});

    // Constants
    for (ns.constants) |c| {
        const c_ident = naming.zigIdent(gpa, c.name) catch return error.OutOfMemory;
        defer gpa.free(c_ident);
        try w.print("    pub const {s}: ", .{c_ident});
        try common.zigType(w, gpa, c.type);
        try w.writeAll(" = ");
        try common.zigConstValue(w, c.value);
        try w.writeAll(";\n");
    }

    // Attributes (all static in a namespace)
    const sorted_attrs = gpa.dupe(model.Attribute, ns.attributes) catch return error.OutOfMemory;
    defer gpa.free(sorted_attrs);
    std.mem.sort(model.Attribute, sorted_attrs, {}, struct {
        fn less(_: void, a: model.Attribute, b: model.Attribute) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (sorted_attrs) |attr| {
        const getter_raw = try std.fmt.allocPrint(gpa, "get_{s}", .{attr.name});
        defer gpa.free(getter_raw);
        const getter_ident = naming.zigIdent(gpa, getter_raw) catch return error.OutOfMemory;
        defer gpa.free(getter_ident);
        try w.print("    pub fn {s}() ", .{getter_ident});
        try common.zigType(w, gpa, attr.type);
        try w.writeAll(" { unreachable; }\n");
        if (!attr.readonly) {
            const setter_raw = try std.fmt.allocPrint(gpa, "set_{s}", .{attr.name});
            defer gpa.free(setter_raw);
            const setter_ident = naming.zigIdent(gpa, setter_raw) catch return error.OutOfMemory;
            defer gpa.free(setter_ident);
            try w.print("    pub fn {s}(value: ", .{setter_ident});
            try common.zigType(w, gpa, attr.type);
            try w.writeAll(") void { _ = value; unreachable; }\n");
        }
    }

    // Operations (all static in a namespace)
    const sorted_ops = gpa.dupe(model.Operation, ns.operations) catch return error.OutOfMemory;
    defer gpa.free(sorted_ops);
    std.mem.sort(model.Operation, sorted_ops, {}, struct {
        fn less(_: void, a: model.Operation, b: model.Operation) bool {
            const an = a.name orelse "";
            const bn = b.name orelse "";
            return std.mem.lessThan(u8, an, bn);
        }
    }.less);
    for (sorted_ops) |op| {
        const raw_name = op.name orelse continue;
        const op_ident = naming.zigIdent(gpa, raw_name) catch return error.OutOfMemory;
        defer gpa.free(op_ident);
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
        try w.writeAll(" {");
        for (op.args) |arg| {
            const arg_ident = naming.zigIdent(gpa, arg.name) catch return error.OutOfMemory;
            defer gpa.free(arg_ident);
            try w.print(" _ = {s};", .{arg_ident});
        }
        try w.writeAll(" unreachable; }\n");
    }

    try w.writeAll("};\n");
}

// Unit tests

const testing = std.testing;

test "host emitEnum: sorted values" {
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

test "host emitInterface: constants only (no vtable)" {
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

test "host emitInterface: readonly attribute gets getter only" {
    var attrs = [_]model.Attribute{
        .{ .name = "count", .type = .long, .readonly = true, .is_static = false, .stringifier = false, .inherit = false },
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
    try testing.expect(std.mem.indexOf(u8, out, "get_count") != null);
    try testing.expect(std.mem.indexOf(u8, out, "set_count") == null);
}

test "host emitInterface: writable attribute gets getter and setter" {
    var attrs = [_]model.Attribute{
        .{ .name = "label", .type = .dom_string, .readonly = false, .is_static = false, .stringifier = false, .inherit = false },
    };
    const iface = model.Interface{
        .name = "Widget",
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
    try testing.expect(std.mem.indexOf(u8, out, "get_label") != null);
    try testing.expect(std.mem.indexOf(u8, out, "set_label") != null);
}

test "host emitInterface: operation vtable entry and wrapper" {
    var args = [_]model.Argument{
        .{ .name = "code", .type = .long, .optional = false, .variadic = false, .default = null },
    };
    var ops = [_]model.Operation{
        .{ .name = "close", .return_type = .undefined, .args = &args, .special = null, .is_static = false, .stringifier = false },
    };
    const iface = model.Interface{
        .name = "Session",
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
    try testing.expect(std.mem.indexOf(u8, out, "close: *const fn (self: *Session, code: i32) void,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn close(self: *Session, code: i32) void {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return self.vtable.close(self, code);") != null);
}

test "host emit: mixin interface is skipped" {
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
        "//! Generated by webidl2zig (host style). Do not edit.\n\n",
        aw.writer.buffered(),
    );
}

test "host emitInterface: attribute named 'type' gets valid getter/setter" {
    var attrs = [_]model.Attribute{
        .{ .name = "type", .type = .dom_string, .readonly = false, .is_static = false, .stringifier = false, .inherit = false },
    };
    const iface = model.Interface{
        .name = "Widget",
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
    try testing.expect(std.mem.indexOf(u8, out, "get_type") != null);
    try testing.expect(std.mem.indexOf(u8, out, "set_type") != null);
    try testing.expect(std.mem.indexOf(u8, out, "get_@") == null);
}

test "golden: host/minimal" {
    const fixture = @embedFile("../../test/fixtures/minimal.webidl");
    const expected = @embedFile("../../test/golden/host/minimal.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .host, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "golden: host/coverage" {
    const fixture = @embedFile("../../test/fixtures/coverage.webidl");
    const expected = @embedFile("../../test/golden/host/coverage.zig");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try @import("common.zig").generate(testing.allocator, fixture, .host, &aw.writer);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}
