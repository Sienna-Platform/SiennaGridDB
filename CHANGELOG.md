# Changelog

All notable changes to SiennaGridDB are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions the
schema itself through `PRAGMA user_version`, bumped on every schema or registry change.

## [Unreleased]

### Schema

- `scripts/generate_sql_schema.py` writes the per-table triggers into a marked region of
  `schema/triggers.sql`: entity-existence and delete triggers for every generated table, and
  the arc-domain triggers of each table with `arc_domain` in `sql_codegen_map.json`. A new
  table no longer needs hand-written triggers.
- New views `interface_member_tables` and `branch_names`, generated into
  `schema/views.sql` from `interface_member` in `sql_codegen_map.json`. The service
  association triggers and `interface_branch_directions` read them in place of hard-coded
  table lists.
- Every AC arc-domain error now ends with "use tmodel_hvdc_lines for DC-network branches".

## [0.2.0] - 2026-10-13

Built from SiennaSchemas v0.2.0 (`.schema-version`). `PRAGMA user_version = 3`.

### Breaking

- The component tables follow SiennaSchemas 0.2. There is no migration from a 0.1
  database; rebuild it. These columns are gone:
  `interconnecting_converters.{ac_setpoint, dc_setpoint, parameter_units, rmpct}`,
  `switched_admittance.admittance_limits`, `tmodel_hvdc_lines.parameter_units`,
  `transformer_circuits.{control_limits, controlled_quantity_limits}`,
  `two_terminal_hvdc_lines.{active_power_limits_from, active_power_limits_to}`.
- `schema/generated_schema.sql` is removed. The generated tables are now in `schema/schema.sql`.

### Schema

- `scripts/generate_sql_schema.py` writes the component tables into a marked region of
  `schema/schema.sql`. Generation is closed-world: it fails when a schema file has no table
  and no exclusion in `schema_map.json`, or a property has no disposition in
  `sql_codegen_map.json`. Dynamics components stay excluded.
- New tables: `reserves` (`OnlineReserve`, `OfflineReserve`, `GroupReserve`),
  `transmission_interfaces`, and `service_associations` for service membership.
- New views: `service_contributors`, `interface_branch_directions`,
  `interface_direction_violations`, `service_bid_offers`, `service_bids`,
  `service_offer_violations`.
- The storage `capital_costs` decomposition stores `interconnection_cost`. Before, an insert lost it.
- The `load_zone` foreign key is `DEFERRABLE INITIALLY DEFERRED`, so a bus row can come
  before its `LoadZone` row.
- A trigger rejects changes to `entities.entity_table` and `entities.entity_type` after insert.
- The production-cost CHECKs accept `MarketBidCost`, `MarketBidTimeSeriesCost` and
  `ImportExportTimeSeriesCost`.

### Unit registry

- The generator derives the conventions of generated columns and attribute-channel
  properties from the schemas' unit annotations. 42 quantity kinds, 67 allowed units,
  534 column conventions, 9 basis rules.
- Attribute units are checked per component. A `HydroPumpTurbine` efficiency row now inserts.

### Release tooling

- `update-schema.yml` opens a regeneration PR on each SiennaSchemas release.

### Known limitations

- Create-only. `schema.sql` drops every table before it creates them.
- 50 SiennaSchemas components have a table. `schema/schema_map.json` lists the excluded
  ones: dynamics, investment requirements, demand-side and colocated technologies, `AGC`,
  `HybridSystem`, `BilateralTransaction`, `GenericArcImpedance` and `VoltageControlAssociation`.
- No PowerSystems `System` converter in either direction.
- Foreign keys are off unless the consumer sets `PRAGMA foreign_keys = ON` on each connection.
- 4 of 55 tables are not `STRICT`: `entity_types`, `attributes`, `supplemental_attributes`, `plants`.

## [0.1.0] - 2026-09-11

First release. `PRAGMA user_version = 1`.

The schema version restarts at 1 for the first public release; the 14-19 ladder that
ran through the development stack was internal history and carries no meaning for a
consumer. Every later schema or registry change bumps it from here.

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

[Unreleased]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Sienna-Platform/SiennaGridDB/releases/tag/v0.1.0
