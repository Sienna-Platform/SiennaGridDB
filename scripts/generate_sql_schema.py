#!/usr/bin/env python3
"""Generate SQLite DDL from the SiennaSchemas JSON Schemas (SQL codegen).

This is the SQL analogue of the openapi-generator Python/Julia model codegen:
the JSON Schemas in SiennaSchemas are the source of truth, and this script
mechanically projects the components mapped in schema/schema_map.json into
CREATE TABLE statements, written to schema/generated_schema.sql.

Inputs (stdlib only, no third-party deps):
  --schemas-path  SiennaSchemas checkout root. Default: ../SiennaSchemas
                  relative to this repository root.
  schema/schema_map.json      DB table -> schema components (shared with
                              check_units_sync.py).
  schema/sql_codegen_map.json DB-specific codegen config this repo owns:
                              per-table column renames, foreign-key clauses,
                              and the attribute-channel property list (schema
                              properties stored in the generic `attributes`
                              table instead of dedicated columns, e.g. branch
                              r/x/b/g).

Output: schema/generated_schema.sql -- a REFERENCE artifact. It is not
executed by the build chain (schema/schema.sql remains the production DDL);
it exists so drift between the hand-written DDL and the schemas is visible
and mechanically checkable. Run with --diff to get the drift report.

Codegen rules
-------------
  table                one per schema_map entry; columns are the union of the
                       mapped components' properties in first-seen order
  id                   INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE
  name                 TEXT NOT NULL UNIQUE
  integer/number/      INTEGER / REAL / BOOLEAN / TEXT
  boolean/string
  ["X", "null"]        nullable X
  $ref to enum def     TEXT + CHECK (col IN (...)) with the enum inlined
  $ref to object def   JSON (composite payloads: MinMax, InOut, cost structs)
  required             NOT NULL only when the property exists on and is
                       required by EVERY mapped component (a component without
                       the property must be storable as NULL)
  default              DEFAULT <literal> (dicts/lists as canonical JSON text)
  minimum/maximum      CHECK (col >= / > / <= / < bound)
  enum (inline)        CHECK (col IN (...))
  x-unit / x-units     trailing "-- Units: ..." comment on the column
  renames              sql_codegen_map.json: schema property -> DB column name
  attribute_channel    properties skipped from DDL (stored in `attributes`),
                       listed in a table comment so nothing disappears silently

Determinism: table order follows schema_map.json, property order follows the
schema files, and there are no timestamps -- regenerating produces a
byte-identical file (CI-checkable with --check).

Modes:
  (none)    write schema/generated_schema.sql
  --check   regenerate in memory and exit non-zero if the checked-in file
            differs (staleness gate, mirrors generate_unit_registry.py)
  --diff    build generated DDL and the hand-written schema.sql in memory and
            report per-table column drift (missing / extra / type mismatch /
            nullability relaxation). Exit non-zero only on a type mismatch for a
            same-named column. Nullability relaxations (a schema-required column
            made nullable in schema.sql, compared via PRAGMA table_info notnull)
            are reported for review but, like the missing/extra-column coverage
            gaps, are non-gating -- the hand-written DDL is a curated subset.
            (CHECK-constraint comparison is deferred: parsing it out of
            sqlite_master.sql is fragile.)
"""

import argparse
import json
import os
import sqlite3
import sys

from _common import load_json, sql_literal

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMAS_PATH = os.path.normpath(os.path.join(REPO_ROOT, "..", "SiennaSchemas"))
SCHEMA_MAP = os.path.join(REPO_ROOT, "schema", "schema_map.json")
CODEGEN_MAP = os.path.join(REPO_ROOT, "schema", "sql_codegen_map.json")
OUTPUT = os.path.join(REPO_ROOT, "schema", "generated_schema.sql")
HANDWRITTEN = os.path.join(REPO_ROOT, "schema", "schema.sql")

HEADER = """\
-- GENERATED FILE -- DO NOT EDIT.
-- Produced by scripts/generate_sql_schema.py from the SiennaSchemas JSON
-- Schemas (schema/schema_map.json x schema/sql_codegen_map.json).
--
-- This is a REFERENCE projection of the schemas into SQLite DDL. The
-- production DDL is the hand-written schema/schema.sql; compare the two with
--     python3 scripts/generate_sql_schema.py --diff
-- to see where the hand-written schema has drifted from the schemas.

"""


