//! Resolve pass: merges partials, folds mixins, resolves typedefs,
//! and converts the raw AST to the normalized model.
//!
//! Passes (in order):
//!  1. Collect typedefs
//!  2. Index base definitions + duplicate-name detection
//!  3. Merge partial definitions
//!  4. Apply includes (mixin folding)
//!  5. Inheritance validation
//!  6. Convert raw AST to model types
//!  7. Per-definition validation (dup members, callback interface restrictions)

const std = @import("std");
const parse = @import("parse.zig");
const model = @import("model.zig");
const diag_mod = @import("diagnostics.zig");
const parser_mod = @import("parser.zig");
const naming = @import("naming.zig");

// Public surface

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    defs: model.Definitions,
    /// Diagnostic list allocated with the gpa passed to resolve().
    /// Caller must call self.diagnostics.deinit(gpa) separately.
    diagnostics: diag_mod.Diagnostics,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
    }
};

// Internal helpers

const zero_loc: diag_mod.Location = .{ .line = 0, .column = 0, .offset = 0 };

const ConvertCtx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    diags: *diag_mod.Diagnostics,
    typedef_raw: *std.StringHashMap(parse.TypeWithExtendedAttributes),
    typedef_model: *std.StringHashMap(model.Type),
    typedef_visiting: *std.StringHashMap(void),
    known_types: *std.StringHashMap(void),
};

const IfaceBuilder = struct {
    loc: diag_mod.Location,
    name: []const u8,
    inherits: ?[]const u8,
    members: std.ArrayList(parse.InterfaceMember),
    is_callback: bool,
    mixin: bool,
};

const MixinBuilder = struct {
    loc: diag_mod.Location,
    name: []const u8,
    members: std.ArrayList(parse.MixinMember),
};

const DictBuilder = struct {
    loc: diag_mod.Location,
    name: []const u8,
    inherits: ?[]const u8,
    members: std.ArrayList(parse.DictionaryMember),
};

const NsBuilder = struct {
    loc: diag_mod.Location,
    name: []const u8,
    members: std.ArrayList(parse.NamespaceMember),
};

// Entry point

