import json

import pytest
from test_insert import count, golden

import sienna_griddb_tools as griddb
from sienna_griddb_tools.encode import features_hash


@pytest.fixture
def conn(tmp_path):
    c = griddb.create_database(str(tmp_path / "t.sqlite"))
    yield c
    c.close()


def thermal(doc):
    return doc["components"]["ThermalStandard"][0]


def series(owner, association_id, **fields):
    row = {
        "association_id": association_id,
        "owner_id": owner["id"],
        "owner_type": "ThermalStandard",
        "owner_category": "Component",
        "time_series_type": "SingleTimeSeries",
        "name": "max_active_power",
        "features": {"scenario": "base", "year": 2030},
        "uri": "/arrays/a",
        "element_type": "f64",
        "element_shape": [],
        "initial_timestamp": "2030-01-01T00:00:00",
        "resolution": "PT1H",
        "length": 24,
    }
    return {**row, **fields}


def test_associations_and_feature_sets_are_stored(conn):
    doc = golden()
    gen = thermal(doc)
    doc["time_series_associations"] = [
        series(gen, 7),
        series(gen, 8, name="min_active_power"),
    ]
    report = griddb.insert_document(conn, doc)
    assert report.inserted["time_series_associations"] == 2
    row = conn.execute(
        "SELECT owner_id, name, features_hash FROM time_series_associations WHERE id = 7"
    ).fetchone()
    expected_hash = features_hash({"scenario": "base", "year": 2030})
    assert row == (gen["id"], "max_active_power", expected_hash)
    # Both rows share one feature set, stored once.
    features = conn.execute(
        "SELECT key, value_kind, value_int, value_str FROM feature_sets ORDER BY key"
    ).fetchall()
    assert features == [("scenario", "str", None, "base"), ("year", "int", 2030, None)]


def test_mislabelled_owner_raises(conn):
    doc = golden()
    doc["time_series_associations"] = [
        series(thermal(doc), 7, owner_type="RenewableDispatch")
    ]
    with pytest.raises(griddb.InsertError, match="is ThermalStandard"):
        griddb.insert_document(conn, doc)
    assert count(conn, "entities") == 0


def test_series_of_an_unsupported_owner_is_reported(conn):
    doc = golden()
    doc["components"]["AGC"] = [{"id": 9001, "name": "agc"}]
    doc["time_series_associations"] = [
        series({"id": 9001}, 7, owner_type="AGC"),
        series(thermal(doc), 8),
    ]
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["time_series_associations"] == 1
    assert count(conn, "time_series_associations") == 1


def test_unsupported_series_type_is_reported_and_strict_raises(conn):
    doc = golden()
    row = series(thermal(doc), 7, time_series_type="NonSequentialTimeSeries")
    for key in ("initial_timestamp", "resolution"):
        row.pop(key)
    doc["time_series_associations"] = [row]
    doc.pop("ext")
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["NonSequentialTimeSeries"] == 1
    assert count(conn, "time_series_associations") == 0
    with pytest.raises(griddb.InsertError, match="timestamps_uri"):
        griddb.insert_document(conn, doc, strict=True)


def test_a_plant_owns_series_as_a_supplemental_attribute(conn):
    doc = golden()
    gen = thermal(doc)
    plant = {"id": 9100, "name": "plant1"}
    doc["supplemental_attributes"].append(plant)
    doc["supplemental_attribute_associations"].append(
        {
            "component_id": gen["id"],
            "component_type": "ThermalStandard",
            "attribute_id": plant["id"],
            "attribute_type": "ThermalPowerPlant",
        }
    )
    owner = {"owner_type": "ThermalPowerPlant", "owner_category": "SupplementalAttribute"}
    doc["time_series_associations"] = [series(plant, 7, **owner)]
    griddb.insert_document(conn, doc)
    assert count(conn, "time_series_associations") == 1


