import { EncodeError, type JsonObject } from "./errors.js";

export type Encoding = "int" | "real" | "text" | "bool" | "json";
export type SqlValue = bigint | number | string | null;

export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortDeep(value));
}

function sortDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortDeep);
  if (value !== null && typeof value === "object") {
    const o = value as JsonObject;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, sortDeep(o[k])]));
  }
  return value;
}

// Integers bind as BigInt: better-sqlite3 binds every JS number as a double.
const ENCODERS: Record<Encoding, (v: unknown) => SqlValue> = {
  int: (v) => {
    if (typeof v !== "number" || !Number.isInteger(v)) {
      throw new EncodeError(`expected an integer, got ${JSON.stringify(v)}`);
    }
    return BigInt(v);
  },
  real: (v) => {
    if (typeof v !== "number") throw new EncodeError(`expected a number, got ${JSON.stringify(v)}`);
    return v;
  },
  text: (v) => {
    if (typeof v !== "string") throw new EncodeError(`expected a string, got ${JSON.stringify(v)}`);
    return v;
  },
  bool: (v) => {
    if (typeof v !== "boolean") {
      throw new EncodeError(`expected a boolean, got ${JSON.stringify(v)}`);
    }
    return v ? 1 : 0;
  },
  json: (v) => canonicalJson(v),
};

export function encode(encoding: Encoding, value: unknown): SqlValue {
  if (isNull(value)) return null;
  return ENCODERS[encoding](value);
}

/** The value at a dotted path, or undefined when any segment is absent. */
export function valueAt(obj: JsonObject, path: string): unknown {
  let node: unknown = obj;
  for (const segment of path.split(".")) {
    if (node === null || typeof node !== "object" || !(segment in (node as JsonObject))) {
      return undefined;
    }
    node = (node as JsonObject)[segment];
  }
  return node;
}

export function isNull(value: unknown): boolean {
  return value === null || value === undefined;
}
