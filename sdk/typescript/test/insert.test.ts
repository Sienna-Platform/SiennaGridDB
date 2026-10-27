import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import {
  createDatabase,
  insertComponent,
  insertComponents,
  insertDocument,
  InsertError,
  type Connection,
  type JsonObject,
} from "../src/index.js";
import { featuresHash } from "../src/encode.js";
import { pointAtSources } from "../src/time_series.js";

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
  delete bus.load_zone;
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
  const bus = { ...loneBus(golden()), angel: 0.1 };
  expect(() => insertComponent(db, "ACBus", bus, { strict: true })).toThrow(InsertError);
  expect(count(db, "entities")).toBe(0);
});

test("unsupported type", () => {
  const db = fresh();
  expect(insertComponents(db, "HybridSystem", [{ id: 1 }]).unsupported).toEqual({ HybridSystem: 1 });
  expect(() => insertComponents(db, "HybridSystem", [{ id: 1 }], { strict: true })).toThrow(
    InsertError,
  );
});

// A power_units field routed to attributes takes the unit of its own row's basis.
test.skipIf(!hasGolden).each(CASES)("attribute unit follows the row's power_units (%s)", (c) => {
  const db = fresh();
  insertDocument(db, golden(c));
  const rows = db
    .prepare(
      "SELECT l.power_units AS basis, a.unit AS unit, a.quantity_kind AS qk FROM attributes a " +
        "JOIN loads l ON l.id = a.entity_id WHERE a.name = 'constant_active_power'",
    )
    .all() as { basis: string; unit: string; qk: string }[];
  expect(rows.length).toBeGreaterThan(0);
  const expected: Record<string, string> = { COMPONENT_BASE: "pu", NATURAL_UNITS: "MW" };
  for (const r of rows) expect([r.unit, r.qk]).toEqual([expected[r.basis], "ActivePower"]);
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

const thermal = (doc: JsonObject): JsonObject => (doc.components as Record<string, JsonObject[]>).ThermalStandard[0];
const series = (owner: JsonObject, associationId: number, fields: JsonObject = {}): JsonObject => ({
  association_id: associationId,
  owner_id: owner.id,
  owner_type: "ThermalStandard",
  owner_category: "Component",
  time_series_type: "SingleTimeSeries",
  name: "max_active_power",
  features: { scenario: "base", year: 2030 },
  uri: "/arrays/a",
  element_type: "f64",
  element_shape: [],
  initial_timestamp: "2030-01-01T00:00:00",
  resolution: "PT1H",
  length: 24,
  ...fields,
});

test.skipIf(!hasGolden)("time series associations and feature sets are stored; values are reported", () => {
  const doc = golden();
  const gen = thermal(doc);
  doc.time_series_associations = [series(gen, 7), series(gen, 8, { name: "min_active_power" })];
  const db = fresh();
  const report = insertDocument(db, doc);
  expect(report.inserted.time_series_associations).toBe(2);
  expect(report.unsupported.time_series_values).toBe(2);
  const row = db.prepare("SELECT owner_id, name, features_hash FROM time_series_associations WHERE id = 7").get();
  expect(row).toEqual({
    owner_id: gen.id,
    name: "max_active_power",
    features_hash: featuresHash({ scenario: "base", year: 2030 }),
  });
  // Both rows share one feature set, stored once.
  const features = db.prepare("SELECT key, value_kind, value_int, value_str FROM feature_sets ORDER BY key").all();
  expect(features).toEqual([
    { key: "scenario", value_kind: "str", value_int: null, value_str: "base" },
    { key: "year", value_kind: "int", value_int: 2030, value_str: null },
  ]);
  delete doc.ext;
  expect(() => insertDocument(fresh(), doc, { strict: true })).toThrow(/time_series_values/);
});

test.skipIf(!hasGolden)("a mislabelled time series owner raises", () => {
  const doc = golden();
  doc.time_series_associations = [series(thermal(doc), 7, { owner_type: "RenewableDispatch" })];
  const db = fresh();
  expect(() => insertDocument(db, doc)).toThrow(/is ThermalStandard/);
  expect(count(db, "entities")).toBe(0);
});

test.skipIf(!hasGolden)("a series of an unsupported owner is reported", () => {
  const doc = golden();
  (doc.components as Record<string, JsonObject[]>).AGC = [{ id: 9001, name: "agc" }];
  doc.time_series_associations = [series({ id: 9001 }, 7, { owner_type: "AGC" }), series(thermal(doc), 8)];
  const db = fresh();
  expect(insertDocument(db, doc).unsupported.time_series_associations).toBe(1);
  expect(count(db, "time_series_associations")).toBe(1);
});

test.skipIf(!hasGolden)("an unsupported series type is reported and strict raises", () => {
  const doc = golden();
  const row = series(thermal(doc), 7, { time_series_type: "NonSequentialTimeSeries" });
  delete row.initial_timestamp;
  delete row.resolution;
  doc.time_series_associations = [row];
  delete doc.ext;
  const db = fresh();
  expect(insertDocument(db, doc).unsupported.NonSequentialTimeSeries).toBe(1);
  expect(count(db, "time_series_associations")).toBe(0);
  expect(() => insertDocument(db, doc, { strict: true })).toThrow(/timestamps_uri/);
});

test.skipIf(!hasGolden)("a plant owns series as a supplemental attribute", () => {
  const doc = golden();
  const gen = thermal(doc);
  const plant = { id: 9100, name: "plant1" };
  (doc.supplemental_attributes as JsonObject[]).push(plant);
  (doc.supplemental_attribute_associations as JsonObject[]).push({
    component_id: gen.id,
    component_type: "ThermalStandard",
    attribute_id: plant.id,
    attribute_type: "ThermalPowerPlant",
  });
  const owner = { owner_type: "ThermalPowerPlant", owner_category: "SupplementalAttribute" };
  doc.time_series_associations = [series(plant, 7, owner)];
  const db = fresh();
  insertDocument(db, doc);
  expect(count(db, "time_series_associations")).toBe(1);
});

// A golden thermal whose fuel cost is the series 7, with a DeterministicSingleTimeSeries 8
// derived from it: same array, owner, name and features, plus forecast windows.
function fuelCostSeries(doc: JsonObject): JsonObject {
  const gen = thermal(doc);
  const cost = (gen.operation_cost as JsonObject).variable_operation_cost as JsonObject;
  Object.assign(cost, { variable_cost_type: "FUEL", fuel_cost: null, fuel_cost_time_series: 8 });
  const derived = series(gen, 8, {
    time_series_type: "DeterministicSingleTimeSeries",
    name: "fuel_cost",
    horizon: "PT24H",
    interval: "PT24H",
    count: 1,
  });
  doc.time_series_associations = [series(gen, 7, { name: "fuel_cost" }), derived];
  delete doc.ext;
  return gen;
}

test.skipIf(!hasGolden)("a DeterministicSingleTimeSeries is reported and strict raises", () => {
  const doc = golden();
  fuelCostSeries(doc);
  const db = fresh();
  expect(insertDocument(db, doc).unsupported.DeterministicSingleTimeSeries).toBe(1);
  expect(db.prepare("SELECT id FROM time_series_associations").all()).toEqual([{ id: 7 }]);
  expect(() => insertDocument(fresh(), doc, { strict: true })).toThrow(/transform_single_time_series/);
});

test.skipIf(!hasGolden)("a reference to a derived series points at its source", () => {
  const doc = golden();
  const gen = fuelCostSeries(doc);
  const db = fresh();
  insertDocument(db, doc);
  const stored = db.prepare("SELECT operation_cost FROM thermal_generators WHERE id = ?").get(gen.id) as {
    operation_cost: string;
  };
  expect(stored.operation_cost).toContain('"fuel_cost_time_series":7');
  expect(db.prepare("SELECT * FROM dangling_time_series_references").all()).toEqual([]);
  // The caller's document is left as it was.
  const cost = (gen.operation_cost as JsonObject).variable_operation_cost as JsonObject;
  expect(cost.fuel_cost_time_series).toBe(8);
});

test("pointAtSources copies only what changes", () => {
  const untouched = { curve: [1, 2], association_id: 3 };
  const node = { a: untouched, b: [{ fuel_cost_time_series: 8 }], c: 8 };
  const out = pointAtSources(node, new Map([[8, 7]]));
  expect(out).toEqual({ a: untouched, b: [{ fuel_cost_time_series: 7 }], c: 8 });
  expect(out.a).toBe(untouched);
  expect(node.b[0].fuel_cost_time_series).toBe(8);
  expect(pointAtSources(untouched, new Map([[8, 7]]))).toBe(untouched);
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
    const owner = (where in comps ? comps : doc) as Record<string, unknown[]>;
    (owner[where] ??= []).push(value);
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
  const area = (id: number, name: string, extra: JsonObject): JsonObject => ({
    id, name, base_power: 100.0, power_units: "NATURAL_UNITS", ...extra,
  });
  expect(insertComponent(db, "Area", area(900, "a", { numbr: 3 })).skipped_fields).toEqual({
    Area: { numbr: 1 },
  });
  expect(() => insertComponent(db, "Area", area(901, "b", { numbr: 3 }), { strict: true })).toThrow(
    /numbr/,
  );
  expect(insertComponent(db, "Area", area(902, "c", { numbr: null })).skipped_fields).toEqual({});
});
