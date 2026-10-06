"""Tests for scripts/generate_sql_schema.py (JSON Schema -> SQL codegen)."""

import json
import sqlite3
import subprocess
import sys

import pytest

# SCHEMAS_PATH is passed explicitly to codegen subprocesses so they never fall
# back to a default that does not exist in the CI layout (conftest resolves
# nested vs sibling).
from conftest import SCHEMA_DIR, SCHEMAS_PATH, SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
import generate_sql_schema as codegen

GENERATE_SCRIPT = SCRIPTS_DIR / "generate_sql_schema.py"
SCHEMA_MAP = SCHEMA_DIR / "schema_map.json"
CODEGEN_MAP = SCHEMA_DIR / "sql_codegen_map.json"


def _schema_map():
    return json.loads(SCHEMA_MAP.read_text(encoding="utf-8"))


def _codegen_map():
    return json.loads(CODEGEN_MAP.read_text(encoding="utf-8"))["tables"]


def test_generated_outputs_are_not_stale():
    """schema.sql's generated region and the derived unit conventions match a
    fresh generation from the pinned schemas."""
    result = subprocess.run(
        [sys.executable, str(GENERATE_SCRIPT), "--schemas-path", SCHEMAS_PATH, "--check"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_mapped_table_is_built_with_entity_id_pk(fresh_db):
    for table in _schema_map()["tables"]:
        info = fresh_db.execute(f"PRAGMA table_info({table})").fetchall()
        assert info, f"{table} is mapped but not in the built database"
        pk_cols = [row[1] for row in info if row[5] == 1]
        assert pk_cols == ["id"], f"{table} PK is {pk_cols}"


def test_attribute_channel_properties_not_columns(fresh_db):
    """Properties routed to the attributes table must not appear as columns."""
    for table, cfg in _codegen_map().items():
        cols = {row[1] for row in fresh_db.execute(f"PRAGMA table_info({table})")}
        leaked = cols & set(cfg.get("attribute_channel", []))
        assert not leaked, f"{table}: attribute-channel properties as columns: {leaked}"


def test_unmapped_schema_file_fails_the_inventory():
    """A component the schemas add, with no table and no exclusion, is an error."""
    schema_map = _schema_map()
    assert codegen.inventory_problems(str(SCHEMAS_PATH), schema_map) == []
    del schema_map["tables"]["sources"]
    problems = codegen.inventory_problems(str(SCHEMAS_PATH), schema_map)
    assert problems == [
        "Operations/StaticInjection/Source.json is neither mapped to a table "
        "nor excluded in schema_map.json"
    ]


def test_property_without_disposition_fails():
    """A property the schemas add fails until sql_codegen_map.json places it, and
    a disposition for a property the schemas dropped fails too."""
    components = _schema_map()["tables"]["sources"]
    merged = codegen.merge_components(components, str(SCHEMAS_PATH))
    cfg = _codegen_map()["sources"]
    assert codegen.disposition_problems("sources", merged, cfg) == []

    cfg["columns"].pop("internal_angle")
    cfg["skip"] = cfg.get("skip", []) + ["no_such_property"]
    problems = codegen.disposition_problems("sources", merged, cfg)
    assert any(p.startswith("sources.internal_angle (Source) has no disposition") for p in problems)
    assert "sources.no_such_property is in skip but no mapped component defines it" in problems


def test_attribute_name_with_two_quantities_fails():
    """attributes conventions key on the name alone, so two components that
    route one name with different quantity kinds are an error."""
    a = {"table": "attributes", "column": "level", "quantity_kind": "Volume", "unit": "m3"}
    b = {"table": "attributes", "column": "level", "quantity_kind": "Elevation", "unit": "m",
         "discriminator_value": "HEAD"}
    _, _, problems = codegen.merge_attribute_rows(
        [("t1", "level", [a], []), ("t2", "level", [b], [])]
    )
    assert problems == ["attributes.level has more than one quantity kind: "
                        "Elevation in t2; Volume in t1"]


def test_unitless_attribute_under_a_registered_name_fails():
    """The unit trigger checks a registered name before the identifier
    exemption, so a name cannot be registered on one component and exempt on
    another (HydroPumpTurbine's object-valued efficiency is the real case)."""
    conv = {"table": "attributes", "column": "efficiency", "quantity_kind": "Dimensionless",
            "unit": "1"}
    _, _, problems = codegen.merge_attribute_rows(
        [("t", "efficiency", [conv], []), ("t", "efficiency", [], ["HydroPumpTurbine"])]
    )
    assert problems == [
        "attributes.efficiency: HydroPumpTurbine stores it with no unit, but another "
        "component registers a unit for the name; set attribute_units for it"
    ]


def test_x_quantity_applies_only_to_the_arms_it_allows():
    """HydroReservoir annotates one x-quantity (Elevation) on a field whose arms
    are m, m3 and MWh; each other arm takes the one kind its unit identifies."""
    units_index = codegen.load_units_index(str(SCHEMAS_PATH))
    node = {"x-quantity": "Elevation"}
    assert codegen.arm_quantity(node, "m", units_index) == "Elevation"
    assert codegen.arm_quantity(node, "m3", units_index) == "Volume"
    assert codegen.arm_quantity(node, "MWh", units_index) == "ElectricalEnergy"


def test_branch_parameters_are_first_class_columns(fresh_db):
    """r/x/b/g are first-class transmission_lines columns, each stored flexibly in
    per-unit (component base) OR natural units, recorded per row by parameter_units.
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
            "SELECT column_name, discriminator_value, quantity_kind, unit "
            "FROM unit_conventions WHERE table_name = 'transmission_lines' "
            "AND column_name IN ('r', 'x', 'b', 'g') "
            "AND discriminator_column = 'parameter_units'"
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
            "SELECT quantity_kind, unit FROM allowed_units WHERE unit IN ('pu', 'pu/min')"
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
        "INSERT INTO transmission_lines (id, name, arc_id, continuous_rating, r, x, b, g, power_units, base_power, angle_limits) "
        "VALUES (1, 'line1', ?, 100.0, 0.01, 0.1, "
        "json('{\"from\": 0.005, \"to\": 0.005}'), "
        "json('{\"from\": 0.0, \"to\": 0.0}'), 'COMPONENT_BASE', 100.0, '{\"min\": -1.0, \"max\": 1.0}')",
        (_arc(1),),
    )
    row = fresh_db.execute(
        "SELECT r, x, json_extract(b, '$.from'), json_extract(g, '$.to') "
        "FROM transmission_lines WHERE id = 1"
    ).fetchone()
    assert row == (0.01, 0.1, 0.005, 0.0)
    # Use a FRESH id (id=1 already exists above) so the raised IntegrityError is
    # the CHECK (r >= 0) bound being violated, not a duplicate-primary-key clash.
    # arc_id/continuous_rating/x/base_power are NOT NULL, so supply them and leave r negative.
    make_entity(fresh_db, 2, entity_table="transmission_lines", entity_type="Line")
    with pytest.raises(sqlite3.IntegrityError, match="r >= 0"):
        fresh_db.execute(
            "INSERT INTO transmission_lines "
            "(id, name, arc_id, continuous_rating, r, x, power_units, base_power, angle_limits) "
            "VALUES (2, 'line2', ?, 100.0, -0.5, 0.1, 'COMPONENT_BASE', 100.0, '{\"min\": -1.0, \"max\": 1.0}')",
            (_arc(2),),
        )


def test_discrete_controlled_ac_branches_columns_and_units(fresh_db):
    """r/x are first-class discrete_controlled_ac_branches columns (pu -- this
    component has no natural-units option in PSY, unlike transmission_lines),
    registered in unit_conventions with no discriminator. rating is stored
    flexibly per power_units, asserted separately below. base_power is the
    component base r/x are per-unitized against, mirroring transmission_lines."""
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
            "SELECT column_name, quantity_kind, unit FROM unit_conventions "
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
            "SELECT column_name, discriminator_value, quantity_kind, unit "
            "FROM unit_conventions WHERE table_name = 'discrete_controlled_ac_branches' "
            "AND discriminator_column = 'power_units'"
        )
    } == {
        ("rating", "COMPONENT_BASE"): ("ApparentPower", "pu"),
        ("rating", "NATURAL_UNITS"): ("ApparentPower", "MVA"),
        ("operational_flow_limit", "COMPONENT_BASE"): ("ActivePower", "pu"),
        ("operational_flow_limit", "NATURAL_UNITS"): ("ActivePower", "MW"),
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
        "(id, name, arc_id, r, x, rating, power_units, base_power, discrete_branch_type, branch_status, normal_branch_status) "
        "VALUES (1, 'sw1', ?, 0.0, 0.0, 100.0, 'COMPONENT_BASE', 100.0, 'BREAKER', 'CLOSED', 'CLOSED')",
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
    component base OR natural-units ohm, recorded per row by parameter_units exactly
    as transmission_lines does it. Each control band has one fixed physical
    quantity (SiennaSchemas 0.2 split the control_objective-multiplexed bands)."""
    cols = {
        row[1]: row[2]
        for row in fresh_db.execute("PRAGMA table_info(transformer_circuits)")
    }
    assert cols["r"] == "REAL"
    assert cols["x"] == "REAL"
    assert cols["tap"] == "REAL"
    assert cols["alpha"] == "REAL"
    for band in ("tap_ratio_limits", "phase_angle_limits", "controlled_voltage_limits",
                 "controlled_reactive_power_flow_limits", "controlled_active_power_flow_limits"):
        assert cols[band] == "TEXT"
    assert "control_limits" not in cols
    assert cols["parameter_units"] == "TEXT"
    assert "name" not in cols  # circuits are unnamed subcomponents

    registered = set(
        fresh_db.execute(
            "SELECT column_name, quantity_kind, unit FROM unit_conventions "
            "WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column IS NULL"
        ).fetchall()
    )
    # r/x are absent here on purpose: they carry a parameter_units discriminator,
    # asserted separately below. rating/rating_b/rating_c/active_power_flow/
    # reactive_power_flow are likewise absent: they carry a power_units
    # discriminator, also asserted separately below.
    assert registered == {
        ("tap", "Dimensionless", "1"),
        ("alpha", "Angle", "rad"),
        ("base_power", "ApparentPower", "MVA"),
        ("base_voltage_primary", "Voltage", "kV"),
        ("base_voltage_secondary", "Voltage", "kV"),
        ("tap_ratio_limits", "Dimensionless", "1"),
        ("phase_angle_limits", "Angle", "rad"),
        ("controlled_voltage_limits", "Voltage", "pu"),
    }

    assert {
        (col, disc): (qt, unit)
        for col, disc, qt, unit in fresh_db.execute(
            "SELECT column_name, discriminator_value, quantity_kind, unit "
            "FROM unit_conventions WHERE table_name = 'transformer_circuits' "
            "AND discriminator_column = 'parameter_units'"
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
            "SELECT column_name, discriminator_value, quantity_kind, unit "
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
        ("operational_flow_limit", "COMPONENT_BASE"): ("ActivePower", "pu"),
        ("operational_flow_limit", "NATURAL_UNITS"): ("ActivePower", "MW"),
        ("controlled_active_power_flow_limits", "COMPONENT_BASE"): ("ActivePower", "pu"),
        ("controlled_active_power_flow_limits", "NATURAL_UNITS"): ("ActivePower", "MW"),
        ("controlled_reactive_power_flow_limits", "COMPONENT_BASE"): ("ReactivePower", "pu"),
        ("controlled_reactive_power_flow_limits", "NATURAL_UNITS"): ("ReactivePower", "MVAr"),
    }

    assert not fresh_db.execute(
        "SELECT 1 FROM unit_conventions WHERE table_name = 'transformer_circuits' "
        "AND discriminator_column = 'control_objective'"
    ).fetchall()


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
            "SELECT column_name, quantity_kind, unit FROM unit_conventions "
            "WHERE table_name = ? AND column_name LIKE 'magnetizing_shunt%' "
            "ORDER BY column_name",
            (table,),
        ).fetchall()
        assert registered == [
            ("magnetizing_shunt.imag", "Susceptance", "pu"),
            ("magnetizing_shunt.real", "Conductance", "pu"),
        ]