class RefResolver:
    """Resolves relative-file $refs the way bundle_specs.py does."""

    def __init__(self, schemas_root):
        self.schemas_root = schemas_root
        self.cache = {}

    def doc(self, rel_path):
        norm = os.path.normpath(rel_path)
        if norm not in self.cache:
            self.cache[norm] = load_json(os.path.join(self.schemas_root, norm))
        return self.cache[norm]

    def resolve(self, ref, current_rel_file):
        file_part, _, frag = ref.partition("#")
        if file_part:
            base_dir = os.path.dirname(current_rel_file)
            target_rel = os.path.normpath(os.path.join(base_dir, file_part))
        else:
            target_rel = current_rel_file
        node = self.doc(target_rel)
        for part in [p for p in frag.split("/") if p]:
            node = node[part]
        return node, target_rel


def sql_type_for(prop, resolver, rel_file):
    """Returns (sql_type, check_values, is_nullable).

    check_values is an enum list (or None); is_nullable is True when the JSON
    type is a list that includes "null".
    """
    if "$ref" in prop:
        target, _ = resolver.resolve(prop["$ref"], rel_file)
        if "enum" in target:
            return "TEXT", list(target["enum"]), False
        return "JSON", None, False
    if "enum" in prop:
        return "TEXT", list(prop["enum"]), False
    jstype = prop.get("type")
    nullable = False
    if isinstance(jstype, list):
        nullable = "null" in jstype
        non_null = [t for t in jstype if t != "null"]
        jstype = non_null[0] if non_null else None
    mapping = {
        "integer": "INTEGER",
        "number": "REAL",
        "boolean": "BOOLEAN",
        "string": "TEXT",
        "object": "JSON",
        "array": "JSON",
    }
    return mapping.get(jstype, "JSON"), None, nullable


def bound_checks(column, prop):
    checks = []
    if "minimum" in prop:
        checks.append(f"{column} >= {json.dumps(prop['minimum'])}")
    if "exclusiveMinimum" in prop:
        checks.append(f"{column} > {json.dumps(prop['exclusiveMinimum'])}")
    if "maximum" in prop:
        checks.append(f"{column} <= {json.dumps(prop['maximum'])}")
    if "exclusiveMaximum" in prop:
        checks.append(f"{column} < {json.dumps(prop['exclusiveMaximum'])}")
    return checks


def _units_entry(key, value, renames):
    """Render one x-units entry. A dict value is a nested discriminator (a field
    whose unit depends on a second discriminator column); a plain value is a
    unit string."""
    if isinstance(value, dict):
        disc2 = value.get("x-unit-discriminator", "?")
        disc2 = renames.get(disc2, disc2)
        inner = ", ".join(f"{k2}: {v2}" for k2, v2 in sorted(value.get("x-units", {}).items()))
        return f"{key}: per {disc2} [{inner}]"
    return f"{key}: {value}"


def units_comment(prop, renames):
    # The discriminator names a sibling column, so the table's renames apply to
    # it the same way they apply to the column itself.
    if "x-units" in prop:
        disc = prop.get("x-unit-discriminator", "?")
        disc = renames.get(disc, disc)
        units_map = prop["x-units"]
        nested = any(isinstance(v, dict) for v in units_map.values())
        sep = "; " if nested else ", "
        pairs = sep.join(_units_entry(k, v, renames) for k, v in sorted(units_map.items()))
        return f" -- Units: per {disc} ({pairs})"
    if "x-unit" in prop:
        return f" -- Units: {prop['x-unit']}"
    return ""


def merge_components(components, resolver):
    """Union of properties across a table's mapped components.

    Returns (ordered {prop_name: prop_node}, required_by_all set, rel_file of
    first definition per property).
    """
    merged = {}
    prop_file = {}
    required_sets = []
    present_sets = []
    for comp in components:
        doc = resolver.doc(comp["file"])
        props = doc.get("properties", {})
        present_sets.append(set(props))
        required_sets.append(set(doc.get("required", [])))
        for pname, pnode in props.items():
            if pname not in merged:
                merged[pname] = pnode
                prop_file[pname] = comp["file"]
    all_present_and_required = set(merged)
    for present, required in zip(present_sets, required_sets):
        all_present_and_required &= present & required
    return merged, all_present_and_required, prop_file


