//! Normalized device model. By the time these types exist, typedefs are
//! resolved, mixins are folded, and partials are merged. Emitters and
//! bindgen code work against this model, not the raw AST.

const std = @import("std");

// Buffer types (kept in model for type resolution)

pub const BufferKind = enum {
    array_buffer,
    shared_array_buffer,
    data_view,
    int8_array,
    int16_array,
    int32_array,
    uint8_array,
    uint16_array,
    uint32_array,
    uint8_clamped_array,
    bigint64_array,
    biguint64_array,
    float16_array,
    float32_array,
    float64_array,
};

/// The fully-normalized type that the resolve pass produces.
pub const Type = union(enum) {
    // Primitives
    boolean,
    byte,
    octet,
    bigint,
    undefined,
    any,
    object,
    symbol,

    // Integer family
    unsigned_short,
    unsigned_long,
    unsigned_long_long,
    short,
    long,
    long_long,

    // Float family
    float,
    double,
    unrestricted_float,
    unrestricted_double,

    // String types
    dom_string,
    byte_string,
    usv_string,

    // Parameterised types (heap-allocated to keep the union small)
    sequence: *const Type,
    record: struct { key: *const Type, value: *const Type },
    frozen_array: *const Type,
    observable_array: *const Type,
    promise: *const Type,
    nullable: *const Type,

    union_of: []const Type,

    buffer: BufferKind,

    // Reference by name (interface / dictionary / enum / callback)
    named: []const u8,
};

// Value literals (for const defaults and dictionary member defaults)

pub const ValueLiteral = union(enum) {
    boolean: bool,
    integer: i64,
    decimal: f64,
    string: []const u8,
    null_value,
    undefined_value,
    empty_sequence,
    empty_dict,
    positive_infinity,
    negative_infinity,
    nan,
};

// Shared member types

pub const Constant = struct {
    name: []const u8,
    type: Type,
    value: ValueLiteral,
};

pub const Attribute = struct {
    name: []const u8,
    type: Type,
    readonly: bool,
    is_static: bool,
    stringifier: bool,
    inherit: bool,
};

pub const Argument = struct {
    name: []const u8,
    type: Type,
    optional: bool,
    variadic: bool,
    default: ?ValueLiteral,
};

pub const SpecialOperation = enum { getter, setter, deleter, legacy_caller };

pub const Operation = struct {
    name: ?[]const u8,
    return_type: Type,
    args: []Argument,
    special: ?SpecialOperation,
    is_static: bool,
    stringifier: bool,
};

pub const Constructor = struct {
    args: []Argument,
};

// Top-level normalized definitions

pub const Interface = struct {
    name: []const u8,
    inherits: ?[]const u8,
    constants: []Constant,
    attributes: []Attribute,
    operations: []Operation,
    constructors: []Constructor,
    /// True if this was originally a mixin (folded in).
    mixin: bool,
};

pub const DictMember = struct {
    name: []const u8,
    type: Type,
    required: bool,
    default: ?ValueLiteral,
};

pub const Dictionary = struct {
    name: []const u8,
    inherits: ?[]const u8,
    members: []DictMember,
};

pub const Enum = struct {
    name: []const u8,
    values: []const []const u8,
};

pub const Callback = struct {
    name: []const u8,
    return_type: Type,
    args: []Argument,
};

pub const Namespace = struct {
    name: []const u8,
    constants: []Constant,
    attributes: []Attribute,
    operations: []Operation,
};

pub const Definitions = struct {
    interfaces: []Interface,
    dictionaries: []Dictionary,
    enums: []Enum,
    callbacks: []Callback,
    namespaces: []Namespace,
};

// Compile-time smoke tests

test "model: type references compile" {
    _ = Type;
    _ = BufferKind;
    _ = ValueLiteral;
    _ = Constant;
    _ = Attribute;
    _ = Argument;
    _ = Operation;
    _ = Constructor;
    _ = Interface;
    _ = DictMember;
    _ = Dictionary;
    _ = Enum;
    _ = Callback;
    _ = Namespace;
    _ = Definitions;
}

test "model: type union construction" {
    const t: Type = .boolean;
    try std.testing.expectEqual(Type.boolean, t);

    const t2: Type = .{ .named = "EventTarget" };
    try std.testing.expectEqualStrings("EventTarget", t2.named);

    const t3: Type = .{ .buffer = .uint8_array };
    try std.testing.expectEqual(BufferKind.uint8_array, t3.buffer);
}
