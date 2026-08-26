# SiennaGridDB ⇄ SiennaSchemas: time-varying costs and association consistency

**Goal — schema consistency.** Absorb the three SiennaSchemas commits that added the
time-series-backed cost family and the minted `association_id`, and reconcile
`time_series_associations` with infrastore's catalog. Export-path research is recorded in Part C
but is **not** in scope; no emitter is built here.

**Upstream baseline.** SiennaSchemas `feat/association-id` = `108f3c1` (main `3207dbd` + `731aa30`,
`53fdb0e`, `108f3c1`). GridDB `main` at `b6f8b8d` plus the uncommitted working tree.

**Measured state (2026-08-26, fresh build). All four gates already pass:**

| Gate | Result |
|---|---|
| `just new-db` | clean, `PRAGMA user_version` = 11 |
| `verify_unit_registry.py` | MATCH, seal `cc3b3ed5…`; regeneration is byte-identical (not stale) |
| `generate_sql_schema.py --check` | exit 0, up to date; 113 coverage-gap lines reported by `--diff` |
| `check_units_sync.py` (3 layers) | **0 FAIL**, 77 WARN |
| `pytest test/` | **255 passed** |

The 2026-08-24 serde-sync plan's Tasks 1–7 have landed. **The gates are green but blind to this
change set**: every `operation_cost.*` row is a "structurally-exempt JSON-path" WARN, so the
checker never descends into the cost blob, and the new cost types are invisible to it.

---

## Part A — absorb the time-varying cost family

### Task 1 — `association_id`: the keystone

Upstream `53fdb0e` made store-minted association ids a *payload* value: `TIME_SERIES_*` function
data carries `association_id`, `FuelCurve` carries `fuel_cost_time_series`,
`MarketBidTimeSeriesCost` carries `start_up_association_id`, and
`TimeSeries{Incremental,AverageRate}Curve` carry `initial_input_association_id` /
`input_at_zero_association_id`. `108f3c1` marked the field `readOnly` on the six wire schemas,
where it is also `required`.

GridDB has **no `association_id` column** (grep across `schema/`, `test/`, `scripts/`: zero hits).
infrastore has one, plus the sequence that mints it:

```
crates/infrastore-core/src/metadata/schema.rs:27   association_id    INTEGER NOT NULL,
crates/infrastore-core/src/metadata/schema.rs:207  CREATE UNIQUE INDEX ... uq_ts_assoc_id ON time_series_associations(association_id);
crates/infrastore-core/src/metadata/schema.rs:323  CREATE TABLE ... association_id_sequence (next_association_id INTEGER NOT NULL);
```

infrastore's own comment states the reason: *"PSY persists these in exported documents."* Without
the column, a GridDB cost blob holds an integer with nothing in the database to resolve it against.
`time_series_associations.id` is not a substitute — it is a bare rowid SQLite may reuse after a
delete, which is precisely the failure the minted id exists to prevent.

1. Add `association_id INTEGER NOT NULL` to `time_series_associations`, positioned after `id` to
   match infrastore's ordinal layout.
2. Add `CREATE UNIQUE INDEX uq_ts_assoc_id ON time_series_associations (association_id);`.
3. Add `association_id_sequence (next_association_id INTEGER NOT NULL)` seeded to 1, mirroring
   schema.rs:323-325, so a GridDB-authored association gets an id from the same contract.
4. Project `association_id` in the `time_series_readable` view (infrastore selects it second).

**Decision required (A1):** whether GridDB *mints* ids (own sequence, Task 1.3) or only *carries*
ids minted by an upstream store. Minting means two producers can allocate the same id for different
series; carrying means the column is populated only on import. I recommend carrying-plus-sequence:
the sequence exists so a DB-authored series is well-formed, and the merge story is deferred rather
than silently wrong. This changes nothing else in the plan either way.

### Task 2 — widen the `curve_type` CHECK

Upstream `ValueCurve` grew from three mapped types to six: `INPUT_OUTPUT`, `INCREMENTAL`,
`AVERAGE_RATE`, `TIME_SERIES_INPUT_OUTPUT`, `TIME_SERIES_INCREMENTAL`, `TIME_SERIES_AVERAGE_RATE`.
GridDB rejects the three new ones:

