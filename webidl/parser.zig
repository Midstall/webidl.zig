//! Recursive-descent WebIDL parser (slice 1).
//! Produces a parse.Definitions AST allocated in an arena.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parse = @import("parse.zig");
const diag = @import("diagnostics.zig");

const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const Kind = tokenizer.Kind;
const Location = tokenizer.Location;

pub const Error = error{ ParseError, OutOfMemory };

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    defs: parse.Definitions,
    diagnostics: diag.Diagnostics,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
        // caller owns diagnostics (allocated with gpa), must deinit(gpa) separately.
    }
};

// Savepoint type

const Mark = struct {
    saved_buf: [LOOKAHEAD]Token,
    saved_buf_len: usize,
    inner_pos: u32,
    inner_line: u32,
    inner_col: u32,
};

// Parser

const LOOKAHEAD = 4;

pub const Parser = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    tok: Tokenizer,
    buf: [LOOKAHEAD]Token,
    buf_len: usize,
    /// When true, accept Mozilla/Gecko WebIDL extensions (forward declarations,
    /// string- and integer-valued extended attributes). Off = strict WebIDL.
    mozilla: bool = false,

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8) Parser {
        return .{
            .gpa = gpa,
            .arena = arena,
            .tok = Tokenizer.init(src),
            .buf = undefined,
            .buf_len = 0,
        };
    }

    // Fill the lookahead buffer up to index n (0-based).
    fn fill(self: *Parser, n: usize) void {
        while (self.buf_len <= n) {
            self.buf[self.buf_len] = self.tok.next();
            self.buf_len += 1;
        }
    }

    pub fn peek(self: *Parser) Token {
        self.fill(0);
        return self.buf[0];
    }

    pub fn peekN(self: *Parser, n: usize) Token {
        std.debug.assert(n < LOOKAHEAD);
        self.fill(n);
        return self.buf[n];
    }

    pub fn next(self: *Parser) Token {
        self.fill(0);
        const t = self.buf[0];
        var i: usize = 0;
        while (i + 1 < self.buf_len) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.buf_len -= 1;
        return t;
    }

    /// Consume a token of kind `other` with the given text. Returns true on match.
    pub fn eatOther(self: *Parser, text: []const u8) bool {
        const t = self.peek();
        if (t.kind == .other and std.mem.eql(u8, t.text, text)) {
            _ = self.next();
            return true;
        }
        return false;
    }

    /// Consume an identifier token whose text equals keyword. Returns true on match.
    pub fn eatKeyword(self: *Parser, kw: []const u8) bool {
        const t = self.peek();
        if (t.kind == .identifier and std.mem.eql(u8, t.text, kw)) {
            _ = self.next();
            return true;
        }
        return false;
    }

    pub fn expectOther(self: *Parser, text: []const u8) !Token {
        const t = self.peek();
        if (t.kind == .other and std.mem.eql(u8, t.text, text)) {
            return self.next();
        }
        return error.ParseError;
    }

    pub fn expectKeyword(self: *Parser, kw: []const u8) !void {
        const t = self.peek();
        if (t.kind == .identifier and std.mem.eql(u8, t.text, kw)) {
            _ = self.next();
            return;
        }
        return error.ParseError;
    }

    pub fn mark(self: *Parser) Mark {
        return .{
            .saved_buf = self.buf,
            .saved_buf_len = self.buf_len,
            .inner_pos = self.tok.pos,
            .inner_line = self.tok.line,
            .inner_col = self.tok.column,
        };
    }

    pub fn reset(self: *Parser, m: Mark) void {
        // restore lookahead buffer and tokenizer state to mark() time.
        self.buf = m.saved_buf;
        self.buf_len = m.saved_buf_len;
        self.tok.pos = m.inner_pos;
        self.tok.line = m.inner_line;
        self.tok.column = m.inner_col;
    }
};

// Full parse entry point

/// Options controlling optional/dialect parser behavior.
pub const ParseOptions = struct {
    /// Accept Mozilla/Gecko WebIDL extensions (forward declarations, string-
    /// and integer-valued extended attributes).
    mozilla: bool = false,
};

/// Parse standard WebIDL (no dialect extensions).
pub fn parse_src(gpa: std.mem.Allocator, src: []const u8) !ParseResult {
    return parse_srcOpts(gpa, src, .{});
}

pub fn parse_srcOpts(gpa: std.mem.Allocator, src: []const u8, opts: ParseOptions) !ParseResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: diag.Diagnostics = .{};

    var p = Parser.init(gpa, arena, src);
    p.mozilla = opts.mozilla;
    p.tok.mozilla = opts.mozilla;

    var defs: std.ArrayList(parse.Definition) = .empty;

    while (p.peek().kind != .eof) {
        const ext_attrs = parseExtendedAttributeList(&p, &diagnostics) catch |err| {
            if (err == error.ParseError) {
                while (p.peek().kind != .eof and !p.eatOther(";")) {
                    _ = p.next();
                }
                continue;
            }
            return err;
        };
        const def = parseDefinition(&p, &diagnostics, ext_attrs) catch |err| {
            if (err == error.ParseError) {
                // Skip to next semicolon for recovery
                while (p.peek().kind != .eof and !p.eatOther(";")) {
                    _ = p.next();
                }
                continue;
            }
            return err;
        };
        try defs.append(arena, def);
    }

    return ParseResult{
        .arena = arena_state,
        .defs = try defs.toOwnedSlice(arena),
        .diagnostics = diagnostics,
    };
}

// Extended attributes

fn parseExtendedAttributeList(p: *Parser, diagnostics: *diag.Diagnostics) Error![]parse.ExtendedAttribute {
    if (!p.eatOther("[")) return &.{};
    var list: std.ArrayList(parse.ExtendedAttribute) = .empty;
    while (true) {
        const attr = try parseExtendedAttribute(p, diagnostics);
        try list.append(p.arena, attr);
        if (!p.eatOther(",")) break;
    }
    _ = p.expectOther("]") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ']' after extended attribute list",
            .expected = "]",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return list.items;
}

fn parseExtendedAttribute(p: *Parser, diagnostics: *diag.Diagnostics) Error!parse.ExtendedAttribute {
    const loc = p.peek().loc;
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = loc,
            .severity = .err,
            .msg = "expected extended attribute name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    const name = name_tok.text;

    if (p.eatOther("=")) {
        // ident or named_arg_list
        const rhs_tok = p.peek();
        if (rhs_tok.kind == .identifier) {
            _ = p.next();
            const rhs = rhs_tok.text;
            if (p.eatOther("(")) {
                // named_arg_list: Name=Rhs(args)
                const args = try parseArgumentList(p, diagnostics);
                _ = p.expectOther(")") catch {
                    try diagnostics.push(p.gpa, .{
                        .loc = p.peek().loc,
                        .severity = .err,
                        .msg = "expected ')' in extended attribute named arg list",
                        .expected = ")",
                        .got = p.peek().text,
                    });
                    return error.ParseError;
                };
                return .{ .loc = loc, .form = .{ .named_arg_list = .{ .name = name, .rhs_name = rhs, .args = args } } };
            }
            // ident: Name=Value
            return .{ .loc = loc, .form = .{ .ident = .{ .name = name, .value = rhs } } };
        }
        // Standard WebIDL wildcard form: [Exposed=*].
        if (rhs_tok.kind == .other and std.mem.eql(u8, rhs_tok.text, "*")) {
            _ = p.next();
            return .{ .loc = loc, .form = .{ .ident = .{ .name = name, .value = rhs_tok.text } } };
        }
        // Gecko/spec extension: string/integer/decimal-valued ext-attr, e.g. [Func="x::y"], [Deprecated=1].
        if (p.mozilla and (rhs_tok.kind == .string or rhs_tok.kind == .integer or rhs_tok.kind == .decimal)) {
            _ = p.next();
            return .{ .loc = loc, .form = .{ .ident = .{ .name = name, .value = rhs_tok.text } } };
        }
        if (p.eatOther("(")) {
            // ident_list: Name=(A,B,...)
            var vals: std.ArrayList([]const u8) = .empty;
            while (true) {
                const v = p.peek();
                // standard: identifiers. mozilla/spec extension also allows integer/string, e.g. [ReflectRange=(0, 8)].
                const ok = v.kind == .identifier or
                    (p.mozilla and (v.kind == .integer or v.kind == .string));
                if (!ok) {
                    try diagnostics.push(p.gpa, .{
                        .loc = v.loc,
                        .severity = .err,
                        .msg = "expected identifier in extended attribute ident list",
                        .expected = "identifier",
                        .got = v.text,
                    });
                    return error.ParseError;
                }
                _ = p.next();
                try vals.append(p.arena, v.text);
                if (!p.eatOther(",")) break;
            }
            _ = p.expectOther(")") catch {
                try diagnostics.push(p.gpa, .{
                    .loc = p.peek().loc,
                    .severity = .err,
                    .msg = "expected ')' in extended attribute ident list",
                    .expected = ")",
                    .got = p.peek().text,
                });
                return error.ParseError;
            };
            return .{ .loc = loc, .form = .{ .ident_list = .{ .name = name, .values = vals.items } } };
        }
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected identifier or '(' after '=' in extended attribute",
            .expected = "identifier or (",
            .got = p.peek().text,
        });
        return error.ParseError;
    }

    if (p.eatOther("(")) {
        // arg_list: Name(args)
        const args = try parseArgumentList(p, diagnostics);
        _ = p.expectOther(")") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected ')' in extended attribute arg list",
                .expected = ")",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return .{ .loc = loc, .form = .{ .arg_list = .{ .name = name, .args = args } } };
    }

    // no_args
    return .{ .loc = loc, .form = .{ .no_args = .{ .name = name } } };
}

