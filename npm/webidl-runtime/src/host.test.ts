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
