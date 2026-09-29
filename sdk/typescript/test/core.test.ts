import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { describe, expect, test } from "vitest";
import {
  createDatabase,
  DatabaseExistsError,
  InsertReport,
  ManifestMismatchError,
  openDatabase,
  seedVocabulary,
} from "../src/index.js";
import { canonicalJson, encode, featuresHash, valueAt } from "../src/encode.js";
import { EncodeError } from "../src/errors.js";
import { loadManifest } from "../src/manifest.js";

const tmp = () => mkdtempSync(join(tmpdir(), "griddb-"));

describe("encodings", () => {
  test("int accepts integral floats and binds BigInt", () => {
    expect(encode("int", 3)).toBe(3n);
    expect(encode("int", 5.0)).toBe(5n);
    expect(() => encode("int", 1.5)).toThrow(EncodeError);
    expect(() => encode("int", true)).toThrow(EncodeError);
  });
  test("others", () => {
    expect(encode("real", 2)).toBe(2);
    expect(() => encode("real", "1")).toThrow(EncodeError);
    expect(encode("bool", false)).toBe(0);
    expect(() => encode("bool", 1)).toThrow(EncodeError);
    expect(encode("text", null)).toBe(null);
    expect(canonicalJson({ b: 1, a: "é" })).toBe('{"a":"é","b":1}');
  });
  test("valueAt", () => {
    expect(valueAt({ a: { b: 2 } }, "a.b")).toBe(2);
    expect(valueAt({ a: 1 }, "a.b")).toBe(undefined);
  });
});

test("featuresHash matches the golden vectors", () => {
  const path = new URL("../../../test/features_hash_vectors.json", import.meta.url);
  const { vectors } = JSON.parse(readFileSync(path, "utf-8"));
  for (const v of vectors) {
    if (v.integral_float) continue;
    expect(featuresHash(v.features)).toBe(v.hash);
  }
  expect(() => featuresHash({ a: null })).toThrow(EncodeError);
});

test("featuresHash hashes a number past the safe integer range as Float", () => {
  // Expected hashes are Python's for the float values 2^53 and the largest f64.
  expect(featuresHash({ a: 2 ** 53 })).toBe("5998b9a1162f4b62e52b9fdb9f2740db7fb931f15a9bc0c3535baa02d6e7f896");
  expect(featuresHash({ a: 1.7976931348623157e308 })).toBe(
    "fb91c0084cd85f09df0b507bac0a4e7c748f5aca8aa305e846727676bdd3991e",
  );
  expect(featuresHash({ a: 2 ** 53 - 1 })).toBe("40b1547e51fc12634be9bd6dd98f3d4ce5ec3b0ae1dd61d524ee2225dd91cae8");
});

test("report serializes with sorted keys", () => {
  const r = new InsertReport();
  r.addInserted("b");
  r.addInserted("a", 2);
  r.addSkipped("a", "x");
  expect(JSON.stringify(r)).toBe(
    '{"inserted":{"a":2,"b":1},"skipped_fields":{"a":{"x":1}},"unsupported":{}}',
  );
});

test("manifest loads", () => {
  expect(loadManifest().components.ThermalStandard.knownFields.has("bus")).toBe(true);
});

test("createDatabase seeds vocabulary and refuses existing paths", () => {
  const path = join(tmp(), "a.sqlite");
  const db = createDatabase(path);
  const n = loadManifest().vocabulary.entity_types.length;
  const count = () => (db.prepare("SELECT count(*) AS n FROM entity_types").get() as { n: number }).n;
  expect(count()).toBe(n);
  seedVocabulary(db);
  expect(count()).toBe(n);
  db.close();
  expect(() => createDatabase(path)).toThrow(DatabaseExistsError);
  const existing = join(tmp(), "b.sqlite");
  writeFileSync(existing, "");
  expect(() => createDatabase(existing)).toThrow(DatabaseExistsError);
});

test("openDatabase checks user_version and enables foreign keys", () => {
  const path = join(tmp(), "a.sqlite");
  createDatabase(path).close();
  const db = openDatabase(path);
  expect(db.pragma("foreign_keys", { simple: true })).toBe(1);
  expect(db.pragma("temp_store", { simple: true })).toBe(2);
  db.close();
  const raw = new Database(path);
  raw.pragma("user_version = 99");
  raw.close();
  expect(() => openDatabase(path)).toThrow(ManifestMismatchError);
});
