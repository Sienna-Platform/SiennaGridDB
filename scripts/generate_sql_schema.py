#!/usr/bin/env python3
"""Generate the component-table DDL and its unit conventions from SiennaSchemas.

The SiennaSchemas JSON Schemas are the source of truth for every component
table. This script writes two outputs from them:

  schema/schema.sql            the region between BEGIN_MARKER and END_MARKER:
                               one DROP + CREATE TABLE (+ indexes) per
                               schema_map.json table, then the
                               attribute_identifiers rows
  schema/column_conventions.json
                               the entries marked "source": "schemas": the unit
                               conventions of the unit-bearing generated columns
                               and attribute-channel properties

Everything outside the marked region of schema.sql, and every convention entry
without the "source" marker, is hand-written and left untouched.

Inputs (stdlib only):
  --schemas-path               SiennaSchemas checkout root (default ../SiennaSchemas)
  schema/schema_map.json       table -> components, plus `excluded`: every other
                               schema file, with the reason it has no table
  schema/sql_codegen_map.json  per-table disposition of every component property

Closed world: generation fails, listing every problem at once, when
  - a schema file with `properties` is neither mapped nor excluded
  - a component property has no disposition in sql_codegen_map.json
  - a disposition names a property that the schemas no longer define
  - a unit arm's quantity kind is neither its x-quantity nor the one kind
    units.json allows for the unit
  - a pu convention has no base column to resolve against
  - an attributes name has more than one quantity kind or unit per arm, or is
    registered by one component and unitless on another
  - a hand-written convention duplicates a derived one, or names a column a
    generated table no longer has

A new schema release therefore fails here until each new property is assigned
to exactly one of:
  columns            a column; the value is an override object (may be empty)
  attribute_channel  a row in the generic `attributes` table
  decomposed         split into DB-only columns (listed in `columns` with "sql");
                     the value maps each column to its JSON path in the property
  skip               not persisted

Column overrides (all optional):
  column      DB column name (default: the property name)
  sql         raw declaration for a DB-only column with no schema property
  references  foreign-key target, e.g. "balancing_topologies (id) ON DELETE CASCADE"
  not_null    force NOT NULL (true) or NULL (false)
  default     replace the schema default (null removes it)
  checks      extra CHECK expressions
  comment     a trailing SQL comment
  unit_base   {"base_power_ref": ..., "base_voltage_ref": ...} for pu conventions
              (default: the same-row base columns of the quantity kind)
  hand_units  true: hand-written conventions own this column's units

Table keys besides the dispositions: comment (lines above CREATE TABLE),
constraints (table-level), indexes (full CREATE INDEX statements), and
attribute_units ({prop: {"unit", "quantity_kind"}} for an attribute-channel
property the schemas leave unannotated).

Derived rules:
  type        integer -> INTEGER, number -> REAL, string/enum -> TEXT,
              boolean -> INTEGER CHECK (0, 1), anything else -> TEXT CHECK json_valid
  NOT NULL    the property is on every mapped component, is required or has a
              default on each, and its type does not admit null
  CHECK       enum values, minimum/maximum bounds, and a oneOf discriminator
  DEFAULT     the schema default, never for base_power
  tables      STRICT
  attributes  a unitless number is Dimensionless; a unitless object or array
              gets an attribute_identifiers row per owning component

Modes:
  (none)   rewrite both outputs
  --check  exit non-zero if either output differs from a fresh generation
"""

import argparse
import functools
import json
import os
import re
import sys

from _common import load_json, sql_literal
from generate_unit_registry import UNIT_BASIS_RULES

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMAS_PATH = os.path.normpath(os.path.join(REPO_ROOT, "..", "SiennaSchemas"))
SCHEMA_MAP = os.path.join(REPO_ROOT, "schema", "schema_map.json")
CODEGEN_MAP = os.path.join(REPO_ROOT, "schema", "sql_codegen_map.json")
SCHEMA_SQL = os.path.join(REPO_ROOT, "schema", "schema.sql")
CONVENTIONS = os.path.join(REPO_ROOT, "schema", "column_conventions.json")

BEGIN_MARKER = "-- BEGIN GENERATED COMPONENT TABLES"
END_MARKER = "-- END GENERATED COMPONENT TABLES"
REGION_HEADER = """\
-- Do not edit this region. scripts/generate_sql_schema.py writes it from the
-- SiennaSchemas components (schema/schema_map.json) and the per-table
-- dispositions (schema/sql_codegen_map.json). Edit those and regenerate.
"""

