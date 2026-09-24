#!/usr/bin/env python3
"""Build the GridDB insert manifest: SDK component -> predictable INSERT SQL.

Pure functions over the repo's mapping files, the SiennaSchemas components, and a
throwaway in-memory database built from schema/schema.sql + triggers.sql +
unit_registry.sql (the database is the source of truth for columns, defaults, and
foreign keys -- no DDL parsing). generate_insert_manifest.py is the CLI.
"""

import json
import os

from _common import load_json, sql_literal
from check_units_sync import build_db
from generate_sql_schema import RefResolver, sql_type_for

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_DIR = os.path.join(REPO_ROOT, "schema")
MANIFEST_VERSION = 1

ENCODING_BY_SQL_TYPE = {
    "INTEGER": "int",
    "REAL": "real",
    "BOOLEAN": "bool",
    "TEXT": "text",
    "JSON": "json",
}


class ManifestError(Exception):
    """The mapping inputs cannot produce a valid manifest."""


def table_columns(conn, table):
    """{column: {"notnull", "default", "hidden"}} in declaration order."""
    rows = conn.execute(f"PRAGMA table_xinfo('{table}')").fetchall()
    if not rows:
        raise ManifestError(f"table {table} does not exist in schema.sql")
    return {
        row[1]: {"notnull": bool(row[3]), "default": row[4], "hidden": row[6] != 0}
        for row in rows
    }


def load_inputs(schema_dir=SCHEMA_DIR):
    return {
        "schema_map": load_json(os.path.join(schema_dir, "schema_map.json"))["tables"],
        "codegen": load_json(os.path.join(schema_dir, "sql_codegen_map.json"))["tables"],
        "conventions": load_json(os.path.join(schema_dir, "column_conventions.json"))[
            "conventions"
        ],
        "config": load_json(os.path.join(schema_dir, "insert_config.json")),
    }


def component_tables(inputs):
    """{table: [{"component", "file"}]} from schema_map.json plus extra_components."""
    tables = {t: list(c) for t, c in inputs["schema_map"].items()}
    for table, comps in inputs["config"]["extra_components"].items():
        tables.setdefault(table, []).extend(comps)
    return tables


def attribute_units(conventions):
    """{attribute name: (unit, quantity_kind)} from the attributes.* conventions."""
    units = {}
    for entry in conventions:
        if entry["table"] == "attributes":
            units[entry["column"]] = (entry["unit"], entry["quantity_kind"])
    return units


def compute_ranks(conn, tables):
    deps = {t: set() for t in tables}
    for table in tables:
        for row in conn.execute(f"PRAGMA foreign_key_list('{table}')"):
            ref = row[2]
            if ref in deps and ref != table:
                deps[table].add(ref)
    ranks = {}

    def visit(table, stack):
        if table in ranks:
            return ranks[table]
        if table in stack:
            raise ManifestError("foreign-key cycle: " + " -> ".join([*stack, table]))
        rank = 0
        for dep in sorted(deps[table]):
            rank = max(rank, 1 + visit(dep, [*stack, table]))
        ranks[table] = rank
        return rank

    for table in sorted(tables):
        visit(table, [])
    return ranks


def default_literal(prop, column):
    """SiennaSchemas default first, then the DB DEFAULT, else None."""
    if prop.get("default") is not None:
        return sql_literal(prop["default"])
    return column["default"]