// Argument list (used in ext-attrs and operation/callback signatures)

fn parseArgumentList(p: *Parser, diagnostics: *diag.Diagnostics) Error![]parse.Argument {
    var list: std.ArrayList(parse.Argument) = .empty;
    if (p.peek().kind == .eof) return list.items;
    const peek_t = p.peek();
    if (peek_t.kind == .other and std.mem.eql(u8, peek_t.text, ")")) return list.items;

    while (true) {
        const t = p.peek();
        if (t.kind == .eof) break;
        if (t.kind == .other and std.mem.eql(u8, t.text, ")")) break;

        const arg = try parseArgument(p, diagnostics);
        try list.append(p.arena, arg);
        if (!p.eatOther(",")) break;
    }
    return list.items;
}

fn parseArgument(p: *Parser, diagnostics: *diag.Diagnostics) Error!parse.Argument {
    const loc = p.peek().loc;
    const ext_attrs = try parseExtendedAttributeList(p, diagnostics);
    const is_optional = p.eatKeyword("optional");
    const typ = try parseTypeWithExtendedAttributes(p, diagnostics);
    const is_variadic = p.eatOther("...");
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected argument name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    var default_val: ?parse.ValueLiteral = null;
    if (is_optional and p.eatOther("=")) {
        default_val = try parseValueLiteral(p, diagnostics);
    }
    return parse.Argument{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .optional = is_optional,
        .variadic = is_variadic,
        .type = typ,
        .name = name_tok.text,
        .default = default_val,
    };
}

fn parseValueLiteral(p: *Parser, diagnostics: *diag.Diagnostics) !parse.ValueLiteral {
    const t = p.peek();
    if (t.kind == .integer) {
        _ = p.next();
        const v = std.fmt.parseInt(i64, t.text, 0) catch 0;
        return .{ .integer = v };
    }
    if (t.kind == .decimal) {
        _ = p.next();
        const v = std.fmt.parseFloat(f64, t.text) catch 0.0;
        return .{ .decimal = v };
    }
    if (t.kind == .string) {
        _ = p.next();
        const inner = if (t.text.len >= 2) t.text[1 .. t.text.len - 1] else t.text;
        return .{ .string = inner };
    }
    if (t.kind == .identifier) {
        if (std.mem.eql(u8, t.text, "true")) {
            _ = p.next();
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, t.text, "false")) {
            _ = p.next();
            return .{ .boolean = false };
        }
        if (std.mem.eql(u8, t.text, "null")) {
            _ = p.next();
            return .null_value;
        }
        if (std.mem.eql(u8, t.text, "undefined")) {
            _ = p.next();
            return .undefined_value;
        }
        if (std.mem.eql(u8, t.text, "Infinity")) {
            _ = p.next();
            return .positive_infinity;
        }
        if (std.mem.eql(u8, t.text, "NaN")) {
            _ = p.next();
            return .nan;
        }
        // The tokenizer reads "-Infinity" as a single identifier token (leading '-' is valid ident start).
        if (std.mem.eql(u8, t.text, "-Infinity")) {
            _ = p.next();
            return .negative_infinity;
        }
    }
    if (t.kind == .other and std.mem.eql(u8, t.text, "-")) {
        _ = p.next();
        const inf = p.peek();
        if (inf.kind == .identifier and std.mem.eql(u8, inf.text, "Infinity")) {
            _ = p.next();
            return .negative_infinity;
        }
    }
    if (t.kind == .other and std.mem.eql(u8, t.text, "[")) {
        _ = p.next();
        _ = p.expectOther("]") catch {};
        return .empty_sequence;
    }
    if (t.kind == .other and std.mem.eql(u8, t.text, "{")) {
        _ = p.next();
        _ = p.expectOther("}") catch {};
        return .empty_dict;
    }
    try diagnostics.push(p.gpa, .{
        .loc = t.loc,
        .severity = .err,
        .msg = "expected value literal",
        .expected = "literal",
        .got = t.text,
    });
    return error.ParseError;
}

// Type parsing

