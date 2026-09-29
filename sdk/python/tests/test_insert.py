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


def test_strict_unknown_field_raises_and_rolls_back(conn):
    bus = dict(lone_bus(golden()), numbr=3)
    with pytest.raises(griddb.GapValueError, match="numbr"):
        griddb.insert_component(conn, "ACBus", bus, strict=True)
    assert count(conn, "entities") == 0


def attributes(conn, entity_id):
    rows = conn.execute(
        "SELECT name, json(value) AS value, unit, quantity_kind FROM attributes WHERE entity_id = ?",
        (entity_id,),
    )
    return {name: (json.loads(value), unit, kind) for name, value, unit, kind in rows}


def test_bus_fields_round_trip_through_attributes(conn):
    bus = lone_bus(golden())
    report = griddb.insert_component(conn, "ACBus", bus, strict=True)
    assert report.skipped_fields == {}
    stored = attributes(conn, bus["id"])
    assert stored["number"] == (bus["number"], None, None)
    assert stored["load_zone"] == (bus["load_zone"], None, None)
    assert stored["available"] == (bus["available"], None, None)
    assert stored["bustype"] == (bus["bustype"], None, None)
    assert stored["angle"] == (bus["angle"], "rad", "Angle")
    assert stored["magnitude"] == (bus["magnitude"], "pu", "Voltage")
    assert stored["voltage_limits"] == (bus["voltage_limits"], "pu", "Voltage")


def test_unsupported_type(conn):
    report = griddb.insert_components(conn, "TransmissionInterface", [{"id": 1}])
    assert report.unsupported == {"TransmissionInterface": 1}
    with pytest.raises(griddb.UnsupportedComponentError):
        griddb.insert_components(conn, "TransmissionInterface", [{"id": 1}], strict=True)


def test_rows_naming_an_unsupported_component_are_reported_not_written(conn):
    """AGC has no table, so an association row naming one, on either side, is
    counted under its section instead of failing the document."""
    doc = golden()
    thermal = first(doc, "ThermalStandard")["id"]
    agc, plant = 9001, 9002
    doc["components"]["AGC"] = [{"id": agc, "name": "agc"}]
    doc["supplemental_attributes"].append(
        {"id": plant, "name": "cc1", "configuration": "SeparateShaftCombustionSteam"}
    )
    doc["supplemental_attribute_associations"] += [
        {"component_id": c, "component_type": t, "attribute_id": plant,
         "attribute_type": "CombinedCycleBlock"}
        for c, t in [(thermal, "ThermalStandard"), (agc, "AGC")]
    ]
    doc["combined_cycle_associations"] = [
        {"plant_id": plant, "entity_id": e, "role": "CT", "hrsg_index": i}
        for i, e in enumerate([thermal, agc], start=1)
    ]
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["AGC"] == 1
    assert report.unsupported["supplemental_attribute_associations"] == 1
    assert report.unsupported["combined_cycle_associations"] == 1
    assert count(conn, "combined_cycle_associations") == 1


# The skip reads ids by the int encoder's rule, so the three SDKs agree on odd ids.
@pytest.mark.parametrize(
    "agc_id, ref, skipped",
    [
        (9001, 9001.0, True),
        ("9001", "9001", False),
        (1, True, False),
        (1e20, 1e20, False),
        (9001, [9001], False),
        (9001, {"id": 9001}, False),
    ],
)
def test_unsupported_reference_ids_follow_the_int_rule(conn, agc_id, ref, skipped):
    doc = golden()
    doc["components"]["AGC"] = [{"id": agc_id, "name": "agc"}]
    rows = doc["supplemental_attribute_associations"]
    rows.append(dict(rows[0], component_id=ref, component_type="AGC"))
    if skipped:
        report = griddb.insert_document(conn, doc)
        assert report.unsupported["supplemental_attribute_associations"] == 1
    else:
        with pytest.raises(griddb.InsertError, match="expected an integer"):
            griddb.insert_document(conn, doc)


def test_non_object_entries_of_an_unsupported_type_are_counted(conn):
    doc = golden()
    doc["components"]["AGC"] = [None, 5, [1]]
    assert griddb.insert_document(conn, doc).unsupported["AGC"] == 3


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


