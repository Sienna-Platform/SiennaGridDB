"""Schema-integrity guards outside the unit registry: the entity supertype
triggers on discrete_controlled_ac_branches and the transformer tables, the
transformer enum/pairwise CHECK constraints, and the static_time_series
(uuid, idx) uniqueness contract."""

import re
import sqlite3

import pytest

from conftest import load_schemas_json, make_entity


def make_bus(conn, bus_id, name):
    make_entity(conn, bus_id, "balancing_topologies", "ACBus", is_topology=1)
    conn.execute(
        "INSERT INTO balancing_topologies(id, name) VALUES (?, ?)", (bus_id, name)
    )
    return bus_id


def make_dc_bus(conn, bus_id, name):
    """Create a DC balancing-topology entity plus its row (entity_types.is_dc = 1)."""
    make_entity(conn, bus_id, "balancing_topologies", "DCBus", is_topology=1, is_dc=1)
    conn.execute(
        "INSERT INTO balancing_topologies(id, name) VALUES (?, ?)", (bus_id, name)
    )
    return bus_id


def make_arc(conn, arc_id, from_id, to_id):
    make_entity(conn, arc_id, "arcs", "Arc")
    conn.execute(
        "INSERT INTO arcs(id, from_id, to_id) VALUES (?, ?, ?)",
        (arc_id, from_id, to_id),
    )
    return arc_id


def make_circuit(conn, circuit_id, arc_id):
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


# Entity supertype triggers, one guard + one cascade test per subtype table.
# Each insert callable provisions its own prerequisites and inserts a row with
# the given entity id.
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


def _insert_two_terminal_hvdc(conn, entity_id):
    arc_id = _arc_between_new_buses(conn)
    conn.execute(
        "INSERT INTO two_terminal_hvdc_lines(id, name, arc_id, converter_type) "
        "VALUES (?, 'row', ?, 'VSC')",
        (entity_id, arc_id),
    )


def _insert_synchronous_condenser(conn, entity_id):
    bus = make_bus(conn, 1, "b1")
    conn.execute(
        "INSERT INTO synchronous_condensers(id, name, bus, rating) VALUES (?, 'row', ?, 2.0)",
        (entity_id, bus),
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
    ("two_terminal_hvdc_lines", "TwoTerminalGenericHVDCLine", _insert_two_terminal_hvdc),
    ("synchronous_condensers", "SynchronousCondenser", _insert_synchronous_condenser),
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
    """Deleting a subtype row must not orphan its entities row."""
    make_entity(fresh_db, 99, table, entity_type)
    insert_row(fresh_db, 99)
    fresh_db.execute(f"DELETE FROM {table} WHERE id = 99")
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM entities WHERE id = 99"
    ).fetchone()
    assert count == 0


def test_every_entity_table_has_supertype_triggers(db):
    """Every table whose id references entities must carry both boilerplate
    triggers."""
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


