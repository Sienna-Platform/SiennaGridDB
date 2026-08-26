# SiennaGridDB — Claude Guide

The canonical **SQLite database schema** ("griddb") for Sienna applications: tables mirroring the PowerSystems data model (entities, thermal/renewable/hydro generators, storage, reservoirs, transmission, planning regions, investment technologies, time-series metadata and static storage) plus the units tables (`quantity_types`, `allowed_units`, `unit_conventions`, `unit_management_metadata`). Content is SQL under `schema/` with a little Python tooling in `scripts/`. Requires **SQLite ≥ 3.45** (jsonb) — `.justfile`'s `assert-sqlite-version` enforces it. Platform conventions: the `sienna-psy6` skill; `README.md` documents the commands and the sync semantics in more detail.

Branch, table counts, convention counts, test counts, and sync-check results all drift constantly. Measure them; don't trust a number written here:

```sh
git branch --show-current
grep -cE '^\s*CREATE TABLE' schema/schema.sql
python3 -c "import json;print(len(json.load(open('schema/column_conventions.json'))['conventions']))"
```

## Working agreement

**Responses.** Keep responses focused and concise. Spend most of the response on the main answer and keep caveats short. When asked to explain something, give a high-level summary unless an in-depth explanation is requested.

**Scope.** Deliver what was asked, at the scope intended. Make routine judgment calls yourself, and check in only when different readings of the request would lead to materially different work. If the request seems mistaken or a better approach exists, say so in a sentence and continue with the task as asked rather than quietly narrowing, widening, or transforming it. Finish the whole task, and stop short of actions clearly beyond what was asked. The concrete limit here: the PSY `System` ⇄ GridDB converter does not exist — don't improvise a partial one.

**Communication.** Before the first tool call, say in one sentence what you're about to do. While working, give a brief update only when you find something important or change direction. When finishing, lead with the outcome: the first sentence answers "what happened" or "what did you find", with supporting detail after it.

**Corrections.** Only correct an earlier statement when the error would change the user's code, conclusions, or decisions. State the correction plainly and briefly, then continue. For slips that change nothing, make the fix and move on without noting it.

**Verification.** The gates are real build steps, not self-checking — build a fresh DB, regenerate and verify the registry, run the sync check, run pytest (see *Commands*). Beyond those, don't add verification passes or re-check work already checked.

**Reviews and audits.** When reviewing DDL or auditing drift, report everything found and filter in a separate pass. Pre-filtering to "high severity only" suppresses real findings. For SQL specifically, the `evaluating-sql-quality` skill carries the review checklist — use it rather than a partial one from memory.

**Written output.** Match document length to what the task needs: cover the substance without filler sections, redundant summaries, or boilerplate.

**Delegation.** Use subagents only when explicitly requested. When they are, delegate only genuinely independent, sizeable tracks — a sweep across all tables or all conventions, say — never to verify your own work, and keep spawn counts low.

## Place in the pipeline

Downstream consumer of **SiennaSchemas' unit vocabulary**:

```
SiennaSchemas/Core/units.json  +  schema/column_conventions.json (DB-owned column→(quantity_type, unit) map)
        │
        └── scripts/generate_unit_registry.py ──▶ schema/unit_registry.sql   (deterministic, sha256-sealed)
```

Cross-repo paths are **flags with `../` defaults, not a required layout**: `generate_unit_registry.py --units-json`, `check_units_sync.py --schemas-path` / `--psy-path` / `--db`. CI checks the sibling repos out flat and passes explicit paths, so don't assume a sibling checkout — pass the flag.

- `schema/schema.sql` (tables), `schema/triggers.sql` (integrity: entity-existence, arc-type, hydro-topology), and `schema/views.sql` (`column_units`, `operational_data`) are **hand-written and authoritative**. `scripts/generate_sql_schema.py` plus `schema/sql_codegen_map.json` produce the *reference* projection `schema/generated_schema.sql` from the SiennaSchemas components; CI checks staleness and reports drift against the hand-written DDL via `--diff`.
- No converter loads a PSY `System` into these tables or back. Table shapes and `column_conventions.json` deliberately mirror PSY fields (natural units; `operation_cost` JSON blobs must use `NATURAL_UNITS`; `base_power` per-unitization columns) so the future bridge is mechanical.
- **AC vs DC topologies**: `entity_types.is_dc` marks the DC side of the network (PSY `DCBus`). All three point-to-point HVDC variants (`TwoTerminalGenericHVDCLine`, `TwoTerminalLCCLine`, `TwoTerminalVSCLine`) live in one `two_terminal_hvdc_lines` table, discriminated by `converter_type` (`GENERIC` | `LCC` | `VSC`). `tmodel_hvdc_lines` is different: it's the DC-network branch running between two `is_dc = 1` topologies — the multi-terminal HVDC building block, not a point-to-point device.

