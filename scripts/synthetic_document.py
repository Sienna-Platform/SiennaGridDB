#!/usr/bin/env python3
"""Generate a synthetic document with every component type.

The document is generated from the SiennaSchemas components in schema_map.json:
every property of every component gets a schema-valid value (its default, else a
value built from its type, enum, and bounds), and every reference points at a
generated row of the table its foreign key names. It is a coverage check, not a
scalability check: one row per type, plus the few extra rows the topology needs.
Dynamic components are out of scope: schema_map.json excludes them, and
dynamic_injector is not set.
"""

import copy
import itertools
import json
import os

from generate_sql_schema import resolve_ref, schema_doc

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(REPO_ROOT, "schema")

# Rows the domain triggers need beyond one per type: two AC and two DC buses for
# the AC and DC arcs, and four circuits so a three-winding transformer (three
# distinct circuits) and a two-winding one never share a circuit.
EXTRA_ROWS = {"ACBus": 2, "DCBus": 2, "Arc": 2, "TransformerCircuit": 4}
DC_REFERENCES = {("InterconnectingConverter", "dc_bus"), ("TModelHVDCLine", "arc")}
NOT_GENERATED = {"dynamic_injector"}


def _load(name):
    with open(os.path.join(SCHEMA_DIR, name), encoding="utf-8") as handle:
        return json.load(handle)


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


def schema_value(node, rel_file, schemas_root):
    """A schema-valid value for one property node."""
    if node.get("default") is not None:
        return copy.deepcopy(node["default"])
    if "const" in node:
        return node["const"]
    if "$ref" in node:
        target, target_file = resolve_ref(schemas_root, node["$ref"], rel_file)
        return schema_value(target, target_file, schemas_root)
    if "enum" in node:
        # The cost triggers accept NATURAL_UNITS payloads only.
        return "NATURAL_UNITS" if "NATURAL_UNITS" in node["enum"] else node["enum"][0]
    if "discriminator" in node:
        tag, ref = sorted(node["discriminator"]["mapping"].items())[0]
        value = schema_value({"$ref": ref}, rel_file, schemas_root)
        value[node["discriminator"]["propertyName"]] = tag
        return value
    for key in ("oneOf", "anyOf"):
        if key in node:
            options = [o for o in node[key] if o.get("type") != "null"]
            return schema_value(options[0], rel_file, schemas_root)
    kind = node.get("type")
    if isinstance(kind, list):
        kind = next(k for k in kind if k != "null")
    if kind == "object" or "properties" in node:
        props = node.get("properties", {})
        return {name: schema_value(sub, rel_file, schemas_root) for name, sub in props.items()}
    if kind == "array":
        return [schema_value(node.get("items", {}), rel_file, schemas_root)]
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


def synthetic_document(conn, schemas_path):
    """Return (document, {component type: table}). conn is a built GridDB."""
    schema_map = _load("schema_map.json")["tables"]
    codegen = _load("sql_codegen_map.json")["tables"]
    ids = itertools.count(1)

    objects = {}
    tables = {}
    for table, components in schema_map.items():
        for comp in components:
            name = comp["component"]
            tables[name] = table
            objects[name] = []
            props = schema_doc(schemas_path, comp["file"])["properties"]
            for n in range(EXTRA_ROWS.get(name, 1)):
                obj = {
                    p: schema_value(node, comp["file"], schemas_path)
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

