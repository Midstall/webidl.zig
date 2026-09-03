//! Minimal Wasm-to-JS boundary runtime for webidl.zig client-generated code.
//! This module is imported as `webidl.rt` by the source that webidl/emit/client.zig
//! generates. It targets wasm32 but is type-checked on all platforms. The
//! extern symbols are resolved by the JS host at wasm instantiation time.

const std = @import("std");
const builtin = @import("builtin");

/// Allocator for runtime-owned allocations (e.g. string buffers the JS host
/// writes via webidl_rt_alloc). wasm32 uses the wasm allocator, native tests
/// use the page allocator.
const rt_alloc: std.mem.Allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

/// Opaque JS-object reference.  Zero is the null/undefined handle.
pub const Handle = u32;

// Allocator exports (JS host calls these to allocate/free string buffers in
// Wasm linear memory on behalf of Zig).

/// Allocate `len` bytes from the runtime allocator and return a pointer to the
/// buffer. Returns null if `len` is zero or allocation fails. The JS host uses
/// this when it needs to write a string into Wasm memory.
pub export fn webidl_rt_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const buf = rt_alloc.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Free a buffer previously returned by `webidl_rt_alloc`. Passing `len == 0`
/// is a no-op.
pub export fn webidl_rt_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    rt_alloc.free(ptr[0..len]);
}

/// Return the ABI version this runtime implements. The JS host can check this
/// at startup to detect incompatible runtime/host pairings.
pub export fn webidl_rt_abi_version() u32 {
    return 1;
}

/// The typed-array flavour a buffer handle stands for. The numbering IS the ABI:
/// `BUFFER_VIEW_CTORS` in the JS host is indexed by it, and it matches the
/// declaration order of `model.BufferKind`. Appending is safe; reordering is not.
pub const BufferKind = enum(u32) {
    array_buffer = 0,
    shared_array_buffer = 1,
    data_view = 2,
    int8_array = 3,
    int16_array = 4,
    int32_array = 5,
    uint8_array = 6,
    uint16_array = 7,
    uint32_array = 8,
    uint8_clamped_array = 9,
    bigint64_array = 10,
    biguint64_array = 11,
    float16_array = 12,
    float32_array = 13,
    float64_array = 14,
};

// JS boundary imports (resolved by the host at wasm link/instantiation time)

extern "env" fn __webidl_call_method(
    handle: Handle,
    method_ptr: [*]const u8,
    method_len: usize,
    args_ptr: [*]const Handle,
    args_len: usize,
) Handle;

extern "env" fn __webidl_get_attr(
    handle: Handle,
    attr_ptr: [*]const u8,
    attr_len: usize,
) Handle;

extern "env" fn __webidl_set_attr(
    handle: Handle,
    attr_ptr: [*]const u8,
    attr_len: usize,
    value: Handle,
) void;

extern "env" fn __webidl_bool_to_handle(v: u32) Handle;
extern "env" fn __webidl_handle_to_bool(h: Handle) u32;
extern "env" fn __webidl_i32_to_handle(v: i32) Handle;
extern "env" fn __webidl_handle_to_i32(h: Handle) i32;
extern "env" fn __webidl_u32_to_handle(v: u32) Handle;
extern "env" fn __webidl_handle_to_u32(h: Handle) u32;
extern "env" fn __webidl_i64_to_handle(v: i64) Handle;
extern "env" fn __webidl_handle_to_i64(h: Handle) i64;
extern "env" fn __webidl_u64_to_handle(v: u64) Handle;
extern "env" fn __webidl_handle_to_u64(h: Handle) u64;
extern "env" fn __webidl_f64_to_handle(v: f64) Handle;
extern "env" fn __webidl_handle_to_f64(h: Handle) f64;
extern "env" fn __webidl_str_to_handle(ptr: [*]const u8, len: usize) Handle;

/// Single-call string-out: the JS host allocates a buffer via
/// `webidl_rt_alloc`, writes the UTF-8 string, and returns
/// `(ptr << 32) | len` packed into a u64. The Zig side then owns that
/// allocation and must free it with `freeStr` when done.
extern "env" fn __webidl_write_str(h: Handle) u64;

/// Hand JS a VIEW over wasm memory rather than a copy of it. `len` counts
/// elements, not bytes, because that is what a typed array constructor takes.
///
/// The host keeps the three numbers and builds the view fresh on every read, so
/// a heap that grows between this call and the use of the handle cannot leave a
/// detached view behind.
extern "env" fn __webidl_buf_to_handle(ptr: [*]const u8, len: usize, kind: u32) Handle;

/// Single-call bytes-out, the same shape as `__webidl_write_str`: the host
/// allocates through `webidl_rt_alloc`, copies the buffer in, and returns
/// `(ptr << 32) | byte_len`. The Zig side owns the result and frees it.
extern "env" fn __webidl_write_bytes(h: Handle) u64;

