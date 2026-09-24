export class GridDBToolsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}
export class DatabaseExistsError extends GridDBToolsError {}
export class SQLiteVersionError extends GridDBToolsError {}
export class ManifestMismatchError extends GridDBToolsError {}
export class InsertError extends GridDBToolsError {}
export class UnsupportedComponentError extends GridDBToolsError {}
export class GapValueError extends GridDBToolsError {}
export class EncodeError extends Error {}

export type JsonObject = Record<string, unknown>;

export function describe(typeName: string, obj: JsonObject): string {
  const parts = [typeName];
  if ("id" in obj) parts.push(`id=${String(obj.id)}`);
  if ("name" in obj) parts.push(`name=${JSON.stringify(obj.name)}`);
  return parts.join(" ");
}
