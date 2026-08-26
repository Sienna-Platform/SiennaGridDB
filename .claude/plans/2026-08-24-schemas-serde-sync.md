# SiennaGridDB ⇄ SiennaSchemas Sync Plan (post-serde)

**Goal:** Absorb everything SiennaSchemas main changed since GridDB was frozen — the TimeSeries
schema package and serde alignment, the registry vocabulary changes, and the small enum/annotation
drift — so all four CI gates pass against upstream main (`3207dbd`).

**Baseline:** GridDB `main` at `b6f8b8d` **plus the uncommitted two-basis working tree** (the
2026-08-03 two-basis-units work). That work already absorbed `DEVICE_BASE → COMPONENT_BASE` and the
Duration/OperationalDuration/CalendarPeriod split. This plan builds on it as-is; landing it is a
separate call.

**Measured state (2026-08-24, fresh build):**

| Gate | Result |
|---|---|
| `just new-db` + `verify-registry` | pass, but checked-in `unit_registry.sql` is stale (regen = 360-line diff, 41 qt / 62 units / 334 conventions, seal `185c018e…`) |
| `check_units_sync` (3 layers) | **6 FAIL** (ThreeWindingTransformer r/x_12/23/31), 79 WARN (mostly structurally-exempt JSON paths) |
| `generate_sql_schema --check --diff` | **STALE** + ~160 coverage-gap lines |
| pytest | **4 failed**, 249 passed (staleness, `allowed_units` count 56→62, pollutant enum ×2) |

---

## Task 1 — Regenerate the sealed registry against upstream `units.json`

The upstream vocabulary grew (`FractionPerTime`, the time-type split refinements; 56→62 allowed
units, 41 quantity types).

1. `python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json`
   (already verified to succeed; new seal `185c018ed278…`).
2. Bump `PRAGMA user_version` in `schema/schema.sql`.
3. Update hardcoded counts in `test/test_unit_registry.py` — `test_build_row_counts` expects
   `allowed_units-56`; re-measure all four table counts from the fresh build, don't hand-compute.
4. Gate: `just new-db && just verify-registry`; pytest registry tests green except the two
   pollutant tests (Task 2).

## Task 2 — Pollutant enum: add `CO`, `VOC`

Upstream `EmissionsData.json` added `CO` and `VOC` after `SO2`. Update the pollutant CHECK lists in
both the insert and update triggers in `schema/triggers.sql` to the exact upstream order:
`CO2, CO2E, CH4, N2O, NOX, SO2, CO, VOC, PM25, PM10, HG, HAP, CUSTOM`.

Gate: `python3 -m pytest test/test_unit_registry.py -k emissions -v` passes (both parametrizations).

## Task 3 — ThreeWindingTransformer two-basis impedances (clears the 6 sync FAILs)