# Top-level SiennaSchemas directories that hold no component schemas.
NON_SCHEMA_DIRS = {"docs", "scripts", "tests", "node_modules"}

DISPOSITIONS = ("columns", "attribute_channel", "decomposed", "skip")

# The pu base columns of each quantity kind. A pu convention gets these same-row
# columns unless the column overrides them with unit_base.
PU_BASES = {
    rule["quantity_kind"]: tuple(sorted(set(re.findall(r"base_\w+", rule["base_expression"]))))
    for rule in UNIT_BASIS_RULES
}


class GenerationError(Exception):
    def __init__(self, problems):
        super().__init__("\n".join(problems))
        self.problems = problems


@functools.lru_cache(maxsize=None)
def schema_doc(schemas_root, rel_path):
    return load_json(os.path.join(schemas_root, os.path.normpath(rel_path)))


def resolve_ref(schemas_root, ref, current_rel_file):
    """Resolves a relative-file $ref the way bundle_specs.py does."""
    file_part, _, frag = ref.partition("#")
    target_rel = current_rel_file
    if file_part:
        target_rel = os.path.normpath(os.path.join(os.path.dirname(current_rel_file), file_part))
    node = schema_doc(schemas_root, target_rel)
    for part in [p for p in frag.split("/") if p]:
        node = node[part]
    return node, target_rel


def sql_type_for(prop, schemas_root, rel_file):
    """Returns (json_kind, enum_values, type_nullable).

    json_kind is one of integer/number/boolean/string/json.
    """
    if "$ref" in prop:
        target, _ = resolve_ref(schemas_root, prop["$ref"], rel_file)
        if "enum" in target:
            return "string", list(target["enum"]), False
        return "json", None, False
    if "enum" in prop:
        return "string", list(prop["enum"]), False
    jstype = prop.get("type")
    nullable = False
    if isinstance(jstype, list):
        nullable = "null" in jstype
        non_null = [t for t in jstype if t != "null"]
        jstype = non_null[0] if len(non_null) == 1 else None
    if jstype in ("integer", "number", "boolean", "string"):
        return jstype, None, nullable
    return "json", None, nullable


def bound_checks(column, prop):
    checks = []
    for key, op in (("minimum", ">="), ("exclusiveMinimum", ">"),
                    ("maximum", "<="), ("exclusiveMaximum", "<")):
        if key in prop:
            checks.append(f"{column} {op} {json.dumps(prop[key])}")
    return checks


def discriminator_check(column, prop):
    disc = prop.get("discriminator")
    if not disc or "mapping" not in disc:
        return None
    values = ", ".join(sql_literal(v) for v in sorted(disc["mapping"]))
    return f"json_extract({column}, '$.{disc['propertyName']}') IN ({values})"


# --------------------------------------------------------------------------- inventory


def schema_files(schemas_root):
    """Every SiennaSchemas file that defines a component (has `properties`)."""
    found = []
    for top in sorted(os.listdir(schemas_root)):
        path = os.path.join(schemas_root, top)
        if top.startswith(".") or top in NON_SCHEMA_DIRS or not os.path.isdir(path):
            continue
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames.sort()
            for name in sorted(filenames):
                if not name.endswith(".json"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, name), schemas_root)
                if "properties" in load_json(os.path.join(schemas_root, rel)):
                    found.append(rel.replace(os.sep, "/"))
    return found


def inventory_problems(schemas_root, schema_map):
    mapped = {c["file"] for comps in schema_map["tables"].values() for c in comps}
    excluded = schema_map.get("excluded", {})
    problems = []
    for rel in sorted(mapped):
        if not os.path.exists(os.path.join(schemas_root, rel)):
            problems.append(f"schema_map.json maps {rel}, which does not exist in the schemas")
    present = schema_files(schemas_root)
    for rel in present:
        if rel not in mapped and not any(rel.startswith(prefix) for prefix in excluded):
            problems.append(
                f"{rel} is neither mapped to a table nor excluded in schema_map.json"
            )
    for prefix in sorted(excluded):
        if not any(rel.startswith(prefix) for rel in present):
            problems.append(f"schema_map.json excludes {prefix}, which matches no schema file")
    return problems


# --------------------------------------------------------------------------- tables