```
schema/schema.sql:397-398   CHECK (ifnull(json_extract(production_cost, '$.value_curve.curve_type'), '')
schema/schema.sql:482-483       IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE'))
```

Widen both (thermal_generators, renewable_generators) to the six. Keep the `ifnull` wrapper — an
absent key must still fail. `variable_cost_type` stays `('COST','FUEL')`: upstream
`ProductionVariableCostCurve` still maps exactly those two.

### Task 3 — `FuelCurve`: `fuel_cost` xor `fuel_cost_time_series`

Upstream replaced the untyped `oneOf[string, number]` `fuel_cost` with two orthogonal nullable
fields and **removed `fuel_cost` from `required`**. GridDB still demands the fixed number:

```
schema/schema.sql:400-401   CHECK (json_extract(production_cost, '$.variable_cost_type') <> 'FUEL'
schema/schema.sql:484-485       OR json_extract(production_cost, '$.fuel_cost') IS NOT NULL),
```

A time-varying fuel price is rejected today. Replace with an exactly-one-of check on both tables:
FUEL requires exactly one of `$.fuel_cost` / `$.fuel_cost_time_series` to be non-null. The upstream
"exactly one is set" rule is description-only (no `oneOf`, no `dependentSchemas`), so the DB CHECK
is the only place it can actually be enforced — worth stating in the DDL comment.

### Task 4 — the two new `cost_type` variants

`MarketBidTimeSeriesCost` (`MARKET_BID_TIME_SERIES`) and `ImportExportTimeSeriesCost`
(`IMPORT_EXPORT_TIME_SERIES`) join the `operation_cost` discriminator on twelve components,
spanning six GridDB tables: `thermal_generators`, `renewable_generators`, `hydro_generators`,
`storage_units`, `hydro_reservoirs`, `sources`. (The three affected load types map to `loads`,
whose `operation_cost` is dispositioned `attribute` in `coverage_decisions.json` — it rides the
generic `attributes` blob and needs no table change.)

- `ImportExportTimeSeriesCost.energy_import_weekly_limit` / `energy_export_weekly_limit` are the
  only two `x-unit` annotations in the whole change set (`MWh`). GridDB already registers exactly
  these two paths on `sources`; confirm no second table needs them.
- Every other new property is an association id or a curve — no new `unit_conventions` rows, and
  `Core/units.json` is unchanged by all three commits (41 quantity types, 62 allowed units).
- Audit the existing `operation_cost` CHECKs (`json_extract(operation_cost,'$.variable') IS NULL`)
  against the new payload shapes so a valid `MARKET_BID_TIME_SERIES` blob is not rejected.

**Decision required (A2):** whether `operation_cost.cost_type` gains a CHECK enumerating the
admissible variants per table. Today there is none, so a typo'd `cost_type` stores silently. The
new 4-way discriminators make this more consequential. Recommend adding it; it is the same
`ifnull(...) IN (...)` pattern already used for `production_cost`.

### Task 5 — `scenario_count`

`TimeSeries/Scenarios.json` requires `scenario_count` alongside `count`. GridDB has no such column
(`grep scenario_count schema/` → zero hits), so a `Scenarios` association cannot round-trip. Add
`scenario_count INTEGER` (nullable — it is meaningful only for `time_series_type = 5`).

Note this is a GridDB-vs-**schemas** gap, not a GridDB-vs-infrastore one: infrastore's catalog has
no `scenario_count` either. Raise it upstream in infrastore (Part D).

### Task 6 — regenerate and re-seal

1. `python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json`.
2. Bump `PRAGMA user_version` 11 → 12, **exactly once** across the whole change set.
3. Re-run `generate_sql_schema.py` if the reference projection moves.

### Task 7 — tests

- `test/test_cost_and_source_coverage.py:377` `test_fuel_curve_without_fuel_cost_is_rejected`
  asserts the pre-`53fdb0e` rule. Rewrite as three cases: fixed-only accepted, time-series-only
  accepted, neither rejected, both rejected.
- New: each of the three `TIME_SERIES_*` curve types is accepted in `production_cost`.
- New: a `Scenarios` association round-trips with `scenario_count`.
- New: `association_id` uniqueness, and that the `time_series_readable` view projects it.
- Re-measure the four registry table counts from the fresh build rather than hand-computing.

### Task 8 — CI pin and docs