def fuel_cost_series(doc):
    """A golden thermal whose fuel cost is the series 7, with a DeterministicSingleTimeSeries
    8 derived from it: same array, owner, name and features, plus forecast windows."""
    gen = thermal(doc)
    cost = gen["operation_cost"]["variable_operation_cost"]
    cost.update(
        {"variable_cost_type": "FUEL", "fuel_cost": None, "fuel_cost_time_series": 8}
    )
    derived = series(
        gen,
        8,
        time_series_type="DeterministicSingleTimeSeries",
        horizon="PT24H",
        interval="PT24H",
        count=1,
    )
    doc["time_series_associations"] = [series(gen, 7, name="fuel_cost"), derived]
    derived["name"] = "fuel_cost"
    doc.pop("ext")
    return gen


def test_deterministic_single_time_series_is_reported_and_strict_raises(conn):
    doc = golden()
    fuel_cost_series(doc)
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["DeterministicSingleTimeSeries"] == 1
    assert conn.execute("SELECT id FROM time_series_associations").fetchall() == [(7,)]
    with pytest.raises(griddb.InsertError, match="transform_single_time_series"):
        griddb.insert_document(conn, doc, strict=True)


def test_a_reference_to_a_derived_series_points_at_its_source(conn):
    doc = golden()
    gen = fuel_cost_series(doc)
    griddb.insert_document(conn, doc)
    stored = conn.execute(
        "SELECT operation_cost FROM thermal_generators WHERE id = ?", (gen["id"],)
    ).fetchone()[0]
    assert '"fuel_cost_time_series":7' in stored.replace(" ", "")
    assert conn.execute("SELECT * FROM dangling_time_series_references").fetchall() == []
    # The caller's document is left as it was.
    assert gen["operation_cost"]["variable_operation_cost"]["fuel_cost_time_series"] == 8


def test_a_reference_no_stored_series_has_is_reported_and_strict_raises(conn):
    doc = golden()
    gen = fuel_cost_series(doc)
    # The payload names 8, but the document holds no series.
    doc["time_series_associations"] = []
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["dangling_time_series_references"] == 1
    assert conn.execute("SELECT association_id FROM dangling_time_series_references").fetchall() == [(8,)]
    first = f"first: entity {gen['id']} fuel_cost_time_series=8"
    with pytest.raises(griddb.InsertError, match=first):
        griddb.insert_document(conn, doc, strict=True)


def test_point_at_sources_copies_only_what_changes():
    from sienna_griddb_tools.time_series import point_at_sources

    untouched = {"curve": [1, 2], "association_id": 3}
    node = {"a": untouched, "b": [{"fuel_cost_time_series": 8}], "c": 8}
    out = point_at_sources(node, {8: 7})
    assert out == {"a": untouched, "b": [{"fuel_cost_time_series": 7}], "c": 8}
    assert out["a"] is untouched
    assert node["b"][0]["fuel_cost_time_series"] == 8
    assert point_at_sources(untouched, {8: 7}) is untouched


def sidecar_document(tmp_path):
    """The golden document with two series of its first thermal stored in a real
    infrastore sidecar; a deleted series leaves a gap so ids are not 1..n."""
    infrastore = pytest.importorskip("infrastore")
    np = pytest.importorskip("numpy")
    from datetime import datetime, timedelta, timezone

    doc = golden()
    gen = thermal(doc)
    path = str(tmp_path / "ts.h5")
    store = infrastore.Store.create(path)
    t0, hour = datetime(2030, 1, 1, tzinfo=timezone.utc), timedelta(hours=1)
    component = infrastore.OwnerCategory.Component

    def add(name, values, **kwargs):
        series = infrastore.SingleTimeSeries(t0, hour, np.array(values, dtype=float), name)
        return store.add_time_series(
            gen["id"], "ThermalStandard", component, series, **kwargs
        )

    gone = add("scratch", [0.0])
    add("max_active_power", [1.0, 2.0, 3.0], features={"year": 2030})
    add("min_active_power", [0.5, 0.5, 0.5])
    store.remove_by_ids([gone])
    doc["time_series_associations"] = json.loads(
        store.export_time_series_associations_openapi()
    )
    store.close()
    doc.pop("ext")
    return doc, path


