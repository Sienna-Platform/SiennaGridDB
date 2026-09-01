"""Tests for scripts/generate_sql_schema.py (JSON Schema -> SQL codegen)."""

import json
import sqlite3
import subprocess
import sys

import pytest

# SCHEMAS_PATH is passed explicitly to codegen subprocesses so they never fall
# back to a default that does not exist in the CI layout (conftest resolves
# nested vs sibling).
from conftest import SCHEMA_DIR, SCHEMAS_PATH, SCRIPTS_DIR, load_schemas_json

sys.path.insert(0, str(SCRIPTS_DIR))
from generate_sql_schema import units_comment

GENERATE_SCRIPT = SCRIPTS_DIR / "generate_sql_schema.py"
GENERATED_SQL = SCHEMA_DIR / "generated_schema.sql"
SCHEMA_MAP = SCHEMA_DIR / "schema_map.json"
CODEGEN_MAP = SCHEMA_DIR / "sql_codegen_map.json"


@pytest.fixture(scope="module")
def generated_db():
    conn = sqlite3.connect(":memory:")
    conn.executescript(GENERATED_SQL.read_text(encoding="utf-8"))
    yield conn
    conn.close()


def test_generated_sql_builds_clean(generated_db):
    tables = {
        row[0]
        for row in generated_db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    mapped = set(json.loads(SCHEMA_MAP.read_text(encoding="utf-8"))["tables"])
    assert mapped <= tables


def test_generated_sql_is_not_stale():
    result = subprocess.run(
        [sys.executable, str(GENERATE_SCRIPT), "--schemas-path", SCHEMAS_PATH,
         "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_diff_reports_no_type_mismatches():
    result = subprocess.run(
        [sys.executable, str(GENERATE_SCRIPT), "--schemas-path", SCHEMAS_PATH,
         "--diff"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_generated_table_has_entity_id_pk(generated_db):
    mapped = json.loads(SCHEMA_MAP.read_text(encoding="utf-8"))["tables"]
    for table in mapped:
        info = generated_db.execute(f"PRAGMA table_info({table})").fetchall()
        pk_cols = [row[1] for row in info if row[5] == 1]
        assert pk_cols == ["id"], f"{table} PK is {pk_cols}"


def test_attribute_channel_properties_not_columns(generated_db):
    """Properties routed to the attributes table must not appear as columns."""
    codegen = json.loads(CODEGEN_MAP.read_text(encoding="utf-8"))["tables"]
    for table, cfg in codegen.items():
        channel = cfg.get("attribute_channel", [])
        if not channel:
            continue
        cols = {
            row[1]
            for row in generated_db.execute(f"PRAGMA table_info({table})").fetchall()
        }
        leaked = cols & set(channel)
        assert not leaked, f"{table}: attribute-channel properties as columns: {leaked}"


def test_branch_parameters_are_first_class_columns(fresh_db):
    """r/x/b/g are first-class transmission_lines columns, each stored flexibly in
    per-unit (component base) OR natural units, recorded per row by unit_basis.
    Under STRICT, r/x are REAL and b/g are TEXT (json_valid-checked FromTo halves)."""
    cols = {
        row[1]: row[2]
        for row in fresh_db.execute("PRAGMA table_info(transmission_lines)")
    }
    assert cols["r"] == "REAL"
    assert cols["x"] == "REAL"
    assert cols["b"] == "TEXT"
    assert cols["g"] == "TEXT"

    registered = set(
        fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_type, unit "
            "FROM unit_conventions WHERE table_name = 'transmission_lines' "
            "AND column_name IN ('r', 'x', 'b', 'g') "
            "AND discriminator_column = 'unit_basis'"
        ).fetchall()
    )
    assert registered == {
        ("r", "COMPONENT_BASE", "Resistance", "pu"),
        ("r", "NATURAL_UNITS", "Resistance", "ohm"),
        ("x", "COMPONENT_BASE", "Reactance", "pu"),
        ("x", "NATURAL_UNITS", "Reactance", "ohm"),
        ("b", "COMPONENT_BASE", "Susceptance", "pu"),
        ("b", "NATURAL_UNITS", "Susceptance", "S"),
        ("g", "COMPONENT_BASE", "Conductance", "pu"),
        ("g", "NATURAL_UNITS", "Conductance", "S"),
    }


def test_branch_parameter_pu_pairs_in_vocabulary(fresh_db):
    """The pu pairs seeded from units.json exist in allowed_units."""
    pairs = set(
        fresh_db.execute(
            "SELECT quantity_type, unit FROM allowed_units WHERE unit IN ('pu', 'pu/min')"
        ).fetchall()
    )
    assert pairs == {
        ("Resistance", "pu"),
        ("Reactance", "pu"),
        ("Susceptance", "pu"),
        ("Conductance", "pu"),
        ("Voltage", "pu"),
        ("ActivePower", "pu"),
        ("ReactivePower", "pu"),
        ("ApparentPower", "pu"),
        ("ActivePowerChangeRate", "pu/min"),
    }


def test_branch_parameter_columns_store_values(fresh_db):
    """End to end on the production build: pu values persist in the columns."""
    from test_unit_registry import make_entity

    def _arc(line_id):
        # transmission_lines.arc_id/continuous_rating are NOT NULL; provision a
        # valid arc (entity + two distinct endpoints) for each line.
        arc, a, b = line_id * 100 + 1, line_id * 100 + 2, line_id * 100 + 3
        make_entity(fresh_db, arc, entity_table="arcs")
        # arc endpoints must be topology-type entities (is_topology = 1).
        fresh_db.execute("INSERT OR IGNORE INTO entity_types(name, is_topology) VALUES ('bus', 1)")
        for eid in (a, b):
            fresh_db.execute(
                "INSERT INTO entities(id, entity_table, entity_type) "
                "VALUES (?, 'balancing_topologies', 'bus')",
                (eid,),
            )
        fresh_db.execute("INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)", (arc, a, b))
        return arc

    make_entity(fresh_db, 1, entity_table="transmission_lines", entity_type="Line")
    fresh_db.execute(
        "INSERT INTO transmission_lines (id, name, arc_id, continuous_rating, r, x, b, g) "
        "VALUES (1, 'line1', ?, 100.0, 0.01, 0.1, "
        "json('{\"from\": 0.005, \"to\": 0.005}'), "
        "json('{\"from\": 0.0, \"to\": 0.0}'))",
        (_arc(1),),
    )
    row = fresh_db.execute(
        "SELECT r, x, json_extract(b, '$.from'), json_extract(g, '$.to') "
        "FROM transmission_lines WHERE id = 1"
    ).fetchone()
    assert row == (0.01, 0.1, 0.005, 0.0)
    # Use a FRESH id (id=1 already exists above) so the raised IntegrityError is
    # the CHECK (r >= 0) bound being violated, not a duplicate-primary-key clash.
    # arc_id/continuous_rating/x are NOT NULL, so supply them and leave r negative.
    make_entity(fresh_db, 2, entity_table="transmission_lines", entity_type="Line")
    with pytest.raises(sqlite3.IntegrityError, match="r >= 0"):
        fresh_db.execute(
            "INSERT INTO transmission_lines (id, name, arc_id, continuous_rating, r, x) "
            "VALUES (2, 'line2', ?, 100.0, -0.5, 0.1)",
            (_arc(2),),
        )


def test_discrete_controlled_ac_branches_columns_and_units(fresh_db):
    """r/x are first-class discrete_controlled_ac_branches columns (pu -- this
    component has no natural-units option in PSY, unlike transmission_lines),
    registered in unit_conventions with no discriminator. rating is stored
    flexibly per power_units, asserted separately below. base_power is the
    per-row system-base snapshot r/x normalize against, mirroring transmission_lines."""
    cols = {
        row[1]: row[2]
        for row in fresh_db.execute("PRAGMA table_info(discrete_controlled_ac_branches)")
    }
    assert cols["r"] == "REAL"
    assert cols["x"] == "REAL"
    assert cols["rating"] == "REAL"
    assert cols["base_power"] == "REAL"
    assert cols["power_units"] == "TEXT"
    assert cols["discrete_branch_type"] == "TEXT"
    assert cols["branch_status"] == "TEXT"
    assert cols["normal_branch_status"] == "TEXT"

    registered = set(
        fresh_db.execute(
            "SELECT column_name, quantity_type, unit FROM unit_conventions "
            "WHERE table_name = 'discrete_controlled_ac_branches' "
            "AND discriminator_column IS NULL"
        ).fetchall()
    )
    assert registered == {
        ("r", "Resistance", "pu"),
        ("x", "Reactance", "pu"),
        ("base_power", "ApparentPower", "MVA"),
    }

    assert {
        (col, disc): (qt, unit)
        for col, disc, qt, unit in fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_type, unit "
            "FROM unit_conventions WHERE table_name = 'discrete_controlled_ac_branches' "
            "AND discriminator_column = 'power_units'"
        )
    } == {
        ("rating", "COMPONENT_BASE"): ("ApparentPower", "pu"),
        ("rating", "NATURAL_UNITS"): ("ApparentPower", "MVA"),
    }


def test_discrete_controlled_ac_branches_store_and_reject_invalid(fresh_db):
    """End to end on the production build: values persist, invalid enum/bound rejected."""
    from test_unit_registry import make_entity

    arc, a, b = 501, 502, 503
    make_entity(fresh_db, arc, entity_table="arcs")
    fresh_db.execute("INSERT OR IGNORE INTO entity_types(name, is_topology) VALUES ('bus', 1)")
    for eid in (a, b):
        fresh_db.execute(
            "INSERT INTO entities(id, entity_table, entity_type) "
            "VALUES (?, 'balancing_topologies', 'bus')",
            (eid,),
        )
    fresh_db.execute("INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)", (arc, a, b))

    make_entity(fresh_db, 1, entity_table="discrete_controlled_ac_branches", entity_type="DiscreteControlledACBranch")
    fresh_db.execute(
        "INSERT INTO discrete_controlled_ac_branches "
        "(id, name, arc_id, r, x, rating, discrete_branch_type, branch_status, normal_branch_status) "
        "VALUES (1, 'sw1', ?, 0.0, 0.0, 100.0, 'BREAKER', 'CLOSED', 'CLOSED')",
        (arc,),
    )
    row = fresh_db.execute(
        "SELECT r, x, rating, discrete_branch_type, branch_status, normal_branch_status "
        "FROM discrete_controlled_ac_branches WHERE id = 1"
    ).fetchone()
    assert row == (0.0, 0.0, 100.0, "BREAKER", "CLOSED", "CLOSED")

    make_entity(fresh_db, 2, entity_table="discrete_controlled_ac_branches", entity_type="DiscreteControlledACBranch")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            "INSERT INTO discrete_controlled_ac_branches "
            "(id, name, arc_id, r, x, rating, branch_status) "
            "VALUES (2, 'sw2', ?, 0.0, 0.0, 100.0, 'HALF_OPEN')",
            (arc,),
        )


def test_transformer_circuits_columns_and_units(fresh_db):
    """Circuit r/x are first-class impedance columns stored flexibly in pu on the
    component base OR natural-units ohm, recorded per row by unit_basis exactly
    as transmission_lines does it, and the two MinMax control bands are
    registered per control_objective value."""
    cols = {
        row[1]: row[2]
        for row in fresh_db.execute("PRAGMA table_info(transformer_circuits)")
    }
    assert cols["r"] == "REAL"
    assert cols["x"] == "REAL"
    assert cols["tap"] == "REAL"
    assert cols["alpha"] == "REAL"
    assert cols["control_limits"] == "TEXT"
    assert cols["controlled_quantity_limits"] == "TEXT"
    assert cols["unit_basis"] == "TEXT"
    assert "name" not in cols  # circuits are unnamed subcomponents

    registered = set(
        fresh_db.execute(
            "SELECT column_name, quantity_type, unit FROM unit_conventions "
            "WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column IS NULL"
        ).fetchall()
    )
    # r/x are absent here on purpose: they carry a unit_basis discriminator,
    # asserted separately below. rating/rating_b/rating_c/active_power_flow/
    # reactive_power_flow are likewise absent: they carry a power_units
    # discriminator, also asserted separately below.
    assert registered == {
        ("tap", "Dimensionless", "1"),
        ("alpha", "Angle", "rad"),
        ("base_power", "ApparentPower", "MVA"),
        ("base_voltage_primary", "Voltage", "kV"),
        ("base_voltage_secondary", "Voltage", "kV"),
    }

    assert {
        (col, disc): (qt, unit)
        for col, disc, qt, unit in fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_type, unit "
            "FROM unit_conventions WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column = 'unit_basis'"
        )
    } == {
        ("r", "COMPONENT_BASE"): ("Resistance", "pu"),
        ("r", "NATURAL_UNITS"): ("Resistance", "ohm"),
        ("x", "COMPONENT_BASE"): ("Reactance", "pu"),
        ("x", "NATURAL_UNITS"): ("Reactance", "ohm"),
    }

    assert {
        (col, disc): (qt, unit)
        for col, disc, qt, unit in fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_type, unit "
            "FROM unit_conventions WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column = 'power_units'"
        )
    } == {
        ("rating", "COMPONENT_BASE"): ("ApparentPower", "pu"),
        ("rating", "NATURAL_UNITS"): ("ApparentPower", "MVA"),
        ("rating_b", "COMPONENT_BASE"): ("ApparentPower", "pu"),
        ("rating_b", "NATURAL_UNITS"): ("ApparentPower", "MVA"),
        ("rating_c", "COMPONENT_BASE"): ("ApparentPower", "pu"),
        ("rating_c", "NATURAL_UNITS"): ("ApparentPower", "MVA"),
        ("active_power_flow", "COMPONENT_BASE"): ("ActivePower", "pu"),
        ("active_power_flow", "NATURAL_UNITS"): ("ActivePower", "MW"),
        ("reactive_power_flow", "COMPONENT_BASE"): ("ReactivePower", "pu"),
        ("reactive_power_flow", "NATURAL_UNITS"): ("ReactivePower", "MVAr"),
    }

    control_bands = {
        (col, disc): (qt, unit)
        for col, disc, qt, unit in fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_type, unit "
            "FROM unit_conventions WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column = 'control_objective'"
        )
    }
    angle_objectives = {
        "ACTIVE_POWER_FLOW", "ACTIVE_POWER_FLOW_DISABLED",
        "ASYMMETRIC_ACTIVE_POWER_FLOW", "ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED",
    }
    schema_objectives = set(
        load_schemas_json("Operations/common.json")["$defs"][
            "TransformerControlObjective"
        ]["enum"]
    )
    objectives = {disc for (col, disc) in control_bands if col == "control_limits"}
    assert objectives == schema_objectives
    assert objectives == {
        disc for (col, disc) in control_bands if col == "controlled_quantity_limits"
    }
    for objective in objectives:
        if objective in angle_objectives:
            assert control_bands[("control_limits", objective)] == ("Angle", "rad")
            assert control_bands[("controlled_quantity_limits", objective)] == (
                "ActivePower", "MW",
            )
        else:
            assert control_bands[("control_limits", objective)] == (
                "Dimensionless", "1",
            )


