"""Coverage close-out for sources and fixed_admittance, and the curve-form
contract for variable costs.

Two things are pinned here. First, every Source and FixedAdmittance field the
schemas define now has somewhere to live, so a loader never has to drop one.
Second, a variable-cost payload's unit follows the curve form it declares:
INPUT_OUTPUT is a cost rate (USD/h), INCREMENTAL and AVERAGE_RATE are per-energy
(USD/MWh), and a FuelCurve carries a heat rate. Piecewise function data must
survive storage unaltered -- the DB is the interchange format, so flattening a
curve on the way in would lose the model."""

import json
import sqlite3

import pytest

from conftest import load_schemas_json, make_entity

NATURAL = "NATURAL_UNITS"

PIECEWISE_IO_COST = {
    "power_units": NATURAL,
    "variable_cost_type": "COST",
    "value_curve": {
        "curve_type": "INPUT_OUTPUT",
        "function_data": {
            "function_type": "PIECEWISE_LINEAR",
            "points": [
                {"x": 0.0, "y": 1512.3587},
                {"x": 67.73333333333333, "y": 2380.255310301013},
                {"x": 135.46666666666667, "y": 3499.742877204054},
                {"x": 203.2, "y": 4870.82140070912},
            ],
        },
    },
    "vom_cost": {
        "curve_type": "INPUT_OUTPUT",
        "function_data": {
            "function_type": "LINEAR",
            "constant_term": 0.0,
            "proportional_term": 0.0,
        },
    },
}


def make_bus(conn, bus_id, name):
    make_entity(conn, bus_id, "balancing_topologies", "ACBus", is_topology=1)
    conn.execute("INSERT INTO balancing_topologies(id, name) VALUES (?, ?)", (bus_id, name))
    return bus_id


def insert_thermal(conn, gen_id, bus_id, production_cost):
    make_entity(conn, gen_id, "thermal_generators", "ThermalStandard")
    # A fresh build seeds no vocabularies; thermal_generators FKs both of these.
    conn.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('ST')")
    conn.execute("INSERT OR IGNORE INTO fuels(name) VALUES ('NATURAL_GAS')")
    conn.execute(
        """INSERT INTO thermal_generators
               (id, name, prime_mover_type, fuel, balancing_topology, rating,
                base_power, active_power_limits, production_cost)
           VALUES (?, ?, 'ST', 'NATURAL_GAS', ?, 203.2, 100.0,
                   '{"min": 0.0, "max": 203.2}', ?)""",
        (gen_id, f"gen-{gen_id}", bus_id, json.dumps(production_cost)),
    )


# Piecewise round trip


def test_piecewise_cost_curve_round_trips_unaltered(fresh_db):
    """A 4-point INPUT_OUTPUT curve must come back out byte-identical in value."""
    bus = make_bus(fresh_db, 1, "bus-1")
    insert_thermal(fresh_db, 2, bus, PIECEWISE_IO_COST)
    (stored,) = fresh_db.execute(
        "SELECT production_cost FROM thermal_generators WHERE id = 2"
    ).fetchone()
    assert json.loads(stored) == PIECEWISE_IO_COST


def test_piecewise_points_are_queryable_as_json(fresh_db):
    """Stored curves must be reachable by SQL, not just opaque text."""
    bus = make_bus(fresh_db, 1, "bus-1")
    insert_thermal(fresh_db, 2, bus, PIECEWISE_IO_COST)
    rows = fresh_db.execute(
        """SELECT json_extract(value, '$.x'), json_extract(value, '$.y')
           FROM thermal_generators,
                json_each(production_cost,
                          '$.value_curve.function_data.points')
           WHERE thermal_generators.id = 2"""
    ).fetchall()
    assert [x for x, _ in rows] == [
        p["x"] for p in PIECEWISE_IO_COST["value_curve"]["function_data"]["points"]
    ]


