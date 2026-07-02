//! Diagnostic collection for parse errors and warnings.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
pub const Location = tokenizer.Location;

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    loc: Location,
    severity: Severity,
    expected: ?[]const u8 = null,
    got: ?[]const u8 = null,
    msg: []const u8,

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) !void {
        const sev = switch (self.severity) {
            .err => "error",
            .warning => "warning",
        };
        try writer.print("{s}:{d}:{d}: {s}: {s}", .{
            "<input>",
            self.loc.line,
            self.loc.column,
            sev,
            self.msg,
        });
        if (self.expected) |e| {
            try writer.print(" (expected '{s}'", .{e});
            if (self.got) |g| {
                try writer.print(", got '{s}'", .{g});
            }
            try writer.print(")", .{});
        }
    }
};

pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn push(self: *Diagnostics, gpa: std.mem.Allocator, d: Diagnostic) !void {
        try self.list.append(gpa, d);
    }

    pub fn deinit(self: *Diagnostics, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }
};

const testing = std.testing;

test "diagnostic format error" {
    const d = Diagnostic{
        .loc = .{ .line = 3, .column = 7, .offset = 42 },
        .severity = .err,
        .msg = "unexpected token",
        .expected = "identifier",
        .got = ";",
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.format(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "error") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3:7") != null);
    try testing.expect(std.mem.indexOf(u8, out, "identifier") != null);
    try testing.expect(std.mem.indexOf(u8, out, ";") != null);
}

test "diagnostic format warning no expected/got" {
    const d = Diagnostic{
        .loc = .{ .line = 1, .column = 1, .offset = 0 },
        .severity = .warning,
        .msg = "deprecated feature",
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.format(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "warning") != null);
    try testing.expect(std.mem.indexOf(u8, out, "deprecated feature") != null);
}

test "diagnostics push and deinit" {
    var diags: Diagnostics = .{};
    defer diags.deinit(testing.allocator);
    try diags.push(testing.allocator, .{
        .loc = .{ .line = 1, .column = 1, .offset = 0 },
        .severity = .err,
        .msg = "test error",
    });
    try testing.expectEqual(@as(usize, 1), diags.list.items.len);
}
