"""Schema-integrity guards outside the unit registry: the entity supertype
triggers on discrete_controlled_ac_branches and the transformer tables, the
transformer enum/pairwise CHECK constraints, and the static_time_series
(uuid, idx) uniqueness contract."""

import re
import sqlite3

import pytest

from conftest import load_schemas_json, make_entity


def make_bus(conn, bus_id, name):
    """Create a balancing-topology entity plus its table row (FK-able bus)."""
    make_entity(conn, bus_id, "balancing_topologies", "ACBus", is_topology=1)
    conn.execute(
        "INSERT INTO balancing_topologies(id, name) VALUES (?, ?)", (bus_id, name)
    )
    return bus_id


def make_arc(conn, arc_id, from_id, to_id):
    """Create an arc (entity + row) between two existing buses."""
    make_entity(conn, arc_id, "arcs", "Arc")
    conn.execute(
        "INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)",
        (arc_id, from_id, to_id),
    )
    return arc_id


def make_circuit(conn, circuit_id, arc_id):
    """Create a transformer circuit (entity + row) on an existing arc."""
    make_entity(conn, circuit_id, "transformer_circuits", "TransformerCircuit")
    conn.execute(
        "INSERT INTO transformer_circuits(id, arc_id) VALUES (?, ?)",
        (circuit_id, arc_id),
    )
    return circuit_id


def _arc_between_new_buses(conn):
    return make_arc(conn, 3, make_bus(conn, 1, "b1"), make_bus(conn, 2, "b2"))


def _three_winding_topology(conn):
    """Star bus + three circuits (each terminal bus -> star bus)."""
    star_bus = make_bus(conn, 10, "star")
    circuits = []
    for i in range(3):
        base = 20 + i * 10
        terminal = make_bus(conn, base, f"bus{i}")
        arc_id = make_arc(conn, base + 1, terminal, star_bus)
        circuits.append(make_circuit(conn, base + 2, arc_id))
    return star_bus, circuits


# --------------------------------------------------------------------------- #
# Entity supertype triggers, one guard + one cascade test per subtype table.
# Each insert callable provisions its own prerequisites and inserts a row with
# the given entity id.
# --------------------------------------------------------------------------- #
def _insert_discrete_branch(conn, entity_id):
    arc_id = _arc_between_new_buses(conn)
    conn.execute(
        "INSERT INTO discrete_controlled_ac_branches"
        "(id, name, arc_id, r, x, rating) VALUES (?, 'row', ?, 0.0, 0.01, 100.0)",
        (entity_id, arc_id),
    )


def _insert_circuit(conn, entity_id):
    arc_id = _arc_between_new_buses(conn)
    conn.execute(
        "INSERT INTO transformer_circuits(id, arc_id) VALUES (?, ?)",
        (entity_id, arc_id),
    )


def _insert_two_winding(conn, entity_id):
    circuit = make_circuit(conn, 4, _arc_between_new_buses(conn))
    conn.execute(
        "INSERT INTO two_winding_transformers(id, name, circuit) VALUES (?, 'row', ?)",
        (entity_id, circuit),
    )


def _insert_three_winding(conn, entity_id):
    star_bus, circuits = _three_winding_topology(conn)
    conn.execute(
        "INSERT INTO three_winding_transformers"
        "(id, name, primary_circuit, secondary_circuit, tertiary_circuit, star_bus) "
        "VALUES (?, 'row', ?, ?, ?, ?)",
        (entity_id, *circuits, star_bus),
    )


_ENTITY_TABLE_CASES = [
    (
        "discrete_controlled_ac_branches",
        "DiscreteControlledACBranch",
        _insert_discrete_branch,
    ),
    ("transformer_circuits", "TransformerCircuit", _insert_circuit),
    ("two_winding_transformers", "TwoWindingTransformer", _insert_two_winding),
    ("three_winding_transformers", "ThreeWindingTransformer", _insert_three_winding),
]
_ENTITY_TABLE_IDS = [case[0] for case in _ENTITY_TABLE_CASES]


