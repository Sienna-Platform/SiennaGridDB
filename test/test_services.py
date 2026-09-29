"""Services: reserves (with per-type shape triggers) and transmission interfaces."""

import sqlite3

import pytest

from conftest import make_entity

CURVE = (
    '{"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": '
    '{"curve_type": "TIME_SERIES_INCREMENTAL", "function_data": '
    '{"function_type": "TIME_SERIES_PIECEWISE_STEP", "association_id": 7}}}'
)

# One valid row per reserve type, as column -> value.
RESERVES = {
    "OnlineReserve": {
        "time_frame": 10.0,
        "requirement": 50.0,
        "sustained_time": 30.0,
        "max_output_fraction": 1.0,
        "max_participation_factor": 0.5,
        "deployed_fraction": 0.0,
        "reserve_direction": "UP",
        "variable": CURVE,
    },
    "OfflineReserve": {
        "time_frame": 30.0,
        "requirement": 20.0,
        "sustained_time": 60.0,
        "max_output_fraction": 1.0,
        "max_participation_factor": 1.0,
        "deployed_fraction": 0.0,
    },
    "GroupReserve": {"requirement": 70.0, "reserve_direction": "SYMMETRIC"},
}


def add_reserve(conn, reserve_id, entity_type, name=None, **overrides):
    make_entity(conn, reserve_id, "reserves", entity_type)
    row = {"id": reserve_id, "name": name or f"r{reserve_id}"}
    row.update(RESERVES.get(entity_type, {}), **overrides)
    conn.execute(
        f"INSERT INTO reserves ({', '.join(row)}) VALUES ({', '.join('?' for _ in row)})",
        list(row.values()),
    )
    return reserve_id


@pytest.mark.parametrize("entity_type", sorted(RESERVES))
def test_reserve_round_trips(fresh_db, entity_type):
    add_reserve(fresh_db, 1, entity_type)
    cols = ["name", "available", *RESERVES[entity_type]]
    row = fresh_db.execute(f"SELECT {', '.join(cols)} FROM reserves").fetchone()
    assert dict(zip(cols, row)) == {"name": "r1", "available": 1, **RESERVES[entity_type]}


GROUP_FORBIDDEN = [
    "time_frame",
    "sustained_time",
    "max_output_fraction",
    "max_participation_factor",
    "deployed_fraction",
]
FRACTIONS = ["max_output_fraction", "max_participation_factor", "deployed_fraction"]

# Wrong shapes for a valid row of each type, each tried by INSERT and by UPDATE.
SHAPE_CASES = [
    ("OnlineReserve", {"time_frame": None}, "require time_frame"),
    ("OfflineReserve", {"time_frame": None}, "require time_frame"),
    ("OnlineReserve", {"reserve_direction": None}, "require reserve_direction"),
    ("GroupReserve", {"reserve_direction": None}, "require reserve_direction"),
    ("OfflineReserve", {"reserve_direction": "UP"}, "upward only"),
    *[("GroupReserve", {c: 0.5}, "GroupReserve rows have no") for c in GROUP_FORBIDDEN],
    *[("OnlineReserve", {c: v}, "CHECK constraint") for c in FRACTIONS for v in (-1, 2)],
    ("OnlineReserve", {"reserve_direction": "LEFT"}, "CHECK constraint"),
    ("OnlineReserve", {"variable": "{not json"}, "CHECK constraint"),
]


@pytest.mark.parametrize(
    "entity_type, overrides, message",
    [*SHAPE_CASES, ("ThermalStandard", {"time_frame": 5.0}, "must be OnlineReserve")],
)
def test_reserve_rejects_wrong_shape_on_insert(fresh_db, entity_type, overrides, message):
    with pytest.raises(sqlite3.IntegrityError, match=message):
        add_reserve(fresh_db, 1, entity_type, **overrides)


@pytest.mark.parametrize("entity_type, overrides, message", SHAPE_CASES)
def test_reserve_rejects_wrong_shape_on_update(fresh_db, entity_type, overrides, message):
    add_reserve(fresh_db, 1, entity_type)
    sets = ", ".join(f"{c} = ?" for c in overrides)
    with pytest.raises(sqlite3.IntegrityError, match=message):
        fresh_db.execute(f"UPDATE reserves SET {sets}", list(overrides.values()))


def add_interface(conn, interface_id, name=None, **overrides):
    make_entity(conn, interface_id, "transmission_interfaces", "TransmissionInterface")
    row = {
        "id": interface_id,
        "name": name or f"i{interface_id}",
        "active_power_flow_limits": '{"min": -100.0, "max": 250.0}',
        "violation_penalty": 1e5,
        "direction_mapping": '{"line_a": 1, "line_b": -1}',
        "base_power": 100.0,
        "power_units": "NATURAL_UNITS",
    }
    row.update(overrides)
    conn.execute(
        f"INSERT INTO transmission_interfaces ({', '.join(row)}) "
        f"VALUES ({', '.join('?' for _ in row)})",
        list(row.values()),
    )
    return interface_id


def test_interface_round_trips(fresh_db):
    add_interface(fresh_db, 1)
    row = fresh_db.execute(
        "SELECT name, available, json_extract(active_power_flow_limits, '$.max'), "
        "violation_penalty, json_extract(direction_mapping, '$.line_b'), power_units "
        "FROM transmission_interfaces"
    ).fetchone()
    assert row == ("i1", 1, 250.0, 1e5, -1, "NATURAL_UNITS")


