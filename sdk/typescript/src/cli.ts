#!/usr/bin/env node
// griddb-tools build <document.json> <out.sqlite> [--strict]
import { readFileSync } from "node:fs";
import { createDatabase } from "./db.js";
import { insertDocument } from "./insert.js";

function main(argv: string[]): number {
  const strict = argv.includes("--strict");
  const positional = argv.filter((a) => !a.startsWith("--"));
  if (positional.length !== 3 || positional[0] !== "build") {
    process.stderr.write("usage: griddb-tools build <document.json> <out.sqlite> [--strict]\n");
    return 2;
  }
  const doc = JSON.parse(readFileSync(positional[1], "utf-8"));
  const db = createDatabase(positional[2]);
  const report = insertDocument(db, doc, { strict });
  db.close();
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  return 0;
}

process.exit(main(process.argv.slice(2)));
