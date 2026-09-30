"""The time_series_values view: every stored SingleTimeSeries value with its UTC
timestamp, initial_timestamp + k * resolution as infrastore computes it."""

import datetime
import json
import shutil
import sqlite3

import pytest

from conftest import make_entity

EMPTY = "f0f10eb0149a8828ad7505d73262e3e4a70bfdfed90e4c2e9ce6013758296ede"

# (resolution, initial_timestamp, the view's timestamps for steps 0, 1, ...)
CASES = {
    "hourly": ("PT1H", "2026-01-01T00:00:00Z", [
        "2026-01-01T00:00:00.000Z", "2026-01-01T01:00:00.000Z"]),
    "five minutes": ("PT5M", "2026-01-01T00:00:00Z", [
        "2026-01-01T00:00:00.000Z", "2026-01-01T00:05:00.000Z"]),
    "fifteen minutes": ("PT15M", "2026-01-01T23:45:00Z", [
        "2026-01-01T23:45:00.000Z", "2026-01-02T00:00:00.000Z"]),
    "thirty seconds": ("PT30S", "2026-01-01T00:00:00Z", [
        "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:30.000Z"]),
    "daily": ("P1D", "2026-02-27T12:00:00Z", [
        "2026-02-27T12:00:00.000Z", "2026-02-28T12:00:00.000Z",
        "2026-03-01T12:00:00.000Z"]),
    "weekly": ("P1W", "2026-01-01T00:00:00Z", [
        "2026-01-01T00:00:00.000Z", "2026-01-08T00:00:00.000Z"]),
    "month-end clamps": ("P1M", "2024-01-31T06:00:00Z", [
        "2024-01-31T06:00:00.000Z", "2024-02-29T06:00:00.000Z",
        "2024-03-31T06:00:00.000Z", "2024-04-30T06:00:00.000Z"]),
    "leap day": ("P1Y", "2024-02-29T00:00:00Z", [
        "2024-02-29T00:00:00.000Z", "2025-02-28T00:00:00.000Z",
        "2026-02-28T00:00:00.000Z", "2027-02-28T00:00:00.000Z",
        "2028-02-29T00:00:00.000Z"]),
    "compound calendar": ("P1Y6M", "2023-08-31T00:00:00Z", [
        "2023-08-31T00:00:00.000Z", "2025-02-28T00:00:00.000Z",
        "2026-08-31T00:00:00.000Z"]),
    "year boundary": ("PT1H", "2025-12-31T23:00:00Z", [
        "2025-12-31T23:00:00.000Z", "2026-01-01T00:00:00.000Z"]),
    "fractional seconds": ("PT0.25S", "2026-01-01T00:00:59.5Z", [
        "2026-01-01T00:00:59.500Z", "2026-01-01T00:00:59.750Z",
        "2026-01-01T00:01:00.000Z"]),
    "one millisecond": ("PT0.001S", "2026-01-01T00:00:00.999Z", [
        "2026-01-01T00:00:00.999Z", "2026-01-01T00:00:01.000Z"]),
    "compound duration": ("P1DT1H30M0.5S", "2026-01-01T00:00:00Z", [
        "2026-01-01T00:00:00.000Z", "2026-01-02T01:30:00.500Z",
        "2026-01-03T03:00:01.000Z"]),
    "UTC offset": ("PT1H", "2026-03-08T01:00:00-06:00", [
        "2026-03-08T07:00:00.000Z", "2026-03-08T08:00:00.000Z"]),
    "before 1970": ("PT0.25S", "1969-12-31T23:59:59.5Z", [
        "1969-12-31T23:59:59.500Z", "1969-12-31T23:59:59.750Z",
        "1970-01-01T00:00:00.000Z"]),
}


def add_series(conn, uri, resolution, initial, steps, width=1, series="SingleTimeSeries"):
    """A new owner's series over uri, whose values are 10 * step + element."""
    (owner,) = conn.execute("SELECT ifnull(max(id), 0) + 1 FROM entities").fetchone()
    make_entity(conn, owner)
    interval = None if series == "SingleTimeSeries" else "PT0S"
    assoc = conn.execute(
        "INSERT INTO time_series_associations (owner_id, owner_type, owner_category, "
        "time_series_type, name, initial_timestamp, resolution, length, interval, uri, "
        "features_hash, units) "
        "VALUES (?, 'thing', 'Component', ?, 'load', ?, ?, ?, ?, ?, ?, 'MW')",
        (owner, series, initial, resolution, steps, interval, uri, EMPTY),
    ).lastrowid
    conn.executemany(
        "INSERT OR IGNORE INTO static_time_series (uri, timestep, element, value) "
        "VALUES (?, ?, ?, ?)",
        [(uri, k, e, 10.0 * k + e) for k in range(steps) for e in range(width)],
    )
    return assoc


def view_stamps(conn, association_id):
    return [
        r[0]
        for r in conn.execute(
            "SELECT timestamp FROM time_series_values WHERE association_id = ? "
            "AND element = 0 ORDER BY timestep",
            (association_id,),
        )
    ]


