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


def _thermal(power_units, function_data, vom=None):
    curve = {
        "power_units": power_units,
        "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": function_data},
    }
    if vom is not None:
        curve["vom_cost"] = vom
    return {
        "components": {
            "ThermalStandard": [
                {
                    "id": 1,
                    "base_power": 100.0,
                    "operation_cost": {"variable_operation_cost": curve},
                }
            ]
        }
    }


def test_quadratic_cost_is_rescaled_to_natural_units():
    data = {
        "function_type": "QUADRATIC",
        "constant_term": 3.0,
        "proportional_term": 200.0,
        "quadratic_term": 50000.0,
    }
    vom = {
        "curve_type": "INPUT_OUTPUT",
        "function_data": {"function_type": "LINEAR", "proportional_term": 100.0},
    }
    out = _load_prepare().convert(_thermal("COMPONENT_BASE", data, vom))
    curve = out["components"]["ThermalStandard"][0]["operation_cost"][
        "variable_operation_cost"
    ]
    assert curve["power_units"] == "NATURAL_UNITS"
    assert curve["value_curve"]["function_data"]["constant_term"] == 3.0
    assert curve["value_curve"]["function_data"]["proportional_term"] == 2.0
    assert curve["value_curve"]["function_data"]["quadratic_term"] == 5.0
    assert curve["vom_cost"]["function_data"]["proportional_term"] == 1.0


def test_natural_units_cost_is_untouched():
    data = {"function_type": "LINEAR", "proportional_term": 7.0, "constant_term": 0.0}
    doc = _thermal("NATURAL_UNITS", data)
    assert _load_prepare().convert(doc) == doc


def test_unsupported_cost_shape_raises():
    data = {"function_type": "PIECEWISE_LINEAR", "points": []}
    with pytest.raises(ValueError, match="PIECEWISE_LINEAR"):
        _load_prepare().convert(_thermal("COMPONENT_BASE", data))


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
