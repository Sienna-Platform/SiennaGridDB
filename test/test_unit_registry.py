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
# +3 for the Duration split: CalendarPeriod (yr, planning spans), OperationalDuration
# (min, scheduling durations), FractionPerTime (1/min, decay/self-discharge rates) --
# Duration itself stays but is re-typed to seconds-only (continuous time constants).
EXPECTED_QUANTITY_TYPES = 41
# +1 MJ for ElectricalEnergy (RealEnergy rename), +1 Mt/MWh for EmissionRate (carbon caps),
# -1 Temperature/degC (unused, removed)
# Duration split: -3 (Duration/h, Duration/min, Duration/yr all dropped),
# +4 (CalendarPeriod/yr, OperationalDuration/min, FractionPerTime/1/min, ElectricalEnergy/MWmin)
# +6 upstream scale units (ActivePower kW/GW/TW, ElectricalEnergy kWh/GWh/TWh)
EXPECTED_ALLOWED_UNITS = 62
# +3 for discrete_controlled_ac_branches.{r,x,rating}
# +49 for the transformer tables: transformer_circuits (36: tap, alpha, r, x,
# 12 control_limits + 12 controlled_quantity_limits discriminated by
# control_objective, ratings, flows, base power/voltages),
# three_winding_transformers (11: pairwise r/x, pairwise base powers,
# magnetizing_shunt.real/.imag), two_winding_transformers (2:
# magnetizing_shunt.real/.imag)
# HVDC consolidation: -45 (the two_terminal_lcc_lines and two_terminal_vsc_lines
# tables are gone), +5 for two_terminal_hvdc_lines' own columns, +29 fixed
# attributes.* conventions for the demoted fields whose unit is unambiguous.
# +2 for the transformer_circuits.{r,x} natural-units arms (discriminated like
# transmission_lines).
# +5 for synchronous_condensers (PSY SynchronousCondenser: the schema component
# existed but the DB had no table for it at all).
# +20 attributes.* conventions for the physical quantities that previously had no
# convention at all (bus voltage/angle, branch flows, load and area powers,
# technology voltage/capacity/costs), each traced to a schema x-unit annotation.
# +16 for the sources coverage close-out (8 physical columns, 2 ImportExportCost
# weekly energy limits, 6 discriminated import/export offer curve arms).
# +17 net for curve-form-aware variable costs: each operation_cost.<curve> row
# becomes one row per declared curve form (INPUT_OUTPUT is a cost rate, USD/h;
# INCREMENTAL and AVERAGE_RATE are per-energy, USD/MWh), plus FuelCurve heat-rate
# arms where the schema permits one, and storage_units' bogus .variable path
# replaced by .charge_variable_cost/.discharge_variable_cost.
# +2 for transmission_lines.base_power and discrete_controlled_ac_branches.base_power:
# a per-row snapshot of the system base their SYSTEM_BASE r/x/b/g arm normalizes
# against (previously unrecorded anywhere in the database).
# +4 for the base columns added alongside the two-basis-units design that were never
# registered: balancing_topologies.base_voltage, fixed_admittance.base_power,
# switched_admittance.base_power, tmodel_hvdc_lines.base_power -- each a per-row
# snapshot of the base its own table's COMPONENT_BASE arm normalizes against,
# registered the same way as the pre-existing base columns above.
# +1 for the EnergyReservoirStorage vocabulary absorption: storage_capacity becomes
# polymorphic on the new energy_units discriminator (one row -> two, MWh/MWmin), and
# self_discharge retypes from Fraction/1 to FractionPerTime/1/min (still one row).
# -2 for the infrastore-mirror time-series redesign: time_series_metadata (and its
# base_power/base_voltage snapshots) is gone; units ride the association row and a
# COMPONENT_BASE series is interpreted against its owner's own base columns.
# +6 for the three_winding_transformers two-basis absorption: r_12/x_12/r_23/x_23/
# r_31/x_31 each gain a NATURAL_UNITS ohm arm alongside the existing pu arm, now
# discriminated by the new unit_basis column (upstream parameter_units pattern).
# +2 attribute-name conventions for the TwoTerminalVSCLine rated AC voltages
# (kV; rated_dc_voltage was already registered). The basis-dependent VSC fields
# (voltage_limits_from/to, dc_voltage_droop_from/to) stay unregistered: a pu
# attributes row has no resolvable base -- the polymorphic-owner exemption is
# reserved for the bus-owned magnitude/voltage_limits pair.
EXPECTED_UNIT_CONVENTIONS = 340

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
    # structural value columns; units live on time_series_associations for series data
    ("static_time_series", "value"),
    # structural value column; units live in attribute conventions for supplemental attrs
    ("supplemental_attributes", "value"),
    # structural TYPE+value JSON store (like supplemental_attributes); no fixed unit
    ("plants", "value"),
    # typed feature-map value column (infrastore mirror); features carry no unit
    ("feature_sets", "value_float"),
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
# Time series (infrastore-mirror catalog)
# --------------------------------------------------------------------------- #
def _insert_association(
    conn,
    owner_id,
    units=None,
    quantity_kind=None,
    uri="static:load-1",
    owner_category=0,
    name="load",
    association_id=None,
):
    # association_id is store-minted and NOT NULL; default it off owner_id so the
    # common single-row case needs no argument and stays unique.
    if association_id is None:
        association_id = owner_id
    conn.execute(
        "INSERT INTO time_series_associations("
        "association_id, owner_id, owner_type, owner_category, time_series_type, name, "
        "initial_timestamp, resolution, length, units, quantity_kind, "
        "uri, data_hash, features_hash) "
        "VALUES (?, ?, 'thing', ?, 0, ?, '2020-01-01T00:00:00', 'PT1H', 24, ?, ?, "
        "?, ?, ?)",
        (association_id, owner_id, owner_category, name, units, quantity_kind, uri,
         b"\x01" * 32, b"\x02" * 32),
    )


