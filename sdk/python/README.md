# sienna-griddb-tools (Python)

Insert Sienna OpenAPI SDK objects (`power-openapi-models`) into a SiennaGridDB SQLite
database. The SQL comes from the bundled insert manifest; this package only binds values.

```python
from power_openapi_models.document import read_document
import sienna_griddb_tools as griddb

conn = griddb.create_database("system.sqlite")
report = griddb.insert_document(conn, read_document("system.json"))
print(report.to_json())   # inserted / skipped_fields / unsupported
```

- Fields GridDB has no column or attribute route for yet are counted in `report.skipped_fields`, not
  written. Pass `strict=True` to raise instead.
- Cost payloads must be in `NATURAL_UNITS`; the database rejects anything else.
  A load's `operation_cost` is the exception: it is stored verbatim as an attribute and is not unit-checked.
- CLI: `python3 -m sienna_griddb_tools build system.json system.sqlite`.
