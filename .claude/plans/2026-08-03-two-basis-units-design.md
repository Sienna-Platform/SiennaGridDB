# Two-basis unit handling in SiennaGridDB

Design and implementation plan. Approved 2026-08-03.

## Problem

The schema has **three differently-named discriminator columns** expressing one concept — what basis a
per-unit number is normalized against — with inconsistent value sets:

| Column | Values | Convention rows | Column defs | Tables |
|---|---|---|---|---|
| `parameter_units` | `SYSTEM_BASE`, `NATURAL_UNITS` | 18 | 4 | `transmission_lines`, `transformer_circuits`, `sources`, `tmodel_hvdc_lines` |
| `admittance_units` | `SYSTEM_BASE`, `NATURAL_UNITS`, `DEVICE_MVAR` | 12 | 2 | `fixed_admittance`, `switched_admittance` |
| `voltage_setpoint_units` | `SYSTEM_BASE`, `NATURAL_UNITS` | 2 | 2 | `facts_control_devices`, `interconnecting_converters` |

Upstream SiennaSchemas uses a consistent `['DEVICE_BASE','NATURAL_UNITS','SYSTEM_BASE']` triple on ~20
properties. GridDB implements only two of the three, which is exactly the 6 `discriminator key mismatch`
FAILs `check_units_sync.py` currently reports.

Worse, `SYSTEM_BASE` was historically **unresolvable**: it meant "pu against a number this database does
not store". Seven of the twelve tables carrying a pu column have no base on the row at all.

## Design

### Two orthogonal axes

**Axis 1 — basis.** One column, `unit_basis`, two values, everywhere:

- `NATURAL_UNITS` — a physical unit (ohm, S, MVAr, kV, MW). Self-contained, no base needed.
- `COMPONENT_BASE` — dimensionless pu against bases reachable from the row.

**Axis 2 — quantity.** The existing `quantity_type` field. Under `NATURAL_UNITS` it also selects *which*
natural unit, which is how `DEVICE_MVAR` is absorbed without a third basis value: `y_b` is
`Susceptance/S` or `ReactivePower/MVAr`, both `NATURAL_UNITS`, distinguished by recorded quantity.

Untouched, because they are a genuinely different axis (they say which *quantity* a polymorphic column
holds, not what basis it is in): `control_objective` (24 rows), `level_data_type` (24), `*.curve_type`
(28), `dc_control` (5), `ac_control` (3).

### Why collapsing DEVICE_BASE and SYSTEM_BASE loses nothing

They differ *only* in what number the base is — `SBASE1-2` for a transformer winding, `SBASE` for a
line. Once the row stores or can reach the number, the label is redundant: it records where the value
came from, not how to interpret it. Two values therefore suffice where upstream needs three.

### Grounding in the PSSE standard

Verified in `PowerFlowFileParser.jl` (`src/pm_io/pti.jl`, `src/pm_io/psse.jl:276-282`):

| PSSE record | Own base? | Fields | Consequence |
|---|---|---|---|
| Transformer winding | **Yes** | `SBASE1-2/2-3/3-1`, `NOMV1/2/3`, `CZ` selects convention | genuine device base; store it |
| Branch (line) | No | `SBASE` only | write system base at parse time |
| Fixed / switched shunt | No | `GL`/`BL` in MW/MVAr at unity voltage | write system base at parse time |

The parser's own docstring: *"a BRANCH record declares no MVA base of its own, unlike a transformer
winding which carries SBASE1-2 and friends, so SBASE is the only base available to interpret them
against. A FIXED SHUNT's GL/BL are MW/MVAr at unity voltage instead, and `_make_per_unit!` divides
every shunt gs/bs by the case base."*

So `three_winding_transformers.base_power_12/23/31` is PSSE's `SBASE1-2 / 2-3 / 3-1` verbatim — a real
device base that stays. Everything else takes the system base written in at parse time.

`PSY.FixedAdmittance.Y` is documented *"Fixed admittance in p.u. (SYSTEM_BASE)"* — pu only, no MVAr
representation downstream.

### There is still no system base in the database

