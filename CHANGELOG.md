# Changelog

All notable changes to SiennaGridDB are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions the
schema itself through `PRAGMA user_version`, bumped on every schema or registry change.

## [Unreleased]

## [0.1.0] - 2026-09-11

First release. `PRAGMA user_version = 19`.

### Schema

- 52 tables mirroring the PowerSystems data model, with `entities` as the supertype
  every component row also has a row in.
- 127 triggers enforcing entity existence, delete cascades, arc AC/DC domains, hydro
  topology, and unit validity on both columns and `attributes` rows.
- Explicit per-row unit basis: `parameter_units` / `power_units` discriminators,
  following the SiennaSchemas spelling, with `COMPONENT_BASE` and `NATURAL_UNITS` arms.
- Every per-unit row records the base it resolves against; no silent defaults.
- All three point-to-point HVDC variants share `two_terminal_hvdc_lines`, discriminated
  by `converter_type`.
- Time-series associations mirror infrastore's catalog: `time_series_associations`,
  `feature_sets` and `timestamp_sets`, keyed by a store-minted association id.

### Unit registry

- `schema/unit_registry.sql` is generated from SiennaSchemas' `Core/units.json` plus
  the DB-owned `schema/column_conventions.json`, and sealed with a sha256 over a
  canonical byte representation. 41 quantity kinds, 66 allowed units, 405 column
  conventions, 9 basis rules.
- Anti-tamper triggers make the registry tables immutable outside the generator.
- Units vocabulary follows QUDT terminology: `quantity_kind`, never `quantity_type`.

### Known limitations

- Create-only. No migration path; `schema.sql` drops every table before creating them.
- 44 of 96 upstream components have a table. Dynamics, services/reserves and the
  investment policy layer have none.
- No PowerSystems `System` converter in either direction.
- Foreign keys are off unless the consumer sets `PRAGMA foreign_keys = ON` on each
  connection — SQLite does not persist it in the file.
- 14 of 52 tables are not `STRICT`, so declared numeric columns on those tables accept
  text.

[Unreleased]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sienna-Platform/SiennaGridDB/releases/tag/v0.1.0