def test_transformer_tables_magnetizing_shunt_units(fresh_db):
    """magnetizing_shunt is a complex-admittance JSON column on both transformer
    tables; its real (conductance) and imag (susceptance) parts are registered
    as dotted JSON-path conventions, pu-only (the operation_cost.* idiom)."""
    for table in ("two_winding_transformers", "three_winding_transformers"):
        cols = {
            row[1]: row[2] for row in fresh_db.execute(f"PRAGMA table_info({table})")
        }
        assert cols["magnetizing_shunt"] == "TEXT"
        registered = fresh_db.execute(
            "SELECT column_name, quantity_type, unit FROM unit_conventions "
            "WHERE table_name = ? AND column_name LIKE 'magnetizing_shunt%' "
            "ORDER BY column_name",
            (table,),
        ).fetchall()
        assert registered == [
            ("magnetizing_shunt.imag", "Susceptance", "pu"),
            ("magnetizing_shunt.real", "Conductance", "pu"),
        ]


def test_units_comment_plain_x_unit_unchanged():
    assert units_comment({"x-unit": "MW"}, {}) == " -- Units: MW"
    assert units_comment({}, {}) == ""


def test_units_comment_flat_x_units_unchanged():
    """A flat x-units map (no nested discriminator) renders exactly as before:
    ', '-joined 'key: value' pairs, sorted by key."""
    prop = {
        "x-unit-discriminator": "parameter_units",
        "x-units": {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "ohm"},
    }
    assert units_comment(prop, {}) == " -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)"