def merge_components(components, schemas_root):
    """Union of the components' properties, in first-seen order.

    Returns {prop: {"node", "file", "owners", "required_all"}}.
    """
    merged = {}
    for comp in components:
        doc = schema_doc(schemas_root, comp["file"])
        required = set(doc.get("required", []))
        for pname, pnode in doc.get("properties", {}).items():
            entry = merged.setdefault(
                pname, {"node": pnode, "file": comp["file"], "owners": [], "required_all": True}
            )
            entry["owners"].append(comp["component"])
            if pname not in required and pnode.get("default") is None:
                entry["required_all"] = False
    for entry in merged.values():
        if len(entry["owners"]) < len(components):
            entry["required_all"] = False
    return merged


def disposition_problems(table, merged, cfg):
    problems = []
    columns = cfg.get("columns", {})
    schema_columns = {p for p, o in columns.items() if "sql" not in o}
    assigned = {
        "columns": schema_columns,
        "attribute_channel": set(cfg.get("attribute_channel", [])),
        "decomposed": set(cfg.get("decomposed", {})),
        "skip": set(cfg.get("skip", [])),
    }
    seen = {}
    for kind in DISPOSITIONS:
        for prop in assigned[kind]:
            if prop in seen:
                problems.append(f"{table}.{prop} is in both {seen[prop]} and {kind}")
            seen[prop] = kind
    for prop in merged:
        if prop not in seen:
            owners = ", ".join(merged[prop]["owners"])
            problems.append(
                f"{table}.{prop} ({owners}) has no disposition in sql_codegen_map.json; "
                f"add it to one of {', '.join(DISPOSITIONS)}"
            )
    for prop, kind in sorted(seen.items()):
        if prop not in merged:
            problems.append(
                f"{table}.{prop} is in {kind} but no mapped component defines it"
            )
    for prop in cfg.get("attribute_units", {}):
        if prop not in assigned["attribute_channel"]:
            problems.append(f"{table}.{prop} has attribute_units but is not in attribute_channel")
    for prop, targets in cfg.get("decomposed", {}).items():
        for target in targets:
            if "sql" not in columns.get(target, {}):
                problems.append(
                    f"{table}.{prop} decomposes into {target}, which is not a DB-only column"
                )
    return problems


def column_decl(prop, entry, override, schemas_root, renames):
    """Return (column name, declaration line without separator)."""
    column = renames.get(prop, prop)
    if prop == "id":
        return column, "id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE"
    node = entry["node"]
    kind, enum_values, type_nullable = sql_type_for(node, schemas_root, entry["file"])
    sql_type = {"integer": "INTEGER", "number": "REAL", "boolean": "INTEGER",
                "string": "TEXT", "json": "TEXT"}[kind]
    not_null = override.get("not_null", entry["required_all"] and not type_nullable)
    parts = [column, sql_type, "NOT NULL" if not_null else "NULL"]
    if prop == "name":
        parts.append("UNIQUE")
    default = override["default"] if "default" in override else node.get("default")
    # A row must state its own base: a silent 100 MVA default makes every pu
    # value on the row wrong without an error.
    if prop == "base_power":
        default = None
    if default is not None:
        parts.append(f"DEFAULT {sql_literal(default)}")
    checks = []
    if kind == "boolean":
        checks.append(f"{column} IN (0, 1)")
    if kind == "json":
        checks.append(f"json_valid({column})")
    if enum_values is not None:
        checks.append(f"{column} IN ({', '.join(sql_literal(v) for v in enum_values)})")
    checks.extend(bound_checks(column, node))
    disc = discriminator_check(column, node)
    if disc:
        checks.append(disc)
    checks.extend(override.get("checks", []))
    parts.extend(f"CHECK ({c})" for c in checks)
    if "references" in override:
        parts.append(f"REFERENCES {override['references']}")
    return column, " ".join(parts)


def quantity_of(node, units_index):
    """The node's x-quantity, else the one quantity kind that allows all its units."""
    if "x-quantity" in node:
        return node["x-quantity"]
    units = set()
    if "x-unit" in node:
        units.add(node["x-unit"])
    units.update(node.get("x-units", {}).values())
    kinds = None
    for unit in units:
        allowed = units_index.get(unit, set())
        kinds = allowed if kinds is None else kinds & allowed
    if kinds and len(kinds) == 1:
        return next(iter(kinds))
    return None


def arm_quantity(node, unit, units_index):
    """x-quantity when it allows this arm's unit, else the one kind allowing the
    unit, else the node's kind. A single x-quantity on a field whose arms are
    different quantities (m3 / MWh / m) applies only to the arms it allows."""
    kinds = units_index.get(unit, set())
    if node.get("x-quantity") in kinds:
        return node["x-quantity"]
    if len(kinds) == 1:
        return next(iter(kinds))
    return quantity_of(node, units_index)