@pytest.mark.parametrize(
    "overrides",
    [
        {"direction_mapping": '["line_a"]'},
        {"direction_mapping": "{bad"},
        {"power_units": "SYSTEM_BASE"},
        {"base_power": 0.0},
        {"active_power_flow_limits": "{bad"},
    ],
)
def test_interface_rejects_bad_values(fresh_db, overrides):
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint"):
        add_interface(fresh_db, 1, **overrides)


@pytest.mark.parametrize(
    "value", ["0", "2", "1.5", '"north"', "true", "null", "[1]"]
)
def test_interface_direction_must_be_one_or_minus_one(fresh_db, value):
    mapping = f'{{"line_a": 1, "line_b": {value}}}'
    with pytest.raises(sqlite3.IntegrityError, match="must be 1 or -1"):
        add_interface(fresh_db, 1, direction_mapping=mapping)
    add_interface(fresh_db, 2)
    with pytest.raises(sqlite3.IntegrityError, match="must be 1 or -1"):
        fresh_db.execute(
            "UPDATE transmission_interfaces SET direction_mapping = ?", (mapping,)
        )


def test_interface_direction_may_be_an_integral_real(fresh_db):
    add_interface(fresh_db, 1, direction_mapping='{"line_a": 1.0, "line_b": -1}')


@pytest.mark.parametrize(
    "power_units, unit", [("COMPONENT_BASE", "pu"), ("NATURAL_UNITS", "MW")]
)
def test_interface_flow_limits_unit_follows_power_units(db, power_units, unit):
    (found,) = db.execute(
        "SELECT unit FROM unit_conventions WHERE table_name = 'transmission_interfaces' "
        "AND column_name = 'active_power_flow_limits' AND discriminator_value = ?",
        (power_units,),
    ).fetchone()
    assert found == unit


# Membership: the member's kind is read from entities, so bare entity rows
# stand in for the member tables here.
def join(conn, service_id, entity_id):
    conn.execute(
        "INSERT INTO service_associations (service_id, entity_id) VALUES (?, ?)",
        (service_id, entity_id),
    )


def members(conn):
    return conn.execute(
        "SELECT service_id, entity_id FROM service_associations ORDER BY 1, 2"
    ).fetchall()


def services(conn):
    """An online, an offline and a group reserve, and an interface: ids 1-4."""
    add_reserve(conn, 1, "OnlineReserve")
    add_reserve(conn, 2, "OfflineReserve")
    add_reserve(conn, 3, "GroupReserve")
    add_interface(conn, 4)
    make_entity(conn, 10, "thermal_generators", "ThermalStandard")
    make_entity(conn, 11, "storage_units", "EnergyReservoirStorage")
    make_entity(conn, 20, "transmission_lines", "Line")
    make_entity(conn, 21, "two_winding_transformers", "TwoWindingTransformer")
    make_entity(conn, 30, "balancing_topologies", "ACBus", is_topology=1)


def test_valid_memberships_per_service_kind(fresh_db):
    services(fresh_db)
    pairs = [(1, 10), (1, 11), (2, 10), (3, 1), (3, 2), (4, 20), (4, 21)]
    for pair in pairs:
        join(fresh_db, *pair)
    assert members(fresh_db) == pairs


WRONG_MEMBERS = [
    (3, 10, "GroupReserve's members must be reserves"),
    (4, 10, "members must be branches"),
    (4, 1, "members must be branches"),
    (1, 20, "members must be devices"),
    (2, 3, "members must be devices"),
    (1, 30, "members must be devices"),
    (10, 11, "must exist in reserves or transmission_interfaces"),
    (3, 3, "CHECK constraint"),
]


@pytest.mark.parametrize("service_id, entity_id, message", WRONG_MEMBERS)
def test_wrong_member_kind_is_rejected(fresh_db, service_id, entity_id, message):
    services(fresh_db)
    with pytest.raises(sqlite3.IntegrityError, match=message):
        join(fresh_db, service_id, entity_id)


@pytest.mark.parametrize("service_id, entity_id, message", WRONG_MEMBERS)
def test_wrong_member_kind_is_rejected_on_update(fresh_db, service_id, entity_id, message):
    services(fresh_db)
    join(fresh_db, 1, 10)
    with pytest.raises(sqlite3.IntegrityError, match=message):
        fresh_db.execute(
            "UPDATE service_associations SET service_id = ?, entity_id = ?",
            (service_id, entity_id),
        )


def test_membership_is_unique(fresh_db):
    services(fresh_db)
    join(fresh_db, 1, 10)
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        join(fresh_db, 1, 10)


def test_deleting_a_service_or_a_member_cascades(fresh_db):
    services(fresh_db)
    for pair in [(1, 10), (1, 11), (3, 1), (4, 20)]:
        join(fresh_db, *pair)
    fresh_db.execute("DELETE FROM reserves WHERE id = 1")
    assert members(fresh_db) == [(4, 20)]
    fresh_db.execute("DELETE FROM entities WHERE id = 20")
    assert members(fresh_db) == []
