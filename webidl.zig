//! webidl.zig: WebIDL parser and Zig bindgen for Zig 0.16.

pub const tokenizer = @import("webidl/tokenizer.zig");
pub const parse = @import("webidl/parse.zig");
pub const parser = @import("webidl/parser.zig");
pub const resolve = @import("webidl/resolve.zig");
pub const model = @import("webidl/model.zig");
pub const naming = @import("webidl/naming.zig");
pub const diagnostics = @import("webidl/diagnostics.zig");

/// Client runtime: the Wasm-to-JS boundary that client-generated code reaches
/// through `webidl.rt`.
pub const rt = @import("webidl/runtime/client.zig");

pub const emit = struct {
    pub const common = @import("webidl/emit/common.zig");
    pub const model_only = @import("webidl/emit/model_only.zig");
    pub const host = @import("webidl/emit/host.zig");
    pub const client = @import("webidl/emit/client.zig");
    pub const json_ir = @import("webidl/emit/json_ir.zig");
};

/// Convenience alias: parse -> resolve -> emit in one call.
pub const generate = emit.common.generate;

test {
    _ = tokenizer;
    _ = parse;
    _ = parser;
    _ = resolve;
    _ = model;
    _ = naming;
    _ = diagnostics;
    _ = emit.common;
    _ = emit.model_only;
    _ = emit.host;
    _ = emit.client;
    _ = emit.json_ir;
    _ = rt;
}
