interface ImportMeta {
  url: string;
}

declare var process: {
  argv: string[];
  stdout: { write: (s: string) => boolean };
  stderr: { write: (s: string) => boolean };
  exit(code?: number): never;
};

declare module "node:fs" {
  export function readFileSync(path: string, encoding: string): string;
  export function writeFileSync(path: string, data: string, encoding?: string): void;
  export function existsSync(path: string): boolean;
  export function unlinkSync(path: string): void;
}

declare module "node:os" {
  export function tmpdir(): string;
}

declare module "node:url" {
  export function fileURLToPath(url: string): string;
}
