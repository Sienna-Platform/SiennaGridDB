#!/usr/bin/env python3
"""Shared helpers for the SiennaGridDB unit-registry / schema-codegen scripts.

Imported by generate_unit_registry.py, verify_unit_registry.py,
generate_sql_schema.py and check_units_sync.py via a same-directory import
(``from _common import ...``); the script's own directory is on sys.path when a
script is run as ``python scripts/x.py``.

CANONICAL CHECKSUM REPRESENTATION
---------------------------------
The seal row ``unit_management_metadata.unit_conventions_checksum`` stores the
sha256 hex digest of a canonical byte representation built from the content of
four tables: quantity_types, allowed_units, unit_conventions, unit_basis_rules.

Field / row / table separators (ASCII control chars, chosen so they cannot
appear in any legitimate field value):
    US  = '\x1f'  (unit separator)   -- between fields within a row
    RS  = '\x1e'  (record separator) -- between rows within a table
    GS  = '\x1d'  (group separator)  -- between the four table blocks

Per-table row field order (NULLs rendered as the empty string):
    quantity_types    : name, default_unit, dimension, description
    allowed_units     : quantity_type, unit
    unit_conventions  : table_name, column_name, quantity_type, unit,
                        discriminator_column, discriminator_value,
                        discriminator_column_2, discriminator_value_2,
                        base_power_ref, base_voltage_ref, description
    unit_basis_rules  : quantity_type, base_expression, description

Rows within each table are sorted (ascending, Python default tuple sort) by the
tuple of their fields in the order listed above. Field values are joined with
US, rows joined with RS. The four table blocks (quantity_types, allowed_units,
unit_conventions, unit_basis_rules -- in that fixed order) are joined with GS.
The result is UTF-8 encoded and hashed with hashlib.sha256; the hex digest is
the seal.
"""

import json

US = "\x1f"
RS = "\x1e"
GS = "\x1d"


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def none_to_empty(value):
    if value is None:
        return ""
    return value


def repr_from_rows(qt_rows, au_rows, uc_rows, ub_rows):
    """Build the canonical checksum string from four lists of field tuples.

    Each argument is an iterable of tuples with fields already in the canonical
    order (NULLs already rendered via none_to_empty). Rows are sorted here.
    """
    qt_sorted = sorted(qt_rows)
    au_sorted = sorted(au_rows)
    uc_sorted = sorted(uc_rows)
    ub_sorted = sorted(ub_rows)
    qt_block = RS.join(US.join(row) for row in qt_sorted)
    au_block = RS.join(US.join(row) for row in au_sorted)
    uc_block = RS.join(US.join(row) for row in uc_sorted)
    ub_block = RS.join(US.join(row) for row in ub_sorted)
    return GS.join([qt_block, au_block, uc_block, ub_block])


def sql_literal(value):
    """SQL literal for str/None/bool/int/float/dict-or-list.

    bool before int (bool is an int subclass). Dicts/lists render as canonical
    compact sorted JSON text. Strings single-quote-escaped.
    """
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return (
        "'"
        + json.dumps(value, sort_keys=True, separators=(",", ":")).replace("'", "''")
        + "'"
    )