def component_entry(conn, resolver, inputs, table, comp, rank, units):
    cfg = inputs["codegen"].get(table, {})
    config = inputs["config"]
    renames = cfg.get("renames", {})
    attribute_channel = set(cfg.get("attribute_channel", []))
    skip = set(cfg.get("skip", []))
    name = comp["component"]
    derived = config["derived"].get(name, {})
    constants = config["constants"].get(name, {})
    derived_sources = {spec["path"].split(".")[0] for spec in derived.values()}
    columns = table_columns(conn, table)
    props = resolver.doc(comp["file"]).get("properties", {})
    if "id" not in props:
        raise ManifestError(f"{name} has no id property")

    bound = {}
    attributes = []
    gaps = []
    skipped = []
    for prop_name, prop in props.items():
        column = renames.get(prop_name, prop_name)
        if column in columns and not columns[column]["hidden"]:
            sql_type = sql_type_for(prop, resolver, comp["file"])[0]
            bound[column] = {
                "path": prop_name,
                "encode": ENCODING_BY_SQL_TYPE[sql_type],
                "default": default_literal(prop, columns[column]),
            }
        elif prop_name in derived_sources:
            continue
        elif prop_name in attribute_channel:
            unit, quantity_kind = units.get(prop_name, (None, None))
            attributes.append(
                {"field": prop_name, "unit": unit, "quantity_kind": quantity_kind}
            )
        elif prop_name in skip:
            skipped.append(prop_name)
        else:
            gaps.append(prop_name)
    for column, spec in derived.items():
        if column not in columns:
            raise ManifestError(f"{name}: derived column {table}.{column} does not exist")
        bound[column] = {
            "path": spec["path"],
            "encode": spec["encode"],
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
        "gaps": sorted(gaps),
    }


def vocabulary(resolver, inputs, component_names, schemas_path):
    config = inputs["config"]
    flags = config["entity_type_flags"]
    entity_types = set(component_names)
    for rel_dir in config["supplemental_attribute_dirs"]:
        directory = os.path.join(schemas_path, rel_dir)
        for file_name in os.listdir(directory):
            if file_name.endswith(".json"):
                entity_types.add(file_name[: -len(".json")])
    vocab = {
        "entity_types": [
            {
                "name": n,
                "is_topology": flags.get(n, {}).get("is_topology", False),
                "is_dc": flags.get(n, {}).get("is_dc", False),
            }
            for n in sorted(entity_types)
        ]
    }
    for table, ref in sorted(config["vocabulary_enums"].items()):
        rel_file, _, frag = ref.partition("#")
        node, _ = resolver.resolve("#" + frag, rel_file)
        vocab[table] = sorted(node["enum"])
    return vocab


def association_entry(conn, resolver, section, rel_file):
    columns = table_columns(conn, section)
    props = resolver.doc(rel_file)["properties"]
    names = [p for p in props if p in columns]
    missing = sorted(set(props) - set(names))
    if missing:
        raise ManifestError(f"{section}: schema properties with no column: {missing}")
    bindings = [
        {
            "path": p,
            "encode": ENCODING_BY_SQL_TYPE[sql_type_for(props[p], resolver, rel_file)[0]],
        }
        for p in names
    ]
    row_sql = f"INSERT INTO {section} ({', '.join(names)}) VALUES ({', '.join('?' for _ in names)})"
    return {"section": section, "row_sql": row_sql, "bindings": bindings}


def build_manifest(schemas_path, schema_dir=SCHEMA_DIR):
    inputs = load_inputs(schema_dir)
    config = inputs["config"]
    resolver = RefResolver(schemas_path)
    conn = build_db(schema_dir)
    tables = component_tables(inputs)
    ranks = compute_ranks(conn, tables)
    units = attribute_units(inputs["conventions"])
    components = {}
    for table in sorted(tables):
        for comp in tables[table]:
            components[comp["component"]] = component_entry(
                conn, resolver, inputs, table, comp, ranks[table], units
            )
    for entry in components.values():
        sql = entry["row_sql"]
        conn.execute("EXPLAIN " + sql, [None] * sql.count("?"))
    associations = [
        association_entry(conn, resolver, section, rel_file)
        for section, rel_file in config["association_sections"]
    ]
    return {
        "manifest_version": MANIFEST_VERSION,
        "schema_user_version": conn.execute("PRAGMA user_version").fetchone()[0],
        "vocabulary": vocabulary(resolver, inputs, components, schemas_path),
        "components": components,
        "unsupported_components": config["unsupported_components"],
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


def gap_report(manifest):
    return {
        "description": (
            "GENERATED by scripts/generate_insert_manifest.py -- do not edit. SDK properties "
            "with no DB column, attribute channel, or skip entry; the inserter reports "
            "values in these fields as skipped instead of writing them."
        ),
        "gaps": {
            name: entry["gaps"]
            for name, entry in sorted(manifest["components"].items())
            if entry["gaps"]
        },
    }


def render(document):
    return json.dumps(document, indent=2, sort_keys=True) + "\n"