def test_plant_attribute_association_is_stored(conn):
    """A plant is listed in supplemental_attribute_associations like any other
    attribute, while its row lives in plants."""
    doc = golden()
    thermal_id = first(doc, "ThermalStandard")["id"]
    plant_id = 1 + max(
        [o["id"] for objs in doc["components"].values() for o in objs]
        + [a["id"] for a in doc["supplemental_attributes"]]
    )
    doc["supplemental_attributes"].append(
        {"id": plant_id, "name": "cc1", "configuration": "SeparateShaftCombustionSteam"}
    )
    doc["supplemental_attribute_associations"].append(
        {"component_id": thermal_id, "component_type": "ThermalStandard",
         "attribute_id": plant_id, "attribute_type": "CombinedCycleBlock"}
    )
    doc["combined_cycle_associations"] = [
        {"plant_id": plant_id, "entity_id": thermal_id, "role": "CT", "hrsg_index": 1}
    ]
    report = griddb.insert_document(conn, doc)
    assert report.inserted["plants"] == 1
    assert report.inserted["combined_cycle_associations"] == 1
    (linked,) = conn.execute(
        "SELECT count(*) FROM supplemental_attribute_associations WHERE attribute_id = ?",
        (plant_id,),
    ).fetchone()
    assert linked == 1


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
    assert report.skipped_fields == {}


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


POWER_ARMS = {
    "discriminator": "power_units",
    "arms": {
        "NATURAL_UNITS": {"unit": "MW", "quantity_kind": "ActivePower"},
        "COMPONENT_BASE": {"unit": "pu", "quantity_kind": "ActivePower"},
    },
}


def test_attribute_unit_follows_the_discriminator():
    unit = griddb.insert.attribute_unit
    assert unit(POWER_ARMS, {"power_units": "COMPONENT_BASE"}) == ("pu", "ActivePower")
    assert unit(POWER_ARMS, {"power_units": "NATURAL_UNITS"}) == ("MW", "ActivePower")
    assert unit(POWER_ARMS, {"power_units": "DEVICE_BASE"}) is None
    assert unit(POWER_ARMS, {}) is None
    assert unit(dict(POWER_ARMS, default="NATURAL_UNITS"), {}) == ("MW", "ActivePower")
    by_flag = {"discriminator": "mode", "arms": {"true": {"unit": "1", "quantity_kind": "Fraction"}}}
    assert unit(by_flag, {"mode": True}) == ("1", "Fraction")
    assert unit({"identifier": True}, {}) == (None, None)
    assert unit({"unit_free": True}, {}) == (None, None)


NESTED_ARMS = {
    "discriminator": "ac_control_from",
    "default": "AC_VOLTAGE",
    "arms": {
        "AC_REACTIVE_POWER": {"unit": "1", "quantity_kind": "PowerFactor"},
        "AC_VOLTAGE": {
            "discriminator": "setpoint_voltage_units",
            "default": "NATURAL_UNITS",
            "arms": {
                "NATURAL_UNITS": {"unit": "kV", "quantity_kind": "Voltage"},
                "COMPONENT_BASE": {"unit": "pu", "quantity_kind": "Voltage"},
            },
        },
    },
}


def test_attribute_unit_follows_nested_arms():
    unit = griddb.insert.attribute_unit
    leaf = {"ac_control_from": "AC_VOLTAGE", "setpoint_voltage_units": "COMPONENT_BASE"}
    assert unit(NESTED_ARMS, leaf) == ("pu", "Voltage")
    assert unit(NESTED_ARMS, {}) == ("kV", "Voltage")
    assert unit(NESTED_ARMS, {"ac_control_from": "AC_REACTIVE_POWER"}) == ("1", "PowerFactor")
    assert unit(NESTED_ARMS, {"setpoint_voltage_units": "DEVICE_BASE"}) is None


def insert_lcc_endpoints(conn, doc):
    """The golden LCC line with its arc and buses inserted, ready to insert."""
    lcc = first(doc, "TwoTerminalLCCLine")
    arc = next(a for a in doc["components"]["Arc"] if a["id"] == lcc["arc"])
    for bus_id in (arc["from_id"], arc["to_id"]):
        griddb.insert_component(conn, "ACBus", lone_bus(doc, bus_id))
    griddb.insert_component(conn, "Arc", arc)
    return lcc