def emit_table(table, components, table_cfg, resolver):
    renames = table_cfg.get("renames", {})
    fks = table_cfg.get("foreign_keys", {})
    attribute_channel = table_cfg.get("attribute_channel", [])
    skip = set(table_cfg.get("skip", []))

    merged, required_all, prop_file = merge_components(components, resolver)

    comp_names = ", ".join(c["component"] for c in components)
    lines = [f"-- {table}: generated from {comp_names}"]
    if attribute_channel:
        lines.append(
            "-- Stored via the generic `attributes` table (registered attribute-name"
        )
        lines.append(f"-- conventions), not as columns: {', '.join(attribute_channel)}")
    lines.append(f"CREATE TABLE {table} (")

    col_lines = []
    for pname, pnode in merged.items():
        if pname in skip or pname in attribute_channel:
            continue
        column = renames.get(pname, pname)
        if pname == "id":
            col_lines.append(
                "    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE"
            )
            continue
        if pname == "name":
            col_lines.append("    name TEXT NOT NULL UNIQUE")
            continue
        sql_type, enum_values, type_nullable = sql_type_for(
            pnode, resolver, prop_file[pname]
        )
        nullable = pname not in required_all or type_nullable
        parts = [f"    {column} {sql_type}"]
        parts.append("NULL" if nullable else "NOT NULL")
        if "default" in pnode and pnode["default"] is not None:
            parts.append(f"DEFAULT {sql_literal(pnode['default'])}")
        if enum_values is not None:
            quoted = ", ".join(sql_literal(v) for v in enum_values)
            parts.append(f"CHECK ({column} IN ({quoted}))")
        for check in bound_checks(column, pnode):
            parts.append(f"CHECK ({check})")
        if column in fks:
            parts.append(fks[column])
        col_lines.append(" ".join(parts) + units_comment(pnode, renames))

    body = []
    for i, col in enumerate(col_lines):
        sep = "," if i < len(col_lines) - 1 else ""
        if " -- " in col:
            decl, comment = col.split(" -- ", 1)
            body.append(f"{decl}{sep} -- {comment}")
        else:
            body.append(col + sep)
    lines.extend(body)
    lines.append(");")
    return "\n".join(lines) + "\n"


def generate(schemas_path):
    resolver = RefResolver(schemas_path)
    schema_map = load_json(SCHEMA_MAP)["tables"]
    codegen_map = load_json(CODEGEN_MAP)["tables"]
    out = [HEADER]
    for table, components in schema_map.items():
        table_cfg = codegen_map.get(table, {})
        out.append(emit_table(table, components, table_cfg, resolver))
        out.append("\n")
    return "".join(out).rstrip("\n") + "\n"


# --------------------------------------------------------------------------- diff
def table_columns(conn, table):
    """column name -> (SQL type upper-cased, is_not_null). PRAGMA table_info
    row layout is (cid, name, type, notnull, dflt_value, pk); notnull was
    previously discarded, which let a schema-required column silently ship as
    nullable in the hand-written DDL."""
    return {
        row[1]: (row[2].upper(), bool(row[3]))
        for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
    }


def check_stale(generated):
    """Return (is_stale, message) comparing OUTPUT against a fresh generation."""
    if not os.path.exists(OUTPUT):
        return True, f"STALE: {OUTPUT} does not exist. Run scripts/generate_sql_schema.py."
    with open(OUTPUT, encoding="utf-8") as f:
        current = f.read()
    if current != generated:
        return True, (f"STALE: {OUTPUT} differs from a fresh generation. "
                      "Run scripts/generate_sql_schema.py and commit the result.")
    return False, f"OK: {OUTPUT} is up to date."