// Public API (thin wrappers that generated code calls)

/// Call a named method on a JS object.  `args` is a slice of Handle values
/// (one per argument).  Returns the result as a Handle (0 for void/undefined).
pub fn callMethod(handle: Handle, method: []const u8, args: []const Handle) Handle {
    return __webidl_call_method(handle, method.ptr, method.len, args.ptr, args.len);
}

/// Read a named attribute from a JS object.  Returns a Handle to the value.
pub fn getAttr(handle: Handle, attr: []const u8) Handle {
    return __webidl_get_attr(handle, attr.ptr, attr.len);
}

/// Write a named attribute on a JS object.  `value` is a Handle to the new value.
pub fn setAttr(handle: Handle, attr: []const u8, value: Handle) void {
    __webidl_set_attr(handle, attr.ptr, attr.len, value);
}

// Zig -> Handle conversions

pub fn fromBool(v: bool) Handle {
    return __webidl_bool_to_handle(@intFromBool(v));
}

pub fn fromI32(v: i32) Handle {
    return __webidl_i32_to_handle(v);
}

pub fn fromU32(v: u32) Handle {
    return __webidl_u32_to_handle(v);
}

pub fn fromI64(v: i64) Handle {
    return __webidl_i64_to_handle(v);
}

pub fn fromU64(v: u64) Handle {
    return __webidl_u64_to_handle(v);
}

pub fn fromF64(v: f64) Handle {
    return __webidl_f64_to_handle(v);
}

/// Pass a Zig string slice to JS. The JS side reads directly from Wasm
/// linear memory while the call is active. Do not retain the pointer.
pub fn fromStr(s: []const u8) Handle {
    return __webidl_str_to_handle(s.ptr, s.len);
}

// Handle -> Zig conversions

pub fn toBool(h: Handle) bool {
    return __webidl_handle_to_bool(h) != 0;
}

pub fn toI32(h: Handle) i32 {
    return __webidl_handle_to_i32(h);
}

pub fn toU32(h: Handle) u32 {
    return __webidl_handle_to_u32(h);
}

pub fn toI64(h: Handle) i64 {
    return __webidl_handle_to_i64(h);
}

pub fn toU64(h: Handle) u64 {
    return __webidl_handle_to_u64(h);
}

pub fn toF64(h: Handle) f64 {
    return __webidl_handle_to_f64(h);
}

/// Ptr + length unpacked from the 64-bit value returned by `__webidl_write_str`.
const StrLoc = struct { ptr: usize, len: usize };

/// Unpack the `(ptr << 32) | len` encoding used by `__webidl_write_str`.
/// Pure function, unit-testable on any target without the extern boundary.
fn unpackStr(packed_val: u64) StrLoc {
    return .{
        .ptr = @intCast(packed_val >> 32),
        .len = @intCast(packed_val & 0xFFFF_FFFF),
    };
}

/// Fetch a JS string from handle `h` as an OWNED Zig slice.
///
/// The JS host allocates the buffer via `webidl_rt_alloc` and hands ownership
/// to Zig. Caller MUST free the returned slice with `freeStr` when done.
pub fn toStr(h: Handle) []const u8 {
    const loc = unpackStr(__webidl_write_str(h));
    if (loc.len == 0) return "";
    return @as([*]const u8, @ptrFromInt(loc.ptr))[0..loc.len];
}

/// Free a string slice that was returned by `toStr`. Passing the empty string
/// literal `""` is a no-op.
pub fn freeStr(s: []const u8) void {
    if (s.len == 0) return;
    rt_alloc.free(@constCast(s));
}

/// Pass a Zig slice to JS as a view over wasm memory. JS reads AND writes it in
/// place, which is the whole point: `crypto.getRandomValues(buf)` fills the
/// caller's slice with no copy on either side.
///
/// The view is only valid while the call that receives it is running. JS must
/// not keep it, and this side must not grow the heap underneath it.
pub fn fromBuf(comptime T: type, buf: []T, kind: BufferKind) Handle {
    return __webidl_buf_to_handle(@ptrCast(buf.ptr), buf.len, @intFromEnum(kind));
}

/// Fetch a JS buffer as an OWNED Zig slice. The host copies the bytes into wasm
/// memory and hands ownership over, the same as `toStr`. Free it with `freeBuf`.
///
/// Returns an empty slice when the handle holds no buffer, or when the byte
/// length is not a whole number of `T`, which is a host that answered with a
/// different flavour of array than the IDL declared.
pub fn toBuf(comptime T: type, h: Handle) []T {
    const loc = unpackStr(__webidl_write_bytes(h));
    if (loc.len == 0) return &[_]T{};
    if (loc.len % @sizeOf(T) != 0) return &[_]T{};
    const p: [*]T = @ptrFromInt(loc.ptr);
    return p[0 .. loc.len / @sizeOf(T)];
}