No `systems` or `cases` table exists and none is added. A single shared `base_power` row would make
every `COMPONENT_BASE` value depend on mutable state elsewhere in the database — changeable
independently of the rows using it, and wrong the moment two callers assume different values. "System
base" remains a property of the model someone builds (`PSY.get_base_power(sys)`). What changes is that
each row now *carries or can reach* the number it was normalized against.

Known and accepted limitation: nothing enforces that every row's `base_power` agrees. A writer that
inserts one line at 100 MVA and another at 138 MVA produces two internally consistent rows that
contradict each other. Cross-row agreement is an application responsibility; a future trigger could
enforce it, and is out of scope here.

### Mechanical resolution: rules + base references

Only five quantity types ever carry `pu`, and which base to divide by follows from the dimension. This
becomes a sealed table, `unit_basis_rules`:

| quantity_type | base_expression |
|---|---|
| `Voltage` | `base_voltage` |
| `Resistance`, `Reactance` | `base_voltage^2/base_power` |
| `Susceptance`, `Conductance` | `base_power/base_voltage^2` |

And `unit_conventions` gains nullable `base_power_ref` / `base_voltage_ref` naming *which* bases apply,
defaulting to same-row `base_power` / `base_voltage`. No arrow means a same-row column; arrows are FK
hops, where each segment after the first is `table.column` and the last segment names the base column:

```
base_power_ref   = 'base_power_12'                                            -- same row
base_power_ref   = 'circuit->transformer_circuits.base_power'                 -- one hop
base_voltage_ref = 'arc_id->arcs.from_id->balancing_topologies.base_voltage'  -- two hops
```

The base must be reachable **without leaving the database**; same-row and FK-path both satisfy that.
The original goal was "not in the modeling application", not "not in another row".

Together these give one invariant worth one test: **every pu convention has a rule for its quantity
type, and the base references it names resolve.** If that passes, every pu value in the database is
resolvable.

### Resolution table (target state)

| Table | `base_power_ref` | `base_voltage_ref` |
|---|---|---|
| `transmission_lines` | `base_power` (present) | `arc_id->arcs.from_id->balancing_topologies.base_voltage` |
| `discrete_controlled_ac_branches` | `base_power` (present) | `arc_id->arcs.from_id->balancing_topologies.base_voltage` |
| `transformer_circuits` | `base_power` (present) | `base_voltage_primary` (present) |
| `three_winding_transformers` | `base_power_12` / `_23` / `_31` (present) | `primary_circuit->transformer_circuits.base_voltage_primary` |
| `two_winding_transformers` | `circuit->transformer_circuits.base_power` | `circuit->transformer_circuits.base_voltage_primary` |
| `sources` | `base_power` (present) | `base_voltage` (present) |
| `fixed_admittance` | **add** `base_power` | `bus->balancing_topologies.base_voltage` |
| `switched_admittance` | **add** `base_power` | `bus->balancing_topologies.base_voltage` |
| `tmodel_hvdc_lines` | **add** `base_power` | `arc_id->arcs.from_id->balancing_topologies.base_voltage` |
| `facts_control_devices` | n/a (Voltage only) | `bus->balancing_topologies.base_voltage` |
| `interconnecting_converters` | n/a (Voltage only) | `bus->balancing_topologies.base_voltage` |

All FK columns above were verified to exist. `balancing_topologies` has **no** `base_voltage` column
today (bus base voltage lives only as an `attributes` row) — it is added as a first-class column and is
the target of most paths.

`attributes` rows keep their inline `unit`/`quantity_type` and are exempt from base references: the
owner is polymorphic (`entity_id` → `entities`), so no single static path applies. Record the exemption
in `coverage_decisions.json` rather than inventing a path that only works for buses.

### Time series

`time_series_metadata` gains the same two-valued `unit_basis`, so time-series and component data share
one vocabulary and one basis axis.

It does **not** use base references: a series owner is polymorphic (`owner_id` → `entities`, with
`base_power` on whichever concrete table), so a static path cannot express it. Series instead carry
their own nullable `base_power` / `base_voltage`, written at ingest — the same parse-time rule, keeping
a series self-contained.

### Sync check

Teach `check_units_sync.py` the basis mapping rather than implementing a third value:

