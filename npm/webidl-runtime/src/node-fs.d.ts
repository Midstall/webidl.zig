declare module "node:fs/promises" {
  export function readFile(path: string): Promise<Uint8Array<ArrayBuffer>>;
}
