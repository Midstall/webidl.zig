import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHost } from './index.ts';

const wasmPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../test/fixtures/roundtrip/roundtrip.wasm',
);

const bytes = readFileSync(wasmPath) as unknown as Uint8Array;

test('roundtrip: getAttr/toStr/freeStr + setAttr/fromStr + callMethod + retain/release', async () => {
  const host = createHost();
  const mod = new WebAssembly.Module(bytes);
  const instance = await WebAssembly.instantiate(mod, host.imports as unknown as WebAssembly.Imports);
  host.attach(instance);

  const appended: unknown[] = [];
  const el = {
    textContent: 'hello',
    appendChild(c: unknown) { appended.push(c); return c; },
  };
  const child = {};

  const elH = host.intern(el);
  const childH = host.intern(child);

  const exports = instance.exports as unknown as { run(elH: number, childH: number): number };
  const ret = exports.run(elH, childH);

  assert.equal(ret, 5);
  assert.equal((el as Record<string, unknown>).textContent, 'changed');
  assert.strictEqual(appended[0], child);
});