def test_static_time_series_without_association_rejected(fresh_db):
    with pytest.raises(
        sqlite3.IntegrityError,
        match=r"static_time_series\.uri must exist in time_series_associations",
    ):
        fresh_db.execute(
            "INSERT INTO static_time_series(uri, idx, value) "
            "VALUES ('static:load-1', 0, 1.0)"
        )


def test_static_time_series_with_association_accepted(fresh_db):
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO static_time_series(uri, idx, value) VALUES ('static:load-1', 0, 1.0)"
    )
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM static_time_series WHERE uri = 'static:load-1'"
    ).fetchone()
    assert count == 1


def test_static_time_series_update_uri_to_orphan_rejected(fresh_db):
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO static_time_series(uri, idx, value) VALUES ('static:load-1', 0, 1.0)"
    )
    with pytest.raises(
        sqlite3.IntegrityError,
        match=r"static_time_series\.uri must exist in time_series_associations",
    ):
        fresh_db.execute("UPDATE static_time_series SET uri = 'static:orphan'")


def test_association_data_hash_optional(fresh_db):
    """data_hash is the OPTIONAL integrity hash per the SiennaSchemas wire
    form; uri is what locates the dense values."""
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_associations("
        "association_id, owner_id, owner_type, owner_category, time_series_type, name, "
        "initial_timestamp, resolution, length, uri, features_hash) "
        "VALUES (1, 1, 'thing', 0, 0, 'nohash', '2020-01-01T00:00:00', 'PT1H', 24, "
        "'static:nohash', ?)",
        (b"\x02" * 32,),
    )
    (stored,) = fresh_db.execute(
        "SELECT data_hash FROM time_series_associations WHERE name = 'nohash'"
    ).fetchone()
    assert stored is None


def test_association_registered_quantity_kind_bad_unit_rejected(fresh_db):
    make_entity(fresh_db, 1)
    with pytest.raises(
        sqlite3.IntegrityError,
        match="registered .quantity_kind, units. pair",
    ):
        _insert_association(fresh_db, 1, units="bananas", quantity_kind="ActivePower")


def test_association_registered_quantity_kind_missing_unit_rejected(fresh_db):
    make_entity(fresh_db, 1)
    with pytest.raises(
        sqlite3.IntegrityError,
        match="registered .quantity_kind, units. pair",
    ):
        _insert_association(fresh_db, 1, units=None, quantity_kind="ActivePower")


def test_association_registered_pair_accepted(fresh_db):
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1, units="MW", quantity_kind="ActivePower")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE units = 'MW'"
    ).fetchone()
    assert count == 1


def test_association_freeform_quantity_kind_accepted(fresh_db):
    """quantity_kind is deliberately unconstrained (mirroring infrastore):
    composite economic quantities pass with any unit spelling. Only a
    REGISTERED quantity-type name pulls in the allowed_units guard."""
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1, units="USD/MWh", quantity_kind="EnergyPrice2050")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE quantity_kind = 'EnergyPrice2050'"
    ).fetchone()
    assert count == 1


def test_association_null_units_and_kind_accepted(fresh_db):
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1)
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM time_series_associations WHERE units IS NULL"
    ).fetchone()
    assert count == 1


def test_association_uniqueness_null_resolution_enforced(fresh_db):
    """The COALESCE index must reject a duplicate identity even when resolution
    and interval are NULL (plain UNIQUE treats NULLs as distinct)."""
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_associations("
        "association_id, owner_id, owner_type, owner_category, time_series_type, name, "
        "uri, features_hash) VALUES (1, 1, 'thing', 0, 1, 'irregular', 'static:a', ?)",
        (b"\x04" * 32,),
    )
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        fresh_db.execute(
            "INSERT INTO time_series_associations("
            "association_id, owner_id, owner_type, owner_category, time_series_type, name, "
            "uri, features_hash) VALUES (2, 1, 'thing', 0, 1, 'irregular', 'static:b', ?)",
            (b"\x04" * 32,),
        )


def test_association_owner_category_attribute_domain_enforced(fresh_db):
    """owner_category = 1 requires the owner to be a supplemental attribute."""
    make_entity(fresh_db, 1)
    with pytest.raises(
        sqlite3.IntegrityError,
        match=r"owner_id must exist in supplemental_attributes",
    ):
        _insert_association(fresh_db, 1, owner_category=1)
    make_entity(fresh_db, 2, entity_table="supplemental_attributes")
    fresh_db.execute(
        "INSERT INTO supplemental_attributes(id, TYPE, value) VALUES (2, 'geo', '{}')"
    )
    _insert_association(fresh_db, 2, owner_category=1)


def test_time_series_readable_decodes_codes_and_hashes(fresh_db):
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1)
    row = fresh_db.execute(
        "SELECT owner_category, time_series_type, data_hash, timestamps_hash "
        "FROM time_series_readable"
    ).fetchone()
    assert row == ("Component", "SingleTimeSeries", "01" * 32, None)


def test_association_id_is_projected_by_readable_view(fresh_db):
    """The store-minted id is what a cost payload references, so it must be
    visible in the decode projection alongside the rowid."""
    make_entity(fresh_db, 1)
    _insert_association(fresh_db, 1, association_id=4242)
    row = fresh_db.execute(
        "SELECT id, association_id FROM time_series_readable"
    ).fetchone()
    assert row[1] == 4242


def test_association_id_uniqueness_enforced(fresh_db):
    """Two associations cannot share a minted id: a cost payload referencing it
    must resolve to exactly one series."""
    make_entity(fresh_db, 1)
    make_entity(fresh_db, 2)
    _insert_association(fresh_db, 1, association_id=7, uri="static:a", name="a")
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        _insert_association(fresh_db, 2, association_id=7, uri="static:b", name="b")