@pytest.mark.parametrize(
    "table, entity_type, insert_row", _ENTITY_TABLE_CASES, ids=_ENTITY_TABLE_IDS
)
def test_requires_matching_entity(fresh_db, table, entity_type, insert_row):
    """The supertype guard: a row cannot be parented by an entities row whose
    entity_table points at a different subtype table."""
    make_entity(fresh_db, 99, "transmission_lines", entity_type)
    with pytest.raises(sqlite3.IntegrityError, match=f"entity_table {table}"):
        insert_row(fresh_db, 99)


@pytest.mark.parametrize(
    "table, entity_type, insert_row", _ENTITY_TABLE_CASES, ids=_ENTITY_TABLE_IDS
)
def test_delete_cleans_entity(fresh_db, table, entity_type, insert_row):
    """With a matching entities row the insert succeeds, and deleting the row
    removes its supertype row (no orphaned entities)."""
    make_entity(fresh_db, 99, table, entity_type)
    insert_row(fresh_db, 99)
    fresh_db.execute(f"DELETE FROM {table} WHERE id = 99")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM entities WHERE id = 99"
    ).fetchone()
    assert count == 0


def test_every_entity_table_has_supertype_triggers(db):
    """Every table whose id references entities must carry both boilerplate
    triggers. discrete_controlled_ac_branches shipped without either and nobody
    noticed; this turns the next such omission into a hard failure."""
    tables = [
        row[0]
        for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND sql LIKE '%PRIMARY KEY REFERENCES entities (id)%'"
        )
    ]
    triggers = {
        row[0]
        for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'")
    }
    assert tables, "no entity-subtype tables found"
    missing = [
        name
        for table in tables
        for name in (f"check_{table}_entity_exists", f"delete_{table}_entity")
        if name not in triggers
    ]
    assert missing == []


# --------------------------------------------------------------------------- #
# Transformer CHECK constraints
# --------------------------------------------------------------------------- #
def test_two_winding_transformer_rejects_three_winding_shunt_location(fresh_db):
    """shunt_location is the TwoWindingTransformerShuntLocation enum; STAR only
    exists on the three-winding enum."""
    circuit = make_circuit(fresh_db, 4, _arc_between_new_buses(fresh_db))
    make_entity(fresh_db, 5, "two_winding_transformers", "TwoWindingTransformer")
    with pytest.raises(sqlite3.IntegrityError, match="shunt_location"):
        fresh_db.execute(
            "INSERT INTO two_winding_transformers(id, name, circuit, shunt_location) "
            "VALUES (5, 'xf2w', ?, 'STAR')",
            (circuit,),
        )


def test_three_winding_transformer_requires_distinct_circuits(fresh_db):
    star_bus, circuits = _three_winding_topology(fresh_db)
    make_entity(fresh_db, 60, "three_winding_transformers", "ThreeWindingTransformer")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            "INSERT INTO three_winding_transformers"
            "(id, name, primary_circuit, secondary_circuit, tertiary_circuit, star_bus) "
            "VALUES (60, 'xf3w', ?, ?, ?, ?)",
            (circuits[0], circuits[0], circuits[2], star_bus),
        )


def test_three_winding_transformer_pairwise_fields_all_or_none(fresh_db):
    """The nine pairwise PSSE fields (r/x pairs + base powers) must be set
    together or all be absent."""
    star_bus, circuits = _three_winding_topology(fresh_db)
    make_entity(fresh_db, 60, "three_winding_transformers", "ThreeWindingTransformer")
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            "INSERT INTO three_winding_transformers"
            "(id, name, primary_circuit, secondary_circuit, tertiary_circuit, "
            "star_bus, r_12) VALUES (60, 'xf3w', ?, ?, ?, ?, 0.01)",
            (*circuits, star_bus),
        )
    fresh_db.execute(
        "INSERT INTO three_winding_transformers"
        "(id, name, primary_circuit, secondary_circuit, tertiary_circuit, star_bus, "
        "r_12, x_12, r_23, x_23, r_31, x_31, "
        "base_power_12, base_power_23, base_power_31) "
        "VALUES (60, 'xf3w', ?, ?, ?, ?, "
        "0.01, 0.1, 0.02, 0.2, 0.03, 0.3, 100.0, 100.0, 100.0)",
        (*circuits, star_bus),
    )


