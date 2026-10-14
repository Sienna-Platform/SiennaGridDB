"""Services: reserves, transmission interfaces, membership, and the service views."""

import json
import sqlite3

import pytest

from conftest import make_entity
from test_cost_and_source_coverage import insert_thermal
from test_schema_integrity import make_arc, make_bus, make_circuit

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


# Views, on a small synthetic system: a line and a transformer in an interface,
# two generators bidding into reserves, and a load whose cost is an attribute.
def insert_line(conn, line_id, name, arc_id):
    make_entity(conn, line_id, "transmission_lines", "Line")
    conn.execute(
        "INSERT INTO transmission_lines "
        "(id, name, arc_id, continuous_rating, r, x, base_power, power_units, angle_limits) "
        "VALUES (?, ?, ?, 100.0, 0.01, 0.1, 100.0, 'NATURAL_UNITS', '{\"min\": -1.0, \"max\": 1.0}')",
        (line_id, name, arc_id),
    )


def insert_transformer(conn, xf_id, name, arc_id):
    make_entity(conn, xf_id, "two_winding_transformers", "TwoWindingTransformer")
    circuit = make_circuit(conn, xf_id + 100, arc_id)
    conn.execute(
        "INSERT INTO two_winding_transformers (id, name, circuit) VALUES (?, ?, ?)",
        (xf_id, name, circuit),
    )


def bid(offers):
    return {"cost_type": "MARKET_BID_TIME_SERIES", "ancillary_service_offers": offers}


def add_series(conn, owner_id, name, time_series_type):
    conn.execute(
        "INSERT INTO time_series_associations (owner_id, owner_type, owner_category, "
        "time_series_type, name, uri, features_hash) "
        "VALUES (?, 'ThermalStandard', 'Component', ?, ?, ?, ?)",
        (owner_id, time_series_type, name, f"uri-{owner_id}-{name}", "0" * 64),
    )


@pytest.fixture
def system(fresh_db):
    conn = fresh_db
    add_reserve(conn, 1, "OnlineReserve", name="online_up")
    add_reserve(conn, 2, "OfflineReserve", name="offline_up")
    add_interface(conn, 4, direction_mapping='{"line_a": 1, "xf_b": -1}')
    # Interface 5 names xf_b, a member of 4 only; transformer 23 shares line_a's name.
    add_interface(conn, 5, direction_mapping='{"line_c": -1.0, "xf_b": 1}')
    bus = make_bus(conn, 50, "b50")
    arc = make_arc(conn, 52, bus, make_bus(conn, 51, "b51"))
    insert_line(conn, 20, "line_a", arc)
    insert_transformer(conn, 21, "xf_b", arc)
    insert_line(conn, 22, "line_c", arc)
    insert_transformer(conn, 23, "line_a", arc)
    insert_thermal(conn, 10, bus, None, operation_cost=bid([1]))
    insert_thermal(conn, 11, bus, None, operation_cost=bid([1, 2]))
    make_entity(conn, 12, "loads", "InterruptiblePowerLoad")
    conn.execute(
        "INSERT INTO attributes (entity_id, TYPE, name, value, unit, quantity_kind) "
        "VALUES (12, 'InterruptiblePowerLoad', 'operation_cost', ?, '1', 'Dimensionless')",
        (json.dumps({"cost_type": "MARKET_BID", "ancillary_service_offers": [2]}),),
    )
    for pair in [(1, 10), (1, 11), (2, 12), (4, 20), (4, 21), (4, 22), (5, 22)]:
        join(conn, *pair)
    add_series(conn, 10, "online_up", "SingleTimeSeries")
    add_series(conn, 10, "online_up", "DeterministicSingleTimeSeries")
    add_series(conn, 10, "max_active_power", "SingleTimeSeries")
    return conn


def rows(conn, sql):
    return sorted(conn.execute(sql).fetchall())


def test_service_contributors(system):
    assert rows(system, "SELECT * FROM service_contributors WHERE service_id = 2") == [
        (2, "OfflineReserve", 12, "InterruptiblePowerLoad")
    ]


def test_interface_branch_directions_resolve_to_member_branches(system):
    assert rows(system, "SELECT * FROM interface_branch_directions") == [
        (4, 20, 1, "line_a"),
        (4, 21, -1, "xf_b"),
        (5, 22, -1, "line_c"),
    ]
    sql = "SELECT DISTINCT typeof(direction) FROM interface_branch_directions"
    assert rows(system, sql) == [("integer",)]


