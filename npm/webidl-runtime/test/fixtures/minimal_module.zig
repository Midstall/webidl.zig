export fn webidl_rt_abi_version() u32 {
    return 1;
}
var scratch: [4096]u8 = undefined;
export fn webidl_rt_alloc(len: usize) ?[*]u8 {
    _ = len;
    return &scratch;
}
export fn webidl_rt_free(ptr: [*]u8, len: usize) void {
    _ = ptr;
    _ = len;
}