pub fn resolve(gpa: std.mem.Allocator, parsed: *parser_mod.ParseResult) !Resolved {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags: diag_mod.Diagnostics = .{};
    errdefer diags.deinit(gpa);

    // Pass 1: Collect raw typedefs
    var typedef_raw = std.StringHashMap(parse.TypeWithExtendedAttributes).init(gpa);
    defer typedef_raw.deinit();

    for (parsed.defs) |def| {
        if (def != .typedef) continue;
        const td = def.typedef;
        if (typedef_raw.contains(td.name)) {
            try diags.push(gpa, .{ .loc = td.loc, .severity = .err, .msg = "duplicate typedef name", .got = td.name });
        } else {
            try typedef_raw.put(td.name, td.type);
        }
    }

    var typedef_model = std.StringHashMap(model.Type).init(gpa);
    defer typedef_model.deinit();

    var typedef_visiting = std.StringHashMap(void).init(gpa);
    defer typedef_visiting.deinit();

    // Pass 2: Index base definitions + dup detection
    var iface_map = std.StringHashMap(IfaceBuilder).init(gpa);
    defer {
        var it = iface_map.valueIterator();
        while (it.next()) |b| b.members.deinit(gpa);
        iface_map.deinit();
    }

    var mixin_map = std.StringHashMap(MixinBuilder).init(gpa);
    defer {
        var it = mixin_map.valueIterator();
        while (it.next()) |b| b.members.deinit(gpa);
        mixin_map.deinit();
    }

    var dict_map = std.StringHashMap(DictBuilder).init(gpa);
    defer {
        var it = dict_map.valueIterator();
        while (it.next()) |b| b.members.deinit(gpa);
        dict_map.deinit();
    }

    var ns_map = std.StringHashMap(NsBuilder).init(gpa);
    defer {
        var it = ns_map.valueIterator();
        while (it.next()) |b| b.members.deinit(gpa);
        ns_map.deinit();
    }

    var enum_map = std.StringHashMap(parse.Enumeration).init(gpa);
    defer enum_map.deinit();

    var callback_map = std.StringHashMap(parse.Callback).init(gpa);
    defer callback_map.deinit();

    var name_set = std.StringHashMap(void).init(gpa);
    defer name_set.deinit();

    for (parsed.defs) |def| {
        switch (def) {
            .interface => |iface| {
                if (name_set.contains(iface.name)) {
                    try diags.push(gpa, .{ .loc = iface.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = iface.name });
                    continue;
                }
                try name_set.put(iface.name, {});
                var members: std.ArrayList(parse.InterfaceMember) = .empty;
                try members.appendSlice(gpa, iface.members);
                try iface_map.put(iface.name, .{
                    .loc = iface.loc,
                    .name = iface.name,
                    .inherits = iface.inherits,
                    .members = members,
                    .is_callback = false,
                    .mixin = false,
                });
            },
            .interface_mixin => |mx| {
                if (name_set.contains(mx.name)) {
                    try diags.push(gpa, .{ .loc = mx.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = mx.name });
                    continue;
                }
                try name_set.put(mx.name, {});
                var members: std.ArrayList(parse.MixinMember) = .empty;
                try members.appendSlice(gpa, mx.members);
                try mixin_map.put(mx.name, .{
                    .loc = mx.loc,
                    .name = mx.name,
                    .members = members,
                });
            },
            .dictionary => |dict| {
                if (name_set.contains(dict.name)) {
                    try diags.push(gpa, .{ .loc = dict.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = dict.name });
                    continue;
                }
                try name_set.put(dict.name, {});
                var members: std.ArrayList(parse.DictionaryMember) = .empty;
                try members.appendSlice(gpa, dict.members);
                try dict_map.put(dict.name, .{
                    .loc = dict.loc,
                    .name = dict.name,
                    .inherits = dict.inherits,
                    .members = members,
                });
            },
            .namespace => |ns| {
                if (name_set.contains(ns.name)) {
                    try diags.push(gpa, .{ .loc = ns.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = ns.name });
                    continue;
                }
                try name_set.put(ns.name, {});
                var members: std.ArrayList(parse.NamespaceMember) = .empty;
                try members.appendSlice(gpa, ns.members);
                try ns_map.put(ns.name, .{
                    .loc = ns.loc,
                    .name = ns.name,
                    .members = members,
                });
            },
            .enumeration => |en| {
                if (name_set.contains(en.name)) {
                    try diags.push(gpa, .{ .loc = en.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = en.name });
                    continue;
                }
                try name_set.put(en.name, {});
                try enum_map.put(en.name, en);
            },
            .callback => |cb| {
                if (name_set.contains(cb.name)) {
                    try diags.push(gpa, .{ .loc = cb.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = cb.name });
                    continue;
                }
                try name_set.put(cb.name, {});
                try callback_map.put(cb.name, cb);
            },
            .callback_interface => |ci| {
                if (name_set.contains(ci.name)) {
                    try diags.push(gpa, .{ .loc = ci.loc, .severity = .err, .msg = "duplicate top-level definition name", .got = ci.name });
                    continue;
                }
                try name_set.put(ci.name, {});
                var members: std.ArrayList(parse.InterfaceMember) = .empty;
                try members.appendSlice(gpa, ci.members);
                try iface_map.put(ci.name, .{
                    .loc = ci.loc,
                    .name = ci.name,
                    .inherits = ci.inherits,
                    .members = members,
                    .is_callback = true,
                    .mixin = false,
                });
            },
            else => {},
        }
    }

    // Pass 3: Merge partials
    for (parsed.defs) |def| {
        switch (def) {
            .partial_interface => |pi| {
                if (iface_map.getPtr(pi.name)) |b| {
                    try b.members.appendSlice(gpa, pi.members);
                } else {
                    try diags.push(gpa, .{ .loc = pi.loc, .severity = .err, .msg = "partial interface has no base definition", .got = pi.name });
                }
            },
            .partial_mixin => |pm| {
                if (mixin_map.getPtr(pm.name)) |b| {
                    try b.members.appendSlice(gpa, pm.members);
                } else {
                    try diags.push(gpa, .{ .loc = pm.loc, .severity = .err, .msg = "partial interface mixin has no base definition", .got = pm.name });
                }
            },
            .partial_dictionary => |pd| {
                if (dict_map.getPtr(pd.name)) |b| {
                    try b.members.appendSlice(gpa, pd.members);
                } else {
                    try diags.push(gpa, .{ .loc = pd.loc, .severity = .err, .msg = "partial dictionary has no base definition", .got = pd.name });
                }
            },
            .partial_namespace => |pn| {
                if (ns_map.getPtr(pn.name)) |b| {
                    try b.members.appendSlice(gpa, pn.members);
                } else {
                    try diags.push(gpa, .{ .loc = pn.loc, .severity = .err, .msg = "partial namespace has no base definition", .got = pn.name });
                }
            },
            else => {},
        }
    }

    // Pass 4: Apply includes (mixin folding)
    for (parsed.defs) |def| {
        if (def != .includes) continue;
        const inc = def.includes;
        const mx_ptr = mixin_map.getPtr(inc.mixin) orelse {
            try diags.push(gpa, .{ .loc = inc.loc, .severity = .err, .msg = "includes references unknown mixin", .got = inc.mixin });
            continue;
        };
        const iface_ptr = iface_map.getPtr(inc.interface) orelse {
            try diags.push(gpa, .{ .loc = inc.loc, .severity = .err, .msg = "includes references unknown interface", .got = inc.interface });
            continue;
        };
        for (mx_ptr.members.items) |mm| {
            const im: parse.InterfaceMember = switch (mm) {
                .constant => |c| .{ .constant = c },
                .attribute => |a| .{ .attribute = a },
                .operation => |o| .{ .operation = o },
                .stringifier => .{ .operation = .{
                    .loc = zero_loc,
                    .extended_attributes = &.{},
                    .special = null,
                    .return_type = .dom_string,
                    .name = null,
                    .args = &.{},
                    .is_static = false,
                    .stringifier = true,
                } },
            };
            try iface_ptr.members.append(gpa, im);
        }
    }

    // Pass 5: Inheritance validation
    {
        var it = iface_map.iterator();
        while (it.next()) |e| {
            const b = e.value_ptr;
            if (b.inherits) |base| {
                if (!iface_map.contains(base)) {
                    try diags.push(gpa, .{ .loc = b.loc, .severity = .err, .msg = "interface inherits from unknown base", .got = base });
                }
            }
        }
    }
    {
        var it = dict_map.iterator();
        while (it.next()) |e| {
            const b = e.value_ptr;
            if (b.inherits) |base| {
                if (!dict_map.contains(base)) {
                    try diags.push(gpa, .{ .loc = b.loc, .severity = .err, .msg = "dictionary inherits from unknown base", .got = base });
                }
            }
        }
    }

    // Known-types set for unknown-type validation. Mixins and namespaces are
    // intentionally excluded: they are not valid type references.
    var known_types = std.StringHashMap(void).init(gpa);
    defer known_types.deinit();
    {
        var it = iface_map.keyIterator();
        while (it.next()) |k| try known_types.put(k.*, {});
    }
    {
        var it = dict_map.keyIterator();
        while (it.next()) |k| try known_types.put(k.*, {});
    }
    {
        var it = enum_map.keyIterator();
        while (it.next()) |k| try known_types.put(k.*, {});
    }
    {
        var it = callback_map.keyIterator();
        while (it.next()) |k| try known_types.put(k.*, {});
    }
    {
        var it = typedef_raw.keyIterator();
        while (it.next()) |k| try known_types.put(k.*, {});
    }

    // Pass 6: Convert to model
    var ctx = ConvertCtx{
        .gpa = gpa,
        .arena = arena,
        .diags = &diags,
        .typedef_raw = &typedef_raw,
        .typedef_model = &typedef_model,
        .typedef_visiting = &typedef_visiting,
        .known_types = &known_types,
    };

    var iface_out: std.ArrayList(model.Interface) = .empty;
    defer iface_out.deinit(gpa);
    {
        var it = iface_map.iterator();
        while (it.next()) |e| {
            try iface_out.append(gpa, try convertInterface(&ctx, e.value_ptr));
        }
    }
    {
        var it = mixin_map.iterator();
        while (it.next()) |e| {
            try iface_out.append(gpa, try convertMixin(&ctx, e.value_ptr));
        }
    }

    var dict_out: std.ArrayList(model.Dictionary) = .empty;
    defer dict_out.deinit(gpa);
    {
        var it = dict_map.iterator();
        while (it.next()) |e| {
            try dict_out.append(gpa, try convertDictionary(&ctx, e.value_ptr));
        }
    }

    var enum_out: std.ArrayList(model.Enum) = .empty;
    defer enum_out.deinit(gpa);
    {
        var it = enum_map.iterator();
        while (it.next()) |e| {
            try enum_out.append(gpa, try convertEnum(&ctx, e.value_ptr.*));
        }
    }

    var cb_out: std.ArrayList(model.Callback) = .empty;
    defer cb_out.deinit(gpa);
    {
        var it = callback_map.iterator();
        while (it.next()) |e| {
            try cb_out.append(gpa, try convertCallback(&ctx, e.value_ptr.*));
        }
    }

    var ns_out: std.ArrayList(model.Namespace) = .empty;
    defer ns_out.deinit(gpa);
    {
        var it = ns_map.iterator();
        while (it.next()) |e| {
            try ns_out.append(gpa, try convertNamespace(&ctx, e.value_ptr));
        }
    }

    const final_defs = model.Definitions{
        .interfaces = try arena.dupe(model.Interface, iface_out.items),
        .dictionaries = try arena.dupe(model.Dictionary, dict_out.items),
        .enums = try arena.dupe(model.Enum, enum_out.items),
        .callbacks = try arena.dupe(model.Callback, cb_out.items),
        .namespaces = try arena.dupe(model.Namespace, ns_out.items),
    };

    return Resolved{
        .arena = arena_state,
        .defs = final_defs,
        .diagnostics = diags,
    };
}