def test_units_comment_discriminator_renamed():
    """The table's renames apply to the discriminator name in the comment: the
    discriminator names a sibling column, so a renamed column (parameter_units ->
    unit_basis) must not leave the comment pointing at the upstream name."""
    prop = {
        "x-unit-discriminator": "parameter_units",
        "x-units": {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "ohm"},
    }
    renames = {"parameter_units": "unit_basis"}
    assert units_comment(prop, renames) == " -- Units: per unit_basis (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)"


def test_units_comment_nested_x_units():
    """A nested x-units value (dc_setpoint_from-shaped: unit depends on a SECOND
    discriminator) renders both discriminators and the pu/kV pair."""
    prop = {
        "x-unit-discriminator": "dc_control_from",
        "x-units": {
            "DC_POWER": "MW",
            "DC_VOLTAGE": {
                "x-unit-discriminator": "voltage_units",
                "x-units": {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "kV"},
            },
        },
    }
    comment = units_comment(prop, {})
    assert "dc_control_from" in comment
    assert "DC_POWER: MW" in comment
    assert "voltage_units" in comment
    assert "COMPONENT_BASE: pu" in comment
    assert "NATURAL_UNITS: kV" in comment
    assert comment == (
        " -- Units: per dc_control_from (DC_POWER: MW; "
        "DC_VOLTAGE: per voltage_units [COMPONENT_BASE: pu, NATURAL_UNITS: kV])"
    )