def test_association_id_is_required(fresh_db):
    """NOT NULL: an association with no minted id is unreferenceable."""
    make_entity(fresh_db, 1)
    with pytest.raises(sqlite3.IntegrityError, match="NOT NULL"):
        fresh_db.execute(
            "INSERT INTO time_series_associations("
            "owner_id, owner_type, owner_category, time_series_type, name, "
            "uri, features_hash) VALUES (1, 'thing', 0, 0, 'x', 'static:x', ?)",
            (b"\x05" * 32,),
        )


def test_scenarios_association_carries_scenario_count(fresh_db):
    """Scenarios (time_series_type = 5) requires scenario_count alongside count
    per TimeSeries/Scenarios.json."""
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_associations("
        "association_id, owner_id, owner_type, owner_category, time_series_type, "
        "name, initial_timestamp, resolution, horizon, interval, count, "
        "scenario_count, uri, features_hash) "
        "VALUES (1, 1, 'thing', 0, 5, 'scen', '2020-01-01T00:00:00', 'PT1H', "
        "'PT24H', 'PT1H', 24, 10, 'static:scen', ?)",
        (b"\x06" * 32,),
    )
    row = fresh_db.execute(
        "SELECT time_series_type, count, scenario_count FROM time_series_readable"
    ).fetchone()
    assert row == ("Scenarios", 24, 10)


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
# Transmission-line unit_basis discriminator + STRICT
# --------------------------------------------------------------------------- #
def _insert_line(conn, entity_id, r=0.1, x=0.2, unit_basis=None):
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
    if unit_basis is not None:
        cols.append("unit_basis")
        vals.append(unit_basis)
    placeholders = ", ".join("?" for _ in cols)
    conn.execute(
        f"INSERT INTO transmission_lines({', '.join(cols)}) VALUES ({placeholders})",
        vals,
    )


def test_transmission_line_unit_basis_default_component_base(fresh_db):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    _insert_line(fresh_db, eid)
    (basis,) = fresh_db.execute(
        "SELECT unit_basis FROM transmission_lines WHERE id = ?", (eid,)
    ).fetchone()
    assert basis == "COMPONENT_BASE"


@pytest.mark.parametrize("unit_basis", ["COMPONENT_BASE", "NATURAL_UNITS"])
def test_transmission_line_unit_basis_valid_accepted(fresh_db, unit_basis):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    _insert_line(fresh_db, eid, unit_basis=unit_basis)
    (stored,) = fresh_db.execute(
        "SELECT unit_basis FROM transmission_lines WHERE id = ?", (eid,)
    ).fetchone()
    assert stored == unit_basis


def test_transmission_line_unit_basis_bad_value_rejected(fresh_db):
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint failed"):
        _insert_line(fresh_db, eid, unit_basis="VOLUME")


def test_transmission_line_r_text_rejected_under_strict(fresh_db):
    """STRICT is restored: a TEXT value in the REAL column r is a datatype mismatch."""
    eid = make_entity(fresh_db, 1, entity_table="transmission_lines")
    with pytest.raises(sqlite3.IntegrityError, match="REAL column"):
        _insert_line(fresh_db, eid, r="not_a_number")


def test_transmission_line_discriminated_registry_rows(db):
    """r/x/b/g each carry two discriminated rows (COMPONENT_BASE + NATURAL_UNITS)."""
    rows = db.execute(
        "SELECT column_name, discriminator_value, quantity_type, unit "
        "FROM unit_conventions WHERE table_name = 'transmission_lines' "
        "AND column_name IN ('r', 'x', 'b', 'g') "
        "AND discriminator_column = 'unit_basis' "
        "ORDER BY column_name, discriminator_value"
    ).fetchall()
    expected = [
        ("b", "COMPONENT_BASE", "Susceptance", "pu"),
        ("b", "NATURAL_UNITS", "Susceptance", "S"),
        ("g", "COMPONENT_BASE", "Conductance", "pu"),
        ("g", "NATURAL_UNITS", "Conductance", "S"),
        ("r", "COMPONENT_BASE", "Resistance", "pu"),
        ("r", "NATURAL_UNITS", "Resistance", "ohm"),
        ("x", "COMPONENT_BASE", "Reactance", "pu"),
        ("x", "NATURAL_UNITS", "Reactance", "ohm"),
    ]
    assert [tuple(r) for r in rows] == expected


# --------------------------------------------------------------------------- #
# Cost payloads
# --------------------------------------------------------------------------- #
def _thermal_production_cost(power_units):
    """The production curve is its own column; operation_cost keeps the rest and
    may not carry a `variable` copy (CHECK on thermal_generators.operation_cost)."""
    return (
        '{"variable_cost_type":"COST","power_units":"' + power_units + '",'
        '"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":'
        '{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}'
    )


def _setup_topology(conn, topo_id=1):
    """Create a balancing_topology (id ``topo_id``) generators can reference."""
    make_entity(conn, topo_id, entity_table="balancing_topologies", entity_type="topo")
    conn.execute("INSERT INTO balancing_topologies(id, name) VALUES (?, 'bt')", (topo_id,))
    return topo_id


def _insert_thermal(conn, gen_id, topo_id, production_cost):
    conn.execute("INSERT INTO prime_mover_types(name) VALUES ('CT')")
    conn.execute("INSERT INTO fuels(name) VALUES ('OTHER')")
    make_entity(conn, gen_id, entity_table="thermal_generators")
    conn.execute(
        "INSERT INTO thermal_generators("
        "id, name, prime_mover_type, fuel, balancing_topology, rating, base_power, "
        "active_power_limits, production_cost) "
        "VALUES (?, 'tg', 'CT', 'OTHER', ?, 1.0, 1.0, '{\"min\":0,\"max\":1}', ?)",
        (gen_id, topo_id, production_cost),
    )


@pytest.mark.parametrize("power_units", ["SYSTEM_BASE", "DEVICE_BASE"])
def test_cost_relative_base_variable_rejected(fresh_db, power_units):
    topo = _setup_topology(fresh_db)
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        _insert_thermal(fresh_db, 2, topo, _thermal_production_cost(power_units))