def unit_arms(node, renames):
    """One dict per unit arm: unit plus any discriminator column/value pairs."""
    if "x-units" not in node:
        return [{"unit": node["x-unit"]}]
    disc = renames.get(node["x-unit-discriminator"], node["x-unit-discriminator"])
    return [{"discriminator_column": disc, "discriminator_value": value, "unit": unit}
            for value, unit in sorted(node["x-units"].items())]


def has_unit(node):
    return "x-unit" in node or "x-units" in node


def short_description(node):
    return node.get("description", "").split(" Units:")[0].strip() or None


def convention(table, column, quantity, arm, node):
    conv = {"table": table, "column": column, "quantity_kind": quantity}
    conv.update(arm)
    description = short_description(node)
    if description:
        conv["description"] = description
    return conv


def column_conventions(table, prop, entry, override, renames, columns_present, units_index):
    """Derive unit_conventions entries for one generated column."""
    node = entry["node"]
    column = renames.get(prop, prop)
    if override.get("hand_units") or not has_unit(node):
        return [], []
    problems = []
    out = []
    for arm in unit_arms(node, renames):
        quantity = arm_quantity(node, arm["unit"], units_index)
        if quantity is None:
            problems.append(f"{table}.{column}: {prop} has no x-quantity, and unit "
                            f"{arm['unit']} does not identify one quantity kind")
            continue
        conv = convention(table, column, quantity, arm, node)
        if arm["unit"] == "pu":
            bases = override.get("unit_base")
            if bases is None:
                if "x-unit-base" in node:
                    defaults = (node["x-unit-base"],)
                else:
                    defaults = PU_BASES.get(quantity, ())
                bases = {f"{b}_ref": b for b in defaults}
            missing = [ref for ref in bases.values()
                       if "->" not in ref and ref not in columns_present]
            if not bases or missing:
                problems.append(
                    f"{table}.{column}: pu {quantity} has no base column "
                    f"({missing or 'no default for this quantity'}); set unit_base"
                )
            conv.update(sorted(bases.items()))
        conv["source"] = "schemas"
        out.append(conv)
    return out, problems


def attribute_rows(prop, entry, schemas_root, units_index, unit_override=None):
    """Return (conventions, identifier owners, problems) for an attribute-channel property.

    The attributes table keys conventions by name alone, so every component
    that routes a name there must agree on its quantity kind. unit_override is
    the table's attribute_units entry: the unit of a property the schemas leave
    unannotated.
    """
    node = entry["node"]
    if has_unit(node):
        convs, problems = [], []
        for arm in unit_arms(node, {}):
            quantity = arm_quantity(node, arm["unit"], units_index)
            if quantity is None:
                problems.append(f"attributes.{prop}: no x-quantity, and unit "
                                f"{arm['unit']} does not identify one quantity kind")
            else:
                convs.append(convention("attributes", prop, quantity, arm, node))
        return convs, [], problems
    if unit_override is not None:
        arm = {"unit": unit_override["unit"]}
        return [convention("attributes", prop, unit_override["quantity_kind"], arm, node)], [], []
    kind = sql_type_for(node, schemas_root, entry["file"])[0]
    if kind in ("integer", "number"):
        return [convention("attributes", prop, "Dimensionless", {"unit": "1"}, node)], [], []
    if kind == "json":
        return [], entry["owners"], []
    return [], [], []


