"""Services: the reserves table and its per-type shape triggers."""

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
