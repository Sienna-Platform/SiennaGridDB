#!/usr/bin/env python3
"""Language-neutral dump of a GridDB database, for cross-runtime parity checks.

Every user table except the sealed unit registry, non-hidden columns only. A table's
`id` is dropped when it is a local surrogate (not a foreign key to entities), since
runtimes may assign surrogates in a different order. JSON text stays as stored: every
runtime writes the same RFC 8785 text, so a difference in it is a parity failure. Rows
are sorted.

    python3 scripts/canonical_dump.py DB [--out FILE]
"""

import argparse
import json
import sqlite3
import sys

REGISTRY_TABLES = {
    "allowed_units",
    "quantity_kinds",
    "unit_basis_rules",
    "unit_conventions",
    "unit_management_metadata",
}


def keeps_id(conn, table):
    if table == "entities":
        return True
    for row in conn.execute(f"PRAGMA foreign_key_list('{table}')"):
        if row[3] == "id" and row[2] == "entities":
            return True
    return False


def dump(path):
    conn = sqlite3.connect(path)
    tables = [
        r[0]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        if r[0] not in REGISTRY_TABLES
    ]
    out = {}
    for table in tables:
        keep_id = keeps_id(conn, table)
        cols = [
            r[1]
            for r in conn.execute(f"PRAGMA table_xinfo('{table}')")
            if r[6] == 0 and (r[1] != "id" or keep_id)
        ]
        rows = conn.execute(f"SELECT {', '.join(cols)} FROM {table}").fetchall()
        norm = [list(row) for row in rows]
        norm.sort(key=lambda r: json.dumps(r, sort_keys=True))
        out[table] = {"columns": cols, "rows": norm}
    conn.close()
    return json.dumps(out, indent=1, sort_keys=True) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("db")
    parser.add_argument("--out")
    args = parser.parse_args()
    text = dump(args.db)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
