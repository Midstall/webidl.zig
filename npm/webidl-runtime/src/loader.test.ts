import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate } from "./loader.ts";

const fixtureWasm = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../test/fixtures/minimal_module.wasm"
);

const fixtureBytes = readFileSync(fixtureWasm) as unknown as Uint8Array;

test("instantiate from Uint8Array bytes returns instance, host, and exports", async () => {
  const { instance, host, exports } = await instantiate(fixtureBytes);
  assert.ok(instance instanceof WebAssembly.Instance);
  assert.ok(exports["memory"] instanceof WebAssembly.Memory);
  const h = host.intern("sanity");
  assert.ok(h > 0);
  assert.equal(host.value(h), "sanity");
});

test("instantiate from pre-compiled WebAssembly.Module works", async () => {
  const mod = new WebAssembly.Module(fixtureBytes);
  const { instance, exports } = await instantiate(mod);
  assert.ok(instance instanceof WebAssembly.Instance);
  assert.ok(exports["memory"] instanceof WebAssembly.Memory);
});

test("instantiate from absolute path string uses node:fs branch", async () => {
  const { instance, exports } = await instantiate(fixtureWasm);
  assert.ok(instance instanceof WebAssembly.Instance);
  assert.ok(exports["memory"] instanceof WebAssembly.Memory);
});

test("instantiate with seed option wires values into host", async () => {
  const doc = { tag: "doc" };
  const { host } = await instantiate(fixtureBytes, {
    seed: { document: doc },
  });
  assert.strictEqual(host.value(1), doc);
  const h = host.intern("extra");
  assert.equal(host.value(h), "extra");
});