def test_unresolved_direction_name_is_a_violation(system):
    assert rows(system, "SELECT * FROM interface_direction_violations") == [(5, "xf_b")]
    join(system, 5, 21)
    assert rows(system, "SELECT * FROM interface_direction_violations") == []


def test_service_bid_offers_read_columns_and_attributes(system):
    assert rows(system, "SELECT * FROM service_bid_offers") == [
        (10, 1),
        (11, 1),
        (11, 2),
        (12, 2),
    ]


def insert_row(conn, table, row):
    conn.execute(
        f"INSERT INTO {table} ({', '.join(row)}) VALUES ({', '.join('?' for _ in row)})",
        list(row.values()),
    )


# A minimal row for each cost table besides thermal: (table, type, cost column, row).
def cost_rows(bus, other_bus):
    limits = '{"min": 0.0, "max": 10.0}'
    power = {"base_power": 100.0, "power_units": "NATURAL_UNITS", "rating": 10.0}
    storage = {
        "prime_mover_type": "BA",
        "storage_technology_type": "LIB",
        "storage_capacity": 40.0,
        "storage_level_limits": limits,
        "initial_storage_capacity_level": 0.5,
        "input_active_power_limits": limits,
        "output_active_power_limits": limits,
        "efficiency": '{"in": 0.9, "out": 0.9}',
    }
    return [
        ("renewable_generators", "RenewableDispatch", "operation_cost",
         {"prime_mover_type": "WT", "balancing_topology": bus, **power}),
        ("hydro_generators", "HydroDispatch", "operation_cost",
         {"balancing_topology": bus, "active_power_limits": limits, **power}),
        ("storage_units", "EnergyReservoirStorage", "operation_cost",
         {"balancing_topology": bus, **storage, **power}),
        ("sources", "Source", "operation_cost",
         {"bus": bus, "base_power": 100.0, "power_units": "NATURAL_UNITS",
          "r_th": 0.0, "x_th": 0.1}),
        ("virtual_participants", "VirtualParticipant", "operation_cost",
         {"max_supply": 10.0, "max_demand": 10.0}),
        ("point_to_point_bids", "PointToPointBid", "spread_bid",
         {"from_id": bus, "to_id": other_bus, "max_active_power": 10.0,
          "price_limits": limits}),
    ]


def test_service_bid_offers_read_every_cost_arm(fresh_db):
    """Every cost column that can hold a bid is read once per (device, service);
    a JSON-null offer list and an attribute other than operation_cost are not."""
    conn = fresh_db
    for name in ("WT", "HY", "BA"):
        conn.execute("INSERT OR IGNORE INTO prime_mover_types (name) VALUES (?)", (name,))
    conn.execute("INSERT OR IGNORE INTO storage_technology_types (name) VALUES ('LIB')")
    bus, other = make_bus(conn, 50, "b50"), make_bus(conn, 51, "b51")
    for device_id, (table, type_name, column, row) in enumerate(cost_rows(bus, other), 10):
        make_entity(conn, device_id, table, type_name)
        row.update(id=device_id, name=f"d{device_id}")
        row[column] = json.dumps(bid([device_id % 2 + 1]))
        insert_row(conn, table, row)
    insert_thermal(conn, 20, bus, None, operation_cost=bid([1, 1]))
    insert_thermal(conn, 21, bus, None, operation_cost=bid(None))
    make_entity(conn, 22, "loads", "InterruptiblePowerLoad")
    conn.execute(
        "INSERT INTO attributes (entity_id, TYPE, name, value, unit, quantity_kind) "
        "VALUES (22, 'InterruptiblePowerLoad', 'other_cost', ?, '1', 'Dimensionless')",
        (json.dumps(bid([2])),),
    )
    assert rows(conn, "SELECT * FROM service_bid_offers") == [
        (10, 1), (11, 2), (12, 1), (13, 2), (14, 1), (15, 2), (20, 1)
    ]


def test_service_bids_are_the_device_series_named_after_the_reserve(system):
    assert rows(
        system, "SELECT device_id, service_id, time_series_type FROM service_bids"
    ) == [
        (10, 1, "DeterministicSingleTimeSeries"),
        (10, 1, "SingleTimeSeries"),
    ]


def test_offer_without_membership_is_a_violation(system):
    assert rows(system, "SELECT * FROM service_offer_violations") == [(11, 2)]
    join(system, 2, 11)
    assert rows(system, "SELECT * FROM service_offer_violations") == []
