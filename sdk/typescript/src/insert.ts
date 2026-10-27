import Database from "better-sqlite3";
import type { Connection } from "./db.js";
import { seedVocabulary } from "./db.js";
import { canonicalJson, encode, isInt, isNull, isObject, valueAt, type SqlValue } from "./encode.js";
import {
  EncodeError,
  InsertError,
  describe,
  type JsonObject,
} from "./errors.js";
import { loadManifest, type Binding, type ComponentPlan, type TimeSeriesPlan } from "./manifest.js";
import { InsertReport } from "./report.js";
import {
  danglingReferences,
  derivedSources,
  featureRows,
  pointAtSources,
  requireOwnerLabel,
  type Dangling,
} from "./time_series.js";

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

function skip(report: InsertReport, strict: boolean, typeName: string, field: string, what: string) {
  if (strict) {
    throw new InsertError(`${what}: field ${JSON.stringify(field)} has no column in GridDB`);
  }
  report.addSkipped(typeName, field);
}

function unsupported(report: InsertReport, strict: boolean, key: string, n: number, reason: string) {
  if (strict) throw new InsertError(`${key} (${n} rows): ${reason}`);
  report.addUnsupported(key, n);
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
    const key = attr.unit_field === null ? "" : String(obj[attr.unit_field] ?? "");
    const arm = Object.hasOwn(attr.arms, key) ? attr.arms[key] : undefined;
    if (arm === undefined && !attr.exempt && typeof value !== "string" && typeof value !== "boolean") {
      skip(report, strict, plan.typeName, attr.field, what);
      continue;
    }
    run(
      db,
      loadManifest().attribute_sql,
      [BigInt(obj.id as number), plan.typeName, attr.field, canonicalJson(value), arm?.unit ?? null, arm?.quantity_kind ?? null],
      what,
    );
  }
  const unknown = Object.keys(obj).filter((k) => !plan.knownFields.has(k) && !isNull(obj[k]));
  for (const key of unknown.sort()) skip(report, strict, plan.typeName, key, what);
  report.addInserted(plan.typeName);
}

