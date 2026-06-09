#!/usr/bin/env python3
"""Generate schema/unit_registry.sql from the unit vocabulary and column map.

Inputs (stdlib only, no third-party deps):
  --units-json   SiennaSchemas Core/units.json  (the vocabulary source of truth:
                 quantity_types + allowed_units). Default: ../SiennaSchemas/Core/units.json
                 relative to this repository root.
  --conventions  schema/column_conventions.json (the DB-specific column mapping).

Output: schema/unit_registry.sql -- portable INSERT statements only (no sqlite3
CLI dot-commands), starting with `PRAGMA foreign_keys = ON;`, sealed with a
sha256 fingerprint over the registry content.

Determinism: every collection is emitted in sorted order and there are no
timestamps, so re-running the generator produces a byte-identical file.

Validation: every (quantity_type, unit) pair used in column_conventions.json
must exist in units.json allowed_units. If any do not, the generator exits with
a non-zero status and lists the offenders -- it never invents vocabulary.

--------------------------------------------------------------------------------
CANONICAL CHECKSUM REPRESENTATION (must match verify_unit_registry.py exactly)
--------------------------------------------------------------------------------
The seal row `unit_management_metadata.unit_conventions_checksum` stores the
sha256 hex digest of a canonical byte representation built from the LIVE content
of three tables: quantity_types, allowed_units, unit_conventions.

Field / row / table separators (ASCII control chars, chosen so they cannot
appear in any legitimate field value):
    US  = '\x1f'  (unit separator)  -- between fields within a row
    RS  = '\x1e'  (record separator) -- between rows within a table
    GS  = '\x1d'  (group separator)  -- between the three table blocks

Per-table row field order (NULLs rendered as the empty string):
    quantity_types    : name, default_unit, dimension, description
                        (dimension is the canonical compact JSON of the exponent
                         map: json.dumps(map, sort_keys=True, separators=(",",":")))
    allowed_units     : quantity_type, unit
    unit_conventions  : table_name, column_name, quantity_type, unit,
                        discriminator_column, discriminator_value, description

Rows within each table are sorted (ascending, Python default string sort) by the
tuple of their fields in the order listed above. Field values are joined with US,
rows joined with RS. The three table blocks (quantity_types, allowed_units,
unit_conventions -- in that fixed order) are joined with GS. The result is
UTF-8 encoded and hashed with hashlib.sha256; the hex digest is the seal.
"""

import argparse
import hashlib
import json
import os
import sys

from _common import none_to_empty, repr_from_rows, sql_literal

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_UNITS_JSON = os.path.normpath(
    os.path.join(REPO_ROOT, "..", "SiennaSchemas", "Core", "units.json")
)
DEFAULT_CONVENTIONS = os.path.join(REPO_ROOT, "schema", "column_conventions.json")
DEFAULT_OUTPUT = os.path.join(REPO_ROOT, "schema", "unit_registry.sql")

CONVENTION_VERSION = "sienna-griddb-1.1"


def canonical_dimension(dimension):
    """Serialize an exponent map to canonical compact sorted JSON."""
    return json.dumps(dimension, sort_keys=True, separators=(",", ":"))