## Generated / sealed artifacts — never hand-edit

- `schema/unit_registry.sql` is checksum-sealed: the canonical byte representation (with `\x1f/\x1e/\x1d` separators) must hash-match the seal. The generator refuses `(quantity_type, unit)` pairs absent from `units.json`.
- Cost fields are registered as JSON-path "columns" (`operation_cost.fixed`, …) and five `attributes.*` rows are attribute-name conventions rather than physical columns — the registry covers more than literal columns.
- Bump `PRAGMA user_version` on any schema or registry change.

## Commands

Recipes live in `.justfile`, and CI runs `just new-db` — prefer the recipes, since they carry the SQLite version assert and a clean-slate step the raw chain below does not. The default DB name is `griddb-example.sqlite`.

```sh
just new-db                                     # schema → triggers → registry → views
just generate-registry
just verify-registry

# equivalent chain if `just` is unavailable
for f in schema.sql triggers.sql unit_registry.sql views.sql; do
  sqlite3 griddb-example.sqlite < schema/$f
done
python3 scripts/generate_unit_registry.py --units-json ../SiennaSchemas/Core/units.json
python3 scripts/verify_unit_registry.py griddb-example.sqlite
```

Tests need `pytest` (in `pyproject.toml`'s `dev` extras) plus `pydantic>=2`, which the extras do **not** declare — CI installs it explicitly. Run them the way CI does: `pip install pytest "pydantic>=2"` then `python3 -m pytest test/ -v`.

## Keeping in lockstep with SiennaSchemas

A vocabulary change upstream without regeneration here is drift. The sync check spans three layers — schemas ↔ registry ↔ PSY descriptor — and **silently drops the PSY layer when `--psy-path` is omitted**, so two developers "measuring" can get different answers. Run it the way CI does:

```sh
python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl --db griddb-example.sqlite
```

A *contradiction* (a mapped column with a different unit on each side) fails; a *gap* (an unmapped column or unannotated property) only warns. Merge order is load-bearing: tag a SiennaSchemas release (with `units.json` and `dist/` bundles) **before** GridDB regenerates.

**Pending upstream change to absorb.** SiennaSchemas split time into three quantity types — `Duration` (`s`, real, continuous time constants), `OperationalDuration` (`min`, integer, scheduling and commitment durations), and `CalendarPeriod` (`yr`, integer, planning spans) — and dropped hours from the vocabulary entirely. `column_conventions.json` still types the affected columns as `Duration` with `h`/`yr`, which fails the upstream pairing rule. Find them and re-type on the next regeneration (`lifetime` → `CalendarPeriod`, the durations → `OperationalDuration`):

```sh
python3 -c "import json;print(sorted({e['column'] for e in json.load(open('schema/column_conventions.json'))['conventions'] if e.get('quantity_type')=='Duration'}))"
```

## Warnings / stale bits

- **`schema/schema.sql` DROPs all tables** — test-only; never apply to a live dataset.
- Stale scaffolding, do not build on it: the root `openapi.json` is a leftover stub referencing a nonexistent `schemas/` dir; `scripts/check-schema-sync.sh` expects a `SiennaOpenAPIModels.jl/src/dbinterface/` package that doesn't exist (the planned Julia DB-interface layer).
- No table records **which devices contribute to which service**. Service/reserve membership has no association table here and no schema upstream, unlike `supplemental_attributes_association`. If reserve participation needs to round-trip, that gap is the blocker.

<tone_preference>
Keep outputs reasonably concise. Lead with the outcome, and let the build gates stand in for extra verification passes.
</tone_preference>
