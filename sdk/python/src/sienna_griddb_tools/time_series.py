"""Time series association rows, their feature sets, and their values."""

import json
import os
import shutil
import sqlite3
import tempfile

from .encode import ENCODERS, EncodeError, is_int
from .errors import InsertError

DERIVED = "DeterministicSingleTimeSeries"


def feature_rows(features_hash, features):
    rows = []
    for key, value in features.items():
        if isinstance(value, bool):
            rows.append((features_hash, key, "bool", None, None, int(value), None))
        elif isinstance(value, int):
            rows.append((features_hash, key, "int", value, None, None, None))
        elif isinstance(value, float):
            rows.append((features_hash, key, "float", None, value, None, None))
        else:
            rows.append((features_hash, key, "str", None, None, None, value))
    return rows


def require_owner_label(row, owners):
    """A row whose owner the document holds names that owner's type and category;
    a mislabel is invalid data, like a dangling reference."""
    owner = row.get("owner_id")
    if not (is_int(owner) and owner in owners):
        return
    label = (row.get("owner_type"), row.get("owner_category"))
    if label != owners[owner]:
        raise InsertError(
            f"time series association id={row.get('association_id')}: owner_id {owner} "
            f"is {owners[owner][0]} ({owners[owner][1]}), not {label[0]} ({label[1]})"
        )


def insert_associations(conn, plan, rows, report):
    """Association rows, then each feature set the first time its hash appears."""
    getters = [(ENCODERS[b["encode"]], b["path"]) for b in plan["bindings"]]
    hash_at = [b["encode"] for b in plan["bindings"]].index("features_hash")
    features_seen = set()
    for row in rows:
        try:
            params = [None if row.get(p) is None else enc(row[p]) for enc, p in getters]
            conn.execute(plan["row_sql"], params)
            features_hash = params[hash_at]
            if features_hash not in features_seen:
                features_seen.add(features_hash)
                conn.executemany(
                    plan["feature_sql"], feature_rows(features_hash, row["features"])
                )
        except (sqlite3.Error, EncodeError) as exc:
            what = f"time series association id={row.get('association_id')}"
            raise InsertError(f"{what}: {exc}") from exc
        report.add_inserted(plan["section"])


def _feature_key(features):
    """A hashable feature map that tells 1, 1.0 and true apart, as features_hash does."""
    if not isinstance(features, dict):
        return None
    return tuple(sorted((k, type(v).__name__, v) for k, v in features.items()))


def _series_key(row):
    features = _feature_key(row.get("features"))
    return (
        row.get("owner_id"),
        row.get("owner_category"),
        row.get("name"),
        features,
        row.get("uri"),
    )


def derived_sources(rows):
    """{DeterministicSingleTimeSeries id: its SingleTimeSeries id}. A derived series is a
    view over its source's array: same owner, name, features and uri."""
    sources = {
        _series_key(r): r.get("association_id")
        for r in rows
        if r.get("time_series_type") == "SingleTimeSeries"
    }
    derived = {}
    for r in rows:
        source = (
            sources.get(_series_key(r)) if r.get("time_series_type") == DERIVED else None
        )
        if source is not None:
            derived[r.get("association_id")] = source
    return derived


def _is_reference(key):
    return key in ("association_id", "fuel_cost_time_series") or key.endswith(
        "_association_id"
    )


def point_at_sources(node, sources):
    """node with its time series references to a derived series naming the source
    instead (the keys dangling_time_series_references reads). A dict or list is
    copied only when something inside it changes; the caller's stays as it was."""
    if not sources or not isinstance(node, (dict, list)):
        return node
    changed = {}
    for k, v in node.items() if isinstance(node, dict) else enumerate(node):
        if isinstance(k, str) and _is_reference(k) and is_int(v) and v in sources:
            changed[k] = sources[v]
        else:
            new = point_at_sources(v, sources)
            if new is not v:
                changed[k] = new
    if not changed:
        return node
    out = dict(node) if isinstance(node, dict) else list(node)
    for k, v in changed.items():
        out[k] = v
    return out


def values_missing(sidecar):
    """Why the values cannot be stored here, or None when they can."""
    if sidecar is None:
        return "no time series sidecar given"
    try:
        import infrastore
    except ImportError:
        return "install sienna-griddb-tools[time-series] to read the sidecar"
    if not hasattr(infrastore.Store, "export_sqlite"):
        return "the installed infrastore has no SQLite export (needs infrastore > 0.14.1)"
    return None


def _copy_export(conn, path):
    """infrastore's export, written into conn inside the caller's transaction: its
    tables with their rows, then their indexes and views."""
    src = sqlite3.connect(path)
    try:
        objects = src.execute(
            "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rowid"
        ).fetchall()
        for kind, name, sql in objects:
            if kind == "table":
                conn.execute(sql)
                rows = src.execute(f'SELECT * FROM "{name}"')
                marks = ", ".join("?" for _ in rows.description)
                conn.executemany(f'INSERT INTO "{name}" VALUES ({marks})', rows)
        for kind, _, sql in objects:
            if kind != "table":
                conn.execute(sql)
    finally:
        src.close()


def export_values(conn, plan, rows, sidecar):
    """Store the rows' arrays as infrastore's SQLite export under plan's prefix. The
    sidecar is only read: infrastore opens a private copy with an in-memory catalog."""
    import infrastore

    # infrastore rejects null for an optional field, which a model dump spells for
    # every unset one; GridDB's own rows treat null as absent
    wire = [{k: v for k, v in row.items() if v is not None} for row in rows]
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "time_series.h5")
        out = os.path.join(tmp, "export.sqlite")
        try:
            shutil.copyfile(sidecar, copy)
            store = infrastore.Store.open_without_catalog(copy, catalog="memory")
            try:
                store.import_time_series_associations_openapi(json.dumps(wire))
                store.export_sqlite(out, table_prefix=plan["table_prefix"])
            finally:
                store.close()
        except (infrastore.TimeSeriesError, OSError) as exc:
            raise InsertError(f"time series sidecar {sidecar}: {exc}") from exc
        try:
            _copy_export(conn, out)
        except sqlite3.Error as exc:
            raise InsertError(f"time series values: {exc}") from exc