pub fn parseType(p: *Parser, diagnostics: *diag.Diagnostics) Error!parse.Type {
    // Union: (A or B ...)
    if (p.eatOther("(")) {
        var members: std.ArrayList(parse.TypeWithExtendedAttributes) = .empty;
        while (true) {
            const member = try parseTypeWithExtendedAttributes(p, diagnostics);
            try members.append(p.arena, member);
            if (!p.eatKeyword("or")) break;
        }
        _ = p.expectOther(")") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected ')' after union type",
                .expected = ")",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const t = try p.arena.create(parse.Type);
        const slice = try members.toOwnedSlice(p.arena);
        t.* = .{ .union_of = slice };
        if (p.eatOther("?")) {
            const outer = try p.arena.create(parse.Type);
            outer.* = .{ .nullable = t };
            return outer.*;
        }
        return t.*;
    }

    const tok = p.peek();
    if (tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = tok.loc,
            .severity = .err,
            .msg = "expected type",
            .expected = "type name",
            .got = tok.text,
        });
        return error.ParseError;
    }

    _ = p.next();
    const word = tok.text;

    // Two-word prefixes: unsigned, unrestricted
    if (std.mem.eql(u8, word, "unsigned")) {
        if (p.eatKeyword("short")) return maybeNullable(p, .unsigned_short);
        if (p.eatKeyword("long")) {
            if (p.eatKeyword("long")) return maybeNullable(p, .unsigned_long_long);
            return maybeNullable(p, .unsigned_long);
        }
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected short/long after unsigned",
            .expected = "short or long",
            .got = p.peek().text,
        });
        return error.ParseError;
    }
    if (std.mem.eql(u8, word, "unrestricted")) {
        if (p.eatKeyword("float")) return maybeNullable(p, .unrestricted_float);
        if (p.eatKeyword("double")) return maybeNullable(p, .unrestricted_double);
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected float/double after unrestricted",
            .expected = "float or double",
            .got = p.peek().text,
        });
        return error.ParseError;
    }
    if (std.mem.eql(u8, word, "long")) {
        if (p.eatKeyword("long")) return maybeNullable(p, .long_long);
        return maybeNullable(p, .long);
    }

    // Primitives
    if (std.mem.eql(u8, word, "boolean")) return maybeNullable(p, .boolean);
    if (std.mem.eql(u8, word, "byte")) return maybeNullable(p, .byte);
    if (std.mem.eql(u8, word, "octet")) return maybeNullable(p, .octet);
    if (std.mem.eql(u8, word, "bigint")) return maybeNullable(p, .bigint);
    if (std.mem.eql(u8, word, "undefined")) return maybeNullable(p, .undefined);
    if (std.mem.eql(u8, word, "any")) return maybeNullable(p, .any);
    if (std.mem.eql(u8, word, "object")) return maybeNullable(p, .object);
    if (std.mem.eql(u8, word, "symbol")) return maybeNullable(p, .symbol);
    if (std.mem.eql(u8, word, "short")) return maybeNullable(p, .short);
    if (std.mem.eql(u8, word, "float")) return maybeNullable(p, .float);
    if (std.mem.eql(u8, word, "double")) return maybeNullable(p, .double);

    // String types
    if (std.mem.eql(u8, word, "DOMString")) return maybeNullable(p, .dom_string);
    if (std.mem.eql(u8, word, "ByteString")) return maybeNullable(p, .byte_string);
    if (std.mem.eql(u8, word, "USVString")) return maybeNullable(p, .usv_string);

    // Buffer types
    if (std.mem.eql(u8, word, "ArrayBuffer")) return maybeNullable(p, .{ .buffer = .array_buffer });
    if (std.mem.eql(u8, word, "SharedArrayBuffer")) return maybeNullable(p, .{ .buffer = .shared_array_buffer });
    if (std.mem.eql(u8, word, "DataView")) return maybeNullable(p, .{ .buffer = .data_view });
    if (std.mem.eql(u8, word, "Int8Array")) return maybeNullable(p, .{ .buffer = .int8_array });
    if (std.mem.eql(u8, word, "Int16Array")) return maybeNullable(p, .{ .buffer = .int16_array });
    if (std.mem.eql(u8, word, "Int32Array")) return maybeNullable(p, .{ .buffer = .int32_array });
    if (std.mem.eql(u8, word, "Uint8Array")) return maybeNullable(p, .{ .buffer = .uint8_array });
    if (std.mem.eql(u8, word, "Uint16Array")) return maybeNullable(p, .{ .buffer = .uint16_array });
    if (std.mem.eql(u8, word, "Uint32Array")) return maybeNullable(p, .{ .buffer = .uint32_array });
    if (std.mem.eql(u8, word, "Uint8ClampedArray")) return maybeNullable(p, .{ .buffer = .uint8_clamped_array });
    if (std.mem.eql(u8, word, "BigInt64Array")) return maybeNullable(p, .{ .buffer = .bigint64_array });
    if (std.mem.eql(u8, word, "BigUint64Array")) return maybeNullable(p, .{ .buffer = .biguint64_array });
    if (std.mem.eql(u8, word, "Float16Array")) return maybeNullable(p, .{ .buffer = .float16_array });
    if (std.mem.eql(u8, word, "Float32Array")) return maybeNullable(p, .{ .buffer = .float32_array });
    if (std.mem.eql(u8, word, "Float64Array")) return maybeNullable(p, .{ .buffer = .float64_array });

    // Parameterised types
    if (std.mem.eql(u8, word, "sequence")) {
        _ = try p.expectOther("<");
        const inner = try p.arena.create(parse.TypeWithExtendedAttributes);
        inner.* = try parseTypeWithExtendedAttributes(p, diagnostics);
        _ = p.expectOther(">") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '>' after sequence type",
                .expected = ">",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return maybeNullable(p, .{ .sequence = inner });
    }
    if (std.mem.eql(u8, word, "FrozenArray")) {
        _ = try p.expectOther("<");
        const inner = try p.arena.create(parse.TypeWithExtendedAttributes);
        inner.* = try parseTypeWithExtendedAttributes(p, diagnostics);
        _ = p.expectOther(">") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '>' after FrozenArray type",
                .expected = ">",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return maybeNullable(p, .{ .frozen_array = inner });
    }
    if (std.mem.eql(u8, word, "ObservableArray")) {
        _ = try p.expectOther("<");
        const inner = try p.arena.create(parse.TypeWithExtendedAttributes);
        inner.* = try parseTypeWithExtendedAttributes(p, diagnostics);
        _ = p.expectOther(">") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '>' after ObservableArray type",
                .expected = ">",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return maybeNullable(p, .{ .observable_array = inner });
    }
    if (std.mem.eql(u8, word, "Promise")) {
        _ = try p.expectOther("<");
        const ret = try p.arena.create(parse.Type);
        ret.* = try parseType(p, diagnostics);
        _ = p.expectOther(">") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '>' after Promise return type",
                .expected = ">",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return maybeNullable(p, .{ .promise = .{ .return_type = ret } });
    }
    if (std.mem.eql(u8, word, "record")) {
        _ = try p.expectOther("<");
        const key = try p.arena.create(parse.TypeWithExtendedAttributes);
        key.* = try parseTypeWithExtendedAttributes(p, diagnostics);
        _ = p.expectOther(",") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected ',' between record key and value types",
                .expected = ",",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const val = try p.arena.create(parse.TypeWithExtendedAttributes);
        val.* = try parseTypeWithExtendedAttributes(p, diagnostics);
        _ = p.expectOther(">") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '>' after record value type",
                .expected = ">",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return maybeNullable(p, .{ .record = .{ .key = key, .value = val } });
    }

    // Identifier reference (named type)
    return maybeNullable(p, .{ .identifier = word });
}

fn maybeNullable(p: *Parser, base: parse.Type) Error!parse.Type {
    if (p.eatOther("?")) {
        const inner = try p.arena.create(parse.Type);
        inner.* = base;
        return .{ .nullable = inner };
    }
    return base;
}

pub fn parseTypeWithExtendedAttributes(p: *Parser, diagnostics: *diag.Diagnostics) Error!parse.TypeWithExtendedAttributes {
    const ext_attrs = try parseExtendedAttributeList(p, diagnostics);
    const typ = try parseType(p, diagnostics);
    const typ_ptr = try p.arena.create(parse.Type);
    typ_ptr.* = typ;
    return .{ .extended_attributes = ext_attrs, .type = typ_ptr };
}

// Top-level definition dispatch

fn parseDefinition(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) !parse.Definition {
    const tok = p.peek();
    if (tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = tok.loc,
            .severity = .err,
            .msg = "expected definition keyword",
            .expected = "interface/enum/typedef/...",
            .got = tok.text,
        });
        return error.ParseError;
    }

    if (std.mem.eql(u8, tok.text, "enum")) {
        return parseEnumDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "typedef")) {
        return parseTypedefDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "interface")) {
        return parseInterfaceDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "partial")) {
        return parsePartialDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "dictionary")) {
        return parseDictionaryDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "namespace")) {
        return parseNamespaceDef(p, diagnostics, ext_attrs);
    }
    if (std.mem.eql(u8, tok.text, "callback")) {
        return parseCallbackDef(p, diagnostics, ext_attrs);
    }
    // includes statement: TargetIdent includes MixinIdent ;
    // tok.kind == .identifier is guaranteed by the check at the top of this function.
    const next2 = p.peekN(1);
    if (next2.kind == .identifier and std.mem.eql(u8, next2.text, "includes")) {
        return parseIncludesDef(p, diagnostics, ext_attrs);
    }

    // Unrecognised keyword: skip to next ";"
    try diagnostics.push(p.gpa, .{
        .loc = tok.loc,
        .severity = .err,
        .msg = "unrecognised definition keyword",
        .expected = "interface/enum/typedef/dictionary/namespace/callback/partial",
        .got = tok.text,
    });
    return error.ParseError;
}

// enum

fn parseEnumDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) !parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("enum");
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected enum name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther("{") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '{' after enum name",
            .expected = "{",
            .got = p.peek().text,
        });
        return error.ParseError;
    };

    var values: std.ArrayList(parse.EnumValue) = .empty;
    while (true) {
        // Allow trailing comma: check for closing brace
        if (p.peek().kind == .other and std.mem.eql(u8, p.peek().text, "}")) break;
        const val_tok = p.peek();
        if (val_tok.kind != .string) {
            try diagnostics.push(p.gpa, .{
                .loc = val_tok.loc,
                .severity = .err,
                .msg = "expected string literal in enum",
                .expected = "string",
                .got = val_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        const raw = val_tok.text;
        const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        try values.append(p.arena, .{ .loc = val_tok.loc, .value = inner });
        if (!p.eatOther(",")) break;
    }

    _ = p.expectOther("}") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '}' after enum values",
            .expected = "}",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after enum",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };

    return .{ .enumeration = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .name = name_tok.text,
        .values = try values.toOwnedSlice(p.arena),
    } };
}

// typedef

fn parseTypedefDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) !parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("typedef");
    const typ = try parseTypeWithExtendedAttributes(p, diagnostics);
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected typedef name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after typedef",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{ .typedef = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .type = typ,
        .name = name_tok.text,
    } };
}

// Const member:  const ConstType name = ConstValue ;

fn parseConstMember(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute, loc: Location) Error!parse.Constant {
    // "const" keyword already consumed by caller.
    const typ = try parseType(p, diagnostics);
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected const member name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther("=") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '=' in const member",
            .expected = "=",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const val = try parseValueLiteral(p, diagnostics);
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after const value",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .type = typ,
        .name = name_tok.text,
        .value = val,
    };
}

// Attribute body  (keyword "attribute" already consumed by caller)

fn parseAttributeBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
    readonly: bool,
    is_static: bool,
    stringifier: bool,
    inherit: bool,
) Error!parse.Attribute {
    const typ = try parseTypeWithExtendedAttributes(p, diagnostics);
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected attribute name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after attribute name",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .readonly = readonly,
        .is_static = is_static,
        .stringifier = stringifier,
        .inherit = inherit,
        .type = typ,
        .name = name_tok.text,
    };
}

// Operation body  (qualifiers already consumed by caller)

