import type {
  IR,
  IRType,
  IRInterface,
  IRDictionary,
  IREnum,
  IRCallback,
  IRNamespace,
  IRArg,
  IRLiteral,
} from "./ir.ts";

function mapType(t: IRType, inReturn: boolean, ifaceNames: Set<string>): string {
  switch (t.kind) {
    case "boolean":
      return "boolean";
    case "dom_string":
    case "byte_string":
    case "usv_string":
      return "string";
    case "byte":
    case "octet":
    case "short":
    case "unsigned_short":
    case "long":
    case "unsigned_long":
    case "float":
    case "double":
    case "unrestricted_float":
    case "unrestricted_double":
      return "number";
    case "long_long":
    case "unsigned_long_long":
    case "bigint":
      return "bigint";
    case "undefined":
      return inReturn ? "void" : "undefined";
    case "any":
    case "object":
    case "symbol":
      return "any";
    case "sequence":
      return `${mapType(t.element, false, ifaceNames)}[]`;
    case "frozen_array":
    case "observable_array":
      return `${mapType(t.inner, false, ifaceNames)}[]`;
    case "promise":
      return `Promise<${mapType(t.inner, false, ifaceNames)}>`;
    case "nullable":
      return `${mapType(t.inner, false, ifaceNames)} | null`;
    case "union":
      return t.members.map((m) => mapType(m, false, ifaceNames)).join(" | ");
    case "record":
      return `Record<${mapType(t.key, false, ifaceNames)}, ${mapType(t.value, false, ifaceNames)}>`;
    case "buffer":
      return "ArrayBuffer";
    case "named":
      return t.name;
  }
}

function literalToTs(lit: IRLiteral): string {
  switch (lit.kind) {
    case "boolean":
      return lit.value ? "true" : "false";
    case "integer":
      return String(lit.value);
    case "decimal":
      return String(lit.value);
    case "string":
      return JSON.stringify(lit.value);
    case "null":
      return "null";
    case "undefined":
      return "undefined";
    case "empty_sequence":
      return "[]";
    case "empty_dict":
      return "{}";
    case "positive_infinity":
      return "Infinity";
    case "negative_infinity":
      return "-Infinity";
    case "nan":
      return "NaN";
  }
}

function typeNeedsMarshal(t: IRType, ifaceNames: Set<string>): boolean {
  switch (t.kind) {
    case "named":
      return ifaceNames.has(t.name);
    case "sequence":
      return typeNeedsMarshal(t.element, ifaceNames);
    case "frozen_array":
    case "observable_array":
    case "nullable":
      return typeNeedsMarshal(t.inner, ifaceNames);
    case "record":
      return typeNeedsMarshal(t.value, ifaceNames);
    case "union":
      return t.members.some((m) => typeNeedsMarshal(m, ifaceNames));
    default:
      return false;
  }
}

// union marshaling is best-effort
function marshalToJs(expr: string, t: IRType, ifaceNames: Set<string>): string {
  if (!typeNeedsMarshal(t, ifaceNames)) return expr;
  switch (t.kind) {
    case "named":
      return `(${expr} as any).obj`;
    case "sequence":
      return `${expr}.map((__x) => ${marshalToJs("__x", t.element, ifaceNames)})`;
    case "frozen_array":
    case "observable_array":
      return `${expr}.map((__x) => ${marshalToJs("__x", t.inner, ifaceNames)})`;
    case "nullable":
      return `(${expr} === null ? null : ${marshalToJs(expr, t.inner, ifaceNames)})`;
    case "record":
      return `Object.fromEntries(Object.entries(${expr}).map(([__k, __v]) => [__k, ${marshalToJs("__v", t.value, ifaceNames)}]))`;
    default:
      return expr;
  }
}

// union marshaling is best-effort
function marshalFromJs(expr: string, t: IRType, ifaceNames: Set<string>, hostExpr: string): string {
  if (!typeNeedsMarshal(t, ifaceNames)) return expr;
  switch (t.kind) {
    case "named":
      return `new ${t.name}(${hostExpr}.intern(${expr}), ${hostExpr})`;
    case "sequence":
      return `${expr}.map((__x: any) => ${marshalFromJs("__x", t.element, ifaceNames, hostExpr)})`;
    case "frozen_array":
    case "observable_array":
      return `${expr}.map((__x: any) => ${marshalFromJs("__x", t.inner, ifaceNames, hostExpr)})`;
    case "nullable":
      return `(${expr} === null ? null : ${marshalFromJs(expr, t.inner, ifaceNames, hostExpr)})`;
    case "record":
      return `Object.fromEntries(Object.entries(${expr}).map(([__k, __v]: [string, any]) => [__k, ${marshalFromJs("__v", t.value, ifaceNames, hostExpr)}]))`;
    default:
      return expr;
  }
}

