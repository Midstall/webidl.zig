import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";
import { parseIR, IRVersionError } from "./ir.ts";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "..", "test", "fixtures");

describe("parseIR", () => {
  it("parses minimal.json correctly", () => {
    const json = readFileSync(join(fixturesDir, "minimal.json"), "utf-8");
    const ir = parseIR(json);

    assert.strictEqual(ir.version, 1);
    assert.strictEqual(ir.interfaces.length, 1);

    const iface = ir.interfaces[0];
    assert.strictEqual(iface.name, "EventTarget");

    const urlAttr = iface.attributes.find((a) => a.name === "url");
    assert.ok(urlAttr, "url attribute not found");
    assert.strictEqual(urlAttr.type.kind, "dom_string");

    const addListener = iface.operations.find((op) => op.name === "addEventListener");
    assert.ok(addListener, "addEventListener operation not found");

    assert.strictEqual(ir.dictionaries.length, 1);
    const dict = ir.dictionaries[0];
    assert.strictEqual(dict.name, "RequestInit");

    const methodMember = dict.members.find((m) => m.name === "method");
    assert.ok(methodMember, "method member not found");
    assert.strictEqual(methodMember.required, true);
    assert.strictEqual(methodMember.default, null);

    const timeoutMember = dict.members.find((m) => m.name === "timeout");
    assert.ok(timeoutMember, "timeout member not found");
    assert.strictEqual(timeoutMember.required, false);
    assert.ok(timeoutMember.default !== null, "timeout default should not be null");

    assert.strictEqual(ir.enums.length, 1);
    assert.strictEqual(ir.enums[0].name, "ReadyState");
  });

  it("parses ir_types.json and exercises compound types", () => {
    const json = readFileSync(join(fixturesDir, "ir_types.json"), "utf-8");
    const ir = parseIR(json);

    assert.strictEqual(ir.version, 1);

    const iface = ir.interfaces.find((i) => i.name === "TypeCoverage");
    assert.ok(iface, "TypeCoverage interface not found");

    const getMapping = iface.operations.find((op) => op.name === "getMapping");
    assert.ok(getMapping, "getMapping operation not found");
    assert.strictEqual(getMapping.returnType.kind, "record");

    const takeUnion = iface.operations.find((op) => op.name === "takeUnion");
    assert.ok(takeUnion, "takeUnion operation not found");
    const unionArg = takeUnion.args[0];
    assert.strictEqual(unionArg.type.kind, "union");
    if (unionArg.type.kind === "union") {
      assert.ok(unionArg.type.members.length >= 2, "union should have at least 2 members");
    }

    const handlerAttr = iface.attributes.find((a) => a.name === "handler");
    assert.ok(handlerAttr, "handler attribute not found");
    assert.strictEqual(handlerAttr.type.kind, "named");
    if (handlerAttr.type.kind === "named") {
      assert.strictEqual(handlerAttr.type.name, "OnProgress");
    }

    const callback = ir.callbacks.find((c) => c.name === "OnProgress");
    assert.ok(callback, "OnProgress callback not found");
    assert.strictEqual(callback.returnType.kind, "undefined");
    assert.ok(callback.args.length >= 1);
  });

  it("throws IRVersionError with correct .found for version 2", () => {
    assert.throws(
      () => parseIR('{"version":2}'),
      (err: unknown) => {
        assert.ok(err instanceof IRVersionError, "should be IRVersionError");
        assert.strictEqual(err.found, 2);
        return true;
      }
    );
  });
});