// Type conversion

fn convertType(ctx: *ConvertCtx, raw: parse.Type) error{OutOfMemory}!model.Type {
    return switch (raw) {
        .boolean => .boolean,
        .byte => .byte,
        .octet => .octet,
        .bigint => .bigint,
        .undefined => .undefined,
        .any => .any,
        .object => .object,
        .symbol => .symbol,
        .unsigned_short => .unsigned_short,
        .unsigned_long => .unsigned_long,
        .unsigned_long_long => .unsigned_long_long,
        .short => .short,
        .long => .long,
        .long_long => .long_long,
        .float => .float,
        .double => .double,
        .unrestricted_float => .unrestricted_float,
        .unrestricted_double => .unrestricted_double,
        .dom_string => .dom_string,
        .byte_string => .byte_string,
        .usv_string => .usv_string,
        .buffer => |b| .{ .buffer = convertBufferKind(b) },
        .nullable => |inner| blk: {
            const t = try ctx.arena.create(model.Type);
            t.* = try convertType(ctx, inner.*);
            break :blk .{ .nullable = t };
        },
        .sequence => |twa| blk: {
            const t = try ctx.arena.create(model.Type);
            t.* = try convertType(ctx, twa.type.*);
            break :blk .{ .sequence = t };
        },
        .frozen_array => |twa| blk: {
            const t = try ctx.arena.create(model.Type);
            t.* = try convertType(ctx, twa.type.*);
            break :blk .{ .frozen_array = t };
        },
        .observable_array => |twa| blk: {
            const t = try ctx.arena.create(model.Type);
            t.* = try convertType(ctx, twa.type.*);
            break :blk .{ .observable_array = t };
        },
        .promise => |p| blk: {
            const t = try ctx.arena.create(model.Type);
            t.* = try convertType(ctx, p.return_type.*);
            break :blk .{ .promise = t };
        },
        .record => |r| blk: {
            const k = try ctx.arena.create(model.Type);
            k.* = try convertType(ctx, r.key.type.*);
            const v = try ctx.arena.create(model.Type);
            v.* = try convertType(ctx, r.value.type.*);
            break :blk .{ .record = .{ .key = k, .value = v } };
        },
        .union_of => |members| blk: {
            var out: std.ArrayList(model.Type) = .empty;
            for (members) |m| {
                try out.append(ctx.arena, try convertType(ctx, m.type.*));
            }
            break :blk .{ .union_of = out.items };
        },
        .identifier => |name| blk: {
            // Typedef: flatten recursively.
            if (ctx.typedef_raw.contains(name)) {
                break :blk try resolveTypedef(ctx, name);
            }
            if (!ctx.known_types.contains(name)) {
                try ctx.diags.push(ctx.gpa, .{ .loc = zero_loc, .severity = .err, .msg = "reference to unknown named type", .got = name });
            }
            break :blk .{ .named = try ctx.arena.dupe(u8, name) };
        },
    };
}

