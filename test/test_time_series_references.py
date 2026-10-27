"""dangling_time_series_references: every payload reference no association resolves."""

import json
import sys

from conftest import SCHEMAS_PATH, SCRIPTS_DIR, make_entity

sys.path.insert(0, str(SCRIPTS_DIR))
from generate_sql_schema import resolve_ref, schema_doc
from insert_manifest import load_inputs

EMPTY = "f0f10eb0149a8828ad7505d73262e3e4a70bfdfed90e4c2e9ce6013758296ede"
VIEW = "SELECT * FROM dangling_time_series_references ORDER BY association_id"


def add_association(conn, owner_id, assoc_id, name):
    conn.execute(
        "INSERT INTO time_series_associations (id, owner_id, owner_type, owner_category, "
        "time_series_type, name, initial_timestamp, resolution, length, uri, features_hash) "
        "VALUES (?, ?, 'thing', 'Component', 'SingleTimeSeries', ?, '2026-01-01T00:00:00', "
        "'PT1H', 3, 'u', ?)",
        (assoc_id, owner_id, name, EMPTY),
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
    add_association(fresh_db, 1, 1, "load")
    assert fresh_db.execute(VIEW).fetchall() == [
        (1, "supplemental_attributes", "value", '$."fuel_cost_time_series"', 77),
        (
            1,
            "supplemental_attributes",
            "value",
            '$.curve."initial_input_association_id"',
            78,
        ),
    ]
    add_association(fresh_db, 1, 77, "fuel")
    add_association(fresh_db, 1, 78, "initial")
    assert fresh_db.execute(VIEW).fetchall() == []


def test_dangling_view_reads_a_reference_spelled_as_a_real(fresh_db):
    """The SDKs read 9.0 as the id 9, so the view must too."""
    make_entity(fresh_db, 1, "supplemental_attributes", "Payload")
    fresh_db.execute(
        "INSERT INTO supplemental_attributes (id, TYPE, value) VALUES (1, 'Payload', ?)",
        (json.dumps({"fuel_cost_time_series": 9.0}),),
    )
    view = "SELECT source_column, path, association_id FROM dangling_time_series_references"
    assert fresh_db.execute(view).fetchall() == [("value", '$."fuel_cost_time_series"', 9.0)]


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


def _reaches_reference(node, rel_file, memo):
    """Whether a schema node can hold a time series reference field."""
    if isinstance(node, list):
        return any(_reaches_reference(n, rel_file, memo) for n in node)
    if not isinstance(node, dict):
        return False
    if "$ref" in node:
        target, target_file = resolve_ref(str(SCHEMAS_PATH), node["$ref"], rel_file)
        key = (target_file, node["$ref"].partition("#")[2])
        if key not in memo:
            memo[key] = False  # a cycle adds nothing new
            memo[key] = _reaches_reference(target, target_file, memo)
        if memo[key]:
            return True
    for name, prop in node.get("properties", {}).items():
        if _is_reference(name) or _reaches_reference(prop, rel_file, memo):
            return True
    return any(
        _reaches_reference(node.get(k), rel_file, memo)
        for k in ("items", "additionalProperties", "anyOf", "oneOf", "allOf")
    )


def test_dangling_view_covers_every_reference_column(db):
    """Every column the inserter writes a reference-bearing schema property to is an
    arm of the view; a decomposed property is checked under each of its columns."""
    view = db.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'dangling_time_series_references'"
    ).fetchone()[0]
    manifest = json.loads(
        (SCRIPTS_DIR.parent / "schema" / "insert_manifest.json").read_text()
    )
    memo = {}
    needed = set()
    for table, comps in load_inputs()["schema_map"].items():
        for comp in comps:
            entry = manifest["components"][comp["component"]]
            columns = entry["row_sql"].split("(", 1)[1].split(")", 1)[0].split(", ")
            bound = {}
            for b, c in zip(entry["bindings"], columns):
                bound.setdefault(b["path"].split(".")[0], []).append(c)
            attributes = {a["field"] for a in entry["attributes"]}
            props = schema_doc(str(SCHEMAS_PATH), comp["file"]).get("properties", {})
            for name, prop in props.items():
                if not (
                    _is_reference(name) or _reaches_reference(prop, comp["file"], memo)
                ):
                    continue
                needed.update(f"'{table}', '{c}'" for c in bound.get(name, []))
                if name in attributes:
                    needed.add("'attributes', name")
    assert needed, "the walk found no reference-bearing column"
    missing = sorted(n for n in needed if n not in view)
    assert not missing, f"dangling_time_series_references lacks arms for {missing}"
