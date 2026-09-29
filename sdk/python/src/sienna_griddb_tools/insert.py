"""Insert SDK objects (as JSON-shaped dicts) using the manifest's SQL."""

import json
import os
import sqlite3
from contextlib import contextmanager

from .db import seed_vocabulary
from .encode import EncodeError, canonical_json, encode, is_int, value_at
from .errors import GapValueError, InsertError, UnsupportedComponentError, describe
from .manifest import load_manifest
from .report import InsertReport
from .time_series import element_dtype, insert_time_series, reader_missing

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


def _skip(report, strict, type_name, field_name, what, reason="has no column in GridDB"):
    if strict:
        raise GapValueError(f"{what}: field {field_name!r} {reason}")
    report.add_skipped(type_name, field_name)


def _unsupported(report, strict, key, n, reason):
    if strict:
        raise UnsupportedComponentError(f"{key} ({n} rows): {reason}")
    report.add_unsupported(key, n)


def attribute_unit(spec, obj):
    """(unit, quantity_kind) of one attribute row, following the discriminator arms of
    its unit spec; None when a discriminating field's value has no arm."""
    while "discriminator" in spec:
        value = obj.get(spec["discriminator"])
        if value is None:
            value = spec.get("default")
        key = value if isinstance(value, str) else canonical_json(value)
        spec = spec["arms"].get(key)
        if spec is None:
            return None
    return spec.get("unit"), spec.get("quantity_kind")


def _write_row(conn, plan, obj, report, strict):
    what = describe(plan.type_name, obj)
    _execute(conn, plan.row_sql, _params(plan.bindings, obj, what), what)
    attribute_sql = load_manifest().attribute_sql
    for attribute in plan.attributes:
        value = obj.get(attribute["field"])
        if value is None:
            continue
        if attribute.get("unit_free") and not isinstance(value, (str, bool)):
            reason = "needs a string or boolean value"
            _skip(report, strict, plan.type_name, attribute["field"], what, reason)
            continue
        unit = attribute_unit(attribute, obj)
        if unit is None:
            reason = "has no unit for its discriminator value"
            _skip(report, strict, plan.type_name, attribute["field"], what, reason)
            continue
        params = [obj["id"], plan.type_name, attribute["field"], canonical_json(value), *unit]
        _execute(conn, attribute_sql, params, what)
    for gap in plan.gaps:
        if obj.get(gap) is not None:
            _skip(report, strict, plan.type_name, gap, what)
    unknown = [k for k in obj if k not in plan.known_fields and obj[k] is not None]
    for key in sorted(unknown):
        _skip(report, strict, plan.type_name, key, what)
    report.add_inserted(plan.type_name)


def _require_object(entry, what):
    """Every document entry is a JSON object; anything else is schema-invalid input."""
    if not isinstance(entry, dict):
        raise InsertError(f"{what} {entry!r}: not an object")


def _section_rows(doc, name):
    """A section's rows; JSON null reads as empty."""
    rows = doc.get(name) or []
    for row in rows:
        _require_object(row, f"{name} row")
    return rows


def _write_entity(conn, plan, obj):
    _require_object(obj, f"{plan.type_name} entry")
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
    for assoc in _section_rows(doc, "supplemental_attribute_associations"):
        types[assoc["attribute_id"]] = assoc["attribute_type"]
    return types


def _names_unsupported(row, references, ids):
    """Whether a reference names a component the insert does not write; ids follow
    the int encoder's rule, so any other value reaches the encoder and fails there."""
    return any(is_int(v) and v in ids for v in (value_at(row, r) for r in references))