# Transformer CHECK constraints
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
    """The nine pairwise measured-impedance fields (r/x pairs + base powers) must be set
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


# Transformer enum drift gate: the CHECK IN-lists in schema.sql hardcode enum
# members $ref'd from SiennaSchemas Operations/common.json by the transformer
# schemas. Editing an enum there without updating schema.sql (or vice versa)
# fails here; the schema files are the source of truth.
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
    schema_members = common["$defs"][definition]["enum"]
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


def test_supplemental_attribute_association_identity_unique(fresh_db):
    """Identity is the (component_id, attribute_id) pair (infrastore mirror);
    the denormalized type labels are not part of it, so re-attaching the same
    attribute under a different type spelling must still be rejected."""
    make_entity(fresh_db, 1)
    make_entity(fresh_db, 2, entity_table="supplemental_attributes")
    fresh_db.execute(
        "INSERT INTO supplemental_attributes(id, TYPE, value) VALUES (2, 'geo', '{}')"
    )
    fresh_db.execute(
        "INSERT INTO supplemental_attribute_associations("
        "component_id, component_type, attribute_id, attribute_type) "
        "VALUES (1, 'ThermalStandard', 2, 'GeographicInfo')"
    )
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        fresh_db.execute(
            "INSERT INTO supplemental_attribute_associations("
            "component_id, component_type, attribute_id, attribute_type) "
            "VALUES (1, 'OtherSpelling', 2, 'OtherType')"
        )


# AC/DC bus domain
# tmodel_hvdc_lines is a DC-network branch between DC buses, reached from the AC
# side through interconnecting_converters. Point-to-point HVDC
# (two_terminal_hvdc_lines) and every AC branch run between AC topologies. The
# two families were interchangeable before these triggers existed.
def _ac_arc(conn):
    return make_arc(conn, 3, make_bus(conn, 1, "ac1"), make_bus(conn, 2, "ac2"))


def _dc_arc(conn):
    return make_arc(conn, 6, make_dc_bus(conn, 4, "dc1"), make_dc_bus(conn, 5, "dc2"))


def test_tmodel_hvdc_line_requires_dc_buses(fresh_db):
    make_entity(fresh_db, 99, "tmodel_hvdc_lines", "TModelHVDCLine")
    with pytest.raises(sqlite3.IntegrityError, match="must connect DC buses"):
        fresh_db.execute(
            "INSERT INTO tmodel_hvdc_lines(id, name, arc_id, r) VALUES (99, 'dc', ?, 0.1)",
            (_ac_arc(fresh_db),),
        )


def test_tmodel_hvdc_line_accepts_dc_buses(fresh_db):
    make_entity(fresh_db, 99, "tmodel_hvdc_lines", "TModelHVDCLine")
    fresh_db.execute(
        "INSERT INTO tmodel_hvdc_lines(id, name, arc_id, r) VALUES (99, 'dc', ?, 0.1)",
        (_dc_arc(fresh_db),),
    )


def test_two_terminal_hvdc_line_rejects_dc_buses(fresh_db):
    """A point-to-point HVDC line terminates on AC buses; its DC side is internal."""
    make_entity(fresh_db, 99, "two_terminal_hvdc_lines", "TwoTerminalVSCLine")
    with pytest.raises(sqlite3.IntegrityError, match="must connect AC topologies"):
        fresh_db.execute(
            "INSERT INTO two_terminal_hvdc_lines(id, name, arc_id) VALUES (99, 'p2p', ?)",
            (_dc_arc(fresh_db),),
        )


def test_transmission_line_rejects_dc_buses(fresh_db):
    make_entity(fresh_db, 99, "transmission_lines", "Line")
    with pytest.raises(sqlite3.IntegrityError, match="must connect AC topologies"):
        fresh_db.execute(
            "INSERT INTO transmission_lines(id, name, arc_id, continuous_rating, r, x) "
            "VALUES (99, 'l', ?, 100.0, 0.01, 0.1)",
            (_dc_arc(fresh_db),),
        )


def test_arc_domain_trigger_fires_on_update(fresh_db):
    """Re-pointing an existing row's arc is checked too, not just the insert."""
    make_entity(fresh_db, 99, "tmodel_hvdc_lines", "TModelHVDCLine")
    fresh_db.execute(
        "INSERT INTO tmodel_hvdc_lines(id, name, arc_id, r) VALUES (99, 'dc', ?, 0.1)",
        (_dc_arc(fresh_db),),
    )
    with pytest.raises(sqlite3.IntegrityError, match="must connect DC buses"):
        fresh_db.execute(
            "UPDATE tmodel_hvdc_lines SET arc_id = ? WHERE id = 99", (_ac_arc(fresh_db),)
        )


def test_interconnecting_converter_bridges_ac_and_dc(fresh_db):
    ac, dc = make_bus(fresh_db, 1, "ac"), make_dc_bus(fresh_db, 2, "dc")
    make_entity(fresh_db, 99, "interconnecting_converters", "InterconnectingConverter")
    fresh_db.execute(
        "INSERT INTO interconnecting_converters(id, name, bus, dc_bus) VALUES (99, 'c', ?, ?)",
        (ac, dc),
    )


