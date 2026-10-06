# SiennaGridDB

Schema for the SQL database for Sienna Applications

> [!IMPORTANT]
> This schema requires SQLite 3.45+ for jsonb support, with no earlier version targeted.

## What this repository ships

The product is **SQL**, not a Python package. `schema/` holds the four files that build a
database — `schema.sql` (tables), `triggers.sql` (integrity), `unit_registry.sql`
(the generated, sha256-sealed unit vocabulary) and `views.sql` — and `scripts/` holds the
Python tooling that generates and verifies them. Nothing here is importable; the
`pyproject.toml` exists to set up the dev environment and host the linter config.

A release is a tarball attached to a `v*` GitHub Release, containing `schema/`,
`scripts/`, `README.md`, `LICENSE` and `.justfile` under a single top-level directory:

```console
tar -xzf sienna-griddb-v0.1.0.tar.gz
cd sienna-griddb-v0.1.0
just new-db                     # or the four sqlite3 calls below
```

### Scope of 0.1

Read this before building on it:

- **Create-only.** There is no migration path. `schema/schema.sql` opens by dropping every
  table, so it builds a new database and must never be applied to one holding data.
  `PRAGMA user_version` is bumped on every schema change but nothing reads it.
- **Roughly half the data model is typed.**
  Dynamics and the investment policy layer have no tables; see the open coverage issue.
- **The unit registry is the load-bearing deliverable.**
  Its column conventions are sealed, tamper-guarded, and readable through the `column_units` view as an authoritative `(table, column) -> (quantity_kind, unit, basis rule)` map.

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

## Foreign keys

**Every connection must set `PRAGMA foreign_keys = ON`.** SQLite defaults it OFF
per connection and does not store it in the file, so a database built by
`just new-db` reports `foreign_keys = 0` when you next open it, and every
foreign key in this schema is inert until you turn it on:

```sh
sqlite3 griddb-example.sqlite "PRAGMA foreign_keys = ON; ..."
```

```python
conn = sqlite3.connect("griddb-example.sqlite")
conn.execute("PRAGMA foreign_keys = ON")   # required, every connection
```

The `PRAGMA foreign_keys = ON` at the top of `schema/schema.sql` governs the
build connection only. There is no file-level equivalent. `ON DELETE CASCADE`
also does nothing without it, so deleting a parent row silently orphans its
children rather than removing them.

## Units

The schema stores physical quantities in **natural units** — MW, MVAr, MVA, kV, and so
on — with one deliberate exception: branch and device electrical parameters
(`transmission_lines.r`/`x`/`b`/`g`, `transformer_circuits.r`/`x`, admittances, HVDC
resistances, and similar) are **stored flexibly in per-unit on a component base OR
natural units**. A per-row discriminator column, `parameter_units`
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
See `docs/units-architecture.md` §5 for the full two-axis design, including how a
`COMPONENT_BASE` row resolves its base without leaving the database.

### The unit registry

Four tables record which unit every column carries and hold the vocabulary that constrains
them:

| Table | Role |
|---|---|
| `quantity_kinds` | The physical quantities (e.g. `ActivePower`, `Voltage`, `Impedance`), each with a dimension. |
| `allowed_units` | The units permitted for each quantity kind (e.g. `MW` for `ActivePower`). |
| `unit_conventions` | The column→(quantity_kind, unit) map: one row per physical column, JSON-path "column" (e.g. `operation_cost.fixed`), or attribute-name convention. |
| `unit_basis_rules` | For each of the 5 quantity kinds that ever carry `pu`, the base expression that resolves it (e.g. `Resistance` → `base_voltage^2/base_power`). |
| `column_units` (view) | Joins `unit_conventions` with `quantity_kinds` and `unit_basis_rules` to show table, column, unit, quantity, dimension, and base references in one place. |

**Columns vs. `attributes`.** `schema/sql_codegen_map.json` places every property of every
mapped component: a column, an `attributes` row, a split into DB-only columns, or not
stored. A field only some variants of a merged table carry (the LCC and VSC detail of
`two_terminal_hvdc_lines`, the ZIP breakdown of `loads`) goes to the generic `attributes`
table. Its unit convention is derived from the schema's annotation and registered as
`attributes.<name>`, one row per unit arm (`MW` and `pu` for a `power_units` field); the
insert trigger accepts any registered arm. A unitless structured attribute (a reference
list, a loss curve) gets an `attribute_identifiers` row instead. An `attributes` name means
one quantity kind everywhere; generation fails otherwise.