fn resolveTypedef(ctx: *ConvertCtx, name: []const u8) error{OutOfMemory}!model.Type {
    if (ctx.typedef_model.get(name)) |t| return t;

    if (ctx.typedef_visiting.contains(name)) {
        try ctx.diags.push(ctx.gpa, .{ .loc = zero_loc, .severity = .err, .msg = "typedef cycle detected", .got = name });
        return .any;
    }

    const raw_twa = ctx.typedef_raw.get(name) orelse return .any;

    try ctx.typedef_visiting.put(name, {});
    defer _ = ctx.typedef_visiting.remove(name);

    const resolved = try convertType(ctx, raw_twa.type.*);
    try ctx.typedef_model.put(name, resolved);
    return resolved;
}

fn convertBufferKind(b: parse.BufferType) model.BufferKind {
    return switch (b) {
        .array_buffer => .array_buffer,
        .shared_array_buffer => .shared_array_buffer,
        .data_view => .data_view,
        .int8_array => .int8_array,
        .int16_array => .int16_array,
        .int32_array => .int32_array,
        .uint8_array => .uint8_array,
        .uint16_array => .uint16_array,
        .uint32_array => .uint32_array,
        .uint8_clamped_array => .uint8_clamped_array,
        .bigint64_array => .bigint64_array,
        .biguint64_array => .biguint64_array,
        .float16_array => .float16_array,
        .float32_array => .float32_array,
        .float64_array => .float64_array,
    };
}

fn convertValueLiteral(v: parse.ValueLiteral) model.ValueLiteral {
    return switch (v) {
        .boolean => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .decimal => |d| .{ .decimal = d },
        .string => |s| .{ .string = s },
        .null_value => .null_value,
        .undefined_value => .undefined_value,
        .empty_sequence => .empty_sequence,
        .empty_dict => .empty_dict,
        .positive_infinity => .positive_infinity,
        .negative_infinity => .negative_infinity,
        .nan => .nan,
    };
}

