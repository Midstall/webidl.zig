//! Round-trip test entry: drives the generated client bindings so the JS host
//! observes getAttr/toStr/setAttr/callMethod/retain/release across the boundary.
const bindings = @import("bindings.zig");
const webidl = @import("webidl");

/// Read textContent (owned string via the allocator string-out path), free it,
/// set textContent to "changed", append `child` to `el`, and retain/release the
/// returned handle. Returns the original textContent byte length.
export fn run(el_h: u32, child_h: u32) u32 {
    const el = bindings.Element{ .handle = el_h };
    const child = bindings.Element{ .handle = child_h };

    const s = el.get_textContent();
    const len: u32 = @intCast(s.len);
    webidl.rt.freeStr(s);

    el.set_textContent("changed");

    const appended = el.appendChild(child);
    appended.ref();
    appended.unref();

    return len;
}