def load_units(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    quantity_types = []
    for qt in data["quantity_types"]:
        quantity_types.append(
            {
                "name": qt["name"],
                "default_unit": qt["default_unit"],
                "dimension": canonical_dimension(qt["dimension"]),
                "description": qt.get("description"),
            }
        )
    allowed_units = []
    for au in data["allowed_units"]:
        allowed_units.append(
            {"quantity_type": au["quantity_type"], "unit": au["unit"]}
        )
    convention = data["convention"]
    return quantity_types, allowed_units, convention


def load_conventions(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    rows = []
    for entry in data["conventions"]:
        rows.append(
            {
                "table_name": entry["table"],
                "column_name": entry["column"],
                "quantity_type": entry["quantity_type"],
                "unit": entry["unit"],
                "discriminator_column": entry.get("discriminator_column"),
                "discriminator_value": entry.get("discriminator_value"),
                "description": entry.get("description"),
            }
        )
    return rows


def validate_pairs(conventions, allowed_units):
    allowed = {(au["quantity_type"], au["unit"]) for au in allowed_units}
    offenders = []
    for row in conventions:
        pair = (row["quantity_type"], row["unit"])
        if pair not in allowed:
            offenders.append(
                "{table_name}.{column_name} -> ({quantity_type}, {unit})".format(
                    **row
                )
            )
    return offenders


def canonical_repr(quantity_types, allowed_units, conventions):
    qt_rows = (
        (
            r["name"],
            r["default_unit"],
            r["dimension"],
            none_to_empty(r["description"]),
        )
        for r in quantity_types
    )
    au_rows = ((r["quantity_type"], r["unit"]) for r in allowed_units)
    uc_rows = (
        (
            r["table_name"],
            r["column_name"],
            r["quantity_type"],
            r["unit"],
            none_to_empty(r["discriminator_column"]),
            none_to_empty(r["discriminator_value"]),
            none_to_empty(r["description"]),
        )
        for r in conventions
    )
    return repr_from_rows(qt_rows, au_rows, uc_rows)


def checksum(quantity_types, allowed_units, conventions):
    repr_str = canonical_repr(quantity_types, allowed_units, conventions)
    return hashlib.sha256(repr_str.encode("utf-8")).hexdigest()


def emit(quantity_types, allowed_units, conventions, units_convention, seal):
    lines = []
    lines.append("PRAGMA foreign_keys = ON;")
    lines.append("")
    lines.append("-- Unit Registry Seed Data (GENERATED -- do not edit by hand)")
    lines.append(
        "-- Regenerate with: python3 scripts/generate_unit_registry.py"
    )
    lines.append(
        "-- Source of truth: SiennaSchemas Core/units.json + schema/column_conventions.json"
    )
    lines.append(
        "-- Must run AFTER schema.sql and triggers.sql, BEFORE views.sql."
    )
    lines.append("")

    lines.append("-- 1. Quantity types")
    lines.append(
        "INSERT INTO quantity_types (name, default_unit, dimension, description) VALUES"
    )
    qt_sorted = sorted(quantity_types, key=lambda r: r["name"])
    qt_values = []
    for r in qt_sorted:
        qt_values.append(
            "    ({}, {}, {}, {})".format(
                sql_literal(r["name"]),
                sql_literal(r["default_unit"]),
                sql_literal(r["dimension"]),
                sql_literal(r["description"]),
            )
        )
    lines.append(",\n".join(qt_values) + ";")
    lines.append("")

    lines.append("-- 2. Allowed (quantity_type, unit) vocabulary")
    lines.append("INSERT INTO allowed_units (quantity_type, unit) VALUES")
    au_sorted = sorted(allowed_units, key=lambda r: (r["quantity_type"], r["unit"]))
    au_values = []
    for r in au_sorted:
        au_values.append(
            "    ({}, {})".format(
                sql_literal(r["quantity_type"]), sql_literal(r["unit"])
            )
        )
    lines.append(",\n".join(au_values) + ";")
    lines.append("")

    lines.append("-- 3. Column unit conventions")
    lines.append(
        "INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, discriminator_column, discriminator_value, description) VALUES"
    )
    uc_sorted = sorted(
        conventions,
        key=lambda r: (
            r["table_name"],
            r["column_name"],
            none_to_empty(r["discriminator_value"]),
        ),
    )
    uc_values = []
    for r in uc_sorted:
        uc_values.append(
            "    ({}, {}, {}, {}, {}, {}, {})".format(
                sql_literal(r["table_name"]),
                sql_literal(r["column_name"]),
                sql_literal(r["quantity_type"]),
                sql_literal(r["unit"]),
                sql_literal(r["discriminator_column"]),
                sql_literal(r["discriminator_value"]),
                sql_literal(r["description"]),
            )
        )
    lines.append(",\n".join(uc_values) + ";")
    lines.append("")

    lines.append("-- 4. Registry metadata (non-seal rows)")
    lines.append("INSERT INTO unit_management_metadata (key, value, description) VALUES")
    meta_rows = sorted(
        [
            (
                "convention",
                CONVENTION_VERSION,
                "Schema unit convention version",
            ),
            (
                "units_artifact",
                units_convention,
                "SiennaSchemas Core/units.json vocabulary convention this registry derives from",
            ),
        ]
    )
    meta_values = []
    for key, value, description in meta_rows:
        meta_values.append(
            "    ({}, {}, {})".format(
                sql_literal(key), sql_literal(value), sql_literal(description)
            )
        )
    lines.append(",\n".join(meta_values) + ";")
    lines.append("")

    lines.append("-- 5. Seal row -- sha256 over canonical repr of the registry.")
    lines.append(
        "-- Inserting this row activates the immutability triggers. See the"
    )
    lines.append(
        "-- module docstring of generate_unit_registry.py for the exact repr."
    )
    lines.append("INSERT INTO unit_management_metadata (key, value, description) VALUES")
    lines.append(
        "    ({}, {}, {});".format(
            sql_literal("unit_conventions_checksum"),
            sql_literal(seal),
            sql_literal(
                "Registry content fingerprint -- verify with scripts/verify_unit_registry.py"
            ),
        )
    )
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--units-json", default=DEFAULT_UNITS_JSON)
    parser.add_argument("--conventions", default=DEFAULT_CONVENTIONS)
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)

    quantity_types, allowed_units, units_convention = load_units(args.units_json)
    conventions = load_conventions(args.conventions)

    offenders = validate_pairs(conventions, allowed_units)
    if offenders:
        sys.stderr.write(
            "ERROR: column_conventions.json uses (quantity_type, unit) pairs "
            "absent from units.json allowed_units:\n"
        )
        for offender in sorted(offenders):
            sys.stderr.write("  - " + offender + "\n")
        return 1

    seal = checksum(quantity_types, allowed_units, conventions)
    content = emit(
        quantity_types, allowed_units, conventions, units_convention, seal
    )
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(content)
    sys.stderr.write(
        "Wrote {} ({} quantity_types, {} allowed_units, {} unit_conventions)\n".format(
            args.output, len(quantity_types), len(allowed_units), len(conventions)
        )
    )
    sys.stderr.write("Seal sha256: {}\n".format(seal))
    return 0


if __name__ == "__main__":
    sys.exit(main())