// Every document entry is a JSON object; anything else is schema-invalid input.
function requireObject(entry: unknown, what: string): void {
  if (!isObject(entry)) {
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
  const components = loadManifest().components;
  if (typeName in components) return components[typeName];
  unsupported(report, strict, typeName, n, "not a GridDB component type");
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

// Whether a reference names a component the insert does not write; ids follow the int
// encoder's rule, so any other value reaches the encoder and fails there.
function namesUnsupported(row: JsonObject, references: string[], ids: Set<number>): boolean {
  return references.some((r) => {
    const id = valueAt(row, r);
    return isInt(id) && ids.has(id);
  });
}

// The association rows to insert, after reporting the ones GridDB cannot store; owners
// maps each id the document holds to its [owner_type, owner_category].
function timeSeriesRows(
  doc: JsonObject,
  report: InsertReport,
  strict: boolean,
  unsupportedIds: Set<number>,
  owners: Map<number, [string, string]>,
): JsonObject[] {
  const plan = loadManifest().time_series;
  const rows = sectionRows(doc, plan.section);
  for (const row of rows) requireOwnerLabel(row, owners);
  const counts = new Map<string, number>();
  const stored: JsonObject[] = [];
  for (const row of rows) {
    const seriesType = String(row.time_series_type);
    if (Object.hasOwn(plan.unsupported_types, seriesType)) {
      counts.set(seriesType, (counts.get(seriesType) ?? 0) + 1);
    } else if (namesUnsupported(row, plan.references, unsupportedIds)) {
      report.addUnsupported(plan.section, 1);
    } else {
      stored.push(row);
    }
  }
  for (const seriesType of [...counts.keys()].sort()) {
    unsupported(report, strict, seriesType, counts.get(seriesType)!, plan.unsupported_types[seriesType]);
  }
  return stored;
}

// Association rows, then each feature set the first time its hash appears.
function insertAssociations(db: Connection, plan: TimeSeriesPlan, rows: JsonObject[], report: InsertReport) {
  const hashAt = plan.bindings.findIndex((b) => b.encode === "features_hash");
  const featuresSeen = new Set<string>();
  for (const row of rows) {
    const what = `time series association id=${String(row.association_id)}`;
    const values = params(plan.bindings, row, what);
    run(db, plan.row_sql, values, what);
    const hash = values[hashAt] as string;
    if (!featuresSeen.has(hash)) {
      featuresSeen.add(hash);
      for (const f of featureRows(hash, row.features as JsonObject)) run(db, plan.feature_sql, f, what);
    }
    report.addInserted(plan.section);
  }
}

// A foreign key cannot reach into JSON, so the insert is the only place that sees a payload
// reference to an association it does not store.
function reportDangling(
  report: InsertReport,
  strict: boolean,
  plans: [ComponentPlan, JsonObject[]][],
  attrs: JsonObject[],
  series: JsonObject[],
) {
  const storedIds = new Set(series.map((r) => r.association_id).filter(isInt));
  const rows = [...plans.flatMap(([, objs]) => objs), ...attrs];
  const payloads = rows.filter((o) => isObject(o) && isInt(o.id)).map((o): [number, unknown] => [o.id as number, o]);
  const dangling = danglingReferences(payloads, storedIds);
  if (dangling.length === 0) return;
  const [entityId, key, ref] = dangling.reduce((a, b) => (compareDangling(a, b) <= 0 ? a : b));
  const reason = `no stored time series association has the id (first: entity ${entityId} ${key}=${ref})`;
  unsupported(report, strict, "dangling_time_series_references", dangling.length, reason);
}

function compareDangling(a: Dangling, b: Dangling): number {
  if (a[0] !== b[0]) return a[0] - b[0];
  if (a[1] !== b[1]) return a[1] < b[1] ? -1 : 1;
  return a[2] - b[2];
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
  // References to a derived series name its source, which GridDB stores instead.
  const sources = derivedSources(sectionRows(doc, m.time_series.section));
  const plans: [ComponentPlan, JsonObject[]][] = [];
  // Ids follow the int encoder's rule, so any other value reaches the encoder and fails there.
  // A non-object entry (schema-invalid) has no id and is only counted.
  const unsupportedIds = new Set<number>();
  const owners = new Map<number, [string, string]>();
  for (const typeName of Object.keys(components).sort()) {
    const objs = components[typeName].map((o) => pointAtSources(o, sources));
    const ids = objs.map((o) => o?.id).filter(isInt);
    for (const id of ids) owners.set(id, [typeName, "Component"]);
    const plan = planFor(typeName, objs.length, report, strict);
    if (plan) plans.push([plan, objs]);
    else for (const id of ids) unsupportedIds.add(id);
  }
  plans.sort((a, b) => a[0].rank - b[0].rank || (a[0].typeName < b[0].typeName ? -1 : 1));
  for (const section of Object.keys(m.unsupported_sections).sort()) {
    const n = sectionSize(doc[section]);
    if (n > 0) unsupported(report, strict, section, n, m.unsupported_sections[section]);
  }
  const attrTypes = new Map<number, string>();
  for (const a of sectionRows(doc, "supplemental_attribute_associations")) {
    attrTypes.set(a.attribute_id as number, a.attribute_type as string);
  }
  const attrs = pointAtSources(sectionRows(doc, "supplemental_attributes"), sources);
  for (const attr of attrs) {
    const attrType = attrTypes.get(attr.id as number);
    if (attrType !== undefined) owners.set(attr.id as number, [attrType, "SupplementalAttribute"]);
  }
  const series = timeSeriesRows(doc, report, strict, unsupportedIds, owners);
  if (series.length > 0) {
    const reason = "the TypeScript SDK has no infrastore binding to read the time series sidecar";
    unsupported(report, strict, "time_series_values", series.length, reason);
  }
  reportDangling(report, strict, plans, attrs, series);
  const supp = m.supplemental_attributes;
  withSavepoint(db, () => {
    seedVocabulary(db);
    for (const [plan, objs] of plans) for (const obj of objs) writeEntity(db, plan, obj);
    const routed: [string, string, JsonObject, string][] = [];
    for (const attr of attrs) {
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
        if (namesUnsupported(row, section.references, unsupportedIds)) {
          report.addUnsupported(section.section, 1);
          continue;
        }
        const what = `${section.section} row ${JSON.stringify(row)}`;
        run(db, section.row_sql, params(section.bindings, row, what), what);
        report.addInserted(section.section);
      }
    }
    insertAssociations(db, m.time_series, series, report);
  });
  return report;
}
