//! WebIDL tokenizer: converts a source string into a flat stream of tokens.

const std = @import("std");

pub const Location = struct {
    line: u32,
    column: u32,
    offset: u32,
};

pub const Kind = enum {
    identifier,
    integer,
    decimal,
    string,
    other,
    eof,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    loc: Location,
};

pub const Tokenizer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    column: u32,
    /// When true, skip Gecko C-preprocessor directive lines (`#ifdef`, `#endif`, ...).
    mozilla: bool = false,

    pub fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0, .line = 1, .column = 1 };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.src.len) {
            return .{ .kind = .eof, .text = "", .loc = self.loc() };
        }

        const start_loc = self.loc();
        const start = self.pos;
        const c = self.src[self.pos];

        if (c == '"') {
            self.pos += 1;
            self.column += 1;
            while (self.pos < self.src.len and self.src[self.pos] != '"') {
                self.advance();
            }
            if (self.pos < self.src.len) {
                self.pos += 1;
                self.column += 1;
            }
            return .{ .kind = .string, .text = self.src[start..self.pos], .loc = start_loc };
        }

        // Ellipsis
        if (self.pos + 2 < self.src.len and
            self.src[self.pos] == '.' and
            self.src[self.pos + 1] == '.' and
            self.src[self.pos + 2] == '.')
        {
            self.pos += 3;
            self.column += 3;
            return .{ .kind = .other, .text = self.src[start..self.pos], .loc = start_loc };
        }

        // Number: digit, '.' then digit, or '-' then either.
        if (isDecimalStart(self.src, self.pos)) {
            return self.readNumber(start, start_loc);
        }

        // Identifier: [_-]?[A-Za-z][0-9A-Za-z_-]*
        if (isIdentStart(c)) {
            return self.readIdent(start, start_loc);
        }

        self.pos += 1;
        self.column += 1;
        return .{ .kind = .other, .text = self.src[start..self.pos], .loc = start_loc };
    }

    fn loc(self: *const Tokenizer) Location {
        return .{ .line = self.line, .column = self.column, .offset = self.pos };
    }

    fn advance(self: *Tokenizer) void {
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.pos += 1;
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
                continue;
            }
            // Gecko C-preprocessor directive line, skip to end of line. Mozilla mode only since '#' is invalid WebIDL.
            if (self.mozilla and c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                    self.column += 1;
                }
                continue;
            }
            // Line comment
            if (self.pos + 1 < self.src.len and c == '/' and self.src[self.pos + 1] == '/') {
                self.pos += 2;
                self.column += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                    self.column += 1;
                }
                continue;
            }
            // Block comment
            if (self.pos + 1 < self.src.len and c == '/' and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                self.column += 2;
                while (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        self.column += 2;
                        break;
                    }
                    self.advance();
                }
                continue;
            }
            break;
        }
    }

    fn readNumber(self: *Tokenizer, start: u32, start_loc: Location) Token {
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
            self.column += 1;
        }

        var is_float = false;

        // Hex integer
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '0' and
            (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            self.column += 2;
            while (self.pos < self.src.len and isHexDigit(self.src[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
            return .{ .kind = .integer, .text = self.src[start..self.pos], .loc = start_loc };
        }

        // Octal 0[0-7]*, only when the next char is an octal digit, else plain zero.
        if (self.pos < self.src.len and self.src[self.pos] == '0' and
            self.pos + 1 < self.src.len and isOctalDigit(self.src[self.pos + 1]))
        {
            self.pos += 1;
            self.column += 1;
            while (self.pos < self.src.len and isOctalDigit(self.src[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
            return .{ .kind = .integer, .text = self.src[start..self.pos], .loc = start_loc };
        }

        const had_leading_dot = self.pos < self.src.len and self.src[self.pos] == '.';
        if (!had_leading_dot) {
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
        }

        // Dot makes it a float.
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
        }

        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
                self.column += 1;
            }
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
        }

        const kind: Kind = if (is_float) .decimal else .integer;
        return .{ .kind = kind, .text = self.src[start..self.pos], .loc = start_loc };
    }

    fn readIdent(self: *Tokenizer, start: u32, start_loc: Location) Token {
        // [_-]?[A-Za-z][0-9A-Za-z_-]*
        if (self.pos < self.src.len and (self.src[self.pos] == '_' or self.src[self.pos] == '-')) {
            self.pos += 1;
            self.column += 1;
        }
        // Mandatory letter.
        if (self.pos < self.src.len and isAlpha(self.src[self.pos])) {
            self.pos += 1;
            self.column += 1;
        }
        while (self.pos < self.src.len and isIdentContinue(self.src[self.pos])) {
            self.pos += 1;
            self.column += 1;
        }
        return .{ .kind = .identifier, .text = self.src[start..self.pos], .loc = start_loc };
    }
};

fn isDecimalStart(src: []const u8, pos: u32) bool {
    if (pos >= src.len) return false;
    const c = src[pos];
    if (isDigit(c)) return true;
    if (c == '.' and pos + 1 < src.len and isDigit(src[pos + 1])) return true;
    if (c == '-' and pos + 1 < src.len) {
        const n = src[pos + 1];
        if (isDigit(n)) return true;
        if (n == '.' and pos + 2 < src.len and isDigit(src[pos + 2])) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return c == '_' or c == '-' or isAlpha(c);
}

fn isIdentContinue(c: u8) bool {
    return isAlpha(c) or isDigit(c) or c == '_' or c == '-';
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

const testing = std.testing;

test "tokenizer: eof on empty input" {
    var t = Tokenizer.init("");
    const tok = t.next();
    try testing.expectEqual(Kind.eof, tok.kind);
}

test "tokenizer: identifier simple" {
    var t = Tokenizer.init("foo");
    const tok = t.next();
    try testing.expectEqual(Kind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
    try testing.expectEqual(Kind.eof, t.next().kind);
}

test "tokenizer: identifier with leading underscore" {
    var t = Tokenizer.init("_foo");
    const tok = t.next();
    try testing.expectEqual(Kind.identifier, tok.kind);
    try testing.expectEqualStrings("_foo", tok.text);
}

test "tokenizer: identifier with leading dash" {
    var t = Tokenizer.init("-foo");
    const tok = t.next();
    try testing.expectEqual(Kind.identifier, tok.kind);
    try testing.expectEqualStrings("-foo", tok.text);
}

test "tokenizer: decimal integer" {
    var t = Tokenizer.init("123");
    const tok = t.next();
    try testing.expectEqual(Kind.integer, tok.kind);
    try testing.expectEqualStrings("123", tok.text);
}

test "tokenizer: hex integer" {
    var t = Tokenizer.init("0xFF");
    const tok = t.next();
    try testing.expectEqual(Kind.integer, tok.kind);
    try testing.expectEqualStrings("0xFF", tok.text);
}

test "tokenizer: octal integer" {
    var t = Tokenizer.init("077");
    const tok = t.next();
    try testing.expectEqual(Kind.integer, tok.kind);
    try testing.expectEqualStrings("077", tok.text);
}

test "tokenizer: negative integer" {
    var t = Tokenizer.init("-42");
    const tok = t.next();
    try testing.expectEqual(Kind.integer, tok.kind);
    try testing.expectEqualStrings("-42", tok.text);
}

test "tokenizer: decimal float" {
    var t = Tokenizer.init("3.14");
    const tok = t.next();
    try testing.expectEqual(Kind.decimal, tok.kind);
    try testing.expectEqualStrings("3.14", tok.text);
}

test "tokenizer: float with exponent" {
    var t = Tokenizer.init("1e10");
    const tok = t.next();
    try testing.expectEqual(Kind.decimal, tok.kind);
    try testing.expectEqualStrings("1e10", tok.text);
}

test "tokenizer: float leading dot" {
    var t = Tokenizer.init(".5");
    const tok = t.next();
    try testing.expectEqual(Kind.decimal, tok.kind);
    try testing.expectEqualStrings(".5", tok.text);
}

test "tokenizer: negative float" {
    var t = Tokenizer.init("-1.5e-3");
    const tok = t.next();
    try testing.expectEqual(Kind.decimal, tok.kind);
    try testing.expectEqualStrings("-1.5e-3", tok.text);
}

test "tokenizer: string literal" {
    var t = Tokenizer.init("\"hello world\"");
    const tok = t.next();
    try testing.expectEqual(Kind.string, tok.kind);
    try testing.expectEqualStrings("\"hello world\"", tok.text);
}

test "tokenizer: ellipsis" {
    var t = Tokenizer.init("...");
    const tok = t.next();
    try testing.expectEqual(Kind.other, tok.kind);
    try testing.expectEqualStrings("...", tok.text);
}

test "tokenizer: punctuation" {
    var t = Tokenizer.init(";");
    const tok = t.next();
    try testing.expectEqual(Kind.other, tok.kind);
    try testing.expectEqualStrings(";", tok.text);
}

test "tokenizer: line comment skipped" {
    var t = Tokenizer.init("// comment\nfoo");
    const tok = t.next();
    try testing.expectEqual(Kind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
}

test "tokenizer: block comment skipped" {
    var t = Tokenizer.init("/* block comment */foo");
    const tok = t.next();
    try testing.expectEqual(Kind.identifier, tok.kind);
    try testing.expectEqualStrings("foo", tok.text);
}

test "tokenizer: location tracking" {
    var t = Tokenizer.init("foo\nbar");
    const t1 = t.next();
    try testing.expectEqual(@as(u32, 1), t1.loc.line);
    try testing.expectEqual(@as(u32, 1), t1.loc.column);
    const t2 = t.next();
    try testing.expectEqual(@as(u32, 2), t2.loc.line);
    try testing.expectEqual(@as(u32, 1), t2.loc.column);
}

test "tokenizer: mixed input" {
    var t = Tokenizer.init("interface Foo { attribute long x; };");
    const kinds = [_]Kind{ .identifier, .identifier, .other, .identifier, .identifier, .identifier, .other, .other, .other };
    const texts = [_][]const u8{ "interface", "Foo", "{", "attribute", "long", "x", ";", "}", ";" };
    for (kinds, texts) |expected_kind, expected_text| {
        const tok = t.next();
        try testing.expectEqual(expected_kind, tok.kind);
        try testing.expectEqualStrings(expected_text, tok.text);
    }
    try testing.expectEqual(Kind.eof, t.next().kind);
}
