#!/usr/bin/env node
// griddb-tools build <document.json | bundle dir> <out.sqlite> [--strict]
// A portfolio's base_system_file goes in first.
import { createDatabase } from "./db.js";
import { insertFile } from "./insert.js";

function main(argv: string[]): number {
  const strict = argv.includes("--strict");
  const positional = argv.filter((a) => !a.startsWith("--"));
  if (positional.length !== 3 || positional[0] !== "build") {
    process.stderr.write("usage: griddb-tools build <document.json | bundle dir> <out.sqlite> [--strict]\n");
    return 2;
  }
  const db = createDatabase(positional[2]);
  const report = insertFile(db, positional[1], { strict });
  db.close();
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  return 0;
}

process.exit(main(process.argv.slice(2)));