Current registry: **42 quantity kinds, 67 allowed units, 534 conventions.**

The generator refuses any `(quantity_kind, unit)` pair absent from the shared vocabulary in
`Core/units.json`, so the registry can never drift from the source of truth: `Core/units.json`
is the **sole vocabulary authority** — see SiennaSchemas'
[Units](https://sienna-platform.github.io/SiennaSchemas/units/) page for how to read it, and
[UNIT_ANNOTATIONS.md](https://github.com/Sienna-Platform/SiennaSchemas/blob/main/docs/UNIT_ANNOTATIONS.md)
for how a new unit gets added there — and every table below is a generated,
sha256-sealed **mirror** of it, never a second source.

### Reading a value: where do I look?

To resolve any column's unit:

1. **Look up the column** in `unit_conventions` (or the joined `column_units` view) by
   `table_name`/`column_name`.
2. **If more than one row comes back**, the column is discriminated — each row names a
   `discriminator_column` (e.g. `parameter_units`, `admittance_units`, `power_units`); match it
   against that same column's value on the row you're reading.
3. **Read the matched row's `unit`.** If it is `pu`, resolve it against the base column on
   the *same row* — `base_power` for power/impedance quantities, `base_voltage` for voltage
   quantities — never a system-wide table.

*Worked example:* `transmission_lines.r` has two `unit_conventions` rows, discriminated by
`parameter_units`: `COMPONENT_BASE` → `unit = pu`, `NATURAL_UNITS` → `unit = ohm`. A row with
`parameter_units = 'COMPONENT_BASE'`, `r = 0.02`, `base_power = 100` reads as 0.02 pu on a
100 MVA base; the same line with `parameter_units = 'NATURAL_UNITS'` would carry `r` directly
in ohm. A column with only one `unit_conventions` row (e.g.
`transmission_lines.continuous_rating` → `MVA`) skips step 2: that unit applies to every
row, unconditionally.

Two kinds of value sit outside `unit_conventions` entirely:

- **Time-series values** — the unit lives on `time_series_metadata` (joined by `uuid`), not
  on the row you're reading; see [Time-series units](#time-series-units) below.
- **Cost JSON payloads** (`operation_cost` / `production_cost`) — carry their own embedded
  `power_units` key. Triggers require it to be `NATURAL_UNITS`, since the DB stores no base
  to resolve `COMPONENT_BASE` against.

### Time-series units

`time_series_associations` carries `units`/`quantity_kind`/`unit_system` per association row,
mirroring infrastore's catalog so rows deserialize straight into a store, and `id` — the
store-minted id, carried verbatim, that a time-series-backed cost payload names its series by
under its wire spelling, `association_id`. `quantity_kind` is free-form (composite economic
quantities must not require a vocabulary change), but a row using a registered quantity-type
name is trigger-checked against `allowed_units` — see `docs/units-architecture.md` §4–6 for
the full contract.

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

### Generated tables (SQL codegen from the JSON Schemas)

Just as the OpenAPI specs generate the Python and Julia model packages, the JSON Schemas
generate the component tables here. `scripts/generate_sql_schema.py` writes every table
mapped in `schema/schema_map.json` into the marked region at the end of `schema/schema.sql`,
and writes the unit conventions of the generated columns into
`schema/column_conventions.json` (entries marked `"source": "schemas"`). Everything else in
those two files is hand-written.

Generation is closed-world. It fails, listing every problem, when a schema file is neither
mapped nor `excluded` in `schema_map.json`, when a component property has no disposition in
`sql_codegen_map.json`, or when a disposition names a property the schemas dropped. A schema
release that adds a component or a field therefore cannot land without a decision.

```console
just generate-schema                              # regenerate (default ../SiennaSchemas)
python3 scripts/generate_sql_schema.py --check    # staleness + closed-world gate (CI)
```

`.schema-version` pins the SiennaSchemas release. On each release,
[`update-schema.yml`](.github/workflows/update-schema.yml) regenerates and opens a PR; when
generation fails, the PR body lists the missing decisions.

## Association tables

A component's own table can hold a foreign key for a many-to-one relationship (a
generator's `bus` column, say), but a relationship where either side can have several
of the other — or where the link itself carries data, or where the "other side" spans
several different component tables — has no single column to hold it. `schema/schema.sql`
handles each of these cases with a dedicated association table: a row per link rather
than a column on either side. Six exist:

| Table | Links | Why it needs its own table |
|---|---|---|
| `supplemental_attribute_associations` | a component ↔ a supplemental attribute | a component can carry several attributes (geolocation, outage data, …), and the linked component can be any of the many concrete component tables — a single `component_id` column resolved through `entities` covers all of them without a dedicated FK per component type |
| `plant_associations` | a plant ↔ its member entities | a plant groups multiple generating units of varying concrete types, and the link carries a payload (`group_index`) that doesn't belong on the generic `entities` row or on any one device table |
| `combined_cycle_associations` | a plant ↔ the CT/CA units feeding into or receiving from its HRSGs | stated directly in the table's own comment: "a CT or CA can feed multiple HRSGs and an HRSG can have multiple CTs/CAs" — genuinely many-to-many, which is why it is a separate table from `plant_associations` rather than another row shape in it (`plant_associations` enforces one row per `(plant, entity)`, which this relationship violates) |
| `time_series_associations` | a time series ↔ the entity that owns it | one entity can own several time series (different resolutions, different features), and the association row is what makes a stored series queryable by owner without touching the series data itself |
| `trading_hub_associations` | a trading hub ↔ its member entities | a hub aggregates several settlement points and an entity can belong to more than one hub, so neither side can hold the link; `UNIQUE (trading_hub_id, entity_id)` keeps one row per membership |
| `service_associations` | a service (reserve or transmission interface) ↔ its members | a reserve draws on many devices and a device can serve several reserves, and members span device, branch and reserve tables; neither side carries a member list, so these rows are the only record of who contributes; `UNIQUE (service_id, entity_id)` keeps one row per membership |

Two of the six (`supplemental_attribute_associations`, `time_series_associations`)
resolve one side of the link through `entities` — the supertype table every component
row also has a row in (`id`, `entity_table`, `entity_type`) — so a single
`component_id`/`owner_id` column can point at a generator, a bus, or any other component
type without a separate FK per possible target. `plant_associations`, `combined_cycle_associations` and
`trading_hub_associations` reference `entities` the same way for their non-owning
side (`entity_id`); their owning side (`plant_id`) always points at `plants`, since that
side is never ambiguous. All six declare their FKs `ON DELETE CASCADE`, so a deleted
component or attribute takes its association rows with it rather than leaving orphans.

`service_associations` resolves both sides through `entities`, and triggers keep each side to its kind: a `reserves` or `transmission_interfaces` row as the service, and branches, reserves or devices as members, depending on the service.
Views in `views.sql` read it: `service_contributors`, `interface_branch_directions` (an interface's `direction_mapping` names resolved to its member branches) and `interface_direction_violations` (mapped names that resolve to none; empty for valid data), `service_bid_offers` and `service_bids` (the market bids devices place on reserves), and `service_offer_violations` (offers into a service the device is not a member of; empty for valid data).

`hydro_reservoir_connections` is association-shaped too, but it is listed with the hydro
topology rather than here: it links two reservoirs to each other, not a component to a
grouping, and its integrity is enforced by the hydro-topology triggers.

### Two ways to identify a row

An association table needs something to name one specific row by — for a caller to hold
onto, or for another table to reference. Which kind of identifier a table uses depends on
where the row's identity actually comes from.

**Mirror table with a store id** — `time_series_associations` — mirrors the catalog of an
external store: each row corresponds to an association the store already knows about and
already gave an id to. Carrying that id, rather than minting a competing one, is the whole
point — a caller working from the store's own reference needs to land on the same row here.
The table's `id INTEGER PRIMARY KEY AUTOINCREMENT` **is** that store-minted id, carried
verbatim, mirroring infrastore's own declaration column-for-column (confirmed against
infrastore's `schema.rs`); `AUTOINCREMENT` is legal on this STRICT table (confirmed on this
branch — see below) and stops SQLite from ever reissuing an id a delete freed, matching the
guarantee infrastore relies on for the same column. `association_id` is only this column's
*spelling on the wire* — the name SiennaSchemas payloads reference it by
(`TimeSeriesLinearFunctionData.association_id` and its siblings) — never a second stored
column. **The id is meaningful only against its origin store: resolve it against the source
store, and re-mint on import when aggregating rows from more than one — exactly what
infrastore's own `merge` does when copying series between stores (verified in
`infrastore-cli/src/commands/manage.rs`: "a merge re-adds the source's rows, so the
destination assigns them fresh ids from its own stream").**

**Mirror table with no store id** — `supplemental_attribute_associations` — mirrors the same
kind of external association, but infrastore's own wire row for it (`SaWireRow`) carries no
id: nothing references an attachment, so there is nothing to preserve, and an import mints a
fresh `id` every time. Identity here is the natural key, `(component_id, attribute_id)`
(`uq_sa_assoc`); `id` is an ordinary rowid, unlike `time_series_associations`' AUTOINCREMENT
column, because nothing outside GridDB ever holds a reference to it that a rowid reuse could
break.

**Native tables** — `plant_associations` and `combined_cycle_associations` — model a
relationship that exists only inside GridDB; no external store has an opinion about it, so
there is no borrowed id to carry. These mint their own instead: `id INTEGER PRIMARY KEY
AUTOINCREMENT`. Unlike a bare rowid, `AUTOINCREMENT` never reissues an id a delete has
freed — SQLite tracks the highest id a table has ever handed out and always allocates past
it — so a stored reference to row 47 either still means row 47 or fails to resolve; it can
never silently land on a different, unrelated row that later reused the same number. The
natural key — `UNIQUE (plant_id, entity_id)` on `plant_associations`, `UNIQUE (plant_id,
entity_id, hrsg_index)` on `combined_cycle_associations` — is kept alongside the surrogate,
so minting the id changes nothing about what identifies the relationship; it only adds a
stable handle for a row that already had an identity.

The split comes down to who is responsible for the id: `time_series_associations` preserves
the identifier its origin store already assigned; the other three mint their own, because
either the store gave no id (`supplemental_attribute_associations`) or the relationship
exists only inside GridDB with no external store to have an opinion (`plant_associations`,
`combined_cycle_associations`) — GridDB is the only source of truth for those ids, which is
exactly why it uses `AUTOINCREMENT` to guarantee them, the same guarantee infrastore's own
declaration relies on for `time_series_associations.id`.

Confirmed on this branch: `AUTOINCREMENT` is legal on a SQLite `STRICT` table, and deleting
the row holding the current maximum `id` in `plant_associations` (and, separately,
`time_series_associations`) and inserting a new row does not reuse the freed value — the new
row's `id` lands one past the highest ever issued, not one past what happens to be present.

### Payload columns

Beyond the link itself, most of the four carry columns that answer "which one, in what
order":

| Column | Table | Meaning |
|---|---|---|
| `group_index` | `plant_associations` | which sub-group of the plant the member belongs to — a shaft, penstock, point-of-common-coupling, or exclusion group, depending on the parent plant's own type |
| `role` | `combined_cycle_associations` | `'CT'` or `'CA'` — whether the linked unit feeds the HRSG (combustion turbine, an input) or receives from it (an output) |
| `hrsg_index` | `combined_cycle_associations` | which HRSG the linked unit feeds or receives from; part of the table's `UNIQUE (plant_id, entity_id, hrsg_index)` key, which is why the same unit can appear more than once — once per HRSG it participates in |
| `component_type`, `attribute_type` | `supplemental_attribute_associations` | denormalized labels for the component's and attribute's concrete tables, carried so a query can filter by kind without joining back to `entities`/`supplemental_attributes` |
| `owner_type` | `time_series_associations` | the owning component's concrete table name, denormalized for the same reason as above |
| `owner_category`, `time_series_type` | `time_series_associations` | `TEXT`, holding the wire spelling directly (`'Component'`/`'SupplementalAttribute'`; `'SingleTimeSeries'` through `'Scenarios'`) — compare against the string, no decoding needed |
| `name`, `resolution`, `interval`, `features_hash` | `time_series_associations` | together with `owner_id` and `owner_category`, form the tuple that actually identifies "which series" (`uq_ts_assoc`) |

### Querying them

Reconstruct a plant's membership by joining `plant_associations` back to the plant and to
`entities`:

```sql
SELECT p.name AS plant_name, e.entity_table, pa.entity_id, pa.group_index
FROM plant_associations pa
JOIN plants p ON p.id = pa.plant_id
JOIN entities e ON e.id = pa.entity_id
WHERE p.name = 'Plant A'
ORDER BY pa.group_index, pa.entity_id;
```

Find every CT/CA feeding a specific HRSG of a plant:

```sql
SELECT cca.entity_id, cca.role
FROM combined_cycle_associations cca
JOIN plants p ON p.id = cca.plant_id
WHERE p.name = 'Plant A' AND cca.hrsg_index = 0
ORDER BY cca.entity_id;
```

Both were run against a database built from `schema/schema.sql` + `triggers.sql` +
`unit_registry.sql` + `views.sql` on this branch.

## Code generation

Two generators project SiennaSchemas into this repo.

| Generated from | Generator | Output |
|---|---|---|
| SiennaSchemas JSON Schemas, via `schema/schema_map.json` × `schema/sql_codegen_map.json` | `scripts/generate_sql_schema.py` | the component tables in `schema/schema.sql`, and the `"source": "schemas"` entries of `schema/column_conventions.json` |
| SiennaSchemas `Core/units.json` × `schema/column_conventions.json` | `scripts/generate_unit_registry.py` | `schema/unit_registry.sql` (sha256-sealed) |

Hand-written: the rest of `schema/schema.sql` (entities, attributes, associations, time
series, the registry tables), `schema/triggers.sql`, and `schema/views.sql`.

### Mapping and config files

- **`schema/schema_map.json`** — DB table → SiennaSchemas component(s), plus `excluded`:
  each schema file with no generated table and the reason. Consumed by
  `generate_sql_schema.py` and `check_units_sync.py` (via `is_psy`, also the
  PowerSystems.jl struct).
- **`schema/sql_codegen_map.json`** — per table, the disposition of every component
  property (`columns` with overrides, `attribute_channel`, `decomposed`, `skip`), DB-only
  columns, table constraints, indexes, and comments. The file's `description` lists the
  override keys.
- **`schema/column_conventions.json`** — column → `(quantity_kind, unit)` map; the input
  `generate_unit_registry.py` seeds `unit_conventions` from, alongside `Core/units.json`.
  Entries for generated columns are derived; JSON-path and DB-only entries are hand-written.
- **`schema/coverage_decisions.json`** — the rules for choosing a disposition (column vs.
  attribute vs. skip). `sql_codegen_map.json` holds the enforced result.

### Sync gates, and when to run them

Run these after touching `Core/units.json` upstream, `schema/schema.sql`, or any mapping file
above — and always before opening a PR that touches any of them:

```console
python3 scripts/verify_unit_registry.py $DB_NAME                                        # registry content matches its own seal
python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas --check         # generated tables + closed-world gate
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --db $DB_NAME        # 3-layer unit consistency: schemas <-> registry <-> DB (add --psy-path for the PSY layer)
```

`generate_unit_registry.py` has no built-in `--check`; CI proves registry staleness the blunt
way instead — regenerate, then `git diff --exit-code schema/unit_registry.sql`. All of the
above run in CI
([`.github/workflows/sqlite-schema-tests.yml`](.github/workflows/sqlite-schema-tests.yml))
on every push and pull request.

### Never hand-edit generated output

The region between `-- BEGIN GENERATED COMPONENT TABLES` and `-- END GENERATED COMPONENT TABLES`
in `schema/schema.sql` and the `"source": "schemas"` convention entries are generated; `schema/unit_registry.sql`
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