def emit_table(table, components, cfg, schemas_root, units_index):
    merged = merge_components(components, schemas_root)
    problems = disposition_problems(table, merged, cfg)
    if problems:
        return None, [], [], set(), problems
    columns = cfg.get("columns", {})
    renames = {p: o["column"] for p, o in columns.items() if "column" in o}

    lines = []
    for text in cfg.get("comment", []):
        lines.append(f"-- {text}" if text else "--")
    lines.append(f"-- Components: {', '.join(c['component'] for c in components)}")
    for label, key in (("Attributes", "attribute_channel"), ("Not stored", "skip")):
        if cfg.get(key):
            lines.append(f"-- {label}: {', '.join(cfg[key])}")
    for prop, targets in cfg.get("decomposed", {}).items():
        lines.append(f"-- {prop} is stored as: {', '.join(targets)}")
    lines.append(f"DROP TABLE IF EXISTS {table};")
    lines.append(f"CREATE TABLE {table} (")

    body = []
    present = set()
    conventions = []
    for prop, override in columns.items():
        if "sql" in override:
            body.append((f"{prop} {override['sql']}", override.get("comment")))
            present.add(prop)
            continue
        column, decl = column_decl(prop, merged[prop], override, schemas_root, renames)
        present.add(column)
        body.append((decl, override.get("comment")))
    for prop, override in columns.items():
        if "sql" not in override:
            derived, conv_problems = column_conventions(
                table, prop, merged[prop], override, renames, present, units_index
            )
            conventions.extend(derived)
            problems.extend(conv_problems)
    # Per component, not the merged node: two components may route one name with
    # different shapes (HydroTurbine's efficiency is a number, HydroPumpTurbine's
    # an object).
    attributes = []
    unit_overrides = cfg.get("attribute_units", {})
    for prop in cfg.get("attribute_channel", []):
        for comp in components:
            node = schema_doc(schemas_root, comp["file"])["properties"].get(prop)
            if node is None:
                continue
            entry = {"node": node, "file": comp["file"], "owners": [comp["component"]]}
            convs, owners, attr_problems = attribute_rows(
                prop, entry, schemas_root, units_index, unit_overrides.get(prop)
            )
            attributes.append((prop, convs, owners))
            problems.extend(attr_problems)
    body.extend((c, None) for c in cfg.get("constraints", []))

    for i, (decl, comment) in enumerate(body):
        sep = "," if i < len(body) - 1 else ""
        lines.append(f"    {decl}{sep}" + (f" -- {comment}" if comment else ""))
    lines.append(") STRICT;")
    lines.extend(f"{index};" for index in cfg.get("indexes", []))
    return "\n".join(lines) + "\n", conventions, attributes, present, problems


def load_units_index(schemas_path):
    """{unit: {quantity kinds that allow it}} from Core/units.json."""
    index = {}
    for row in load_json(os.path.join(schemas_path, "Core", "units.json"))["allowed_units"]:
        index.setdefault(row["unit"], set()).add(row["quantity_kind"])
    return index


def merge_attribute_rows(attributes):
    """Combine every table's attribute conventions and identifier rows.

    Returns (conventions, identifier (type, name) pairs, problems).
    """
    by_arm = {}
    quantities = {}
    identifiers = set()
    problems = []
    for table, prop, convs, owners in attributes:
        identifiers.update((owner, prop) for owner in owners)
        for conv in convs:
            quantities.setdefault(prop, {}).setdefault(conv["quantity_kind"], []).append(table)
            key = (prop, conv.get("discriminator_value"), conv.get("discriminator_value_2"))
            seen = by_arm.setdefault(key, (table, conv))
            if seen[1]["unit"] != conv["unit"]:
                problems.append(
                    f"attributes.{prop}: {seen[0]} stores {seen[1]['unit']} and {table} stores "
                    f"{conv['unit']} for the same unit arm"
                )
    # The unit trigger checks a registered name before the identifier exemption,
    # so an exempt row under a registered name would always be rejected.
    for owner, prop in sorted(identifiers):
        if prop in quantities:
            problems.append(
                f"attributes.{prop}: {owner} stores it with no unit, but another component "
                "registers a unit for the name; set attribute_units for it"
            )
    for prop, kinds in sorted(quantities.items()):
        if len(kinds) > 1:
            detail = "; ".join(f"{k} in {', '.join(sorted(set(t)))}" for k, t in sorted(kinds.items()))
            problems.append(f"attributes.{prop} has more than one quantity kind: {detail}")
    conventions = []
    for _, conv in by_arm.values():
        conventions.append({**conv, "source": "schemas"})
    return conventions, sorted(identifiers), problems


def identifiers_sql(identifiers):
    if not identifiers:
        return ""
    rows = ",\n".join(f"    ({sql_literal(t)}, {sql_literal(n)})" for t, n in identifiers)
    return (
        "-- Attribute-channel properties with no unit and a structured value\n"
        "-- (references, curves): exempt from the attributes unit rule.\n"
        f"INSERT INTO attribute_identifiers (TYPE, name)\nVALUES\n{rows};\n"
    )


