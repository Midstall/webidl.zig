# webidl.zig

WebIDL parser and Zig bindgen targeting Zig 0.16.

## CLI

```
webidl2zig [--style model|host|client] [--emit json] [--mozilla] <input.webidl>... [-o output.zig]

  --style <s>   output style (default: model)
  --emit json   emit JSON IR instead of Zig (mutually exclusive with --style)
  --mozilla     accept Mozilla/Gecko WebIDL extensions (forward declarations,
                string/integer-valued extended attributes)
  -o <path>     write to file instead of stdout
  -h, --help    show this help
```

Multiple input files are read and resolved together in one scope, so a file may
reference definitions declared in another:

```sh
zig build run -- --style host api.webidl -o api_host.zig
zig build run -- --mozilla --style client Node.webidl Element.webidl -o dom.zig
```

## Build system helper

Add webidl.zig as a dependency, then in your `build.zig`:

```zig
const webidl = @import("webidl");

const api_mod = webidl.generateModule(b, b.dependency("webidl", .{}), .{
    .name = "api",
    .idl  = b.path("api.webidl"),
    .style = .model,
});
exe.root_module.addImport("api", api_mod);
```

Styles: `.model` (plain Zig structs), `.host` (vtable wrappers), `.client` (Wasm handle wrappers, auto-imports the runtime as `core`).