fn parseOperationBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
    special: ?parse.SpecialOperation,
    is_static: bool,
    stringifier: bool,
) Error!parse.Operation {
    const return_type = try parseType(p, diagnostics);
    var name: ?[]const u8 = null;
    if (p.peek().kind == .identifier) {
        name = p.next().text;
    }
    _ = p.expectOther("(") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '(' in operation",
            .expected = "(",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const args = try parseArgumentList(p, diagnostics);
    _ = p.expectOther(")") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ')' after argument list",
            .expected = ")",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after operation",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .special = special,
        .return_type = return_type,
        .name = name,
        .args = args,
        .is_static = is_static,
        .stringifier = stringifier,
    };
}

// Constructor body  (keyword "constructor" already consumed by caller)

fn parseConstructorBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
) Error!parse.Constructor {
    _ = p.expectOther("(") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '(' after constructor",
            .expected = "(",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const args = try parseArgumentList(p, diagnostics);
    _ = p.expectOther(")") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ')' after constructor args",
            .expected = ")",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after constructor",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .args = args,
    };
}

// Iterable body  (keyword "iterable" already consumed by caller)

fn parseIterableBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
    is_async: bool,
) Error!parse.Iterable {
    _ = p.expectOther("<") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '<' after iterable",
            .expected = "<",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const first = try parseTypeWithExtendedAttributes(p, diagnostics);
    var key_type: ?parse.TypeWithExtendedAttributes = null;
    var value_type: parse.TypeWithExtendedAttributes = undefined;
    if (p.eatOther(",")) {
        key_type = first;
        value_type = try parseTypeWithExtendedAttributes(p, diagnostics);
    } else {
        value_type = first;
    }
    _ = p.expectOther(">") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '>' after iterable type args",
            .expected = ">",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    var args: ?[]parse.Argument = null;
    if (is_async and p.eatOther("(")) {
        const inner_args = try parseArgumentList(p, diagnostics);
        _ = p.expectOther(")") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected ')' after async iterable args",
                .expected = ")",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        args = inner_args;
    }
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after iterable",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .kind = if (is_async) .async_iterable else .iterable,
        .key_type = key_type,
        .value_type = value_type,
        .args = args,
    };
}

// Maplike body  (keyword "maplike" already consumed by caller)

fn parseMaplikeBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
    readonly: bool,
) Error!parse.Maplike {
    _ = p.expectOther("<") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '<' after maplike",
            .expected = "<",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const key_type = try parseTypeWithExtendedAttributes(p, diagnostics);
    _ = p.expectOther(",") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ',' in maplike type args",
            .expected = ",",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const value_type = try parseTypeWithExtendedAttributes(p, diagnostics);
    _ = p.expectOther(">") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '>' after maplike type args",
            .expected = ">",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after maplike",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .readonly = readonly,
        .key_type = key_type,
        .value_type = value_type,
    };
}

// Setlike body  (keyword "setlike" already consumed by caller)

fn parseSetlikeBody(
    p: *Parser,
    diagnostics: *diag.Diagnostics,
    ext_attrs: []parse.ExtendedAttribute,
    loc: Location,
    readonly: bool,
) Error!parse.Setlike {
    _ = p.expectOther("<") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '<' after setlike",
            .expected = "<",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const typ = try parseTypeWithExtendedAttributes(p, diagnostics);
    _ = p.expectOther(">") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '>' after setlike type",
            .expected = ">",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after setlike",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .readonly = readonly,
        .type = typ,
    };
}

// Interface member dispatch

pub fn parseInterfaceMember(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.InterfaceMember {
    const loc = p.peek().loc;

    if (p.eatKeyword("const")) {
        return .{ .constant = try parseConstMember(p, diagnostics, ext_attrs, loc) };
    }

    if (p.eatKeyword("constructor")) {
        return .{ .constructor = try parseConstructorBody(p, diagnostics, ext_attrs, loc) };
    }

    if (p.eatKeyword("stringifier")) {
        if (p.eatOther(";")) {
            return .{ .operation = .{
                .loc = loc,
                .extended_attributes = ext_attrs,
                .special = null,
                .return_type = .dom_string,
                .name = null,
                .args = &.{},
                .is_static = false,
                .stringifier = true,
            } };
        }
        var local_ro = false;
        if (p.eatKeyword("readonly")) local_ro = true;
        if (p.eatKeyword("attribute")) {
            return .{ .attribute = try parseAttributeBody(p, diagnostics, ext_attrs, loc, local_ro, false, true, false) };
        }
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, null, false, true) };
    }

    if (p.eatKeyword("static")) {
        var local_ro = false;
        if (p.eatKeyword("readonly")) local_ro = true;
        if (p.eatKeyword("attribute")) {
            return .{ .attribute = try parseAttributeBody(p, diagnostics, ext_attrs, loc, local_ro, true, false, false) };
        }
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, null, true, false) };
    }

    if (p.eatKeyword("inherit")) {
        _ = p.expectKeyword("attribute") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected 'attribute' after 'inherit'",
                .expected = "attribute",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return .{ .attribute = try parseAttributeBody(p, diagnostics, ext_attrs, loc, false, false, false, true) };
    }

    if (p.eatKeyword("readonly")) {
        if (p.eatKeyword("attribute")) {
            return .{ .attribute = try parseAttributeBody(p, diagnostics, ext_attrs, loc, true, false, false, false) };
        }
        if (p.eatKeyword("maplike")) {
            return .{ .maplike = try parseMaplikeBody(p, diagnostics, ext_attrs, loc, true) };
        }
        if (p.eatKeyword("setlike")) {
            return .{ .setlike = try parseSetlikeBody(p, diagnostics, ext_attrs, loc, true) };
        }
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected 'attribute', 'maplike', or 'setlike' after 'readonly'",
            .expected = "attribute/maplike/setlike",
            .got = p.peek().text,
        });
        return error.ParseError;
    }

    // current WebIDL uses one `async_iterable` token, older syntax uses two `async iterable`. accept both.
    if (p.eatKeyword("async_iterable")) {
        return .{ .iterable = try parseIterableBody(p, diagnostics, ext_attrs, loc, true) };
    }

    if (p.eatKeyword("async")) {
        _ = p.expectKeyword("iterable") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected 'iterable' after 'async'",
                .expected = "iterable",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        return .{ .iterable = try parseIterableBody(p, diagnostics, ext_attrs, loc, true) };
    }

    if (p.eatKeyword("attribute")) {
        return .{ .attribute = try parseAttributeBody(p, diagnostics, ext_attrs, loc, false, false, false, false) };
    }

    if (p.eatKeyword("iterable")) {
        return .{ .iterable = try parseIterableBody(p, diagnostics, ext_attrs, loc, false) };
    }

    if (p.eatKeyword("maplike")) {
        return .{ .maplike = try parseMaplikeBody(p, diagnostics, ext_attrs, loc, false) };
    }

    if (p.eatKeyword("setlike")) {
        return .{ .setlike = try parseSetlikeBody(p, diagnostics, ext_attrs, loc, false) };
    }

    if (p.eatKeyword("getter")) {
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, .getter, false, false) };
    }
    if (p.eatKeyword("setter")) {
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, .setter, false, false) };
    }
    if (p.eatKeyword("deleter")) {
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, .deleter, false, false) };
    }
    if (p.eatKeyword("legacycaller")) {
        return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, .legacy_caller, false, false) };
    }

    // Regular operation: ReturnType [name] ( ArgumentList ) ;
    return .{ .operation = try parseOperationBody(p, diagnostics, ext_attrs, loc, null, false, false) };
}

// Interface member list helper (shared by interface and partial interface)

fn parseMemberList(p: *Parser, diagnostics: *diag.Diagnostics) Error![]parse.InterfaceMember {
    var members: std.ArrayList(parse.InterfaceMember) = .empty;
    while (true) {
        if (p.peek().kind == .eof) break;
        if (p.peek().kind == .other and std.mem.eql(u8, p.peek().text, "}")) break;
        const mem_ext = try parseExtendedAttributeList(p, diagnostics);
        const mem = parseInterfaceMember(p, diagnostics, mem_ext) catch |err| {
            if (err == error.ParseError) {
                while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
                continue;
            }
            return err;
        };
        try members.append(p.arena, mem);
    }
    return members.toOwnedSlice(p.arena);
}

// Interface definition