def test_piecewise_step_incremental_curve_is_accepted(fresh_db):
    """IncrementalCurve takes PiecewiseStepData, a different payload shape."""
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = json.loads(json.dumps(PIECEWISE_IO_COST))
    cost["value_curve"] = {
        "curve_type": "INCREMENTAL",
        "initial_input": 1512.3587,
        "function_data": {
            "function_type": "PIECEWISE_STEP",
            "x_coords": [0.0, 67.7, 135.5, 203.2],
            "y_coords": [12.8, 16.5, 20.2],
        },
    }
    insert_thermal(fresh_db, 2, bus, cost)
    (stored,) = fresh_db.execute(
        "SELECT production_cost FROM thermal_generators WHERE id = 2"
    ).fetchone()
    assert json.loads(stored) == cost


def test_relative_power_units_still_rejected_for_piecewise(fresh_db):
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = json.loads(json.dumps(PIECEWISE_IO_COST))
    cost["power_units"] = "SYSTEM_BASE"
    with pytest.raises(sqlite3.IntegrityError, match="power_units"):
        insert_thermal(fresh_db, 2, bus, cost)


# Curve-form conventions in the registry

CURVE_FORM_EXPECTATIONS = [
    (
        "thermal_generators",
        "production_cost",
        "INPUT_OUTPUT",
        "COST",
        "CostPerTime",
        "USD/h",
    ),
    (
        "thermal_generators",
        "production_cost",
        "INCREMENTAL",
        "COST",
        "CostPerEnergy",
        "USD/MWh",
    ),
    (
        "thermal_generators",
        "production_cost",
        "AVERAGE_RATE",
        "COST",
        "CostPerEnergy",
        "USD/MWh",
    ),
    (
        "thermal_generators",
        "production_cost",
        "INCREMENTAL",
        "FUEL",
        "HeatRate",
        "MMBtu/MWh",
    ),
    (
        "hydro_generators",
        "production_cost",
        "INPUT_OUTPUT",
        "COST",
        "CostPerTime",
        "USD/h",
    ),
    (
        "renewable_generators",
        "operation_cost.curtailment_cost",
        "INPUT_OUTPUT",
        None,
        "CostPerTime",
        "USD/h",
    ),
    (
        "storage_units",
        "operation_cost.charge_variable_cost",
        "AVERAGE_RATE",
        None,
        "CostPerEnergy",
        "USD/MWh",
    ),
    (
        "sources",
        "operation_cost.import_offer_curves",
        "INCREMENTAL",
        None,
        "CostPerEnergy",
        "USD/MWh",
    ),
]


@pytest.mark.parametrize(
    "table, column, curve_type, cost_type, quantity_type, unit",
    CURVE_FORM_EXPECTATIONS,
)
def test_variable_cost_convention_follows_curve_form(
    db, table, column, curve_type, cost_type, quantity_type, unit
):
    row = db.execute(
        """SELECT quantity_type, unit, discriminator_column, discriminator_value_2
           FROM unit_conventions
           WHERE table_name = ? AND column_name = ? AND discriminator_value = ?
             AND (discriminator_value_2 IS ? OR discriminator_value_2 = ?)""",
        (table, column, curve_type, cost_type, cost_type),
    ).fetchone()
    assert row is not None, f"no convention for {table}.{column} {curve_type}"
    assert (row[0], row[1]) == (quantity_type, unit)
    assert row[2].endswith("value_curve.curve_type")


def test_input_output_and_incremental_units_differ(db):
    """The whole point: one path, two units, chosen by the payload's curve form."""
    units = dict(
        db.execute(
            """SELECT discriminator_value, unit FROM unit_conventions
               WHERE table_name = 'thermal_generators'
                 AND column_name = 'production_cost'
                 AND discriminator_value_2 = 'COST'"""
        ).fetchall()
    )
    assert units["INPUT_OUTPUT"] == "USD/h"
    assert units["INCREMENTAL"] == "USD/MWh"


