#!/usr/bin/env python3
"""Verify a built database's unit registry against its stored seal.

Recomputes the canonical sha256 from the LIVE contents of quantity_types,
allowed_units and unit_conventions, and compares it to the stored
unit_management_metadata.unit_conventions_checksum row.

The canonical representation MUST match generate_unit_registry.py exactly:

    US = '\x1f' between fields, RS = '\x1e' between rows, GS = '\x1d' between
    the three table blocks. NULLs render as the empty string. Rows are sorted
    by their field tuple. Table blocks are joined in the fixed order
    quantity_types, allowed_units, unit_conventions. See the generator's module
    docstring for the authoritative spec.

Usage: verify_unit_registry.py <database-path>
Exit 0 on match, 1 on mismatch or missing seal.
"""

import hashlib
import sqlite3
import sys

from _common import none_to_empty, repr_from_rows


def fetch_repr(conn):
    cur = conn.cursor()

    cur.execute(
        "SELECT name, default_unit, dimension, description FROM quantity_types"
    )
    qt_rows = (
        (
            row[0],
            row[1],
            row[2],
            none_to_empty(row[3]),
        )
        for row in cur.fetchall()
    )

    cur.execute("SELECT quantity_type, unit FROM allowed_units")
    au_rows = ((row[0], row[1]) for row in cur.fetchall())

    cur.execute(
        "SELECT table_name, column_name, quantity_type, unit, "
        "discriminator_column, discriminator_value, description "
        "FROM unit_conventions"
    )
    uc_rows = (
        (
            row[0],
            row[1],
            row[2],
            row[3],
            none_to_empty(row[4]),
            none_to_empty(row[5]),
            none_to_empty(row[6]),
        )
        for row in cur.fetchall()
    )

    return repr_from_rows(qt_rows, au_rows, uc_rows)


def stored_seal(conn):
    cur = conn.cursor()
    cur.execute(
        "SELECT value FROM unit_management_metadata "
        "WHERE key = 'unit_conventions_checksum'"
    )
    row = cur.fetchone()
    if row is None:
        return None
    return row[0]


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("Usage: verify_unit_registry.py <database-path>\n")
        return 1
    db_path = argv[1]
    conn = sqlite3.connect(db_path)
    try:
        expected = stored_seal(conn)
        if expected is None:
            sys.stderr.write(
                "MISMATCH: no unit_conventions_checksum row (registry unsealed)\n"
            )
            return 1
        actual = hashlib.sha256(fetch_repr(conn).encode("utf-8")).hexdigest()
    finally:
        conn.close()

    if actual == expected:
        sys.stdout.write("MATCH: registry checksum {}\n".format(actual))
        return 0
    sys.stderr.write(
        "MISMATCH: stored {} != recomputed {}\n".format(expected, actual)
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