def vsc(arc_id, **fields):
    """A COMPONENT_BASE VSC line: its powers are per unit on its 100 MVA base."""
    return {
        "id": 9101, "name": "vsc", "available": True, "arc": arc_id, "base_power": 100.0,
        "power_units": "COMPONENT_BASE", "active_power_flow": 1.5, "rating": 2.0, **fields,
    }


def test_vsc_dc_power_setpoints_are_reported_not_written(conn):
    arc_id = insert_lcc_endpoints(conn, golden())["arc"]
    obj = vsc(arc_id, dc_control_from="DC_POWER", dc_setpoint_from=1.5, dc_setpoint_to=1.0)
    with pytest.raises(griddb.GapValueError, match="dc_setpoint_from"):
        griddb.insert_component(conn, "TwoTerminalVSCLine", obj, strict=True)
    report = griddb.insert_component(conn, "TwoTerminalVSCLine", obj)
    skipped = {"TwoTerminalVSCLine": {"dc_setpoint_from": 1, "dc_setpoint_to": 1}}
    assert report.skipped_fields == skipped
    stored = dict(conn.execute("SELECT name, unit FROM attributes WHERE entity_id = 9101"))
    assert "dc_setpoint_from" not in stored
    assert stored["rating"] == "pu"


def test_unit_free_field_holding_a_number_is_reported_or_raises(conn):
    obj = vsc(insert_lcc_endpoints(conn, golden())["arc"], dc_control_from=1.0)
    with pytest.raises(griddb.GapValueError, match="dc_control_from"):
        griddb.insert_component(conn, "TwoTerminalVSCLine", obj, strict=True)
    report = griddb.insert_component(conn, "TwoTerminalVSCLine", obj)
    assert report.skipped_fields == {"TwoTerminalVSCLine": {"dc_control_from": 1}}


def test_unknown_discriminator_value_is_reported_or_raises(conn):
    lcc = dict(insert_lcc_endpoints(conn, golden()), parameter_units="BOGUS")
    with pytest.raises(griddb.GapValueError, match="discriminator"):
        griddb.insert_component(conn, "TwoTerminalLCCLine", lcc, strict=True)
    report = griddb.insert_component(conn, "TwoTerminalLCCLine", lcc)
    assert report.skipped_fields["TwoTerminalLCCLine"]["r"] == 1


def load(bus_id, power_units, **fields):
    return {
        "id": 9001, "name": "load", "available": True, "bus": bus_id,
        "active_power": 0.5, "reactive_power": 0.1, "base_power": 100.0,
        "power_units": power_units, "max_active_power": 0.6, "max_reactive_power": 0.2,
        **fields,
    }


@pytest.mark.parametrize(
    "power_units,active,reactive",
    [("COMPONENT_BASE", "pu", "pu"), ("NATURAL_UNITS", "MW", "MVAr")],
)
def test_load_power_follows_its_power_units(conn, power_units, active, reactive):
    bus = lone_bus(golden())
    griddb.insert_component(conn, "ACBus", bus)
    report = griddb.insert_component(conn, "PowerLoad", load(bus["id"], power_units), strict=True)
    assert report.skipped_fields == {}
    stored = attributes(conn, 9001)
    assert stored["active_power"] == (0.5, active, "ActivePower")
    assert stored["max_reactive_power"] == (0.2, reactive, "ReactivePower")
    assert stored["available"] == (True, None, None)


def test_interruptible_load_cost_is_stored_verbatim(conn):
    bus = lone_bus(golden())
    griddb.insert_component(conn, "ACBus", bus)
    cost = {
        "cost_type": "LOAD",
        "fixed": 2.0,
        "variable_operation_cost": {
            "power_units": "NATURAL_UNITS",
            "value_curve": {
                "curve_type": "INPUT_OUTPUT",
                "function_data": {"function_type": "LINEAR", "proportional_term": 30.0},
            },
        },
    }
    obj = load(bus["id"], "NATURAL_UNITS", operation_cost=cost)
    griddb.insert_component(conn, "InterruptiblePowerLoad", obj, strict=True)
    assert attributes(conn, 9001)["operation_cost"] == (cost, None, None)
