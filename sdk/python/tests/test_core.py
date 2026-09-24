import json
import sqlite3

import pytest

from sienna_griddb_tools import (
    DatabaseExistsError,
    InsertReport,
    ManifestMismatchError,
    create_database,
    open_database,
    seed_vocabulary,
)
from sienna_griddb_tools.encode import EncodeError, encode, value_at
from sienna_griddb_tools.manifest import load_manifest


def test_int_encoding_accepts_integral_floats():
    assert encode("int", 3) == 3
    assert encode("int", 5.0) == 5
    with pytest.raises(EncodeError):
        encode("int", 1.5)
    with pytest.raises(EncodeError):
        encode("int", True)


def test_other_encodings():
    assert encode("real", 2) == 2.0
    with pytest.raises(EncodeError):
        encode("real", "1")
    assert encode("bool", False) == 0
    with pytest.raises(EncodeError):
        encode("bool", 1)
    assert encode("text", "x") == "x"
    assert encode("json", {"b": 1, "a": "é"}) == '{"a":"é","b":1}'
    assert encode("text", None) is None


def test_value_at():
    obj = {"a": {"b": 2}, "c": None}
    assert value_at(obj, "a.b") == 2
    assert value_at(obj, "a.z") is None
    assert value_at(obj, "c.d") is None


def test_report_merge_and_json():
    a = InsertReport()
    a.add_inserted("ACBus")
    a.add_skipped("ACBus", "number")
    b = InsertReport()
    b.add_inserted("ACBus", 2)
    b.add_unsupported("LoadZone", 1)
    a.merge(b)
    assert json.loads(a.to_json()) == {
        "inserted": {"ACBus": 3},
        "skipped_fields": {"ACBus": {"number": 1}},
        "unsupported": {"LoadZone": 1},
    }


def test_manifest_loads():
    manifest = load_manifest()
    assert "ThermalStandard" in manifest.components
    assert "bus" in manifest.components["ThermalStandard"].known_fields


def test_create_database_seeds_vocabulary(tmp_path):
    conn = create_database(str(tmp_path / "a.sqlite"))
    n = conn.execute("SELECT count(*) FROM entity_types").fetchone()[0]
    assert n == len(load_manifest().vocabulary["entity_types"])
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    seed_vocabulary(conn)
    assert conn.execute("SELECT count(*) FROM entity_types").fetchone()[0] == n


def test_create_database_refuses_existing_path(tmp_path):
    path = tmp_path / "a.sqlite"
    path.write_bytes(b"")
    with pytest.raises(DatabaseExistsError):
        create_database(str(path))


def test_open_database_checks_user_version(tmp_path):
    path = str(tmp_path / "a.sqlite")
    create_database(path).close()
    conn = open_database(path)
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    conn.close()
    raw = sqlite3.connect(path)
    raw.execute("PRAGMA user_version = 99")
    raw.close()
    with pytest.raises(ManifestMismatchError):
        open_database(path)