- schema `DEVICE_BASE` → GridDB `COMPONENT_BASE`
- schema `SYSTEM_BASE` → GridDB `COMPONENT_BASE`
- schema `DEVICE_MVAR` → GridDB `NATURAL_UNITS` + `ReactivePower` (`y_b`) / `ActivePower` (`y_g`)

This resolves the 6 existing `discriminator key mismatch` FAILs.

### Seal contract

`unit_conventions` gaining two fields changes the canonical checksum representation, and
`unit_basis_rules` is sealed too (drift there silently corrupts every conversion). Three things move in
lockstep, or `verify-registry` fails:

1. the docstring contract in `generate_unit_registry.py:22-47`
2. its row emission
3. the `SELECT` in `verify_unit_registry.py:47-49`

Canonical repr gains `base_power_ref`, `base_voltage_ref` on the `unit_conventions` block (after
`discriminator_value_2`, before `description`) and a fourth table block for `unit_basis_rules`
(`quantity_type`, `base_expression`, `description`), joined with GS in that fixed order. The seal hash
changes once, by construction.

## Out of scope

- No `PRAGMA user_version` bump — not releasing yet.
- No changes to the orthogonal discriminators.
- No cross-row `base_power` agreement trigger.
- No PSY `System` ⇄ GridDB converter.
- The 3 test failures already on this branch (`test_generated_sql_is_not_stale`,
  `test_emissions_enum_lists_match_schema` ×2) are pre-existing and unrelated. Leave them failing;
  do not fold fixes in.

## Implementation phases

Dependencies are mostly linear because the registry is generated from the schema inputs. Each phase
ends green on the gates listed under it.

### Phase 1 — Schema DDL (`schema/schema.sql`)

1. Rename all 8 discriminator column definitions to `unit_basis`, values
   `CHECK (unit_basis IN ('COMPONENT_BASE','NATURAL_UNITS'))`. Preserve per-table defaults:
   `tmodel_hvdc_lines` defaults `NATURAL_UNITS`, the other seven default `COMPONENT_BASE`.
   `admittance_units`' `DEVICE_MVAR` value disappears from the CHECK.
2. Add `base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0)` to `fixed_admittance`,
   `switched_admittance`, `tmodel_hvdc_lines`.
3. Add `base_voltage REAL NULL CHECK (base_voltage IS NULL OR base_voltage > 0)` to
   `balancing_topologies`.
4. `unit_conventions`: add `base_power_ref TEXT NULL`, `base_voltage_ref TEXT NULL`; widen
   `UNIQUE(table_name, column_name, discriminator_value, discriminator_value_2)` to include
   `quantity_type`; widen the `uq_unit_conventions_no_discriminator` partial index the same way.
5. New `unit_basis_rules` table (`quantity_type TEXT PRIMARY KEY REFERENCES quantity_types(name)`,
   `base_expression TEXT NOT NULL`, `description TEXT NULL`) `strict`, plus its `DROP TABLE IF EXISTS`
   in the drop block, ordered before `quantity_types` is dropped.
6. `time_series_metadata`: add `unit_basis TEXT NOT NULL DEFAULT 'NATURAL_UNITS'
   CHECK (unit_basis IN ('COMPONENT_BASE','NATURAL_UNITS'))`, `base_power REAL NULL CHECK (base_power > 0)`,
   `base_voltage REAL NULL CHECK (base_voltage IS NULL OR base_voltage > 0)`.

Gate: `just new-db` builds without error.

### Phase 2 — Conventions (`schema/column_conventions.json`)

1. Rewrite `discriminator_column` `parameter_units` / `admittance_units` / `voltage_setpoint_units`
   → `unit_basis` (32 rows).
2. `discriminator_value` `SYSTEM_BASE` → `COMPONENT_BASE`.
3. The 4 `DEVICE_MVAR` rows → `discriminator_value: NATURAL_UNITS`, keeping their existing
   `ReactivePower/MVAr` and `ActivePower/MW` quantity/unit pairs. They now coexist with the
   `Susceptance/S` and `Conductance/S` rows under the widened uniqueness key.
