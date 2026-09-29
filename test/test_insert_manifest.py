"""Tests for scripts/insert_manifest.py (SDK component -> INSERT manifest)."""

import sqlite3
import sys

import pytest

from conftest import SCHEMAS_PATH, SCRIPTS_DIR, load_schemas_json

sys.path.insert(0, str(SCRIPTS_DIR))
from check_units_sync import build_db
from insert_manifest import (
    ManifestError,
    RefResolver,
    attribute_registry,
    attribute_spec,
    build_manifest,
    component_entry,
    component_tables,
    compute_ranks,
    default_literal,
    load_inputs,
    render,
)


@pytest.fixture(scope="module")
def manifest():
    return build_manifest(str(SCHEMAS_PATH))


@pytest.fixture(scope="module")
def component_files():
    tables = component_tables(load_inputs())
    return {c["component"]: c["file"] for comps in tables.values() for c in comps}


def test_every_schema_property_is_classified_exactly_once(manifest, component_files):
    for name, entry in manifest["components"].items():
        props = set(load_schemas_json(component_files[name])["properties"])
        roots = {b["path"].split(".")[0] for b in entry["bindings"]}
        attrs = {a["field"] for a in entry["attributes"]}
        groups = [roots, attrs, set(entry["skip"]), set(entry["gaps"])]
        assert set().union(*groups) == props, name
        assert sum(len(g) for g in groups) == len(props), f"{name}: overlapping classes"


def test_first_binding_is_the_id(manifest):
    for name, entry in manifest["components"].items():
        assert entry["bindings"][0] == {"path": "id", "encode": "int"}, name


def test_placeholders_match_bindings(manifest):
    for name, entry in manifest["components"].items():
        assert entry["row_sql"].count("?") == len(entry["bindings"]), name
        assert entry["entity_sql"].count("?") == 1, name
    for section in manifest["associations"]:
        assert section["row_sql"].count("?") == len(section["bindings"])


def test_every_statement_prepares_on_a_fresh_database(manifest, db):
    statements = [manifest["attribute_sql"]]
    statements += (
        manifest["supplemental_attributes"]["plant_sql"],
        manifest["supplemental_attributes"]["attribute_sql"],
    )
    for entry in manifest["components"].values():
        statements += [entry["entity_sql"], entry["row_sql"]]
    statements += [s["row_sql"] for s in manifest["associations"]]
    for sql in statements:
        db.execute("EXPLAIN " + sql, [None] * sql.count("?"))


def test_ranks_respect_foreign_keys(manifest, db):
    rank_by_table = {e["table"]: e["rank"] for e in manifest["components"].values()}
    for table, rank in rank_by_table.items():
        for row in db.execute(f"PRAGMA foreign_key_list('{table}')"):
            ref = row[2]
            if ref in rank_by_table and ref != table:
                assert rank > rank_by_table[ref], f"{table} -> {ref}"


def test_fk_cycle_is_an_error():
    conn = sqlite3.connect(":memory:")
    conn.executescript(
        "CREATE TABLE a (id INTEGER PRIMARY KEY, b_id INTEGER REFERENCES b (id));"
        "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a (id));"
    )
    with pytest.raises(ManifestError, match="cycle"):
        compute_ranks(conn, {"a": [], "b": []})


def test_schema_default_wins_over_db_default():
    assert default_literal({"default": 5}, {"default": "7"}) == "5"
    assert default_literal({"default": "OT"}, {"default": None}) == "'OT'"
    assert default_literal({}, {"default": "7"}) == "7"
    assert default_literal({}, {"default": None}) is None


def test_defaulted_columns_coalesce(manifest):
    sql = manifest["components"]["ThermalStandard"]["row_sql"]
    assert "COALESCE(?, 'OT')" in sql
    assert "COALESCE(?, 'OTHER')" in sql


def test_constants_are_inlined(manifest):
    assert manifest["components"]["TwoTerminalLCCLine"]["row_sql"].endswith("'LCC')")
    assert manifest["components"]["TwoTerminalVSCLine"]["row_sql"].endswith("'VSC')")


def test_derived_columns_bind_json_paths(manifest):
    paths = [b["path"] for b in manifest["components"]["AreaInterchange"]["bindings"]]
    assert "flow_limits.from_to" in paths
    assert "flow_limits.to_from" in paths


def test_not_null_column_without_source_blocks_generation():
    inputs = load_inputs()
    inputs["config"]["derived"] = {}
    conn = build_db(SCHEMA_DIR)
    resolver = RefResolver(str(SCHEMAS_PATH))
    comp = {
        "component": "AreaInterchange",
        "file": "Operations/Branch/AreaInterchange.json",
    }
    registry = attribute_registry(conn, inputs["conventions"])
    with pytest.raises(ManifestError, match="max_flow_from"):
        component_entry(conn, resolver, inputs, "transmission_interchanges", comp, 0, registry)