`.github/workflows/sqlite-schema-tests.yml:20-25` pins SiennaSchemas to `ref: jm/units`, which
predates all three commits. CI is therefore green against a schema that no longer exists upstream.
Move the pin to the branch/tag carrying `108f3c1`. Update `README.md` §Time-series units and
`docs/units-architecture.md` §2/§4 (the ER diagram and the association field list both need
`association_id` and `scenario_count`).

---

## Part B — association audit: GridDB vs infrastore

Verified against `crates/infrastore-core/src/metadata/schema.rs` directly. **22 of 25 columns match
exactly.** `feature_sets`, `timestamp_sets`, and `supplemental_attribute_associations` match
column-for-column and index-for-index (modulo `strict` and GridDB's FKs). All enum encodings agree:
`owner_category` 0/1, `time_series_type` 0–5, `element_type` default `'f64'`, and `unit_system` in
infrastore's **lowercase** `natural_units`/`component_base` spelling.

Open divergences, each needing a ruling:

| # | Column / object | infrastore | GridDB | Note |
|---|---|---|---|---|
| B1 | `association_id` | `INTEGER NOT NULL` + unique index + sequence | absent | **Task 1** |
| B2 | `uri` | absent | `TEXT NOT NULL`, non-unique `idx_uri` | GridDB follows the wire form; infrastore locates values in HDF5 |
| B3 | `data_hash` | `BLOB NOT NULL`, full index | `BLOB` nullable, partial index | prior decision: wire form wins |
| B4 | `element_shape` | `TEXT` nullable, no CHECK | `TEXT NOT NULL DEFAULT '[]' CHECK(json_valid())` | prior decision: wire form wins |
| B5 | `scenario_count` | absent | absent | required by `Scenarios.json`; **both** sides are behind |
| B6 | `parent_child_associations` | present, generic `(parent, child)` | absent | GridDB has three *richer* domain tables instead (`plant_associations` w/ `group_index`, `combined_cycle_associations` w/ `role`+`hrsg_index`, `hydro_reservoir_connections`). Not a defect — but nothing projects them into the store's shape |
| B7 | `uri` uniqueness | n/a | **not UNIQUE** | `static_time_series` triggers treat it as a lookup key, and `docs/units-architecture.md` §4 says arrays shared by many associations are stored once — so non-unique is deliberate. Worth stating in the DDL comment; today it reads as an oversight |
| B8 | idempotency | `CREATE ... IF NOT EXISTS`, additive | `DROP TABLE IF EXISTS` + `CREATE` | GridDB's schema is drop-and-recreate by design (already flagged in `.claude/CLAUDE.md`) |

B2–B4 and B6–B8 are settled or deliberate; the deliverable is documenting them in the DDL comment
block at `schema/schema.sql:767-796` so the next reader does not re-litigate them. B1 and B5 are
real work (Tasks 1 and 5).

---

## Part C — export path: findings recorded, not in scope

No exporter exists, and this effort does not start one. The research below is recorded so it is not
re-done; none of it is a task here.

**The format is `system.json` + one HDF5 values sidecar.** Time-series associations serialize and
deserialize through the schemas like any other association —
`SystemDocument.time_series_associations` is an array of the six-variant
`TimeSeries/TimeSeriesAssociation.json`, typed concretely at
`PowerOpenAPIModels.jl/src/document.jl:84` and read back at `:727`. `document.jl:25-27`: *"This file
NEVER touches time series values… Reading or writing that HDF5 file belongs to the consumer."* The
`time_series.h5.sqlite` beside a PSB case is infrastore's internal catalog, written because
`IS.serialize(store, path)` persists a store — not a member of the document contract.

**This is why Part A matters beyond the cost blob.** `time_series_associations` already mirrors
infrastore's catalog column-for-column, and that same row shape is what the wire schema carries, so
emitting the association array is close to a projection. Tasks 1 and 5 (`association_id`,
`scenario_count`) are the two columns standing between the current row and a valid wire object. The
remaining differences are mechanical encodings — integer codes → names, `features_hash` →
`feature_sets` join, BLOB → hex, `percentiles_json` → `percentiles`.

`uri` is **not** a portability problem. The wire schema: *"No required format — typically a file
path or an HDF5 dataset path; the backing store decides what it means and resolves it (infrastore
uses its content hash as this value). Never parsed or interpreted here."* A GridDB-chosen `uri` is
legal.

Gaps that would block an emitter, for whenever one is written:

| | Gap | Evidence |
|---|---|---|
| C1 | `static_time_series` is `(uri, idx, value REAL)` — scalars only. `element_type` admits `tuple(N,dtype)`, `piecewise_linear`, function-data kinds; Probabilistic/Scenarios are 2-D. The new time-series-backed cost curves are exactly this case | `schema.sql:1137-1142` |
| C2 | `entity_types` is never seeded — zero rows in a fresh build, zero `INSERT` statements — so `entities.entity_type` is unvalidated free text, and it is the only discriminator (`schema_map.json` is one-to-many). Real CATS data carries `Transformer2W` (title: `TwoWindingTransformer`) and `ExistingCapacity` (`ExistingDevices`) | verified |
| C3 | 113 "schema property has no DB column" lines. `loads` is `(id, name, balancing_topology, base_power)` — no `available`, no `active_power` | `generate_sql_schema.py --check --diff` |
| C4 | `coverage_decisions.json` is a proposal awaiting sign-off (221 dispositions) and names `scripts/check_coverage.py` as its enforcer — that script does not exist | verified |
| C5 | No `systems`/`cases` table, so `base_power`/`unit_system` have no home. A recorded decision, not an oversight. Sharper: `unit_system` is one value per document, `unit_basis` is per row on eight tables | `docs/units-architecture.md:225-233` |
| C6 | `service_associations` is a required document key; no services tables and no membership table exist. Also strands `ancillary_service_offers` on both market-bid cost types | `.claude/CLAUDE.md` |
| C7 | All three CATS databases are pre-migration — `user_version` 0/9/9, still on `time_series_uuid`/`metadata_uuid`/`window_count`. ~8532 associations, ~56.5M value rows | verified |

C1 is the one that touches this effort: the new cost curves resolve to non-scalar series that
`static_time_series` cannot hold. Task 5b addresses it minimally.

## Part D — raise upstream (not GridDB edits)

- **infrastore**: `scenario_count` is absent from the catalog but required by
  `TimeSeries/Scenarios.json`. (`uri` is *not* an infrastore gap — the catalog derives it at export
  from `data_hash`, which the schema explicitly permits.)
- **SiennaSchemas**: `SystemDocument.json`'s `time_series_associations` description still says each
  row "names the store holding its values in its own `address`". `address` was renamed to `uri` in
  `c8c2428`; the prose was not updated.
- **SiennaSchemas**: `FACTSControlDevice.max_reactive_power` — PSY marks it `needs_conversion
  (:mva)`, the schema property has no `x-unit`. The single remaining L3 WARN.
- **SiennaSchemas**: `Source.json`'s `operation_cost` description reads "…or MarketBidCost", but
  `MarketBidCost` is in neither the discriminator mapping nor the `oneOf`.
- **Merge order** is load-bearing: tag a SiennaSchemas release carrying `108f3c1` (with
  `units.json` and `dist/`) **before** GridDB's PR merges, then move the CI pin (Task 8).

---

## Gate run

```sh
just new-db
python3 scripts/verify_unit_registry.py griddb-example.sqlite
python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas --check --diff
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl --db griddb-example.sqlite
python3 scripts/check_coverage.py            # new, Task C3
../.venv/bin/python3 -m pytest test/ -q
```

Report sync FAIL/WARN counts and the pytest pass count. `PRAGMA user_version` bumped exactly once.

## Open decisions, collected

| id | Decision | Recommendation |
|---|---|---|
| A1 | Does GridDB mint `association_id` or only carry it? | Carry + seed a sequence for DB-authored rows |
| A2 | Add a CHECK on `operation_cost.cost_type`? | Yes, matching the `production_cost` pattern |
| C1 | Sign off `coverage_decisions.json` so `check_coverage.py` has a spec | Needed before C3 lands |
| C2 | Non-scalar time-series values | Option 1: reject them in GridDB, store outside |
| C5 | One-row `systems` table, or emitter arguments for `base_power`/`unit_system`? | Arguments — but the per-row `unit_basis` → per-document `unit_system` rule must be written either way |

## Out of scope

- The PSY `System` ⇄ GridDB converter. Part C closes preconditions; it builds nothing.
- Landing the uncommitted two-basis working tree — a separate call.
