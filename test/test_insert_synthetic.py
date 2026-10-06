"""Insert one synthetic document holding every supported component type.

scripts/synthetic_document.py generates the document from the SiennaSchemas
components in schema_map.json; see its docstring. A strict insert fails on the
first type or field GridDB cannot store.
"""

import json
import sys

import pytest

from conftest import REPO_ROOT, SCHEMA_DIR, SCHEMAS_PATH, SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
sys.path.insert(0, str(REPO_ROOT / "sdk" / "python" / "src"))
import sienna_griddb_tools as griddb
import synthetic_document as synthetic


@pytest.fixture(scope="module")
def generated(db):
    return synthetic.synthetic_document(db, str(SCHEMAS_PATH))


def test_every_supported_component_type_is_generated(generated):
    doc, _ = generated
    manifest = json.loads((SCHEMA_DIR / "insert_manifest.json").read_text("utf-8"))
    assert set(doc["components"]) == set(manifest["components"])


def test_synthetic_document_inserts_every_component(generated, tmp_path):
    doc, tables = generated
    conn = griddb.create_database(str(tmp_path / "synthetic.sqlite"))
    try:
        report = griddb.insert_document(conn, doc, strict=True)
        expected = {name: len(objs) for name, objs in doc["components"].items()}
        assert report.inserted == expected
        assert report.skipped_fields == {}
        assert report.unsupported == {}
        for table in set(tables.values()):
            stored = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            generated_rows = sum(n for name, n in expected.items() if tables[name] == table)
            assert stored == generated_rows, table
        manifest = json.loads((SCHEMA_DIR / "insert_manifest.json").read_text("utf-8"))
        attribute_values = sum(
            obj.get(a["field"]) is not None
            for name, objs in doc["components"].items()
            for obj in objs
            for a in manifest["components"][name]["attributes"]
        )
        assert attribute_values > 0
        stored = conn.execute("SELECT count(*) FROM attributes").fetchone()[0]
        assert stored == attribute_values
    finally:
        conn.close()

