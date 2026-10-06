"""Insert one synthetic document holding every supported component type.

The document is generated from the SiennaSchemas components in schema_map.json:
every property of every component gets a schema-valid value (its default, else a
value built from its type, enum, and bounds), and every reference points at a
generated row of the table its foreign key names. The test proves that each
component type inserts with no field skipped. It is a coverage test, not a
scalability test: one row per type, plus the few extra rows the topology needs.

Dynamic components are out of scope: schema_map.json excludes them, and the
dynamic_injector reference is left unset.
"""

import copy
import itertools
import json
import sys

import pytest

from conftest import REPO_ROOT, SCHEMA_DIR, SCHEMAS_PATH, SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
sys.path.insert(0, str(REPO_ROOT / "sdk" / "python" / "src"))
from generate_sql_schema import RefResolver  # noqa: E402

import sienna_griddb_tools as griddb  # noqa: E402

# Rows the domain triggers need beyond one per type: two AC and two DC buses for
# the AC and DC arcs, and four circuits so a three-winding transformer (three
# distinct circuits) and a two-winding one never share a circuit.
EXTRA_ROWS = {"ACBus": 2, "DCBus": 2, "Arc": 2, "TransformerCircuit": 4}
DC_REFERENCES = {("InterconnectingConverter", "dc_bus"), ("TModelHVDCLine", "arc")}
NOT_GENERATED = {"dynamic_injector"}


def _bounded_number(node, integer):
    value = 1
    if "minimum" in node:
        value = max(value, node["minimum"])
    if "exclusiveMinimum" in node:
        value = max(value, node["exclusiveMinimum"] + 1)
    if "maximum" in node:
        value = min(value, node["maximum"])
    if "exclusiveMaximum" in node:
        value = min(value, node["exclusiveMaximum"] - (1 if integer else 0.5))
    return int(value) if integer else float(value)


def schema_value(node, rel_file, resolver):
    """A schema-valid value for one property node."""
    if node.get("default") is not None:
        return copy.deepcopy(node["default"])
    if "const" in node:
        return node["const"]
    if "$ref" in node:
        target, target_file = resolver.resolve(node["$ref"], rel_file)
        return schema_value(target, target_file, resolver)
    if "enum" in node:
        # The cost triggers accept NATURAL_UNITS payloads only.
        return "NATURAL_UNITS" if "NATURAL_UNITS" in node["enum"] else node["enum"][0]
    if "discriminator" in node:
        tag, ref = sorted(node["discriminator"]["mapping"].items())[0]
        value = schema_value({"$ref": ref}, rel_file, resolver)
        value[node["discriminator"]["propertyName"]] = tag
        return value
    for key in ("oneOf", "anyOf"):
        if key in node:
            options = [o for o in node[key] if o.get("type") != "null"]
            return schema_value(options[0], rel_file, resolver)
    kind = node.get("type")
    if isinstance(kind, list):
        kind = next(k for k in kind if k != "null")
    if kind == "object" or "properties" in node:
        props = node.get("properties", {})
        return {name: schema_value(sub, rel_file, resolver) for name, sub in props.items()}
    if kind == "array":
        return [schema_value(node.get("items", {}), rel_file, resolver)]
    if kind == "integer":
        return _bounded_number(node, integer=True)
    if kind == "number":
        return _bounded_number(node, integer=False)
    if kind == "boolean":
        return True
    return "x"


def _foreign_keys(conn, table):
    """{column: referenced table} for one table."""
    return {row[3]: row[2] for row in conn.execute(f"PRAGMA foreign_key_list('{table}')")}


def synthetic_document(conn):
    """Return (document, {component type: table})."""
    resolver = RefResolver(str(SCHEMAS_PATH))
    schema_map = json.loads((SCHEMA_DIR / "schema_map.json").read_text("utf-8"))["tables"]
    codegen = json.loads((SCHEMA_DIR / "sql_codegen_map.json").read_text("utf-8"))["tables"]
    ids = itertools.count(1)

    objects = {}
    tables = {}
    for table, components in schema_map.items():
        for comp in components:
            name = comp["component"]
            tables[name] = table
            objects[name] = []
            props = resolver.doc(comp["file"])["properties"]
            for n in range(EXTRA_ROWS.get(name, 1)):
                obj = {
                    p: schema_value(node, comp["file"], resolver)
                    for p, node in props.items()
                    if p not in NOT_GENERATED
                }
                obj["id"] = next(ids)
                if "name" in props:
                    obj["name"] = f"{name}_{n}"
                objects[name].append(obj)

    def row_ids(type_name):
        return [o["id"] for o in objects[type_name]]

    ac_buses, dc_buses = row_ids("ACBus"), row_ids("DCBus")
    ac_arc, dc_arc = objects["Arc"]
    ac_arc.update(from_id=ac_buses[0], to_id=ac_buses[1])
    dc_arc.update(from_id=dc_buses[0], to_id=dc_buses[1])
    circuits = iter(row_ids("TransformerCircuit"))
    pools = {
        "balancing_topologies": ac_buses[0],
        "planning_regions": row_ids("Area")[0],
        "arcs": ac_arc["id"],
    }

    for table, components in schema_map.items():
        renames = {
            o["column"]: p
            for p, o in codegen.get(table, {}).get("columns", {}).items()
            if "column" in o
        }
        for column, target in _foreign_keys(conn, table).items():
            prop = renames.get(column, column)
            for comp in components:
                name = comp["component"]
                if name == "Arc" or column == "id":
                    continue
                for n, obj in enumerate(objects[name]):
                    if prop not in obj:
                        continue
                    if column == "load_zone":
                        obj[prop] = row_ids("LoadZone")[0]
                    elif (name, prop) in DC_REFERENCES:
                        obj[prop] = dc_arc["id"] if target == "arcs" else dc_buses[0]
                    elif target == "transformer_circuits":
                        obj[prop] = next(circuits)
                    elif target in pools:
                        obj[prop] = pools[target]
                    elif target == "entities":
                        # Distinct per column, so from_id <> to_id holds.
                        obj[prop] = ac_buses[n % 2 if prop != "to_id" else 1]
    return {"components": objects}, tables


@pytest.fixture(scope="module")
def synthetic(db):
    return synthetic_document(db)


def test_every_supported_component_type_is_generated(synthetic):
    doc, _ = synthetic
    manifest = json.loads((SCHEMA_DIR / "insert_manifest.json").read_text("utf-8"))
    assert set(doc["components"]) == set(manifest["components"])


def test_synthetic_document_inserts_every_component(synthetic, tmp_path):
    doc, tables = synthetic
    conn = griddb.create_database(str(tmp_path / "synthetic.sqlite"))
    try:
        report = griddb.insert_document(conn, doc, strict=True)
        expected = {name: len(objs) for name, objs in doc["components"].items()}
        assert report.inserted == expected
        assert report.skipped_fields == {}
        assert report.unsupported == {}
        for table in set(tables.values()):
            stored = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            generated = sum(n for name, n in expected.items() if tables[name] == table)
            assert stored == generated, table
        manifest = json.loads((SCHEMA_DIR / "insert_manifest.json").read_text("utf-8"))
        attribute_values = sum(
            obj.get(a["field"]) is not None
            for name, objs in doc["components"].items()
            for obj in objs
            for a in manifest["components"][name]["attributes"]
        )
        assert attribute_values > 0
        stored = conn.execute("SELECT count(*) FROM attributes").fetchone()[0]
        assert stored == attribute_values
    finally:
        conn.close()