4. Add `base_power_ref` / `base_voltage_ref` to every pu convention row per the resolution table above.
5. Update the file's `description` to document the two axes, the base-ref syntax, and the widened key.

Gate: `python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json` succeeds.

### Phase 3 — Generator and verifier

1. `generate_unit_registry.py`: load and emit the two new convention fields; emit the
   `unit_basis_rules` seed block; extend the canonical repr per the seal contract above; update the
   module docstring.
2. Seed `unit_basis_rules` with the five rules in the table above.
3. `verify_unit_registry.py`: extend its `SELECT`s to match the new repr exactly, including the new
   table block.
4. Regenerate `schema/unit_registry.sql`.

Gates: `just new-db` then `just verify-registry` reports MATCH.

### Phase 4 — Triggers and views

1. `schema/triggers.sql`: seal-protection triggers for `unit_basis_rules` mirroring the existing
   `quantity_types` / `allowed_units` pattern (UPDATE and DELETE blocked unconditionally, INSERT
   blocked once the checksum row exists).
2. Confirm the `attributes` unit-validation triggers still behave under the widened uniqueness key —
   their `NOT EXISTS`-over-match logic already handles polymorphic names, but a name with two
   `NATURAL_UNITS` arms is new. Add a regression test either way.
3. `schema/views.sql`: extend `column_units` to expose `base_power_ref`, `base_voltage_ref`, and the
   joined `base_expression`.

Gate: `just new-db && just verify-registry`.

### Phase 5 — Codegen map and drift gate

1. `schema/sql_codegen_map.json`: rename `parameter_units` / `admittance_units` /
   `voltage_setpoint_units` in the `db_only` and `skip` lists to `unit_basis`; add the new
   `base_power` / `base_voltage` columns to the appropriate `db_only` lists so the drift gate does not
   flag them as missing from the schemas.
2. `schema/coverage_decisions.json`: rename the two discriminator keys; record the `attributes`
   base-ref exemption.
3. Regenerate `schema/generated_schema.sql`.

Gate: `python3 scripts/generate_sql_schema.py --check` is no *newly* stale (this test is already
failing on this branch — confirm the failure reason is unchanged, do not fix it).

### Phase 6 — Sync check

Implement the basis mapping in `check_units_sync.py` per the design. Expect the 6
`discriminator key mismatch` FAILs to clear.

Gate: `python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl --db griddb-example.sqlite`
reports 6 fewer FAILs than before, with no new ones.

### Phase 7 — Tests

1. Update the files referencing old names: `test_sql_codegen.py`, `test_unit_registry.py`,
   `test_cost_and_source_coverage.py`, `test_check_units_sync_nested.py`.
2. Update `EXPECTED_QUANTITY_TYPES` / `EXPECTED_ALLOWED_UNITS` / `EXPECTED_UNIT_CONVENTIONS` to
   measured values, with a comment explaining the delta.
3. New: the resolvability invariant — every `unit='pu'` convention has a `unit_basis_rules` row for its
   quantity type, and every `base_power_ref` / `base_voltage_ref` resolves (same-row column exists, or
   every FK hop's table/column/FK exists).
4. New: `unit_basis` accepts both values and rejects a third on every table carrying it.
5. New: a column with two `NATURAL_UNITS` arms differing only by quantity type is registrable
   (the `y_b` regression), and the attributes trigger accepts either arm.
6. New: `time_series_metadata` round-trips `unit_basis` + its own bases, and rejects a bad basis.

Gate: `python3 -m pytest test/ -v` — all green except the 3 documented pre-existing failures.

### Phase 8 — Documentation

Update `docs/units-architecture.md` to describe the two-axis model as built: replace the three-basis
§5 with the two-basis design, the rules table, the base-ref syntax, the PSSE grounding, and the
revised time-series section. Update the `README.md` Units section, whose registry counts are already
stale.

## Verification gates (all must pass before handing back)

```sh
just new-db
just verify-registry
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl --db griddb-example.sqlite
source .venv/bin/activate && python3 -m pytest test/ -v
```

Leave all changes **unstaged**; `git add -N` new files so they appear in `git diff`. Do not commit or
push.
