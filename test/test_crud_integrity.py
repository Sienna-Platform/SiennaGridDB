"""Integrity rules that a CRUD layer relies on: labels that match their entity,
id arrays that name real rows, deletes that remove what a row owns, and lookups
that return one row per key. Each test writes raw SQL into a database that holds
the synthetic document, so the rules hold for any writer, not only the SDKs."""

import sqlite3
import sys

import pytest

from conftest import REPO_ROOT, SCHEMAS_PATH, SCRIPTS_DIR, make_entity

sys.path.insert(0, str(SCRIPTS_DIR))
sys.path.insert(0, str(REPO_ROOT / "sdk" / "python" / "src"))
import sienna_griddb_tools as griddb
import synthetic_document as synthetic


@pytest.fixture(scope="module")
def document(db):
    doc, _ = synthetic.synthetic_document(db, str(SCHEMAS_PATH))
    return doc


@pytest.fixture
def filled(document, tmp_path):
    conn = griddb.create_database(str(tmp_path / "filled.sqlite"))
    griddb.insert_document(conn, document, strict=True)
    yield conn
    conn.close()


def first_id(doc, type_name):
    return doc["components"][type_name][0]["id"]


def one(conn, sql, params=()):
    return conn.execute(sql, params).fetchone()[0]


def test_an_entity_type_must_belong_to_its_table(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match=r"must be a type of entities.entity_table"):
        fresh_db.execute(
            "INSERT INTO entities (id, entity_table, entity_type) "
            "VALUES (40, 'thermal_generators', 'ACBus')"
        )


def test_the_entity_type_vocabulary_is_fixed(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="entity_types rows cannot change"):
        fresh_db.execute("UPDATE entity_types SET is_dc = 1 WHERE name = 'ACBus'")
    with pytest.raises(sqlite3.IntegrityError, match="cannot store TEXT value in INTEGER column"):
        fresh_db.execute("INSERT INTO entity_types (name, is_topology) VALUES ('Zzz', 'yes')")


def test_an_attribute_states_its_owners_type(filled, document):
    thermal = first_id(document, "ThermalStandard")
    with pytest.raises(sqlite3.IntegrityError, match=r"attributes.TYPE must be the entity_type"):
        filled.execute(
            "INSERT INTO attributes (entity_id, TYPE, name, value) "
            "VALUES (?, 'TwoTerminalGenericHVDCLine', 'loss', '5')",
            (thermal,),
        )


def test_a_supplemental_attribute_states_its_own_type(fresh_db):
    make_entity(fresh_db, 70, "supplemental_attributes", "EmissionsData")
    with pytest.raises(sqlite3.IntegrityError, match="TYPE must be the entity_type"):
        fresh_db.execute(
            "INSERT INTO supplemental_attributes (id, TYPE, value) "
            "VALUES (70, 'GeographicInfo', '{\"pollutant\": \"BANANA\"}')"
        )


def test_an_association_names_its_ends_by_their_types(fresh_db):
    make_entity(fresh_db, 3, "thermal_generators", "ThermalStandard")
    make_entity(fresh_db, 90, "supplemental_attributes", "GeographicInfo")
    fresh_db.execute(
        "INSERT INTO supplemental_attributes (id, TYPE, value) VALUES (90, 'GeographicInfo', '{}')"
    )
    insert = (
        "INSERT INTO supplemental_attribute_associations "
        "(component_id, component_type, attribute_id, attribute_type) VALUES (?, ?, ?, ?)"
    )
    with pytest.raises(sqlite3.IntegrityError, match="component_type must be the entity_type"):
        fresh_db.execute(insert, (3, "Banana", 90, "GeographicInfo"))
    with pytest.raises(sqlite3.IntegrityError, match="attribute_type must be the entity_type"):
        fresh_db.execute(insert, (3, "ThermalStandard", 90, "Apple"))
    with pytest.raises(sqlite3.IntegrityError, match="must differ"):
        fresh_db.execute(insert, (90, "GeographicInfo", 90, "GeographicInfo"))
    fresh_db.execute(insert, (3, "ThermalStandard", 90, "GeographicInfo"))


@pytest.mark.parametrize(
    "owner_type, name, target_type",
    [
        ("Area", "out_of_area_load_ids", "ThermalStandard"),
        ("HydroReservoir", "upstream_turbines", "ThermalStandard"),
        ("HydroReservoir", "upstream_reservoirs", "HydroTurbine"),
    ],
)
def test_an_id_array_lists_only_rows_of_its_target(filled, document, owner_type, name, target_type):
    owner = first_id(document, owner_type)
    wrong = first_id(document, target_type)
    filled.execute("DELETE FROM attributes WHERE entity_id = ? AND name = ?", (owner, name))
    for value in (f"[{wrong}]", "[999999]"):
        with pytest.raises(sqlite3.IntegrityError, match=f"{name} lists an id"):
            filled.execute(
                "INSERT INTO attributes (entity_id, TYPE, name, value) VALUES (?, ?, ?, ?)",
                (owner, owner_type, name, value),
            )