def utc_text(t):
    """infrastore's instant in the view's spelling (a naive one is zoneless)."""
    if t.tzinfo is not None:
        t = t.astimezone(datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


@pytest.mark.parametrize("case", CASES)
def test_timestamps(fresh_db, case):
    resolution, initial, expected = CASES[case]
    assoc = add_series(fresh_db, "u1", resolution, initial, len(expected))
    assert view_stamps(fresh_db, assoc) == expected


@pytest.mark.parametrize("case", CASES)
def test_cases_match_infrastore(case):
    """The expected timestamps above are infrastore's own grid."""
    infrastore = pytest.importorskip("infrastore")
    np = pytest.importorskip("numpy")
    resolution, initial, expected = CASES[case]
    start = datetime.datetime.fromisoformat(initial.replace("Z", "+00:00"))
    series = infrastore.SingleTimeSeries(start, resolution, np.zeros(len(expected)), "x")
    assert [utc_text(t) for t in series.timestamps] == expected


def test_composite_elements_share_their_step_timestamp(fresh_db):
    assoc = add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 2, width=3)
    rows = fresh_db.execute(
        "SELECT timestamp, timestep, element, value, units FROM time_series_values "
        "WHERE association_id = ? ORDER BY timestep, element",
        (assoc,),
    ).fetchall()
    first, second = "2026-01-01T00:00:00.000Z", "2026-01-01T01:00:00.000Z"
    assert rows == [
        (first, 0, 0, 0.0, "MW"), (first, 0, 1, 1.0, "MW"), (first, 0, 2, 2.0, "MW"),
        (second, 1, 0, 10.0, "MW"), (second, 1, 1, 11.0, "MW"), (second, 1, 2, 12.0, "MW"),
    ]


def test_nan_is_a_null_value_with_its_timestamp(fresh_db):
    assoc = add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 0)
    fresh_db.execute(
        "INSERT INTO static_time_series (uri, timestep, value) VALUES ('u1', 0, ?)",
        (float("nan"),),
    )
    assert fresh_db.execute(
        "SELECT timestamp, value FROM time_series_values WHERE association_id = ?", (assoc,)
    ).fetchall() == [("2026-01-01T00:00:00.000Z", None)]


def test_one_row_per_single_time_series_value(fresh_db):
    """A forecast sharing the array adds no rows: forecasts are not in the view."""
    add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 3, width=2)
    add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 3, width=2)
    add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 3, width=2,
               series="DeterministicSingleTimeSeries")
    rows = fresh_db.execute(
        "SELECT time_series_type, count(*) FROM time_series_values GROUP BY 1"
    ).fetchall()
    assert rows == [("SingleTimeSeries", 12)]


def test_slice_by_timestamp_or_timestep(fresh_db):
    assoc = add_series(fresh_db, "u1", "PT1H", "2026-01-01T00:00:00Z", 24)
    by_time = fresh_db.execute(
        "SELECT timestep FROM time_series_values WHERE association_id = ? AND timestamp "
        "BETWEEN '2026-01-01T06:00:00.000Z' AND '2026-01-01T08:00:00.000Z' "
        "ORDER BY timestep",
        (assoc,),
    ).fetchall()
    # A bound passed as text ('6', as Datasette sends it) still matches the column
    by_step = fresh_db.execute(
        "SELECT timestep FROM time_series_values WHERE association_id = ? "
        "AND timestep BETWEEN '6' AND 8 ORDER BY timestep",
        (assoc,),
    ).fetchall()
    assert by_time == by_step == [(6,), (7,), (8,)]


def test_view_matches_infrastore_on_the_synthetic_case(tmp_path):
    """Every SingleTimeSeries of the synthetic case, inserted by the Python SDK, reads
    the timestamps infrastore reads from a copy of the case's sidecar."""
    infrastore = pytest.importorskip("infrastore")
    pytest.importorskip("numpy")
    import time_series_case

    path = time_series_case.build(str(tmp_path))
    db_path = str(tmp_path / "case.sqlite")
    time_series_case.expected_outputs(path, db_path)
    conn = sqlite3.connect(db_path)
    ours = {}
    for assoc, stamp in conn.execute(
        "SELECT association_id, timestamp FROM time_series_values WHERE element = 0 "
        "ORDER BY association_id, timestep"
    ):
        ours.setdefault(assoc, []).append(stamp)
    conn.close()
    with open(path, encoding="utf-8") as handle:
        rows = [
            r for r in json.load(handle)["time_series_associations"]
            if r["time_series_type"] == "SingleTimeSeries" and r["association_id"] in ours
        ]
    copy = str(tmp_path / "copy.h5")
    shutil.copyfile(str(tmp_path / "case.h5"), copy)
    store = infrastore.Store.open_without_catalog(copy, catalog="memory")
    try:
        store.import_time_series_associations_openapi(json.dumps(rows))
        theirs = {
            r["association_id"]: [
                utc_text(t) for t in store.read_by_id(r["association_id"]).timestamps
            ]
            for r in rows
        }
    finally:
        store.close()
    assert len(ours) >= 5
    assert ours == theirs