Upstream moved the 3W impedances to the two-basis `parameter_units` pattern (NATURAL_UNITS: ohm,
COMPONENT_BASE: pu, referenced to the primary winding's voltage base). GridDB still types them
statically as pu with no discriminator, and `three_winding_transformers` has no `unit_basis`
column.

1. Add to `three_winding_transformers` in `schema/schema.sql` (mirror `transformer_circuits`):
   `unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS'))`.
2. In `schema/column_conventions.json`, replace the six static rows
   (`r_12, x_12, r_23, x_23, r_31, x_31`, unit `pu`) with discriminator pairs exactly like the
   `transformer_circuits.r` pattern: one `pu` row with
   `"discriminator_column": "unit_basis", "discriminator_value": "COMPONENT_BASE"` keeping the
   existing `base_power_ref` (`base_power_12`/`_23`/`_31`) and
   `base_voltage_ref: "primary_circuit->transformer_circuits.base_voltage_primary"`, plus one
   `ohm` row with `"discriminator_value": "NATURAL_UNITS"`. Preserve the PSSE-convention
   descriptions (all three pairs referred to the primary winding's base).
3. Regenerate the registry (Task 1 command), re-bump nothing (user_version already bumped once for
   this change set).
4. Gate: `python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path
   ../PowerSystems.jl --db griddb-example.sqlite` → **L1 FAILs = 0**.

## Task 4 — Time-series wire-schema alignment — **DONE 2026-08-24, redirected to the infrastore mirror**

Direction change (user decision): the association tables mirror **infrastore's catalog DDL**
(`infrastore/crates/infrastore-core/src/metadata/schema.rs`), not the SiennaSchemas wire form,
so GridDB rows deserialize straight into a store at the modeling stage. Executed:

- `time_series_associations` rebuilt column-for-column on infrastore's catalog: integer-code
  `owner_category` (0/1) and `time_series_type` (0–5), content-address `data_hash` /
  `features_hash` / `timestamps_hash` BLOBs, `units` / free-form `quantity_kind` / lowercase
  un-CHECKed `unit_system`, `time_reference`, `component_field`, `percentiles_json`,
  `element_type` (default `'f64'`) / `element_shape`, `application_data`; infrastore's full index
  set including the uq_ts_assoc + uq_ts_assoc_coalesced uniqueness pair and the partial
  `idx_component_field`; the `time_series_readable` decode view.
- New `feature_sets` and `timestamp_sets` companion tables (content-addressed, no FK by design).
- `supplemental_attributes_association` → `supplemental_attribute_associations`
  (id, component_id/type, attribute_id/type + uq_sa_assoc + reverse index), FKs kept as
  GridDB-side integrity.
- Where the catalog and the SiennaSchemas wire form diverge, the wire form wins (user decision):
  `uri TEXT NOT NULL` added (dense-data locator, keys `static_time_series`), `element_shape`
  NOT NULL (default `'[]'`), `data_hash` nullable (optional integrity hash, partial index).
- `time_series_metadata` dropped; `static_time_series` re-keyed uuid → `uri`.
  Triggers: association-existence on `uri`; registered-`quantity_kind` unit guard
  (free-form kinds pass); owner-domain check for `owner_category = 1`.
- Registry regenerated (332 conventions, seal `577d8c0f…`), `user_version` 9→10, tests and docs
  (README §Time-series units, units-architecture §2–6) updated. Gates: build + verify green,
  pytest 248 passed / 3 pre-existing failures (Tasks 2, 5), sync check 6 pre-existing FAILs
  (Task 3), the two time_series_metadata WARNs gone (79→77).

Superseded original scope kept below for reference; its open remainder folds into Task 5 (coverage
reconciliation) and Task 6 (the schemas ⇄ catalog `uri`/`data_hash`/`element_shape` divergence is
resolved in GridDB by following the schemas; infrastore's catalog gaining `uri` is an upstream
question to raise there).

### (superseded) original Task 4 scope

Upstream rewrote the association wire schema (`TimeSeries/` package): a closed six-type
discriminated union (`SingleTimeSeries`, `NonSequentialTimeSeries`, `Deterministic`,
`DeterministicSingleTimeSeries`, `Probabilistic`, `Scenarios`) that **dropped** the catalog rowid,
`time_series_uuid`/`metadata_uuid`, and `scaling_factor_multiplier`, **renamed** address→`uri` and
`quantity_type`→`quantity_kind`, and **added** `data_hash`, `element_type`, `element_shape`,
`component_field`, `application_data`, and the unit trio `units` / `quantity_kind` /
`unit_system` (enum `COMPONENT_BASE | NATURAL_UNITS`, matching GridDB's `unit_basis` vocabulary)
directly on the association.

Rework `time_series_associations` in `schema/schema.sql`:

- Drop: `time_series_uuid`, `metadata_uuid`, `scaling_factor_multiplier`.
- Add: `uri TEXT NOT NULL`, `data_hash TEXT NULL`, `element_type TEXT NOT NULL`,
  `element_shape TEXT NOT NULL CHECK (json_valid(element_shape))` (JSON int array; `[]` = scalar),
  `component_field TEXT NULL`, `application_data TEXT NULL`, `units TEXT NULL`,
  `quantity_kind TEXT NULL`, `unit_system TEXT NULL
  CHECK (unit_system IS NULL OR unit_system IN ('COMPONENT_BASE', 'NATURAL_UNITS'))`.
- Constrain `time_series_type` to the six canonical names, and add per-type CHECKs for the timing
  fields each variant requires (SingleTimeSeries: `initial_timestamp`/`resolution`/`length`;
  forecasts: `horizon`/`interval`/`window_count`; NonSequentialTimeSeries carries explicit
  timestamps, not a resolution — read each of the six upstream schema files for the exact
  required lists before writing the CHECKs).
- Re-point the unique index (`time_series_uuid` is gone; dense-data identity is now `uri`).

**Decision (a), needs sign-off before this task starts** — `time_series_metadata`:
upstream now carries units on the association, overlapping GridDB's per-uuid
`time_series_metadata` (unit, quantity_type, unit_basis, base_power/base_voltage snapshots) that
the `static_time_series` triggers validate against. Options:

1. *(Recommended)* Fold: move the base snapshots (`base_power`, `base_voltage`) onto
   `time_series_associations`, key `static_time_series` validation triggers off the association
   row, drop `time_series_metadata`. One source of truth, matches the wire schema.
2. Keep `time_series_metadata` re-keyed by `uri` as a store-internal detail. Two places to keep
   consistent.

Either way: update `schema/triggers.sql` (the static_time_series unit-enforcement triggers),
`schema/schema_map.json`, and `schema/column_conventions.json` (registry rows for the new unit
columns; this also clears the two `time_series_metadata.base_power/base_voltage` unmapped-table
WARNs). Rename remaining `quantity_type` column references on the TS side to `quantity_kind`
(the registry table `quantity_types` itself keeps its name — that's the vocabulary, not the wire
field).

Gate: `just new-db`, full sync check, and the time-series pytest files green.

## Task 5 — Refresh `generated_schema.sql`, reconcile coverage decisions

1. `python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas` to regenerate the
   reference projection (currently STALE).
2. Diff the ~160 gap lines against `schema/coverage_decisions.json`. New since the freeze and
   needing an explicit decision each (cover or record as deliberate exclusion):
   - `TwoTerminalVSCLine`: `rated_ac_voltage_from/to`, `rated_dc_voltage`,
     `voltage_limits_from/to`, `dc_voltage_droop_from/to` — the consolidated
     `two_terminal_hvdc_lines` table moved variant-specific fields to `attributes`; add
     attribute-name conventions for the unit-bearing ones (kV) rather than columns.
   - `DataSource` supplemental attribute — stored generically in `supplemental_attributes` JSON;
     record as covered-by-generic in `coverage_decisions.json`.
   - The long-standing gaps (loads, balancing_topologies, technologies…) — confirm they are all
     already in `coverage_decisions.json`; anything new gets a decision entry, not silence.
3. Gate: `python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas --check --diff`
   exits 0; `pytest test/test_sql_codegen.py` green.

## Task 6 — Upstream coordination (SiennaSchemas PRs, not GridDB edits)

- `FACTSControlDevice.max_reactive_power`: PSY marks it `needs_conversion (:mva)` but the schema
  property has no `x-unit` — the one L3 WARN. Fix belongs upstream.
- Confirm the checker's discriminator handling matches upstream's `parameter_units` prose on the
  3W transformer (Task 3 clears the FAILs on our side; if the sync checker later learns to read
  `parameter_units`, no GridDB change needed).
- Merge order: tag a SiennaSchemas release (with `units.json` + `dist/`) **before** GridDB's
  regeneration PR merges.

## Task 7 — Full gate run

The complete CI chain locally, in order, all green:

```sh
just new-db
python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json
python3 scripts/verify_unit_registry.py griddb-example.sqlite
python3 scripts/generate_sql_schema.py --schemas-path ../SiennaSchemas --check --diff
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl --db griddb-example.sqlite
../.venv/bin/python3 -m pytest test/ -q     # 0 failed
```

`PRAGMA user_version` bumped exactly once across the whole change set. Report the sync-check
FAIL/WARN counts and the pytest pass count.

---

## Out of scope, noted

- Service/reserve membership still has no association table here **and no schema upstream** —
  unchanged by the serde work; still the blocker if reserve participation must round-trip.
- The System ⇄ GridDB converter remains unbuilt; nothing here starts it.
- Dense NonSequentialTimeSeries storage in `static_time_series` (idx-based, no explicit-timestamp
  variant) is a follow-on if that type ever lands in the static store; the association row (Task 4)
  is what the serde needs now.
