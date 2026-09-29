"""Time series associations and their arrays, read from the document's HDF5 sidecar."""

import json
import os
import re
import shutil
import sqlite3
import tempfile
from contextlib import contextmanager

from .encode import ENCODERS, EncodeError
from .errors import InsertError

EXTRA = "sienna-griddb-tools[time-series]"
DST = "DeterministicSingleTimeSeries"
TUPLE = re.compile(r"tuple\(\d+,\s*(\w+)\)")


def reader_missing():
    """Why arrays cannot be read here, or None when infrastore is installed."""
    try:
        import infrastore  # noqa: F401
    except ImportError:
        return f"install {EXTRA} to read the HDF5 sidecar"
    return None


def element_dtype(element_type):
    """The dtype inside tuple(N,dtype), else element_type itself."""
    match = TUPLE.fullmatch(element_type or "")
    return match.group(1) if match else element_type


@contextmanager
def _store(sidecar):
    """infrastore on a private copy: it opens its file writable, so the caller's
    sidecar is only ever read (copyfile follows a symlink to its target)."""
    import infrastore

    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "time_series.h5")
        shutil.copyfile(sidecar, copy)
        store = infrastore.Store.open_without_catalog(copy, catalog="memory")
        try:
            yield store
        finally:
            store.close()


def arrays(sidecar, rows):
    """Yield (row, array) for each row, one row per array, the array in the dtype
    and shape infrastore stores it; the rows are imported so it serves them by hash."""
    import infrastore

    # infrastore rejects null for an optional field, which an SDK model dump
    # spells for every unset one; GridDB's own rows already treat null as absent
    wire = [{k: v for k, v in row.items() if v is not None} for row in rows]
    try:
        with _store(sidecar) as store:
            store.import_time_series_associations_openapi(json.dumps(wire))
            for row in rows:
                yield row, store.get_array_by_hash(row.get("data_hash") or row["uri"])
    except (infrastore.TimeSeriesError, OSError) as exc:
        raise InsertError(f"time series sidecar {sidecar}: {exc}") from exc


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


def insert_time_series(conn, plan, rows, sidecar, report):
    """Association rows, their feature sets, then each array's values the first
    time its uri appears (arrays are shared by uri)."""
    getters = [(ENCODERS[b["encode"]], b["path"]) for b in plan["bindings"]]
    hash_at = [b["encode"] for b in plan["bindings"]].index("features_hash")
    features_seen = set()
    chosen = {}  # uri -> the row infrastore imports to serve the array
    declared = {}  # uri -> {array_shape: association id}
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
        uri = row["uri"]
        # infrastore imports a DeterministicSingleTimeSeries only beside its source
        if chosen.setdefault(uri, row)["time_series_type"] == DST:
            chosen[uri] = row
        if row.get("array_shape"):
            shapes = declared.setdefault(uri, {})
            shapes.setdefault(tuple(row["array_shape"]), row["association_id"])
    stored = "SELECT 1 FROM static_time_series WHERE uri = ? LIMIT 1"
    held = {u for u in chosen if conn.execute(stored, (u,)).fetchone()}
    # An array already stored is read again only to check the shapes declared for it
    read = [r for u, r in chosen.items() if u not in held or u in declared]
    if not read:
        return
    for row, array in arrays(sidecar, read):
        uri = row["uri"]
        # infrastore checks the imported row's element_type and shape, not the rest
        for shape, association_id in declared.get(uri, {}).items():
            if list(shape) != list(array.shape):
                raise InsertError(
                    f"time series association id={association_id}: array_shape "
                    f"{list(shape)} is not the sidecar's {list(array.shape)} for {uri}"
                )
        if uri in held:
            continue
        # One split per uri, from the stored shape: its last axis is element.
        width = array.shape[-1] if array.ndim > 1 else 1
        values = array.reshape(-1).tolist()
        try:
            conn.executemany(
                plan["value_sql"],
                ((uri, i // width, i % width, v) for i, v in enumerate(values)),
            )
        except sqlite3.Error as exc:
            raise InsertError(f"time series {uri}: {exc}") from exc
        report.add_inserted("static_time_series", len(values))
