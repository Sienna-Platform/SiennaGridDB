import Database from "better-sqlite3";
import type { Connection } from "./db.js";
import { seedVocabulary } from "./db.js";
import { canonicalJson, encode, isInt, isNull, valueAt, type SqlValue } from "./encode.js";
import {
  EncodeError,
  GapValueError,
  InsertError,
  UnsupportedComponentError,
  describe,
  type JsonObject,
} from "./errors.js";
import { loadManifest, type Binding, type ComponentPlan, type UnitSpec } from "./manifest.js";
import { InsertReport } from "./report.js";

const SAVEPOINT = "sienna_griddb_tools_insert";

export interface InsertOptions { strict?: boolean }

function withSavepoint(db: Connection, f: () => void): void {
  db.exec(`SAVEPOINT ${SAVEPOINT}`);
  try {
    f();
  } catch (err) {
    db.exec(`ROLLBACK TO ${SAVEPOINT}`);
    db.exec(`RELEASE ${SAVEPOINT}`);
    throw err;
  }
  db.exec(`RELEASE ${SAVEPOINT}`);
}

function wrap(err: unknown, what: string): unknown {
  if (err instanceof EncodeError || err instanceof Database.SqliteError) {
    return new InsertError(`${what}: ${err.message}`);
  }
  return err;
}

// better-sqlite3 does not cache prepared statements; compile each SQL text once per connection.
const statements = new WeakMap<Connection, Map<string, Database.Statement>>();

function prepared(db: Connection, sql: string): Database.Statement {
  let cache = statements.get(db);
  if (!cache) {
    cache = new Map();
    statements.set(db, cache);
  }
  let stmt = cache.get(sql);
  if (!stmt) {
    stmt = db.prepare(sql);
    cache.set(sql, stmt);
  }
  return stmt;
}

function run(db: Connection, sql: string, params: SqlValue[], what: string): void {
  try {
    prepared(db, sql).run(...params);
  } catch (err) {
    throw wrap(err, what);
  }
}

function params(bindings: Binding[], obj: JsonObject, what: string): SqlValue[] {
  try {
    return bindings.map((b) => encode(b.encode, valueAt(obj, b.path)));
  } catch (err) {
    throw wrap(err, what);
  }
}

function skip(
  report: InsertReport,
  strict: boolean,
  typeName: string,
  field: string,
  what: string,
  reason = "has no column in GridDB",
) {
  if (strict) throw new GapValueError(`${what}: field ${JSON.stringify(field)} ${reason}`);
  report.addSkipped(typeName, field);
}

function unsupported(report: InsertReport, strict: boolean, key: string, n: number, reason: string) {
  if (strict) throw new UnsupportedComponentError(`${key} (${n} rows): ${reason}`);
  report.addUnsupported(key, n);
}

/** The spec fixing one attribute row's unit, following discriminator arms; undefined
 * when a discriminating field's value has no arm. */
export function resolveUnit(spec: UnitSpec, obj: JsonObject): UnitSpec | undefined {
  let s: UnitSpec | undefined = spec;
  while (s?.discriminator !== undefined) {
    const raw: unknown = isNull(obj[s.discriminator]) ? s.default : obj[s.discriminator];
    const key: string = typeof raw === "string" ? raw : canonicalJson(raw ?? null);
    s = s.arms && Object.hasOwn(s.arms, key) ? s.arms[key] : undefined;
  }
  return s;
}

function writeRow(
  db: Connection,
  plan: ComponentPlan,
  obj: JsonObject,
  report: InsertReport,
  strict: boolean,
) {
  const what = describe(plan.typeName, obj);
  run(db, plan.row_sql, params(plan.bindings, obj, what), what);
  for (const attr of plan.attributes) {
    const value = obj[attr.field];
    if (isNull(value)) continue;
    if (attr.unit_free && typeof value !== "string" && typeof value !== "boolean") {
      skip(report, strict, plan.typeName, attr.field, what, "needs a string or boolean value");
      continue;
    }
    const spec = resolveUnit(attr, obj);
    if (!spec) {
      skip(report, strict, plan.typeName, attr.field, what, "has no unit for its discriminator value");
      continue;
    }
    run(
      db,
      loadManifest().attribute_sql,
      [BigInt(obj.id as number), plan.typeName, attr.field, canonicalJson(value), spec.unit ?? null, spec.quantity_kind ?? null],
      what,
    );
  }
  for (const gap of plan.gaps) {
    if (!isNull(obj[gap])) skip(report, strict, plan.typeName, gap, what);
  }
  const unknown = Object.keys(obj).filter((k) => !plan.knownFields.has(k) && !isNull(obj[k]));
  for (const key of unknown.sort()) skip(report, strict, plan.typeName, key, what);
  report.addInserted(plan.typeName);
}

// Every document entry is a JSON object; anything else is schema-invalid input.
function requireObject(entry: unknown, what: string): void {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    throw new InsertError(`${what} ${JSON.stringify(entry)}: not an object`);
  }
}

// A section given as JSON null reads as empty.
function sectionRows(doc: JsonObject, name: string): JsonObject[] {
  const rows = (doc[name] ?? []) as unknown[];
  for (const row of rows) requireObject(row, `${name} row`);
  return rows as JsonObject[];
}

