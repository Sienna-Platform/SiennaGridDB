"""Create, open, and seed GridDB databases."""

import os
import sqlite3

from .errors import DatabaseExistsError, ManifestMismatchError, SQLiteVersionError
from .manifest import data_text, load_manifest

MIN_SQLITE = (3, 45, 0)
SCHEMA_FILES = ("schema.sql", "triggers.sql", "unit_registry.sql", "views.sql")


def _connect(path):
    if sqlite3.sqlite_version_info < MIN_SQLITE:
        raise SQLiteVersionError(
            f"SQLite {sqlite3.sqlite_version} is older than the required 3.45.0"
        )
    conn = sqlite3.connect(path, isolation_level=None)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def open_database(path):
    conn = _connect(path)
    found = conn.execute("PRAGMA user_version").fetchone()[0]
    expected = load_manifest().schema_user_version
    if found != expected:
        conn.close()
        raise ManifestMismatchError(
            f"{path} has user_version {found}; this package writes schema version {expected}"
        )
    return conn


def seed_vocabulary(conn):
    vocab = load_manifest().vocabulary
    conn.executemany(
        "INSERT OR IGNORE INTO entity_types (name, is_topology, is_dc) VALUES (?, ?, ?)",
        [
            (t["name"], int(t["is_topology"]), int(t["is_dc"]))
            for t in vocab["entity_types"]
        ],
    )
    for table, names in vocab.items():
        if table == "entity_types":
            continue
        conn.executemany(
            f"INSERT OR IGNORE INTO {table} (name) VALUES (?)", [(n,) for n in names]
        )


def create_database(path):
    if os.path.exists(path):
        raise DatabaseExistsError(
            f"{path} already exists; create_database never overwrites"
        )
    conn = _connect(path)
    for name in SCHEMA_FILES:
        conn.executescript(data_text(name))
    seed_vocabulary(conn)
    return conn
