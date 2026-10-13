"""Time series association rows and their feature sets."""

import sqlite3

from .encode import ENCODERS, EncodeError, is_int
from .errors import InsertError


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