def test_a_listed_turbine_cannot_be_deleted(filled, document):
    turbines = one(
        filled,
        "SELECT value FROM attributes WHERE TYPE = 'HydroReservoir' AND name = 'upstream_turbines'",
    )
    listed = int(turbines.strip("[]").split(",")[0])
    with pytest.raises(sqlite3.IntegrityError, match="is listed in hydro_reservoirs"):
        filled.execute("DELETE FROM hydro_generators WHERE id = ?", (listed,))


def test_deleting_a_transformer_deletes_its_circuits(filled, document):
    two = document["components"]["TwoWindingTransformer"][0]
    three = document["components"]["ThreeWindingTransformer"][0]
    circuits = [two["circuit"]] + [
        three[k] for k in ("primary_circuit", "secondary_circuit", "tertiary_circuit")
    ]
    filled.execute("DELETE FROM two_winding_transformers WHERE id = ?", (two["id"],))
    filled.execute("DELETE FROM three_winding_transformers WHERE id = ?", (three["id"],))
    marks = ", ".join("?" for _ in circuits)
    assert one(filled, f"SELECT count(*) FROM transformer_circuits WHERE id IN ({marks})", circuits) == 0
    assert one(filled, f"SELECT count(*) FROM entities WHERE id IN ({marks})", circuits) == 0
    assert filled.execute("PRAGMA foreign_key_check").fetchall() == []


def test_replace_cannot_take_another_rows_name(filled, document):
    standard = document["components"]["ThermalStandard"][0]
    multistart = document["components"]["ThermalMultiStart"][0]
    columns = [
        r[1] for r in filled.execute("PRAGMA table_xinfo(thermal_generators)") if r[6] == 0
    ]
    copied = ", ".join("9001" if c == "id" else c for c in columns)
    make_entity(filled, 9001, "thermal_generators", "ThermalStandard")
    with pytest.raises(sqlite3.IntegrityError, match=r"thermal_generators.name is used by another row"):
        filled.execute(
            f"INSERT OR REPLACE INTO thermal_generators ({', '.join(columns)}) "
            f"SELECT {copied} FROM thermal_generators WHERE id = ?",
            (standard["id"],),
        )
    with pytest.raises(sqlite3.IntegrityError, match=r"thermal_generators.name is used by another row"):
        filled.execute(
            "UPDATE OR REPLACE thermal_generators SET name = ? WHERE id = ?",
            (multistart["name"], standard["id"]),
        )
    ids = (standard["id"], multistart["id"])
    assert one(filled, "SELECT count(*) FROM thermal_generators WHERE id IN (?, ?)", ids) == 2


def test_a_deleted_store_id_is_never_given_again(fresh_db):
    fresh_db.execute("INSERT INTO time_series_stores (id_offset) VALUES (0)")
    fresh_db.execute("DELETE FROM time_series_stores")
    fresh_db.execute("INSERT INTO time_series_stores (id_offset) VALUES (0)")
    assert one(fresh_db, "SELECT id FROM time_series_stores") == 2


def test_operational_data_reads_the_typed_columns(filled, document):
    thermal = document["components"]["ThermalStandard"][0]
    row = filled.execute(
        "SELECT active_power_limit_min, operational_cost FROM operational_data WHERE entity_id = ?",
        (thermal["id"],),
    ).fetchone()
    assert row is not None
    assert row[0] == thermal["active_power_limits"]["min"]
    assert row[1] is not None


def test_attribute_names_differing_only_in_case_collide(filled, document):
    thermal = first_id(document, "ThermalStandard")
    filled.execute(
        "INSERT INTO attributes (entity_id, TYPE, name, value) VALUES (?, 'ThermalStandard', 'Note', '\"a\"')",
        (thermal,),
    )
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        filled.execute(
            "INSERT INTO attributes (entity_id, TYPE, name, value) VALUES (?, 'ThermalStandard', 'note', '\"b\"')",
            (thermal,),
        )


@pytest.mark.parametrize(
    "kind, columns",
    [("int", "value_str"), ("float", "value_int"), ("str", "value_int, value_str")],
)
def test_a_feature_value_sits_in_the_column_its_kind_names(fresh_db, kind, columns):
    names = columns.split(", ")
    values = ", ".join("1" if c != "value_str" else "'x'" for c in names)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK constraint failed"):
        fresh_db.execute(
            f"INSERT INTO feature_sets (features_hash, key, value_kind, {columns}) "
            f"VALUES ('{'0' * 64}', 'year', '{kind}', {values})"
        )


def test_an_interchange_runs_between_two_areas(filled, document):
    interchange = first_id(document, "AreaInterchange")
    with pytest.raises(sqlite3.IntegrityError, match="from_area <> to_area"):
        filled.execute(
            "UPDATE transmission_interchanges SET to_area = from_area WHERE id = ?", (interchange,)
        )


def test_capital_cost_columns_hold_json(filled, document):
    storage = first_id(document, "StorageTechnology")
    with pytest.raises(sqlite3.IntegrityError, match="json_valid"):
        filled.execute(
            "UPDATE storage_technologies SET capital_costs_charge = '{bad json' WHERE id = ?",
            (storage,),
        )
