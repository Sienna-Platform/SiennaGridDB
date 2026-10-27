#!/usr/bin/env python3
"""Build the GridDB insert manifest: SDK component -> predictable INSERT SQL.

Pure functions over the repo's mapping files, the SiennaSchemas components, and a
throwaway in-memory database built from schema/schema.sql + triggers.sql +
unit_registry.sql (the database is the source of truth for columns, defaults, and
foreign keys -- no DDL parsing). generate_insert_manifest.py is the CLI.
"""

import graphlib
import json
import os

from _common import load_json, sql_literal
from check_units_sync import build_db
from generate_sql_schema import (
    attribute_rows,
    load_units_index,
    schema_doc,
    sql_type_for,
    vocabulary,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(REPO_ROOT, "schema")

ENCODING_BY_KIND = {
    "integer": "int",
    "number": "real",
    "boolean": "bool",
    "string": "text",
    "json": "json",
}
# A decomposed part is a number or a structured value.
ENCODING_BY_SQL_TYPE = {"INTEGER": "int", "REAL": "real", "TEXT": "json"}


class ManifestError(Exception):
    """The mapping inputs cannot produce a valid manifest."""


def table_columns(conn, table):
    """{column: {"type", "notnull", "default", "hidden"}} in declaration order."""
    rows = conn.execute(f"PRAGMA table_xinfo('{table}')").fetchall()
    if not rows:
        raise ManifestError(f"table {table} does not exist in schema.sql")
    return {
        row[1]: {"type": row[2], "notnull": bool(row[3]), "default": row[4], "hidden": row[6] != 0}
        for row in rows
    }


def load_inputs(schema_dir=SCHEMA_DIR):
    return {
        "schema_map": load_json(os.path.join(schema_dir, "schema_map.json"))["tables"],
        "codegen": load_json(os.path.join(schema_dir, "sql_codegen_map.json"))["tables"],
        "config": load_json(os.path.join(schema_dir, "insert_config.json")),
    }


def attribute_plan(name, comp, prop_name, prop, schemas_root, units_index, unit_override):
    """How the runtimes write one attribute-channel field.

    Mirrors the conventions generate_sql_schema.py registers for the field:
    `arms` maps the value of `unit_field` (or "" for a fixed unit) to its unit
    and quantity kind, and `exempt` marks a unitless structured value that
    attribute_identifiers lets through with no unit.
    """
    entry = {"node": prop, "file": comp["file"], "owners": [name]}
    convs, owners, problems = attribute_rows(
        prop_name, entry, schemas_root, units_index, unit_override
    )
    if problems:
        raise ManifestError("; ".join(problems))
    if any("discriminator_column_2" in c for c in convs):
        raise ManifestError(f"{name}.{prop_name}: a second unit discriminator is not supported")
    unit_field = convs[0].get("discriminator_column") if convs else None
    arms = {
        c.get("discriminator_value", ""): {"unit": c["unit"], "quantity_kind": c["quantity_kind"]}
        for c in convs
    }
    return {"field": prop_name, "unit_field": unit_field, "arms": arms, "exempt": bool(owners)}


def compute_ranks(conn, tables):
    deps = {
        t: {r[2] for r in conn.execute(f"PRAGMA foreign_key_list('{t}')") if r[2] in tables and r[2] != t}
        for t in tables
    }
    ranks = {}
    try:
        for table in graphlib.TopologicalSorter(deps).static_order():
            ranks[table] = max((ranks[d] + 1 for d in deps[table]), default=0)
    except graphlib.CycleError as err:
        raise ManifestError("foreign-key cycle: " + " -> ".join(err.args[1])) from err
    return ranks


def default_literal(prop, column):
    """SiennaSchemas default first, then the DB DEFAULT, else None."""
    if prop.get("default") is not None:
        return sql_literal(prop["default"])
    return column["default"]


def component_entry(conn, schemas_root, inputs, table, comp, rank, units_index):
    cfg = inputs["codegen"].get(table, {})
    config = inputs["config"]
    renames = {p: o["column"] for p, o in cfg.get("columns", {}).items() if "column" in o}
    attribute_channel = set(cfg.get("attribute_channel", []))
    skip = set(cfg.get("skip", []))
    name = comp["component"]
    constants = config["constants"].get(name, {})
    columns = table_columns(conn, table)
    props = schema_doc(schemas_root, comp["file"]).get("properties", {})
    if "id" not in props:
        raise ManifestError(f"{name} has no id property")
    decomposed = {p: t for p, t in cfg.get("decomposed", {}).items() if p in props}

    bound = {}
    attributes = []
    skipped = []
    for prop_name, prop in props.items():
        column = renames.get(prop_name, prop_name)
        if column in columns and not columns[column]["hidden"]:
            kind = sql_type_for(prop, schemas_root, comp["file"])[0]
            bound[column] = {
                "path": prop_name,
                "encode": ENCODING_BY_KIND[kind],
                "default": default_literal(prop, columns[column]),
            }
        elif prop_name in decomposed:
            continue
        elif prop_name in attribute_channel:
            attributes.append(
                attribute_plan(
                    name, comp, prop_name, prop, schemas_root, units_index,
                    cfg.get("attribute_units", {}).get(prop_name),
                )
            )
        elif prop_name in skip:
            skipped.append(prop_name)
        else:
            raise ManifestError(
                f"{name}.{prop_name} has no column, attribute channel, decomposed, or skip entry"
            )
    for targets in decomposed.values():
        for column, path in targets.items():
            bound[column] = {
                "path": path,
                "encode": ENCODING_BY_SQL_TYPE[columns[column]["type"]],
                "default": columns[column]["default"],
            }

    for column, info in columns.items():
        if info["hidden"] or column in bound or column in constants:
            continue
        if info["notnull"] and info["default"] is None:
            raise ManifestError(
                f"{name}: {table}.{column} is NOT NULL with no default and no SDK source"
            )

    ordered = ["id"] + [c for c in columns if c in bound and c != "id"]
    placeholders = []
    bindings = []
    for column in ordered:
        spec = bound[column]
        bindings.append({"path": spec["path"], "encode": spec["encode"]})
        if column != "id" and spec["default"] is not None:
            placeholders.append(f"COALESCE(?, {spec['default']})")
        else:
            placeholders.append("?")
    for column, value in sorted(constants.items()):
        ordered.append(column)
        placeholders.append(sql_literal(value))
    row_sql = (
        f"INSERT INTO {table} ({', '.join(ordered)}) VALUES ({', '.join(placeholders)})"
    )
    entity_sql = (
        "INSERT INTO entities (id, entity_table, entity_type) "
        f"VALUES (?, {sql_literal(table)}, {sql_literal(name)})"
    )
    return {
        "table": table,
        "rank": rank,
        "entity_sql": entity_sql,
        "row_sql": row_sql,
        "bindings": bindings,
        "attributes": sorted(attributes, key=lambda a: a["field"]),
        "skip": sorted(skipped),
    }


def association_entry(conn, schemas_root, section, rel_file):
    columns = table_columns(conn, section)
    props = schema_doc(schemas_root, rel_file)["properties"]
    names = [p for p in props if p in columns]
    missing = sorted(set(props) - set(names))
    if missing:
        raise ManifestError(f"{section}: schema properties with no column: {missing}")
    bindings = [
        {
            "path": p,
            "encode": ENCODING_BY_KIND[sql_type_for(props[p], schemas_root, rel_file)[0]],
        }
        for p in names
    ]
    row_sql = f"INSERT INTO {section} ({', '.join(names)}) VALUES ({', '.join('?' for _ in names)})"
    fk_columns = {row[3] for row in conn.execute(f"PRAGMA foreign_key_list('{section}')")}
    references = [p for p in names if p in fk_columns]
    return {"section": section, "row_sql": row_sql, "bindings": bindings, "references": references}


def build_manifest(schemas_path, schema_dir=SCHEMA_DIR):
    inputs = load_inputs(schema_dir)
    config = inputs["config"]
    conn = build_db(schema_dir)
    tables = inputs["schema_map"]
    ranks = compute_ranks(conn, tables)
    units_index = load_units_index(schemas_path)
    components = {}
    for table in sorted(tables):
        for comp in tables[table]:
            components[comp["component"]] = component_entry(
                conn, schemas_path, inputs, table, comp, ranks[table], units_index
            )
    for entry in components.values():
        sql = entry["row_sql"]
        conn.execute("EXPLAIN " + sql, [None] * sql.count("?"))
    associations = [
        association_entry(conn, schemas_path, section, rel_file)
        for section, rel_file in config["association_sections"]
    ]
    return {
        "schema_user_version": conn.execute("PRAGMA user_version").fetchone()[0],
        "vocabulary": vocabulary(inputs["config"], components, schemas_path),
        "components": components,
        "attribute_sql": (
            "INSERT INTO attributes (entity_id, TYPE, name, value, unit, quantity_kind) "
            "VALUES (?, ?, ?, ?, ?, ?)"
        ),
        "supplemental_attributes": {
            "plant_types": sorted(config["plant_attribute_types"]),
            "plant_sql": "INSERT INTO plants (id, name, TYPE, value) VALUES (?, ?, ?, ?)",
            "attribute_sql": (
                "INSERT INTO supplemental_attributes (id, TYPE, value) VALUES (?, ?, ?)"
            ),
        },
        "associations": associations,
        "unsupported_sections": config["unsupported_sections"],
    }


def render(document):
    return json.dumps(document, indent=2, sort_keys=True) + "\n"