def test_fuel_input_output_is_deliberately_unregistered(db):
    """A FuelCurve input-output y is MMBtu/h, absent from the unit vocabulary.
    Recorded in coverage_decisions.json as an upstream prerequisite; if someone
    adds the pair upstream, this test is the reminder to register the arm."""
    row = db.execute(
        """SELECT 1 FROM unit_conventions
           WHERE column_name = 'production_cost'
             AND discriminator_value = 'INPUT_OUTPUT'
             AND discriminator_value_2 = 'FUEL'"""
    ).fetchone()
    assert row is None


def test_storage_units_registers_its_real_curve_paths(db):
    """StorageCost has no `variable`; it has charge and discharge curves."""
    paths = {
        r[0]
        for r in db.execute(
            """SELECT column_name FROM unit_conventions
               WHERE table_name = 'storage_units'
                 AND column_name LIKE 'operation_cost.%'"""
        ).fetchall()
    }
    assert "production_cost" not in paths
    assert "operation_cost.charge_variable_cost" in paths
    assert "operation_cost.discharge_variable_cost" in paths


# sources / fixed_admittance field coverage

SOURCE_SKIPPED = {"id", "dynamic_injector", "R_th", "X_th"}


def test_every_source_schema_field_has_a_column(db):
    """No Source field may be droppable by a loader."""
    props = set(load_schemas_json("Operations/StaticInjection/Source.json")["properties"])
    columns = {r[1] for r in db.execute("PRAGMA table_info(sources)")}
    columns |= {"R_th", "X_th"}  # stored lowercase; a rename, not a gap
    columns |= {"parameter_units"}  # renamed to unit_basis (two-basis-units refactor)
    missing = props - SOURCE_SKIPPED - columns
    assert not missing, f"Source fields with no column: {sorted(missing)}"


def test_fixed_admittance_available_is_a_column(db):
    columns = {r[1] for r in db.execute("PRAGMA table_info(fixed_admittance)")}
    assert "available" in columns


def test_source_impedance_columns_are_lowercase(db):
    columns = {r[1] for r in db.execute("PRAGMA table_info(sources)")}
    assert {"r_th", "x_th"} <= columns
    assert not {"R_th", "X_th"} & columns


def test_source_defaults_match_psy(fresh_db):
    """A minimal insert must land on the schema defaults, not zeros."""
    bus = make_bus(fresh_db, 1, "bus-1")
    make_entity(fresh_db, 2, "sources", "Source")
    fresh_db.execute(
        "INSERT INTO sources(id, name, bus, r_th, x_th) VALUES (2, 'src', ?, 0.0, 0.0)",
        (bus,),
    )
    row = fresh_db.execute(
        """SELECT available, base_power, internal_voltage, internal_angle,
                  base_voltage, unit_basis, operation_cost
           FROM sources WHERE id = 2"""
    ).fetchone()
    assert row[0] == 1
    assert row[1] == 100.0
    assert row[2] == 1.0
    assert row[3] == 0.0
    assert row[4] is None, "base_voltage is nullable: may be taken from the bus"
    assert row[5] == "COMPONENT_BASE"
    cost = json.loads(row[6])
    assert cost["import_offer_curves"] is None
    assert cost["energy_import_weekly_limit"] == 1000000.0


def test_source_cost_units_trigger_guards_both_offer_curves(fresh_db):
    bus = make_bus(fresh_db, 1, "bus-1")
    for offset, side in enumerate(("import_offer_curves", "export_offer_curves")):
        make_entity(fresh_db, 10 + offset, "sources", "Source")
        cost = {
            "cost_type": "IMPORTEXPORT",
            "energy_import_weekly_limit": 1.0,
            "energy_export_weekly_limit": 1.0,
            side: {"power_units": "DEVICE_BASE"},
        }
        with pytest.raises(sqlite3.IntegrityError, match="power_units"):
            fresh_db.execute(
                """INSERT INTO sources(id, name, bus, r_th, x_th, operation_cost)
                   VALUES (?, ?, ?, 0.0, 0.0, ?)""",
                (10 + offset, f"src-{side}", bus, json.dumps(cost)),
            )