fn parseInterfaceDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("interface");

    // interface mixin
    if (p.eatKeyword("mixin")) {
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = name_tok.loc,
                .severity = .err,
                .msg = "expected mixin name",
                .expected = "identifier",
                .got = name_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        _ = p.expectOther("{") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '{' in interface mixin",
                .expected = "{",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const members = try parseMemberList(p, diagnostics);
        _ = p.expectOther("}") catch {};
        _ = p.expectOther(";") catch {};
        return .{ .interface_mixin = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .members = blk: {
                var ms: std.ArrayList(parse.MixinMember) = .empty;
                for (members) |m| {
                    switch (m) {
                        .constant => |c| try ms.append(p.arena, .{ .constant = c }),
                        .attribute => |a| try ms.append(p.arena, .{ .attribute = a }),
                        .operation => |o| try ms.append(p.arena, .{ .operation = o }),
                        else => try diagnostics.push(p.gpa, .{
                            .loc = switch (m) {
                                .constant => |c| c.loc,
                                .attribute => |a| a.loc,
                                .operation => |o| o.loc,
                                .constructor => |c| c.loc,
                                .iterable => |it| it.loc,
                                .maplike => |ml| ml.loc,
                                .setlike => |sl| sl.loc,
                            },
                            .severity = .err,
                            .msg = "member type not allowed in interface mixin",
                            .expected = "const/attribute/operation",
                            .got = null,
                        }),
                    }
                }
                break :blk try ms.toOwnedSlice(p.arena);
            },
        } };
    }

    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected interface name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();

    // Forward declaration (Gecko extension): `interface Name;`. Represent it as
    // an empty interface so the name resolves as an opaque type where used.
    if (p.mozilla and p.eatOther(";")) {
        return .{ .interface = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .inherits = null,
            .members = &.{},
        } };
    }

    var inherits: ?[]const u8 = null;
    if (p.eatOther(":")) {
        const inh = p.peek();
        if (inh.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = inh.loc,
                .severity = .err,
                .msg = "expected parent interface name",
                .expected = "identifier",
                .got = inh.text,
            });
            return error.ParseError;
        }
        inherits = inh.text;
        _ = p.next();
    }

    _ = p.expectOther("{") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '{' in interface",
            .expected = "{",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const members = try parseMemberList(p, diagnostics);
    _ = p.expectOther("}") catch {};
    _ = p.expectOther(";") catch {};

    return .{ .interface = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .name = name_tok.text,
        .inherits = inherits,
        .members = members,
    } };
}

// Partial definition

fn parsePartialDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("partial");

    if (p.eatKeyword("interface")) {
        // partial interface mixin Name { ... }; or partial interface Name { ... };
        if (p.eatKeyword("mixin")) {
            const name_tok = p.peek();
            if (name_tok.kind != .identifier) {
                try diagnostics.push(p.gpa, .{
                    .loc = name_tok.loc,
                    .severity = .err,
                    .msg = "expected partial interface mixin name",
                    .expected = "identifier",
                    .got = name_tok.text,
                });
                return error.ParseError;
            }
            _ = p.next();
            _ = p.expectOther("{") catch {
                try diagnostics.push(p.gpa, .{
                    .loc = p.peek().loc,
                    .severity = .err,
                    .msg = "expected '{' in partial interface mixin",
                    .expected = "{",
                    .got = p.peek().text,
                });
                return error.ParseError;
            };
            const members = try parseMemberList(p, diagnostics);
            _ = p.expectOther("}") catch {};
            _ = p.expectOther(";") catch {};
            return .{ .partial_mixin = .{
                .loc = loc,
                .extended_attributes = ext_attrs,
                .name = name_tok.text,
                .members = blk: {
                    var ms: std.ArrayList(parse.MixinMember) = .empty;
                    for (members) |m| {
                        switch (m) {
                            .constant => |c| try ms.append(p.arena, .{ .constant = c }),
                            .attribute => |a| try ms.append(p.arena, .{ .attribute = a }),
                            .operation => |o| try ms.append(p.arena, .{ .operation = o }),
                            else => try diagnostics.push(p.gpa, .{
                                .loc = switch (m) {
                                    .constant => |c| c.loc,
                                    .attribute => |a| a.loc,
                                    .operation => |o| o.loc,
                                    .constructor => |c| c.loc,
                                    .iterable => |it| it.loc,
                                    .maplike => |ml| ml.loc,
                                    .setlike => |sl| sl.loc,
                                },
                                .severity = .err,
                                .msg = "member type not allowed in interface mixin",
                                .expected = "const/attribute/operation",
                                .got = null,
                            }),
                        }
                    }
                    break :blk try ms.toOwnedSlice(p.arena);
                },
            } };
        }
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = name_tok.loc,
                .severity = .err,
                .msg = "expected partial interface name",
                .expected = "identifier",
                .got = name_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        _ = p.expectOther("{") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '{' in partial interface",
                .expected = "{",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const members = try parseMemberList(p, diagnostics);
        _ = p.expectOther("}") catch {};
        _ = p.expectOther(";") catch {};
        return .{ .partial_interface = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .members = members,
        } };
    }

    if (p.eatKeyword("dictionary")) {
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = name_tok.loc,
                .severity = .err,
                .msg = "expected partial dictionary name",
                .expected = "identifier",
                .got = name_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        _ = p.expectOther("{") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '{' in partial dictionary",
                .expected = "{",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const members = try parseDictionaryMemberList(p, diagnostics);
        _ = p.expectOther("}") catch {};
        _ = p.expectOther(";") catch {};
        return .{ .partial_dictionary = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .members = members,
        } };
    }

    if (p.eatKeyword("namespace")) {
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = name_tok.loc,
                .severity = .err,
                .msg = "expected partial namespace name",
                .expected = "identifier",
                .got = name_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        _ = p.expectOther("{") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '{' in partial namespace",
                .expected = "{",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const members = try parseNamespaceMemberList(p, diagnostics);
        _ = p.expectOther("}") catch {};
        _ = p.expectOther(";") catch {};
        return .{ .partial_namespace = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .members = members,
        } };
    }

    try diagnostics.push(p.gpa, .{
        .loc = p.peek().loc,
        .severity = .err,
        .msg = "expected 'interface', 'dictionary', or 'namespace' after 'partial'",
        .expected = "interface/dictionary/namespace",
        .got = p.peek().text,
    });
    return error.ParseError;
}

// Dictionary member list

fn parseDictionaryMemberList(p: *Parser, diagnostics: *diag.Diagnostics) Error![]parse.DictionaryMember {
    var list: std.ArrayList(parse.DictionaryMember) = .empty;
    while (true) {
        if (p.peek().kind == .eof) break;
        if (p.peek().kind == .other and std.mem.eql(u8, p.peek().text, "}")) break;
        const mem_ext = try parseExtendedAttributeList(p, diagnostics);
        const mem_loc = p.peek().loc;
        const required = p.eatKeyword("required");
        const typ = parseTypeWithExtendedAttributes(p, diagnostics) catch |err| {
            if (err == error.ParseError) {
                while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
                continue;
            }
            return err;
        };
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
            continue;
        }
        _ = p.next();
        var default_val: ?parse.ValueLiteral = null;
        if (!required and p.eatOther("=")) {
            default_val = parseValueLiteral(p, diagnostics) catch null;
        }
        _ = p.expectOther(";") catch {};
        try list.append(p.arena, .{
            .loc = mem_loc,
            .extended_attributes = mem_ext,
            .required = required,
            .type = typ,
            .name = name_tok.text,
            .default = default_val,
        });
    }
    return list.toOwnedSlice(p.arena);
}

// Dictionary definition

fn parseDictionaryDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("dictionary");
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected dictionary name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    var inherits: ?[]const u8 = null;
    if (p.eatOther(":")) {
        const inh = p.peek();
        if (inh.kind == .identifier) {
            inherits = inh.text;
            _ = p.next();
        }
    }
    _ = p.expectOther("{") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '{' in dictionary definition",
            .expected = "{",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const members = try parseDictionaryMemberList(p, diagnostics);
    _ = p.expectOther("}") catch {};
    _ = p.expectOther(";") catch {};
    return .{ .dictionary = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .name = name_tok.text,
        .inherits = inherits,
        .members = members,
    } };
}

// Namespace member list

fn parseNamespaceMemberList(p: *Parser, diagnostics: *diag.Diagnostics) Error![]parse.NamespaceMember {
    var list: std.ArrayList(parse.NamespaceMember) = .empty;
    while (true) {
        if (p.peek().kind == .eof) break;
        if (p.peek().kind == .other and std.mem.eql(u8, p.peek().text, "}")) break;
        const mem_ext = try parseExtendedAttributeList(p, diagnostics);
        const mem_loc = p.peek().loc;
        if (p.eatKeyword("const")) {
            const c = parseConstMember(p, diagnostics, mem_ext, mem_loc) catch |err| {
                if (err == error.ParseError) {
                    while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
                    continue;
                }
                return err;
            };
            try list.append(p.arena, .{ .constant = c });
            continue;
        }
        if (p.eatKeyword("readonly")) {
            _ = p.expectKeyword("attribute") catch {
                while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
                continue;
            };
            const a = parseAttributeBody(p, diagnostics, mem_ext, mem_loc, true, false, false, false) catch |err| {
                if (err == error.ParseError) continue;
                return err;
            };
            try list.append(p.arena, .{ .attribute = a });
            continue;
        }
        // operation
        const op = parseOperationBody(p, diagnostics, mem_ext, mem_loc, null, false, false) catch |err| {
            if (err == error.ParseError) {
                while (p.peek().kind != .eof and !p.eatOther(";")) _ = p.next();
                continue;
            }
            return err;
        };
        try list.append(p.arena, .{ .operation = op });
    }
    return list.toOwnedSlice(p.arena);
}

