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
Costs stay in natural currency units, and the cost JSON blobs must carry
`NATURAL_UNITS`. The schemas' one `OperationalCost` object is stored verbatim in
`operation_cost` on the generator tables, `variable_operation_cost` member included.
`production_cost` is a `GENERATED ALWAYS AS` column deriving
`json_extract(operation_cost, '$.variable_operation_cost')` -- a queryable column for
the curve (the part that gets read, compared and repriced) with zero stored
duplication. Cost objects without a single production curve (storage, sources) stay
whole in `operation_cost`/`operation_costs`.

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

Current registry: **41 quantity types, 66 allowed units, 402 conventions.**

The generator refuses any `(quantity_type, unit)` pair absent from the shared vocabulary in
`Core/units.json`, so the registry can never drift from the source of truth: `Core/units.json`
is the **sole vocabulary authority** — see SiennaSchemas'
[Units](https://sienna-platform.github.io/SiennaSchemas/units/) page for how to read it, and
[UNIT_ANNOTATIONS.md](https://github.com/Sienna-Platform/SiennaSchemas/blob/main/docs/UNIT_ANNOTATIONS.md)
for how a new unit gets added there — and every table below is a generated,
sha256-sealed **mirror** of it, never a second source.

### Reading a value: where do I look?

Four different things determine how a stored value reads, and each is looked up differently.

- **A column with one fixed unit** (e.g. `transmission_lines.continuous_rating`) — look it up
  in `unit_conventions` (or the joined `column_units` view) by `table_name`/`column_name`; its
  `unit` is the whole answer, with no row-by-row variation.

  *Worked example:* `column_units` has one row for `(transmission_lines,
  continuous_rating)` → `unit = MVA`, `quantity_type = ApparentPower`. Every
  `continuous_rating` value in `transmission_lines` is megavolt-amperes.

- **A column discriminated by `unit_basis`** (the branch/device electrical parameters —
  `transmission_lines.r`/`x`/`b`/`g`, `transformer_circuits.r`/`x`, admittances, HVDC
  impedances) — `unit_conventions` carries one row per `unit_basis` value for that column.
  Read the row's own `unit_basis` first, then the same row's own base column —
  `base_power` for power/impedance quantities, `base_voltage` for voltage quantities (e.g.
  `sources.internal_voltage`, always stored as `pu` against the row's own `base_voltage`) —
  never a system-wide table.

  *Worked example:* `transmission_lines.r` has two `unit_conventions` rows — `unit_basis =
  COMPONENT_BASE` → `unit = pu`, `unit_basis = NATURAL_UNITS` → `unit = ohm`. A row with
  `unit_basis = 'COMPONENT_BASE'`, `r = 0.02`, `base_power = 100` reads as 0.02 pu on a
  100 MVA base; the same line with `unit_basis = 'NATURAL_UNITS'` would carry `r` directly
  in ohm.

- **A time-series association row** — the canonical unit lives on `time_series_metadata`
  (joined by `time_series_uuid`/`uuid`), not on `time_series_associations` itself; see
  [Time-series units](#time-series-units) below.

  *Worked example:* series `uuid = 'a1b2...'` has `time_series_metadata.unit = 'MW'`,
  `quantity_type = 'ActivePower'` — every value in that series is megawatts, regardless of
  what (if anything) the deprecated `time_series_associations.units` says for the same uuid.

- **A cost JSON payload** (`operation_cost` / `operation_costs` / `production_cost`) — its own
  embedded `power_units` key, at whatever nesting the cost shape puts it (e.g.
  `production_cost.power_units`, or `operation_cost.curtailment_cost.power_units` on
  `renewable_generators`). Per-table triggers **require it to be `NATURAL_UNITS`** — the DB
  stores no base to interpret a relative one, so `COMPONENT_BASE` (legal at the JSON Schema
  layer) is rejected here.

  *Worked example:* `thermal_generators.production_cost` with
  `json_extract(production_cost, '$.power_units') = 'NATURAL_UNITS'` reads its
  `variable_operation_cost` curve directly in MW/MWh; an INSERT with `'COMPONENT_BASE'` there
  is rejected by the `validate_thermal_generators_cost_units_insert` trigger.

**Stage-2 territory:** a generic basis-resolution table (sketched on sibling branches as
`unit_basis_rules`, mapping a quantity type to the expression that resolves its base) is not
part of this branch's DDL — no such table exists here yet, so there is no schema.sql entry to
carry. Today, resolution is exactly the two same-row lookups above (`unit_basis` +
`base_power`/`base_voltage`); nothing generic sits behind them yet.

### Time-series units

`time_series_metadata` — one row per series, keyed by `uuid` — carries `unit` and
`quantity_type`, so units are recorded **per series** rather than assumed schema-wide.
`time_series_associations` also carries a `units` column, but it is **deprecated** in favor
of `time_series_metadata.unit`. A trigger only checks the two agree when `units` is set —
read `time_series_metadata` directly.

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

## Code generation

Two independent generators project SiennaSchemas into this repo. Neither is authoritative
over the hand-written DDL — both are checked against it instead.

| Generated from | Generator | Output | Authoritative? |
|---|---|---|---|
| SiennaSchemas JSON Schemas, via `schema/schema_map.json` × `schema/sql_codegen_map.json` | `scripts/generate_sql_schema.py` | `schema/generated_schema.sql` | No — a reference projection, diffed against `schema/schema.sql` |
| SiennaSchemas `Core/units.json` × `schema/column_conventions.json` | `scripts/generate_unit_registry.py` | `schema/unit_registry.sql` (sha256-sealed) | Yes — loaded verbatim; see [The unit registry](#the-unit-registry) |

Hand-written, not generated: `schema/schema.sql` (production DDL) and `schema/triggers.sql`
(validation triggers). `schema.sql` does not consume `generated_schema.sql` at build time —
`--diff` is a drift *report*, not a build dependency; see
[Generated DDL](#generated-ddl-sql-codegen-from-the-json-schemas) above for how the two relate.

### Mapping and config files

- **`schema/schema_map.json`** — DB table → SiennaSchemas component(s). Consumed by
  `generate_sql_schema.py` and `check_units_sync.py` to resolve a column back to its schema
  property (and, via `is_psy`, to a PowerSystems.jl struct).
- **`schema/sql_codegen_map.json`** — DB-specific codegen config: column renames,
  foreign-key clauses, which properties live in the generic `attributes` table instead of a
  dedicated column, which are intentionally not persisted, and which hand-written columns
  have no schema property at all (so the drift gate doesn't flag them as missing).
- **`schema/column_conventions.json`** — DB-owned column → `(quantity_type, unit)` map; the
  input `generate_unit_registry.py` seeds `unit_conventions` from, alongside `Core/units.json`.
- **`schema/coverage_decisions.json`** — a proposal (awaiting sign-off) recording, for every
  schema property with no column in `schema.sql`, what should happen to it (new column,
  `attributes` entry, rename, decomposed, or skip); intended to be enforced by
  `scripts/check_coverage.py`, which does not exist in this checkout yet.

### Sync gates, and when to run them

Run these after touching `Core/units.json` upstream, `schema/schema.sql`, or any mapping file
above — and always before opening a PR that touches any of them:

```console
python3 scripts/verify_unit_registry.py $DB_NAME                                        # registry content matches its own seal
python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas --check --diff    # DDL staleness + drift vs schema.sql
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --db $DB_NAME        # 3-layer unit consistency: schemas <-> registry <-> DB (add --psy-path for the PSY layer)
```

`generate_unit_registry.py` has no built-in `--check`; CI proves registry staleness the blunt
way instead — regenerate, then `git diff --exit-code schema/unit_registry.sql`. All of the
above run in CI
([`.github/workflows/sqlite-schema-tests.yml`](.github/workflows/sqlite-schema-tests.yml))
on every push and pull request.

### Never hand-edit generated output

`schema/generated_schema.sql` opens `-- GENERATED FILE -- DO NOT EDIT.`; `schema/unit_registry.sql`
opens `-- Unit Registry Seed Data (GENERATED -- do not edit by hand)`. Change the source
instead — a schema in SiennaSchemas, `Core/units.json`, or one of the mapping files above —
then regenerate.

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
