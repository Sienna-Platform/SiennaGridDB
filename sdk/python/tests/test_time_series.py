import hashlib
import json
import os
import stat
import sys
from pathlib import Path

import pytest

import sienna_griddb_tools as griddb
from sienna_griddb_tools import insert as insert_module

pytest.importorskip("infrastore")
REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "test"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))
import time_series_case  # noqa: E402
from canonical_dump import dump  # noqa: E402

UNSUPPORTED = {
    "AGC": 1,
    "NonSequentialTimeSeries": 1,
    "time_series_associations": 4,  # AGC's two rows, the i64 series and its forecast view
}


def snapshot(directory):
    """Names, bytes and mtimes of everything in a directory."""
    return {
        p.name: (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
        for p in sorted(directory.iterdir())
    }


@pytest.fixture
def case(tmp_path):
    """The synthetic case in its own directory, sidecar read-only like a shared input."""
    case_dir = tmp_path / "case"
    case_dir.mkdir()
    path = Path(time_series_case.build(str(case_dir)))
    os.chmod(case_dir / "case.h5", stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    return path


@pytest.fixture
def conn(tmp_path):
    c = griddb.create_database(str(tmp_path / "t.sqlite"))
    yield c
    c.close()


def rows(conn, sql, *params):
    return conn.execute(sql, params).fetchall()


def load(case):
    return json.loads(case.read_text("utf-8"))


def sidecar(case):
    return str(case.parent / "case.h5")


def triples(conn, name, series="SingleTimeSeries", owner=1):
    return rows(
        conn,
        "SELECT v.timestep, v.element, v.value FROM time_series_associations a "
        "JOIN static_time_series v ON v.uri = a.uri WHERE a.name = ? "
        "AND a.time_series_type = ? AND a.owner_id = ? ORDER BY v.timestep, v.element",
        name,
        series,
        owner,
    )


def grid(values):
    """(timestep, element, value) triples of a nested list, rows by steps."""
    return [(t, e, v) for t, step in enumerate(values) for e, v in enumerate(step)]


def insert_dump(tmp_path, name, doc, **kwargs):
    path = str(tmp_path / f"{name}.sqlite")
    db = griddb.create_database(path)
    griddb.insert_document(db, doc, **kwargs)
    db.close()
    return dump(path)


def test_document_path_inserts_series_and_leaves_the_sidecar_untouched(conn, case):
    before = snapshot(case.parent)
    report = griddb.insert_document(conn, str(case))
    assert snapshot(case.parent) == before
    assert report.inserted["time_series_associations"] == 19
    assert report.unsupported == UNSUPPORTED
    assert rows(conn, "SELECT * FROM dangling_time_series_references") == []
    assert rows(conn, "SELECT * FROM orphaned_time_series") == []
    kept = {r["association_id"] for r in load(case)["time_series_associations"]}
    stored = {i for (i,) in rows(conn, "SELECT id FROM time_series_associations")}
    assert stored < kept


def test_a_symlinked_read_only_sidecar_is_left_alone(conn, case, tmp_path):
    target = tmp_path / "elsewhere.h5"
    os.replace(case.parent / "case.h5", target)
    os.symlink(target, case.parent / "case.h5")
    before = (target.stat().st_mode, target.stat().st_mtime_ns, target.read_bytes())
    griddb.insert_document(conn, str(case))
    assert (target.stat().st_mode, target.stat().st_mtime_ns, target.read_bytes()) == before
    assert rows(conn, "SELECT count(*) FROM static_time_series") == [(57,)]


def test_one_array_is_stored_once_for_every_association(conn, case):
    griddb.insert_document(conn, str(case))
    shared = rows(
        conn,
        "SELECT DISTINCT uri FROM time_series_associations WHERE name = 'max_active_power'",
    )
    assert len(shared) == 1
    uri = shared[0][0]
    assert rows(conn, "SELECT count(*) FROM static_time_series WHERE uri = ?", uri) == [
        (3,)
    ]
    assert rows(
        conn, "SELECT count(*) FROM time_series_associations WHERE uri = ?", uri
    ) == [(4,)]
    for owner in (1, 2):
        for series in ("SingleTimeSeries", "DeterministicSingleTimeSeries"):
            assert triples(conn, "max_active_power", series, owner) == [
                (t, 0, v) for t, v in enumerate(time_series_case.SHARED)
            ]
    assert rows(conn, "SELECT unit_system FROM time_series_associations WHERE id = 1") == [
        ("component_base",)
    ]


def test_composite_elements_keep_every_slot(conn, case):
    griddb.insert_document(conn, str(case))
    infrastore = pytest.importorskip("infrastore")
    linear = infrastore.encode_element_values(time_series_case.LINEAR, "linear_function")
    steps = infrastore.encode_element_values(time_series_case.STEPS, "piecewise_step")
    assert triples(conn, "linear") == grid(linear.tolist())
    assert triples(conn, "steps") == grid(steps.tolist())
    assert triples(conn, "tuples") == grid(time_series_case.TUPLES)
    view = "DeterministicSingleTimeSeries"
    assert triples(conn, "steps", view) == triples(conn, "steps")


def test_nan_is_stored_as_null_and_inf_as_real(conn, case):
    griddb.insert_document(conn, str(case))
    assert triples(conn, "gaps") == [(0, 0, 1.0), (1, 0, None), (2, 0, float("inf"))]


def test_forecast_splits_on_the_stored_last_axis(conn, case):
    """A scalar Deterministic is stored [horizon steps, windows]: element is the window."""
    griddb.insert_document(conn, str(case))
    assert triples(conn, "forecast", "Deterministic", 2) == grid(time_series_case.FORECAST)


def test_an_array_read_two_ways_is_stored_once(conn, case):
    """A zero scalar forecast and a zero linear_function series share bytes and shape,
    hence one uri and one (timestep, element) split."""
    griddb.insert_document(conn, str(case))
    zero = triples(conn, "zero", "Deterministic", 1)
    assert zero == grid([[0.0, 0.0]] * 3)
    assert triples(conn, "zero_linear", owner=2) == zero
    uris = rows(
        conn, "SELECT DISTINCT uri FROM time_series_associations WHERE name LIKE 'zero%'"
    )
    assert len(uris) == 1


def test_a_second_document_reuses_stored_arrays(conn, case):
    """Across documents too: the forecast first, then the linear series naming its array."""
    doc = load(case)
    by_name = {}
    for row in doc["time_series_associations"]:
        by_name.setdefault(row["name"], []).append(row)
    first = {"components": {"Area": [{"id": 1, "name": "a1"}]}}
    first["time_series_associations"] = by_name["zero"] + by_name["max_active_power"][:1]
    griddb.insert_document(conn, first, time_series=sidecar(case))
    before = rows(conn, "SELECT uri, timestep, element, value FROM static_time_series")
    second = {"components": {"Area": [{"id": 2, "name": "a2"}]}}
    second["time_series_associations"] = [
        r
        for r in by_name["zero_linear"] + by_name["max_active_power"]
        if r["owner_id"] == 2
    ]
    report = griddb.insert_document(conn, second, time_series=sidecar(case))
    assert report.inserted["time_series_associations"] == 4
    assert "static_time_series" not in report.inserted
    assert (
        rows(conn, "SELECT uri, timestep, element, value FROM static_time_series") == before
    )
    assert triples(conn, "zero_linear", owner=2) == grid([[0.0, 0.0]] * 3)


def test_a_declared_shape_is_checked_for_an_array_already_stored(conn, case):
    doc = load(case)
    named = {r["name"]: [] for r in doc["time_series_associations"]}
    for row in doc["time_series_associations"]:
        named[row["name"]].append(row)
    first = {"components": {"Area": [{"id": 1, "name": "a1"}]}}
    first["time_series_associations"] = named["zero"]
    griddb.insert_document(conn, first, time_series=sidecar(case))
    second = {"components": {"Area": [{"id": 2, "name": "a2"}]}}
    second["time_series_associations"] = named["zero_linear"]
    for row in named["zero_linear"]:
        row["array_shape"] = [2, 3]
    with pytest.raises(griddb.InsertError, match=r"shape \[2, 3\]"):
        griddb.insert_document(conn, second, time_series=sidecar(case))
    assert rows(conn, "SELECT count(*) FROM entities") == [(1,)]


def test_features_hash_and_feature_sets(conn, case):
    griddb.insert_document(conn, str(case))
    (bus_hash,) = rows(
        conn,
        "SELECT DISTINCT features_hash FROM time_series_associations WHERE name = 'load'",
    )
    (mixed_hash,) = rows(
        conn,
        "SELECT DISTINCT features_hash FROM time_series_associations WHERE name = 'tuples'",
    )
    assert bus_hash[0] == griddb.encode.features_hash({"bus": 7})
    assert mixed_hash[0] == griddb.encode.features_hash(time_series_case.MIXED)
    stored = rows(
        conn,
        "SELECT features_hash, key, value_kind, value_int, value_float, value_bool, "
        "value_str FROM feature_sets ORDER BY features_hash, key",
    )
    assert sorted(stored) == sorted(
        [
            (bus_hash[0], "bus", "int", 7, None, None, None),
            (mixed_hash[0], "flag", "bool", None, None, 1, None),
            (mixed_hash[0], "n", "int", -3, None, None, None),
            (mixed_hash[0], "w", "float", None, 1.0, None, None),
            (mixed_hash[0], "x", "float", None, 0.5, None, None),
            (mixed_hash[0], "zone", "str", None, None, None, "north"),
        ]
    )


def test_parsed_document_takes_an_explicit_sidecar(tmp_path, case):
    parsed = insert_dump(tmp_path, "a", load(case), time_series=sidecar(case))
    assert parsed == insert_dump(tmp_path, "b", str(case))


def test_row_order_does_not_matter(tmp_path, case):
    """A DeterministicSingleTimeSeries listed before the SingleTimeSeries it views."""
    doc = load(case)
    doc["time_series_associations"].reverse()
    reversed_rows = insert_dump(tmp_path, "a", doc, time_series=sidecar(case))
    assert reversed_rows == insert_dump(tmp_path, "b", str(case))


def test_missing_reader_reports_time_series_unsupported(conn, case, monkeypatch):
    monkeypatch.setattr(insert_module, "reader_missing", lambda: "install the extra")
    report = griddb.insert_document(conn, str(case))
    assert report.unsupported["time_series_associations"] == 24
    assert rows(conn, "SELECT count(*) FROM time_series_associations") == [(0,)]


def test_missing_default_sidecar_is_unsupported(conn, case):
    os.remove(case.parent / "case.h5")
    report = griddb.insert_document(conn, str(case))
    assert report.unsupported["time_series_associations"] == 24
    assert rows(conn, "SELECT count(*) FROM time_series_associations") == [(0,)]


def test_strict_rejects_a_missing_default_sidecar_before_writing(conn, case):
    os.remove(case.parent / "case.h5")
    doc = load(case)
    del doc["components"][time_series_case.UNSTORED_OWNER]
    case.write_text(json.dumps(doc), "utf-8")
    with pytest.raises(griddb.UnsupportedComponentError, match=r"case\.h5 does not exist"):
        griddb.insert_document(conn, str(case), strict=True)
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]


def test_missing_explicit_sidecar_is_an_error(conn, case, tmp_path):
    with pytest.raises(griddb.InsertError, match="sidecar"):
        griddb.insert_document(conn, str(case), time_series=str(tmp_path / "none.h5"))
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]


