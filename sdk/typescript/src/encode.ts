import { createHash } from "node:crypto";
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

function u64(n: number | bigint): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n));
  return b;
}

function featureBytes(value: unknown): Buffer {
  if (typeof value === "boolean") return Buffer.from([0x62, value ? 1 : 0]);
  if (typeof value === "number" && Number.isSafeInteger(value)) {
    const b = Buffer.alloc(9, 0x69);
    b.writeBigInt64LE(BigInt(value), 1);
    return b;
  }
  if (typeof value === "number") {
    // Any NaN hashes as Rust's f64::NAN bit pattern.
    const b = Buffer.alloc(9, 0x66);
    if (Number.isNaN(value)) b.writeBigUInt64LE(0x7ff8000000000000n, 1);
    else b.writeDoubleLE(value, 1);
    return b;
  }
  if (typeof value === "string") {
    const raw = Buffer.from(value, "utf8");
    return Buffer.concat([Buffer.from("s"), u64(raw.length), raw]);
  }
  throw new EncodeError(`expected an int, float, bool or string feature, got ${JSON.stringify(value)}`);
}

/**
 * infrastore's features_hash (crates/infrastore-core/src/hash.rs), lowercase hex. Keys go in
 * UTF-8 byte order. JSON.parse cannot tell 1.0 from 1, so a safe integer (|x| < 2^53) hashes
 * as Int and every other number as Float.
 */
export function featuresHash(features: JsonObject): string {
  const keys = Object.keys(features).map((k) => [k, Buffer.from(k, "utf8")] as const);
  keys.sort((a, b) => Buffer.compare(a[1], b[1]));
  const hash = createHash("sha256").update("features\0").update(u64(keys.length));
  for (const [key, raw] of keys) hash.update(u64(raw.length)).update(raw).update(featureBytes(features[key]));
  return hash.digest("hex");
}