// Namespace definition

fn parseNamespaceDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("namespace");
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected namespace name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther("{") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '{' in namespace definition",
            .expected = "{",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const members = try parseNamespaceMemberList(p, diagnostics);
    _ = p.expectOther("}") catch {};
    _ = p.expectOther(";") catch {};
    return .{ .namespace = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .name = name_tok.text,
        .members = members,
    } };
}

// Callback definition

fn parseCallbackDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    try p.expectKeyword("callback");

    // callback interface
    if (p.eatKeyword("interface")) {
        const name_tok = p.peek();
        if (name_tok.kind != .identifier) {
            try diagnostics.push(p.gpa, .{
                .loc = name_tok.loc,
                .severity = .err,
                .msg = "expected callback interface name",
                .expected = "identifier",
                .got = name_tok.text,
            });
            return error.ParseError;
        }
        _ = p.next();
        var inherits: ?[]const u8 = null;
        if (p.eatOther(":")) {
            const inh = p.peek();
            if (inh.kind == .identifier) {
                inherits = inh.text;
                _ = p.next();
            }
        }
        _ = p.expectOther("{") catch {
            try diagnostics.push(p.gpa, .{
                .loc = p.peek().loc,
                .severity = .err,
                .msg = "expected '{' in callback interface",
                .expected = "{",
                .got = p.peek().text,
            });
            return error.ParseError;
        };
        const members = try parseMemberList(p, diagnostics);
        _ = p.expectOther("}") catch {};
        _ = p.expectOther(";") catch {};
        return .{ .callback_interface = .{
            .loc = loc,
            .extended_attributes = ext_attrs,
            .name = name_tok.text,
            .inherits = inherits,
            .members = members,
        } };
    }

    // plain callback: callback Name = ReturnType ( ArgumentList ) ;
    const name_tok = p.peek();
    if (name_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = name_tok.loc,
            .severity = .err,
            .msg = "expected callback name",
            .expected = "identifier",
            .got = name_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther("=") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '=' in callback definition",
            .expected = "=",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const ret = try parseType(p, diagnostics);
    _ = p.expectOther("(") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected '(' in callback argument list",
            .expected = "(",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const args = try parseArgumentList(p, diagnostics);
    _ = p.expectOther(")") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ')' after callback argument list",
            .expected = ")",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after callback definition",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{ .callback = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .name = name_tok.text,
        .return_type = ret,
        .args = args,
    } };
}

// Includes statement:  TargetIdent includes MixinIdent ;

fn parseIncludesDef(p: *Parser, diagnostics: *diag.Diagnostics, ext_attrs: []parse.ExtendedAttribute) Error!parse.Definition {
    const loc = p.peek().loc;
    const target_tok = p.peek();
    if (target_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = target_tok.loc,
            .severity = .err,
            .msg = "expected interface name in includes statement",
            .expected = "identifier",
            .got = target_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectKeyword("includes") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected 'includes'",
            .expected = "includes",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    const mixin_tok = p.peek();
    if (mixin_tok.kind != .identifier) {
        try diagnostics.push(p.gpa, .{
            .loc = mixin_tok.loc,
            .severity = .err,
            .msg = "expected mixin name in includes statement",
            .expected = "identifier",
            .got = mixin_tok.text,
        });
        return error.ParseError;
    }
    _ = p.next();
    _ = p.expectOther(";") catch {
        try diagnostics.push(p.gpa, .{
            .loc = p.peek().loc,
            .severity = .err,
            .msg = "expected ';' after includes statement",
            .expected = ";",
            .got = p.peek().text,
        });
        return error.ParseError;
    };
    return .{ .includes = .{
        .loc = loc,
        .extended_attributes = ext_attrs,
        .interface = target_tok.text,
        .mixin = mixin_tok.text,
    } };
}

// Tests

const testing = std.testing;

// Parser harness helpers

test "parser: peek does not consume" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "foo bar");
    const t1 = p.peek();
    const t2 = p.peek();
    try testing.expectEqualStrings(t1.text, t2.text);
    try testing.expectEqualStrings("foo", t1.text);
}

test "parser: next advances" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "foo bar");
    const t1 = p.next();
    const t2 = p.next();
    try testing.expectEqualStrings("foo", t1.text);
    try testing.expectEqualStrings("bar", t2.text);
}

test "parser: eatOther matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), ";");
    try testing.expect(p.eatOther(";"));
    try testing.expectEqual(Kind.eof, p.peek().kind);
}

test "parser: eatKeyword matches identifier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "enum Foo");
    try testing.expect(p.eatKeyword("enum"));
    try testing.expectEqualStrings("Foo", p.peek().text);
}

test "parser: mark/reset restores position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "foo bar baz");
    const m = p.mark();
    _ = p.next();
    _ = p.next();
    p.reset(m);
    try testing.expectEqualStrings("foo", p.peek().text);
}

test "parser: peekN looks ahead" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "a b c");
    try testing.expectEqualStrings("a", p.peekN(0).text);
    try testing.expectEqualStrings("b", p.peekN(1).text);
    try testing.expectEqualStrings("c", p.peekN(2).text);
    try testing.expectEqualStrings("a", p.peek().text);
}

test "parser: mark/reset with pre-filled buffer" {
    // regression: mark() with a non-empty lookahead buffer must restore buffer contents, not just buf_len.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(testing.allocator, arena_state.allocator(), "a b c");
    _ = p.peekN(1);
    const m = p.mark();
    // Consume the first token (shifts buffer, corrupting state in the old impl).
    _ = p.next();
    p.reset(m);
    // After reset, peek() must return the token that was at position 0 at mark time.
    try testing.expectEqualStrings("a", p.peek().text);
    // And the full stream must replay correctly.
    try testing.expectEqualStrings("a", p.next().text);
    try testing.expectEqualStrings("b", p.next().text);
}

// Type tests

fn makeParser(src: []const u8, arena: std.mem.Allocator) Parser {
    return Parser.init(testing.allocator, arena, src);
}

test "type: boolean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("boolean", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.boolean, t);
}

test "type: unsigned long long" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("unsigned long long", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.unsigned_long_long, t);
}

test "type: unsigned long" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("unsigned long", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.unsigned_long, t);
}

test "type: long long" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("long long", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.long_long, t);
}

test "type: unrestricted float" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("unrestricted float", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.unrestricted_float, t);
}

test "type: DOMString" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("DOMString", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expectEqual(parse.Type.dom_string, t);
}

test "type: nullable boolean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("boolean?", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .nullable);
    try testing.expectEqual(parse.Type.boolean, t.nullable.*);
}

test "type: sequence<long>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("sequence<long>", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .sequence);
    try testing.expectEqual(parse.Type.long, t.sequence.type.*);
}

test "type: record<DOMString, long>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("record<DOMString, long>", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .record);
    try testing.expectEqual(parse.Type.dom_string, t.record.key.type.*);
    try testing.expectEqual(parse.Type.long, t.record.value.type.*);
}

test "type: Promise<undefined>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("Promise<undefined>", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .promise);
    try testing.expectEqual(parse.Type.undefined, t.promise.return_type.*);
}

test "type: union (boolean or long)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("(boolean or long)", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .union_of);
    try testing.expectEqual(@as(usize, 2), t.union_of.len);
    try testing.expectEqual(parse.Type.boolean, t.union_of[0].type.*);
    try testing.expectEqual(parse.Type.long, t.union_of[1].type.*);
}

test "type: buffer ArrayBuffer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("ArrayBuffer", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .buffer);
    try testing.expectEqual(parse.BufferType.array_buffer, t.buffer);
}

test "type: identifier reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("EventTarget", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const t = try parseType(&p, &d);
    try testing.expect(t == .identifier);
    try testing.expectEqualStrings("EventTarget", t.identifier);
}

// Extended attribute tests

test "ext-attr: no_args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[Exposed]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const attrs = try parseExtendedAttributeList(&p, &d);
    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0].form == .no_args);
    try testing.expectEqualStrings("Exposed", attrs[0].form.no_args.name);
}

test "ext-attr: ident" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[Exposed=Window]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const attrs = try parseExtendedAttributeList(&p, &d);
    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0].form == .ident);
    try testing.expectEqualStrings("Exposed", attrs[0].form.ident.name);
    try testing.expectEqualStrings("Window", attrs[0].form.ident.value);
}

