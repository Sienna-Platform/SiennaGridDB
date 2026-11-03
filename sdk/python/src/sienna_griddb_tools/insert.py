"""Insert SDK objects (as JSON-shaped dicts) using the manifest's SQL."""

import json
import os
import sqlite3
from contextlib import contextmanager

from .db import seed_vocabulary
from .encode import EncodeError, canonical_json, encode, is_int, value_at
from .errors import InsertError, describe
from .manifest import load_manifest
from .report import InsertReport
from .time_series import (
    dangling_references,
    derived_sources,
    export_values,
    insert_associations,
    remap_references,
    series_remap,
    shift_ids,
    require_owner_label,
    values_missing,
)

SAVEPOINT = "sienna_griddb_tools_insert"


def as_json_data(obj):
    """SDK model -> plain dict; plain mappings pass through."""
    dump = getattr(obj, "model_dump", None)
    if dump is not None:
        return dump(mode="json")
    return obj


@contextmanager
def _savepoint(conn):
    _require_foreign_keys(conn)
    conn.execute(f"SAVEPOINT {SAVEPOINT}")
    try:
        yield
    except BaseException:
        conn.execute(f"ROLLBACK TO {SAVEPOINT}")
        conn.execute(f"RELEASE {SAVEPOINT}")
        raise
    conn.execute(f"RELEASE {SAVEPOINT}")


def _require_foreign_keys(conn):
    """The caller's connection may have foreign keys off. The PRAGMA does nothing
    inside an open transaction, so read it back."""
    conn.execute("PRAGMA foreign_keys = ON")
    if conn.execute("PRAGMA foreign_keys").fetchone()[0] != 1:
        raise InsertError("foreign keys are off and cannot be turned on inside an open transaction")


def _required_id(row, key, what):
    """An id the insert needs before it writes a row, by the int encoder's rule."""
    value = row.get(key)
    if value is None:
        raise InsertError(f"{what}: no {key}")
    if not is_int(value):
        raise InsertError(f"{what}: {key}: expected an integer, got {value!r}")
    return int(value)


def _components(doc):
    """{type name: entries}; each entry list must be a JSON array."""
    components = doc.get("components") or {}
    for type_name, objs in components.items():
        if not isinstance(objs, list):
            raise InsertError(f"components.{type_name}: not a list")
    return components


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
        raise InsertError(f"{what}: field {field_name!r} has no column in GridDB")
    report.add_skipped(type_name, field_name)


def _unsupported(report, strict, key, n, reason):
    if strict:
        raise InsertError(f"{key} ({n} rows): {reason}")
    report.add_unsupported(key, n)


def _attribute_arm(attribute, obj):
    """The registered unit for this row: chosen by the row's own value of
    unit_field (e.g. power_units), or the fixed arm "" when there is none."""
    key = obj.get(attribute["unit_field"]) if attribute["unit_field"] else ""
    return attribute["arms"].get(key)


def _write_row(conn, plan, obj, report, strict):
    what = describe(plan["type_name"], obj)
    _execute(conn, plan["row_sql"], _params(plan["bindings"], obj, what), what)
    attribute_sql = load_manifest()["attribute_sql"]
    for attribute in plan["attributes"]:
        value = obj.get(attribute["field"])
        if value is None:
            continue
        arm = _attribute_arm(attribute, obj)
        if arm is None and not attribute["exempt"] and not isinstance(value, (str, bool)):
            _skip(report, strict, plan["type_name"], attribute["field"], what)
            continue
        unit, quantity_kind = (arm["unit"], arm["quantity_kind"]) if arm else (None, None)
        _execute(
            conn,
            attribute_sql,
            [
                obj["id"],
                plan["type_name"],
                attribute["field"],
                canonical_json(value),
                unit,
                quantity_kind,
            ],
            what,
        )
    unknown = [k for k in obj if k not in plan["known_fields"] and obj[k] is not None]
    for key in sorted(unknown):
        _skip(report, strict, plan["type_name"], key, what)
    report.add_inserted(plan["type_name"])


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
    _require_object(obj, f"{plan['type_name']} entry")
    what = describe(plan["type_name"], obj)
    _execute(conn, plan["entity_sql"], _params(plan["bindings"][:1], obj, what), what)


