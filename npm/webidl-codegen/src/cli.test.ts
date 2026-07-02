import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { parseIR } from "./ir.ts";
import { generate } from "./emit-ts.ts";
import { main } from "./cli.ts";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "fixtures");

describe("cli main", () => {
  it("writes output to file when -o is provided", async () => {
    const minimalPath = join(fixturesDir, "minimal.json");
    const tmpFile = join(tmpdir(), `webidl-codegen-test-${Date.now()}.ts`);
    try {
      await main([minimalPath, "-o", tmpFile]);
      const actual = readFileSync(tmpFile, "utf-8");
      const expected = generate(parseIR(readFileSync(minimalPath, "utf-8")));
      assert.strictEqual(actual, expected);
    } finally {
      if (existsSync(tmpFile)) unlinkSync(tmpFile);
    }
  });

  it("writes output to stdout when no -o is provided", async () => {
    const minimalPath = join(fixturesDir, "minimal.json");
    const expected = generate(parseIR(readFileSync(minimalPath, "utf-8")));

    let captured = "";
    const origWrite = process.stdout.write.bind(process.stdout);
    process.stdout.write = (s: string): boolean => {
      captured += s;
      return true;
    };
    try {
      await main([minimalPath]);
    } finally {
      process.stdout.write = origWrite;
    }
    assert.strictEqual(captured, expected);
  });

  it("writes usage to stdout for -h flag", async () => {
    let captured = "";
    const origWrite = process.stdout.write.bind(process.stdout);
    process.stdout.write = (s: string): boolean => {
      captured += s;
      return true;
    };
    try {
      await main(["-h"]);
    } finally {
      process.stdout.write = origWrite;
    }
    assert.ok(captured.toLowerCase().includes("usage"), "should contain usage message");
  });

  it("flag-before-positional and positional-before-flag produce identical output", async () => {
    const minimalPath = join(fixturesDir, "minimal.json");
    const tmpA = join(tmpdir(), `webidl-codegen-test-a-${Date.now()}.ts`);
    const tmpB = join(tmpdir(), `webidl-codegen-test-b-${Date.now()}.ts`);
    try {
      await main(["-o", tmpA, minimalPath]);
      await main([minimalPath, "-o", tmpB]);
      assert.strictEqual(readFileSync(tmpA, "utf-8"), readFileSync(tmpB, "utf-8"));
    } finally {
      if (existsSync(tmpA)) unlinkSync(tmpA);
      if (existsSync(tmpB)) unlinkSync(tmpB);
    }
  });

  it("trailing -o with no value throws an error", async () => {
    await assert.rejects(
      () => main(["-o"]),
      (err: unknown) => {
        assert.ok(err instanceof Error);
        assert.ok(err.message.includes("-o"), "error should mention -o");
        return true;
      },
    );
  });
});