def diff(generated_sql):
    gen = sqlite3.connect(":memory:")
    gen.executescript(generated_sql)
    hand = sqlite3.connect(":memory:")
    with open(HANDWRITTEN, encoding="utf-8") as f:
        hand.executescript(f.read())

    schema_map = load_json(SCHEMA_MAP)["tables"]
    codegen_map = load_json(CODEGEN_MAP)["tables"]
    type_conflicts = 0
    null_relaxations = 0
    for table in schema_map:
        gen_cols = table_columns(gen, table)
        hand_cols = table_columns(hand, table)
        if not hand_cols:
            print(f"[{table}] MISSING in hand-written schema.sql")
            continue
        attribute_channel = set(codegen_map.get(table, {}).get("attribute_channel", []))
        db_only = set(codegen_map.get(table, {}).get("db_only", []))
        only_gen = sorted(set(gen_cols) - set(hand_cols))
        only_hand = sorted(set(hand_cols) - set(gen_cols))
        shared = sorted(set(gen_cols) & set(hand_cols))
        for col in only_gen:
            print(f"[{table}] schema property has no DB column: {col} ({gen_cols[col][0]})")
        for col in only_hand:
            if col in db_only:
                continue  # DB-only column (e.g. unit discriminator); intentional, not drift
            note = " (attribute-channel)" if col in attribute_channel else ""
            print(f"[{table}] DB column has no schema property: {col} ({hand_cols[col][0]}){note}")
        for col in shared:
            gen_type, gen_notnull = gen_cols[col]
            hand_type, hand_notnull = hand_cols[col]
            # Type comparison. SQLite stores JSON as TEXT; a JSON-typed
            # projection of a TEXT column (or vice versa) is the same physical
            # storage class, so it is a note rather than a mismatch.
            # TEXT/JSON and INTEGER/BOOLEAN pairs share a storage class: the
            # hand-written DDL uses the STRICT-legal spelling (TEXT+json_valid,
            # INTEGER+CHECK IN (0,1)) of the generated JSON/BOOLEAN type.
            if gen_type != hand_type:
                if {gen_type, hand_type} in ({"TEXT", "JSON"}, {"INTEGER", "BOOLEAN"}):
                    print(
                        f"[{table}] note: {col} is {hand_type} in schema.sql, "
                        f"{gen_type} per the schemas (same storage class)"
                    )
                else:
                    print(
                        f"[{table}] TYPE MISMATCH {col}: schemas say {gen_type}, "
                        f"schema.sql says {hand_type}"
                    )
                    type_conflicts += 1
            # Nullability comparison (previously invisible: PRAGMA notnull was
            # discarded). GATE the DANGEROUS direction -- a column the schemas
            # require (NOT NULL) that the hand-written DDL relaxed to NULL. That
            # is a constraint-loss defect: a consumer trusting the schema's
            # required-ness reads a NULL where a value must exist. The reverse
            # (hand-written stricter than the schema) is a deliberate curation
            # choice, not a loss, so it is not reported. (CHECK-constraint
            # comparison is deferred: parsing it out of sqlite_master.sql is
            # fragile.)
            if gen_notnull and not hand_notnull:
                print(
                    f"[{table}] NULLABILITY RELAXATION {col}: schemas require "
                    "NOT NULL, schema.sql allows NULL"
                )
                null_relaxations += 1
    if type_conflicts or null_relaxations:
        if type_conflicts:
            print(f"\n{type_conflicts} type mismatch(es) between schemas and schema.sql.")
        if null_relaxations:
            print(
                f"\n{null_relaxations} nullability relaxation(s): a schema-required "
                "column is nullable in schema.sql."
            )
        return 1
    print("\nNo type mismatches or nullability relaxations; remaining lines above are coverage drift (gaps).")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--schemas-path", default=DEFAULT_SCHEMAS_PATH)
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero if schema/generated_schema.sql is stale")
    parser.add_argument("--diff", action="store_true",
                        help="report drift between generated DDL and schema.sql")
    args = parser.parse_args()

    # --check and --diff may be combined: generate once, run both comparisons.
    if args.check or args.diff:
        generated = generate(args.schemas_path)
        exit_code = 0
        if args.check:
            stale, message = check_stale(generated)
            print(message)
            if stale:
                exit_code = 1
        if args.diff:
            exit_code = diff(generated) or exit_code
        sys.exit(exit_code)

    generated = generate(args.schemas_path)
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write(generated)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