def attributes_of(manifest, type_name):
    attributes = manifest["components"][type_name]["attributes"]
    return {a["field"]: {k: v for k, v in a.items() if k != "field"} for a in attributes}


def test_fixed_attribute_unit(manifest):
    hydro = attributes_of(manifest, "HydroTurbine")
    assert hydro["efficiency"] == {"unit": "1", "quantity_kind": "Fraction"}
    assert hydro["turbine_type"] == {"unit_free": True}


def test_discriminated_attribute_unit_has_one_arm_per_value(manifest):
    vsc = attributes_of(manifest, "TwoTerminalVSCLine")
    assert vsc["rating"] == {
        "discriminator": "power_units",
        "arms": {
            "COMPONENT_BASE": {"unit": "pu", "quantity_kind": "ApparentPower"},
            "NATURAL_UNITS": {"unit": "MVA", "quantity_kind": "ApparentPower"},
        },
    }
    # A nested discriminator; x-quantity names no kind for kV, the registry does.
    setpoint = vsc["ac_setpoint_from"]
    assert setpoint["discriminator"] == "ac_control_from"
    assert setpoint["arms"]["AC_REACTIVE_POWER"] == {"unit": "1", "quantity_kind": "PowerFactor"}
    voltage = setpoint["arms"]["AC_VOLTAGE"]
    assert voltage["discriminator"] == "setpoint_voltage_units"
    assert voltage["arms"]["NATURAL_UNITS"] == {"unit": "kV", "quantity_kind": "Voltage"}


def test_discriminator_default_is_an_arm_key(manifest):
    lcc = attributes_of(manifest, "TwoTerminalLCCLine")
    assert lcc["r"]["default"] == "NATURAL_UNITS"
    assert set(lcc["r"]["arms"]) == {"COMPONENT_BASE", "NATURAL_UNITS"}


def test_attribute_identifier_is_flagged(manifest):
    vsc = attributes_of(manifest, "TwoTerminalVSCLine")
    assert vsc["remote_bus_control_from"] == {"identifier": True}
    assert vsc["converter_loss_from"] == {"identifier": True}


REGISTRY = {
    "pairs": {"p": {("MW", "ActivePower")}},
    "allowed": {("MW", "ActivePower"), ("pu", "ActivePower")},
    "identifiers": {("T", "id_ref")},
}


@pytest.mark.parametrize(
    "prop,sql_type,match",
    [
        ({"type": "number"}, "REAL", "no unit annotation"),
        ({"type": "number", "x-unit": "MW"}, "REAL", "needs exactly one"),
        ({"type": "array"}, "JSON", "no unit annotation"),
    ],
)
def test_unclassifiable_attribute_fails_generation(prop, sql_type, match):
    with pytest.raises(ManifestError, match=match):
        attribute_spec("T", "f", {"f": prop}, sql_type, REGISTRY)


def test_unregistered_arm_fails_generation():
    props = {
        "power_units": {"type": "string"},
        "p": {"x-unit-discriminator": "power_units", "x-units": {"A": "MW", "B": "pu"},
              "x-quantity": "ActivePower"},
    }
    with pytest.raises(ManifestError, match=r"p\[B\]: register .*ActivePower/pu"):
        attribute_spec("T", "p", props, "REAL", REGISTRY)


def test_identifier_with_a_registered_unit_fails_generation():
    registry = dict(REGISTRY, identifiers={("T", "p")})
    with pytest.raises(ManifestError, match="identifier"):
        attribute_spec("T", "p", {"p": {"type": "integer"}}, "INTEGER", registry)


def test_vocabulary(manifest):
    types = {t["name"]: t for t in manifest["vocabulary"]["entity_types"]}
    assert types["ACBus"]["is_topology"] is True
    assert types["DCBus"]["is_dc"] is True
    assert "ImpedanceCorrectionData" in types
    assert "OT" in manifest["vocabulary"]["prime_mover_types"]
    assert "OTHER" in manifest["vocabulary"]["fuels"]


def test_unsupported_entries(manifest):
    assert manifest["unsupported_components"] == {}
    assert set(manifest["unsupported_sections"]) == {
        "ext",
        "service_associations",
        "time_series_associations",
    }


def test_render_is_deterministic():
    assert render(build_manifest(str(SCHEMAS_PATH))) == render(
        build_manifest(str(SCHEMAS_PATH))
    )


import json  # noqa: E402
import subprocess  # noqa: E402

from conftest import SCHEMA_DIR  # noqa: E402


def test_checked_in_manifest_is_current():
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPTS_DIR / "generate_insert_manifest.py"),
            "--schemas-path",
            str(SCHEMAS_PATH),
            "--check",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_gap_file_lists_known_gaps():
    gaps = json.loads((SCHEMA_DIR / "insert_gaps.json").read_text(encoding="utf-8"))["gaps"]
    assert "ACBus" not in gaps
    assert "available" in gaps["Line"]
