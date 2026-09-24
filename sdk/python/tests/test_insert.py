import copy
import json
import subprocess
import sys
from pathlib import Path

import pytest

import sienna_griddb_tools as griddb

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPO_ROOT / "test" / "fixtures" / "insert"
CASES = ("NATURAL_UNITS", "COMPONENT_BASE")
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "test"))
from canonical_dump import dump  # noqa: E402
import prepare_fixtures  # noqa: E402


def sdk_repo():
    """CI checks power-openapi-models out nested; locally it is a sibling."""
    for candidate in (
        REPO_ROOT / "power-openapi-models",
        REPO_ROOT.parent / "power-openapi-models",
    ):
        if candidate.exists():
            return candidate
    return REPO_ROOT.parent / "power-openapi-models"


def ensure_fixtures():
    """Golden fixtures are generated on the fly and gitignored."""
    try:
        prepare_fixtures.ensure_generated()
    except FileNotFoundError:
        pytest.skip("power-openapi-models checkout not found")


def golden(case="NATURAL_UNITS"):
    ensure_fixtures()
    return json.loads((FIXTURES / f"case14_{case}.json").read_text(encoding="utf-8"))


def first(doc, type_name):
    return copy.deepcopy(doc["components"][type_name][0])


def lone_bus(doc, bus_id=None):
    """A golden bus with its area reference removed, so it inserts on its own."""
    buses = doc["components"]["ACBus"]
    bus = copy.deepcopy(buses[0])
    if bus_id is not None:
        bus = copy.deepcopy(next(b for b in buses if b["id"] == bus_id))
    bus.pop("area", None)
    return bus


def count(conn, table):
    return conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]


@pytest.fixture
def conn(tmp_path):
    c = griddb.create_database(str(tmp_path / "t.sqlite"))
    yield c
    c.close()


@pytest.mark.parametrize("case", CASES)
def test_golden_document_matches_expected_outputs(tmp_path, case):
    path = str(tmp_path / "g.sqlite")
    c = griddb.create_database(path)
    report = griddb.insert_document(c, golden(case))
    c.close()
    expected = json.loads((FIXTURES / f"case14_{case}.report.json").read_text("utf-8"))
    assert report.to_dict() == expected
    assert dump(path) == (FIXTURES / f"case14_{case}.dump.json").read_text("utf-8")


def test_bus_then_generator(conn):
    doc = golden()
    thermal = first(doc, "ThermalStandard")
    griddb.insert_component(conn, "ACBus", lone_bus(doc, thermal["bus"]))
    report = griddb.insert_component(conn, "ThermalStandard", thermal)
    assert report.inserted == {"ThermalStandard": 1}
    assert count(conn, "thermal_generators") == 1


def test_strict_gap_raises_and_rolls_back(conn):
    with pytest.raises(griddb.GapValueError, match="angle"):
        griddb.insert_component(conn, "ACBus", lone_bus(golden()), strict=True)
    assert count(conn, "entities") == 0


def test_unsupported_type(conn):
    report = griddb.insert_components(conn, "LoadZone", [{"id": 1}])
    assert report.unsupported == {"LoadZone": 1}
    with pytest.raises(griddb.UnsupportedComponentError):
        griddb.insert_components(conn, "LoadZone", [{"id": 1}], strict=True)


def test_component_base_cost_is_rejected(conn):
    raw_path = sdk_repo() / "fixtures" / "case14_operations.NATURAL_UNITS.json"
    if not raw_path.exists():
        pytest.skip("power-openapi-models checkout not found")
    raw = json.loads(raw_path.read_text("utf-8"))
    thermal = first(raw, "ThermalStandard")
    griddb.insert_component(conn, "ACBus", lone_bus(raw, thermal["bus"]))
    with pytest.raises(griddb.InsertError, match="NATURAL_UNITS"):
        griddb.insert_component(conn, "ThermalStandard", thermal)


# Review Focus 1
def test_duplicate_id_across_types_rolls_back_document(conn):
    doc = golden()
    bus = lone_bus(doc)
    area = dict(first(doc, "Area"), id=bus["id"])
    with pytest.raises(griddb.InsertError, match="ACBus id="):
        griddb.insert_document(conn, {"components": {"ACBus": [bus], "Area": [area]}})
    assert count(conn, "entities") == 0


# Review Focus 2
def test_dangling_bus_reference_rolls_back_document(conn):
    thermal = dict(first(golden(), "ThermalStandard"), bus=999999)
    with pytest.raises(griddb.InsertError, match=r"ThermalStandard id=.*FOREIGN KEY"):
        griddb.insert_document(conn, {"components": {"ThermalStandard": [thermal]}})
    assert count(conn, "entities") == 0


# Review Focus 3
def test_integral_float_ids_are_integers(conn):
    bus = dict(lone_bus(golden()), id=5.0)
    griddb.insert_component(conn, "ACBus", bus)
    assert conn.execute("SELECT typeof(id), id FROM entities").fetchone() == ("integer", 5)
    with pytest.raises(griddb.InsertError, match="expected an integer"):
        griddb.insert_component(conn, "Arc", {"id": 6, "from_id": 1.5, "to_id": 5})


# Review Focus 4
def test_reinserting_a_document_fails_and_keeps_the_first_copy(tmp_path):
    path = str(tmp_path / "r.sqlite")
    c = griddb.create_database(path)
    griddb.insert_document(c, golden())
    before = dump(path)
    with pytest.raises(griddb.InsertError):
        griddb.insert_document(c, golden())
    c.close()
    assert dump(path) == before


# Review Focus 5
def test_misspelled_field(conn):
    report = griddb.insert_component(conn, "Area", {"id": 900, "name": "a", "numbr": 3})
    assert report.skipped_fields == {"Area": {"numbr": 1}}
    with pytest.raises(griddb.GapValueError, match="numbr"):
        griddb.insert_component(
            conn, "Area", {"id": 901, "name": "b", "numbr": 3}, strict=True
        )
    report = griddb.insert_component(conn, "Area", {"id": 902, "name": "c", "numbr": None})
    assert report.skipped_fields == {}


def test_insert_model_with_sdk_objects(conn):
    sdk_src = sdk_repo() / "python" / "src"
    if sdk_src.exists():
        sys.path.insert(0, str(sdk_src))
    models = pytest.importorskip("power_openapi_models.core.models")
    report = griddb.insert_model(
        conn, models.ACBus(id=1, name="b", number=1, available=True)
    )
    assert report.inserted == {"ACBus": 1}
    assert report.skipped_fields == {"ACBus": {"available": 1, "number": 1}}


def test_cli_build_prints_the_report(tmp_path):
    ensure_fixtures()
    out = tmp_path / "cli.sqlite"
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "sienna_griddb_tools",
            "build",
            str(FIXTURES / "case14_NATURAL_UNITS.json"),
            str(out),
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    expected = json.loads(
        (FIXTURES / "case14_NATURAL_UNITS.report.json").read_text("utf-8")
    )
    assert json.loads(result.stdout) == expected
