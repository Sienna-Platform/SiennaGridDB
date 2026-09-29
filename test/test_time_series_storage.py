"""Time series storage: arrays shared by uri, orphan cleanup, identity, and the
dangling-reference view."""

import json
import sqlite3
import sys

import pytest

from conftest import SCHEMAS_PATH, SCRIPTS_DIR, make_entity

sys.path.insert(0, str(SCRIPTS_DIR))
from generate_sql_schema import RefResolver
from insert_manifest import component_tables, load_inputs

EMPTY = "f0f10eb0149a8828ad7505d73262e3e4a70bfdfed90e4c2e9ce6013758296ede"
BUS = "8501cadc82028b22c2f212efbb7adc49644161174a9c708b0dae85892bba5da1"


def add_association(
    conn,
    owner_id,
    uri,
    *,
    name="load",
    series="SingleTimeSeries",
    resolution="PT1H",
    features_hash=EMPTY,
    assoc_id=None,
    verb="INSERT",
):
    conn.execute(
        f"{verb} INTO time_series_associations (id, owner_id, owner_type, owner_category, "
        "time_series_type, name, initial_timestamp, resolution, length, interval, uri, "
        "features_hash) VALUES (?, ?, 'thing', 'Component', ?, ?, '2026-01-01T00:00:00', "
        "?, 3, ?, ?, ?)",
        (
            assoc_id,
            owner_id,
            series,
            name,
            resolution,
            "PT0S" if series != "SingleTimeSeries" else None,
            uri,
            features_hash,
        ),
    )
    return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def add_values(conn, uri, values, width=1):
    conn.executemany(
        "INSERT INTO static_time_series (uri, timestep, element, value) VALUES (?, ?, ?, ?)",
        [(uri, i // width, i % width, v) for i, v in enumerate(values)],
    )


def series_values(conn, assoc_id):
    return [
        r[0]
        for r in conn.execute(
            "SELECT v.value FROM time_series_associations a "
            "JOIN static_time_series v ON v.uri = a.uri WHERE a.id = ? "
            "ORDER BY v.timestep, v.element",
            (assoc_id,),
        )
    ]


def count_values(conn, uri):
    return conn.execute(
        "SELECT count(*) FROM static_time_series WHERE uri = ?", (uri,)
    ).fetchone()[0]


def test_one_array_many_associations(fresh_db):
    make_entity(fresh_db, 1)
    make_entity(fresh_db, 2)
    ids = [
        add_association(fresh_db, 1, "u1"),
        add_association(fresh_db, 1, "u1", series="DeterministicSingleTimeSeries"),
        add_association(fresh_db, 2, "u1"),
        add_association(fresh_db, 2, "u1", series="DeterministicSingleTimeSeries"),
    ]
    add_values(fresh_db, "u1", [1.0, 2.0, 3.0])
    assert count_values(fresh_db, "u1") == 3
    for assoc_id in ids:
        assert series_values(fresh_db, assoc_id) == [1.0, 2.0, 3.0]


def test_delete_keeps_shared_values_until_the_last(fresh_db):
    make_entity(fresh_db, 1)
    make_entity(fresh_db, 2)
    first = add_association(fresh_db, 1, "u1", features_hash=BUS)
    add_association(fresh_db, 2, "u1", features_hash=BUS)
    add_values(fresh_db, "u1", [1.0, 2.0, 3.0])
    fresh_db.execute(
        "INSERT INTO feature_sets (features_hash, key, value_kind, value_int) "
        "VALUES (?, 'bus', 'int', 33081)",
        (BUS,),
    )
    fresh_db.execute("DELETE FROM time_series_associations WHERE id = ?", (first,))
    assert count_values(fresh_db, "u1") == 3
    fresh_db.execute("DELETE FROM entities WHERE id = 2")  # cascades to its association
    assert count_values(fresh_db, "u1") == 0
    assert fresh_db.execute("SELECT count(*) FROM feature_sets").fetchone()[0] == 1


def test_uri_update_drops_the_orphaned_array(fresh_db):
    make_entity(fresh_db, 1)
    assoc_id = add_association(fresh_db, 1, "u1")
    add_association(fresh_db, 1, "u2", name="other")
    add_values(fresh_db, "u1", [1.0])
    add_values(fresh_db, "u2", [2.0])
    fresh_db.execute(
        "UPDATE time_series_associations SET uri = 'u2' WHERE id = ?", (assoc_id,)
    )
    assert count_values(fresh_db, "u1") == 0
    assert count_values(fresh_db, "u2") == 1


ORPHANS = "SELECT problem, uri, association_id FROM orphaned_time_series ORDER BY uri"


def test_orphan_view_lists_what_a_replace_leaves(fresh_db):
    """A REPLACE conflict delete fires no trigger (recursive_triggers is off)."""
    make_entity(fresh_db, 1)
    add_association(fresh_db, 1, "u1", assoc_id=1)
    add_values(fresh_db, "u1", [1.0, 2.0])
    assert fresh_db.execute(ORPHANS).fetchall() == []
    add_association(fresh_db, 1, "u2", assoc_id=1, verb="INSERT OR REPLACE")
    assert fresh_db.execute(ORPHANS).fetchall() == [
        ("values without association", "u1", None),
        ("association without values", "u2", 1),
    ]


def test_orphan_view_lists_what_a_uri_swap_drops(fresh_db):
    """The update trigger runs per row, so a one-statement swap drops the array
    the second row is about to name."""
    make_entity(fresh_db, 1)
    add_association(fresh_db, 1, "u1", assoc_id=1)
    add_association(fresh_db, 1, "u2", name="other", assoc_id=2)
    add_values(fresh_db, "u1", [1.0])
    add_values(fresh_db, "u2", [2.0])
    fresh_db.execute(
        "UPDATE time_series_associations SET uri = CASE uri WHEN 'u1' THEN 'u2' ELSE 'u1' END"
    )
    assert fresh_db.execute(ORPHANS).fetchall() == [("association without values", "u1", 2)]


def test_one_owner_many_series_and_identity(fresh_db):
    make_entity(fresh_db, 1)
    add_association(fresh_db, 1, "u1")
    add_association(fresh_db, 1, "u2", name="other")
    add_association(fresh_db, 1, "u3", resolution="PT5M")
    add_association(fresh_db, 1, "u4", features_hash=BUS)
    add_association(fresh_db, 1, "u1", series="DeterministicSingleTimeSeries")
    assert fresh_db.execute("SELECT count(*) FROM time_series_associations").fetchone() == (
        5,
    )
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        add_association(fresh_db, 1, "u9")


def test_composite_elements_are_unique_per_slot(fresh_db):
    make_entity(fresh_db, 1)
    assoc_id = add_association(fresh_db, 1, "u1")
    add_values(fresh_db, "u1", [2.0, 0.0, 10.0, 5.0, 3.0, 1.0], width=3)
    assert series_values(fresh_db, assoc_id) == [2.0, 0.0, 10.0, 5.0, 3.0, 1.0]
    with pytest.raises(sqlite3.IntegrityError, match="element"):
        fresh_db.execute(
            "INSERT INTO static_time_series (uri, timestep, element, value) "
            "VALUES ('u1', 1, 2, 9.0)"
        )


def test_dangling_view_lists_unresolved_references(fresh_db):
    make_entity(fresh_db, 1, "supplemental_attributes", "Payload")
    payload = {
        "fuel_cost_time_series": 77,
        "curve": {
            "initial_input_association_id": 78,
            "function_data": {"association_id": 1},
        },
    }
    fresh_db.execute(
        "INSERT INTO supplemental_attributes (id, TYPE, value) VALUES (1, 'Payload', ?)",
        (json.dumps(payload),),
    )
    add_association(fresh_db, 1, "u1", assoc_id=1)
    view = "SELECT * FROM dangling_time_series_references ORDER BY association_id"
    assert fresh_db.execute(view).fetchall() == [
        (1, "supplemental_attributes", "value", '$."fuel_cost_time_series"', 77),
        (
            1,
            "supplemental_attributes",
            "value",
            '$.curve."initial_input_association_id"',
            78,
        ),
    ]
    add_association(fresh_db, 1, "u2", name="fuel", assoc_id=77)
    add_association(fresh_db, 1, "u3", name="initial", assoc_id=78)
    assert fresh_db.execute(view).fetchall() == []


def test_dangling_view_reads_a_bare_integer_reference(fresh_db):
    """A scalar reference (here an attribute) is named by its column, not a key."""
    make_entity(fresh_db, 1, "thermal_generators", "Payload")
    fresh_db.execute(
        "INSERT INTO attribute_identifiers (TYPE, name) VALUES ('Payload', 'start_association_id')"
    )
    fresh_db.execute(
        "INSERT INTO attributes (entity_id, TYPE, name, value) "
        "VALUES (1, 'Payload', 'start_association_id', '5')"
    )
    view = "SELECT source_table, source_column, association_id FROM dangling_time_series_references"
    assert fresh_db.execute(view).fetchall() == [("attributes", "start_association_id", 5)]


def _is_reference(key):
    return key in ("association_id", "fuel_cost_time_series") or key.endswith(
        "_association_id"
    )


def _holds_reference(resolver, name, prop, rel_file, memo):
    """Whether a component property is a time series reference or can hold one."""
    return _is_reference(name) or _reaches_reference(resolver, prop, rel_file, memo)


def _reaches_reference(resolver, node, rel_file, memo):
    """Whether a schema node can hold a time series reference field."""
    if isinstance(node, list):
        return any(_reaches_reference(resolver, n, rel_file, memo) for n in node)
    if not isinstance(node, dict):
        return False
    if "$ref" in node:
        target, target_file = resolver.resolve(node["$ref"], rel_file)
        key = (target_file, node["$ref"].partition("#")[2])
        if key not in memo:
            memo[key] = False  # a cycle adds nothing new
            memo[key] = _reaches_reference(resolver, target, target_file, memo)
        if memo[key]:
            return True
    for name, prop in node.get("properties", {}).items():
        if _is_reference(name) or _reaches_reference(resolver, prop, rel_file, memo):
            return True
    return any(
        _reaches_reference(resolver, node.get(k), rel_file, memo)
        for k in ("items", "additionalProperties", "anyOf", "oneOf", "allOf")
    )


def test_dangling_view_covers_every_reference_column(db):
    """Every column the inserter writes a reference-bearing schema property to
    is an arm of dangling_time_series_references."""
    view = db.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'dangling_time_series_references'"
    ).fetchone()[0]
    manifest = json.loads(
        (SCRIPTS_DIR.parent / "schema" / "insert_manifest.json").read_text(encoding="utf-8")
    )
    resolver = RefResolver(str(SCHEMAS_PATH))
    memo = {}
    needed = set()
    for table, comps in component_tables(load_inputs()).items():
        for comp in comps:
            entry = manifest["components"][comp["component"]]
            columns = entry["row_sql"].split("(", 1)[1].split(")", 1)[0].split(", ")
            bound = {b["path"]: c for b, c in zip(entry["bindings"], columns)}
            attributes = {a["field"] for a in entry["attributes"]}
            props = resolver.doc(comp["file"]).get("properties", {})
            for name, prop in props.items():
                if not _holds_reference(resolver, name, prop, comp["file"], memo):
                    continue
                if name in bound:
                    needed.add(f"'{table}', '{bound[name]}'")
                elif name in attributes:
                    needed.add("'attributes', name")
    assert needed, "the walk found no reference-bearing column"
    missing = sorted(n for n in needed if n not in view)
    assert not missing, f"dangling_time_series_references lacks arms for {missing}"


def test_a_top_level_reference_property_counts():
    """A plain integer column such as a *_association_id property needs an arm too."""
    resolver = RefResolver(str(SCHEMAS_PATH))
    prop = {"type": ["integer", "null"]}
    assert _holds_reference(resolver, "active_power_association_id", prop, "x.json", {})
    assert not _holds_reference(resolver, "rating", prop, "x.json", {})
