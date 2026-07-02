import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";
import { parseIR } from "./ir.ts";
import { generate } from "./emit-ts.ts";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "fixtures");
const goldenDir = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "golden");

describe("generate", () => {
  it("byte-compares generate(minimal.json) to test/golden/minimal.ts", () => {
    const json = readFileSync(join(fixturesDir, "minimal.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    const golden = readFileSync(join(goldenDir, "minimal.ts"), "utf-8");
    assert.strictEqual(result, golden);
  });

  it("generate(ir_types.json) contains union, Record, and array types", () => {
    const json = readFileSync(join(fixturesDir, "ir_types.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(result.includes(" | "), "should contain union type");
    assert.ok(result.includes("Record<"), "should contain Record type");
    assert.ok(result.includes("[]"), "should contain array type");
  });

  it("byte-compares generate(refs.json) to test/golden/refs.ts", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    const golden = readFileSync(join(goldenDir, "refs.ts"), "utf-8");
    assert.strictEqual(result, golden);
  });

  it("generate(refs.json) skips mixin Ignored", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(!result.includes("Ignored"), "mixin Ignored must be absent from output");
  });

  it("generate(refs.json) wraps interface return with host.intern", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(result.includes("this.host.intern"), "interface return must use host.intern");
  });

  it("generate(refs.json) unwraps interface arg with .obj", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(result.includes("(child as any).obj"), "interface arg must use .obj unwrap");
  });

  it("generate(refs.json) null-guards nullable interface return", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(result.includes("=== null ? null : new Node"), "nullable must null-guard with new Node");
  });

  it("generate(refs.json) emits static fromDocument returning Node", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(result.includes("static fromDocument(host: Host): Node"), "static op must appear");
  });

  it("generate(refs.json) wraps sequence<Node> return with .map and host.intern", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(
      result.includes(".map((__x: any) => new Node(this.host.intern(__x), this.host))"),
      "sequence<Node> return must map-wrap each element via host.intern"
    );
  });

  it("generate(refs.json) unwraps sequence<Node> arg inside .map with .obj", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(
      result.includes(".map((__x) => (__x as any).obj)"),
      "sequence<Node> arg must map-unwrap each element via .obj"
    );
  });

  it("generate(refs.json) null-guards nullable op return with temp var", () => {
    const json = readFileSync(join(fixturesDir, "refs.json"), "utf-8");
    const ir = parseIR(json);
    const result = generate(ir);
    assert.ok(
      result.includes("const __r = this.obj.firstChild()"),
      "nullable op return must capture result before null-guard"
    );
  });
});