def test_cost_natural_units_variable_accepted(fresh_db):
    topo = _setup_topology(fresh_db)
    _insert_thermal(fresh_db, 2, topo, _thermal_production_cost("NATURAL_UNITS"))
    (count,) = fresh_db.execute("SELECT COUNT(*) FROM thermal_generators").fetchone()
    assert count == 1


def test_cost_update_relative_base_rejected(fresh_db):
    """UPDATE that changes production_cost to a relative-base payload is rejected."""
    topo = _setup_topology(fresh_db)
    _insert_thermal(fresh_db, 2, topo, _thermal_production_cost("NATURAL_UNITS"))
    with pytest.raises(
        sqlite3.IntegrityError, match="power_units must be NATURAL_UNITS"
    ):
        fresh_db.execute(
            "UPDATE thermal_generators SET production_cost = ? WHERE id = 2",
            (_thermal_production_cost("SYSTEM_BASE"),),
        )


def test_renewable_curtailment_cost_system_base_rejected(fresh_db):
    """curtailment_cost stays inside operation_cost, so it keeps its own guard."""
    topo = _setup_topology(fresh_db)
    make_entity(fresh_db, 2, entity_table="renewable_generators")
    fresh_db.execute("INSERT INTO prime_mover_types(name) VALUES ('PV')")
    curtailment_cost = (
        '{"cost_type":"RENEWABLE","fixed":0,'
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
    registry_internals = {
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
        if row[0] not in registry_internals
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
# Flexible unit-basis columns (externally-sourced fields, UIP Phase 2)
# --------------------------------------------------------------------------- #
def test_flexible_basis_columns_registered(db):
    """Every discriminated externally-sourced column added in Phase 2 has exactly the
    expected set of unit_basis discriminator values in unit_conventions -- no missing
    or extra basis. This only checks the DISTINCT discriminator_value set (two values,
    COMPONENT_BASE/NATURAL_UNITS, everywhere); it does not see that y_b/y_g pack TWO
    rows under one NATURAL_UNITS value (see test_admittance_natural_units_two_arms_registered
    for that finer-grained check)."""
    expected = {
        ("fixed_admittance", "y_b"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        ("fixed_admittance", "y_g"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        ("sources", "r_th"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        ("sources", "x_th"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        ("facts_control_devices", "voltage_setpoint"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        # Transformer circuits mirror transmission_lines: pu on the device base
        # or natural-units ohm, per the row's unit_basis.
        ("transformer_circuits", "r"): {"COMPONENT_BASE", "NATURAL_UNITS"},
        ("transformer_circuits", "x"): {"COMPONENT_BASE", "NATURAL_UNITS"},
    }
    for (table, col), bases in expected.items():
        rows = db.execute(
            "SELECT discriminator_value FROM unit_conventions "
            "WHERE table_name=? AND column_name=?", (table, col)
        ).fetchall()
        got = {r[0] for r in rows}
        assert got == bases, f"{table}.{col}: {got} != {bases}"


def test_merged_hvdc_columns_registered(db):
    """The consolidated two_terminal_hvdc_lines registers its own columns; the
    variant-specific fields live in attributes instead."""
    rows = dict(
        db.execute(
            "SELECT column_name, quantity_type || '/' || unit FROM unit_conventions "
            "WHERE table_name='two_terminal_hvdc_lines'"
        ).fetchall()
    )
    assert rows == {
        "active_power_flow": "ActivePower/MW",
        "active_power_limits_from": "ActivePower/MW",
        "active_power_limits_to": "ActivePower/MW",
        "reactive_power_limits_from": "ReactivePower/MVAr",
        "reactive_power_limits_to": "ReactivePower/MVAr",
    }
    for gone in ("two_terminal_lcc_lines", "two_terminal_vsc_lines"):
        assert not db.execute(
            "SELECT 1 FROM unit_conventions WHERE table_name=?", (gone,)
        ).fetchone(), f"{gone} conventions outlived the table"


@pytest.mark.parametrize(
    "name,expected",
    [
        # Physical quantities that previously had no convention at all.
        ("magnitude", "Voltage/pu"),
        ("base_voltage", "Voltage/kV"),
        ("angle", "Angle/rad"),
        ("angle_limits", "Angle/rad"),
        ("active_power_flow", "ActivePower/MW"),
        ("reactive_power_flow", "ReactivePower/MVAr"),
        ("max_active_power", "ActivePower/MW"),
        ("time_at_status", "OperationalDuration/min"),
        ("load_response", "PowerPerFrequency/MW/Hz"),
        ("voltage", "Voltage/kV"),
        ("value_of_lost_load", "CostPerEnergy/USD/MWh"),
        ("start_fuel_mmbtu_per_mw", "StartFuelPerCapacity/MMBtu/MW"),
        # A per-length impedance: Core/units.json has no ohm/km or pu/km, so no
        # valid pair exists to register and each row must state its own unit.
        ("resistance", None),
        ("reactance", None),
        # Curve blobs whose numeric leaves carry different dimensions.
        ("unserved_demand_curve", None),
        # Unambiguous unit -> registered, so a writer cannot get it wrong.
        ("rectifier_delay_angle", "Angle/deg"),
        ("inverter_extinction_angle_limits", "Angle/deg"),
        ("rectifier_bridges", "Dimensionless/1"),
        ("inverter_base_voltage", "Voltage/kV"),
        ("dc_current", "CurrentFlow/A"),
        ("rating_from", "ApparentPower/MVA"),
        ("reactive_power_to", "ReactivePower/MVAr"),
        ("rmpct_from", "Fraction/1"),
        # Unit depends on a basis choice or a sibling control mode. A convention's
        # discriminator_column names a sibling *column*, which an attributes row
        # does not have, so these stay unregistered and each row carries its own
        # unit/quantity_type (validated against allowed_units by the insert trigger).
        ("r", None),
        ("rectifier_rc", None),
        ("scheduled_dc_voltage", None),
        ("g", None),
        ("voltage_limits_from", None),
        ("dc_setpoint_from", None),
        ("ac_setpoint_to", None),
        ("transfer_setpoint", None),
        ("dc_voltage_droop_from", None),
        ("loss", None),
        ("converter_loss_from", None),
    ],
)
def test_demoted_hvdc_attribute_conventions(db, name, expected):
    rows = db.execute(
        "SELECT quantity_type || '/' || unit FROM unit_conventions "
        "WHERE table_name='attributes' AND LOWER(column_name)=LOWER(?)",
        (name,),
    ).fetchall()
    if expected is None:
        assert rows == [], f"attributes.{name} should stay unregistered, got {rows}"
    else:
        assert [r[0] for r in rows] == [expected]


def test_interconnecting_converter_setpoints_two_discriminator(db):
    """InterconnectingConverter dc_setpoint/ac_setpoint are mode-multiplexed by
    dc_control/ac_control, the same enums used by TwoTerminalVSCLine; their
    voltage-mode rows carry a second discriminator (unit_basis) so pu vs kV is
    also explicit."""
    rows = set(db.execute(
        "SELECT column_name, discriminator_value, discriminator_value_2, quantity_type, unit "
        "FROM unit_conventions WHERE table_name='interconnecting_converters' "
        "AND column_name IN ('dc_setpoint','ac_setpoint')"
    ).fetchall())
    assert ('dc_setpoint','DC_POWER',None,'ActivePower','MW') in rows
    assert ('dc_setpoint','DC_VOLTAGE','COMPONENT_BASE','Voltage','pu') in rows
    assert ('ac_setpoint','AC_VOLTAGE','NATURAL_UNITS','Voltage','kV') in rows


# --------------------------------------------------------------------------- #
# Basis resolvability invariant (UIP two-basis-units design): every pu
# convention names a unit_basis_rules entry and every base ref it declares
# resolves to a real, reachable column. generate_unit_registry.py does not
# validate this (see the design ledger's Task 3 note) -- this is the only
# check that catches a typo'd ref or a new pu column with no rule.
# --------------------------------------------------------------------------- #
ATTRIBUTES_BASE_REF_EXEMPT = {("attributes", "magnitude"), ("attributes", "voltage_limits")}


def _table_exists(conn, table):
    return conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone() is not None


def _is_entity_subtype(conn, table):
    """True if table.id is itself an FK to entities(id) -- the table-per-type
    pattern every concrete entity table follows."""
    return any(
        fk[2] == "entities" and fk[3] == "id" and fk[4] == "id"
        for fk in conn.execute(f"PRAGMA foreign_key_list({table})")
    )


def _resolves_ref(conn, table, ref):
    """Resolve a base_power_ref/base_voltage_ref path.

    No '->': a same-row column, checked directly. With '->': a chain of FK
    hops ``local_col->table.col[->table.col...]``; each hop's local column
    must be a genuine FK on the current table, targeting either the named
    table directly or ``entities`` when the named table is itself an
    entities-subtype (id REFERENCES entities(id)) -- the table-per-type
    pattern arcs.from_id/to_id use (they FK to entities; the concrete subtype
    is resolved by entity_type/application convention, not a row-level FK to
    the concrete table, e.g. arc endpoints are always balancing_topologies in
    practice but the FK itself only promises "some entity"). The final
    segment names the base column itself, which must exist as a real column
    (no FK requirement) on the last table in the chain.
    """
    if "->" not in ref:
        return ref in _table_columns(conn, table)
    parts = ref.split("->")
    current_table = table
    local_col = parts[0]
    for hop in parts[1:]:
        target_table, target_col = hop.split(".", 1)
        if not _table_exists(conn, target_table):
            return False
        fks = list(conn.execute(f"PRAGMA foreign_key_list({current_table})"))
        matches = [fk for fk in fks if fk[3] == local_col]
        if not matches:
            return False
        direct = any(fk[2] == target_table for fk in matches)
        polymorphic = any(fk[2] == "entities" for fk in matches) and _is_entity_subtype(
            conn, target_table
        )
        if not (direct or polymorphic):
            return False
        current_table = target_table
        local_col = target_col
    return target_col in _table_columns(conn, current_table)


def test_pu_conventions_have_resolvable_basis(db):
    """THE resolvability invariant. For every unit='pu' convention (excluding
    the two documented attributes exemptions): (a) a unit_basis_rules row
    exists for its quantity_type, (b) it names at least one base ref, and (c)
    every base_power_ref/base_voltage_ref it declares resolves."""
    rows = db.execute(
        "SELECT table_name, column_name, quantity_type, base_power_ref, base_voltage_ref "
        "FROM unit_conventions WHERE unit = 'pu'"
    ).fetchall()
    assert rows, "no pu conventions found -- fixture/schema regression"

    rule_types = {r[0] for r in db.execute("SELECT quantity_type FROM unit_basis_rules")}

    exempt_seen = set()
    failures = []
    for table_name, column_name, quantity_type, base_power_ref, base_voltage_ref in rows:
        key = (table_name, column_name)
        if table_name == "attributes":
            exempt_seen.add(key)
            if key not in ATTRIBUTES_BASE_REF_EXEMPT:
                failures.append(
                    f"{table_name}.{column_name}: pu attributes row not in the "
                    "documented base-ref exemption allowlist"
                )
            continue

        if quantity_type not in rule_types:
            failures.append(
                f"{table_name}.{column_name}: no unit_basis_rules row for "
                f"quantity_type={quantity_type}"
            )

        if base_power_ref is None and base_voltage_ref is None:
            failures.append(
                f"{table_name}.{column_name}: pu row carries neither "
                "base_power_ref nor base_voltage_ref"
            )

        for label, ref in (
            ("base_power_ref", base_power_ref),
            ("base_voltage_ref", base_voltage_ref),
        ):
            if ref is None:
                continue
            if not _resolves_ref(db, table_name, ref):
                failures.append(
                    f"{table_name}.{column_name}.{label}={ref!r} does not resolve"
                )

    assert failures == [], "\n".join(failures)
    assert exempt_seen == ATTRIBUTES_BASE_REF_EXEMPT, (
        "attributes pu rows exempt from base refs must be EXACTLY "
        f"{ATTRIBUTES_BASE_REF_EXEMPT}, got {exempt_seen}"
    )


# --------------------------------------------------------------------------- #
# unit_basis CHECK constraint, on every table that carries the column (derived
# from a scratch build of the live schema, not hardcoded, so a newly added
# table is covered automatically).
# --------------------------------------------------------------------------- #
def _discover_unit_basis_tables():
    conn = sqlite3.connect(":memory:")
    conn.execute("PRAGMA foreign_keys = ON")
    for sql_file in (
        SCHEMA_DIR / "schema.sql",
        SCHEMA_DIR / "triggers.sql",
        SCHEMA_DIR / "unit_registry.sql",
        SCHEMA_DIR / "views.sql",
    ):
        conn.executescript(sql_file.read_text())
    tables = [
        row[0]
        for row in conn.execute(
            "SELECT DISTINCT m.name FROM sqlite_master m "
            "JOIN pragma_table_info(m.name) p "
            "WHERE m.type = 'table' AND p.name = 'unit_basis' "
            "ORDER BY 1"
        )
    ]
    conn.close()
    return tables


UNIT_BASIS_TABLES = _discover_unit_basis_tables()


def _provision_bus(conn, bus_id, is_dc=0):
    entity_type = "DCBus" if is_dc else "ACBus"
    make_entity(
        conn, bus_id, entity_table="balancing_topologies", entity_type=entity_type,
        is_topology=1, is_dc=is_dc,
    )
    conn.execute(
        "INSERT INTO balancing_topologies(id, name) VALUES (?, ?)", (bus_id, f"bus_{bus_id}")
    )
    return bus_id


def _provision_arc(conn, arc_id, is_dc=0):
    make_entity(conn, arc_id, entity_table="arcs")
    from_id, to_id = arc_id + 1, arc_id + 2
    _provision_bus(conn, from_id, is_dc=is_dc)
    _provision_bus(conn, to_id, is_dc=is_dc)
    conn.execute("INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)", (arc_id, from_id, to_id))
    return arc_id


def _build_transmission_line(conn, base_id, unit_basis):
    arc = _provision_arc(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="transmission_lines", entity_type="Line")
    conn.execute(
        "INSERT INTO transmission_lines(id, name, arc_id, continuous_rating, r, x, unit_basis) "
        "VALUES (?, ?, ?, 100.0, 0.01, 0.1, ?)",
        (base_id, f"line_{base_id}", arc, unit_basis),
    )


def _build_transformer_circuit(conn, base_id, unit_basis):
    arc = _provision_arc(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="transformer_circuits", entity_type="Circuit")
    conn.execute(
        "INSERT INTO transformer_circuits(id, arc_id, unit_basis) VALUES (?, ?, ?)",
        (base_id, arc, unit_basis),
    )


def _build_three_winding_transformer(conn, base_id, unit_basis):
    circuits = [base_id * (i + 1) * 100 for i in range(3)]
    for circuit in circuits:
        _build_transformer_circuit(conn, circuit, unit_basis)
    star_bus = _provision_bus(conn, base_id * 400)
    make_entity(
        conn, base_id, entity_table="three_winding_transformers",
        entity_type="ThreeWindingTransformer",
    )
    conn.execute(
        "INSERT INTO three_winding_transformers("
        "id, name, primary_circuit, secondary_circuit, tertiary_circuit, star_bus, unit_basis"
        ") VALUES (?, ?, ?, ?, ?, ?, ?)",
        (base_id, f"twt_{base_id}", *circuits, star_bus, unit_basis),
    )


def _build_fixed_admittance(conn, base_id, unit_basis):
    bus = _provision_bus(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="fixed_admittance", entity_type="FixedAdmittance")
    conn.execute(
        "INSERT INTO fixed_admittance(id, name, bus, unit_basis) VALUES (?, ?, ?, ?)",
        (base_id, f"fa_{base_id}", bus, unit_basis),
    )


def _build_switched_admittance(conn, base_id, unit_basis):
    bus = _provision_bus(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="switched_admittance", entity_type="SwitchedAdmittance")
    conn.execute(
        "INSERT INTO switched_admittance(id, name, bus, unit_basis) VALUES (?, ?, ?, ?)",
        (base_id, f"sa_{base_id}", bus, unit_basis),
    )


def _build_source(conn, base_id, unit_basis):
    bus = _provision_bus(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="sources", entity_type="Source")
    conn.execute(
        "INSERT INTO sources(id, name, bus, r_th, x_th, unit_basis) VALUES (?, ?, ?, 0.0, 0.0, ?)",
        (base_id, f"src_{base_id}", bus, unit_basis),
    )


def _build_tmodel_hvdc_line(conn, base_id, unit_basis):
    arc = _provision_arc(conn, base_id * 100, is_dc=1)
    make_entity(conn, base_id, entity_table="tmodel_hvdc_lines", entity_type="TModelHVDCLine")
    conn.execute(
        "INSERT INTO tmodel_hvdc_lines(id, name, arc_id, r, unit_basis) VALUES (?, ?, ?, 0.01, ?)",
        (base_id, f"tm_{base_id}", arc, unit_basis),
    )


def _build_facts_control_device(conn, base_id, unit_basis):
    bus = _provision_bus(conn, base_id * 100)
    make_entity(conn, base_id, entity_table="facts_control_devices", entity_type="FACTSControlDevice")
    conn.execute(
        "INSERT INTO facts_control_devices(id, name, bus, voltage_setpoint, unit_basis) "
        "VALUES (?, ?, ?, 1.0, ?)",
        (base_id, f"facts_{base_id}", bus, unit_basis),
    )


def _build_interconnecting_converter(conn, base_id, unit_basis):
    ac_bus = _provision_bus(conn, base_id * 100, is_dc=0)
    dc_bus = _provision_bus(conn, base_id * 100 + 1, is_dc=1)
    make_entity(
        conn, base_id, entity_table="interconnecting_converters",
        entity_type="InterconnectingConverter",
    )
    conn.execute(
        "INSERT INTO interconnecting_converters(id, name, bus, dc_bus, unit_basis) "
        "VALUES (?, ?, ?, ?, ?)",
        (base_id, f"conv_{base_id}", ac_bus, dc_bus, unit_basis),
    )


UNIT_BASIS_BUILDERS = {
    "transmission_lines": _build_transmission_line,
    "transformer_circuits": _build_transformer_circuit,
    "three_winding_transformers": _build_three_winding_transformer,
    "fixed_admittance": _build_fixed_admittance,
    "switched_admittance": _build_switched_admittance,
    "sources": _build_source,
    "tmodel_hvdc_lines": _build_tmodel_hvdc_line,
    "facts_control_devices": _build_facts_control_device,
    "interconnecting_converters": _build_interconnecting_converter,
}


def test_unit_basis_tables_have_fixture_builders():
    """Guard: every table carrying unit_basis (discovered from the live schema)
    must have a builder above, so a newly added table gets real CHECK coverage
    below instead of silently falling through the parametrize."""
    missing = [t for t in UNIT_BASIS_TABLES if t not in UNIT_BASIS_BUILDERS]
    assert missing == [], f"tables with unit_basis but no test fixture builder: {missing}"


@pytest.mark.parametrize("table", UNIT_BASIS_TABLES)
@pytest.mark.parametrize("value", ["COMPONENT_BASE", "NATURAL_UNITS"])
def test_unit_basis_accepts_both_legal_values(fresh_db, table, value):
    UNIT_BASIS_BUILDERS[table](fresh_db, 1, value)
    (stored,) = fresh_db.execute(f"SELECT unit_basis FROM {table} LIMIT 1").fetchone()
    assert stored == value


@pytest.mark.parametrize("table", UNIT_BASIS_TABLES)
def test_unit_basis_rejects_a_third_value(fresh_db, table):
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint failed"):
        UNIT_BASIS_BUILDERS[table](fresh_db, 1, "BOGUS_BASIS")


# --------------------------------------------------------------------------- #
# Two-arm NATURAL_UNITS registration: y_b/y_g each carry TWO NATURAL_UNITS
# rows differing only by quantity_type (the electrical form vs the PSS/E
# form at 1.0 pu voltage).
# --------------------------------------------------------------------------- #
def test_admittance_natural_units_two_arms_registered(db):
    """Finer-grained than test_flexible_basis_columns_registered, which only
    sees the distinct discriminator_value SET and would still pass if one of
    the two NATURAL_UNITS arms silently vanished (both rows share the same
    discriminator_value)."""
    expected = {
        ("fixed_admittance", "y_b"): {("Susceptance", "S"), ("ReactivePower", "MVAr")},
        ("fixed_admittance", "y_g"): {("Conductance", "S"), ("ActivePower", "MW")},
        ("switched_admittance", "y_b"): {("Susceptance", "S"), ("ReactivePower", "MVAr")},
        ("switched_admittance", "y_g"): {("Conductance", "S"), ("ActivePower", "MW")},
    }
    for (table, column), pairs in expected.items():
        rows = db.execute(
            "SELECT quantity_type, unit FROM unit_conventions "
            "WHERE table_name = ? AND column_name = ? AND discriminator_value = 'NATURAL_UNITS'",
            (table, column),
        ).fetchall()
        assert set(rows) == pairs, f"{table}.{column}: {set(rows)} != {pairs}"


def test_attributes_trigger_accepts_either_natural_units_arm_rejects_cross_pair(fresh_db):
    """The generic attributes unit-validation trigger, exercised with the exact
    y_b/y_g two-arm SHAPE (same discriminator_value, differing only by
    quantity_type) rather than a generic stand-in: no attributes name in the
    real seed has two arms (y_b/y_g are physical columns, not attributes
    rows), so register a synthetic one with that exact shape and confirm both
    arms are accepted and a cross pair is rejected. The ledger's Task 4 note
    records this mechanism was empirically confirmed but never captured in a
    test; this closes that gap."""
    drop_seal_triggers(fresh_db)
    fresh_db.execute(
        "INSERT INTO unit_conventions"
        "(table_name, column_name, quantity_type, unit, "
        " discriminator_column, discriminator_value) "
        "VALUES ('attributes', 'shunt_susceptance_arm', 'Susceptance', 'S', 'mode', 'NATURAL'), "
        "       ('attributes', 'shunt_susceptance_arm', 'ReactivePower', 'MVAr', 'mode', 'NATURAL')"
    )
    make_entity(fresh_db, 1)
    insert_attribute(fresh_db, 1, "shunt_susceptance_arm", "0.01", "S", "Susceptance")
    make_entity(fresh_db, 2)
    insert_attribute(fresh_db, 2, "shunt_susceptance_arm", "1.5", "MVAr", "ReactivePower")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM attributes WHERE name = 'shunt_susceptance_arm'"
    ).fetchone()
    assert count == 2

    make_entity(fresh_db, 3)
    with pytest.raises(
        sqlite3.IntegrityError, match="Known attribute must use the registered unit"
    ):
        insert_attribute(fresh_db, 3, "shunt_susceptance_arm", "0.01", "MW", "ActivePower")


# --------------------------------------------------------------------------- #
# time_series_associations unit_system (infrastore mirror: lowercase spellings,
# deliberately no CHECK -- a third basis must not require a format bump)
# --------------------------------------------------------------------------- #
def test_association_unit_system_round_trips_lowercase(fresh_db):
    make_entity(fresh_db, 1)
    fresh_db.execute(
        "INSERT INTO time_series_associations("
        "association_id, owner_id, owner_type, owner_category, time_series_type, name, "
        "unit_system, uri, features_hash) "
        "VALUES (1, 1, 'thing', 0, 0, 'v', 'component_base', 'static:v', ?)",
        (b"\x07" * 32,),
    )
    (system,) = fresh_db.execute(
        "SELECT unit_system FROM time_series_associations WHERE name = 'v'"
    ).fetchone()
    assert system == "component_base"


# --------------------------------------------------------------------------- #
# unit_basis_rules seal protection
# --------------------------------------------------------------------------- #
def test_unit_basis_rules_update_blocked(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "UPDATE unit_basis_rules SET base_expression = 'bogus' WHERE quantity_type = 'Voltage'"
        )


def test_unit_basis_rules_delete_blocked(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute("DELETE FROM unit_basis_rules WHERE quantity_type = 'Voltage'")


def test_unit_basis_rules_post_seal_insert_blocked(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="protected against ad-hoc edits"):
        fresh_db.execute(
            "INSERT INTO unit_basis_rules(quantity_type, base_expression) "
            "VALUES ('ActivePower', 'base_power')"
        )


# --------------------------------------------------------------------------- #
# column_units view: base refs exposed + row-count parity with unit_conventions
# --------------------------------------------------------------------------- #
def test_column_units_view_exposes_base_ref_columns(db):
    cols = [row[1] for row in db.execute("PRAGMA table_info(column_units)")]
    assert {"base_power_ref", "base_voltage_ref", "base_expression"} <= set(cols)


def test_column_units_view_row_count_matches_unit_conventions(db):
    """The LEFT JOIN to unit_basis_rules must not drop NATURAL_UNITS (and other
    non-pu) rows, which have no unit_basis_rules match."""
    (view_count,) = db.execute("SELECT COUNT(*) FROM column_units").fetchone()
    (conv_count,) = db.execute("SELECT COUNT(*) FROM unit_conventions").fetchone()
    assert view_count == conv_count == EXPECTED_UNIT_CONVENTIONS


# --------------------------------------------------------------------------- #
# Part C judgment call: dimensional sanity for unit_basis-discriminated
# columns. See task-7-report.md for the full reasoning; summary: worth adding
# in a DB-derived, non-brittle form (cross-arm consistency), with a documented
# coverage gap for pu-only columns that carry no sibling arm to compare
# against.
# --------------------------------------------------------------------------- #
def test_unit_basis_arms_share_quantity_type(db):
    """For any column discriminated by unit_basis (whether as the primary
    discriminator_column, or as discriminator_column_2 on a column already
    multiplexed by a sibling like dc_control), the COMPONENT_BASE (pu) arm's
    quantity_type must be one of the NATURAL_UNITS arm(s)' quantity_types.

    This targets the Task 6 finding directly: nothing else stops a pu arm's
    quantity_type from silently diverging from its physical meaning (e.g.
    Resistance -> Voltage on transmission_lines.r), because (Voltage, pu) is
    independently a legal vocabulary pair -- changing ONLY the pu arm's
    quantity_type, leaving its NATURAL_UNITS sibling as Resistance/ohm, is
    exactly the cross-arm mismatch this test catches, entirely from the DB
    (no hardcoded column-name list). A subset check (not equality) is
    deliberate: fixed_admittance/switched_admittance's y_b/y_g legitimately
    carry TWO NATURAL_UNITS quantity_types for one COMPONENT_BASE quantity
    (the two-arm regression -- Susceptance/S AND ReactivePower/MVAr both
    represent the same COMPONENT_BASE Susceptance arm), which equality would
    wrongly flag.

    Known scope limit: this cannot see (a) a mutation that changes BOTH arms
    of a column consistently, or (b) a pu-only column with no unit_basis
    discriminator at all (three_winding_transformers.r_12 and its pairwise
    siblings, two_winding_transformers.magnetizing_shunt.*) since there is no
    sibling arm to compare against. Closing that residual would need either a
    maintained name->quantity_type map -- the brittle list this project wants
    to avoid -- or a schema-level dimensional annotation that does not exist
    today.
    """
    rows = db.execute(
        "SELECT table_name, column_name, discriminator_column, discriminator_value, "
        "discriminator_column_2, discriminator_value_2, quantity_type "
        "FROM unit_conventions "
        "WHERE discriminator_column = 'unit_basis' OR discriminator_column_2 = 'unit_basis'"
    ).fetchall()
    by_group = {}
    for table_name, column_name, disc_col, disc_val, disc_col2, disc_val2, quantity_type in rows:
        if disc_col == "unit_basis":
            key, basis = (table_name, column_name), disc_val
        else:
            # unit_basis is the SECOND discriminator (interconnecting_converters
            # dc_setpoint/ac_setpoint): group per primary discriminator value, since
            # DC_POWER and DC_VOLTAGE are legitimately different quantities.
            key, basis = (table_name, column_name, disc_val), disc_val2
        by_group.setdefault(key, {"COMPONENT_BASE": set(), "NATURAL_UNITS": set()})
        by_group[key][basis].add(quantity_type)

    assert by_group, "no unit_basis-discriminated columns found -- fixture regression"
    mismatched = {
        key: bases
        for key, bases in by_group.items()
        if bases["COMPONENT_BASE"] and bases["NATURAL_UNITS"]
        and not bases["COMPONENT_BASE"] <= bases["NATURAL_UNITS"]
    }
    assert mismatched == {}, f"unit_basis arms disagree on quantity_type: {mismatched}"