def test_source_base_voltage_must_be_positive(fresh_db):
    bus = make_bus(fresh_db, 1, "bus-1")
    make_entity(fresh_db, 2, "sources", "Source")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            """INSERT INTO sources(id, name, bus, r_th, x_th, base_voltage)
               VALUES (2, 'src', ?, 0.0, 0.0, 0.0)""",
            (bus,),
        )


# production_cost: the payload must say which kind of curve it is


def fuel_curve(fuel_cost=4.0, curve_type="INCREMENTAL", fuel_cost_time_series=None):
    curve = {
        "variable_cost_type": "FUEL",
        "power_units": NATURAL,
        "value_curve": {
            "curve_type": curve_type,
            "function_data": {
                "function_type": "LINEAR",
                "constant_term": 0.0,
                "proportional_term": 8.2,
            },
        },
    }
    if fuel_cost is not None:
        curve["fuel_cost"] = fuel_cost
    if fuel_cost_time_series is not None:
        curve["fuel_cost_time_series"] = fuel_cost_time_series
    return curve


def test_fuel_curve_is_accepted_and_self_describing(fresh_db):
    """A FuelCurve stores its own discriminator, so a reader never guesses."""
    bus = make_bus(fresh_db, 1, "bus-1")
    insert_thermal(fresh_db, 2, bus, fuel_curve())
    row = fresh_db.execute(
        """SELECT json_extract(production_cost, '$.variable_cost_type'),
                  json_extract(production_cost, '$.fuel_cost')
           FROM thermal_generators WHERE id = 2"""
    ).fetchone()
    assert row == ("FUEL", 4.0)


def test_fuel_curve_without_any_fuel_price_is_rejected(fresh_db):
    """A heat rate with no fuel price at all cannot be turned into money."""
    bus = make_bus(fresh_db, 1, "bus-1")
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(fresh_db, 2, bus, fuel_curve(fuel_cost=None))


def test_fuel_curve_with_time_series_price_is_accepted(fresh_db):
    """A time-varying price is a valid FuelCurve."""
    bus = make_bus(fresh_db, 1, "bus-1")
    insert_thermal(
        fresh_db, 2, bus, fuel_curve(fuel_cost=None, fuel_cost_time_series=77)
    )
    (stored,) = fresh_db.execute(
        "SELECT json_extract(production_cost, '$.fuel_cost_time_series') "
        "FROM thermal_generators WHERE id = 2"
    ).fetchone()
    assert stored == 77


def test_fuel_curve_with_both_prices_is_rejected(fresh_db):
    """Exactly one of the two is set. Upstream says so only in prose, so this
    CHECK is the only place the rule is enforced."""
    bus = make_bus(fresh_db, 1, "bus-1")
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(
            fresh_db, 2, bus, fuel_curve(fuel_cost=4.0, fuel_cost_time_series=77)
        )


@pytest.mark.parametrize(
    "curve_type",
    ["TIME_SERIES_INPUT_OUTPUT", "TIME_SERIES_INCREMENTAL", "TIME_SERIES_AVERAGE_RATE"],
)
def test_time_series_backed_curve_types_are_accepted(fresh_db, curve_type):
    """The three time-series-backed ValueCurve forms carry an association_id in
    their function_data instead of coefficients."""
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = {
        "variable_cost_type": "COST",
        "power_units": NATURAL,
        "value_curve": {
            "curve_type": curve_type,
            "function_data": {
                "function_type": "TIME_SERIES_LINEAR",
                "association_id": 42,
            },
        },
    }
    insert_thermal(fresh_db, 2, bus, cost)
    (stored,) = fresh_db.execute(
        "SELECT json_extract(production_cost, '$.value_curve.curve_type') "
        "FROM thermal_generators WHERE id = 2"
    ).fetchone()
    assert stored == curve_type


def test_unknown_curve_type_is_still_rejected(fresh_db):
    """The enum stays closed."""
    bus = make_bus(fresh_db, 1, "bus-1")
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(fresh_db, 2, bus, fuel_curve(curve_type="TIME_SERIES_GUESS"))


def test_unknown_variable_cost_type_is_rejected(fresh_db):
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = fuel_curve()
    cost["variable_cost_type"] = "GUESS"
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(fresh_db, 2, bus, cost)