fn convertArgument(ctx: *ConvertCtx, arg: parse.Argument) !model.Argument {
    return .{
        .name = try ctx.arena.dupe(u8, arg.name),
        .type = try convertType(ctx, arg.type.type.*),
        .optional = arg.optional,
        .variadic = arg.variadic,
        .default = if (arg.default) |d| convertValueLiteral(d) else null,
    };
}

fn convertArguments(ctx: *ConvertCtx, args: []const parse.Argument) ![]model.Argument {
    var out: std.ArrayList(model.Argument) = .empty;
    for (args) |arg| try out.append(ctx.arena, try convertArgument(ctx, arg));
    return out.items;
}

fn convertConstant(ctx: *ConvertCtx, c: parse.Constant) !model.Constant {
    return .{
        .name = try ctx.arena.dupe(u8, c.name),
        .type = try convertType(ctx, c.type),
        .value = convertValueLiteral(c.value),
    };
}

fn convertAttribute(ctx: *ConvertCtx, a: parse.Attribute) !model.Attribute {
    return .{
        .name = try ctx.arena.dupe(u8, a.name),
        .type = try convertType(ctx, a.type.type.*),
        .readonly = a.readonly,
        .is_static = a.is_static,
        .stringifier = a.stringifier,
        .inherit = a.inherit,
    };
}

fn convertSpecialOp(s: parse.SpecialOperation) model.SpecialOperation {
    return switch (s) {
        .getter => .getter,
        .setter => .setter,
        .deleter => .deleter,
        .legacy_caller => .legacy_caller,
    };
}

fn convertOperation(ctx: *ConvertCtx, op: parse.Operation) !model.Operation {
    return .{
        .name = if (op.name) |n| try ctx.arena.dupe(u8, n) else null,
        .return_type = try convertType(ctx, op.return_type),
        .args = try convertArguments(ctx, op.args),
        .special = if (op.special) |s| convertSpecialOp(s) else null,
        .is_static = op.is_static,
        .stringifier = op.stringifier,
    };
}

fn convertConstructor(ctx: *ConvertCtx, c: parse.Constructor) !model.Constructor {
    return .{ .args = try convertArguments(ctx, c.args) };
}

// Definition conversion

fn convertInterface(ctx: *ConvertCtx, b: *const IfaceBuilder) !model.Interface {
    var constants: std.ArrayList(model.Constant) = .empty;
    var attributes: std.ArrayList(model.Attribute) = .empty;
    var operations: std.ArrayList(model.Operation) = .empty;
    var constructors: std.ArrayList(model.Constructor) = .empty;

    var member_names = std.StringHashMap(void).init(ctx.gpa);
    defer member_names.deinit();

    for (b.members.items) |m| {
        switch (m) {
            .constant => |c| {
                if (member_names.contains(c.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = c.loc, .severity = .err, .msg = "duplicate member name in interface", .got = c.name });
                } else {
                    try member_names.put(c.name, {});
                    try constants.append(ctx.arena, try convertConstant(ctx, c));
                }
            },
            .attribute => |a| {
                if (member_names.contains(a.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = a.loc, .severity = .err, .msg = "duplicate member name in interface", .got = a.name });
                } else {
                    try member_names.put(a.name, {});
                    try attributes.append(ctx.arena, try convertAttribute(ctx, a));
                }
            },
            .operation => |op| {
                if (b.is_callback and op.special != null) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = op.loc, .severity = .err, .msg = "callback interface may not contain special operations", .got = null });
                }
                if (op.name == null and op.special == null and !op.stringifier) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = op.loc, .severity = .warning, .msg = "anonymous operation with no special keyword; dropped from output", .got = b.name });
                }
                // Operations are allowed overloads. Named ones share the name bucket.
                if (op.name) |n| {
                    if (!member_names.contains(n)) try member_names.put(n, {});
                }
                try operations.append(ctx.arena, try convertOperation(ctx, op));
            },
            .constructor => |c| {
                if (b.is_callback) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = c.loc, .severity = .err, .msg = "callback interface may not contain constructors", .got = null });
                } else {
                    try constructors.append(ctx.arena, try convertConstructor(ctx, c));
                }
            },
            .iterable => |it| {
                if (b.is_callback) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = it.loc, .severity = .err, .msg = "callback interface may not contain iterable", .got = null });
                } else {
                    try ctx.diags.push(ctx.gpa, .{ .loc = it.loc, .severity = .warning, .msg = "iterable not modeled; dropped from output", .got = b.name });
                }
            },
            .maplike => |ml| {
                if (b.is_callback) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = ml.loc, .severity = .err, .msg = "callback interface may not contain maplike", .got = null });
                } else {
                    try ctx.diags.push(ctx.gpa, .{ .loc = ml.loc, .severity = .warning, .msg = "maplike not modeled; dropped from output", .got = b.name });
                }
            },
            .setlike => |sl| {
                if (b.is_callback) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = sl.loc, .severity = .err, .msg = "callback interface may not contain setlike", .got = null });
                } else {
                    try ctx.diags.push(ctx.gpa, .{ .loc = sl.loc, .severity = .warning, .msg = "setlike not modeled; dropped from output", .got = b.name });
                }
            },
        }
    }

    return .{
        .name = try ctx.arena.dupe(u8, b.name),
        .inherits = if (b.inherits) |h| try ctx.arena.dupe(u8, h) else null,
        .constants = constants.items,
        .attributes = attributes.items,
        .operations = operations.items,
        .constructors = constructors.items,
        .mixin = b.mixin,
    };
}