def generate(schemas_path):
    """Return (region text, derived conventions, {table: columns}). Raises GenerationError."""
    units_index = load_units_index(schemas_path)
    schema_map = load_json(SCHEMA_MAP)
    codegen = load_json(CODEGEN_MAP)["tables"]
    problems = inventory_problems(schemas_path, schema_map)
    if problems:
        raise GenerationError(problems)
    for table in sorted(set(codegen) - set(schema_map["tables"])):
        problems.append(f"sql_codegen_map.json configures {table}, which schema_map.json does not map")

    blocks = [BEGIN_MARKER + "\n", REGION_HEADER]
    conventions = []
    attributes = []
    table_columns = {}
    for table, components in schema_map["tables"].items():
        ddl, convs, attrs, present, table_problems = emit_table(
            table, components, codegen.get(table, {}), schemas_path, units_index
        )
        problems.extend(table_problems)
        if ddl:
            blocks.append("\n" + ddl)
        conventions.extend(convs)
        table_columns[table] = present
        attributes.extend((table, prop, c, o) for prop, c, o in attrs)
    attr_conventions, identifiers, attr_problems = merge_attribute_rows(attributes)
    problems.extend(attr_problems)
    if problems:
        raise GenerationError(problems)
    conventions.extend(attr_conventions)
    blocks.append("\n" + identifiers_sql(identifiers))
    blocks.append("\n" + END_MARKER)
    return "".join(blocks), conventions, table_columns


# --------------------------------------------------------------------------- outputs


def splice_schema_sql(current, region):
    begin = current.find(BEGIN_MARKER)
    end = current.find(END_MARKER)
    if begin < 0 or end < begin:
        raise GenerationError([f"{SCHEMA_SQL} has no {BEGIN_MARKER} ... {END_MARKER} region"])
    return current[:begin] + region + current[end + len(END_MARKER):]


def conventions_key(entry):
    return tuple(str(entry.get(k) or "") for k in (
        "table", "column", "discriminator_value", "discriminator_value_2", "quantity_kind"))


def merge_conventions(current, derived, table_columns):
    """Replace the "source": "schemas" entries; keep hand entries.

    A hand entry for a column the schemas now annotate is a second owner for
    the same convention, and a hand entry for a generated table names a column
    that must still exist (a JSON path names its base column). Both fail
    instead of being dropped silently.
    """
    hand = [e for e in current["conventions"] if e.get("source") != "schemas"]
    derived_columns = {(e["table"], e["column"]) for e in derived}
    problems = set()
    for e in hand:
        name = f"{e['table']}.{e['column']}"
        if (e["table"], e["column"]) in derived_columns:
            problems.add(f"column_conventions.json has a hand-written entry for {name}, "
                         "which the schemas annotate; delete the hand entry")
        elif (e["table"] in table_columns
              and e["column"].split(".")[0] not in table_columns[e["table"]]):
            problems.add(f"column_conventions.json has a hand-written entry for {name}, "
                         "which is not a column of the generated table")
    if problems:
        raise GenerationError(sorted(problems))
    return {**current, "conventions": hand + sorted(derived, key=conventions_key)}


def render_conventions(document):
    """One convention per line, matching the file's reviewable layout."""
    head = {k: v for k, v in document.items() if k != "conventions"}
    lines = ["{"]
    for key, value in head.items():
        lines.append(f"  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)},")
    lines.append('  "conventions": [')
    rows = [json.dumps(e, ensure_ascii=False) for e in document["conventions"]]
    lines.append(",\n".join(f"    {r}" for r in rows))
    lines.append("  ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


def outputs(schemas_path):
    region, derived, table_columns = generate(schemas_path)
    with open(SCHEMA_SQL, encoding="utf-8") as f:
        schema_sql = splice_schema_sql(f.read(), region)
    conventions = render_conventions(merge_conventions(load_json(CONVENTIONS), derived, table_columns))
    return {SCHEMA_SQL: schema_sql, CONVENTIONS: conventions}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--schemas-path", default=DEFAULT_SCHEMAS_PATH)
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero if schema.sql or column_conventions.json is stale")
    args = parser.parse_args()

    try:
        fresh = outputs(args.schemas_path)
    except GenerationError as err:
        print(f"ERROR: {len(err.problems)} problem(s) between the schemas and the DB:",
              file=sys.stderr)
        for problem in err.problems:
            print(f"  - {problem}", file=sys.stderr)
        sys.exit(1)

    stale = []
    for path, content in fresh.items():
        with open(path, encoding="utf-8") as f:
            current = f.read()
        if current == content:
            continue
        if args.check:
            stale.append(path)
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            print(f"Wrote {path}")
    if stale:
        for path in stale:
            print(f"STALE: {path} differs from a fresh generation. "
                  "Run scripts/generate_sql_schema.py and commit the result.")
        sys.exit(1)
    if args.check:
        print("OK: schema.sql and column_conventions.json match the schemas.")


if __name__ == "__main__":
    main()