test "ext-attr: ident_list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[Exposed=(Window,Worker)]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const attrs = try parseExtendedAttributeList(&p, &d);
    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0].form == .ident_list);
    try testing.expectEqual(@as(usize, 2), attrs[0].form.ident_list.values.len);
    try testing.expectEqualStrings("Window", attrs[0].form.ident_list.values[0]);
    try testing.expectEqualStrings("Worker", attrs[0].form.ident_list.values[1]);
}

test "ext-attr: arg_list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[Constructor(long x)]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const attrs = try parseExtendedAttributeList(&p, &d);
    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0].form == .arg_list);
    try testing.expectEqualStrings("Constructor", attrs[0].form.arg_list.name);
    try testing.expectEqual(@as(usize, 1), attrs[0].form.arg_list.args.len);
}

test "ext-attr: named_arg_list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[NamedConstructor=Audio(DOMString src)]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const attrs = try parseExtendedAttributeList(&p, &d);
    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0].form == .named_arg_list);
    try testing.expectEqualStrings("NamedConstructor", attrs[0].form.named_arg_list.name);
    try testing.expectEqualStrings("Audio", attrs[0].form.named_arg_list.rhs_name);
}

// enum test

test "parse: full enum definition" {
    var r = try parse_src(testing.allocator, "enum Color { \"red\", \"green\", \"blue\" };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    try testing.expect(r.defs[0] == .enumeration);
    const e = r.defs[0].enumeration;
    try testing.expectEqualStrings("Color", e.name);
    try testing.expectEqual(@as(usize, 3), e.values.len);
    try testing.expectEqualStrings("red", e.values[0].value);
    try testing.expectEqualStrings("green", e.values[1].value);
    try testing.expectEqualStrings("blue", e.values[2].value);
}

// typedef tests

test "parse: typedef simple" {
    var r = try parse_src(testing.allocator, "typedef long MyLong;");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    try testing.expect(r.defs[0] == .typedef);
    const td = r.defs[0].typedef;
    try testing.expectEqualStrings("MyLong", td.name);
    try testing.expectEqual(parse.Type.long, td.type.type.*);
}

test "parse: typedef sequence<long>" {
    var r = try parse_src(testing.allocator, "typedef sequence<long> LongList;");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    const td = r.defs[0].typedef;
    try testing.expectEqualStrings("LongList", td.name);
    try testing.expect(td.type.type.* == .sequence);
}

// nullable + union + parameterised end-to-end

test "parse: typedef nullable union" {
    var r = try parse_src(testing.allocator, "typedef (long or DOMString)? MaybeStr;");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    const td = r.defs[0].typedef;
    try testing.expect(td.type.type.* == .nullable);
    try testing.expect(td.type.type.*.nullable.* == .union_of);
}

// malformed input diagnostic

test "parse: malformed yields diagnostic" {
    // Missing type, name and value after const keyword, should emit diagnostics
    var r = try parse_src(testing.allocator, "interface Foo { const; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expect(r.diagnostics.list.items.len >= 1);
}

// Mozilla/Gecko dialect extensions (opt-in via ParseOptions.mozilla)

test "mozilla: forward declaration rejected in standard mode, accepted with mozilla" {
    var strict = try parse_src(testing.allocator, "interface nsIScreen;");
    defer strict.arena.deinit();
    defer strict.diagnostics.deinit(testing.allocator);
    try testing.expect(strict.diagnostics.list.items.len >= 1);
    try testing.expectEqual(@as(usize, 0), strict.defs.len);

    var moz = try parse_srcOpts(testing.allocator, "interface nsIScreen;", .{ .mozilla = true });
    defer moz.arena.deinit();
    defer moz.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), moz.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), moz.defs.len);
    try testing.expect(moz.defs[0] == .interface);
    try testing.expectEqualStrings("nsIScreen", moz.defs[0].interface.name);
    try testing.expectEqual(@as(usize, 0), moz.defs[0].interface.members.len);
}

test "mozilla: string-valued extended attribute rejected in standard mode, accepted with mozilla" {
    const src = "interface E { [Func=\"x::y\"] readonly attribute long z; };";
    var strict = try parse_src(testing.allocator, src);
    defer strict.arena.deinit();
    defer strict.diagnostics.deinit(testing.allocator);
    try testing.expect(strict.diagnostics.list.items.len >= 1);

    var moz = try parse_srcOpts(testing.allocator, src, .{ .mozilla = true });
    defer moz.arena.deinit();
    defer moz.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), moz.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), moz.defs.len);
}

test "standard: wildcard-valued extended attribute [Exposed=*] parses in strict mode" {
    // [Exposed=*] is the standard ExtendedAttributeWildcard form, so it parses without the mozilla flag.
    const src = "[Exposed=*] interface E { readonly attribute long x; };";
    var strict = try parse_src(testing.allocator, src);
    defer strict.arena.deinit();
    defer strict.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), strict.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), strict.defs.len);
}

test "standard: single-token async_iterable with argument list" {
    // Current WebIDL: `async_iterable<V>(optional Opts o = {});`
    const src = "interface E { async_iterable<any>(optional long n); };";
    var r = try parse_src(testing.allocator, src);
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    try testing.expectEqual(@as(usize, 1), r.defs[0].interface.members.len);
    try testing.expect(r.defs[0].interface.members[0] == .iterable);
}

test "mozilla: C-preprocessor directive lines are skipped" {
    const src =
        "interface E {\n" ++
        "  readonly attribute long a;\n" ++
        "#ifdef NIGHTLY_BUILD\n" ++
        "  readonly attribute long b;\n" ++
        "#endif\n" ++
        "};\n";
    // Standard mode chokes on '#'.
    var strict = try parse_src(testing.allocator, src);
    defer strict.arena.deinit();
    defer strict.diagnostics.deinit(testing.allocator);
    try testing.expect(strict.diagnostics.list.items.len >= 1);

    // Mozilla mode skips the directive lines and keeps the guarded member.
    var moz = try parse_srcOpts(testing.allocator, src, .{ .mozilla = true });
    defer moz.arena.deinit();
    defer moz.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), moz.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), moz.defs.len);
    try testing.expectEqual(@as(usize, 2), moz.defs[0].interface.members.len);
}

// Slice-2 tests: ValueLiteral variants

test "value: boolean true" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("true", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .boolean);
    try testing.expect(v.boolean == true);
}

test "value: boolean false" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("false", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v.boolean == false);
}

test "value: integer decimal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("42", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expectEqual(@as(i64, 42), v.integer);
}

test "value: integer hex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("0xFF", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expectEqual(@as(i64, 255), v.integer);
}

test "value: integer negative" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("-7", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expectEqual(@as(i64, -7), v.integer);
}

test "value: decimal float" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("3.14", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .decimal);
}

test "value: string literal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("\"hello\"", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expectEqualStrings("hello", v.string);
}

test "value: null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("null", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .null_value);
}

test "value: positive Infinity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("Infinity", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .positive_infinity);
}

test "value: negative Infinity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("-Infinity", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .negative_infinity);
}

test "value: NaN" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("NaN", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .nan);
}

test "value: empty sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("[]", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .empty_sequence);
}

test "value: empty dict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("{}", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const v = try parseValueLiteral(&p, &d);
    try testing.expect(v == .empty_dict);
}

// Slice-2 tests: Const member

test "member: const integer" {
    var r = try parse_src(testing.allocator, "interface X { const long FOO = 42; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const iface = r.defs[0].interface;
    try testing.expectEqual(@as(usize, 1), iface.members.len);
    const c = iface.members[0].constant;
    try testing.expectEqualStrings("FOO", c.name);
    try testing.expectEqual(parse.Type.long, c.type);
    try testing.expectEqual(@as(i64, 42), c.value.integer);
}

test "member: const boolean" {
    var r = try parse_src(testing.allocator, "interface X { const boolean FLAG = true; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const c = r.defs[0].interface.members[0].constant;
    try testing.expectEqualStrings("FLAG", c.name);
    try testing.expect(c.value.boolean == true);
}

// Slice-2 tests: Argument list

test "arg: simple argument" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("long x", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const arg = try parseArgument(&p, &d);
    try testing.expectEqualStrings("x", arg.name);
    try testing.expect(arg.type.type.* == .long);
    try testing.expect(!arg.optional);
    try testing.expect(!arg.variadic);
}

test "arg: optional with default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("optional long x = 0", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const arg = try parseArgument(&p, &d);
    try testing.expect(arg.optional);
    try testing.expect(arg.default != null);
    try testing.expectEqual(@as(i64, 0), arg.default.?.integer);
}

test "arg: variadic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("long... xs", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const arg = try parseArgument(&p, &d);
    try testing.expect(arg.variadic);
    try testing.expectEqualStrings("xs", arg.name);
}

