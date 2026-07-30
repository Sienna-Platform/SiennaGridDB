"""Unit-registry test suite (UIP section 6.1).

Covers, positively and negatively: the build (row counts, FK integrity, seal
presence, verify tool), seal honesty (tamper detection incl. quantity_types),
seal enforcement (protected tables + no-op rerun), attribute unit validation
(incl. the polymorphic NOT EXISTS regression), series-level time series, the
hydro ``level_data_type`` CHECK, cost-payload power-units, and completeness
(registry rows exist + physical columns are registered or allow-listed).

Each negative assertion checks the raised message contains the expected trigger
text fragment, not merely that *some* error was raised.
"""

import json
import sqlite3
import subprocess
import sys

import pytest

from conftest import SCHEMA_DIR, SCRIPTS_DIR, load_schemas_json, make_entity

# Expected seed row counts (current sealed state).
# Temperature (degC) removed: unused by any schema component.
EXPECTED_QUANTITY_TYPES = 38
# +1 MJ for ElectricalEnergy (RealEnergy rename), +1 Mt/MWh for EmissionRate (carbon caps),
# -1 Temperature/degC (unused, removed)
EXPECTED_ALLOWED_UNITS = 55
# +3 for discrete_controlled_ac_branches.{r,x,rating}
# +49 for the transformer tables: transformer_circuits (36: tap, alpha, r, x,
# 12 control_limits + 12 controlled_quantity_limits discriminated by
# control_objective, ratings, flows, base power/voltages),
# three_winding_transformers (11: pairwise r/x, pairwise base powers,
# magnetizing_shunt.real/.imag), two_winding_transformers (2:
# magnetizing_shunt.real/.imag)
EXPECTED_UNIT_CONVENTIONS = 276

VERIFY_SCRIPT = SCRIPTS_DIR / "verify_unit_registry.py"
REGISTRY_SQL = SCHEMA_DIR / "unit_registry.sql"

# Registry tables sealed against ad-hoc edits after the checksum row exists.
SEALED_TABLES = [
    "quantity_types",
    "allowed_units",
    "unit_conventions",
    "unit_management_metadata",
]

# Physical REAL/JSON columns intentionally NOT unit-registered: free-form region
# descriptors (JSON lists of region names, not a physical quantity). Any other
# unregistered REAL/JSON column on an entity table is a bug (see the reverse
# completeness test). Keep this list minimal and justified.
COMPLETENESS_ALLOWLIST = {
    ("storage_technologies", "region"),
    ("supply_technologies", "region"),
    # structural value columns; units live in time_series_metadata for series data
    ("static_time_series", "value"),
    # structural value column; units live in attribute conventions for supplemental attrs
    ("supplemental_attributes", "value"),
    # structural TYPE+value JSON store (like supplemental_attributes); no fixed unit
    ("plants", "value"),
    # non-binding sentinel ceiling, not unit-converted on the PSY side (no x-unit
    # in the schema; see schema.sql's facts_control_devices comment)
    ("facts_control_devices", "max_reactive_power"),
}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def insert_attribute(conn, entity_id, name, value, unit=None, quantity_type=None):
    conn.execute(
        "INSERT INTO attributes(entity_id, type, name, value, unit, quantity_type) "
        "VALUES (?, 'test', ?, ?, ?, ?)",
        (entity_id, name, value, unit, quantity_type),
    )


def drop_seal_triggers(conn):
    """Drop the immutability triggers so a registry table can be tampered."""
    for table in SEALED_TABLES:
        for action in ("insert", "update", "delete"):
            conn.execute(
                f"DROP TRIGGER IF EXISTS prevent_{table}_{action}"
            )


def run_verify(db_path):
    return subprocess.run(
        [sys.executable, str(VERIFY_SCRIPT), str(db_path)],
        capture_output=True,
        text=True,
    )


# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "table, expected",
    [
        ("quantity_types", EXPECTED_QUANTITY_TYPES),
        ("allowed_units", EXPECTED_ALLOWED_UNITS),
        ("unit_conventions", EXPECTED_UNIT_CONVENTIONS),
    ],
)
def test_build_row_counts(db, table, expected):
    (count,) = db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
    assert count == expected


def test_build_foreign_key_check_empty(db):
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []


def test_build_seal_row_present(db):
    row = db.execute(
        "SELECT value FROM unit_management_metadata "
        "WHERE key = 'unit_conventions_checksum'"
    ).fetchone()
    assert row is not None
    assert len(row[0]) == 64  # sha256 hex digest


def test_build_user_version_set(db):
    (version,) = db.execute("PRAGMA user_version").fetchone()
    assert version >= 1


def test_verify_tool_passes_on_clean_db(built_db_path):
    result = run_verify(built_db_path)
    assert result.returncode == 0, result.stderr
    assert "MATCH" in result.stdout


# --------------------------------------------------------------------------- #
# Seal honesty (tamper detection)
# --------------------------------------------------------------------------- #
def test_verify_detects_quantity_types_tamper(fresh_db, fresh_db_path):
    """quantity_types tampering is the blind spot the old checksum flunked."""
    drop_seal_triggers(fresh_db)
    fresh_db.execute(
        "UPDATE quantity_types SET default_unit = 'bogus' WHERE name = 'ActivePower'"
    )
    fresh_db.commit()
    fresh_db.close()
    result = run_verify(fresh_db_path)
    assert result.returncode == 1
    assert "MISMATCH" in result.stderr


def test_verify_detects_allowed_units_tamper(fresh_db, fresh_db_path):
    drop_seal_triggers(fresh_db)
    fresh_db.execute("DELETE FROM allowed_units WHERE quantity_type = 'Angle'")
    fresh_db.commit()
    fresh_db.close()
    result = run_verify(fresh_db_path)
    assert result.returncode == 1
    assert "MISMATCH" in result.stderr