function marshalArg(arg: IRArg, ifaceNames: Set<string>): string {
  return marshalToJs(arg.name, arg.type, ifaceNames);
}

function emitInterface(iface: IRInterface, ifaceNames: Set<string>): string {
  const lines: string[] = [];
  lines.push(`export class ${iface.name} {`);
  lines.push(`  constructor(readonly handle: number, private host: Host) {}`);
  lines.push(`  private get obj(): any { return this.host.value(this.handle); }`);

  for (const ctor of iface.constructors) {
    const params = ctor.args
      .map((a) => `${a.name}: ${mapType(a.type, false, ifaceNames)}`)
      .join(", ");
    const marshalledArgs = ctor.args.map((a) => marshalArg(a, ifaceNames)).join(", ");
    const ctorParams = params ? `, ${params}` : "";
    lines.push(
      `  static create(host: Host${ctorParams}): ${iface.name} { return new ${iface.name}(host.intern(new (globalThis as any)["${iface.name}"](${marshalledArgs})), host); }`
    );
  }

  for (const c of iface.constants) {
    lines.push(
      `  static readonly ${c.name}: ${mapType(c.type, false, ifaceNames)} = ${literalToTs(c.value)};`
    );
  }

  for (const attr of iface.attributes) {
    const retType = mapType(attr.type, false, ifaceNames);
    const attrNeedsMarshal = typeNeedsMarshal(attr.type, ifaceNames);
    if (attr.static) {
      const staticExpr = `(globalThis as any)["${iface.name}"].${attr.name}`;
      if (attrNeedsMarshal) {
        lines.push(
          `  static ${attr.name}(host: Host): ${retType} { return ${marshalFromJs(staticExpr, attr.type, ifaceNames, "host")}; }`
        );
      } else {
        lines.push(
          `  static ${attr.name}(host: Host): ${retType} { return ${staticExpr}; }`
        );
      }
    } else {
      const propExpr = `this.obj.${attr.name}`;
      if (attrNeedsMarshal) {
        lines.push(
          `  get ${attr.name}(): ${retType} { return ${marshalFromJs(propExpr, attr.type, ifaceNames, "this.host")}; }`
        );
      } else {
        lines.push(`  get ${attr.name}(): ${retType} { return ${propExpr}; }`);
      }

      if (!attr.readonly) {
        if (attrNeedsMarshal) {
          lines.push(
            `  set ${attr.name}(value: ${retType}) { this.obj.${attr.name} = ${marshalToJs("value", attr.type, ifaceNames)}; }`
          );
        } else {
          lines.push(
            `  set ${attr.name}(value: ${retType}) { this.obj.${attr.name} = value; }`
          );
        }
      }
    }
  }

  for (const op of iface.operations) {
    if (op.name === null) continue;
    const params = op.args
      .map((a) => `${a.name}: ${mapType(a.type, false, ifaceNames)}`)
      .join(", ");
    const marshalledArgs = op.args.map((a) => marshalArg(a, ifaceNames)).join(", ");
    const retTypeStr = mapType(op.returnType, true, ifaceNames);
    const isVoid = op.returnType.kind === "undefined";
    const retNeedsMarshal = typeNeedsMarshal(op.returnType, ifaceNames);
    const retNeedsTemp = op.returnType.kind === "nullable" && retNeedsMarshal;

    if (op.static) {
      const hostParam = `host: Host${params ? `, ${params}` : ""}`;
      const rawStaticExpr = `(globalThis as any)["${iface.name}"].${op.name}(${marshalledArgs})`;
      if (isVoid) {
        lines.push(
          `  static ${op.name}(${hostParam}): ${retTypeStr} { (globalThis as any)["${iface.name}"].${op.name}(${marshalledArgs}); }`
        );
      } else if (retNeedsTemp) {
        lines.push(
          `  static ${op.name}(${hostParam}): ${retTypeStr} { const __r = ${rawStaticExpr}; return ${marshalFromJs("__r", op.returnType, ifaceNames, "host")}; }`
        );
      } else if (retNeedsMarshal) {
        lines.push(
          `  static ${op.name}(${hostParam}): ${retTypeStr} { return ${marshalFromJs(rawStaticExpr, op.returnType, ifaceNames, "host")}; }`
        );
      } else {
        lines.push(
          `  static ${op.name}(${hostParam}): ${retTypeStr} { return ${rawStaticExpr}; }`
        );
      }
    } else {
      const rawExpr = `this.obj.${op.name}(${marshalledArgs})`;
      if (isVoid) {
        lines.push(
          `  ${op.name}(${params}): ${retTypeStr} { this.obj.${op.name}(${marshalledArgs}); }`
        );
      } else if (retNeedsTemp) {
        lines.push(
          `  ${op.name}(${params}): ${retTypeStr} { const __r = ${rawExpr}; return ${marshalFromJs("__r", op.returnType, ifaceNames, "this.host")}; }`
        );
      } else if (retNeedsMarshal) {
        lines.push(
          `  ${op.name}(${params}): ${retTypeStr} { return ${marshalFromJs(rawExpr, op.returnType, ifaceNames, "this.host")}; }`
        );
      } else {
        lines.push(
          `  ${op.name}(${params}): ${retTypeStr} { return ${rawExpr}; }`
        );
      }
    }
  }

  lines.push(`}`);
  return lines.join("\n");
}