def test_strict_rejects_unstorable_series_before_writing(conn, case):
    doc = load(case)
    del doc["components"][time_series_case.UNSTORED_OWNER]
    with pytest.raises(griddb.UnsupportedComponentError, match="timestamp vector"):
        griddb.insert_document(conn, doc, time_series=sidecar(case), strict=True)
    series = [
        r
        for r in doc["time_series_associations"]
        if r["time_series_type"] != "NonSequentialTimeSeries"
    ]
    doc["time_series_associations"] = series
    with pytest.raises(griddb.UnsupportedComponentError, match="GridDB does not store"):
        griddb.insert_document(conn, doc, time_series=sidecar(case), strict=True)
    doc["time_series_associations"] = [r for r in series if r["owner_type"] != "AGC"]
    with pytest.raises(griddb.UnsupportedComponentError, match="element_type i64"):
        griddb.insert_document(conn, doc, time_series=sidecar(case), strict=True)
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]


def test_a_non_f64_element_type_is_unsupported_up_front(conn, case):
    doc = load(case)
    for row in doc["time_series_associations"]:
        if row["name"] == "tuples":
            row["element_type"] = "tuple(3,i32)"
    report = griddb.insert_document(conn, doc, time_series=sidecar(case))
    assert report.unsupported["time_series_associations"] == 6
    assert rows(conn, "SELECT count(*) FROM time_series_associations") == [(17,)]