def test_verify_detects_unit_conventions_tamper(fresh_db, fresh_db_path):
    drop_seal_triggers(fresh_db)
    fresh_db.execute(
        "UPDATE unit_conventions SET unit = 'bogus' WHERE table_name = 'loads'"
    )
    fresh_db.commit()
    fresh_db.close()
    result = run_verify(fresh_db_path)
    assert result.returncode == 1
    assert "MISMATCH" in result.stderr


def test_verify_fails_when_seal_row_missing(fresh_db, fresh_db_path):
    drop_seal_triggers(fresh_db)
    fresh_db.execute(
        "DELETE FROM unit_management_metadata "
        "WHERE key = 'unit_conventions_checksum'"
    )
    fresh_db.commit()
    fresh_db.close()
    result = run_verify(fresh_db_path)
    assert result.returncode == 1
    assert "unsealed" in result.stderr


# --------------------------------------------------------------------------- #
# Seal enforcement (protected registry tables)
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("table", SEALED_TABLES)
def test_seal_blocks_delete(fresh_db, table):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(f"DELETE FROM {table}")


def test_seal_blocks_update_quantity_types(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "UPDATE quantity_types SET default_unit = 'x' WHERE name = 'ActivePower'"
        )


def test_seal_blocks_update_allowed_units(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute("UPDATE allowed_units SET unit = 'x' WHERE unit = 'MW'")


def test_seal_blocks_update_unit_conventions(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute("UPDATE unit_conventions SET unit = 'x' WHERE id = 1")


def test_seal_blocks_update_metadata(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "UPDATE unit_management_metadata SET value = 'x' "
            "WHERE key = 'unit_conventions_checksum'"
        )


def test_seal_blocks_insert_quantity_types(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT INTO quantity_types(name, default_unit, dimension) "
            "VALUES ('Bogus', 'x', 'x')"
        )


def test_seal_blocks_insert_allowed_units(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT INTO allowed_units(quantity_type, unit) VALUES ('ActivePower', 'GW')"
        )


def test_seal_blocks_insert_unit_conventions(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT INTO unit_conventions(table_name, column_name, quantity_type, unit) "
            "VALUES ('loads', 'bogus', 'ActivePower', 'MW')"
        )


def test_seal_blocks_insert_metadata(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT INTO unit_management_metadata(key, value) VALUES ('k', 'v')"
        )


def test_seal_blocks_insert_or_replace_metadata(fresh_db):
    """INSERT OR REPLACE on the seal key must not slip past the guard."""
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT OR REPLACE INTO unit_management_metadata(key, value) "
            "VALUES ('unit_conventions_checksum', 'forged')"
        )


def test_seal_blocks_insert_or_replace_quantity_types(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT OR REPLACE INTO quantity_types(name, default_unit, dimension) "
            "VALUES ('ActivePower', 'x', 'x')"
        )


def test_registry_rerun_is_noop_failure_not_corruption(fresh_db, fresh_db_path):
    """Re-running unit_registry.sql against a sealed DB aborts without corrupting."""
    before = {
        table: fresh_db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        for table in SEALED_TABLES
    }
    fresh_db.close()

    conn = sqlite3.connect(str(fresh_db_path))
    conn.execute("PRAGMA foreign_keys = ON")
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        conn.executescript(REGISTRY_SQL.read_text())
    # BEFORE trigger aborts on first INSERT; counts stay stable without rollback
    after = {
        table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        for table in SEALED_TABLES
    }
    conn.close()
    assert after == before


# --------------------------------------------------------------------------- #
# Attributes
# --------------------------------------------------------------------------- #
def test_attribute_known_name_wrong_unit_rejected(fresh_db):
    make_entity(fresh_db, 1)
    with pytest.raises(
        sqlite3.IntegrityError, match="Known attribute must use the registered unit"
    ):
        insert_attribute(fresh_db, 1, "ramp_limits", "1.0", "MW", "ActivePower")


def test_attribute_known_name_registered_pair_accepted(fresh_db):
    make_entity(fresh_db, 1)
    insert_attribute(fresh_db, 1, "active_power_limits", "10.0", "MW", "ActivePower")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'active_power_limits'"
    ).fetchone()
    assert count == 1


def test_attribute_known_name_case_insensitive_accepted(fresh_db):
    """UPPERCASE attribute name still matches the registered lower-case row."""
    make_entity(fresh_db, 1)
    insert_attribute(fresh_db, 1, "ACTIVE_POWER_LIMITS", "10.0", "MW", "ActivePower")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'ACTIVE_POWER_LIMITS'"
    ).fetchone()
    assert count == 1


def test_attribute_unknown_name_bad_pair_rejected(fresh_db):
    make_entity(fresh_db, 1)
    with pytest.raises(
        sqlite3.IntegrityError, match="vocabulary-valid unit and quantity_type"
    ):
        insert_attribute(fresh_db, 1, "mystery", "7.0", "bananas", "ActivePower")


def test_attribute_unknown_name_valid_pair_accepted(fresh_db):
    make_entity(fresh_db, 1)
    insert_attribute(fresh_db, 1, "mystery", "7.0", "MW", "ActivePower")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'mystery'"
    ).fetchone()
    assert count == 1


@pytest.mark.parametrize(
    "value",
    [
        '"some text"',  # json text
        "true",  # json bool
        "false",
        "null",  # json null
    ],
)
def test_attribute_nonphysical_values_pass_without_units(fresh_db, value):
    """text / bool / null values require no unit or quantity_type."""
    make_entity(fresh_db, 1)
    insert_attribute(fresh_db, 1, "some_flag", value, None, None)
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'some_flag'"
    ).fetchone()
    assert count == 1


