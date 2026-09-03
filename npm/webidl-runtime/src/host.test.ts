import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHost, ABI_VERSION, ENV_IMPORTS } from './index.ts';

const enc = new TextEncoder();
const dec = new TextDecoder();

function setup() {
  const mem = new WebAssembly.Memory({ initial: 1 });
  let offset = 1024;
  const host = createHost();
  const inst = {
    exports: {
      memory: mem,
      webidl_rt_alloc(len: number): number { const p = offset; offset += len; return p; },
      webidl_rt_free(_ptr: number, _len: number): void {},
      webidl_rt_abi_version(): number { return ABI_VERSION; },
    },
  } as unknown as WebAssembly.Instance;
  host.attach(inst);
  return { host, mem, env: host.imports.env };
}

test('intern/value round-trip and null handle', () => {
  const host = createHost();
  assert.equal(host.intern(null), 0);
  assert.equal(host.intern(undefined), 0);
  assert.equal(host.value(0), null);

  const h = host.intern(42);
  assert.ok(h > 0);
  assert.equal(host.value(h), 42);

  const obj = { x: 1 };
  const hObj = host.intern(obj);
  assert.strictEqual(host.value(hObj), obj);
});

test('refcount: intern, retain, release, freed', () => {
  const host = createHost();
  const h = host.intern('hello');

  assert.equal(host.retainCount(h), 1);

  host.imports.env.__webidl_retain(h);
  assert.equal(host.retainCount(h), 2);

  host.imports.env.__webidl_release(h);
  assert.equal(host.retainCount(h), 1);

  host.imports.env.__webidl_release(h);
  assert.equal(host.retainCount(h), 0);
  assert.equal(host.value(h), undefined);
});

test('__webidl_str_to_handle decodes UTF-8 from memory', () => {
  const { host, mem, env } = setup();

  const str = 'こんにちは';
  const bytes = enc.encode(str);
  const ptr = 64;
  new Uint8Array(mem.buffer).set(bytes, ptr);

  const h = env.__webidl_str_to_handle(ptr, bytes.length);
  assert.equal(host.value(h), str);
});

test('__webidl_write_str encodes string to memory', () => {
  const { host, mem, env } = setup();

  const str = 'hello world';
  const h = host.seed('s', str);
  const packed = env.__webidl_write_str(h) as bigint;
  const ptr = Number(packed >> 32n);
  const len = Number(packed & 0xFFFFFFFFn);

  const bytes = new Uint8Array(mem.buffer, ptr, len);
  assert.equal(dec.decode(bytes), str);
});

test('__webidl_call_method invokes method on object with args', () => {
  const { host, mem, env } = setup();

  const obj = { greet: (x: number) => x + 1 };
  const objHandle = host.seed('obj', obj);
  const argHandle = host.intern(41);

  const methodBytes = enc.encode('greet');
  const mPtr = 128;
  new Uint8Array(mem.buffer).set(methodBytes, mPtr);

  const argsPtr = 200;
  new Uint32Array(mem.buffer, argsPtr, 1).set([argHandle]);

  const result = env.__webidl_call_method(objHandle, mPtr, methodBytes.length, argsPtr, 1);
  assert.equal(host.value(result), 42);
});

test('__webidl_construct creates instances via globalThis', () => {
  const { host, mem, env } = setup();

  (globalThis as any).__TestCtor = class { x: unknown; constructor(x: unknown) { this.x = x; } };

  try {
    const argHandle = host.intern(99);
    const nameBytes = enc.encode('__TestCtor');
    const namePtr = 300;
    new Uint8Array(mem.buffer).set(nameBytes, namePtr);

    const argsPtr = 400;
    new Uint32Array(mem.buffer, argsPtr, 1).set([argHandle]);

    const result = env.__webidl_construct(namePtr, nameBytes.length, argsPtr, 1);
    assert.equal((host.value(result) as any).x, 99);
  } finally {
    delete (globalThis as any).__TestCtor;
  }
});

test('__webidl_get_attr and __webidl_set_attr round-trip an attribute', () => {
  const { host, mem, env } = setup();

  const obj: Record<string, unknown> = { color: 'red' };
  const objHandle = host.seed('obj', obj);

  const attrBytes = enc.encode('color');
  const aPtr = 500;
  new Uint8Array(mem.buffer).set(attrBytes, aPtr);

  const h = env.__webidl_get_attr(objHandle, aPtr, attrBytes.length);
  assert.equal(host.value(h), 'red');

  const newValHandle = host.intern('blue');
  env.__webidl_set_attr(objHandle, aPtr, attrBytes.length, newValHandle);
  assert.equal(obj.color, 'blue');
});