def test_transformer_circuit_control_fields_roundtrip(fresh_db):
    """Control fields persist, including the corrected ASYMMETRIC_* objective
    spelling; an unknown objective is rejected by the CHECK."""
    arc_id = _arc_between_new_buses(fresh_db)
    make_entity(fresh_db, 4, "transformer_circuits", "TransformerCircuit")
    fresh_db.execute(
        "INSERT INTO transformer_circuits"
        "(id, arc_id, tap, alpha, r, x, control_objective, control_limits, rating) "
        "VALUES (4, ?, 1.05, 0.1, 0.001, 0.05, 'ASYMMETRIC_ACTIVE_POWER_FLOW', "
        "json('{\"min\": -0.5, \"max\": 0.5}'), 250.0)",
        (arc_id,),
    )
    row = fresh_db.execute(
        "SELECT tap, control_objective, json_extract(control_limits, '$.max') "
        "FROM transformer_circuits WHERE id = 4"
    ).fetchone()
    assert row == (1.05, "ASYMMETRIC_ACTIVE_POWER_FLOW", 0.5)

    make_entity(fresh_db, 5, "transformer_circuits", "TransformerCircuit")
    with pytest.raises(sqlite3.IntegrityError, match="control_objective"):
        fresh_db.execute(
            "INSERT INTO transformer_circuits(id, arc_id, control_objective) "
            "VALUES (5, ?, 'ASSYMETRIC_ACTIVE_POWER_FLOW')",
            (arc_id,),
        )


# --------------------------------------------------------------------------- #
# Transformer enum drift gate: the CHECK IN-lists in schema.sql hardcode enum
# members $ref'd from SiennaSchemas Operations/common.json by the transformer
# schemas. Editing an enum there without updating schema.sql (or vice versa)
# fails here; the schema files are the source of truth.
# --------------------------------------------------------------------------- #
_TRANSFORMER_ENUM_COLUMNS = [
    ("two_winding_transformers", "shunt_location",
     "TwoWindingTransformerShuntLocation"),
    ("three_winding_transformers", "shunt_location",
     "ThreeWindingTransformerShuntLocation"),
    ("transformer_circuits", "control_objective", "TransformerControlObjective"),
]


@pytest.mark.parametrize("table, column, definition", _TRANSFORMER_ENUM_COLUMNS)
def test_transformer_enum_checks_match_schema(db, table, column, definition):
    common = load_schemas_json("Operations/common.json")
    schema_members = common["definitions"][definition]["enum"]
    (table_sql,) = db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()
    match = re.search(column + r"\s+IN\s+\(([^)]*)\)", table_sql)
    assert match, f"no CHECK IN-list for {table}.{column}"
    check_members = re.findall(r"'([^']*)'", match.group(1))
    assert check_members == schema_members, (
        f"{table}.{column} enum drift: CHECK has {check_members} but "
        f"{definition} in Operations/common.json has {schema_members}"
    )


def test_static_time_series_rejects_duplicate_timepoint(fresh_db):
    """One value per (uuid, idx): a loader double-insert must fail loudly
    instead of silently duplicating timepoints."""
    fresh_db.execute(
        "INSERT INTO time_series_metadata(uuid, unit, quantity_type) "
        "VALUES ('ts-1', 'MW', 'ActivePower')"
    )
    fresh_db.execute(
        "INSERT INTO static_time_series(uuid, idx, value) VALUES ('ts-1', 0, 1.5)"
    )
    with pytest.raises(sqlite3.IntegrityError, match="idx"):
        fresh_db.execute(
            "INSERT INTO static_time_series(uuid, idx, value) VALUES ('ts-1', 0, 2.5)"
        )
    fresh_db.execute(
        "INSERT INTO static_time_series(uuid, idx, value) VALUES ('ts-1', 1, 2.5)"
    )