def test_attribute_polymorphic_both_pairs_accepted_cross_rejected(fresh_db):
    """Regression for the scalar-subquery -> NOT EXISTS rewrite.

    A name with two discriminated registry rows must accept BOTH registered
    (quantity_type, unit) pairs and reject a cross pair. No such name exists in
    the seed, so we synthesise one on an unsealed copy: register poly_attr under
    Duration/h and Duration/min (both are real allowed_units pairs).
    """
    drop_seal_triggers(fresh_db)
    fresh_db.execute(
        "INSERT INTO unit_conventions"
        "(table_name, column_name, quantity_type, unit, "
        " discriminator_column, discriminator_value) "
        "VALUES ('attributes', 'poly_attr', 'Duration', 'h', 'mode', 'A'), "
        "       ('attributes', 'poly_attr', 'Duration', 'min', 'mode', 'B')"
    )
    make_entity(fresh_db, 1)

    # Both registered pairs accepted (distinct entities to dodge UNIQUE(entity,name)).
    insert_attribute(fresh_db, 1, "poly_attr", "1.0", "h", "Duration")
    make_entity(fresh_db, 2)
    insert_attribute(fresh_db, 2, "poly_attr", "2.0", "min", "Duration")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'poly_attr'"
    ).fetchone()
    assert count == 2

    # A cross pair (valid vocabulary Duration/s, but not registered for this name).
    make_entity(fresh_db, 3)
    with pytest.raises(
        sqlite3.IntegrityError, match="Known attribute must use the registered unit"
    ):
        insert_attribute(fresh_db, 3, "poly_attr", "3.0", "s", "Duration")


# --------------------------------------------------------------------------- #
# Time series
# --------------------------------------------------------------------------- #
def test_static_time_series_without_metadata_rejected(fresh_db):
    with pytest.raises(
        sqlite3.IntegrityError,
        match="static_time_series.uuid must exist in time_series_metadata",
    ):
        fresh_db.execute(
            "INSERT INTO static_time_series(uuid, idx, value) VALUES ('u1', 0, 1.0)"
        )


def test_static_time_series_with_metadata_accepted(fresh_db):
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('u1', 'MW', 'ActivePower')"
    )
    fresh_db.execute(
        "INSERT INTO static_time_series(uuid, idx, value) VALUES ('u1', 0, 1.0)"
    )
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM static_time_series WHERE uuid = 'u1'"
    ).fetchone()
    assert count == 1


def test_static_time_series_update_uuid_to_orphan_rejected(fresh_db):
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('u1', 'MW', 'ActivePower')"
    )
    fresh_db.execute(
        "INSERT INTO static_time_series(uuid, idx, value) VALUES ('u1', 0, 1.0)"
    )
    with pytest.raises(
        sqlite3.IntegrityError,
        match="static_time_series.uuid must exist in time_series_metadata",
    ):
        fresh_db.execute("UPDATE static_time_series SET uuid = 'orphan' WHERE uuid = 'u1'")


def test_time_series_metadata_bad_pair_rejected(fresh_db):
    with pytest.raises(
        sqlite3.IntegrityError,
        match="must be a registered pair in allowed_units",
    ):
        fresh_db.execute(
            "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
            "VALUES ('u2', 'bananas', 'ActivePower')"
        )


def test_time_series_metadata_mixed_units_impossible(fresh_db):
    """One metadata row per uuid (PRIMARY KEY): a second row for the same uuid
    with a different unit cannot exist, so a series cannot carry mixed units."""
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('u1', 'MW', 'ActivePower')"
    )
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE|PRIMARY KEY"):
        fresh_db.execute(
            "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
            "VALUES ('u1', 'MVAr', 'ReactivePower')"
        )


def _insert_association(conn, uuid, units):
    conn.execute(
        "INSERT INTO time_series_associations("
        "time_series_uuid, time_series_type, initial_timestamp, resolution, "
        "name, owner_id, owner_type, owner_category, features, metadata_uuid, units) "
        "VALUES (?, 'Deterministic', '2020-01-01', 'PT1H', 'load', ?, 'thing', "
        "'gen', '{}', 'm-uuid', ?)",
        (uuid, 1, units),
    )


def test_association_units_contradiction_rejected(fresh_db):
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('u1', 'MW', 'ActivePower')"
    )
    with pytest.raises(
        sqlite3.IntegrityError,
        match="time_series_associations.units must equal time_series_metadata.unit",
    ):
        _insert_association(fresh_db, "u1", "MVAr")


def test_association_units_matching_accepted(fresh_db):
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('u1', 'MW', 'ActivePower')"
    )
    _insert_association(fresh_db, "u1", "MW")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE units = 'MW'"
    ).fetchone()
    assert count == 1


def test_association_units_null_accepted(fresh_db):
    """NULL units skip the equality guard (column is deprecated/optional)."""
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, "u1", None)
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE units IS NULL"
    ).fetchone()
    assert count == 1


def test_association_units_non_null_no_metadata_accepted(fresh_db):
    """Non-NULL units with NO metadata row for the uuid must be ACCEPTED.

    Bulk loads insert the association before its time_series_metadata row, so a
    missing metadata row is a valid transient state (the trigger's own message
    says "or no time_series_metadata row exists" is acceptable). The guard only
    fires when a metadata row EXISTS with a DIFFERENT unit.
    """
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, "no-such-uuid", "MW")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE units = 'MW'"
    ).fetchone()
    assert count == 1


# --------------------------------------------------------------------------- #
# Hydro level_data_type CHECK
# --------------------------------------------------------------------------- #
HYDRO_ENUM_VALUES = ["USABLE_VOLUME", "TOTAL_VOLUME", "HEAD", "ENERGY"]


