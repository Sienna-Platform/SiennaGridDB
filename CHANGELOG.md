# Changelog

All notable changes to SiennaGridDB are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project versions the
schema itself through `PRAGMA user_version`, bumped on every schema or registry change.

## [Unreleased]

### Schema

- `PRAGMA user_version = 6`.
- Every foreign-key column has an index. `scripts/generate_sql_schema.py` emits one for each
  generated column with `references`, and `schema.sql` adds the four hand-written ones that
  reference `entities`. Before, a bus delete scanned every device table for its cascade.
- A cost payload without its `cost_type` key fails the discriminator CHECK. Before, the missing
  key read as NULL, and a CHECK that evaluates to NULL passes. The `sources.operation_cost`
  default now carries `"cost_type": "IMPORTEXPORT"`.
- An update of `arcs.from_id` or `arcs.to_id` re-checks the AC/DC domain of every branch on that
  arc. Before, only an insert or update of the branch row was checked.
- The `id` of a generated table cannot change. Before, an update could re-parent the row onto
  an entities row of another subtype.
- The lookup tables `entity_types`, `prime_mover_types`, `fuels` and `storage_technology_types`
  are seeded in the generated region of `schema.sql`. Before, a database built from the SQL
  alone rejected every generator insert on its foreign keys until an insert SDK seeded them.
- `loads.base_power` must be positive, like every other `base_power`.
- `hydro_reservoir_connections` must connect `hydro_reservoirs`, `hydro_generators` or
  `storage_units` rows. Before, any two entities connected.
- A `time_series_associations.owner_type` must be its owner's `entities.entity_type`, a
  `Component` owner cannot be a supplemental attribute or plant, and a `Scenarios` row needs
  `scenario_count`.
- New index `idx_attributes_name` on `attributes (name, TYPE)`: triggers and views select by name.
- Removed `uq_ts_assoc`: `uq_ts_assoc_coalesced` rejects every row it rejected.

## [0.3.0] - 2026-10-27

Built from SiennaSchemas v0.3.0. `PRAGMA user_version = 5`.

### Breaking

- The DC current conventions are in kA, not A: `dc_current`, `max_dc_current`,
  `max_dc_current_from`, `max_dc_current_to`, `current_transfer_setpoint`, and
  `tmodel_hvdc_lines.base_current`. A 0.2 database holds these values 1000 times too large;
  rebuild it.
- The hydro `efficiency` attribute is a `Fraction`, not `Dimensionless`.

### Schema

- New table `series_compensators` (`SeriesCompensator`): a series capacitor or reactor, a
  TCSC, or an SSSC on an AC arc. `DISPATCHABLE` and `ACTIVE_POWER_FLOW` require
  `reactance_limits`; `ACTIVE_POWER_FLOW` also requires `active_power_flow_setpoint`.
- New attributes: `rated_dc_voltage` and `rated_ac_voltage` on `InterconnectingConverter`,
  and `scheduled_net_interchange` and `out_of_area_load_ids` on `Area`.
- A load listed in an `Area`'s `out_of_area_load_ids` cannot be deleted. Remove it from the
  list first. `attribute_references` in `sql_codegen_map.json` generates the trigger.
- `interval_alignment` is a reserved `feature_sets.key`.
- `scripts/generate_sql_schema.py` writes the per-table triggers into a marked region of
  `schema/triggers.sql`: entity-existence and delete triggers for every generated table, and
  the arc-domain triggers of each table with `arc_domain` in `sql_codegen_map.json`. A new
  table no longer needs hand-written triggers.
- New views `interface_member_tables` and `branch_names`, generated into
  `schema/views.sql` from `interface_member` in `sql_codegen_map.json`. The service
  association triggers and `interface_branch_directions` read them in place of hard-coded
  table lists.
- Every AC arc-domain error now ends with "use tmodel_hvdc_lines for DC-network branches".

### Unit registry

- `scripts/check_units_sync.py --psy-path` checks one more rule: a schema property with a fixed
  non-power unit (A, kA, ...) whose PowerSystems field converts by the power base. The check
  fails when GridDB stores the field, and warns when it does not.

### Fixed

- The schema update workflow no longer commits its SiennaSchemas checkout as a gitlink.
- The schema update workflow regenerates `schema/insert_manifest.json`. Before, the insert
  SDKs kept the previous `schema_user_version` and refused the new database.

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

[Unreleased]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Sienna-Platform/SiennaGridDB/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Sienna-Platform/SiennaGridDB/releases/tag/v0.1.0
