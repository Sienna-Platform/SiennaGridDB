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
four tables: quantity_kinds, allowed_units, unit_conventions, unit_basis_rules.

Field / row / table separators (ASCII control chars, chosen so they cannot
appear in any legitimate field value):
    US  = '\x1f'  (unit separator)   -- between fields within a row
    RS  = '\x1e'  (record separator) -- between rows within a table
    GS  = '\x1d'  (group separator)  -- between the four table blocks

Per-table row field order (NULLs rendered as the empty string):
    quantity_kinds    : name, default_unit, dimension, description
    allowed_units     : quantity_kind, unit
    unit_conventions  : table_name, column_name, quantity_kind, unit,
                        discriminator_column, discriminator_value,
                        discriminator_column_2, discriminator_value_2,
                        base_power_ref, base_voltage_ref, description
    unit_basis_rules  : quantity_kind, base_expression, description

Rows within each table are sorted (ascending, Python default tuple sort) by the
tuple of their fields in the order listed above. Field values are joined with
US, rows joined with RS. The four table blocks (quantity_kinds, allowed_units,
unit_conventions, unit_basis_rules -- in that fixed order) are joined with GS.
The result is UTF-8 encoded and hashed with hashlib.sha256; the hex digest is
the seal.
"""

import json
import math
import os
import sys

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
    return "'" + canonical_json(value).replace("'", "''") + "'"


# A copy of sdk/python's canonical_json: the release tarball ships scripts/ without sdk/.
# test/canonical_json_vectors.json holds both copies to the same text.
def canonical_json(value):
    """RFC 8785 (JCS) text, the form the SDKs write: keys in UTF-16 code-unit order,
    numbers as ECMAScript writes them (1.0 -> 1), no whitespace."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical_json(v) for v in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: k.encode("utf-16-be"))
        items = (json.dumps(k, ensure_ascii=False) + ":" + canonical_json(value[k]) for k in keys)
        return "{" + ",".join(items) + "}"
    raise ValueError(f"not a JSON value: {value!r}")


def _number(x):
    """ECMAScript Number::toString, from the shortest round-trip digits repr gives."""
    if not math.isfinite(x):
        raise ValueError(f"{x!r}: not a finite number")
    if x == 0:
        return "0"
    sign = "-" if x < 0 else ""
    mantissa, _, exponent = repr(abs(x)).partition("e")
    whole, _, fraction = mantissa.partition(".")
    all_digits = whole + fraction
    digits = all_digits.lstrip("0")
    # n: where the decimal point sits relative to the first significant digit.
    n = len(whole) + int(exponent or 0) - (len(all_digits) - len(digits))
    digits = digits.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * -n + digits
    e = n - 1
    mark = "+" if e >= 0 else "-"
    if k == 1:
        return f"{sign}{digits}e{mark}{abs(e)}"
    return f"{sign}{digits[0]}.{digits[1:]}e{mark}{abs(e)}"


def write_or_check(outputs, check, hint):
    """Write each {path: str|bytes}, or with check=True report stale paths. Returns an exit code."""
    stale = []
    for path, content in outputs.items():
        data = content.encode("utf-8") if isinstance(content, str) else content
        if check:
            current = None
            if os.path.exists(path):
                with open(path, "rb") as handle:
                    current = handle.read()
            if current != data:
                stale.append(path)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
    if stale:
        sys.stderr.write(f"stale ({hint}): " + ", ".join(stale) + "\n")
        return 1
    return 0
