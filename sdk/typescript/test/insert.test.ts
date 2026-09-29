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
import { resolveUnit } from "../src/insert.js";

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

test.skipIf(!hasGolden)("strict unknown field rolls back", () => {
  const db = fresh();
  const bus = { ...loneBus(golden()), numbr: 3 };
  expect(() => insertComponent(db, "ACBus", bus, { strict: true })).toThrow(GapValueError);
  expect(count(db, "entities")).toBe(0);
});

const attributes = (db: Connection, id: unknown): Record<string, [unknown, unknown, unknown]> => {
  const rows = db
    .prepare("SELECT name, json(value) AS value, unit, quantity_kind FROM attributes WHERE entity_id = ?")
    .all(id) as { name: string; value: string; unit: unknown; quantity_kind: unknown }[];
  return Object.fromEntries(rows.map((r) => [r.name, [JSON.parse(r.value), r.unit, r.quantity_kind]]));
};

test.skipIf(!hasGolden)("bus fields round-trip through attributes", () => {
  const db = fresh();
  const bus = loneBus(golden());
  expect(insertComponent(db, "ACBus", bus, { strict: true }).skipped_fields).toEqual({});
  const stored = attributes(db, bus.id);
  expect(stored.number).toEqual([bus.number, null, null]);
  expect(stored.load_zone).toEqual([bus.load_zone, null, null]);
  expect(stored.available).toEqual([bus.available, null, null]);
  expect(stored.bustype).toEqual([bus.bustype, null, null]);
  expect(stored.angle).toEqual([bus.angle, "rad", "Angle"]);
  expect(stored.magnitude).toEqual([bus.magnitude, "pu", "Voltage"]);
  expect(stored.voltage_limits).toEqual([bus.voltage_limits, "pu", "Voltage"]);
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

test("attribute unit follows the discriminator", () => {
  const spec = {
    discriminator: "power_units",
    arms: {
      NATURAL_UNITS: { unit: "MW", quantity_kind: "ActivePower" },
      COMPONENT_BASE: { unit: "pu", quantity_kind: "ActivePower" },
    },
  };
  expect(resolveUnit(spec, { power_units: "COMPONENT_BASE" })?.unit).toBe("pu");
  expect(resolveUnit(spec, { power_units: "NATURAL_UNITS" })?.unit).toBe("MW");
  expect(resolveUnit(spec, { power_units: "DEVICE_BASE" })).toBeUndefined();
  expect(resolveUnit(spec, { power_units: "constructor" })).toBeUndefined();
  expect(resolveUnit(spec, {})).toBeUndefined();
  expect(resolveUnit({ ...spec, default: "NATURAL_UNITS" }, {})?.unit).toBe("MW");
  const byFlag = { discriminator: "mode", arms: { true: { unit: "1", quantity_kind: "Fraction" } } };
  expect(resolveUnit(byFlag, { mode: true })?.unit).toBe("1");
  expect(resolveUnit({ identifier: true }, {})?.unit).toBeUndefined();
});

test("attribute unit follows nested arms", () => {
  const spec = {
    discriminator: "ac_control_from",
    default: "AC_VOLTAGE",
    arms: {
      AC_REACTIVE_POWER: { unit: "1", quantity_kind: "PowerFactor" },
      AC_VOLTAGE: {
        discriminator: "setpoint_voltage_units",
        default: "NATURAL_UNITS",
        arms: {
          NATURAL_UNITS: { unit: "kV", quantity_kind: "Voltage" },
          COMPONENT_BASE: { unit: "pu", quantity_kind: "Voltage" },
        },
      },
    },
  };
  const leaf = { ac_control_from: "AC_VOLTAGE", setpoint_voltage_units: "COMPONENT_BASE" };
  expect(resolveUnit(spec, leaf)?.unit).toBe("pu");
  expect(resolveUnit(spec, {})?.unit).toBe("kV");
  expect(resolveUnit(spec, { ac_control_from: "AC_REACTIVE_POWER" })?.unit).toBe("1");
  expect(resolveUnit(spec, { setpoint_voltage_units: "DEVICE_BASE" })).toBeUndefined();
});

const insertLccEndpoints = (db: Connection, doc: JsonObject): JsonObject => {
  const comps = doc.components as Record<string, JsonObject[]>;
  const lcc = firstOf(doc, "TwoTerminalLCCLine");
  const arc = comps.Arc.find((a) => a.id === lcc.arc) as JsonObject;
  for (const busId of [arc.from_id, arc.to_id]) {
    const bus = structuredClone(comps.ACBus.find((b) => b.id === busId) as JsonObject);
    delete bus.area;
    insertComponent(db, "ACBus", bus);
  }
  insertComponent(db, "Arc", arc);
  return lcc;
};

// A COMPONENT_BASE VSC line: its powers are per unit on its 100 MVA base.
const vsc = (arc: unknown, extra: JsonObject = {}): JsonObject => ({
  id: 9101, name: "vsc", available: true, arc, base_power: 100.0,
  power_units: "COMPONENT_BASE", active_power_flow: 1.5, rating: 2.0, ...extra,
});

test.skipIf(!hasGolden)("VSC DC power setpoints are reported, not written", () => {
  const db = fresh();
  const obj = vsc(insertLccEndpoints(db, golden()).arc, {
    dc_control_from: "DC_POWER", dc_setpoint_from: 1.5, dc_setpoint_to: 1.0,
  });
  expect(() => insertComponent(db, "TwoTerminalVSCLine", obj, { strict: true })).toThrow(/dc_setpoint_from/);
  const report = insertComponent(db, "TwoTerminalVSCLine", obj);
  expect(report.skipped_fields).toEqual({ TwoTerminalVSCLine: { dc_setpoint_from: 1, dc_setpoint_to: 1 } });
  const rows = db.prepare("SELECT name, unit FROM attributes WHERE entity_id = 9101").all() as { name: string; unit: unknown }[];
  const stored = Object.fromEntries(rows.map((r) => [r.name, r.unit]));
  expect(stored).not.toHaveProperty("dc_setpoint_from");
  expect(stored.rating).toBe("pu");
});

test.skipIf(!hasGolden)("unit-free field holding a number is reported or raises", () => {
  const db = fresh();
  const obj = vsc(insertLccEndpoints(db, golden()).arc, { dc_control_from: 1.0 });
  expect(() => insertComponent(db, "TwoTerminalVSCLine", obj, { strict: true })).toThrow(/dc_control_from/);
  const report = insertComponent(db, "TwoTerminalVSCLine", obj);
  expect(report.skipped_fields).toEqual({ TwoTerminalVSCLine: { dc_control_from: 1 } });
});

test.skipIf(!hasGolden)("unknown discriminator value is reported or raises", () => {
  const db = fresh();
  const lcc = { ...insertLccEndpoints(db, golden()), parameter_units: "BOGUS" };
  expect(() => insertComponent(db, "TwoTerminalLCCLine", lcc, { strict: true })).toThrow(/discriminator/);
  const report = insertComponent(db, "TwoTerminalLCCLine", lcc);
  expect((report.skipped_fields as Record<string, Record<string, number>>).TwoTerminalLCCLine.r).toBe(1);
});

const load = (bus: unknown, powerUnits: string, extra: JsonObject = {}): JsonObject => ({
  id: 9001, name: "load", available: true, bus, active_power: 0.5, reactive_power: 0.1,
  base_power: 100.0, power_units: powerUnits, max_active_power: 0.6, max_reactive_power: 0.2,
  ...extra,
});

test.skipIf(!hasGolden).each([
  ["COMPONENT_BASE", "pu", "pu"],
  ["NATURAL_UNITS", "MW", "MVAr"],
])("%s load power follows its power_units", (powerUnits, active, reactive) => {
  const db = fresh();
  const bus = loneBus(golden());
  insertComponent(db, "ACBus", bus);
  const report = insertComponent(db, "PowerLoad", load(bus.id, powerUnits), { strict: true });
  expect(report.skipped_fields).toEqual({});
  const stored = attributes(db, 9001);
  expect(stored.active_power).toEqual([0.5, active, "ActivePower"]);
  expect(stored.max_reactive_power).toEqual([0.2, reactive, "ReactivePower"]);
  expect(stored.available).toEqual([true, null, null]);
});

test.skipIf(!hasGolden)("interruptible load cost is stored verbatim", () => {
  const db = fresh();
  const bus = loneBus(golden());
  insertComponent(db, "ACBus", bus);
  const cost = {
    cost_type: "LOAD",
    fixed: 2.0,
    variable_operation_cost: {
      power_units: "NATURAL_UNITS",
      value_curve: { curve_type: "INPUT_OUTPUT", function_data: { function_type: "LINEAR", proportional_term: 30.0 } },
    },
  };
  insertComponent(db, "InterruptiblePowerLoad", load(bus.id, "NATURAL_UNITS", { operation_cost: cost }), { strict: true });
  expect(attributes(db, 9001).operation_cost).toEqual([cost, null, null]);
});