def _insert_reservoir(conn, entity_id, level_data_type):
    conn.execute(
        "INSERT INTO hydro_reservoirs("
        "id, name, storage_level_limits, initial_level, head_to_volume_factor, "
        "level_data_type) VALUES (?, ?, '{\"min\":0,\"max\":1}', 0.0, "
        "'{\"function_type\":\"LINEAR\",\"proportional_term\":0,\"constant_term\":0}', ?)",
        (entity_id, f"res_{entity_id}", level_data_type),
    )


@pytest.mark.parametrize("level_data_type", HYDRO_ENUM_VALUES)
def test_hydro_level_data_type_enum_accepted(fresh_db, level_data_type):
    eid = make_entity(fresh_db, 1, entity_table="hydro_reservoirs")
    _insert_reservoir(fresh_db, eid, level_data_type)
    (stored,) = fresh_db.execute(
        "SELECT level_data_type FROM hydro_reservoirs WHERE id = ?", (eid,)
    ).fetchone()
    assert stored == level_data_type


def test_hydro_level_data_type_volume_rejected(fresh_db):
    eid = make_entity(fresh_db, 1, entity_table="hydro_reservoirs")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint failed"):
        _insert_reservoir(fresh_db, eid, "VOLUME")


# --------------------------------------------------------------------------- #
# Transmission-line parameter_units discriminator + STRICT
# --------------------------------------------------------------------------- #
def _insert_line(conn, entity_id, r=0.1, x=0.2, parameter_units=None):
    # transmission_lines.arc_id (NOT NULL) -> arcs -> entities; provision an
    # arc with two distinct endpoint entities so the FK/NOT NULL are satisfied.
    arc_eid, from_eid, to_eid = entity_id * 100 + 1, entity_id * 100 + 2, entity_id * 100 + 3
    make_entity(conn, arc_eid, entity_table="arcs")
    # arc endpoints must be topology-type entities (is_topology = 1).
    conn.execute("INSERT OR IGNORE INTO entity_types(name, is_topology) VALUES ('bus', 1)")
    for eid in (from_eid, to_eid):
        conn.execute(
            "INSERT INTO entities(id, entity_table, entity_type) "
            "VALUES (?, 'balancing_topologies', 'bus')",
            (eid,),
        )
    conn.execute(
        "INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)",
        (arc_eid, from_eid, to_eid),
    )
    cols = ["id", "name", "arc_id", "continuous_rating", "r", "x"]
    vals = [entity_id, f"line_{entity_id}", arc_eid, 100.0, r, x]
    if parameter_units is not None:
        cols.append("parameter_units")
        vals.append(parameter_units)
    placeholders = ", ".join("?" for _ in cols)
    conn.execute(
        f"INSERT INTO transmission_lines({', '.join(cols)}) VALUES ({placeholders})",
        vals,
    )


def test_transmission_line_parameter_units_default_system_base(fresh_db):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    _insert_line(fresh_db, eid)
    (pu,) = fresh_db.execute(
        "SELECT parameter_units FROM transmission_lines WHERE id = ?", (eid,)
    ).fetchone()
    assert pu == "SYSTEM_BASE"


@pytest.mark.parametrize("parameter_units", ["SYSTEM_BASE", "NATURAL_UNITS"])
def test_transmission_line_parameter_units_valid_accepted(fresh_db, parameter_units):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    _insert_line(fresh_db, eid, parameter_units=parameter_units)
    (stored,) = fresh_db.execute(
        "SELECT parameter_units FROM transmission_lines WHERE id = ?", (eid,)
    ).fetchone()
    assert stored == parameter_units


def test_transmission_line_parameter_units_bad_value_rejected(fresh_db):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint failed"):
        _insert_line(fresh_db, eid, parameter_units="VOLUME")


def test_transmission_line_r_text_rejected_under_strict(fresh_db):
    """STRICT is restored: a TEXT value in the REAL column r is a datatype mismatch."""
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    with pytest.raises(sqlite3.IntegrityError, match="REAL column"):
        _insert_line(fresh_db, eid, r="not_a_number")


def test_transmission_line_discriminated_registry_rows(db):
    """r/x/b/g each carry two discriminated rows (SYSTEM_BASE + NATURAL_UNITS)."""
    rows = db.execute(
        "SELECT column_name, discriminator_value, quantity_type, unit "
        "FROM unit_conventions WHERE table_name = 'transmission_lines' "
        "AND column_name IN ('r', 'x', 'b', 'g') "
        "AND discriminator_column = 'parameter_units' "
        "ORDER BY column_name, discriminator_value"
    ).fetchall()
    expected = [
        ("b", "NATURAL_UNITS", "Susceptance", "S"),
        ("b", "SYSTEM_BASE", "Susceptance", "pu"),
        ("g", "NATURAL_UNITS", "Conductance", "S"),
        ("g", "SYSTEM_BASE", "Conductance", "pu"),
        ("r", "NATURAL_UNITS", "Resistance", "ohm"),
        ("r", "SYSTEM_BASE", "Resistance", "pu"),
        ("x", "NATURAL_UNITS", "Reactance", "ohm"),
        ("x", "SYSTEM_BASE", "Reactance", "pu"),
    ]
    assert [tuple(r) for r in rows] == expected


# --------------------------------------------------------------------------- #
# Cost payloads
# --------------------------------------------------------------------------- #
def _thermal_cost(power_units):
    return (
        '{"cost_type":"THERMAL","fixed":0,"shut_down":0,"start_up":0,'
        '"variable":{"variable_cost_type":"COST","power_units":"' + power_units + '",'
        '"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":'
        '{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}}'
    )


def _setup_topology(conn, topo_id=1):
    """Create a balancing_topology (id ``topo_id``) generators can reference."""
    make_entity(conn, topo_id, entity_table="balancing_topologies", entity_type="topo")
    conn.execute("INSERT INTO balancing_topologies(id, name) VALUES (?, 'bt')", (topo_id,))
    return topo_id


