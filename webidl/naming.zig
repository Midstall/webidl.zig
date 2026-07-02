//! Naming utilities: convert WebIDL identifiers to valid Zig identifiers.

const std = @import("std");

/// All Zig 0.16 keywords that must be escaped as @"...".
/// Note: async/await are NOT keywords in Zig 0.16 and are intentionally omitted.
/// suspend/resume/nosuspend/anyframe ARE still keywords and are kept.
const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
    .{ "nosuspend", {} },
    .{ "null", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "try", {} },
    .{ "type", {} },
    .{ "undefined", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "usingnamespace", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
    // Built-in types that collide with keywords in practice
    .{ "bool", {} },
    .{ "true", {} },
    .{ "false", {} },
    // Zig primitive types (not true keywords but invalid as bare identifiers in context)
    .{ "void", {} },
    .{ "noreturn", {} },
    .{ "anyopaque", {} },
    .{ "anyerror", {} },
    .{ "comptime_int", {} },
    .{ "comptime_float", {} },
    .{ "usize", {} },
    .{ "isize", {} },
    .{ "f16", {} },
    .{ "f32", {} },
    .{ "f64", {} },
    .{ "f80", {} },
    .{ "f128", {} },
    // C interop types
    .{ "c_char", {} },
    .{ "c_short", {} },
    .{ "c_ushort", {} },
    .{ "c_int", {} },
    .{ "c_uint", {} },
    .{ "c_long", {} },
    .{ "c_ulong", {} },
    .{ "c_longlong", {} },
    .{ "c_ulonglong", {} },
    .{ "c_longdouble", {} },
});

/// Convert a WebIDL identifier to a valid Zig identifier.
/// Escapes Zig keywords as @"name". Replaces illegal chars (dashes) with
/// underscores. Caller owns the returned slice.
pub fn zigIdent(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    var sanitized = try gpa.dupe(u8, name);
    defer gpa.free(sanitized);

    // Strip leading underscore (WebIDL [_]identifier escape convention).
    var start: usize = 0;
    if (sanitized.len > 0 and sanitized[0] == '_') {
        start = 1;
    }
    var view = sanitized[start..];

    var buf = try gpa.alloc(u8, view.len);
    defer gpa.free(buf);
    for (view, 0..) |c, i| {
        buf[i] = if (c == '-') '_' else c;
    }
    view = buf;

    // Nothing left after sanitization: fall back to a stable placeholder.
    if (view.len == 0) {
        return gpa.dupe(u8, "empty");
    }

    // Escape Zig integer types like u0..u65535, i0..i65535 (u/i then digits only).
    if (view.len >= 2 and (view[0] == 'u' or view[0] == 'i')) {
        const rest = view[1..];
        var all_digits = rest.len > 0;
        for (rest) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            return std.fmt.allocPrint(gpa, "@\"{s}\"", .{view});
        }
    }

    if (zig_keywords.get(view) != null) {
        return std.fmt.allocPrint(gpa, "@\"{s}\"", .{view});
    }

    // Leading digit would be invalid Zig.
    if (view.len > 0 and view[0] >= '0' and view[0] <= '9') {
        return std.fmt.allocPrint(gpa, "@\"{s}\"", .{view});
    }

    return gpa.dupe(u8, view);
}

/// Check a list of names for collisions after zigIdent conversion.
/// Returns the first colliding name pair found, or null if none.
pub fn checkCollisions(
    gpa: std.mem.Allocator,
    names: []const []const u8,
) !?struct { a: []const u8, b: []const u8 } {
    var seen = std.StringHashMap([]const u8).init(gpa);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
        }
        seen.deinit();
    }

    for (names) |name| {
        const z = try zigIdent(gpa, name);
        defer gpa.free(z);
        if (seen.get(z)) |orig| {
            return .{ .a = orig, .b = name };
        }
        const z_owned = try gpa.dupe(u8, z);
        try seen.put(z_owned, name);
    }
    return null;
}

const testing = std.testing;

test "naming: plain identifier passes through" {
    const result = try zigIdent(testing.allocator, "EventTarget");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("EventTarget", result);
}

test "naming: keyword is escaped" {
    const result = try zigIdent(testing.allocator, "type");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"type\"", result);
}

test "naming: error keyword escaped" {
    const result = try zigIdent(testing.allocator, "error");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"error\"", result);
}

test "naming: const keyword escaped" {
    const result = try zigIdent(testing.allocator, "const");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"const\"", result);
}

test "naming: dash replaced with underscore" {
    const result = try zigIdent(testing.allocator, "dom-string");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("dom_string", result);
}

test "naming: leading underscore stripped" {
    const result = try zigIdent(testing.allocator, "_constructor");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("constructor", result);
}

test "naming: WebIDL names" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "DOMString", .out = "DOMString" },
        .{ .in = "fetch", .out = "fetch" },
        .{ .in = "undefined", .out = "@\"undefined\"" },
        .{ .in = "null", .out = "@\"null\"" },
        .{ .in = "true", .out = "@\"true\"" },
        .{ .in = "false", .out = "@\"false\"" },
    };
    for (cases) |c| {
        const result = try zigIdent(testing.allocator, c.in);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(c.out, result);
    }
}

test "naming: void is escaped" {
    const result = try zigIdent(testing.allocator, "void");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"void\"", result);
}

test "naming: usize is escaped" {
    const result = try zigIdent(testing.allocator, "usize");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"usize\"", result);
}

test "naming: u32 integer type is escaped" {
    const result = try zigIdent(testing.allocator, "u32");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"u32\"", result);
}

test "naming: f64 float type is escaped" {
    const result = try zigIdent(testing.allocator, "f64");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"f64\"", result);
}

test "naming: i128 integer type is escaped" {
    const result = try zigIdent(testing.allocator, "i128");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"i128\"", result);
}

test "naming: c_int is escaped" {
    const result = try zigIdent(testing.allocator, "c_int");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"c_int\"", result);
}

test "naming: comptime_int is escaped" {
    const result = try zigIdent(testing.allocator, "comptime_int");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("@\"comptime_int\"", result);
}

test "naming: plain name not affected by integer check" {
    // 'url' does not match the u[0-9]+ pattern.
    const result = try zigIdent(testing.allocator, "url");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("url", result);
}

test "naming: empty string returns placeholder" {
    const result = try zigIdent(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("empty", result);
}

test "naming: lone underscore returns placeholder" {
    const result = try zigIdent(testing.allocator, "_");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("empty", result);
}

test "naming: multi-underscore not treated as empty" {
    // "__" keeps its second underscore after the leading one is stripped, so not empty.
    const result = try zigIdent(testing.allocator, "__");
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    try testing.expect(!std.mem.eql(u8, result, ""));
}

test "checkCollisions: detects a-b vs a_b collision" {
    const names = [_][]const u8{ "a-b", "a_b" };
    const result = try checkCollisions(testing.allocator, &names);
    try testing.expect(result != null);
}

test "checkCollisions: no collision when unique" {
    const names = [_][]const u8{ "foo", "bar", "baz" };
    const result = try checkCollisions(testing.allocator, &names);
    try testing.expect(result == null);
}
