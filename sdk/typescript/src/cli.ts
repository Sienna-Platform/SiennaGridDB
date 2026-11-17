#!/usr/bin/env node
// griddb-tools build <document.json | bundle dir> <out.sqlite> [--strict] [--time-series <sidecar.h5>]
// A portfolio's base_system_file goes in first.
import { rmSync } from "node:fs";
import { createDatabase } from "./db.js";
import { insertFile } from "./insert.js";

const USAGE = "usage: griddb-tools build <document.json | bundle dir> <out.sqlite> [--strict] [--time-series <sidecar.h5>]\n";

function main(argv: string[]): number {
  const args = [...argv];
  const strict = args.includes("--strict");
  let timeSeries: string | undefined;
  const at = args.indexOf("--time-series");
  if (at >= 0) {
    timeSeries = args[at + 1];
    if (timeSeries === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    args.splice(at, 2);
  }
  const positional = args.filter((a) => !a.startsWith("--"));
  if (positional.length !== 3 || positional[0] !== "build") {
    process.stderr.write(USAGE);
    return 2;
  }
  const out = positional[2];
  const db = createDatabase(out);
  let report;
  try {
    report = insertFile(db, positional[1], { strict, timeSeries });
  } catch (err) {
    // A failed build leaves no schema-only file to block the next run.
    db.close();
    rmSync(out);
    throw err;
  }
  db.close();
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  return 0;
}

process.exit(main(process.argv.slice(2)));