def _insert_thermal(conn, gen_id, topo_id, operation_cost):
    conn.execute("INSERT INTO prime_mover_types(name) VALUES ('CT')")
    conn.execute("INSERT INTO fuels(name) VALUES ('OTHER')")
    make_entity(conn, gen_id, entity_table="thermal_generators")
    conn.execute(
        "INSERT INTO thermal_generators("
        "id, name, prime_mover_type, fuel, balancing_topology, rating, base_power, "
        "active_power_limits, operation_cost) "
        "VALUES (?, 'tg', 'CT', 'OTHER', ?, 1.0, 1.0, '{\"min\":0,\"max\":1}', ?)",
        (gen_id, topo_id, operation_cost),
    )


@pytest.mark.parametrize("power_units", ["SYSTEM_BASE", "DEVICE_BASE"])
def test_cost_relative_base_variable_rejected(fresh_db, power_units):
    topo = _setup_topology(fresh_db)
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        _insert_thermal(fresh_db, 2, topo, _thermal_cost(power_units))


def test_cost_natural_units_variable_accepted(fresh_db):
    topo = _setup_topology(fresh_db)
    _insert_thermal(fresh_db, 2, topo, _thermal_cost("NATURAL_UNITS"))
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM thermal_generators"
    ).fetchone()
    assert count == 1


def test_cost_update_relative_base_rejected(fresh_db):
    """UPDATE that changes operation_cost to a relative-base payload is rejected."""
    topo = _setup_topology(fresh_db)
    _insert_thermal(fresh_db, 2, topo, _thermal_cost("NATURAL_UNITS"))
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        fresh_db.execute(
            "UPDATE thermal_generators SET operation_cost = ? WHERE id = 2",
            (_thermal_cost("SYSTEM_BASE"),),
        )


def test_renewable_curtailment_cost_system_base_rejected(fresh_db):
    topo = _setup_topology(fresh_db)
    make_entity(fresh_db, 2, entity_table="renewable_generators")
    fresh_db.execute("INSERT INTO prime_mover_types(name) VALUES ('PV')")
    curtailment_cost = (
        '{"cost_type":"RENEWABLE","fixed":0,'
        '"variable":{"variable_cost_type":"COST","power_units":"NATURAL_UNITS",'
        '"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":'
        '{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}},'
        '"curtailment_cost":{"variable_cost_type":"COST","power_units":"SYSTEM_BASE",'
        '"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":'
        '{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}}'
    )
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        fresh_db.execute(
            "INSERT INTO renewable_generators("
            "id, name, prime_mover_type, balancing_topology, rating, base_power, "
            "operation_cost) VALUES (2, 'rg', 'PV', ?, 1.0, 1.0, ?)",
            (topo, curtailment_cost),
        )


def _storage_cost(charge_pu="NATURAL_UNITS", discharge_pu="NATURAL_UNITS"):
    """A StorageCost payload. power_units live under charge/discharge_variable_cost
    (CostCurve), NOT under a `variable` key (that key does not exist on StorageCost)."""
    def cc(pu):
        return (
            '{"variable_cost_type":"COST","power_units":"' + pu + '",'
            '"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":'
            '{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}'
        )
    return (
        '{"cost_type":"STORAGE","fixed":0,"start_up":0,"shut_down":0,'
        '"charge_variable_cost":' + cc(charge_pu) + ','
        '"discharge_variable_cost":' + cc(discharge_pu) + '}'
    )


def _insert_storage_unit(conn, unit_id, topo_id, operation_cost):
    conn.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('BA')")
    conn.execute("INSERT OR IGNORE INTO storage_technology_types(name) VALUES ('LI')")
    make_entity(conn, unit_id, entity_table="storage_units")
    conn.execute(
        "INSERT INTO storage_units("
        "id, name, prime_mover_type, storage_technology_type, balancing_topology, "
        "rating, base_power, storage_capacity, storage_level_limits, "
        "initial_storage_capacity_level, input_active_power_limits, "
        "output_active_power_limits, efficiency, operation_cost) "
        "VALUES (?, 'su', 'BA', 'LI', ?, 1.0, 1.0, 1.0, "
        "'{\"min\":0,\"max\":1}', 0.0, '{\"min\":0,\"max\":1}', "
        "'{\"min\":0,\"max\":1}', '{\"in\":0.9,\"out\":0.9}', ?)",
        (unit_id, topo_id, operation_cost),
    )


def _insert_storage_technology(conn, tech_id, operation_costs):
    conn.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('BA')")
    make_entity(conn, tech_id, entity_table="storage_technologies")
    conn.execute(
        "INSERT INTO storage_technologies("
        "id, name, prime_mover_type, region, power_systems_type, financial_data, "
        "operation_costs) VALUES (?, 'st', 'BA', '[\"r\"]', 'EnergyReservoirStorage', "
        "'{}', ?)",
        (tech_id, operation_costs),
    )


@pytest.mark.parametrize(
    "operation_cost",
    [
        _storage_cost(charge_pu="SYSTEM_BASE"),
        _storage_cost(discharge_pu="DEVICE_BASE"),
    ],
)
def test_storage_unit_relative_base_cost_rejected(fresh_db, operation_cost):
    """[2] StorageCost with a relative base on EITHER charge or discharge variable
    cost must be rejected. The old guard probed $.variable.power_units, a key that
    does not exist on StorageCost, so it was DEAD (never fired)."""
    topo = _setup_topology(fresh_db)
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        _insert_storage_unit(fresh_db, 2, topo, operation_cost)


def test_storage_unit_natural_units_cost_accepted(fresh_db):
    topo = _setup_topology(fresh_db)
    _insert_storage_unit(fresh_db, 2, topo, _storage_cost())
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM storage_units"
    ).fetchone()
    assert count == 1


