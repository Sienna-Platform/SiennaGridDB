# SiennaGridDB

Schema for the SQL database for Sienna Applications

> [!IMPORTANT]
> The griddb schema was designed using SQLite 3.45 to use some of the jsonb
> functionality. We do not intend to provide backwards compatibility since when
> we deisgined this 3.45 had already a year of being deployed.

## How To(s)

### How to install `just`

> [!NOTE]
> The recommended method to install just is using cargo.
> However, there are multiple ways of installing it see the `just` documentation for [just](https://github.com/casey/just)

```console
cargo install just
```

### Create a database with the schema

```console
just new-db              # builds griddb-example.sqlite
just new-db $DB_NAME     # or a database of your choosing
```

`new-db` runs the whole chain in order — schema, triggers, unit registry, views — then
prints a row count. `just` is optional; the underlying commands are four `sqlite3` calls:

```console
for f in schema.sql triggers.sql unit_registry.sql views.sql; do sqlite3 $DB_NAME < schema/$f; done
```

## Units

The schema stores physical quantities in **natural units** — MW, MVAr, MVA, kV, and so
on — with one deliberate exception: branch and device electrical parameters
(`transmission_lines.r`/`x`/`b`/`g`, `transformer_circuits.r`/`x`, admittances, HVDC
resistances, and similar) are **stored flexibly in per-unit on a component base OR
natural units**. A per-row discriminator column, `unit_basis`
(`COMPONENT_BASE` | `NATURAL_UNITS`), records which basis a row uses. `r`/`x` are scalar
`REAL`; `b`/`g` are JSON `{from, to}` shunt halves (stored as `json_valid`-checked text).
Costs stay in natural currency units, and `operation_cost` JSON blobs must carry
`NATURAL_UNITS`.

### The unit registry

Four tables record which unit every column carries and hold the vocabulary that constrains
them:

| Table | Role |
|---|---|
| `quantity_types` | The physical quantities (e.g. `ActivePower`, `Voltage`, `Impedance`), each with a dimension. |
| `allowed_units` | The units permitted for each quantity type (e.g. `MW` for `ActivePower`). |
| `unit_conventions` | The column→(quantity_type, unit) map: one row per physical column, JSON-path "column" (e.g. `operation_cost.fixed`), or attribute-name convention. |
| `column_units` (view) | Joins `unit_conventions` with `quantity_types` to show table, column, unit, quantity, and dimension in one place. |

Some columns are deliberately *not* registered. A convention's `discriminator_column`
names a sibling column, so a field whose unit depends on a basis choice or a control mode
cannot be registered once it lives in the generic `attributes` table — the sibling is an
attribute too, not a column. Those rows carry their own `attributes.unit` and
`attributes.quantity_type` instead, validated against `allowed_units` on write. This is
how the point-to-point HVDC fields (LCC impedances, VSC setpoints) are handled.

Current registry: **39 quantity types, 46 allowed units, 133 conventions.**

The generator refuses any `(quantity_type, unit)` pair absent from the shared vocabulary
in `Core/units.json`, so the registry can never drift from the source of truth.

### Time-series units

`time_series_metadata` carries a `unit` column, so units are recorded **per series** rather
than assumed schema-wide.

### Regenerate

`schema/unit_registry.sql` is generated from two inputs: the shared vocabulary in
SiennaSchemas' `Core/units.json` and this repo's column map `schema/column_conventions.json`.
Regenerate it after either input changes:

```console
python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json
```

### Verify

The generated registry is **sha256-sealed**. Verify a built database against its seal:

```console
python3 scripts/verify_unit_registry.py $DB_NAME
just verify-registry            # same, via the recipe
```

Verification hashes a canonical byte representation of the live registry rows and compares
it to the sealed checksum.

> [!IMPORTANT]
> The seal protects against **accidental** edits. SQLite has no privilege model, so a
> determined editor can rewrite both the rows and the seal. The guarantee here is
> **verification via the sha256 seal, not prevention** — run `verify-registry` to detect
> tampering; it cannot be stopped at write time.

### Cross-repo sync

`Core/units.json` (SiennaSchemas) and this registry must stay in lockstep. The sync check
resolves every convention row to the same-named schema property (via `schema/schema_map.json`)
and flags contradictions:

```console
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --db $DB_NAME
```

A **contradiction** (a mapped column with a different unit on each side) fails the check;
a **gap** (an unmapped column or unannotated property) is only a warning. `schema_map.json`
records the DB-table → SiennaSchemas-component mapping the check walks, and marks which
components also correspond to a PowerSystems.jl struct for the optional PSY-descriptor layer.

### Generated DDL (SQL codegen from the JSON Schemas)

Just as the OpenAPI specs generate the Python and Julia model packages, the JSON Schemas
generate SQLite DDL here. `scripts/generate_sql_schema.py` projects the components mapped
in `schema/schema_map.json` into `schema/generated_schema.sql`, applying the DB-specific
config in `schema/sql_codegen_map.json` (column renames, foreign keys, and the
attribute-channel property lists — e.g. the `two_terminal_hvdc_lines` converter
fields live in the `attributes` table, not as columns). The generated file is a **reference projection**: the production
DDL remains the hand-written `schema/schema.sql`, and the two are compared mechanically:

```console
python3 scripts/generate_sql_schema.py           # regenerate
python3 scripts/generate_sql_schema.py --check   # staleness gate (CI)
python3 scripts/generate_sql_schema.py --diff    # drift report vs schema.sql
```

`--diff` fails only on type contradictions for same-named columns; coverage gaps
(schema properties without DB columns, and vice versa) are reported as drift lines.

## Contributing

### Set pre-commit environment

Install a virtual environment

```console
python -m venv .venv
```

Setup the python environment

```console
python -m pip install -r requirements.txt
```

Setup pre-commit to run automatically on each commit.

```console
pre-commit install
```
