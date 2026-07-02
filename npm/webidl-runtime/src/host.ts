import { ABI_VERSION, ENV_IMPORTS } from './abi.ts';

export interface Host {
  imports: { env: Record<string, (...a: any[]) => any> };
  intern(v: unknown): number;
  value(h: number): unknown;
  seed(name: string, v: unknown): number;
  attach(instance: WebAssembly.Instance): void;
  retainCount(h: number): number;
}

export function createHost(): Host {
  const handleTable = new Map<number, unknown>();
  const refcounts = new Map<number, number>();
  let nextId = 1;

  let memory: WebAssembly.Memory | null = null;
  let allocFn: ((len: number) => number) | null = null;
  let freeFn: ((ptr: number, len: number) => void) | null = null;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function getMemory(): WebAssembly.Memory {
    if (!memory) throw new Error('Host not attached to a WebAssembly instance');
    return memory;
  }

  function getAlloc(): (len: number) => number {
    if (!allocFn) throw new Error('Host not attached');
    return allocFn;
  }

  function internValue(v: unknown): number {
    if (v === null || v === undefined) return 0;
    const id = nextId++;
    handleTable.set(id, v);
    refcounts.set(id, 1);
    return id;
  }

  function getValue(h: number): unknown {
    if (h === 0) return null;
    return handleTable.get(h);
  }

  function readString(ptr: number, len: number): string {
    return decoder.decode(new Uint8Array(getMemory().buffer, ptr, len));
  }

  function readArgs(argsPtr: number, argsLen: number): unknown[] {
    if (argsLen === 0) return [];
    // argsPtr is 4-byte aligned. Zig guarantees this for []Handle.
    const handles = new Uint32Array(getMemory().buffer, argsPtr, argsLen);
    return Array.from(handles).map(h => getValue(h));
  }

  const host: Host = {
    intern: internValue,
    value: getValue,

    seed(_name: string, v: unknown): number {
      return internValue(v);
    },

    retainCount(h: number): number {
      return refcounts.get(h) ?? 0;
    },

    attach(instance: WebAssembly.Instance): void {
      const exp = instance.exports;
      const versionFn = exp['webidl_rt_abi_version'] as () => number;
      const ver = versionFn();
      if (ver !== ABI_VERSION) {
        throw new Error(`ABI version mismatch: expected ${ABI_VERSION}, got ${ver}`);
      }
      memory = exp['memory'] as WebAssembly.Memory;
      allocFn = exp['webidl_rt_alloc'] as (len: number) => number;
      freeFn = exp['webidl_rt_free'] as (ptr: number, len: number) => void;
    },

    imports: {
      env: {
        __webidl_retain(h: number): void {
          const c = refcounts.get(h);
          if (c !== undefined) refcounts.set(h, c + 1);
        },

        __webidl_release(h: number): void {
          const c = refcounts.get(h);
          if (c === undefined) return;
          if (c <= 1) {
            handleTable.delete(h);
            refcounts.delete(h);
          } else {
            refcounts.set(h, c - 1);
          }
        },

        // Transient primitive/string handles aren't auto-released. Object lifetimes rely on retain/release.
        __webidl_str_to_handle(ptr: number, len: number): number {
          return internValue(readString(ptr, len));
        },

        __webidl_write_str(h: number): bigint {
          const s = String(getValue(h));
          const bytes = encoder.encode(s);
          if (bytes.length === 0) return 0n;
          const ptr = getAlloc()(bytes.length);
          new Uint8Array(getMemory().buffer, ptr, bytes.length).set(bytes);
          return (BigInt(ptr) << 32n) | BigInt(bytes.length);
        },

        __webidl_bool_to_handle(v: number): number {
          return internValue(v !== 0);
        },

        __webidl_handle_to_bool(h: number): number {
          return getValue(h) ? 1 : 0;
        },

        __webidl_i32_to_handle(v: number): number {
          return internValue(v);
        },

        __webidl_handle_to_i32(h: number): number {
          return getValue(h) as number;
        },

        __webidl_u32_to_handle(v: number): number {
          return internValue(v >>> 0);
        },

        __webidl_handle_to_u32(h: number): number {
          return (getValue(h) as number) >>> 0;
        },

        __webidl_i64_to_handle(v: bigint): number {
          return internValue(v);
        },

        __webidl_handle_to_i64(h: number): bigint {
          return BigInt(getValue(h) as number | bigint);
        },

        __webidl_u64_to_handle(v: bigint): number {
          return internValue(v);
        },

        __webidl_handle_to_u64(h: number): bigint {
          return BigInt(getValue(h) as number | bigint);
        },

        __webidl_f64_to_handle(v: number): number {
          return internValue(v);
        },

        __webidl_handle_to_f64(h: number): number {
          return getValue(h) as number;
        },

        __webidl_call_method(handle: number, mPtr: number, mLen: number, argsPtr: number, argsLen: number): number {
          const obj = getValue(handle) as Record<string, (...a: unknown[]) => unknown>;
          const method = readString(mPtr, mLen);
          const args = readArgs(argsPtr, argsLen);
          return internValue(obj[method](...args));
        },

        __webidl_get_attr(handle: number, aPtr: number, aLen: number): number {
          const obj = getValue(handle) as Record<string, unknown>;
          const attr = readString(aPtr, aLen);
          return internValue(obj[attr]);
        },

        __webidl_set_attr(handle: number, aPtr: number, aLen: number, valueHandle: number): void {
          const obj = getValue(handle) as Record<string, unknown>;
          const attr = readString(aPtr, aLen);
          obj[attr] = getValue(valueHandle);
        },

        __webidl_call_static(ifacePtr: number, ifaceLen: number, mPtr: number, mLen: number, argsPtr: number, argsLen: number): number {
          const iface = readString(ifacePtr, ifaceLen);
          const method = readString(mPtr, mLen);
          const args = readArgs(argsPtr, argsLen);
          const g = globalThis as unknown as Record<string, Record<string, (...a: unknown[]) => unknown>>;
          return internValue(g[iface][method](...args));
        },

        __webidl_get_static_attr(ifacePtr: number, ifaceLen: number, aPtr: number, aLen: number): number {
          const iface = readString(ifacePtr, ifaceLen);
          const attr = readString(aPtr, aLen);
          const g = globalThis as unknown as Record<string, Record<string, unknown>>;
          return internValue(g[iface][attr]);
        },

        __webidl_set_static_attr(ifacePtr: number, ifaceLen: number, aPtr: number, aLen: number, valueHandle: number): void {
          const iface = readString(ifacePtr, ifaceLen);
          const attr = readString(aPtr, aLen);
          const g = globalThis as unknown as Record<string, Record<string, unknown>>;
          g[iface][attr] = getValue(valueHandle);
        },

        __webidl_construct(namePtr: number, nameLen: number, argsPtr: number, argsLen: number): number {
          const name = readString(namePtr, nameLen);
          const args = readArgs(argsPtr, argsLen);
          const ctor = (globalThis as unknown as Record<string, new (...a: unknown[]) => unknown>)[name];
          return internValue(new ctor(...args));
        },
      },
    },
  };

  const actualKeys = new Set(Object.keys(host.imports.env));
  const expectedKeys = new Set<string>(ENV_IMPORTS);
  const missing = [...expectedKeys].filter(k => !actualKeys.has(k));
  const extra = [...actualKeys].filter(k => !expectedKeys.has(k));
  if (missing.length > 0 || extra.length > 0) {
    const parts: string[] = [];
    if (missing.length > 0) parts.push(`missing: ${missing.join(', ')}`);
    if (extra.length > 0) parts.push(`extra: ${extra.join(', ')}`);
    throw new Error(`host imports.env does not match ENV_IMPORTS (${parts.join('; ')})`);
  }

  return host;
}