@pytest.mark.parametrize(
    "operation_costs",
    [
        _storage_cost(charge_pu="SYSTEM_BASE"),
        _storage_cost(discharge_pu="DEVICE_BASE"),
    ],
)
def test_storage_technology_relative_base_cost_rejected(fresh_db, operation_costs):
    """[2] storage_technologies.operation_costs StorageCost guard (charge/discharge)."""
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        _insert_storage_technology(fresh_db, 2, operation_costs)


def test_storage_technology_natural_units_cost_accepted(fresh_db):
    _insert_storage_technology(fresh_db, 2, _storage_cost())
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM storage_technologies"
    ).fetchone()
    assert count == 1


def test_every_cost_bearing_table_has_both_cost_unit_triggers(db):
    """Every table with an operation_cost(s) convention row must carry BOTH its
    cost-unit guard triggers (insert + update). Derived from
    column_conventions.json so a newly cost-bearing table without a guard fails.
    """
    conventions = json.loads(
        (SCHEMA_DIR / "column_conventions.json").read_text(encoding="utf-8")
    )["conventions"]
    cost_tables = {
        row["table"]
        for row in conventions
        if row["column"].startswith("operation_cost")
        or row["column"].startswith("operation_costs")
    }
    assert cost_tables, "no operation_cost* convention rows found"

    triggers = {
        row[0]
        for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='trigger'"
        ).fetchall()
    }
    missing = []
    for table in sorted(cost_tables):
        for action in ("insert", "update"):
            name = f"validate_{table}_cost_units_{action}"
            if name not in triggers:
                missing.append(name)
    assert missing == [], f"cost-bearing tables missing guard triggers: {missing}"


# --------------------------------------------------------------------------- #
# Completeness
# --------------------------------------------------------------------------- #
def _table_columns(conn, table):
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()}


def test_completeness_registered_columns_exist(db):
    """Every registered (table, column) resolves to a real column.

    Plain columns (no discriminator, table != attributes, no dot) must exist per
    pragma. JSON-path columns (dotted) require their base column to exist.
    attributes rows are logical names, not physical columns -> skipped here.
    """
    rows = db.execute(
        "SELECT table_name, column_name, discriminator_column FROM unit_conventions"
    ).fetchall()
    missing = []
    for table_name, column_name, discriminator in rows:
        if table_name == "attributes":
            continue
        base_column = column_name.split(".")[0]
        columns = _table_columns(db, table_name)
        if base_column not in columns:
            missing.append((table_name, column_name))
    assert missing == [], f"registered columns absent from schema: {missing}"


def test_completeness_attributes_rows_whitelisted(db):
    """attributes convention rows are logical names, not physical columns; they
    are simply whitelisted (must not be treated as missing columns)."""
    rows = db.execute(
        "SELECT DISTINCT column_name FROM unit_conventions WHERE table_name = 'attributes'"
    ).fetchall()
    assert len(rows) > 0


def test_completeness_cost_bearing_tables_have_guard_triggers(db):
    """Every table with an operation_cost* convention row must carry the
    cost-payload guard trigger pair, so registering a new cost-bearing table
    without extending triggers.sql fails here instead of silently."""
    # Any operation_cost-prefixed column marks a cost-bearing table: dotted
    # JSON-path rows (operation_cost.variable), discriminated whole-blob rows,
    # and non-discriminated whole-blob rows (e.g. hydro_reservoirs) alike.
    tables = {
        row[0]
        for row in db.execute(
            "SELECT DISTINCT table_name FROM unit_conventions"
            " WHERE column_name LIKE 'operation_cost%'"
        )
    }
    assert len(tables) >= 7
    triggers = {
        row[0]
        for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'")
    }
    missing = []
    for table in sorted(tables):
        for event in ("insert", "update"):
            name = f"validate_{table}_cost_units_{event}"
            if name not in triggers:
                missing.append(name)
    assert missing == [], f"cost-bearing tables without guard triggers: {missing}"


def test_completeness_all_physical_columns_registered_or_allowlisted(db):
    """Reverse check: every REAL/JSON column on an entity table is either
    unit-registered or in COMPLETENESS_ALLOWLIST. Guards against silently
    unregistered future columns.

    Entity tables are sourced from sqlite_master (type='table') rather than
    DISTINCT unit_conventions.table_name so tables that happen to have no
    registered columns still participate in the check.
    """
    # Registry/metadata/view internals excluded from the physical-column scan.
    REGISTRY_INTERNALS = {
        "unit_conventions",
        "quantity_types",
        "allowed_units",
        "unit_management_metadata",
        "sqlite_sequence",
        "attributes",
    }
    entity_tables = [
        row[0]
        for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        if row[0] not in REGISTRY_INTERNALS
    ]

    registered = {}
    for table_name, column_name in db.execute(
        "SELECT table_name, column_name FROM unit_conventions WHERE table_name != 'attributes'"
    ).fetchall():
        registered.setdefault(table_name, set()).add(column_name.split(".")[0])

    unregistered = []
    for table in entity_tables:
        for row in db.execute(f"PRAGMA table_info({table})").fetchall():
            name, ctype = row[1], row[2]
            if ctype not in ("REAL", "JSON"):
                continue
            if name in registered.get(table, set()):
                continue
            if (table, name) in COMPLETENESS_ALLOWLIST:
                continue
            unregistered.append((table, name))
    assert unregistered == [], (
        "physical REAL/JSON columns neither registered nor allow-listed: "
        f"{unregistered}"
    )


# --------------------------------------------------------------------------- #
# EmissionsData supplemental-attribute payload guard
# --------------------------------------------------------------------------- #
EMISSIONS_OK = (
    '{"name": "co2_rate", "pollutant": "CO2", "basis": "FUEL_INPUT",'
    ' "energy_unit": "MMBTU", "mass_unit": "KG", "start_up_adder": 0.0,'
    ' "gwp": 1.0, "emission_rate": {}}'
)