function writeEntity(db: Connection, plan: ComponentPlan, obj: JsonObject) {
  requireObject(obj, `${plan.typeName} entry`);
  const what = describe(plan.typeName, obj);
  run(db, plan.entity_sql, params(plan.entityBindings, obj, what), what);
}

function planFor(
  typeName: string,
  n: number,
  report: InsertReport,
  strict: boolean,
): ComponentPlan | undefined {
  const m = loadManifest();
  if (typeName in m.components) return m.components[typeName];
  const reason = m.unsupported_components[typeName] ?? "not a GridDB component type";
  unsupported(report, strict, typeName, n, reason);
  return undefined;
}

export function insertComponents(
  db: Connection,
  typeName: string,
  objs: JsonObject[],
  opts: InsertOptions = {},
): InsertReport {
  const strict = opts.strict ?? false;
  const report = new InsertReport();
  const plan = planFor(typeName, objs.length, report, strict);
  if (!plan) return report;
  withSavepoint(db, () => {
    for (const obj of objs) {
      writeEntity(db, plan, obj);
      writeRow(db, plan, obj, report, strict);
    }
  });
  return report;
}

export function insertComponent(
  db: Connection,
  typeName: string,
  obj: JsonObject,
  opts: InsertOptions = {},
): InsertReport {
  return insertComponents(db, typeName, [obj], opts);
}

function sectionSize(value: unknown): number {
  if (Array.isArray(value)) return value.length;
  if (value !== null && typeof value === "object") return Object.keys(value).length;
  return 0;
}

export function insertDocument(db: Connection, doc: JsonObject, opts: InsertOptions = {}): InsertReport {
  const strict = opts.strict ?? false;
  const m = loadManifest();
  const report = new InsertReport();
  const components = (doc.components ?? {}) as Record<string, JsonObject[]>;
  const plans: [ComponentPlan, JsonObject[]][] = [];
  // Ids follow the int encoder's rule, so any other value reaches the encoder and fails there.
  // A non-object entry (schema-invalid) has no id and is only counted.
  const unsupportedIds = new Set<number>();
  for (const typeName of Object.keys(components).sort()) {
    const plan = planFor(typeName, components[typeName].length, report, strict);
    if (plan) plans.push([plan, components[typeName]]);
    else for (const obj of components[typeName]) if (isInt(obj?.id)) unsupportedIds.add(obj.id);
  }
  plans.sort((a, b) => a[0].rank - b[0].rank || (a[0].typeName < b[0].typeName ? -1 : 1));
  for (const section of Object.keys(m.unsupported_sections).sort()) {
    const n = sectionSize(doc[section]);
    if (n > 0) unsupported(report, strict, section, n, m.unsupported_sections[section]);
  }
  const nSeries = sectionSize(doc[m.time_series.section]);
  if (nSeries > 0) {
    const reason = "the TypeScript SDK has no reader for the HDF5 time series sidecar";
    unsupported(report, strict, m.time_series.section, nSeries, reason);
  }
  const attrTypes = new Map<number, string>();
  for (const a of sectionRows(doc, "supplemental_attribute_associations")) {
    attrTypes.set(a.attribute_id as number, a.attribute_type as string);
  }
  const supp = m.supplemental_attributes;
  withSavepoint(db, () => {
    seedVocabulary(db);
    for (const [plan, objs] of plans) for (const obj of objs) writeEntity(db, plan, obj);
    const routed: [string, string, JsonObject, string][] = [];
    for (const attr of sectionRows(doc, "supplemental_attributes")) {
      const id = attr.id as number;
      const attrType = attrTypes.get(id);
      if (attrType === undefined) {
        throw new InsertError(`supplemental attribute id=${id}: no association names its type`);
      }
      const table = supp.plant_types.includes(attrType) ? "plants" : "supplemental_attributes";
      const what = `${attrType} id=${id}`;
      run(
        db,
        "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, ?, ?)",
        [BigInt(id), table, attrType],
        what,
      );
      routed.push([table, attrType, attr, what]);
    }
    for (const [plan, objs] of plans) for (const obj of objs) writeRow(db, plan, obj, report, strict);
    for (const [table, attrType, attr, what] of routed) {
      const id = BigInt(attr.id as number);
      if (table === "plants") {
        const { id: _id, name, ...rest } = attr;
        run(db, supp.plant_sql, [id, name as string, attrType, canonicalJson(rest)], what);
      } else {
        const { id: _id, ...rest } = attr;
        run(db, supp.attribute_sql, [id, attrType, canonicalJson(rest)], what);
      }
      report.addInserted(table);
    }
    for (const section of m.associations) {
      for (const row of sectionRows(doc, section.section)) {
        // A row naming a component that has no table is not written either.
        const refs = section.references.map((r) => valueAt(row, r));
        if (refs.some((id) => isInt(id) && unsupportedIds.has(id))) {
          report.addUnsupported(section.section, 1);
          continue;
        }
        const what = `${section.section} row ${JSON.stringify(row)}`;
        run(db, section.row_sql, params(section.bindings, row, what), what);
        report.addInserted(section.section);
      }
    }
  });
  return report;
}
