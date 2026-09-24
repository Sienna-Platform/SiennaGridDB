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
    with pytest.raises(ManifestError, match="max_flow_from"):
        component_entry(conn, resolver, inputs, "transmission_interchanges", comp, 0, {})


def test_attribute_units(manifest):
    lcc = {
        a["field"]: a for a in manifest["components"]["TwoTerminalLCCLine"]["attributes"]
    }
    assert lcc["rectifier_rc"]["unit"] is None
    hydro = {a["field"]: a for a in manifest["components"]["HydroTurbine"]["attributes"]}
    assert hydro["efficiency"]["unit"] == "1"
    assert hydro["efficiency"]["quantity_kind"] == "Fraction"


def test_vocabulary(manifest):
    types = {t["name"]: t for t in manifest["vocabulary"]["entity_types"]}
    assert types["ACBus"]["is_topology"] is True
    assert types["DCBus"]["is_dc"] is True
    assert "ImpedanceCorrectionData" in types
    assert "OT" in manifest["vocabulary"]["prime_mover_types"]
    assert "OTHER" in manifest["vocabulary"]["fuels"]


def test_unsupported_entries(manifest):
    assert "LoadZone" in manifest["unsupported_components"]
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
    assert "number" in gaps["ACBus"]
    assert "available" in gaps["Line"]
