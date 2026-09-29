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
  expect(insertComponents(db, "AGC", [{ id: 1 }]).unsupported).toEqual({ AGC: 1 });
  expect(() => insertComponents(db, "AGC", [{ id: 1 }], { strict: true })).toThrow(UnsupportedComponentError);
});

// AGC has no table, so an association row naming one, on either side, is counted
// under its section instead of failing the document.
test.skipIf(!hasGolden)("rows naming an unsupported component are reported, not written", () => {
  const db = fresh();
  const doc = golden();
  const thermal = firstOf(doc, "ThermalStandard").id as number;
  const [agc, plant] = [9001, 9002];
  (doc.components as Record<string, JsonObject[]>).AGC = [{ id: agc, name: "agc" }];
  (doc.supplemental_attributes as JsonObject[]).push({
    id: plant,
    name: "cc1",
    configuration: "SeparateShaftCombustionSteam",
  });
  for (const [c, t] of [
    [thermal, "ThermalStandard"],
    [agc, "AGC"],
  ]) {
    (doc.supplemental_attribute_associations as JsonObject[]).push({
      component_id: c,
      component_type: t,
      attribute_id: plant,
      attribute_type: "CombinedCycleBlock",
    });
  }
  doc.combined_cycle_associations = [thermal, agc].map((e, i) => ({
    plant_id: plant,
    entity_id: e,
    role: "CT",
    hrsg_index: i + 1,
  }));
  const report = insertDocument(db, doc);
  expect(report.unsupported.AGC).toBe(1);
  expect(report.unsupported.supplemental_attribute_associations).toBe(1);
  expect(report.unsupported.combined_cycle_associations).toBe(1);
  expect(count(db, "combined_cycle_associations")).toBe(1);
});

// The skip reads ids by the int encoder's rule, so the three SDKs agree on odd ids.
test.skipIf(!hasGolden).each([
  [9001, 9001.0, true],
  ["9001", "9001", false],
  [1, true, false],
  [1e20, 1e20, false],
  [9001, [9001], false],
  [9001, { id: 9001 }, false],
])("unsupported reference id %j -> %j", (agcId, ref, skipped) => {
  const db = fresh();
  const doc = golden();
  (doc.components as Record<string, JsonObject[]>).AGC = [{ id: agcId, name: "agc" }];
  const rows = doc.supplemental_attribute_associations as JsonObject[];
  rows.push({ ...rows[0], component_id: ref, component_type: "AGC" });
  if (skipped) {
    expect(insertDocument(db, doc).unsupported.supplemental_attribute_associations).toBe(1);
  } else {
    expect(() => insertDocument(db, doc)).toThrow(InsertError);
    expect(() => insertDocument(db, doc)).toThrow(/expected an integer/);
  }
});

test.skipIf(!hasGolden)("non-object entries of an unsupported type are counted", () => {
  const doc = golden();
  (doc.components as Record<string, unknown[]>).AGC = [null, 5, [1]];
  expect(insertDocument(fresh(), doc).unsupported.AGC).toBe(3);
});

const ENTRY_LISTS = [
  "ThermalStandard",
  "supplemental_attributes",
  "supplemental_attribute_associations",
  "plant_associations",
  "combined_cycle_associations",
  "trading_hub_associations",
  "service_associations",
];

test.skipIf(!hasGolden).each(ENTRY_LISTS.flatMap((where) => [null, 5, [1]].map((v) => [where, v])))(
  "non-object entry in %s (%j) raises InsertError",
  (where, value) => {
    const db = fresh();
    const doc = golden();
    const comps = doc.components as Record<string, unknown[]>;
    ((where in comps ? comps : doc) as Record<string, unknown[]>)[where].push(value);
    expect(() => insertDocument(db, doc)).toThrow(InsertError);
    expect(() => insertDocument(db, doc)).toThrow(/not an object/);
    expect(count(db, "entities")).toBe(0);
  },
);

// Review Focus 1
test.skipIf(!hasGolden)("duplicate id across types rolls back the document", () => {
  const db = fresh();
  const doc = golden();
  const bus = loneBus(doc);
  const area = { ...firstOf(doc, "Area"), id: bus.id };
  expect(() => insertDocument(db, { components: { ACBus: [bus], Area: [area] } })).toThrow(/ACBus id=/);
  expect(count(db, "entities")).toBe(0);
});

const SERVICE_TYPES = ["OnlineReserve", "OfflineReserve", "GroupReserve", "TransmissionInterface"];

// The golden document plus an online and an offline reserve on a generator, a group
// over both, and an interface on a line, with their memberships.
function withServices(doc: JsonObject): JsonObject {
  const comps = doc.components as Record<string, JsonObject[]>;
  const ids = [...Object.values(comps).flat(), ...(doc.supplemental_attributes as JsonObject[])].map(
    (o) => o.id as number,
  );
  const top = Math.max(...ids);
  const [online, offline, group, iface] = [top + 1, top + 2, top + 3, top + 4];
  const thermal = comps.ThermalStandard[0].id as number;
  const line = comps.Line[0];
  comps.OnlineReserve = [
    { id: online, name: "online_up", available: true, time_frame: 5.0, requirement: 10.0, reserve_direction: "UP" },
  ];
  comps.OfflineReserve = [{ id: offline, name: "offline_up", available: true, time_frame: 30.0 }];
  comps.GroupReserve = [{ id: group, name: "group_up", available: true, requirement: 0.0, reserve_direction: "UP" }];
  comps.TransmissionInterface = [
    {
      id: iface,
      name: "IFACE",
      available: true,
      active_power_flow_limits: { min: -100.0, max: 100.0 },
      violation_penalty: 1e5,
      direction_mapping: { [line.name as string]: -1 },
      base_power: 100.0,
      power_units: "NATURAL_UNITS",
    },
  ];
  const pairs = [
    [online, thermal],
    [offline, thermal],
    [group, online],
    [group, offline],
    [iface, line.id as number],
  ];
  doc.service_associations = pairs.map(([s, e]) => ({ service_id: s, entity_id: e }));
  return doc;
}

test.skipIf(!hasGolden)("services and memberships are stored", () => {
  const db = fresh();
  const doc = withServices(golden());
  const report = insertDocument(db, doc);
  for (const t of SERVICE_TYPES) {
    expect(report.inserted[t]).toBe(1);
    expect(report.skipped_fields[t]).toBeUndefined();
  }
  expect(report.inserted.service_associations).toBe(5);
  expect(Object.keys(report.unsupported)).toEqual(["ext"]);
  const line = firstOf(doc, "Line").id;
  expect(db.prepare("SELECT branch_id, direction FROM interface_branch_directions").all()).toEqual([
    { branch_id: line, direction: -1 },
  ]);
});

// AGC has no table, so its membership rows are counted, not inserted.
test.skipIf(!hasGolden)("membership of an unsupported service is reported, not written", () => {
  const db = fresh();
  const doc = withServices(golden());
  const online = firstOf(doc, "OnlineReserve").id as number;
  (doc.components as Record<string, JsonObject[]>).AGC = [{ id: online + 10, name: "agc" }];
  (doc.service_associations as JsonObject[]).push({ service_id: online + 10, entity_id: online });
  const report = insertDocument(db, doc);
  expect(report.unsupported.AGC).toBe(1);
  expect(report.unsupported.service_associations).toBe(1);
  expect(report.inserted.service_associations).toBe(5);
  expect(count(db, "service_associations")).toBe(5);
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