test "arg: list two args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("long x, DOMString y", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const args = try parseArgumentList(&p, &d);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", args[0].name);
    try testing.expectEqualStrings("y", args[1].name);
}

test "arg: optional default empty sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p = makeParser("optional sequence<long> items = []", arena_state.allocator());
    var d: diag.Diagnostics = .{};
    defer d.deinit(testing.allocator);
    const arg = try parseArgument(&p, &d);
    try testing.expect(arg.optional);
    try testing.expect(arg.default.? == .empty_sequence);
}

// Slice-2 tests: Operation

test "member: regular operation no name" {
    // Anonymous operation: return type then '(' directly, no name identifier.
    var r = try parse_src(testing.allocator, "interface X { undefined (); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.special == null);
    try testing.expect(!op.is_static);
    try testing.expect(!op.stringifier);
    try testing.expectEqual(parse.Type.undefined, op.return_type);
    try testing.expect(op.name == null);
}

test "member: named operation with args" {
    var r = try parse_src(testing.allocator, "interface X { DOMString item(unsigned long index); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expectEqualStrings("item", op.name.?);
    try testing.expectEqual(parse.Type.dom_string, op.return_type);
    try testing.expectEqual(@as(usize, 1), op.args.len);
    try testing.expectEqualStrings("index", op.args[0].name);
}

test "member: static operation" {
    var r = try parse_src(testing.allocator, "interface X { static DOMString create(); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.is_static);
    try testing.expectEqualStrings("create", op.name.?);
}

test "member: getter special op" {
    var r = try parse_src(testing.allocator, "interface X { getter DOMString (unsigned long index); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.special.? == .getter);
    try testing.expect(op.name == null);
}

test "member: setter special op" {
    var r = try parse_src(testing.allocator, "interface X { setter undefined (unsigned long index, DOMString val); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.special.? == .setter);
}

test "member: deleter special op" {
    var r = try parse_src(testing.allocator, "interface X { deleter undefined (unsigned long index); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.special.? == .deleter);
}

test "member: named getter" {
    var r = try parse_src(testing.allocator, "interface X { getter DOMString item(unsigned long index); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.special.? == .getter);
    try testing.expectEqualStrings("item", op.name.?);
}

test "member: stringifier bare" {
    var r = try parse_src(testing.allocator, "interface X { stringifier; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const op = r.defs[0].interface.members[0].operation;
    try testing.expect(op.stringifier);
    try testing.expect(op.name == null);
    try testing.expectEqual(parse.Type.dom_string, op.return_type);
}

test "member: stringifier attribute" {
    var r = try parse_src(testing.allocator, "interface X { stringifier attribute DOMString name; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const attr = r.defs[0].interface.members[0].attribute;
    try testing.expect(attr.stringifier);
    try testing.expectEqualStrings("name", attr.name);
}

// Slice-2 tests: Attribute

test "member: readonly attribute" {
    var r = try parse_src(testing.allocator, "interface X { readonly attribute DOMString name; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const attr = r.defs[0].interface.members[0].attribute;
    try testing.expect(attr.readonly);
    try testing.expect(!attr.is_static);
    try testing.expectEqualStrings("name", attr.name);
    try testing.expectEqual(parse.Type.dom_string, attr.type.type.*);
}

test "member: plain attribute" {
    var r = try parse_src(testing.allocator, "interface X { attribute long x; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const attr = r.defs[0].interface.members[0].attribute;
    try testing.expect(!attr.readonly);
    try testing.expect(!attr.is_static);
    try testing.expectEqualStrings("x", attr.name);
}

test "member: static attribute" {
    var r = try parse_src(testing.allocator, "interface X { static readonly attribute long count; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const attr = r.defs[0].interface.members[0].attribute;
    try testing.expect(attr.is_static);
    try testing.expect(attr.readonly);
    try testing.expectEqualStrings("count", attr.name);
}

test "member: inherit attribute" {
    var r = try parse_src(testing.allocator, "interface X { inherit attribute long x; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const attr = r.defs[0].interface.members[0].attribute;
    try testing.expect(attr.inherit);
    try testing.expect(!attr.readonly);
}

// Slice-2 tests: Constructor

test "member: constructor no args" {
    var r = try parse_src(testing.allocator, "interface X { constructor(); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const ctor = r.defs[0].interface.members[0].constructor;
    try testing.expectEqual(@as(usize, 0), ctor.args.len);
}

test "member: constructor with args" {
    var r = try parse_src(testing.allocator, "interface X { constructor(DOMString src, optional long x = 0); };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const ctor = r.defs[0].interface.members[0].constructor;
    try testing.expectEqual(@as(usize, 2), ctor.args.len);
    try testing.expectEqualStrings("src", ctor.args[0].name);
    try testing.expect(ctor.args[1].optional);
}

// Slice-2 tests: Iterable / Maplike / Setlike

test "member: iterable value only" {
    var r = try parse_src(testing.allocator, "interface X { iterable<DOMString>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const it = r.defs[0].interface.members[0].iterable;
    try testing.expect(it.kind == .iterable);
    try testing.expect(it.key_type == null);
    try testing.expectEqual(parse.Type.dom_string, it.value_type.type.*);
}

test "member: iterable key-value" {
    var r = try parse_src(testing.allocator, "interface X { iterable<long, DOMString>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const it = r.defs[0].interface.members[0].iterable;
    try testing.expect(it.key_type != null);
    try testing.expectEqual(parse.Type.long, it.key_type.?.type.*);
    try testing.expectEqual(parse.Type.dom_string, it.value_type.type.*);
}

test "member: async iterable" {
    var r = try parse_src(testing.allocator, "interface X { async iterable<DOMString>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const it = r.defs[0].interface.members[0].iterable;
    try testing.expect(it.kind == .async_iterable);
}

test "member: maplike read-write" {
    var r = try parse_src(testing.allocator, "interface X { maplike<DOMString, long>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const ml = r.defs[0].interface.members[0].maplike;
    try testing.expect(!ml.readonly);
    try testing.expectEqual(parse.Type.dom_string, ml.key_type.type.*);
    try testing.expectEqual(parse.Type.long, ml.value_type.type.*);
}

test "member: readonly maplike" {
    var r = try parse_src(testing.allocator, "interface X { readonly maplike<DOMString, long>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const ml = r.defs[0].interface.members[0].maplike;
    try testing.expect(ml.readonly);
}

test "member: setlike" {
    var r = try parse_src(testing.allocator, "interface X { setlike<DOMString>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const sl = r.defs[0].interface.members[0].setlike;
    try testing.expect(!sl.readonly);
    try testing.expectEqual(parse.Type.dom_string, sl.type.type.*);
}

test "member: readonly setlike" {
    var r = try parse_src(testing.allocator, "interface X { readonly setlike<long>; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    const sl = r.defs[0].interface.members[0].setlike;
    try testing.expect(sl.readonly);
    try testing.expectEqual(parse.Type.long, sl.type.type.*);
}

// Slice-2 tests: interface definition end-to-end

test "parse: interface empty" {
    var r = try parse_src(testing.allocator, "interface Foo {};");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    try testing.expectEqual(@as(usize, 1), r.defs.len);
    const iface = r.defs[0].interface;
    try testing.expectEqualStrings("Foo", iface.name);
    try testing.expect(iface.inherits == null);
    try testing.expectEqual(@as(usize, 0), iface.members.len);
}

test "parse: interface with inheritance" {
    var r = try parse_src(testing.allocator, "interface Bar : Foo { readonly attribute long x; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const iface = r.defs[0].interface;
    try testing.expectEqualStrings("Bar", iface.name);
    try testing.expectEqualStrings("Foo", iface.inherits.?);
    try testing.expectEqual(@as(usize, 1), iface.members.len);
}

test "parse: interface multiple members" {
    var r = try parse_src(testing.allocator,
        \\interface Element {
        \\    readonly attribute DOMString tagName;
        \\    attribute DOMString id;
        \\    DOMString getAttribute(DOMString name);
        \\    undefined setAttribute(DOMString name, DOMString value);
        \\};
    );
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.list.items.len);
    const iface = r.defs[0].interface;
    try testing.expectEqual(@as(usize, 4), iface.members.len);
    try testing.expect(iface.members[0] == .attribute);
    try testing.expect(iface.members[1] == .attribute);
    try testing.expect(iface.members[2] == .operation);
    try testing.expect(iface.members[3] == .operation);
}

test "parse: malformed member emits diagnostic" {
    // readonly without attribute/maplike/setlike is an error
    var r = try parse_src(testing.allocator, "interface X { readonly undefined; };");
    defer r.arena.deinit();
    defer r.diagnostics.deinit(testing.allocator);
    try testing.expect(r.diagnostics.list.items.len >= 1);
}