def test_values_are_infrastore_export_keyed_by_association_id(conn, tmp_path):
    doc, sidecar = sidecar_document(tmp_path)
    griddb.insert_document(conn, doc, time_series=sidecar)
    values = conn.execute(
        "SELECT association_id, name, timestamp, value FROM time_series_values "
        "ORDER BY association_id, timestamp"
    ).fetchall()
    ids = {r["name"]: r["association_id"] for r in doc["time_series_associations"]}
    assert sorted(ids.values()) == [2, 3]
    assert values == [
        (ids["max_active_power"], "max_active_power", "2030-01-01T00:00:00.000Z", 1.0),
        (ids["max_active_power"], "max_active_power", "2030-01-01T01:00:00.000Z", 2.0),
        (ids["max_active_power"], "max_active_power", "2030-01-01T02:00:00.000Z", 3.0),
        (ids["min_active_power"], "min_active_power", "2030-01-01T00:00:00.000Z", 0.5),
        (ids["min_active_power"], "min_active_power", "2030-01-01T01:00:00.000Z", 0.5),
        (ids["min_active_power"], "min_active_power", "2030-01-01T02:00:00.000Z", 0.5),
    ]
    assert conn.execute("SELECT * FROM orphaned_time_series").fetchall() == []


def test_values_without_a_sidecar_are_reported_and_strict_raises(conn, tmp_path):
    doc, _ = sidecar_document(tmp_path)
    report = griddb.insert_document(conn, doc)
    assert report.unsupported["time_series_values"] == 2
    assert count(conn, "time_series_associations") == 2
    with pytest.raises(griddb.InsertError, match="no time series sidecar"):
        griddb.insert_document(conn, doc, strict=True)


def test_a_missing_sidecar_is_reported_by_path_and_strict_raises(conn, tmp_path):
    doc, _ = sidecar_document(tmp_path)
    gone = str(tmp_path / "gone.h5")
    report = griddb.insert_document(conn, doc, time_series=gone)
    assert report.unsupported["time_series_values"] == 2
    with pytest.raises(griddb.InsertError, match="gone.h5 not found"):
        griddb.insert_document(conn, doc, strict=True, time_series=gone)


def test_the_cli_reports_a_named_sidecar_that_is_missing(tmp_path, capsys):
    from sienna_griddb_tools.__main__ import main

    doc, _ = sidecar_document(tmp_path)
    doc["time_series_storage_file"] = "gone.h5"
    path = tmp_path / "doc.json"
    path.write_text(json.dumps(doc))
    assert main(["build", str(path), str(tmp_path / "out.sqlite")]) == 0
    assert json.loads(capsys.readouterr().out)["unsupported"]["time_series_values"] == 2
    with pytest.raises(griddb.InsertError, match="gone.h5 not found"):
        main(["build", str(path), str(tmp_path / "strict.sqlite"), "--strict"])


def test_deleting_an_owner_leaves_its_values_orphaned(conn, tmp_path):
    doc, sidecar = sidecar_document(tmp_path)
    griddb.insert_document(conn, doc, time_series=sidecar)
    conn.execute("DELETE FROM entities WHERE id = ?", (thermal(doc)["id"],))
    assert len(conn.execute("SELECT * FROM orphaned_time_series").fetchall()) == 2


def test_a_second_export_into_one_database_raises(conn, tmp_path):
    doc, sidecar = sidecar_document(tmp_path)
    griddb.insert_document(conn, doc, time_series=sidecar)
    # A second document's series (new ids and names) land in the same export tables.
    rows = [
        {**r, "association_id": r["association_id"] + 100, "name": r["name"] + "_2"}
        for r in doc["time_series_associations"]
    ]
    second = {"components": {}, "time_series_associations": rows}
    with pytest.raises(griddb.InsertError, match="already exists"):
        griddb.insert_document(conn, second, time_series=sidecar)
    assert count(conn, "time_series_associations") == 2