def test_a_declared_shape_must_match_the_stored_array(conn, case):
    """Checked on every row naming the array, not only the one infrastore imports."""
    doc = load(case)
    for row in doc["time_series_associations"]:
        if row["name"] == "linear" and row["time_series_type"] != "SingleTimeSeries":
            row["array_shape"] = [2, 3]
    with pytest.raises(griddb.InsertError, match=r"array_shape \[2, 3\] is not"):
        griddb.insert_document(conn, doc, time_series=sidecar(case))
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]


def test_reserved_feature_key_is_an_insert_error(conn, case):
    doc = load(case)
    next(r for r in doc["time_series_associations"] if r["name"] == "load")["features"] = {
        "name": "x"
    }
    with pytest.raises(griddb.InsertError, match=r"association id=.*CHECK constraint"):
        griddb.insert_document(conn, doc, time_series=sidecar(case))
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]


def test_array_missing_from_the_sidecar_rolls_back(conn, case):
    doc = load(case)
    for row in doc["time_series_associations"]:
        if row["name"] == "geo":
            row["uri"] = row["data_hash"] = "ab" * 32
    with pytest.raises(griddb.InsertError, match="sidecar"):
        griddb.insert_document(conn, doc, time_series=sidecar(case))
    assert rows(conn, "SELECT count(*) FROM entities") == [(0,)]
