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