def insert_supplemental(conn, entity_id, type_name, value):
    conn.execute(
        "INSERT INTO supplemental_attributes(id, TYPE, value) VALUES (?, ?, ?)",
        (entity_id, type_name, value),
    )


def make_supplemental_entity(conn, entity_id):
    return make_entity(
        conn, entity_id,
        entity_table="supplemental_attributes",
        entity_type="EmissionsData",
    )


def test_emissions_payload_valid_accepted(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    insert_supplemental(fresh_db, 1, "EmissionsData", EMISSIONS_OK)
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM supplemental_attributes"
    ).fetchone()
    assert count == 1


def test_emissions_payload_bad_mass_unit_rejected(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    bad = EMISSIONS_OK.replace('"KG"', '"BANANAS"')
    with pytest.raises(sqlite3.IntegrityError, match="MassUnit"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_payload_bad_pollutant_rejected(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    bad = EMISSIONS_OK.replace('"CO2"', '"SMOG"')
    with pytest.raises(sqlite3.IntegrityError, match="PollutantType"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_fuel_input_with_mwh_rejected(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    bad = EMISSIONS_OK.replace('"MMBTU"', '"MWH"')
    with pytest.raises(sqlite3.IntegrityError, match="basis-consistent"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_power_output_requires_mwh(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    ok = EMISSIONS_OK.replace('"FUEL_INPUT"', '"POWER_OUTPUT"').replace(
        '"MMBTU"', '"MWH"'
    )
    insert_supplemental(fresh_db, 1, "EmissionsData", ok)
    make_supplemental_entity(fresh_db, 2)
    bad = EMISSIONS_OK.replace('"FUEL_INPUT"', '"POWER_OUTPUT"')
    with pytest.raises(sqlite3.IntegrityError, match="basis-consistent"):
        insert_supplemental(fresh_db, 2, "EmissionsData", bad)


def test_emissions_update_to_bad_enum_rejected(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    insert_supplemental(fresh_db, 1, "EmissionsData", EMISSIONS_OK)
    bad = EMISSIONS_OK.replace('"KG"', '"STONES"')
    with pytest.raises(sqlite3.IntegrityError, match="MassUnit"):
        fresh_db.execute(
            "UPDATE supplemental_attributes SET value = ? WHERE id = 1", (bad,)
        )


def test_emissions_optional_fields_absent_pass(fresh_db):
    """Absent OPTIONAL fields (mass_unit) do not trip the guard, as long as the
    schema-required enum fields (pollutant, basis, energy_unit) are present."""
    make_supplemental_entity(fresh_db, 1)
    insert_supplemental(
        fresh_db,
        1,
        "EmissionsData",
        '{"name": "minimal", "pollutant": "CO2", "basis": "FUEL_INPUT",'
        ' "energy_unit": "MMBTU", "emission_rate": {}}',
    )
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM supplemental_attributes"
    ).fetchone()
    assert count == 1


def test_emissions_power_output_missing_energy_unit_rejected(fresh_db):
    """[4] regression: basis=POWER_OUTPUT with energy_unit OMITTED must be
    rejected. Previously the ``energy_unit <> 'MWH'`` term evaluated to NULL
    (not TRUE) when energy_unit was absent, silently passing the insert."""
    make_supplemental_entity(fresh_db, 1)
    bad = (
        '{"name": "co2_rate", "pollutant": "CO2", "basis": "POWER_OUTPUT",'
        ' "mass_unit": "KG", "emission_rate": {}}'
    )
    with pytest.raises(sqlite3.IntegrityError, match="basis-consistent"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_fuel_input_missing_energy_unit_rejected(fresh_db):
    """basis=FUEL_INPUT with energy_unit OMITTED must be rejected (NULL-safe)."""
    make_supplemental_entity(fresh_db, 1)
    bad = (
        '{"name": "co2_rate", "pollutant": "CO2", "basis": "FUEL_INPUT",'
        ' "mass_unit": "KG", "emission_rate": {}}'
    )
    with pytest.raises(sqlite3.IntegrityError, match="basis-consistent"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_missing_required_pollutant_rejected(fresh_db):
    """A required enum field (pollutant) absent from the payload is a violation."""
    make_supplemental_entity(fresh_db, 1)
    bad = (
        '{"name": "x", "basis": "FUEL_INPUT", "energy_unit": "MMBTU",'
        ' "emission_rate": {}}'
    )
    with pytest.raises(sqlite3.IntegrityError, match="EmissionsData payload"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_emissions_missing_required_basis_rejected(fresh_db):
    """A required enum field (basis) absent from the payload is a violation."""
    make_supplemental_entity(fresh_db, 1)
    bad = (
        '{"name": "x", "pollutant": "CO2", "energy_unit": "MMBTU",'
        ' "emission_rate": {}}'
    )
    with pytest.raises(sqlite3.IntegrityError, match="EmissionsData payload"):
        insert_supplemental(fresh_db, 1, "EmissionsData", bad)


def test_other_supplemental_types_unaffected(fresh_db):
    make_supplemental_entity(fresh_db, 1)
    insert_supplemental(
        fresh_db, 1, "GeographicInfo", '{"geo_json": {}, "mass_unit": "whatever"}'
    )


# --------------------------------------------------------------------------- #
# EmissionsData enum drift gate: the trigger hardcodes the pollutant / mass_unit
# / energy_unit / basis enum members copied from EmissionsData.json's
# properties (each a $ref into Core/common.json definitions). If someone edits
# one of these enums in the schemas without updating the trigger, this test
# FAILS. It does not change the trigger's values; it locks them to the schema
# source of truth.
# --------------------------------------------------------------------------- #
import posixpath  # noqa: E402
import re  # noqa: E402

# EmissionsData.json property names carrying an enum the trigger probes.
_EMISSIONS_ENUM_FIELDS = ["pollutant", "mass_unit", "energy_unit", "basis"]

EMISSIONS_DATA_REL = "Operations/SupplementalAttributes/EmissionsData.json"


def _schema_enum(prop, current_rel_file=EMISSIONS_DATA_REL):
    """Return a property's enum members, following a relative ``$ref`` into its
    target file (e.g. ``../../Core/common.json#/definitions/PollutantType``)
    when the enum is not inline."""
    if "enum" in prop:
        return prop["enum"]
    rel, frag = prop["$ref"].split("#", 1)
    target = posixpath.normpath(
        posixpath.join(posixpath.dirname(current_rel_file), rel)
    )
    node = load_schemas_json(target)
    for part in frag.strip("/").split("/"):
        node = node[part]
    return node["enum"]


def _extract_trigger_in_lists(trigger_sql):
    """Extract the ``NOT IN (...)`` enum member lists for each probed field from
    an EmissionsData trigger body, keyed by field name."""
    lists = {}
    for field in _EMISSIONS_ENUM_FIELDS:
        m = re.search(
            r"\$\." + re.escape(field) + r"'\)\s*NOT IN\s*\(([^)]*)\)",
            trigger_sql,
        )
        assert m is not None, f"no NOT IN list found for '{field}' in trigger"
        members = re.findall(r"'([^']*)'", m.group(1))
        lists[field] = members
    return lists


@pytest.mark.parametrize("action", ["insert", "update"])
def test_emissions_enum_lists_match_schema(db, action):
    """DRIFT GATE: the hardcoded enum members in the EmissionsData guard trigger
    must exactly equal the enum arrays reachable from
    SiennaSchemas/Operations/SupplementalAttributes/EmissionsData.json's
    properties (via their Core/common.json $refs). Editing an enum there
    without updating the trigger (or vice versa) fails here."""
    properties = load_schemas_json(EMISSIONS_DATA_REL)["properties"]

    (trigger_sql,) = db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
        (f"validate_supplemental_emissions_{action}",),
    ).fetchone()
    trigger_lists = _extract_trigger_in_lists(trigger_sql)

    for field in _EMISSIONS_ENUM_FIELDS:
        schema_members = _schema_enum(properties[field])
        assert trigger_lists[field] == schema_members, (
            f"{field} enum drift: trigger has {trigger_lists[field]} but "
            f"EmissionsData.json has {schema_members}"
        )


# --------------------------------------------------------------------------- #
# Flexible unit-basis columns (PSS/E-sourced fields, UIP Phase 2)
# --------------------------------------------------------------------------- #
def test_flexible_basis_columns_registered(db):
    """Every discriminated PSS/E-sourced column added in Phase 2 has exactly the
    expected set of basis rows in unit_conventions -- no missing or extra basis."""
    expected = {
        ("fixed_admittance", "y_b"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("fixed_admittance", "y_g"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("sources", "r_th"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("sources", "x_th"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_lcc_lines", "r"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_lcc_lines", "scheduled_dc_voltage"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_lcc_lines", "switch_mode_voltage"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_lcc_lines", "min_compounding_voltage"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_vsc_lines", "g"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("two_terminal_vsc_lines", "voltage_limits_from"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_vsc_lines", "voltage_limits_to"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("facts_control_devices", "voltage_setpoint"): {"SYSTEM_BASE", "NATURAL_UNITS"},
    }
    for (table, col), bases in expected.items():
        rows = db.execute(
            "SELECT discriminator_value FROM unit_conventions "
            "WHERE table_name=? AND column_name=?", (table, col)
        ).fetchall()
        got = {r[0] for r in rows}
        assert got == bases, f"{table}.{col}: {got} != {bases}"


def test_vsc_setpoints_two_discriminator(db):
    """VSC dc_setpoint_from/ac_setpoint_from are mode-multiplexed by
    dc_control_from/ac_control_from; their voltage-mode rows carry a second
    discriminator (voltage_units) so pu vs kV is also explicit."""
    rows = set(db.execute(
        "SELECT column_name, discriminator_value, discriminator_value_2, quantity_type, unit "
        "FROM unit_conventions WHERE table_name='two_terminal_vsc_lines' "
        "AND column_name IN ('dc_setpoint_from','ac_setpoint_from')"
    ).fetchall())
    assert ('dc_setpoint_from','DC_POWER',None,'ActivePower','MW') in rows
    assert ('dc_setpoint_from','DC_VOLTAGE','SYSTEM_BASE','Voltage','pu') in rows
    assert ('dc_setpoint_from','DC_VOLTAGE','NATURAL_UNITS','Voltage','kV') in rows
    assert ('ac_setpoint_from','AC_VOLTAGE','SYSTEM_BASE','Voltage','pu') in rows
    assert ('ac_setpoint_from','AC_REACTIVE_POWER',None,'PowerFactor','1') in rows


def test_interconnecting_converter_setpoints_two_discriminator(db):
    """InterconnectingConverter dc_setpoint/ac_setpoint are mode-multiplexed by
    dc_control/ac_control, the same enums used by TwoTerminalVSCLine; their
    voltage-mode rows carry a second discriminator (voltage_setpoint_units) so
    pu vs kV is also explicit."""
    rows = set(db.execute(
        "SELECT column_name, discriminator_value, discriminator_value_2, quantity_type, unit "
        "FROM unit_conventions WHERE table_name='interconnecting_converters' "
        "AND column_name IN ('dc_setpoint','ac_setpoint')"
    ).fetchall())
    assert ('dc_setpoint','DC_POWER',None,'ActivePower','MW') in rows
    assert ('dc_setpoint','DC_VOLTAGE','SYSTEM_BASE','Voltage','pu') in rows
    assert ('ac_setpoint','AC_VOLTAGE','NATURAL_UNITS','Voltage','kV') in rows
