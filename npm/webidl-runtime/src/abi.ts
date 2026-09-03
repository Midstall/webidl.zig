// Only bump due to breaking changes in major or minor releases.
export const ABI_VERSION = 1;

export const ENV_IMPORTS = [
  "__webidl_call_method",
  "__webidl_get_attr",
  "__webidl_set_attr",
  "__webidl_bool_to_handle",
  "__webidl_handle_to_bool",
  "__webidl_i32_to_handle",
  "__webidl_handle_to_i32",
  "__webidl_u32_to_handle",
  "__webidl_handle_to_u32",
  "__webidl_i64_to_handle",
  "__webidl_handle_to_i64",
  "__webidl_u64_to_handle",
  "__webidl_handle_to_u64",
  "__webidl_f64_to_handle",
  "__webidl_handle_to_f64",
  "__webidl_str_to_handle",
  "__webidl_write_str",
  "__webidl_buf_to_handle",
  "__webidl_write_bytes",
  "__webidl_call_static",
  "__webidl_get_static_attr",
  "__webidl_set_static_attr",
  "__webidl_construct",
  "__webidl_retain",
  "__webidl_release",
] as const;

/// What each buffer kind is viewed AS over wasm memory, indexed by the kind
/// number. The order IS the ABI: it is the declaration order of
/// `model.BufferKind` and of `BufferKind` in the Zig runtime, and all three move
/// together. Appending is safe; reordering silently hands JS the wrong
/// constructor, which reads the caller's bytes at the wrong stride.
///
/// The three that are not typed arrays in their own right (ArrayBuffer,
/// SharedArrayBuffer, DataView) are handed over as a byte view, because wasm
/// memory is the backing store and a fresh ArrayBuffer would be a copy rather
/// than the caller's own bytes.
export const BUFFER_VIEW_CTORS = [
  "Uint8Array",
  "Uint8Array",
  "Uint8Array",
  "Int8Array",
  "Int16Array",
  "Int32Array",
  "Uint8Array",
  "Uint16Array",
  "Uint32Array",
  "Uint8ClampedArray",
  "BigInt64Array",
  "BigUint64Array",
  "Float16Array",
  "Float32Array",
  "Float64Array",
] as const;
