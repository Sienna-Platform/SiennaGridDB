"""Insert SDK objects (as JSON-shaped dicts) using the manifest's SQL."""

import sqlite3
from contextlib import contextmanager

from .db import seed_vocabulary
from .encode import EncodeError, canonical_json, encode, value_at
from .errors import GapValueError, InsertError, UnsupportedComponentError, describe
from .manifest import load_manifest
from .report import InsertReport

SAVEPOINT = "sienna_griddb_tools_insert"


def as_json_data(obj):
    """SDK model -> plain dict; plain mappings pass through."""
    dump = getattr(obj, "model_dump", None)
    if dump is not None:
        return dump(mode="json")
    return obj


@contextmanager
def _savepoint(conn):
    conn.execute(f"SAVEPOINT {SAVEPOINT}")
    try:
        yield
    except BaseException:
        conn.execute(f"ROLLBACK TO {SAVEPOINT}")
        conn.execute(f"RELEASE {SAVEPOINT}")
        raise
    conn.execute(f"RELEASE {SAVEPOINT}")


def _execute(conn, sql, params, what):
    try:
        conn.execute(sql, params)
    except sqlite3.Error as exc:
        raise InsertError(f"{what}: {exc}") from exc


def _params(bindings, obj, what):
    try:
        return [encode(b["encode"], value_at(obj, b["path"])) for b in bindings]
    except EncodeError as exc:
        raise InsertError(f"{what}: {exc}") from exc


def _skip(report, strict, type_name, field_name, what):
    if strict:
        raise GapValueError(f"{what}: field {field_name!r} has no column in GridDB")
    report.add_skipped(type_name, field_name)


def _unsupported(report, strict, key, n, reason):
    if strict:
        raise UnsupportedComponentError(f"{key} ({n} rows): {reason}")
    report.add_unsupported(key, n)


def _write_row(conn, plan, obj, report, strict):
    what = describe(plan.type_name, obj)
    _execute(conn, plan.row_sql, _params(plan.bindings, obj, what), what)
    attribute_sql = load_manifest().attribute_sql
    for attribute in plan.attributes:
        value = obj.get(attribute["field"])
        if value is None:
            continue
        if attribute["unit"] is None and not isinstance(value, (str, bool)):
            _skip(report, strict, plan.type_name, attribute["field"], what)
            continue
        _execute(
            conn,
            attribute_sql,
            [
                obj["id"],
                plan.type_name,
                attribute["field"],
                canonical_json(value),
                attribute["unit"],
                attribute["quantity_kind"],
            ],
            what,
        )
    for gap in plan.gaps:
        if obj.get(gap) is not None:
            _skip(report, strict, plan.type_name, gap, what)
    unknown = [k for k in obj if k not in plan.known_fields and obj[k] is not None]
    for key in sorted(unknown):
        _skip(report, strict, plan.type_name, key, what)
    report.add_inserted(plan.type_name)


def _write_entity(conn, plan, obj):
    what = describe(plan.type_name, obj)
    _execute(conn, plan.entity_sql, _params(plan.entity_bindings, obj, what), what)


def _plan_for(type_name, n, report, strict):
    manifest = load_manifest()
    if type_name in manifest.components:
        return manifest.components[type_name]
    reason = manifest.unsupported_components.get(type_name, "not a GridDB component type")
    _unsupported(report, strict, type_name, n, reason)
    return None


def insert_components(conn, type_name, objs, *, strict=False):
    objs = [as_json_data(o) for o in objs]
    report = InsertReport()
    plan = _plan_for(type_name, len(objs), report, strict)
    if plan is None:
        return report
    with _savepoint(conn):
        for obj in objs:
            _write_entity(conn, plan, obj)
            _write_row(conn, plan, obj, report, strict)
    return report


def insert_component(conn, type_name, obj, *, strict=False):
    return insert_components(conn, type_name, [obj], strict=strict)


def insert_model(conn, model, *, strict=False):
    return insert_component(conn, type(model).__name__, model, strict=strict)


def _attribute_types(doc):
    types = {}
    for assoc in doc.get("supplemental_attribute_associations") or []:
        types[assoc["attribute_id"]] = assoc["attribute_type"]
    return types


def insert_document(conn, doc, *, strict=False):
    doc = as_json_data(doc)
    manifest = load_manifest()
    report = InsertReport()
    components = doc.get("components") or {}
    plans = []
    for type_name in sorted(components):
        objs = [as_json_data(o) for o in components[type_name]]
        plan = _plan_for(type_name, len(objs), report, strict)
        if plan is not None:
            plans.append((plan, objs))
    plans.sort(key=lambda p: (p[0].rank, p[0].type_name))
    for section, reason in sorted(manifest.unsupported_sections.items()):
        rows = doc.get(section) or []
        if len(rows) > 0:
            _unsupported(report, strict, section, len(rows), reason)

    attr_types = _attribute_types(doc)
    supplemental = manifest.supplemental
    with _savepoint(conn):
        seed_vocabulary(conn)
        for plan, objs in plans:
            for obj in objs:
                _write_entity(conn, plan, obj)
        routed = []
        for attr in doc.get("supplemental_attributes") or []:
            if attr["id"] not in attr_types:
                raise InsertError(
                    f"supplemental attribute id={attr['id']}: no association names its type"
                )
            attr_type = attr_types[attr["id"]]
            table = "supplemental_attributes"
            if attr_type in supplemental["plant_types"]:
                table = "plants"
            what = f"{attr_type} id={attr['id']}"
            _execute(
                conn,
                "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, ?, ?)",
                [attr["id"], table, attr_type],
                what,
            )
            routed.append((table, attr_type, attr, what))
        for plan, objs in plans:
            for obj in objs:
                _write_row(conn, plan, obj, report, strict)
        for table, attr_type, attr, what in routed:
            if table == "plants":
                value = {k: v for k, v in attr.items() if k not in ("id", "name")}
                params = [attr["id"], attr["name"], attr_type, canonical_json(value)]
                _execute(conn, supplemental["plant_sql"], params, what)
            else:
                value = {k: v for k, v in attr.items() if k != "id"}
                params = [attr["id"], attr_type, canonical_json(value)]
                _execute(conn, supplemental["attribute_sql"], params, what)
            report.add_inserted(table)
        for section in manifest.associations:
            name = section["section"]
            for row in doc.get(name) or []:
                what = f"{name} row {row}"
                _execute(
                    conn, section["row_sql"], _params(section["bindings"], row, what), what
                )
                report.add_inserted(name)
    return report
