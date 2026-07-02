import { createHost, type Host } from "./host.ts";

export type Source =
  | string
  | URL
  | Response
  | ArrayBuffer
  | Uint8Array
  | WebAssembly.Module;

export interface InstantiateOptions {
  seed?: Record<string, unknown>;
  imports?: WebAssembly.Imports;
}

export interface Instantiated {
  instance: WebAssembly.Instance;
  host: Host;
  exports: WebAssembly.Exports;
}

function looksLikeUrl(s: string): boolean {
  return (
    s.startsWith("http:") ||
    s.startsWith("https:") ||
    s.startsWith("file:")
  );
}

function hasStreamingInstantiate(): boolean {
  return (
    typeof (WebAssembly as Record<string, unknown>)["instantiateStreaming"] ===
    "function"
  );
}

async function instantiateBytes(
  bytes: BufferSource,
  imports: WebAssembly.Imports
): Promise<WebAssembly.Instance> {
  const result = await WebAssembly.instantiate(bytes, imports);
  return result.instance;
}

async function fetchInstantiate(
  input: string | URL | Request,
  imports: WebAssembly.Imports
): Promise<WebAssembly.Instance> {
  if (hasStreamingInstantiate()) {
    const result = await WebAssembly.instantiateStreaming(fetch(input), imports);
    return result.instance;
  }
  const resp = await fetch(input);
  return instantiateBytes(await resp.arrayBuffer(), imports);
}

export async function instantiate(
  source: Source,
  opts?: InstantiateOptions
): Promise<Instantiated> {
  const host = createHost();

  const userEnv = (opts?.imports?.["env"] ?? {}) as WebAssembly.ModuleImports;
  const env: WebAssembly.ModuleImports = {
    ...userEnv,
    ...(host.imports.env as unknown as WebAssembly.ModuleImports),
  };
  const importObj: WebAssembly.Imports = { ...opts?.imports, env };

  let instance: WebAssembly.Instance;

  if (source instanceof WebAssembly.Module) {
    instance = await WebAssembly.instantiate(source, importObj);
  } else if (
    typeof (globalThis as Record<string, unknown>)["Response"] === "function" &&
    source instanceof Response
  ) {
    if (hasStreamingInstantiate()) {
      const result = await WebAssembly.instantiateStreaming(source, importObj);
      instance = result.instance;
    } else {
      instance = await instantiateBytes(await source.arrayBuffer(), importObj);
    }
  } else if (source instanceof URL) {
    instance = await fetchInstantiate(source, importObj);
  } else if (typeof source === "string" && looksLikeUrl(source)) {
    instance = await fetchInstantiate(source, importObj);
  } else if (typeof source === "string") {
    const { readFile } = await import("node:fs/promises");
    const bytes = await readFile(source);
    instance = await instantiateBytes(bytes, importObj);
  } else {
    instance = await instantiateBytes(source as BufferSource, importObj);
  }

  host.attach(instance);

  for (const [name, value] of Object.entries(opts?.seed ?? {})) {
    host.seed(name, value);
  }

  return { instance, host, exports: instance.exports };
}
