export type IRPrimitiveKind =
  | "long"
  | "dom_string"
  | "boolean"
  | "byte"
  | "octet"
  | "unsigned_short"
  | "unsigned_long"
  | "unsigned_long_long"
  | "short"
  | "long_long"
  | "float"
  | "double"
  | "unrestricted_float"
  | "unrestricted_double"
  | "bigint"
  | "undefined"
  | "any"
  | "object"
  | "symbol"
  | "byte_string"
  | "usv_string";

export type IRType =
  | { kind: IRPrimitiveKind }
  | { kind: "sequence"; element: IRType }
  | { kind: "record"; key: IRType; value: IRType }
  | { kind: "frozen_array" | "observable_array" | "promise" | "nullable"; inner: IRType }
  | { kind: "union"; members: IRType[] }
  | { kind: "buffer"; buffer: string }
  | { kind: "named"; name: string };

export type IRLiteral =
  | { kind: "boolean"; value: boolean }
  | { kind: "integer"; value: number }
  | { kind: "decimal"; value: number }
  | { kind: "string"; value: string }
  | { kind: "null" | "undefined" | "empty_sequence" | "empty_dict" | "positive_infinity" | "negative_infinity" | "nan" };

export interface IRConst {
  name: string;
  type: IRType;
  value: IRLiteral;
}

export interface IRAttr {
  name: string;
  type: IRType;
  readonly: boolean;
  static: boolean;
}

export interface IRArg {
  name: string;
  type: IRType;
  optional: boolean;
  variadic: boolean;
  default: IRLiteral | null;
}

export interface IROp {
  name: string | null;
  special: "getter" | "setter" | "deleter" | "legacy_caller" | null;
  static: boolean;
  returnType: IRType;
  args: IRArg[];
}

export interface IRInterface {
  name: string;
  inherits: string | null;
  mixin: boolean;
  constants: IRConst[];
  attributes: IRAttr[];
  operations: IROp[];
  constructors: { args: IRArg[] }[];
}

export interface IRDictionary {
  name: string;
  inherits: string | null;
  members: {
    name: string;
    type: IRType;
    required: boolean;
    default: IRLiteral | null;
  }[];
}

export interface IREnum {
  name: string;
  values: string[];
}

export interface IRCallback {
  name: string;
  returnType: IRType;
  args: IRArg[];
}

export interface IRNamespace {
  name: string;
  constants: IRConst[];
  attributes: IRAttr[];
  operations: IROp[];
}

export interface IR {
  version: 1;
  interfaces: IRInterface[];
  dictionaries: IRDictionary[];
  enums: IREnum[];
  callbacks: IRCallback[];
  namespaces: IRNamespace[];
}

export class IRVersionError extends Error {
  found: number;

  constructor(found: number) {
    super(`unsupported IR version: ${found}`);
    this.name = "IRVersionError";
    this.found = found;
  }
}

export function parseIR(json: string): IR {
  const raw = JSON.parse(json) as { version?: unknown };
  if (raw.version !== 1) {
    throw new IRVersionError(raw.version as number);
  }
  return raw as unknown as IR;
}
