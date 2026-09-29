"""The features_hash golden vectors are what infrastore itself stores.

Builds a throwaway store in tmp_path, files one series per vector's feature map,
and reads the catalog's features_hash BLOB back. Skipped without infrastore.
"""

import datetime
import json
import sqlite3
from pathlib import Path

import pytest

infrastore = pytest.importorskip("infrastore")
np = pytest.importorskip("numpy")

VECTORS = json.loads(
    (Path(__file__).parent / "features_hash_vectors.json").read_text(encoding="utf-8")
)["vectors"]


def test_vectors_match_infrastore_catalog(tmp_path):
    path = str(tmp_path / "oracle.h5")
    store = infrastore.Store.create(path)
    for i, vector in enumerate(VECTORS):
        series = infrastore.SingleTimeSeries(
            datetime.datetime(2026, 1, 1), "PT1H", np.arange(3.0), f"s{i}"
        )
        store.add_time_series(
            1, "Gen", infrastore.OwnerCategory.Component, series, features=vector["features"]
        )
    store.close()
    conn = sqlite3.connect(path + ".sqlite")
    stored = dict(conn.execute("SELECT name, features_hash FROM time_series_associations"))
    conn.close()
    assert [stored[f"s{i}"].hex() for i in range(len(VECTORS))] == [
        v["hash"] for v in VECTORS
    ]
