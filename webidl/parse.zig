//! Raw AST node types mirroring the WebIDL grammar. All nodes are
//! arena-allocated. No parser logic lives here yet.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
pub const Location = tokenizer.Location;

// Value literals (for const values and argument defaults)

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

// Extended attributes (5 grammar forms)

pub const ExtendedAttributeForm = union(enum) {
    /// [Foo]
    no_args: struct { name: []const u8 },
    /// [Foo(long x, ...)]
    arg_list: struct { name: []const u8, args: []Argument },
    /// [Foo=Bar(long x, ...)]
    named_arg_list: struct { name: []const u8, rhs_name: []const u8, args: []Argument },
    /// [Foo=Bar]
    ident: struct { name: []const u8, value: []const u8 },
    /// [Foo=(Bar,Baz)]
    ident_list: struct { name: []const u8, values: [][]const u8 },
};

pub const ExtendedAttribute = struct {
    loc: Location,
    form: ExtendedAttributeForm,
};

// Types

pub const BufferType = enum {
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

/// A "type with extended attributes" wrapper used at grammar points that
/// allow [ExtendedAttributeList] before a type.
pub const TypeWithExtendedAttributes = struct {
    extended_attributes: []ExtendedAttribute,
    type: *Type,
};

/// Raw AST type node.
pub const Type = union(enum) {
    // Primitive integer types
    byte,
    octet,
    bigint,
    unsigned_short,
    unsigned_long,
    unsigned_long_long,
    short,
    long,
    long_long,

    // Primitive float types
    float,
    double,
    unrestricted_float,
    unrestricted_double,

    // Other primitives
    boolean,
    undefined,
    any,
    object,
    symbol,

    // String types
    dom_string,
    byte_string,
    usv_string,

    // Parameterised types
    sequence: *const TypeWithExtendedAttributes,
    record: struct { key: *const TypeWithExtendedAttributes, value: *const TypeWithExtendedAttributes },
    frozen_array: *const TypeWithExtendedAttributes,
    observable_array: *const TypeWithExtendedAttributes,
    promise: struct { return_type: *const Type },

    // Nullable wrapper: T?
    nullable: *const Type,

    // Union: (A or B or ...)
    union_of: []const TypeWithExtendedAttributes,

    // Buffer types (ArrayBuffer, typed arrays, etc.)
    buffer: BufferType,

    // Reference to a named type (interface, dictionary, enum, callback)
    identifier: []const u8,
};

// Members

pub const SpecialOperation = enum { getter, setter, deleter, legacy_caller };

pub const Argument = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    optional: bool,
    variadic: bool,
    type: TypeWithExtendedAttributes,
    name: []const u8,
    default: ?ValueLiteral,
};

pub const Constant = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    type: Type,
    name: []const u8,
    value: ValueLiteral,
};

pub const Attribute = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    readonly: bool,
    is_static: bool,
    stringifier: bool,
    inherit: bool,
    type: TypeWithExtendedAttributes,
    name: []const u8,
};

pub const Operation = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    special: ?SpecialOperation,
    return_type: Type,
    name: ?[]const u8,
    args: []Argument,
    is_static: bool,
    stringifier: bool,
};

pub const Constructor = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    args: []Argument,
};

pub const IterableKind = enum { iterable, async_iterable };

pub const Iterable = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    kind: IterableKind,
    key_type: ?TypeWithExtendedAttributes,
    value_type: TypeWithExtendedAttributes,
    args: ?[]Argument,
};

pub const MaplikeReadonly = bool;
pub const SetlikeReadonly = bool;

pub const Maplike = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    readonly: bool,
    key_type: TypeWithExtendedAttributes,
    value_type: TypeWithExtendedAttributes,
};

pub const Setlike = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    readonly: bool,
    type: TypeWithExtendedAttributes,
};

pub const InterfaceMember = union(enum) {
    constant: Constant,
    attribute: Attribute,
    operation: Operation,
    constructor: Constructor,
    iterable: Iterable,
    maplike: Maplike,
    setlike: Setlike,
};

pub const MixinMember = union(enum) {
    constant: Constant,
    attribute: Attribute,
    operation: Operation,
    stringifier,
};

pub const NamespaceMember = union(enum) {
    constant: Constant,
    attribute: Attribute,
    operation: Operation,
};

pub const DictionaryMember = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    required: bool,
    type: TypeWithExtendedAttributes,
    name: []const u8,
    default: ?ValueLiteral,
};

pub const EnumValue = struct {
    loc: Location,
    value: []const u8,
};

// Top-level definitions

pub const Interface = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    inherits: ?[]const u8,
    members: []InterfaceMember,
};

pub const InterfaceMixin = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []MixinMember,
};

pub const PartialInterface = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []InterfaceMember,
};

pub const PartialMixin = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []MixinMember,
};

pub const PartialDictionary = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []DictionaryMember,
};

pub const PartialNamespace = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []NamespaceMember,
};

pub const Includes = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    interface: []const u8,
    mixin: []const u8,
};

pub const Namespace = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    members: []NamespaceMember,
};

pub const Dictionary = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    inherits: ?[]const u8,
    members: []DictionaryMember,
};

pub const Enumeration = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    values: []EnumValue,
};

pub const Callback = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    return_type: Type,
    args: []Argument,
};

pub const CallbackInterface = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    name: []const u8,
    inherits: ?[]const u8,
    members: []InterfaceMember,
};

pub const Typedef = struct {
    loc: Location,
    extended_attributes: []ExtendedAttribute,
    type: TypeWithExtendedAttributes,
    name: []const u8,
};

pub const Definition = union(enum) {
    interface: Interface,
    interface_mixin: InterfaceMixin,
    partial_interface: PartialInterface,
    partial_mixin: PartialMixin,
    partial_dictionary: PartialDictionary,
    partial_namespace: PartialNamespace,
    includes: Includes,
    namespace: Namespace,
    dictionary: Dictionary,
    enumeration: Enumeration,
    callback: Callback,
    callback_interface: CallbackInterface,
    typedef: Typedef,
};

pub const Definitions = []Definition;

// Arena helper

/// A simple arena wrapper for AST allocation. Call deinit when done.
pub const Arena = struct {
    state: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) Arena {
        return .{ .state = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.state.allocator();
    }

    pub fn deinit(self: *Arena) void {
        self.state.deinit();
    }
};

// Compile-time reference smoke test

test "parse: type references compile" {
    // Just reference the types so they compile.
    _ = Definition;
    _ = Definitions;
    _ = Type;
    _ = ExtendedAttribute;
    _ = Argument;
    _ = Constant;
    _ = Attribute;
    _ = Operation;
    _ = Constructor;
    _ = InterfaceMember;
    _ = MixinMember;
    _ = NamespaceMember;
    _ = DictionaryMember;
    _ = EnumValue;
    _ = ValueLiteral;
    _ = Arena;
    _ = TypeWithExtendedAttributes;
    _ = BufferType;
    _ = Iterable;
    _ = Maplike;
    _ = Setlike;
}

test "parse: arena allocates and frees" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const p = try alloc.create(Type);
    p.* = .boolean;
    try std.testing.expectEqual(Type.boolean, p.*);
}
