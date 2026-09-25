import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import {
  createDatabase,
  GapValueError,
  insertComponent,
  insertComponents,
  insertDocument,
  InsertError,
  UnsupportedComponentError,
  type Connection,
  type JsonObject,
} from "../src/index.js";

const FIXTURES = fileURLToPath(new URL("../../../test/fixtures/insert/", import.meta.url));
const CASES = ["NATURAL_UNITS", "COMPONENT_BASE"];
// globalSetup generates the gitignored fixtures on the fly; without a
// power-openapi-models checkout they stay missing and golden tests skip.
const hasGolden = CASES.every((c) => existsSync(join(FIXTURES, `case14_${c}.json`)));
const golden = (c = "NATURAL_UNITS"): JsonObject =>
  JSON.parse(readFileSync(join(FIXTURES, `case14_${c}.json`), "utf-8"));
const firstOf = (doc: JsonObject, t: string): JsonObject =>
  structuredClone((doc.components as Record<string, JsonObject[]>)[t][0]);
const loneBus = (doc: JsonObject): JsonObject => {
  const bus = firstOf(doc, "ACBus");
  delete bus.area;
  return bus;
};
const fresh = (): Connection => createDatabase(join(mkdtempSync(join(tmpdir(), "g-")), "t.sqlite"));
const count = (db: Connection, table: string): number =>
  (db.prepare(`SELECT count(*) AS n FROM ${table}`).get() as { n: number }).n;

test.skipIf(!hasGolden).each(CASES)("golden %s matches the expected report and row counts", (c) => {
  const db = fresh();
  const report = insertDocument(db, golden(c));
  const expected = JSON.parse(readFileSync(join(FIXTURES, `case14_${c}.report.json`), "utf-8"));
  expect(JSON.parse(JSON.stringify(report))).toEqual(expected);
  const dump = JSON.parse(readFileSync(join(FIXTURES, `case14_${c}.dump.json`), "utf-8"));
  for (const [table, content] of Object.entries<any>(dump)) {
    expect(count(db, table)).toBe(content.rows.length);
  }
});

test.skipIf(!hasGolden)("strict gap rolls back", () => {
  const db = fresh();
  expect(() => insertComponent(db, "ACBus", loneBus(golden()), { strict: true })).toThrow(GapValueError);
  expect(count(db, "entities")).toBe(0);
});

test("unsupported type", () => {
  const db = fresh();
  expect(insertComponents(db, "TransmissionInterface", [{ id: 1 }]).unsupported).toEqual({ TransmissionInterface: 1 });
  expect(() => insertComponents(db, "TransmissionInterface", [{ id: 1 }], { strict: true })).toThrow(
    UnsupportedComponentError,
  );
});

// Review Focus 1
test.skipIf(!hasGolden)("duplicate id across types rolls back the document", () => {
  const db = fresh();
  const doc = golden();
  const bus = loneBus(doc);
  const area = { ...firstOf(doc, "Area"), id: bus.id };
  expect(() => insertDocument(db, { components: { ACBus: [bus], Area: [area] } })).toThrow(/ACBus id=/);
  expect(count(db, "entities")).toBe(0);
});

// Review Focus 2
test.skipIf(!hasGolden)("dangling bus reference rolls back the document", () => {
  const db = fresh();
  const thermal = { ...firstOf(golden(), "ThermalStandard"), bus: 999999 };
  expect(() => insertDocument(db, { components: { ThermalStandard: [thermal] } })).toThrow(
    /ThermalStandard id=.*FOREIGN KEY/,
  );
  expect(count(db, "entities")).toBe(0);
});

// Review Focus 3
test.skipIf(!hasGolden)("integral float ids are integers", () => {
  const db = fresh();
  const bus = { ...loneBus(golden()), id: 5.0 };
  insertComponent(db, "ACBus", bus);
  expect(db.prepare("SELECT typeof(id) AS t, id FROM entities").get()).toEqual({ t: "integer", id: 5 });
  expect(() => insertComponent(db, "Arc", { id: 6, from_id: 1.5, to_id: 5 })).toThrow(/expected an integer/);
});

// Review Focus 4
test.skipIf(!hasGolden)("reinserting a document fails and keeps the first copy", () => {
  const db = fresh();
  insertDocument(db, golden());
  const before = count(db, "entities");
  expect(() => insertDocument(db, golden())).toThrow(InsertError);
  expect(count(db, "entities")).toBe(before);
});

// Review Focus 5
test("misspelled field", () => {
  const db = fresh();
  expect(insertComponent(db, "Area", { id: 900, name: "a", numbr: 3 }).skipped_fields).toEqual({
    Area: { numbr: 1 },
  });
  expect(() => insertComponent(db, "Area", { id: 901, name: "b", numbr: 3 }, { strict: true })).toThrow(
    /numbr/,
  );
  expect(insertComponent(db, "Area", { id: 902, name: "c", numbr: null }).skipped_fields).toEqual({});
});
