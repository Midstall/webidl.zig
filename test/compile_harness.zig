//! Compile-check harness: importing this module verifies the generated Zig
//! source is valid Zig. The build maps "generated" to each style's output.
const generated = @import("generated");
test {
    _ = generated;
}