@pytest.mark.parametrize(
    "bus_kinds", [("ac", "ac"), ("dc", "dc"), ("dc", "ac")], ids=["ac-ac", "dc-dc", "swapped"]
)
def test_interconnecting_converter_rejects_wrong_domains(fresh_db, bus_kinds):
    """bus must be AC and dc_bus DC -- including the swapped case, which a plain
    pair of foreign keys would happily accept."""
    make = {"ac": make_bus, "dc": make_dc_bus}
    first = make[bus_kinds[0]](fresh_db, 1, "b1")
    second = make[bus_kinds[1]](fresh_db, 2, "b2")
    make_entity(fresh_db, 99, "interconnecting_converters", "InterconnectingConverter")
    with pytest.raises(sqlite3.IntegrityError, match="must be an AC topology"):
        fresh_db.execute(
            "INSERT INTO interconnecting_converters(id, name, bus, dc_bus) "
            "VALUES (99, 'c', ?, ?)",
            (first, second),
        )


# Identifier attributes
# The unit triggers treat any numeric JSON value as physical. Bus numbers and node
# references are not, so attribute_identifiers exempts them instead of forcing a
# made-up unit onto a key.
def _attr_owner(conn):
    make_entity(conn, 1, "balancing_topologies", "ACBus", is_topology=1)
    conn.execute("INSERT INTO balancing_topologies(id, name) VALUES (1, 'b1')")
    return 1


@pytest.mark.parametrize("name", ["number", "start_node", "end_node", "load_zone"])
def test_identifier_attribute_needs_no_unit(fresh_db, name):
    owner = _attr_owner(fresh_db)
    fresh_db.execute(
        "INSERT INTO attributes(entity_id, TYPE, name, value) VALUES (?, 'T', ?, '8901')",
        (owner, name),
    )


def test_non_identifier_numeric_attribute_still_needs_a_unit(fresh_db):
    """The exemption is scoped to the listed names, not to integers in general."""
    owner = _attr_owner(fresh_db)
    with pytest.raises(sqlite3.IntegrityError, match="require a vocabulary-valid unit"):
        fresh_db.execute(
            "INSERT INTO attributes(entity_id, TYPE, name, value) "
            "VALUES (?, 'T', 'not_an_identifier', '8901')",
            (owner,),
        )


def test_identifier_exemption_survives_update(fresh_db):
    owner = _attr_owner(fresh_db)
    fresh_db.execute(
        "INSERT INTO attributes(entity_id, TYPE, name, value) VALUES (?, 'T', 'number', '1')",
        (owner,),
    )
    fresh_db.execute("UPDATE attributes SET value = '2' WHERE name = 'number'")


def test_dc_flag_requires_topology_type(fresh_db):
    """is_dc is only meaningful for a topology type."""
    with pytest.raises(sqlite3.IntegrityError, match="is_dc"):
        fresh_db.execute(
            "INSERT INTO entity_types(name, is_topology, is_dc) VALUES ('Bogus', 0, 1)"
        )


def test_time_series_metadata_carries_time_reference_and_shape(fresh_db):
    fresh_db.execute(
        "INSERT INTO time_series_metadata"
        "(uuid, unit, quantity_type, time_reference, array_shape) "
        "VALUES ('ts-2', 'MW', 'ActivePower', 'America/Denver', '[8760]')"
    )
    (tr, shape) = fresh_db.execute(
        "SELECT time_reference, array_shape FROM time_series_metadata "
        "WHERE uuid = 'ts-2'"
    ).fetchone()
    assert tr == "America/Denver"
    assert shape == "[8760]"


def test_time_series_metadata_rejects_non_array_shape(fresh_db):
    """array_shape must be a JSON array; a bare number or object is malformed
    data, not a shape."""
    with pytest.raises(sqlite3.IntegrityError):
        fresh_db.execute(
            "INSERT INTO time_series_metadata"
            "(uuid, unit, quantity_type, array_shape) "
            "VALUES ('ts-3', 'MW', 'ActivePower', '8760')"
        )