def _plan_for(type_name, n, report, strict):
    components = load_manifest()["components"]
    if type_name in components:
        return components[type_name]
    _unsupported(report, strict, type_name, n, "not a GridDB component type")
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
        types[_required_id(assoc, "attribute_id", "supplemental_attribute_associations row")] = (
            assoc["attribute_type"]
        )
    return types


def _names_unsupported(row, references, ids):
    """Whether a reference names a component the insert does not write; ids follow
    the int encoder's rule, so any other value reaches the encoder and fails there."""
    return any(is_int(v) and v in ids for v in (value_at(row, r) for r in references))


def _time_series_rows(doc, report, strict, unsupported_ids, owners):
    """The association rows to insert, after reporting the ones GridDB cannot store;
    owners maps each id the document holds to its (owner_type, owner_category)."""
    plan = load_manifest()["time_series"]
    rows = _section_rows(doc, plan["section"])
    for row in rows:
        require_owner_label(row, owners)
    unsupported = plan["unsupported_types"]
    counts = {}
    stored = []
    for row in rows:
        series_type = row.get("time_series_type")
        if series_type in unsupported:
            counts[series_type] = counts.get(series_type, 0) + 1
        elif _names_unsupported(row, plan["references"], unsupported_ids):
            report.add_unsupported(plan["section"], 1)
        else:
            stored.append(row)
    for series_type, n in sorted(counts.items()):
        _unsupported(report, strict, series_type, n, unsupported[series_type])
    return stored


def _report_dangling(report, strict, plans, attrs, series):
    """Report payload references that name no association this insert stores; a foreign
    key cannot reach into JSON, so the insert is the only place that sees them."""
    stored_ids = {int(r["association_id"]) for r in series if is_int(r.get("association_id"))}
    rows = [o for _, objs in plans for o in objs] + attrs
    payloads = [(int(o["id"]), o) for o in rows if isinstance(o, dict) and is_int(o.get("id"))]
    dangling = dangling_references(payloads, stored_ids)
    if dangling:
        entity_id, key, ref = min(dangling)
        reason = f"no stored time series association has the id (first: entity {entity_id} {key}={ref})"
        _unsupported(report, strict, "dangling_time_series_references", len(dangling), reason)


def _section_size(value):
    """Rows in a list section; a non-empty object or scalar is one."""
    if isinstance(value, list):
        return len(value)
    return 1 if value else 0


def _require_new_ids(conn, plans, attrs):
    """The insert's entity ids must miss the ones stored, so a portfolio numbers its own
    above its base system's; the UNIQUE failure alone would not say why."""
    ids = [o["id"] for _, objs in plans for o in objs if isinstance(o, dict) and is_int(o.get("id"))]
    ids += [a["id"] for a in attrs if is_int(a.get("id"))]
    taken = conn.execute(
        "SELECT id FROM entities WHERE id IN (SELECT value FROM json_each(?)) ORDER BY id",
        [json.dumps(ids)],
    ).fetchall()
    if taken:
        raise InsertError(
            f"{len(taken)} ids are already in the database (first: {taken[0][0]}): a document's "
            "ids must miss the stored ones, so a portfolio numbers its own above its base system's"
        )


