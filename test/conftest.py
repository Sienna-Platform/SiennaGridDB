"""Shared fixtures for the unit-registry test suite.

The database is built purely with Python's ``sqlite3`` by ``executescript``-ing
the four schema files in order, with ``PRAGMA foreign_keys = ON``. No sqlite3
CLI dependency (Phase 2 removed it).
"""

import shutil
import sqlite3
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_DIR = REPO_ROOT / "schema"
SCRIPTS_DIR = REPO_ROOT / "scripts"

# Order matters: schema (tables) -> triggers -> registry seed (+ seal) -> views.
SCHEMA_FILES = [
    SCHEMA_DIR / "schema.sql",
    SCHEMA_DIR / "triggers.sql",
    SCHEMA_DIR / "unit_registry.sql",
    SCHEMA_DIR / "views.sql",
]


def build_database(path):
    """Build a fresh sealed database at ``path`` from the four schema files."""
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA foreign_keys = ON")
    for sql_file in SCHEMA_FILES:
        conn.executescript(sql_file.read_text())
    conn.commit()
    conn.close()
    return path


def open_connection(path):
    """Open a connection with foreign keys enforced (as production drivers do)."""
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


@pytest.fixture(scope="session")
def built_db_path(tmp_path_factory):
    """A single sealed database, built once per session (read-only tests)."""
    path = tmp_path_factory.mktemp("built_db") / "griddb.sqlite"
    return build_database(path)


@pytest.fixture(scope="session")
def db(built_db_path):
    """A read-only connection to the session database.

    Tests that use this fixture MUST NOT mutate the registry; use the
    ``fresh_db`` fixture for destructive work.
    """
    conn = open_connection(built_db_path)
    yield conn
    conn.close()


@pytest.fixture
def fresh_db_path(built_db_path, tmp_path):
    """A private, writable file copy of the session database, per test.

    File-copy of the already-built DB avoids re-running the four scripts for
    every destructive test while still isolating mutations.
    """
    path = tmp_path / "fresh.sqlite"
    shutil.copyfile(str(built_db_path), str(path))
    return path


@pytest.fixture
def fresh_db(fresh_db_path):
    """A writable connection to a private per-test copy of the database."""
    conn = open_connection(fresh_db_path)
    yield conn
    conn.close()
