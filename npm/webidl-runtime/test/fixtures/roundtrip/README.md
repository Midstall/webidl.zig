# Round-trip fixture

`roundtrip.wasm` is a pre-built Wasm binary committed to the repo so that
`npm test` works without a Zig toolchain.

## Rebuild recipe

Run the commands below from the **repo root** (`/path/to/webidl.zig/`).

### Regenerate bindings

```
webidl2zig --style client npm/webidl-runtime/test/fixtures/roundtrip/dom.webidl -o npm/webidl-runtime/test/fixtures/roundtrip/bindings.zig
```

### Rebuild the Wasm binary

```
zig build-exe \
  -target wasm32-freestanding \
  -fno-entry \
  -rdynamic \
  -O ReleaseSmall \
  --dep webidl \
  -Mroot=npm/webidl-runtime/test/fixtures/roundtrip/entry.zig \
  -Mwebidl=webidl.zig \
  -femit-bin=npm/webidl-runtime/test/fixtures/roundtrip/roundtrip.wasm
```

After rebuilding, run the test suite to confirm the binary is correct:

```
cd npm && npm -w @midstall/webidl-runtime test
```