def test_missing_variable_cost_type_is_rejected(fresh_db):
    """The discriminator is mandatory: an unlabelled curve has no unit."""
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = json.loads(json.dumps(PIECEWISE_IO_COST))
    del cost["variable_cost_type"]
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(fresh_db, 2, bus, cost)


def test_unknown_curve_type_is_rejected(fresh_db):
    bus = make_bus(fresh_db, 1, "bus-1")
    cost = json.loads(json.dumps(PIECEWISE_IO_COST))
    cost["value_curve"]["curve_type"] = "SPLINE"
    with pytest.raises(sqlite3.IntegrityError):
        insert_thermal(fresh_db, 2, bus, cost)


def test_operation_cost_may_not_keep_a_copy_of_the_curve(fresh_db):
    """One source of truth: the curve lives in production_cost, nowhere else."""
    bus = make_bus(fresh_db, 1, "bus-1")
    fresh_db.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('ST')")
    fresh_db.execute("INSERT OR IGNORE INTO fuels(name) VALUES ('NATURAL_GAS')")
    make_entity(fresh_db, 2, "thermal_generators", "ThermalStandard")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            """INSERT INTO thermal_generators
                   (id, name, prime_mover_type, fuel, balancing_topology, rating,
                    base_power, active_power_limits, production_cost, operation_cost)
               VALUES (2, 'gen-2', 'ST', 'NATURAL_GAS', ?, 203.2, 100.0,
                       '{"min": 0.0, "max": 203.2}', ?,
                       '{"cost_type": "THERMAL", "fixed": 0, "variable": {}}')""",
            (bus, json.dumps(PIECEWISE_IO_COST)),
        )


def test_renewable_production_cost_rejects_fuel(fresh_db):
    """The schemas make RenewableGenerationCost.variable a CostCurve; FUEL has no
    registered unit here."""
    bus = make_bus(fresh_db, 1, "bus-1")
    fresh_db.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('PV')")
    make_entity(fresh_db, 2, "renewable_generators", "RenewableDispatch")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            """INSERT INTO renewable_generators
                   (id, name, prime_mover_type, balancing_topology, rating,
                    base_power, production_cost)
               VALUES (2, 'rg', 'PV', ?, 1.0, 1.0, ?)""",
            (bus, json.dumps(fuel_curve())),
        )


def test_generators_are_queryable_by_curve_kind(fresh_db):
    """The point of a first-class column: select on how the cost is expressed."""
    bus = make_bus(fresh_db, 1, "bus-1")
    insert_thermal(fresh_db, 2, bus, PIECEWISE_IO_COST)
    insert_thermal(fresh_db, 3, bus, fuel_curve())
    kinds = dict(
        fresh_db.execute(
            """SELECT json_extract(production_cost, '$.variable_cost_type'),
                      COUNT(*)
               FROM thermal_generators GROUP BY 1"""
        ).fetchall()
    )
    assert kinds == {"COST": 1, "FUEL": 1}


def test_every_generator_table_has_production_cost(db):
    for table in ("thermal_generators", "renewable_generators", "hydro_generators"):
        columns = {r[1] for r in db.execute(f"PRAGMA table_info({table})")}
        assert "production_cost" in columns, table


def test_storage_keeps_the_whole_storage_cost_object(db):
    """storage_units.operation_cost IS the StorageCost schema: its charge and
    discharge curves stay inside the blob and are registered there. The contrast
    with the generator tables is deliberate -- do not promote them."""
    columns = {r[1] for r in db.execute("PRAGMA table_info(storage_units)")}
    assert "production_cost" not in columns
    assert "operation_cost" in columns
    registered = {
        r[0]
        for r in db.execute(
            """SELECT column_name FROM unit_conventions
               WHERE table_name = 'storage_units'
                 AND column_name LIKE 'operation_cost.%_variable_cost'"""
        ).fetchall()
    }
    assert registered == {
        "operation_cost.charge_variable_cost",
        "operation_cost.discharge_variable_cost",
    }
