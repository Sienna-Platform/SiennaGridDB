# SiennaGridDB — Claude Guide

The canonical **SQLite database schema** ("griddb") for Sienna applications: 31 tables mirroring the PowerSystems data model (entities, thermal/renewable/hydro generators, storage, reservoirs, transmission, planning regions, investment technologies, time-series metadata/static storage) plus the units tables (`quantity_types`, `allowed_units`, `unit_conventions`, `unit_management_metadata`). Content is SQL under `schema/` with a little Python tooling in `scripts/`. Requires **SQLite ≥ 3.45** (jsonb). Platform conventions: `.claude/Sienna.md`; workspace architecture: the psy6 workspace root `CLAUDE.md`.

Current branch: `jm/units_v2` (units registry effort, PR #169). Master plan: the psy6 workspace root's `.claude/plans/2026-07-05-units-ecosystem-closure.md`.

## Place in the pipeline

Downstream consumer of **SiennaSchemas' unit vocabulary** (sibling checkout at `../SiennaSchemas`):

```
SiennaSchemas/Core/units.json  +  schema/column_conventions.json (DB-owned column→(quantity_type, unit) map)
        │
        └── scripts/generate_unit_registry.py ──▶ schema/unit_registry.sql   (deterministic, sha256-sealed)
```

- `schema/schema.sql` (tables), `schema/triggers.sql` (integrity: entity-existence, arc-type, hydro-topology), `schema/views.sql` (`column_units`, `operational_data`) are **hand-written**; `scripts/generate_sql_schema.py` + `schema/sql_codegen_map.json` produce the *reference* projection `schema/generated_schema.sql` from the SiennaSchemas components (CI checks staleness and reports drift vs the hand-written DDL via `--diff`) — the hand-written files remain authoritative.
- **The PSY6 System ⇄ OpenAPI ⇄ GridDB loop is not closed**: no converter loads a PSY `System` into these tables or back. Table shapes and `column_conventions.json` deliberately mirror PSY fields (natural units; `operation_cost` JSON blobs must use `NATURAL_UNITS`; `base_power` per-unitization columns) so the future bridge is mechanical. That bridge is the next stage — don't improvise partial ones.
- State (post PR #169 work, 2026-07-05): builds clean; 137 conventions / 39 quantity types / 46 allowed units; registry generated+sealed; 65 pytest tests; sync check 0 FAIL / 54 WARN.

## Generated / sealed artifacts — never hand-edit

- **`schema/unit_registry.sql` is generated and checksum-sealed.** Regenerate with `python3 scripts/generate_unit_registry.py`; verify a built DB with `python3 scripts/verify_unit_registry.py` (canonical byte representation with `\x1f/\x1e/\x1d` separators must hash-match the seal). The generator refuses (quantity_type, unit) pairs absent from `units.json`.
- Cost fields are registered as JSON-path "columns" (`operation_cost.fixed`, …) and five `attributes.*` rows are attribute-name conventions, not physical columns — the registry covers more than literal columns.
- Bump `PRAGMA user_version` on any schema/registry change.

## Commands

Recipes live in `.justfile`, but **`just` is NOT installed on this machine — run the underlying commands directly**:

```sh
# fresh DB (the chain behind `just new-db`): schema → triggers → registry → views
sqlite3 test.db < schema/schema.sql
sqlite3 test.db < schema/triggers.sql
sqlite3 test.db < schema/unit_registry.sql
sqlite3 test.db < schema/views.sql

python3 scripts/generate_unit_registry.py       # `just generate-registry`
python3 scripts/verify_unit_registry.py test.db # `just verify-registry`
```

Python tests use the shared venv `.venv-units` at the psy6 workspace root (`.venv-units/bin/pytest`); pytest is not installed globally.

## Warnings / stale bits

- **`schema/schema.sql` DROPs all tables** — test-only; never apply to a live dataset.
- Stale scaffolding, do not build on it: `pyproject.toml` declares a `sienna_database_gen` Python package that doesn't exist in the checkout (and its sqlfluff dialect says `postgres` while everything is SQLite); the root `openapi.json` is a leftover stub referencing a nonexistent `schemas/` dir; `test/load_models.py` imports a bygone `python_models` package (predecessor of power-openapi-models); `scripts/check-schema-sync.sh` expects a `SiennaOpenAPIModels.jl/src/dbinterface/` package that doesn't exist (the planned Julia DB-interface layer). README's `just test`/`just queries` targets don't exist in the current `.justfile`.
- Keep GridDB registry and SiennaSchemas vocabulary in lockstep — a vocabulary change without regeneration here is drift; `python3 scripts/check_units_sync.py` is the sync check (schemas ↔ registry ↔ PSY descriptor). Merge order is load-bearing: tag a SiennaSchemas release (with `units.json` + `dist/` bundles) **before** GridDB regenerates.