fn convertMixin(ctx: *ConvertCtx, b: *const MixinBuilder) !model.Interface {
    var constants: std.ArrayList(model.Constant) = .empty;
    var attributes: std.ArrayList(model.Attribute) = .empty;
    var operations: std.ArrayList(model.Operation) = .empty;

    var member_names = std.StringHashMap(void).init(ctx.gpa);
    defer member_names.deinit();

    for (b.members.items) |m| {
        switch (m) {
            .constant => |c| {
                if (member_names.contains(c.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = c.loc, .severity = .err, .msg = "duplicate member name in mixin", .got = c.name });
                } else {
                    try member_names.put(c.name, {});
                    try constants.append(ctx.arena, try convertConstant(ctx, c));
                }
            },
            .attribute => |a| {
                if (member_names.contains(a.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = a.loc, .severity = .err, .msg = "duplicate member name in mixin", .got = a.name });
                } else {
                    try member_names.put(a.name, {});
                    try attributes.append(ctx.arena, try convertAttribute(ctx, a));
                }
            },
            .operation => |op| {
                if (op.name) |n| {
                    if (!member_names.contains(n)) try member_names.put(n, {});
                }
                try operations.append(ctx.arena, try convertOperation(ctx, op));
            },
            .stringifier => {
                // Bare stringifier in mixin: synthesise an anonymous stringifier operation.
                try operations.append(ctx.arena, .{
                    .name = null,
                    .return_type = .dom_string,
                    .args = &.{},
                    .special = null,
                    .is_static = false,
                    .stringifier = true,
                });
            },
        }
    }

    return .{
        .name = try ctx.arena.dupe(u8, b.name),
        .inherits = null,
        .constants = constants.items,
        .attributes = attributes.items,
        .operations = operations.items,
        .constructors = &.{},
        .mixin = true,
    };
}

fn convertDictionary(ctx: *ConvertCtx, b: *const DictBuilder) !model.Dictionary {
    var members: std.ArrayList(model.DictMember) = .empty;

    var member_names = std.StringHashMap(void).init(ctx.gpa);
    defer member_names.deinit();

    for (b.members.items) |m| {
        if (member_names.contains(m.name)) {
            try ctx.diags.push(ctx.gpa, .{ .loc = m.loc, .severity = .err, .msg = "duplicate dictionary member name", .got = m.name });
            continue;
        }
        try member_names.put(m.name, {});
        try members.append(ctx.arena, .{
            .name = try ctx.arena.dupe(u8, m.name),
            .type = try convertType(ctx, m.type.type.*),
            .required = m.required,
            .default = if (m.default) |d| convertValueLiteral(d) else null,
        });
    }

    {
        var names_tmp: std.ArrayList([]const u8) = .empty;
        defer names_tmp.deinit(ctx.gpa);
        for (members.items) |m| try names_tmp.append(ctx.gpa, m.name);
        if (try naming.checkCollisions(ctx.gpa, names_tmp.items)) |pair| {
            try ctx.diags.push(ctx.gpa, .{
                .loc = zero_loc,
                .severity = .warning,
                .msg = "dictionary members collide after Zig identifier normalization",
                .got = pair.a,
            });
        }
    }

    return .{
        .name = try ctx.arena.dupe(u8, b.name),
        .inherits = if (b.inherits) |h| try ctx.arena.dupe(u8, h) else null,
        .members = members.items,
    };
}

fn convertEnum(ctx: *ConvertCtx, en: parse.Enumeration) !model.Enum {
    var values: std.ArrayList([]const u8) = .empty;
    for (en.values) |v| try values.append(ctx.arena, try ctx.arena.dupe(u8, v.value));

    if (try naming.checkCollisions(ctx.gpa, values.items)) |pair| {
        try ctx.diags.push(ctx.gpa, .{
            .loc = zero_loc,
            .severity = .warning,
            .msg = "enum values collide after Zig identifier normalization",
            .got = pair.a,
        });
    }

    return .{
        .name = try ctx.arena.dupe(u8, en.name),
        .values = values.items,
    };
}

