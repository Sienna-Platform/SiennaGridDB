import { featureKind, isInt, isObject, type SqlValue } from "./encode.js";
import { InsertError, type JsonObject } from "./errors.js";

const DERIVED = "DeterministicSingleTimeSeries";

export function featureRows(hash: string, features: JsonObject): SqlValue[][] {
  return Object.entries(features).map(([key, value]) => {
    const kind = featureKind(value);
    if (kind === "bool") return [hash, key, kind, null, null, value ? 1 : 0, null];
    if (kind === "int") return [hash, key, kind, BigInt(value as number), null, null, null];
    if (kind === "float") return [hash, key, kind, null, value as number, null, null];
    return [hash, key, kind, null, null, null, value as string];
  });
}

/**
 * A row whose owner the document holds names that owner's type and category; a mislabel
 * is invalid data, like a dangling reference.
 */
export function requireOwnerLabel(row: JsonObject, owners: Map<number, [string, string]>): void {
  const owner = row.owner_id;
  if (!isInt(owner) || !owners.has(owner)) return;
  const [heldType, heldCategory] = owners.get(owner)!;
  if (row.owner_type !== heldType || row.owner_category !== heldCategory) {
    throw new InsertError(
      `time series association id=${String(row.association_id)}: owner_id ${owner} ` +
        `is ${heldType} (${heldCategory}), not ${String(row.owner_type)} (${String(row.owner_category)})`,
    );
  }
}

// A hashable feature map that tells 1, 1.0 and true apart as featuresHash does.
function featureKey(features: unknown): unknown {
  if (!isObject(features)) return null;
  return Object.keys(features)
    .sort()
    .map((k) => [k, featureKind(features[k]), features[k]]);
}

function seriesKey(row: JsonObject): string {
  return JSON.stringify([row.owner_id, row.owner_category, row.name, featureKey(row.features), row.uri]);
}

/**
 * DeterministicSingleTimeSeries id => its SingleTimeSeries id. A derived series is a view
 * over its source's array: same owner, name, features and uri.
 */
export function derivedSources(rows: JsonObject[]): Map<number, number> {
  const sources = new Map<string, unknown>();
  for (const r of rows) if (r.time_series_type === "SingleTimeSeries") sources.set(seriesKey(r), r.association_id);
  const derived = new Map<number, number>();
  for (const r of rows) {
    if (r.time_series_type !== DERIVED) continue;
    const source = sources.get(seriesKey(r));
    if (isInt(source) && isInt(r.association_id)) derived.set(r.association_id, source);
  }
  return derived;
}

function isReference(key: string): boolean {
  return key === "association_id" || key === "fuel_cost_time_series" || key.endsWith("_association_id");
}

function collectDangling(found: Dangling[], entityId: number, node: unknown, storedIds: Set<number>): void {
  if (Array.isArray(node)) {
    for (const v of node) collectDangling(found, entityId, v, storedIds);
  } else if (isObject(node)) {
    for (const [k, v] of Object.entries(node)) {
      if (isReference(k) && isInt(v)) {
        if (!storedIds.has(v)) found.push([entityId, k, v]);
      } else {
        collectDangling(found, entityId, v, storedIds);
      }
    }
  }
}

export type Dangling = [entityId: number, key: string, id: number];

/**
 * [entity id, key, id] for each time series reference that names no id in storedIds.
 * payloads holds [entity id, payload] for every row the insert writes.
 */
export function danglingReferences(payloads: [number, unknown][], storedIds: Set<number>): Dangling[] {
  const found: Dangling[] = [];
  for (const [entityId, payload] of payloads) collectDangling(found, entityId, payload, storedIds);
  return found;
}

export type SeriesRemap = (ref: number) => number;

/**
 * A document's series id to the one GridDB stores: a derived series' names its source,
 * and every id moves past offset. Undefined when no id changes.
 */
export function seriesRemap(sources: Map<number, number>, offset: number): SeriesRemap | undefined {
  if (sources.size === 0 && offset === 0) return undefined;
  return (ref) => (sources.get(ref) ?? ref) + offset;
}

/** The association rows with their ids moved past offset; any other id reaches the encoder and fails there. */
export function shiftIds(rows: JsonObject[], offset: number): JsonObject[] {
  if (offset === 0) return rows;
  return rows.map((r) => (isInt(r.association_id) ? { ...r, association_id: r.association_id + offset } : r));
}

/**
 * node with each time series reference (the keys dangling_time_series_references reads)
 * replaced by remap(id). An object or array is copied only when something inside it
 * changes; the caller's stays as it was.
 */
export function remapReferences<T>(node: T, remap: SeriesRemap | undefined): T {
  if (remap === undefined || node === null || typeof node !== "object") return node;
  const entries: [string | number, unknown][] = Array.isArray(node)
    ? [...node.entries()]
    : Object.entries(node as JsonObject);
  const changed = new Map<string | number, unknown>();
  for (const [k, v] of entries) {
    if (typeof k === "string" && isReference(k) && isInt(v)) {
      if (remap(v) !== v) changed.set(k, remap(v));
    } else {
      const remapped = remapReferences(v, remap);
      if (remapped !== v) changed.set(k, remapped);
    }
  }
  if (changed.size === 0) return node;
  const out = (Array.isArray(node) ? [...node] : { ...(node as JsonObject) }) as Record<string | number, unknown>;
  for (const [k, v] of changed) out[k] = v;
  return out as T;
}