/// Free a slice that was returned by `toBuf`. An empty slice is a no-op.
pub fn freeBuf(comptime T: type, buf: []T) void {
    if (buf.len == 0) return;
    rt_alloc.free(buf);
}

/// Return the null/undefined handle sentinel (zero).
/// Used by generated client code for nullable-null cases.
pub fn nullHandle() Handle {
    return 0;
}

extern "env" fn __webidl_retain(h: Handle) void;
extern "env" fn __webidl_release(h: Handle) void;

/// Increment the host-side reference count for a handle.
pub fn retain(h: Handle) void {
    __webidl_retain(h);
}

/// Decrement the host-side reference count for a handle. When it reaches zero
/// the host drops the handle from its table, freeing the slot.
pub fn release(h: Handle) void {
    __webidl_release(h);
}

// Static / constructor boundary (interface-level, no instance handle)

extern "env" fn __webidl_call_static(
    iface_ptr: [*]const u8,
    iface_len: usize,
    method_ptr: [*]const u8,
    method_len: usize,
    args_ptr: [*]const Handle,
    args_len: usize,
) Handle;

extern "env" fn __webidl_get_static_attr(
    iface_ptr: [*]const u8,
    iface_len: usize,
    attr_ptr: [*]const u8,
    attr_len: usize,
) Handle;

extern "env" fn __webidl_set_static_attr(
    iface_ptr: [*]const u8,
    iface_len: usize,
    attr_ptr: [*]const u8,
    attr_len: usize,
    value: Handle,
) void;

extern "env" fn __webidl_construct(
    name_ptr: [*]const u8,
    name_len: usize,
    args_ptr: [*]const Handle,
    args_len: usize,
) Handle;

/// Call a static method on a JS interface by name.
pub fn callStaticMethod(iface_name: []const u8, method: []const u8, args: []const Handle) Handle {
    return __webidl_call_static(iface_name.ptr, iface_name.len, method.ptr, method.len, args.ptr, args.len);
}

/// Read a static attribute from a JS interface.
pub fn getStaticAttr(iface_name: []const u8, attr: []const u8) Handle {
    return __webidl_get_static_attr(iface_name.ptr, iface_name.len, attr.ptr, attr.len);
}

/// Write a static attribute on a JS interface.
pub fn setStaticAttr(iface_name: []const u8, attr: []const u8, value: Handle) void {
    __webidl_set_static_attr(iface_name.ptr, iface_name.len, attr.ptr, attr.len, value);
}

/// Construct a new JS object by interface name.
pub fn construct(iface_name: []const u8, args: []const Handle) Handle {
    return __webidl_construct(iface_name.ptr, iface_name.len, args.ptr, args.len);
}

// Tests (native target: do NOT call extern fns)

test {
    _ = Handle;
}

test "webidl_rt_abi_version is 1" {
    try std.testing.expectEqual(@as(u32, 1), webidl_rt_abi_version());
}

test "the buffer kind numbering is the ABI and does not drift" {
    // BUFFER_VIEW_CTORS on the JS side is indexed by these numbers. A reorder
    // here silently hands JS the wrong constructor, which is a wrong ANSWER
    // rather than a crash: bytes read as the wrong element type.
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(BufferKind.array_buffer));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(BufferKind.uint8_array));
    try std.testing.expectEqual(@as(u32, 14), @intFromEnum(BufferKind.float64_array));
    try std.testing.expectEqual(15, @typeInfo(BufferKind).@"enum".fields.len);
}

test "webidl_rt_alloc(0) returns null" {
    try std.testing.expectEqual(@as(?[*]u8, null), webidl_rt_alloc(0));
}

test "webidl_rt_alloc/free round-trip" {
    const len = 16;
    const ptr = webidl_rt_alloc(len) orelse return error.AllocFailed;
    // Write something so the memory is actually touched.
    for (0..len) |i| ptr[i] = @intCast(i);
    webidl_rt_free(ptr, len);
}

test "unpackStr: ptr and len are extracted correctly" {
    // ptr = 0x1000, len = 5
    const a = unpackStr((@as(u64, 0x1000) << 32) | 5);
    try std.testing.expectEqual(@as(usize, 0x1000), a.ptr);
    try std.testing.expectEqual(@as(usize, 5), a.len);

    // ptr = 0xDEAD_BEEF, len = 0x1234
    const b = unpackStr((@as(u64, 0xDEAD_BEEF) << 32) | 0x1234);
    try std.testing.expectEqual(@as(usize, 0xDEAD_BEEF), b.ptr);
    try std.testing.expectEqual(@as(usize, 0x1234), b.len);

    // zero packed value: both fields zero
    const c = unpackStr(0);
    try std.testing.expectEqual(@as(usize, 0), c.ptr);
    try std.testing.expectEqual(@as(usize, 0), c.len);
}