fn convertCallback(ctx: *ConvertCtx, cb: parse.Callback) !model.Callback {
    return .{
        .name = try ctx.arena.dupe(u8, cb.name),
        .return_type = try convertType(ctx, cb.return_type),
        .args = try convertArguments(ctx, cb.args),
    };
}

fn convertNamespace(ctx: *ConvertCtx, b: *const NsBuilder) !model.Namespace {
    var constants: std.ArrayList(model.Constant) = .empty;
    var attributes: std.ArrayList(model.Attribute) = .empty;
    var operations: std.ArrayList(model.Operation) = .empty;

    var member_names = std.StringHashMap(void).init(ctx.gpa);
    defer member_names.deinit();

    for (b.members.items) |m| {
        switch (m) {
            .constant => |c| {
                if (member_names.contains(c.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = c.loc, .severity = .err, .msg = "duplicate member name in namespace", .got = c.name });
                } else {
                    try member_names.put(c.name, {});
                    try constants.append(ctx.arena, try convertConstant(ctx, c));
                }
            },
            .attribute => |a| {
                if (member_names.contains(a.name)) {
                    try ctx.diags.push(ctx.gpa, .{ .loc = a.loc, .severity = .err, .msg = "duplicate member name in namespace", .got = a.name });
                } else {
                    try member_names.put(a.name, {});
                    try attributes.append(ctx.arena, try convertAttribute(ctx, a));
                }
            },
            .operation => |op| {
                if (op.name) |n| {
                    if (!member_names.contains(n)) try member_names.put(n, {});
                }
                try operations.append(ctx.arena, try convertOperation(ctx, op));
            },
        }
    }

    return .{
        .name = try ctx.arena.dupe(u8, b.name),
        .constants = constants.items,
        .attributes = attributes.items,
        .operations = operations.items,
    };
}

// Tests

const testing = std.testing;

test "resolve: stub compiles" {
    _ = std.mem;
}

test "resolve: typedef flattening basic" {
    const src =
        \\typedef long MyLong;
        \\interface Foo {
        \\  MyLong doThing();
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), res.defs.interfaces.len);
    const iface = res.defs.interfaces[0];
    try testing.expectEqualStrings("Foo", iface.name);
    try testing.expectEqual(@as(usize, 1), iface.operations.len);
    // typedef MyLong -> long, so return_type should be .long
    try testing.expectEqual(model.Type.long, iface.operations[0].return_type);
}

test "resolve: typedef sequence flattening" {
    const src =
        \\typedef sequence<long> LongSeq;
        \\interface Bar {
        \\  LongSeq getItems();
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), res.defs.interfaces.len);
    const op = res.defs.interfaces[0].operations[0];
    // LongSeq -> sequence<long>
    try testing.expect(op.return_type == .sequence);
    try testing.expect(op.return_type.sequence.* == .long);
}

test "resolve: typedef cycle diagnostic" {
    // A -> B -> A is a cycle
    const src =
        \\typedef B AlphaType;
        \\typedef AlphaType B;
        \\interface Test {
        \\  AlphaType x();
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    // Should have at least one error diagnostic about the cycle
    try testing.expect(res.diagnostics.list.items.len > 0);
    var found_cycle = false;
    for (res.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "cycle") != null) {
            found_cycle = true;
            break;
        }
    }
    try testing.expect(found_cycle);
}

test "resolve: partial interface merge" {
    const src =
        \\interface Node {
        \\  attribute long x;
        \\};
        \\partial interface Node {
        \\  attribute long y;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), res.defs.interfaces.len);
    try testing.expectEqual(@as(usize, 2), res.defs.interfaces[0].attributes.len);
}

test "resolve: partial without base produces diagnostic" {
    const src =
        \\partial interface Ghost {
        \\  attribute long x;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.diagnostics.list.items[0].msg, "partial") != null);
}

test "resolve: includes mixin application" {
    const src =
        \\interface mixin Serializable {
        \\  attribute long id;
        \\};
        \\interface Document {};
        \\Document includes Serializable;
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);

    // Find the Document interface (not the mixin)
    var doc: ?model.Interface = null;
    for (res.defs.interfaces) |iface| {
        if (std.mem.eql(u8, iface.name, "Document")) doc = iface;
    }
    try testing.expect(doc != null);
    try testing.expectEqual(@as(usize, 1), doc.?.attributes.len);
    try testing.expectEqualStrings("id", doc.?.attributes[0].name);
}

test "resolve: includes missing mixin diagnostic" {
    const src =
        \\interface Foo {};
        \\Foo includes NoSuchMixin;
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.diagnostics.list.items[0].msg, "mixin") != null);
}

