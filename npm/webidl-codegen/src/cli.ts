#!/usr/bin/env node
import { fileURLToPath } from "node:url";
import { parseIR } from "./ir.ts";
import { generate } from "./emit-ts.ts";

export async function main(argv: string[]): Promise<void> {
  if (argv.includes("-h") || argv.includes("--help")) {
    process.stdout.write("usage: webidl-codegen <input.json> [-o output.ts]\n");
    return;
  }

  let outputPath: string | null = null;
  const remaining: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "-o") {
      if (i + 1 >= argv.length) {
        throw new Error("error: -o requires a following value");
      }
      outputPath = argv[i + 1];
      i++;
    } else {
      remaining.push(argv[i]);
    }
  }
  if (remaining.length === 0) {
    throw new Error("usage: webidl-codegen <input.json> [-o output.ts]");
  }
  const inputPath = remaining[0];

  const { readFileSync, writeFileSync } = await import("node:fs");
  const json = readFileSync(inputPath, "utf-8");
  const ir = parseIR(json);
  const code = generate(ir);

  if (outputPath) {
    writeFileSync(outputPath, code);
  } else {
    process.stdout.write(code);
  }
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).catch((e: unknown) => {
    process.stderr.write(String(e) + "\n");
    process.exit(1);
  });
}
