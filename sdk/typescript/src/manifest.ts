import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { ManifestMismatchError } from "./errors.js";
import type { Encoding } from "./encode.js";

export const DATA_DIR = fileURLToPath(new URL("../data/", import.meta.url));
const SUPPORTED_MANIFEST_VERSION = 1;

export interface Binding { path: string; encode: Encoding }
export interface AttributePlan { field: string; unit: string | null; quantity_kind: string | null }
export interface ComponentPlan {
  typeName: string;
  rank: number;
  entity_sql: string;
  row_sql: string;
  bindings: Binding[];
  entityBindings: Binding[];
  attributes: AttributePlan[];
  gaps: string[];
  knownFields: Set<string>;
}
export interface AssociationPlan { section: string; row_sql: string; bindings: Binding[] }
export interface Manifest {
  schema_user_version: number;
  vocabulary: {
    entity_types: { name: string; is_topology: boolean; is_dc: boolean }[];
    [table: string]: unknown;
  };
  components: Record<string, ComponentPlan>;
  unsupported_components: Record<string, string>;
  attribute_sql: string;
  supplemental_attributes: { plant_types: string[]; plant_sql: string; attribute_sql: string };
  associations: AssociationPlan[];
  unsupported_sections: Record<string, string>;
}

let cached: Manifest | undefined;

export function dataText(name: string): string {
  return readFileSync(DATA_DIR + name, "utf-8");
}

export function loadManifest(): Manifest {
  if (cached) return cached;
  const raw = JSON.parse(dataText("insert_manifest.json"));
  if (raw.manifest_version !== SUPPORTED_MANIFEST_VERSION) {
    throw new ManifestMismatchError(
      `manifest_version ${raw.manifest_version} is not ${SUPPORTED_MANIFEST_VERSION}`,
    );
  }
  const components: Record<string, ComponentPlan> = {};
  for (const [typeName, entry] of Object.entries<any>(raw.components)) {
    const knownFields = new Set<string>([
      ...entry.bindings.map((b: Binding) => b.path.split(".")[0]),
      ...entry.attributes.map((a: AttributePlan) => a.field),
      ...entry.skip,
      ...entry.gaps,
    ]);
    components[typeName] = {
      ...entry,
      typeName,
      entityBindings: entry.bindings.slice(0, 1),
      knownFields,
    };
  }
  cached = { ...raw, components } as Manifest;
  return cached;
}