test "resolve: inheritance linking" {
    const src =
        \\interface Base {
        \\  attribute long x;
        \\};
        \\interface Child : Base {
        \\  attribute long y;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);

    var child: ?model.Interface = null;
    for (res.defs.interfaces) |iface| {
        if (std.mem.eql(u8, iface.name, "Child")) child = iface;
    }
    try testing.expect(child != null);
    try testing.expect(child.?.inherits != null);
    try testing.expectEqualStrings("Base", child.?.inherits.?);
}

test "resolve: missing base inheritance diagnostic" {
    const src =
        \\interface Child : NoSuchBase {
        \\  attribute long y;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    var found = false;
    for (res.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "inherits") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "resolve: unknown type reference diagnostic" {
    const src =
        \\interface Foo {
        \\  NoSuchType doThing();
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    var found = false;
    for (res.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "unknown named type") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "resolve: duplicate member diagnostic" {
    const src =
        \\interface Foo {
        \\  attribute long x;
        \\  attribute long x;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    var found = false;
    for (res.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "duplicate member") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "resolve: callback interface allows const and regular ops" {
    const src =
        \\callback interface EventListener {
        \\  undefined handleEvent(long event);
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), res.defs.interfaces.len);
    try testing.expectEqual(@as(usize, 1), res.defs.interfaces[0].operations.len);
}

test "resolve: callback interface rejects constructor" {
    const src =
        \\callback interface Bad {
        \\  constructor();
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expect(res.diagnostics.list.items.len > 0);
    var found = false;
    for (res.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "callback interface") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "resolve: end-to-end multi-definition" {
    const src =
        \\typedef sequence<long> LongSeq;
        \\
        \\enum Status { "ok", "error" };
        \\
        \\interface mixin Named {
        \\  attribute DOMString name;
        \\};
        \\
        \\interface Base {
        \\  readonly attribute long id;
        \\};
        \\
        \\interface Child : Base {
        \\  constructor(long x);
        \\  LongSeq getNumbers();
        \\};
        \\Child includes Named;
        \\
        \\dictionary Options {
        \\  required DOMString url;
        \\  long timeout = 0;
        \\};
        \\
        \\callback OnDone = undefined (long code);
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);

    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), res.diagnostics.list.items.len);

    // Enums
    try testing.expectEqual(@as(usize, 1), res.defs.enums.len);
    try testing.expectEqualStrings("Status", res.defs.enums[0].name);
    try testing.expectEqual(@as(usize, 2), res.defs.enums[0].values.len);

    // Callbacks
    try testing.expectEqual(@as(usize, 1), res.defs.callbacks.len);
    try testing.expectEqualStrings("OnDone", res.defs.callbacks[0].name);

    // Dictionaries
    try testing.expectEqual(@as(usize, 1), res.defs.dictionaries.len);
    try testing.expectEqual(@as(usize, 2), res.defs.dictionaries[0].members.len);

    // Interfaces: Base, Child, Named(mixin)
    try testing.expectEqual(@as(usize, 3), res.defs.interfaces.len);

    // Find Child
    var child: ?model.Interface = null;
    for (res.defs.interfaces) |iface| {
        if (std.mem.eql(u8, iface.name, "Child")) child = iface;
    }
    try testing.expect(child != null);
    // inherits Base
    try testing.expect(child.?.inherits != null);
    try testing.expectEqualStrings("Base", child.?.inherits.?);
    // constructor
    try testing.expectEqual(@as(usize, 1), child.?.constructors.len);
    // operation getNumbers -> sequence<long> (from typedef LongSeq)
    try testing.expectEqual(@as(usize, 1), child.?.operations.len);
    try testing.expect(child.?.operations[0].return_type == .sequence);
    // attribute from Named mixin (via includes)
    try testing.expectEqual(@as(usize, 1), child.?.attributes.len);
    try testing.expectEqualStrings("name", child.?.attributes[0].name);
}

test "resolve: enum values that collide in Zig produce warning diagnostic" {
    // "a-b" and "a_b" both normalize to a_b
    const src = "enum E { \"a-b\", \"a_b\" };";
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);
    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);
    // Should have at least one warning diagnostic about the collision
    try testing.expect(res.diagnostics.list.items.len > 0);
}

test "resolve: iterable on regular interface produces warning diagnostic" {
    const src =
        \\interface Coll {
        \\  iterable<long>;
        \\};
    ;
    var parsed = try parser_mod.parse_src(testing.allocator, src);
    defer parsed.deinit();
    defer parsed.diagnostics.deinit(testing.allocator);
    var res = try resolve(testing.allocator, &parsed);
    defer res.deinit();
    defer res.diagnostics.deinit(testing.allocator);
    var found = false;
    for (res.diagnostics.list.items) |d| {
        if (d.severity == .warning and std.mem.indexOf(u8, d.msg, "iterable") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
