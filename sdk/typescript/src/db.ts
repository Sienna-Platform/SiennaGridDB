import Database from "better-sqlite3";
import { existsSync } from "node:fs";
import { DatabaseExistsError, ManifestMismatchError, SQLiteVersionError } from "./errors.js";
import { dataText, loadManifest } from "./manifest.js";

export type Connection = Database.Database;
const SCHEMA_FILES = ["schema.sql", "triggers.sql", "unit_registry.sql", "views.sql"];

function versionAtLeast(found: string, min: number[]): boolean {
  const parts = found.split(".").map(Number);
  for (let i = 0; i < min.length; i++) {
    if ((parts[i] ?? 0) !== min[i]) return (parts[i] ?? 0) > min[i];
  }
  return true;
}

function connect(path: string): Connection {
  const db = new Database(path);
  const found = db.prepare("SELECT sqlite_version() AS v").get() as { v: string };
  if (!versionAtLeast(found.v, [3, 45, 0])) {
    db.close();
    throw new SQLiteVersionError(`SQLite ${found.v} is older than the required 3.45.0`);
  }
  db.pragma("foreign_keys = ON");
  return db;
}

export function openDatabase(path: string): Connection {
  const db = connect(path);
  const found = db.pragma("user_version", { simple: true }) as number;
  const expected = loadManifest().schema_user_version;
  if (found !== expected) {
    db.close();
    throw new ManifestMismatchError(
      `${path} has user_version ${found}; this package writes schema version ${expected}`,
    );
  }
  return db;
}

export function seedVocabulary(db: Connection): void {
  const vocab = loadManifest().vocabulary;
  const et = db.prepare(
    "INSERT OR IGNORE INTO entity_types (name, is_topology, is_dc) VALUES (?, ?, ?)",
  );
  for (const t of vocab.entity_types) et.run(t.name, t.is_topology ? 1 : 0, t.is_dc ? 1 : 0);
  for (const [table, names] of Object.entries(vocab)) {
    if (table === "entity_types") continue;
    const stmt = db.prepare(`INSERT OR IGNORE INTO ${table} (name) VALUES (?)`);
    for (const name of names as string[]) stmt.run(name);
  }
}

export function createDatabase(path: string): Connection {
  if (existsSync(path)) {
    throw new DatabaseExistsError(`${path} already exists; createDatabase never overwrites`);
  }
  const db = connect(path);
  for (const name of SCHEMA_FILES) db.exec(dataText(name));
  seedVocabulary(db);
  return db;
}