test('__webidl_call_static, __webidl_get_static_attr, __webidl_set_static_attr via globalThis', () => {
  const { host, mem, env } = setup();

  (globalThis as any).__TestStaticIface = {
    greetStatic: (x: number) => x * 2,
    staticField: 10,
  };

  try {
    const ifaceBytes = enc.encode('__TestStaticIface');
    const ifacePtr = 600;
    new Uint8Array(mem.buffer).set(ifaceBytes, ifacePtr);

    const methodBytes = enc.encode('greetStatic');
    const mPtr = 650;
    new Uint8Array(mem.buffer).set(methodBytes, mPtr);

    const argHandle = host.intern(21);
    const argsPtr = 700;
    new Uint32Array(mem.buffer, argsPtr, 1).set([argHandle]);

    const result = env.__webidl_call_static(ifacePtr, ifaceBytes.length, mPtr, methodBytes.length, argsPtr, 1);
    assert.equal(host.value(result), 42);

    const attrBytes = enc.encode('staticField');
    const aPtr = 724;
    new Uint8Array(mem.buffer).set(attrBytes, aPtr);

    const attrHandle = env.__webidl_get_static_attr(ifacePtr, ifaceBytes.length, aPtr, attrBytes.length);
    assert.equal(host.value(attrHandle), 10);

    const newValHandle = host.intern(99);
    env.__webidl_set_static_attr(ifacePtr, ifaceBytes.length, aPtr, attrBytes.length, newValHandle);
    assert.equal((globalThis as any).__TestStaticIface.staticField, 99);
  } finally {
    delete (globalThis as any).__TestStaticIface;
  }
});

test('numeric converter round-trips: i32 and i64 BigInt', () => {
  const host = createHost();
  const env = host.imports.env;

  const i32h = env.__webidl_i32_to_handle(7);
  assert.equal(env.__webidl_handle_to_i32(i32h), 7);

  const large = BigInt('9007199254740993');
  const i64h = env.__webidl_i64_to_handle(large);
  assert.equal(env.__webidl_handle_to_i64(i64h), large);
});

test('createHost imports.env has exactly ENV_IMPORTS keys', () => {
  const host = createHost();
  const actualKeys = new Set(Object.keys(host.imports.env));
  const expectedKeys = new Set<string>(ENV_IMPORTS);
  assert.deepStrictEqual(actualKeys, expectedKeys);
});

test('attach throws on ABI version mismatch', () => {
  const host = createHost();
  const mem = new WebAssembly.Memory({ initial: 1 });
  const badInst = {
    exports: {
      memory: mem,
      webidl_rt_alloc(_len: number): number { return 0; },
      webidl_rt_free(): void {},
      webidl_rt_abi_version(): number { return ABI_VERSION + 1; },
    },
  } as unknown as WebAssembly.Instance;
  assert.throws(() => host.attach(badInst), { message: /mismatch/ });
});

test('__webidl_buf_to_handle hands JS a live view, so a fill lands in wasm memory', () => {
  const { host, mem, env } = setup();
  const ptr = 2048;
  const h = env['__webidl_buf_to_handle']!(ptr, 8, 6); // kind 6 = Uint8Array

  // What a fill target looks like from JS: writing through the handle writes
  // the caller's own memory, with no copy back.
  const view = host.value(h) as Uint8Array;
  assert.ok(view instanceof Uint8Array);
  assert.equal(view.length, 8);
  view.set([1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual(Array.from(new Uint8Array(mem.buffer, ptr, 8)), [1, 2, 3, 4, 5, 6, 7, 8]);
});

test('a buffer handle survives the heap growing under it', () => {
  // This is why the host stores a descriptor and not a typed array. Growing the
  // memory detaches every view over the old ArrayBuffer, and a stored view
  // would throw "detached" on the next read instead of showing the bytes.
  const { host, mem, env } = setup();
  const h = env['__webidl_buf_to_handle']!(2048, 4, 6);
  assert.equal((host.value(h) as Uint8Array).length, 4);

  mem.grow(1);

  const after = host.value(h) as Uint8Array;
  assert.ok(after instanceof Uint8Array);
  after.set([9, 9, 9, 9]);
  assert.deepEqual(Array.from(new Uint8Array(mem.buffer, 2048, 4)), [9, 9, 9, 9]);
});

test('the view flavour follows the declared kind', () => {
  const { host, env } = setup();
  // Element size, not byte count: 4 f32s is 16 bytes.
  const f32 = host.value(env['__webidl_buf_to_handle']!(2048, 4, 13)) as Float32Array;
  assert.ok(f32 instanceof Float32Array);
  assert.equal(f32.length, 4);
  assert.equal(f32.byteLength, 16);

  const i16 = host.value(env['__webidl_buf_to_handle']!(2048, 4, 4)) as Int16Array;
  assert.ok(i16 instanceof Int16Array);
  assert.equal(i16.byteLength, 8);
});

test('an unknown buffer kind is named rather than crashing as "not a constructor"', () => {
  const { host, env } = setup();
  const h = env['__webidl_buf_to_handle']!(2048, 4, 99);
  assert.throws(() => host.value(h), /unknown buffer kind 99/);
});

test('__webidl_write_bytes copies a JS buffer into wasm memory and hands over the bytes', () => {
  const { host, mem, env } = setup();
  const packed = env['__webidl_write_bytes']!(host.intern(new Uint8Array([10, 20, 30])));
  const ptr = Number(packed >> 32n);
  const len = Number(packed & 0xffffffffn);
  assert.equal(len, 3);
  assert.deepEqual(Array.from(new Uint8Array(mem.buffer, ptr, len)), [10, 20, 30]);

  // A plain ArrayBuffer is read the same way as a view over one.
  const packed2 = env['__webidl_write_bytes']!(host.intern(new Uint8Array([7, 7]).buffer));
  assert.equal(Number(packed2 & 0xffffffffn), 2);

  // Nothing to copy answers with a zero, which the Zig side reads as empty.
  assert.equal(env['__webidl_write_bytes']!(host.intern('not a buffer')), 0n);
  assert.equal(env['__webidl_write_bytes']!(host.intern(new Uint8Array(0))), 0n);
});