function emitDictionary(dict: IRDictionary, ifaceNames: Set<string>): string {
  const lines: string[] = [];
  lines.push(`export interface ${dict.name} {`);
  for (const m of dict.members) {
    const optional = m.required ? "" : "?";
    lines.push(`  ${m.name}${optional}: ${mapType(m.type, false, ifaceNames)};`);
  }
  lines.push(`}`);
  return lines.join("\n");
}

function emitEnum(e: IREnum): string {
  const values = e.values.map((v) => JSON.stringify(v)).join(" | ");
  return `export type ${e.name} = ${values};`;
}

function emitCallback(cb: IRCallback, ifaceNames: Set<string>): string {
  const params = cb.args
    .map((a) => `${a.name}: ${mapType(a.type, false, ifaceNames)}`)
    .join(", ");
  const retType = mapType(cb.returnType, true, ifaceNames);
  return `export type ${cb.name} = (${params}) => ${retType};`;
}

function emitNamespace(ns: IRNamespace, ifaceNames: Set<string>): string {
  const lines: string[] = [];
  lines.push(`export const ${ns.name}: {`);
  for (const c of ns.constants) {
    lines.push(`  readonly ${c.name}: ${mapType(c.type, false, ifaceNames)};`);
  }
  for (const attr of ns.attributes) {
    lines.push(`  ${attr.name}: ${mapType(attr.type, false, ifaceNames)};`);
  }
  for (const op of ns.operations) {
    if (op.name === null) continue;
    const params = op.args
      .map((a) => `${a.name}: ${mapType(a.type, false, ifaceNames)}`)
      .join(", ");
    lines.push(`  ${op.name}(${params}): ${mapType(op.returnType, true, ifaceNames)};`);
  }
  lines.push(`} = (globalThis as any)["${ns.name}"];`);
  return lines.join("\n");
}

export function generate(ir: IR): string {
  const ifaceNames = new Set(
    ir.interfaces.filter((i) => !i.mixin).map((i) => i.name)
  );

  type Def = { name: string; text: string };
  const defs: Def[] = [];

  for (const iface of ir.interfaces) {
    if (iface.mixin) continue;
    defs.push({ name: iface.name, text: emitInterface(iface, ifaceNames) });
  }
  for (const dict of ir.dictionaries) {
    defs.push({ name: dict.name, text: emitDictionary(dict, ifaceNames) });
  }
  for (const e of ir.enums) {
    defs.push({ name: e.name, text: emitEnum(e) });
  }
  for (const cb of ir.callbacks) {
    defs.push({ name: cb.name, text: emitCallback(cb, ifaceNames) });
  }
  for (const ns of ir.namespaces) {
    defs.push({ name: ns.name, text: emitNamespace(ns, ifaceNames) });
  }

  defs.sort((a, b) => a.name.localeCompare(b.name));

  const header = `import type { Host } from "@midstall/webidl-runtime";\n`;
  const body = defs.map((d) => d.text).join("\n\n");
  return `${header}\n${body}\n`;
}