def insert_document(conn, doc, *, strict=False, time_series=None):
    """Insert a whole SystemDocument in one savepoint. time_series is the HDF5
    sidecar holding its arrays (time_series_storage_file); it is only read. The
    sidecar is a time_series_stores row, and its series ids move past every id stored."""
    doc = as_json_data(doc)
    manifest = load_manifest()
    report = InsertReport()
    components = _components(doc)
    ts = manifest["time_series"]
    # Series ids move past every id stored, and references to a derived series name
    # its source, which GridDB stores instead.
    offset = conn.execute(ts["id_offset_sql"]).fetchone()[0]
    remap = series_remap(derived_sources(_section_rows(doc, ts["section"])), offset)
    plans = []
    unsupported_ids = set()
    owners = {}
    for type_name in sorted(components):
        objs = [remap_references(as_json_data(o), remap) for o in components[type_name]]
        ids = [o.get("id") for o in objs if isinstance(o, dict)]
        ids = [i for i in ids if is_int(i)]
        owners.update(dict.fromkeys(ids, (type_name, "Component")))
        plan = _plan_for(type_name, len(objs), report, strict)
        if plan is not None:
            plans.append((plan, objs))
        else:
            unsupported_ids.update(ids)
    plans.sort(key=lambda p: (p[0]["rank"], p[0]["type_name"]))
    for section, reason in sorted(manifest["unsupported_sections"].items()):
        n = _section_size(doc.get(section))
        if n > 0:
            _unsupported(report, strict, section, n, reason)

    attr_types = _attribute_types(doc)
    attrs = remap_references(_section_rows(doc, "supplemental_attributes"), remap)
    for attr in attrs:
        if attr.get("id") in attr_types:
            owners[attr["id"]] = (attr_types[attr["id"]], "SupplementalAttribute")
    series = shift_ids(_time_series_rows(doc, report, strict, unsupported_ids, owners), offset)
    missing = values_missing(time_series) if series else None
    if missing is not None:
        _unsupported(report, strict, "time_series_values", len(series), missing)
    _report_dangling(report, strict, plans, attrs, series)
    _require_new_ids(conn, plans, attrs)
    supplemental = manifest["supplemental_attributes"]
    with _savepoint(conn):
        seed_vocabulary(conn)
        for plan, objs in plans:
            for obj in objs:
                _write_entity(conn, plan, obj)
        routed = []
        for attr in attrs:
            attr_id = _required_id(attr, "id", "supplemental attribute")
            if attr_id not in attr_types:
                raise InsertError(
                    f"supplemental attribute id={attr_id}: no association names its type"
                )
            attr_type = attr_types[attr_id]
            table = "supplemental_attributes"
            if attr_type in supplemental["plant_types"]:
                table = "plants"
            what = f"{attr_type} id={attr_id}"
            _execute(
                conn,
                "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, ?, ?)",
                [attr_id, table, attr_type],
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
        for section in manifest["associations"]:
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
            sidecar = None if time_series is None else str(time_series)
            store_id = conn.execute(ts["store_sql"], [offset, sidecar]).lastrowid
            insert_associations(conn, ts, series, report)
            conn.execute(ts["store_rows_sql"], [store_id, offset])
            if missing is None:
                export_values(conn, ts, series, time_series, store_id)
    return report


def _document_path(path):
    """A document file, or the one .json document in a bundle directory (PSIP writes a
    portfolio's base system as base_system/system.json)."""
    path = os.fspath(path)
    if not os.path.isdir(path):
        return path
    docs = sorted(f for f in os.listdir(path) if f.endswith(".json"))
    if len(docs) != 1:
        raise InsertError(f"{path}: expected one .json document, found {len(docs)}")
    return os.path.join(path, docs[0])


def _beside(path, name):
    """A sidecar a document names by basename, resolved next to it; None when unnamed."""
    return os.path.join(os.path.dirname(os.path.abspath(path)), name) if name else None


def insert_file(conn, path, *, strict=False, time_series=None):
    """Insert the document at path (a file or bundle directory) with its sidecar:
    time_series, else its time_series_storage_file. A portfolio's base_system_file
    goes in first, with its own sidecar; both in one savepoint."""
    path = _document_path(path)
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    report = InsertReport()
    with _savepoint(conn):
        base = _beside(path, doc.get("base_system_file"))
        if base is not None:
            base = _document_path(base)
            with open(base, encoding="utf-8") as handle:
                system = json.load(handle)
            sidecar = _beside(base, system.get("time_series_storage_file"))
            report.merge(insert_document(conn, system, strict=strict, time_series=sidecar))
        sidecar = time_series or _beside(path, doc.get("time_series_storage_file"))
        report.merge(insert_document(conn, doc, strict=strict, time_series=sidecar))
    return report