def _time_series_plan(doc, sidecar, report, strict, no_sidecar):
    """The association rows to insert, after reporting what cannot be stored."""
    plan = load_manifest().time_series
    rows = doc.get(plan["section"]) or []
    if not rows:
        return []
    missing = no_sidecar if sidecar is None else reader_missing()
    if missing is not None:
        _unsupported(report, strict, plan["section"], len(rows), missing)
        return []
    unsupported = plan["unsupported_types"]
    counts = {}
    for row in rows:
        if row.get("time_series_type") in unsupported:
            counts[row["time_series_type"]] = counts.get(row["time_series_type"], 0) + 1
    for series_type, n in sorted(counts.items()):
        _unsupported(report, strict, series_type, n, unsupported[series_type])
    components = load_manifest().components
    stored, orphans, dtypes = [], {}, {}
    for row in rows:
        if row.get("time_series_type") in unsupported:
            continue
        owner = row.get("owner_type")
        if row.get("owner_category") == "Component" and owner not in components:
            orphans[owner] = orphans.get(owner, 0) + 1
        elif element_dtype(row.get("element_type")) in plan["unsupported_dtypes"]:
            dtypes[row["element_type"]] = dtypes.get(row["element_type"], 0) + 1
        else:
            stored.append(row)
    if orphans:
        reason = f"owned by types GridDB does not store: {', '.join(sorted(orphans))}"
        _unsupported(report, strict, plan["section"], sum(orphans.values()), reason)
    for element_type, n in sorted(dtypes.items()):
        why = plan["unsupported_dtypes"][element_dtype(element_type)]
        reason = f"element_type {element_type}: {why}"
        _unsupported(report, strict, plan["section"], n, reason)
    return stored


def insert_document(conn, doc, *, strict=False, time_series=None):
    """Insert a whole SystemDocument in one savepoint.

    doc is a parsed document, an SDK model, or the path of a document's JSON.
    time_series is the HDF5 sidecar holding its arrays; by default a path doc's
    time_series_storage_file, resolved beside it (reported unsupported when that
    file does not exist). It is only ever read, and an explicit one must exist.
    """
    if time_series is not None and not os.path.isfile(time_series):
        raise InsertError(f"time series sidecar {time_series} does not exist")
    no_sidecar = "no time series sidecar given"
    if isinstance(doc, (str, os.PathLike)):
        with open(doc, encoding="utf-8") as handle:
            loaded = json.load(handle)
        stored = loaded.get("time_series_storage_file")
        if time_series is None and stored:
            default = os.path.join(os.path.dirname(os.path.abspath(doc)), stored)
            if os.path.isfile(default):
                time_series = default
            else:
                no_sidecar = f"time series sidecar {default} does not exist"
        doc = loaded
    doc = as_json_data(doc)
    manifest = load_manifest()
    report = InsertReport()
    components = doc.get("components") or {}
    plans = []
    unsupported_ids = set()
    for type_name in sorted(components):
        objs = [as_json_data(o) for o in components[type_name]]
        plan = _plan_for(type_name, len(objs), report, strict)
        if plan is not None:
            plans.append((plan, objs))
        else:
            ids = (o.get("id") for o in objs if isinstance(o, dict))
            unsupported_ids.update(i for i in ids if is_int(i))
    plans.sort(key=lambda p: (p[0].rank, p[0].type_name))
    for section, reason in sorted(manifest.unsupported_sections.items()):
        rows = doc.get(section) or []
        if len(rows) > 0:
            _unsupported(report, strict, section, len(rows), reason)
    series = _time_series_plan(doc, time_series, report, strict, no_sidecar)

    attr_types = _attribute_types(doc)
    supplemental = manifest.supplemental
    with _savepoint(conn):
        seed_vocabulary(conn)
        for plan, objs in plans:
            for obj in objs:
                _write_entity(conn, plan, obj)
        routed = []
        for attr in _section_rows(doc, "supplemental_attributes"):
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
            for row in _section_rows(doc, name):
                # A row naming a component that has no table is not written either.
                if _names_unsupported(row, section["references"], unsupported_ids):
                    report.add_unsupported(name, 1)
                    continue
                what = f"{name} row {row}"
                _execute(
                    conn, section["row_sql"], _params(section["bindings"], row, what), what
                )
                report.add_inserted(name)
        if series:
            insert_time_series(conn, manifest.time_series, series, time_series, report)
    return report
