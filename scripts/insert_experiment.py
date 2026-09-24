#!/usr/bin/env python3
"""Insert-experiment harness: build a GridDB from a SystemDocument JSON and report gaps.

Builds a fresh database with the bundled Python runtime (`sdk/python`), inserts the
whole document (lenient by default, `--strict` to fail on the first gap), then
cross-checks the InsertReport against the manifest and the actual table contents:

- every skipped field is classified as a *tracked gap* (listed in the manifest), an
  *attribute-channel unit gap* (unregistered structured value), or *unknown* (absent
  from the manifest entirely — schema-version drift or a manifest bug);
- table row counts are reconciled against what the report claims was inserted.

Exits 1 on InsertError (the document is rolled back; the DB is left for inspection).

The CATS source directory is never assumed: pass --cats-dir (or set CATS_DIR) to a
CATS clone holding CATS-CaliforniaTestSystem/, or --document for any other export.

Usage:
    python3 scripts/insert_experiment.py --cats-dir PATH [--db PATH] [--strict] [--dump PATH]
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "sdk" / "python" / "src"))

from sienna_griddb_tools.db import create_database  # noqa: E402
from sienna_griddb_tools.encode import EncodeError, encode, value_at  # noqa: E402
from sienna_griddb_tools.errors import GridDBToolsError  # noqa: E402
from sienna_griddb_tools.insert import insert_document  # noqa: E402

CATS_DOCUMENT = Path("CATS-CaliforniaTestSystem") / "CATS_openapi" / "system.json"
INSERT_INTO = re.compile(r"INSERT INTO (\w+)")


def resolve_document(args):
    """--document wins; otherwise the CATS source directory must be set explicitly."""
    if args.document is not None:
        return Path(args.document)
    cats_dir = args.cats_dir or os.environ.get("CATS_DIR")
    if cats_dir is None:
        sys.exit(
            "error: set the CATS source directory with --cats-dir or CATS_DIR (a CATS\n"
            "clone holding CATS-CaliforniaTestSystem/), or pass --document PATH"
        )
    return Path(cats_dir) / CATS_DOCUMENT


def classify_skips(report, manifest):
    """Split skipped_fields into tracked gaps, attribute unit gaps, and unknown keys."""
    tracked, unit_gaps, unknown = {}, {}, {}
    for type_name, fields in report.skipped_fields.items():
        entry = manifest["components"].get(type_name)
        if entry is None:
            unknown[type_name] = fields
            continue
        gaps = set(entry["gaps"])
        unregistered = {a["field"] for a in entry["attributes"] if a["unit"] is None}
        for field_name, n in fields.items():
            if field_name in gaps:
                tracked.setdefault(type_name, {})[field_name] = n
            elif field_name in unregistered:
                unit_gaps.setdefault(type_name, {})[field_name] = n
            else:
                unknown.setdefault(type_name, {})[field_name] = n
    return tracked, unit_gaps, unknown


def check_row_counts(conn, report, doc, manifest):
    """Reconcile table contents with the report; return a list of mismatch strings."""
    problems = []
    inserted = report.inserted
    components = doc.get("components") or {}

    entities_expected = sum(
        inserted.get(t, 0) for t in manifest["components"] if t in components
    )
    entities_expected += inserted.get("plants", 0) + inserted.get(
        "supplemental_attributes", 0
    )
    entities_actual = conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0]
    if entities_actual != entities_expected:
        problems.append(f"entities: expected {entities_expected}, found {entities_actual}")

    by_table = {}
    for type_name, entry in manifest["components"].items():
        if type_name not in components:
            continue
        by_table[entry["table"]] = by_table.get(entry["table"], 0) + inserted.get(
            type_name, 0
        )
    for table, expected in sorted(by_table.items()):
        actual = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if actual != expected:
            problems.append(f"{table}: expected {expected}, found {actual}")

    for table in ("plants", "supplemental_attributes"):
        actual = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if actual != inserted.get(table, 0):
            problems.append(f"{table}: expected {inserted.get(table, 0)}, found {actual}")

    for section in manifest["associations"]:
        name = section["section"]
        match = INSERT_INTO.search(section["row_sql"])
        if match is None:
            problems.append(f"{name}: cannot parse table from row_sql")
            continue
        actual = conn.execute(f"SELECT COUNT(*) FROM {match.group(1)}").fetchone()[0]
        expected = inserted.get(name, 0)
        if actual != expected:
            problems.append(f"{match.group(1)}: expected {expected}, found {actual}")
    return problems


def print_gap_summary(report, manifest):
    tracked, unit_gaps, unknown = classify_skips(report, manifest)
    total_skipped = sum(
        n for fields in report.skipped_fields.values() for n in fields.values()
    )
    print(f"\nskipped field values: {total_skipped}")
    for label, group in (
        ("tracked gaps (manifest lists them; schema update closes them)", tracked),
        ("attribute-channel unit gaps (no registered unit)", unit_gaps),
        ("UNKNOWN keys (not in manifest — drift or manifest bug)", unknown),
    ):
        n_total = sum(n for fields in group.values() for n in fields.values())
        print(f"  {label}: {n_total}")
        for type_name in sorted(group):
            fields = ", ".join(
                f"{f}x{n}"
                for f, n in sorted(group[type_name].items(), key=lambda kv: -kv[1])
            )
            print(f"    {type_name}: {fields}")
    if report.unsupported:
        print("  unsupported (not written):")
        for key, n in sorted(report.unsupported.items()):
            reason = manifest["unsupported_components"].get(
                key, manifest["unsupported_sections"].get(key, "")
            )
            print(f"    {key}x{n} - {reason}")


def _kind(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    return type(value).__name__


def dry_run(doc, manifest):
    """Encode-check every bound field of every row without touching a database."""
    mismatches = {}

    def probe(owner, path, encoding, value):
        try:
            encode(encoding, value)
        except EncodeError:
            key = (owner, path, encoding, _kind(value))
            mismatches[key] = mismatches.get(key, 0) + 1

    for type_name, objs in sorted((doc.get("components") or {}).items()):
        entry = manifest["components"].get(type_name)
        if entry is None:
            continue
        for obj in objs:
            for binding in entry["bindings"]:
                probe(
                    type_name,
                    binding["path"],
                    binding["encode"],
                    value_at(obj, binding["path"]),
                )
    for section in manifest["associations"]:
        name = section["section"]
        for row in doc.get(name) or []:
            for binding in section["bindings"]:
                probe(
                    name, binding["path"], binding["encode"], value_at(row, binding["path"])
                )

    assoc_types = {
        a["attribute_id"] for a in doc.get("supplemental_attribute_associations") or []
    }
    orphans = [
        a["id"]
        for a in doc.get("supplemental_attributes") or []
        if a["id"] not in assoc_types
    ]

    total = sum(mismatches.values())
    print(f"dry-run encode mismatches: {total}")
    for (owner, path, encoding, kind), n in sorted(
        mismatches.items(), key=lambda kv: -kv[1]
    ):
        print(f"  {n:6d}  {owner}.{path}: manifest encode={encoding}, document has {kind}")
    print(f"supplemental attributes no association names: {len(orphans)}")
    for attr_id in orphans[:10]:
        print(f"  orphan attribute id={attr_id}")
    return 1 if mismatches or orphans else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--document", default=None, help="explicit SystemDocument path (overrides CATS_DIR)"
    )
    parser.add_argument(
        "--cats-dir",
        default=None,
        help="CATS clone holding CATS-CaliforniaTestSystem/ (or set CATS_DIR)",
    )
    parser.add_argument("--db", default="/tmp/griddb-insert-experiment.sqlite")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--dump", help="write a canonical dump of the built DB to PATH")
    parser.add_argument(
        "--overwrite", action="store_true", help="replace an existing --db file"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="encode-check all bound fields without building a database",
    )
    args = parser.parse_args()

    db_path = Path(args.db)
    if db_path.exists():
        if not args.overwrite:
            sys.exit(f"error: {db_path} exists; pass --overwrite to replace it")
        db_path.unlink()

    document = resolve_document(args)
    if not document.exists():
        sys.exit(f"error: {document} not found; check the CATS source directory")
    with open(document, encoding="utf-8") as handle:
        doc = json.load(handle)
    manifest = json.loads((REPO_ROOT / "schema" / "insert_manifest.json").read_text())

    if args.dry_run:
        sys.exit(dry_run(doc, manifest))

    started = time.monotonic()
    conn = create_database(str(db_path))
    try:
        report = insert_document(conn, doc, strict=args.strict)
    except GridDBToolsError as exc:
        conn.close()
        print(f"INSERT FAILED after {time.monotonic() - started:.1f}s\n{exc}")
        sys.exit(1)
    elapsed = time.monotonic() - started

    n_objects = sum(len(v) for v in (doc.get("components") or {}).values())
    print(
        f"inserted document in {elapsed:.1f}s -> {db_path} ({db_path.stat().st_size >> 20} MiB)"
    )
    print(
        f"component objects: {n_objects}; supplemental_attributes: "
        f"{len(doc.get('supplemental_attributes') or [])}"
    )
    print("\n" + report.to_json())

    problems = check_row_counts(conn, report, doc, manifest)
    if problems:
        print("ROW-COUNT MISMATCHES:")
        for problem in problems:
            print(f"  {problem}")
    else:
        print("row-count reconciliation: all tables match the report")

    print_gap_summary(report, manifest)

    conn.close()
    if args.dump:
        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        from canonical_dump import dump

        Path(args.dump).write_text(dump(str(db_path)))
        print(f"\ncanonical dump -> {args.dump}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
