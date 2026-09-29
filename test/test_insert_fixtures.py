"""Tests for the golden insert fixtures and the parity tooling.

The fixtures are generated on the fly into the gitignored test/fixtures/insert/
by test/prepare_fixtures.py; nothing under fixtures/ is checked in.
"""

import importlib.util
import json
import sqlite3
import subprocess
import sys

import pytest

from conftest import REPO_ROOT, SCRIPTS_DIR, build_database

sys.path.insert(0, str(SCRIPTS_DIR))
from canonical_dump import dump, normalize

GENERATOR = REPO_ROOT / "test" / "prepare_fixtures.py"
FIXTURES = REPO_ROOT / "test" / "fixtures" / "insert"


def _load_prepare():
    spec = importlib.util.spec_from_file_location("prepare_fixtures", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sdk_fixtures_or_skip(prepare):
    try:
        return prepare.find_sdk_fixtures()
    except FileNotFoundError:
        pytest.skip("power-openapi-models checkout not found")


def test_golden_fixtures_are_current():
    prepare = _load_prepare()
    sdk = _sdk_fixtures_or_skip(prepare)
    prepare.ensure_generated(sdk)
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--sdk-fixtures-path", sdk, "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_normalize_treats_json_ints_and_floats_alike():
    assert normalize('{"b":1,"a":[2]}') == normalize('{"a": [2.0], "b": 1.0}')
    assert normalize(3) == 3
    assert normalize("text") == "text"


def test_dump_keeps_entity_ids_and_drops_surrogate_ids(tmp_path):
    path = build_database(tmp_path / "d.sqlite")
    conn = sqlite3.connect(str(path))
    conn.execute("INSERT INTO entity_types (name) VALUES ('X')")
    conn.execute(
        "INSERT INTO entities (id, entity_table, entity_type) VALUES (7, 't', 'X')"
    )
    conn.commit()
    conn.close()
    out = json.loads(dump(str(path)))
    assert "id" in out["entities"]["columns"]
    assert out["entities"]["rows"] == [[7, "t", "X"]]
    assert "id" not in out["attributes"]["columns"]
    assert "id" in out["balancing_topologies"]["columns"]
    assert "unit_conventions" not in out


def test_sdk_data_bundles_match_schema_dir():
    result = subprocess.run(
        [sys.executable, str(SCRIPTS_DIR / "sync_sdk_data.py"), "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
