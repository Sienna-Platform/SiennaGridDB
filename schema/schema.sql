-- Requires SQLite >= 3.45. Test-only: drops every table below, so never run
-- against a live dataset.
PRAGMA user_version = 3; -- bump on every schema or registry change

DROP TABLE IF EXISTS prime_mover_types;

DROP TABLE IF EXISTS storage_technology_types;

DROP TABLE IF EXISTS service_associations;

DROP TABLE IF EXISTS entities;

DROP TABLE IF EXISTS time_series_associations;

DROP TABLE IF EXISTS feature_sets;

DROP TABLE IF EXISTS attribute_identifiers;

DROP TABLE IF EXISTS attributes;

DROP TABLE IF EXISTS static_time_series;

DROP TABLE IF EXISTS allowed_units;

DROP TABLE IF EXISTS entity_types;

DROP TABLE IF EXISTS supplemental_attributes;

DROP TABLE IF EXISTS hydro_reservoir_connections;

DROP TABLE IF EXISTS fuels;

DROP TABLE IF EXISTS supplemental_attribute_associations;

DROP TABLE IF EXISTS combined_cycle_associations;

DROP TABLE IF EXISTS plant_associations;

DROP TABLE IF EXISTS plants;

DROP TABLE IF EXISTS trading_hub_associations;

DROP TABLE IF EXISTS unit_conventions;

DROP TABLE IF EXISTS unit_basis_rules;

DROP TABLE IF EXISTS quantity_kinds;

DROP TABLE IF EXISTS unit_management_metadata;

-- PER-CONNECTION, AND NOT PERSISTED IN THE FILE. SQLite defaults this OFF on
-- every new connection, so this line governs the build only: it does not travel
-- with the database. Every consumer must issue `PRAGMA foreign_keys = ON` on
-- each connection it opens, or every foreign key in this schema is inert.
-- There is no file-level setting that changes this -- see README "Foreign keys".
PRAGMA foreign_keys = ON;

-- Populated automatically; do not insert or update rows directly.
CREATE TABLE entities (
    id INTEGER PRIMARY KEY,
    entity_table TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    FOREIGN KEY (entity_type) REFERENCES entity_types (name)
) strict;

-- is_dc marks the DC side of the network (PSY DCBus) as a property of the
-- type, not the row. It separates the two HVDC families: tmodel_hvdc_lines
-- arcs run between is_dc = 1 topologies; everything else, between is_dc = 0.
CREATE TABLE entity_types (
    name TEXT PRIMARY KEY,
    is_topology BOOLEAN NOT NULL DEFAULT FALSE,
    is_dc BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (is_dc = FALSE OR is_topology = TRUE)
);

CREATE TABLE prime_mover_types (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NULL
) strict;

CREATE TABLE fuels (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NULL
) strict;

CREATE TABLE storage_technology_types (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NULL
) strict;

-- One (service, member) pair (SiennaSchemas ServiceAssociation), the only record of
-- who contributes to a service; enforce_service_associations_domain_* keep members to
-- the service's kind. AUTOINCREMENT id for the reason given at plant_associations.
CREATE TABLE service_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    FOREIGN KEY (service_id) REFERENCES entities (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE (service_id, entity_id),
    CHECK (service_id <> entity_id)
) strict;

-- The UNIQUE pair serves by-service lookups; this one serves by-member lookups.
CREATE INDEX idx_service_associations_entity ON service_associations (entity_id);

CREATE TABLE hydro_reservoir_connections (
    source_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    sink_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    CHECK (source_id <> sink_id),
    PRIMARY KEY (source_id, sink_id)
) strict;

-- Holds a field that doesn't fit an entity table's typed columns (fixed or
-- variable O&M cost, etc.). Not for operational data -- that belongs in the
-- operational_data view.
CREATE TABLE attributes (
    id INTEGER PRIMARY KEY,
    entity_id INTEGER NOT NULL,
    TYPE TEXT NOT NULL,
    name TEXT NOT NULL,
    value JSON NOT NULL,
    unit TEXT NULL,
    quantity_kind TEXT NULL REFERENCES quantity_kinds (name),
    json_type TEXT generated always AS (json_type(value)) virtual,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE(entity_id, name)
);

-- (TYPE, name) pairs that hold an identifier, not a physical quantity (bus
-- numbers, node references, zone ids). Unit-validation triggers otherwise
-- classify any numeric JSON value as physical and demand a unit; listing the
-- pair here exempts it, instead of inventing a Dimensionless unit for a key.
-- Scoped by TYPE: a name is not an identifier on every component type.
CREATE TABLE attribute_identifiers (
    TYPE TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NULL,
    PRIMARY KEY (TYPE, name)
) strict;

-- Matches the LOWER(TYPE)/LOWER(name) predicate in the attributes unit triggers.
CREATE INDEX ix_attribute_identifiers_lower
    ON attribute_identifiers (LOWER(TYPE), LOWER(name));

-- Optional entity data not required for modeling (geolocation, outages, ...).
CREATE TABLE supplemental_attributes (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    TYPE TEXT NOT NULL,
    value JSON NOT NULL,
    json_type TEXT generated always AS (json_type (value)) virtual
);

-- Mirrors infrastore's supplemental_attribute_associations column-for-column
-- so rows deserialize straight into a store at the modeling stage. Identity
-- is the (component_id, attribute_id) pair; the type columns are denormalized
-- labels for filtering. The FKs are GridDB-side integrity infrastore omits,
-- since its endpoints live in the consumer's object graph, not a database.
CREATE TABLE supplemental_attribute_associations (
    id INTEGER PRIMARY KEY,
    component_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    component_type TEXT NOT NULL,
    attribute_id INTEGER NOT NULL REFERENCES supplemental_attributes (id) ON DELETE CASCADE,
    attribute_type TEXT NOT NULL
) strict;

-- uq_sa_assoc doubles as the by-component query index; the reverse direction
-- ("which components carry this attribute") needs its own.
CREATE UNIQUE INDEX uq_sa_assoc
    ON supplemental_attribute_associations (component_id, attribute_id);

CREATE INDEX idx_sa_assoc_attribute
    ON supplemental_attribute_associations (attribute_id, component_id, component_type);

CREATE TABLE plants (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    TYPE TEXT NOT NULL,
    value JSON,
    json_type TEXT generated always AS (json_type (value)) virtual
);

-- plant and combined-cycle membership are GridDB's own relationships, not a mirror of a
-- store catalog, so there is no store-minted association_id to carry. They get a local
-- surrogate instead: AUTOINCREMENT never reissues an id a delete freed, so a consumer
-- storing one cannot have it later resolve to a different row. The natural key stays
-- UNIQUE, so identity is unchanged by the surrogate.
CREATE TABLE plant_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plant_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    group_index INTEGER NOT NULL,
    FOREIGN KEY (plant_id) REFERENCES plants (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE (plant_id, entity_id)
) strict;

-- CombinedCycleBlock CT/CA <-> HRSG associations are n-to-m: a CT or CA can
-- feed multiple HRSGs and an HRSG can have multiple CTs/CAs. Kept in its own
-- table so (plant, entity) is not unique.
CREATE TABLE combined_cycle_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    plant_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('CT', 'CA')),
    hrsg_index INTEGER NOT NULL,
    FOREIGN KEY (plant_id) REFERENCES plants (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE (plant_id, entity_id, hrsg_index)
) strict;

-- Mirrors infrastore's catalog table column-for-column so a row deserializes
-- straight into a store, and projects onto the SiennaSchemas wire form.
-- owner_category / time_series_type hold the wire string spelling directly
-- (SiennaSchemas' OwnerCategory and the TimeSeriesAssociation discriminator
-- are both string enums). infrastore packs these as INTEGER codes for a
-- measured index-size win at its own scale; this schema states its priority
-- as user-friendly over performance (see the file header), so it stores the
-- spelling a reader or a wire payload actually uses, not infrastore's
-- internal encoding.
-- unit_system is lowercase 'natural_units' |
-- 'component_base' -- NOT the component tables' unit_basis vocabulary -- and
-- carries no CHECK so a third basis can land without a format bump.
-- quantity_kind is free-form: a CHECK would turn composite economic quantities
-- ($/MWh) into schema migrations. resolution / interval / horizon are ISO-8601
-- durations so calendar periods stay distinguishable from fixed ones.
-- time_reference NULL means unspecified, not UTC.
CREATE TABLE time_series_associations (
    -- The store-minted id, carried verbatim from the origin infrastore catalog;
    -- `association_id` is its spelling on the wire (SiennaSchemas cost-payload
    -- fields such as TimeSeriesLinearFunctionData.association_id and its
    -- siblings), not a second stored column. AUTOINCREMENT mirrors infrastore's
    -- own declaration and guarantees SQLite never reissues an id a delete freed,
    -- so a payload's reference either still resolves to the same row or fails
    -- outright, never silently landing on a different series that later reused
    -- the same number.
    --
    -- Meaningful only against its origin store: two rows from different stores
    -- can carry the same id by coincidence, so aggregating rows from more than
    -- one store means re-minting ids on import, exactly as infrastore's own
    -- `merge` does when copying series between stores.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    owner_type TEXT NOT NULL,
    owner_category TEXT NOT NULL CHECK (owner_category IN ('Component', 'SupplementalAttribute')),
    time_series_type TEXT NOT NULL CHECK (time_series_type IN (
        'SingleTimeSeries', 'NonSequentialTimeSeries', 'Deterministic',
        'DeterministicSingleTimeSeries', 'Probabilistic', 'Scenarios'
    )),
    name TEXT NOT NULL,
    initial_timestamp TEXT,
    resolution TEXT,
    length INTEGER,
    horizon TEXT,
    interval TEXT,
    count INTEGER,
    -- Scenarios only (time_series_type = 'Scenarios'), which requires it alongside count.
    scenario_count INTEGER,
    -- Lowercase hex SHA-256 (64 chars), matching infrastore's hash_hex spelling
    -- (crates/infrastore-core/src/hash.rs), not the raw 32-byte digest. TEXT
    -- over BLOB costs the ~32% catalog-space increase measured against the
    -- BLOB encoding -- accepted deliberately, because this schema states its
    -- priority as user-friendly over performance (see the file header), not
    -- something to "optimize" back to BLOB later. NULL means unspecified (a
    -- static series has no timestamp vector to hash).
    timestamps_hash TEXT CHECK (
        timestamps_hash IS NULL
        OR (length(timestamps_hash) = 64 AND timestamps_hash NOT GLOB '*[^0-9a-f]*')
    ),
    units TEXT,
    quantity_kind TEXT,
    unit_system TEXT,
    time_reference TEXT,
    component_field TEXT,
    percentiles_json TEXT,
    -- Three columns describe the stored values at two levels, per the wire
    -- schemas. ONE TIMESTEP: element_type says what a single step's value
    -- means and how it is laid out (a dtype spelling like 'f64', a
    -- 'tuple(N,dtype)', or a function-data kind); element_shape is that
    -- element's trailing dims after the time axis, '[]' for scalar steps.
    -- THE WHOLE ARRAY: array_shape is the full native geometry the store
    -- holds, whose trailing axes end with element_shape --
    -- [length, *element_shape] for static types, while forecasts prepend
    -- their window/percentile/scenario axes. It is not derivable from the
    -- other fields for forecasts (their layout is a producer convention), so
    -- NULL means unspecified and consumers fall back to
    -- horizon/count/percentiles/scenario_count, exact only for static types.
    element_type TEXT NOT NULL DEFAULT 'f64',
    element_shape TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(element_shape)),
    -- Wire-only for now: infrastore's catalog has no counterpart yet, same
    -- as scenario_count.
    array_shape TEXT NULL CHECK (
        array_shape IS NULL
        OR (json_valid(array_shape) AND json_type(array_shape) = 'array')
    ),
    application_data TEXT,
    uri TEXT NOT NULL,
    -- Lowercase hex SHA-256 (64 chars) per hash_hex, same rationale as
    -- timestamps_hash above. Optional (SiennaSchemas wire form): NULL means
    -- unspecified, not "hash of nothing".
    data_hash TEXT CHECK (
        data_hash IS NULL
        OR (length(data_hash) = 64 AND data_hash NOT GLOB '*[^0-9a-f]*')
    ),
    -- Lowercase hex SHA-256 (64 chars) per hash_hex, same rationale as
    -- timestamps_hash above. NOT NULL: every association carries a feature
    -- set, even an empty one.
    features_hash TEXT NOT NULL CHECK (
        length(features_hash) = 64 AND features_hash NOT GLOB '*[^0-9a-f]*'
    )
) strict;

-- Feature sets are content-addressed by the SHA-256 of the feature map and
-- stored once, shared by every association whose features_hash matches.
-- Deliberately NO foreign key and NO cascade (mirroring infrastore): rows are
-- shared, so deleting one association must not delete a set another still uses.
CREATE TABLE feature_sets (
    -- The wire schemas reserve the catalog's own field names as feature keys
    -- (TimeSeriesFeatures propertyNames) and infrastore rejects them in
    -- validate_features; this CHECK is the only enforcement at the DB layer.
    key TEXT NOT NULL CHECK (key NOT IN (
        'application_data', 'array_shape', 'association_id', 'component_field',
        'count', 'data', 'data_hash', 'dtype', 'element_shape', 'element_type',
        'ext', 'features', 'horizon', 'id', 'initial_timestamp', 'interval',
        'length', 'name', 'owner_category', 'owner_id', 'owner_type',
        'percentiles', 'quantity_kind', 'resolution', 'scenario_count',
        'time_reference', 'time_series_type', 'timestamps', 'timestamps_uri',
        'unit_system', 'units', 'uri'
    )),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('int', 'float', 'bool', 'str')),
    value_int INTEGER,
    value_float REAL,
    value_bool INTEGER,
    value_str TEXT,
    -- Same lowercase hex SHA-256 encoding as time_series_associations.features_hash
    -- (the join key between the two tables) -- it must match that column's
    -- storage class byte-for-byte, or the "shared by every association whose
    -- features_hash matches" contract above silently stops matching anything.
    features_hash TEXT NOT NULL CHECK (
        length(features_hash) = 64 AND features_hash NOT GLOB '*[^0-9a-f]*'
    ),
    PRIMARY KEY (features_hash, key)
) strict;

-- Both are needed: uq_ts_assoc cannot enforce uniqueness when resolution or
-- interval IS NULL (SQLite treats NULLs as distinct); the coalesced twin closes
-- that gap with the empty string, never a valid ISO-8601 period.
CREATE UNIQUE INDEX uq_ts_assoc ON time_series_associations
    (owner_id, owner_category, time_series_type, name, resolution, interval, features_hash);

CREATE UNIQUE INDEX uq_ts_assoc_coalesced ON time_series_associations
    (owner_id, owner_category, time_series_type, name,
     COALESCE(resolution, ''), COALESCE(interval, ''), features_hash);

-- Used on every static_time_series insert/update: the FK-style existence
-- check (triggers.sql) filters time_series_associations by uri per row.
CREATE INDEX idx_uri ON time_series_associations (uri);

-- One (trading hub, member) pair (PSY TradingHubAssociation). entity_id names
-- a bus or a market transaction settling at the hub, resolved through the
-- entities supertype. The surrogate id lets a consumer store a stable
-- reference: AUTOINCREMENT never reissues one a delete freed. The
-- (trading_hub_id, entity_id) pair stays UNIQUE.
CREATE TABLE trading_hub_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trading_hub_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    FOREIGN KEY (trading_hub_id) REFERENCES trading_hubs (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE (trading_hub_id, entity_id)
) strict;

-- Dense values, located by the association rows' uri (the role infrastore's
-- HDF5 half plays; here the uri IS the key into this table). One copy per
-- distinct array: associations sharing a uri share these rows, and the
-- association's optional data_hash lets a consumer verify the array's content.
-- Units/basis live on the association (units, quantity_kind, unit_system); a
-- COMPONENT_BASE series is interpreted against the owning component's own base
-- columns, so no per-series base snapshot is stored.
CREATE TABLE static_time_series (
    id INTEGER PRIMARY KEY,
    uri TEXT NOT NULL,
    -- The timestep's ordinal position within the array named by `uri`, 0-based
    -- (confirmed by test_static_time_series_rejects_duplicate_timepoint, whose
    -- first inserted timestep uses timestep = 0). Enforced unique per array by
    -- the (uri, timestep) index below.
    timestep INTEGER NOT NULL,
    value REAL NOT NULL
) strict;

-- UNIQUE: one value per (array, timepoint); loader double-inserts must fail
-- loudly rather than silently duplicate timepoints.
CREATE UNIQUE INDEX uq_static_time_series_uri_timestep ON static_time_series (uri, timestep);

-- Registry metadata, not runtime data; sealed and trigger-protected.
CREATE TABLE unit_management_metadata (
    KEY TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    description TEXT NULL
) strict;

CREATE TABLE quantity_kinds (
    name TEXT PRIMARY KEY NOT NULL,
    default_unit TEXT NOT NULL,
    dimension TEXT NOT NULL,
    description TEXT NULL
) strict;

-- Vocabulary of valid (quantity_kind, unit) pairs. Seeded from units.json and
-- sealed like the other registry tables; unit-string writes are validated
-- against it.
CREATE TABLE allowed_units (
    quantity_kind TEXT NOT NULL REFERENCES quantity_kinds (name),
    unit TEXT NOT NULL,
    PRIMARY KEY (quantity_kind, unit)
) strict;

CREATE TABLE unit_conventions (
    id INTEGER PRIMARY KEY,
    table_name TEXT NOT NULL,
    column_name TEXT NOT NULL,
    quantity_kind TEXT NOT NULL REFERENCES quantity_kinds (name),
    unit TEXT NOT NULL,
    -- Polymorphic units: when a column's unit depends on a sibling column's
    -- value (e.g. hydro_reservoirs.level_data_type), one row is registered
    -- per discriminator value. Both NULL for a column with one fixed unit.
    discriminator_column TEXT NULL,
    discriminator_value TEXT NULL,
    -- Optional second discriminator, for columns whose unit depends on a pair of
    -- sibling columns. NULL for every current convention (single or no
    -- discriminator); reserved for future use.
    discriminator_column_2 TEXT NULL,
    discriminator_value_2 TEXT NULL,
    -- Base reachable without leaving the database: NULL means same-row
    -- base_power/base_voltage; otherwise a same-row column name or an
    -- FK-hop path (col->table.col->table.base_col).
    base_power_ref TEXT NULL,
    base_voltage_ref TEXT NULL,
    description TEXT NULL,
    -- Distinct units per discriminator value (and quantity_kind, for columns
    -- like admittance whose NATURAL_UNITS value is disambiguated by quantity)
    -- for a polymorphic column.
    UNIQUE(table_name, column_name, discriminator_value, discriminator_value_2, quantity_kind)
) strict;

-- For non-polymorphic columns (no discriminator) enforce one row per column.
-- A table-level UNIQUE can't do this because SQLite treats each NULL
-- discriminator_value as distinct, so guard those rows with a partial index.
CREATE UNIQUE INDEX uq_unit_conventions_no_discriminator
    ON unit_conventions (table_name, column_name, quantity_kind)
    WHERE discriminator_value IS NULL;

-- The attributes unit triggers match on LOWER(column_name) / LOWER(TYPE),
-- which the plain UNIQUE constraints above cannot serve -- without these the
-- lookup degrades to a scan of every 'attributes' convention on every
-- attributes insert, the highest-volume write path in the schema.
CREATE INDEX ix_unit_conventions_table_lower_column
    ON unit_conventions (table_name, LOWER(column_name));

-- Per-quantity-type pu resolution rule: how to divide a COMPONENT_BASE value
-- down to a physical quantity, in terms of base_power/base_voltage (or a
-- unit_conventions base_power_ref/base_voltage_ref override).
CREATE TABLE unit_basis_rules (
    quantity_kind TEXT PRIMARY KEY REFERENCES quantity_kinds (name),
    base_expression TEXT NOT NULL,
    description TEXT NULL
) strict;

-- BEGIN GENERATED COMPONENT TABLES
-- Do not edit this region. scripts/generate_sql_schema.py writes it from the
-- SiennaSchemas components (schema/schema_map.json) and the per-table
-- dispositions (schema/sql_codegen_map.json). Edit those and regenerate.

-- Control or planning areas (PSY Area).
-- Components: Area
DROP TABLE IF EXISTS planning_regions;
CREATE TABLE planning_regions (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    description TEXT NULL,
    peak_active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    peak_reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    load_response REAL NOT NULL DEFAULT 0.0, -- Units: MW/Hz
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS'))
) STRICT;

-- Generic from/to link between entities, reused by transmission lines,
-- interchanges, HVDC lines, and other arc-based devices.
-- Components: Arc
DROP TABLE IF EXISTS arcs;
CREATE TABLE arcs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    from_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    to_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    CHECK (from_id <> to_id)
) STRICT;
CREATE INDEX idx_arcs_from ON arcs (from_id);
CREATE INDEX idx_arcs_to ON arcs (to_id);

-- Existing thermal generation units (ThermalStandard, ThermalMultiStart).
-- operation_cost stores the schemas' cost object verbatim. production_cost is a
-- GENERATED column that reads variable_operation_cost out of it, with no stored
-- copy. The curve states its own kind: COST is money, FUEL is a heat rate priced
-- via fuel_cost. Market-bid costs carry offer curves instead, so the
-- production-curve CHECKs skip them. A FuelCurve needs exactly one price source.
-- Components: ThermalStandard, ThermalMultiStart
-- Attributes: power_trajectory, start_time_limits, start_types
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS thermal_generators;
CREATE TABLE thermal_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    fuel TEXT NOT NULL DEFAULT 'OTHER' CHECK (fuel IN ('ANTHRACITE_COAL', 'BITUMINOUS_COAL', 'LIGNITE_COAL', 'SUBBITUMINOUS_COAL', 'WASTE_COAL', 'REFINED_COAL', 'SYNTHESIS_GAS_COAL', 'DISTILLATE_FUEL_OIL', 'JET_FUEL', 'KEROSENE', 'PETROLEUM_COKE', 'RESIDUAL_FUEL_OIL', 'PROPANE', 'SYNTHESIS_GAS_PETROLEUM_COKE', 'WASTE_OIL', 'BLAST_FURNACE_GAS', 'NATURAL_GAS', 'OTHER_GAS', 'AG_BYPRODUCT', 'MUNICIPAL_WASTE', 'OTHER_BIOMASS_SOLIDS', 'WOOD_WASTE_SOLIDS', 'OTHER_BIOMASS_LIQUIDS', 'SLUDGE_WASTE', 'BLACK_LIQUOR', 'WOOD_WASTE_LIQUIDS', 'LANDFILL_GAS', 'OTHER_BIOMASS_GAS', 'NUCLEAR', 'WASTE_HEAT', 'TIRE_DERIVED_FUEL', 'COAL', 'GEOTHERMAL', 'OTHER')) REFERENCES fuels(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_limits TEXT NOT NULL CHECK (json_valid(active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    ramp_limits TEXT NULL CHECK (json_valid(ramp_limits)), -- Units: per power_units (COMPONENT_BASE: pu/min, NATURAL_UNITS: MW/min)
    time_limits TEXT NULL CHECK (json_valid(time_limits)), -- Units: min
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    status TEXT NOT NULL CHECK (status IN ('OFFLINE', 'ONLINE', 'STARTUP', 'SHUTDOWN')),
    commitment_mode TEXT NOT NULL DEFAULT 'COMMITTED' CHECK (commitment_mode IN ('UNCOMMITTED', 'COMMITTED', 'SELF_SCHEDULED', 'RELIABILITY', 'MUST_RUN')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    operation_cost TEXT NOT NULL DEFAULT '{"cost_type":"THERMAL","fixed":0,"shut_down":0,"start_up":0,"variable_operation_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}}}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID', 'MARKET_BID_TIME_SERIES', 'THERMAL')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '') IN ('COST', 'FUEL')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '') IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE', 'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL', 'TIME_SERIES_AVERAGE_RATE')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type') <> 'FUEL' OR (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost') IS NOT NULL) <> (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost_time_series') IS NOT NULL)),
    production_cost TEXT GENERATED ALWAYS AS (json_extract(operation_cost, '$.variable_operation_cost')) VIRTUAL,
    time_at_status REAL NOT NULL DEFAULT 600000.0, -- Units: min
    switching_times TEXT NULL CHECK (json_valid(switching_times)) -- Units: min
) STRICT;

-- Existing renewable generation units (RenewableDispatch, RenewableNonDispatch).
-- operation_cost is NULL for RenewableNonDispatch, which has no cost. Its curve is
-- always a CostCurve: FUEL would admit rows with no registered unit.
-- Components: RenewableDispatch, RenewableNonDispatch
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS renewable_generators;
CREATE TABLE renewable_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    power_factor REAL NOT NULL DEFAULT 1.0 CHECK (power_factor > 0 AND power_factor <= 1.0), -- Units: 1
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    operation_cost TEXT NULL DEFAULT '{"cost_type":"RENEWABLE","curtailment_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}},"fixed":0,"variable_operation_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}}}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID', 'MARKET_BID_TIME_SERIES', 'RENEWABLE')) CHECK (operation_cost IS NULL OR json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '') = 'COST') CHECK (operation_cost IS NULL OR json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '') IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE', 'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL', 'TIME_SERIES_AVERAGE_RATE')),
    production_cost TEXT GENERATED ALWAYS AS (json_extract(operation_cost, '$.variable_operation_cost')) VIRTUAL
) STRICT;

-- Existing hydro generation units (HydroDispatch, HydroTurbine, HydroPumpTurbine).
-- HydroTurbine and HydroPumpTurbine fields are NULL for HydroDispatch.
-- operation_cost follows thermal_generators; its curve may be COST or FUEL.
-- Components: HydroDispatch, HydroTurbine, HydroPumpTurbine
-- Attributes: efficiency, turbine_type, active_power_limits_pump, active_power_pump, transition_time, minimum_time
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS hydro_generators;
CREATE TABLE hydro_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'HY' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_limits TEXT NOT NULL CHECK (json_valid(active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    ramp_limits TEXT NULL CHECK (json_valid(ramp_limits)), -- Units: per power_units (COMPONENT_BASE: pu/min, NATURAL_UNITS: MW/min)
    time_limits TEXT NULL CHECK (json_valid(time_limits)), -- Units: min
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    status TEXT NOT NULL DEFAULT 'OFFLINE' CHECK (status IN ('OFFLINE', 'ONLINE', 'STARTUP', 'SHUTDOWN')),
    commitment_mode TEXT NOT NULL DEFAULT 'COMMITTED' CHECK (commitment_mode IN ('UNCOMMITTED', 'COMMITTED', 'SELF_SCHEDULED', 'RELIABILITY', 'MUST_RUN')),
    operating_mode TEXT NULL DEFAULT 'OFF' CHECK (operating_mode IN ('PUMP', 'GEN', 'OFF')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    powerhouse_elevation REAL NULL DEFAULT 0.0 CHECK (powerhouse_elevation >= 0), -- Units: m
    outflow_limits TEXT NULL CHECK (json_valid(outflow_limits)), -- Units: m3/s
    conversion_factor REAL NULL DEFAULT 1.0 CHECK (conversion_factor > 0), -- Units: 1
    travel_time REAL NULL CHECK (travel_time >= 0), -- Units: min
    operation_cost TEXT NOT NULL DEFAULT '{"cost_type":"HYDRO_GEN","fixed":0.0,"variable_operation_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}}}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('HYDRO_GEN', 'IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID', 'MARKET_BID_TIME_SERIES')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '') IN ('COST', 'FUEL')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '') IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE', 'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL', 'TIME_SERIES_AVERAGE_RATE')) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES', 'IMPORT_EXPORT_TIME_SERIES') OR json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type') <> 'FUEL' OR (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost') IS NOT NULL) <> (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost_time_series') IS NOT NULL)),
    production_cost TEXT GENERATED ALWAYS AS (json_extract(operation_cost, '$.variable_operation_cost')) VIRTUAL,
    time_at_status REAL NOT NULL DEFAULT 600000.0 -- Units: min
) STRICT;

-- Existing energy storage units, including PHES and other kinds.
-- energy_units MWMIN makes duration = energy / power come out in minutes.
-- operation_cost is the whole StorageCost object: two curves, so neither becomes
-- a production_cost column.
-- Components: EnergyReservoirStorage
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS storage_units;
CREATE TABLE storage_units (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    storage_technology_type TEXT NOT NULL CHECK (storage_technology_type IN ('PTES', 'LIB', 'LAB', 'FLWB', 'SIB', 'ZIB', 'HGS', 'LAES', 'OTHER_CHEM', 'OTHER_MECH', 'OTHER_THERM')) REFERENCES storage_technology_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    storage_capacity REAL NOT NULL CHECK (storage_capacity >= 0), -- Units: per energy_units (MWH: MWh, MWMIN: MWmin)
    energy_units TEXT NOT NULL DEFAULT 'MWH' CHECK (energy_units IN ('MWH', 'MWMIN')),
    storage_level_limits TEXT NOT NULL CHECK (json_valid(storage_level_limits)),
    initial_storage_capacity_level REAL NOT NULL CHECK (initial_storage_capacity_level >= 0), -- Units: 1
    input_active_power_limits TEXT NOT NULL CHECK (json_valid(input_active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    output_active_power_limits TEXT NOT NULL CHECK (json_valid(output_active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    efficiency TEXT NOT NULL CHECK (json_valid(efficiency)),
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    conversion_factor REAL NOT NULL DEFAULT 1.0 CHECK (conversion_factor > 0), -- Units: 1
    storage_target REAL NOT NULL DEFAULT 0.0, -- Units: 1
    cycle_limits INTEGER NOT NULL DEFAULT 10000 CHECK (cycle_limits > 0), -- Units: 1
    ramp_limits TEXT NULL CHECK (json_valid(ramp_limits)), -- Units: per power_units (COMPONENT_BASE: pu/min, NATURAL_UNITS: MW/min)
    self_discharge REAL NOT NULL DEFAULT 0.0 CHECK (self_discharge >= 0), -- Units: 1/min
    standing_loss REAL NOT NULL DEFAULT 0.0 CHECK (standing_loss >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    operation_cost TEXT NOT NULL DEFAULT '{"charge_variable_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST"},"cost_type":"STORAGE","discharge_variable_cost":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST"}}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID', 'MARKET_BID_TIME_SERIES', 'STORAGE'))
) STRICT;

-- Topological hydro reservoirs. operation_cost is always USD/MWh: level-native
-- values convert to energy via head_to_volume_factor before costing.
-- Components: HydroReservoir
-- Attributes: upstream_turbines, downstream_turbines, upstream_reservoirs
DROP TABLE IF EXISTS hydro_reservoirs;
CREATE TABLE hydro_reservoirs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    storage_level_limits TEXT NOT NULL CHECK (json_valid(storage_level_limits)), -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    initial_level REAL NOT NULL, -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    spillage_limits TEXT NULL CHECK (json_valid(spillage_limits)), -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    inflow REAL NOT NULL DEFAULT 0.0, -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    outflow REAL NOT NULL DEFAULT 0.0, -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    level_targets REAL NULL, -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    intake_elevation REAL NOT NULL DEFAULT 0.0, -- Units: m
    head_to_volume_factor TEXT NOT NULL CHECK (json_valid(head_to_volume_factor)),
    operation_cost TEXT NOT NULL DEFAULT '{"cost_type":"HYDRO_RES","level_shortage_cost":0.0,"level_surplus_cost":0.0,"spillage_cost":0.0}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('HYDRO_RES', 'IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID_TIME_SERIES')),
    level_data_type TEXT NOT NULL DEFAULT 'USABLE_VOLUME' CHECK (level_data_type IN ('USABLE_VOLUME', 'TOTAL_VOLUME', 'HEAD', 'ENERGY')),
    evaporative_loss REAL NOT NULL DEFAULT 0.0 CHECK (evaporative_loss >= 0) -- Units: 1
) STRICT;

-- Loads of every PSY type. The ZIP-model breakdown is present on only two of
-- the seven load types, so it lives in the attributes table.
-- Components: PowerLoad, StandardLoad, InterruptiblePowerLoad, InterruptibleStandardLoad, MotorLoad, ExponentialLoad, ShiftablePowerLoad
-- Attributes: constant_active_power, constant_reactive_power, impedance_active_power, impedance_reactive_power, current_active_power, current_reactive_power, max_constant_active_power, max_constant_reactive_power, max_impedance_active_power, max_impedance_reactive_power, max_current_active_power, max_current_reactive_power, operation_cost, rating, reactive_power_limits, motor_technology, alpha, beta, active_power_limits, load_balance_time_horizon
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS loads;
CREATE TABLE loads (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    base_power REAL NOT NULL, -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    max_active_power REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    max_reactive_power REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    conformity TEXT NULL DEFAULT 'UNDEFINED' CHECK (conformity IN ('NON_CONFORMING', 'CONFORMING', 'UNDEFINED'))
) STRICT;

-- r/x/b/g follow parameter_units: COMPONENT_BASE is per-unit on base_power;
-- NATURAL_UNITS is ohm (r/x) or siemens (b/g). All four share one row's basis
-- (PSY writes COMPONENT_BASE; a matpower import is NATURAL_UNITS). b/g are
-- JSON {"from": ..., "to": ...}; base_power is expected equal across every
-- COMPONENT_BASE row, though that is not trigger-enforced.
-- power_units is independent of parameter_units: it governs only the power-family
-- columns (ratings, limits, ramp rates). parameter_units's DEFAULT is a DB
-- convenience; the wire schema requires the field with no default.
-- Components: Line
DROP TABLE IF EXISTS transmission_lines;
CREATE TABLE transmission_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    continuous_rating REAL NOT NULL CHECK (continuous_rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    ste_rating REAL NULL CHECK (ste_rating >= 0),
    lte_rating REAL NULL CHECK (lte_rating >= 0),
    line_length REAL NULL CHECK (line_length >= 0),
    r REAL NOT NULL CHECK (r >= 0), -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x REAL NOT NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    b TEXT NULL CHECK (json_valid(b)), -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: S)
    g TEXT NOT NULL DEFAULT '{"from":0.0,"to":0.0}' CHECK (json_valid(g)), -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: S)
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('NATURAL_UNITS', 'COMPONENT_BASE')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    rating_b REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    rating_c REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    operational_flow_limit TEXT NULL CHECK (json_valid(operational_flow_limit)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    angle_limits TEXT NOT NULL CHECK (json_valid(angle_limits)) -- Units: rad
) STRICT;

-- Physical flow limits between areas or balancing topologies, distinct from
-- transmission_lines: these enforce market-level interchange limits.
-- Components: AreaInterchange
-- flow_limits is stored as: max_flow_from, max_flow_to
DROP TABLE IF EXISTS transmission_interchanges;
CREATE TABLE transmission_interchanges (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER REFERENCES arcs (id) ON DELETE CASCADE,
    max_flow_from REAL NOT NULL,
    max_flow_to REAL NOT NULL,
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    from_area INTEGER NOT NULL REFERENCES planning_regions (id) ON DELETE CASCADE,
    to_area INTEGER NOT NULL REFERENCES planning_regions (id) ON DELETE CASCADE
) STRICT;

-- Reserve products (PSY OnlineReserve, OfflineReserve, GroupReserve), one table
-- discriminated by entities.entity_type. enforce_reserves_type_shape_* keep each
-- row to its type's fields, so fields absent from a type have no DB default.
-- requirement has none either: a GroupReserve without one is rejected.
-- Contributors are service_associations rows.
-- Components: OnlineReserve, OfflineReserve, GroupReserve
DROP TABLE IF EXISTS reserves;
CREATE TABLE reserves (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    time_frame REAL NULL, -- Units: min
    requirement REAL NOT NULL, -- Units: MW
    sustained_time REAL NULL, -- Units: min
    max_output_fraction REAL NULL CHECK (max_output_fraction BETWEEN 0 AND 1),
    max_participation_factor REAL NULL CHECK (max_participation_factor BETWEEN 0 AND 1),
    deployed_fraction REAL NULL CHECK (deployed_fraction BETWEEN 0 AND 1),
    reserve_direction TEXT NULL CHECK (reserve_direction IN ('UP', 'DOWN', 'SYMMETRIC')),
    variable TEXT NULL CHECK (json_valid(variable))
) STRICT;

-- Flow limit on a set of branches (PSY TransmissionInterface). direction_mapping
-- is the schemas' branch name -> 1 or -1 object, verbatim; the member branches
-- are service_associations rows.
-- Components: TransmissionInterface
DROP TABLE IF EXISTS transmission_interfaces;
CREATE TABLE transmission_interfaces (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power_flow_limits TEXT NOT NULL CHECK (json_valid(active_power_flow_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    violation_penalty REAL NULL,
    direction_mapping TEXT NULL CHECK (json_valid(direction_mapping)) CHECK (json_type(direction_mapping) = 'object'),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS'))
) STRICT;

-- Switches and breakers connecting AC buses (PSY DiscreteControlledACBranch).
-- r/x are always per-unit on base_power -- this component has no
-- natural-units option in PSY, unlike transmission_lines. rating follows
-- power_units, like transmission_lines.continuous_rating.
-- Components: DiscreteControlledACBranch
-- Not stored: available, active_power_flow, reactive_power_flow
DROP TABLE IF EXISTS discrete_controlled_ac_branches;
CREATE TABLE discrete_controlled_ac_branches (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL CHECK (r >= 0), -- Units: pu
    x REAL NOT NULL CHECK (x >= 0), -- Units: pu
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    discrete_branch_type TEXT NOT NULL DEFAULT 'OTHER' CHECK (discrete_branch_type IN ('SWITCH', 'BREAKER', 'OTHER')),
    branch_status TEXT NOT NULL DEFAULT 'CLOSED' CHECK (branch_status IN ('OPEN', 'CLOSED')),
    normal_branch_status TEXT NOT NULL DEFAULT 'CLOSED' CHECK (normal_branch_status IN ('OPEN', 'CLOSED')),
    operational_flow_limit TEXT NULL CHECK (json_valid(operational_flow_limit)) -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
) STRICT;

-- One modeled arc of a transformer (PSY TransformerCircuit); unnamed
-- subcomponents, so no name column. r/x follow parameter_units (COMPONENT_BASE ->
-- pu on base_power/base_voltage_primary; NATURAL_UNITS -> ohm). r/x have no sign
-- CHECK: a three-winding star-leg reactance may be negative. Each control band
-- has one fixed unit.
-- Components: TransformerCircuit
DROP TABLE IF EXISTS transformer_circuits;
CREATE TABLE transformer_circuits (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    tap REAL NOT NULL DEFAULT 1.0 CHECK (tap >= 0 AND tap <= 2), -- Units: 1
    alpha REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('NATURAL_UNITS', 'COMPONENT_BASE')),
    control_objective TEXT NOT NULL DEFAULT 'UNDEFINED' CHECK (control_objective IN ('UNDEFINED', 'VOLTAGE_DISABLED', 'REACTIVE_POWER_FLOW_DISABLED', 'ACTIVE_POWER_FLOW_DISABLED', 'CONTROL_OF_DC_LINE_DISABLED', 'ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED', 'FIXED', 'VOLTAGE', 'REACTIVE_POWER_FLOW', 'ACTIVE_POWER_FLOW', 'CONTROL_OF_DC_LINE', 'ASYMMETRIC_ACTIVE_POWER_FLOW')),
    regulated_bus_number INTEGER NOT NULL DEFAULT 0,
    number_of_tap_positions INTEGER NOT NULL DEFAULT 33,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    rating_b REAL NULL CHECK (rating_b >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    rating_c REAL NULL CHECK (rating_c >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_voltage_primary REAL NULL CHECK (base_voltage_primary > 0), -- Units: kV
    base_voltage_secondary REAL NULL CHECK (base_voltage_secondary > 0), -- Units: kV
    tap_ratio_limits TEXT NULL CHECK (json_valid(tap_ratio_limits)), -- Units: 1
    phase_angle_limits TEXT NULL CHECK (json_valid(phase_angle_limits)), -- Units: rad
    controlled_voltage_limits TEXT NULL CHECK (json_valid(controlled_voltage_limits)), -- Units: pu
    controlled_reactive_power_flow_limits TEXT NULL CHECK (json_valid(controlled_reactive_power_flow_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    controlled_active_power_flow_limits TEXT NULL CHECK (json_valid(controlled_active_power_flow_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    operational_flow_limit TEXT NULL CHECK (json_valid(operational_flow_limit)) -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
) STRICT;

-- Two-winding transformer (PSY TwoWindingTransformer); series data lives on
-- the referenced circuit. magnetizing_shunt is a complex admittance as JSON
-- {"real": ..., "imag": ...} (real = conductance, imag = susceptance).
-- A circuit is owned by exactly one transformer slot, so the circuit indexes are UNIQUE.
-- Sharing one circuit between a two- and a three-winding transformer is not trigger-enforced.
-- Components: TwoWindingTransformer
-- Not stored: admittance_units
DROP TABLE IF EXISTS two_winding_transformers;
CREATE TABLE two_winding_transformers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    magnetizing_shunt TEXT NOT NULL DEFAULT '{"imag":0.0,"real":0.0}' CHECK (json_valid(magnetizing_shunt)), -- Units: per admittance_units (COMPONENT_BASE: pu, COMPONENT_MVAR: MVAr, NATURAL_UNITS: S)
    shunt_location TEXT NOT NULL DEFAULT 'PRIMARY' CHECK (shunt_location IN ('PRIMARY', 'SECONDARY', 'SPLIT'))
) STRICT;
CREATE UNIQUE INDEX idx_two_winding_transformers_circuit ON two_winding_transformers (circuit);

-- Three-winding transformer (PSY ThreeWindingTransformer), star model: each
-- circuit connects a terminal bus to the star bus. The pairwise measured-impedance
-- fields are all-or-none (table CHECK); star-leg impedances derived from them
-- live on the circuits and are not synced back.
-- Components: ThreeWindingTransformer
-- Not stored: admittance_units
DROP TABLE IF EXISTS three_winding_transformers;
CREATE TABLE three_winding_transformers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    primary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    secondary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    tertiary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    star_bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    r_12 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x_12 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    r_23 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x_23 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    r_31 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x_31 REAL NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('NATURAL_UNITS', 'COMPONENT_BASE')),
    base_power_12 REAL NULL CHECK (base_power_12 > 0), -- Units: MVA
    base_power_23 REAL NULL CHECK (base_power_23 > 0), -- Units: MVA
    base_power_31 REAL NULL CHECK (base_power_31 > 0), -- Units: MVA
    magnetizing_shunt TEXT NOT NULL DEFAULT '{"imag":0.0,"real":0.0}' CHECK (json_valid(magnetizing_shunt)), -- Units: per admittance_units (COMPONENT_BASE: pu, COMPONENT_MVAR: MVAr, NATURAL_UNITS: S)
    shunt_location TEXT NOT NULL DEFAULT 'PRIMARY' CHECK (shunt_location IN ('PRIMARY', 'STAR')),
    CHECK (primary_circuit <> secondary_circuit AND primary_circuit <> tertiary_circuit AND secondary_circuit <> tertiary_circuit),
    CHECK ((r_12 IS NULL) + (x_12 IS NULL) + (r_23 IS NULL) + (x_23 IS NULL) + (r_31 IS NULL) + (x_31 IS NULL) + (base_power_12 IS NULL) + (base_power_23 IS NULL) + (base_power_31 IS NULL) IN (0, 9))
) STRICT;
CREATE UNIQUE INDEX idx_three_winding_transformers_primary_circuit ON three_winding_transformers (primary_circuit);
CREATE UNIQUE INDEX idx_three_winding_transformers_secondary_circuit ON three_winding_transformers (secondary_circuit);
CREATE UNIQUE INDEX idx_three_winding_transformers_tertiary_circuit ON three_winding_transformers (tertiary_circuit);
CREATE INDEX idx_three_winding_transformers_star_bus ON three_winding_transformers (star_bus);

-- Point-to-point (two-terminal) HVDC line, one table for all three PSY variants
-- (Generic/LCC/VSC), discriminated by converter_type. Only fields common to
-- all three are columns; variant-specific fields (LCC rectifier/inverter
-- detail, VSC controls, loss curves) live in the generic attributes table.
-- Both terminals are AC buses, DC side internal -- unlike tmodel_hvdc_lines,
-- which runs between DC buses for multi-terminal networks.
-- Components: TwoTerminalGenericHVDCLine, TwoTerminalLCCLine, TwoTerminalVSCLine
-- Attributes: loss, r, power_transfer_setpoint, current_transfer_setpoint, scheduled_dc_voltage, rectifier_bridges, rectifier_delay_angle_limits, rectifier_rc, rectifier_xc, rectifier_base_voltage, inverter_bridges, inverter_extinction_angle_limits, inverter_rc, inverter_xc, inverter_base_voltage, control_mode, switch_mode_voltage, compounding_resistance, min_compounding_voltage, rectifier_transformer_ratio, rectifier_tap_setting, rectifier_tap_limits, rectifier_tap_step, rectifier_delay_angle, rectifier_capacitor_reactance, inverter_transformer_ratio, inverter_tap_setting, inverter_tap_limits, inverter_tap_step, inverter_extinction_angle, inverter_capacitor_reactance, g, dc_current, reactive_power_from, dc_control_from, ac_control_from, dc_power_setpoint_from, dc_voltage_setpoint_from, power_factor_setpoint_from, ac_voltage_setpoint_from, rated_ac_voltage_from, converter_loss_from, max_dc_current_from, power_factor_weighting_fraction_from, voltage_limits_from, dc_voltage_droop_from, reactive_power_to, dc_control_to, ac_control_to, dc_power_setpoint_to, dc_voltage_setpoint_to, power_factor_setpoint_to, ac_voltage_setpoint_to, rated_ac_voltage_to, converter_loss_to, max_dc_current_to, power_factor_weighting_fraction_to, voltage_limits_to, dc_voltage_droop_to, rated_dc_voltage, remote_bus_control_from, remote_bus_control_to
DROP TABLE IF EXISTS two_terminal_hvdc_lines;
CREATE TABLE two_terminal_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    converter_type TEXT NOT NULL DEFAULT 'GENERIC' CHECK (converter_type IN ('GENERIC', 'LCC', 'VSC')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    rating_from REAL NULL CHECK (rating_from >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    rating_to REAL NULL CHECK (rating_to >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    reactive_power_limits_from TEXT NOT NULL CHECK (json_valid(reactive_power_limits_from)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    reactive_power_limits_to TEXT NOT NULL CHECK (json_valid(reactive_power_limits_to)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    operational_flow_limit TEXT NULL CHECK (json_valid(operational_flow_limit)) -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
) STRICT;

-- T-model HVDC line (PSY TModelHVDCLine): a DC-network element whose arc
-- endpoints must both be DC buses (entity_types.is_dc = 1), enforced by
-- enforce_tmodel_hvdc_lines_arc_domain. It is the multi-terminal building
-- block, paired with interconnecting_converters at each AC/DC boundary --
-- use two_terminal_hvdc_lines for point-to-point HVDC. r, l and c are natural
-- units only. base_current, not base_power, is the row's base: the DC line
-- current is the value that is actually known.
-- Components: TModelHVDCLine
DROP TABLE IF EXISTS tmodel_hvdc_lines;
CREATE TABLE tmodel_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL, -- Units: ohm
    base_current REAL NOT NULL CHECK (base_current > 0), -- Units: A
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: MW
    l REAL NOT NULL, -- Units: H
    c REAL NOT NULL, -- Units: F
    operational_flow_limit TEXT NULL CHECK (json_valid(operational_flow_limit)) -- Units: MW
) STRICT;

-- Synchronous machine for inertia or reactive support (PSY SynchronousCondenser).
-- It injects no active power, so there is no active_power column;
-- active_power_losses is the loss incurred by being online. Power-family
-- columns follow power_units (COMPONENT_BASE -> pu; NATURAL_UNITS -> physical unit).
-- Components: SynchronousCondenser
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS synchronous_condensers;
CREATE TABLE synchronous_condensers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    rating REAL NOT NULL CHECK (rating > 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    active_power_losses REAL NOT NULL DEFAULT 0.0 CHECK (active_power_losses >= 0) -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
) STRICT;

-- Fixed shunt admittance (PSY FixedAdmittance): Y as conductance (y_g) and
-- susceptance (y_b). admittance_units is NATURAL_UNITS (siemens) or
-- COMPONENT_MVAR (MW/MVAr at unity voltage, PSS/E native) -- no per-unit arm,
-- since a shunt has no MVA rating; base_power is just the recorded base.
-- Components: FixedAdmittance
-- Not stored: dynamic_injector
-- Y is stored as: y_g, y_b
DROP TABLE IF EXISTS fixed_admittance;
CREATE TABLE fixed_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    y_g REAL NOT NULL DEFAULT 0.0,
    y_b REAL NOT NULL DEFAULT 0.0,
    admittance_units TEXT NOT NULL DEFAULT 'COMPONENT_MVAR' CHECK (admittance_units IN ('NATURAL_UNITS', 'COMPONENT_MVAR')),
    base_power REAL NOT NULL CHECK (base_power > 0) -- Units: MVA
) STRICT;

-- Switched shunt admittance (PSY SwitchedAdmittance). Effective admittance is
-- number_engaged * Y_increase, or solved_admittance when present.
-- admittance_units is NATURAL_UNITS (siemens) or COMPONENT_MVAR (MW/MVAr at
-- unity voltage, PSS/E native). No base_power: neither basis needs one.
-- Components: SwitchedAdmittance
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS switched_admittance;
CREATE TABLE switched_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    admittance_units TEXT NOT NULL DEFAULT 'COMPONENT_MVAR' CHECK (admittance_units IN ('NATURAL_UNITS', 'COMPONENT_MVAR')),
    Y_increase TEXT NULL CHECK (json_valid(Y_increase)), -- Units: per admittance_units (COMPONENT_MVAR: MVAr, NATURAL_UNITS: S)
    number_engaged TEXT NULL CHECK (json_valid(number_engaged)),
    number_of_steps TEXT NULL CHECK (json_valid(number_of_steps)),
    solved_admittance REAL NULL, -- Units: per admittance_units (COMPONENT_MVAR: MVAr, NATURAL_UNITS: S)
    control_mode TEXT NOT NULL DEFAULT 'FIXED' CHECK (control_mode IN ('UNDEFINED', 'FIXED', 'DISCRETE_VOLTAGE', 'CONTINUOUS_VOLTAGE', 'DISCRETE_REACTIVE_PLANT', 'DISCRETE_REACTIVE_VSC', 'DISCRETE_ADMITTANCE_REMOTE', 'DISCRETE_REACTIVE_FACTS')),
    regulated_bus_number INTEGER NOT NULL DEFAULT 0, -- Units: 1
    voltage_limits TEXT NULL CHECK (json_valid(voltage_limits)), -- Units: pu
    reactive_power_range_limits TEXT NULL CHECK (json_valid(reactive_power_range_limits)) -- Units: 1
) STRICT;

-- Thevenin equivalent source (PSY Source). r_th/x_th follow parameter_units: pu on
-- base_power, or natural-units ohm; COMPONENT_BASE is the default since PSY
-- has no native external representation for this component. Column names are
-- lowercase (the schemas spell R_th/X_th) -- a naming difference only, see
-- sql_codegen_map.json. Power-family columns follow power_units instead,
-- independent of parameter_units.
-- Components: Source
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS sources;
CREATE TABLE sources (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    base_voltage REAL NULL CHECK (base_voltage > 0), -- Units: kV
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    active_power_limits TEXT NOT NULL DEFAULT '{"max":0.0,"min":0.0}' CHECK (json_valid(active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_limits TEXT NOT NULL DEFAULT '{"max":0.0,"min":0.0}' CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    internal_voltage REAL NOT NULL DEFAULT 1.0 CHECK (internal_voltage >= 0), -- Units: pu
    internal_angle REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r_th REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    x_th REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: ohm)
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('NATURAL_UNITS', 'COMPONENT_BASE')),
    operation_cost TEXT NOT NULL DEFAULT '{"ancillary_service_offers":[],"energy_export_weekly_limit":1000000.0,"energy_import_weekly_limit":1000000.0,"export_offer_curves":null,"import_offer_curves":null}' CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('IMPORTEXPORT', 'IMPORT_EXPORT_TIME_SERIES', 'MARKET_BID_TIME_SERIES'))
) STRICT;

-- Interconnecting power converter (PSY InterconnectingConverter), an AC<->DC
-- bus converter. bus is the AC side, dc_bus the DC side; the domain of each is
-- enforced by enforce_interconnecting_converters_bus_domain, since a plain FK
-- cannot see the entity_types.is_dc flag. Each setpoint has one fixed unit.
-- Components: InterconnectingConverter
-- Attributes: dc_current, max_dc_current, loss_function, dc_voltage_droop
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS interconnecting_converters;
CREATE TABLE interconnecting_converters (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    dc_bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    dc_control TEXT NOT NULL DEFAULT 'DC_VOLTAGE' CHECK (dc_control IN ('DC_POWER', 'DC_VOLTAGE', 'DC_VOLTAGE_DROOP')),
    ac_control TEXT NOT NULL DEFAULT 'AC_REACTIVE_POWER' CHECK (ac_control IN ('AC_REACTIVE_POWER', 'AC_VOLTAGE')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    remote_bus_control INTEGER NULL CHECK (remote_bus_control >= 1),
    power_factor_weighting_fraction REAL NOT NULL DEFAULT 1.0 CHECK (power_factor_weighting_fraction >= 0), -- Units: 1
    voltage_limits TEXT NOT NULL DEFAULT '{"max":999.9,"min":0.0}' CHECK (json_valid(voltage_limits)), -- Units: kV
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power REAL NOT NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    rating REAL NOT NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    active_power_limits TEXT NOT NULL CHECK (json_valid(active_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    reactive_power_limits TEXT NULL CHECK (json_valid(reactive_power_limits)), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    dc_power_setpoint REAL NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MW)
    dc_voltage_setpoint REAL NULL, -- Units: kV
    power_factor_setpoint REAL NULL CHECK (power_factor_setpoint >= -1.0) CHECK (power_factor_setpoint <= 1.0), -- Units: 1
    ac_voltage_setpoint REAL NULL, -- Units: kV
    CHECK (bus <> dc_bus)
) STRICT;

-- FACTS control device (PSY FACTSControlDevice). voltage_setpoint is stored flexibly
-- per parameter_units (COMPONENT_BASE: pu on bus base_voltage, the native external form;
-- NATURAL_UNITS: kV). power_units is a second, independent discriminator governing
-- max_reactive_power (COMPONENT_BASE: pu; NATURAL_UNITS: MVAr).
-- Components: FACTSControlDevice
-- Not stored: dynamic_injector
DROP TABLE IF EXISTS facts_control_devices;
CREATE TABLE facts_control_devices (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    voltage_setpoint REAL NOT NULL, -- Units: per parameter_units (COMPONENT_BASE: pu, NATURAL_UNITS: kV)
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('NATURAL_UNITS', 'COMPONENT_BASE')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    max_reactive_power REAL NOT NULL DEFAULT 9999.0 CHECK (max_reactive_power >= 0), -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVAr)
    shunt_control_type TEXT NOT NULL DEFAULT 'STATCOM' CHECK (shunt_control_type IN ('SVC', 'STATCOM')),
    regulated_bus_number INTEGER NOT NULL DEFAULT 0, -- Units: 1
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    control_mode TEXT NULL CHECK (control_mode IN ('OOS', 'NML', 'BYP')),
    max_shunt_current REAL NOT NULL, -- Units: per power_units (COMPONENT_BASE: pu, NATURAL_UNITS: MVA)
    reactive_power_required REAL NOT NULL -- Units: 1
) STRICT;

-- Balancing topologies for the system: buses (ACBus, DCBus) or larger aggregated
-- regions (LoadZone). load_zone and area reference other rows.
-- Components: ACBus, DCBus, LoadZone
-- Attributes: peak_active_power, peak_reactive_power, base_power
-- Not stored: power_units
DROP TABLE IF EXISTS balancing_topologies;
CREATE TABLE balancing_topologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    area INTEGER NULL REFERENCES planning_regions (id) ON DELETE SET NULL,
    description TEXT NULL,
    base_voltage REAL NULL CHECK (base_voltage > 0), -- Units: kV
    number INTEGER NULL,
    available INTEGER NULL DEFAULT 1 CHECK (available IN (0, 1)),
    bustype TEXT NULL CHECK (bustype IN ('PQ', 'PV', 'REF', 'ISOLATED', 'SLACK')),
    angle REAL NULL, -- Units: rad
    magnitude REAL NULL, -- Units: pu
    voltage_limits TEXT NULL CHECK (json_valid(voltage_limits)), -- Units: pu
    load_zone INTEGER NULL REFERENCES balancing_topologies (id) ON DELETE SET NULL
) STRICT;

-- Investment technology options for expansion problems
-- Components: SupplyTechnology
DROP TABLE IF EXISTS supply_technologies;
CREATE TABLE supply_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    region TEXT NOT NULL CHECK (json_valid(region)),
    power_systems_type TEXT NOT NULL,
    lifetime INTEGER NOT NULL DEFAULT 100, -- Units: yr
    unit_size REAL NOT NULL DEFAULT 0.0, -- Units: MW
    capacity_limits TEXT NULL CHECK (json_valid(capacity_limits)), -- Units: MW
    fuel TEXT NOT NULL DEFAULT '["OTHER"]' CHECK (json_valid(fuel)),
    start_fuel_mmbtu_per_mw REAL NOT NULL DEFAULT 0.0, -- Units: MMBtu/MW
    cofire_level_limits TEXT NULL CHECK (json_valid(cofire_level_limits)), -- Units: 1
    cofire_start_limits TEXT NULL CHECK (json_valid(cofire_start_limits)), -- Units: 1
    co2 TEXT NULL,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    ramp_limits TEXT NULL CHECK (json_valid(ramp_limits)), -- Units: MW/min
    time_limits TEXT NULL CHECK (json_valid(time_limits)), -- Units: min
    outage_factor TEXT NULL CHECK (json_valid(outage_factor)),
    min_generation_fraction REAL NOT NULL DEFAULT 0.0, -- Units: 1
    capital_costs TEXT NOT NULL DEFAULT '{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}' CHECK (json_valid(capital_costs)),
    operation_costs TEXT NOT NULL DEFAULT '{"cost_type":"THERMAL","fixed":0,"shut_down":0,"start_up":0,"variable":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}}}' CHECK (json_valid(operation_costs)), -- Units: USD/MWh
    financial_data TEXT NOT NULL CHECK (json_valid(financial_data))
) STRICT;

-- Components: StorageTechnology
-- capital_costs is stored as: capital_costs_charge, capital_costs_discharge, capital_costs_energy, interconnection_cost
DROP TABLE IF EXISTS storage_technologies;
CREATE TABLE storage_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types(name),
    storage_tech TEXT NOT NULL CHECK (storage_tech IN ('PTES', 'LIB', 'LAB', 'FLWB', 'SIB', 'ZIB', 'HGS', 'LAES', 'OTHER_CHEM', 'OTHER_MECH', 'OTHER_THERM')),
    region TEXT NOT NULL CHECK (json_valid(region)),
    power_systems_type TEXT NOT NULL,
    lifetime INTEGER NOT NULL DEFAULT 100, -- Units: yr
    unit_size_charge REAL NULL, -- Units: MW
    unit_size_discharge REAL NOT NULL DEFAULT 0.0, -- Units: MW
    unit_size_energy REAL NOT NULL DEFAULT 0.0, -- Units: MWh
    capacity_limits_charge TEXT NULL CHECK (json_valid(capacity_limits_charge)), -- Units: MW
    capacity_limits_discharge TEXT NULL CHECK (json_valid(capacity_limits_discharge)), -- Units: MW
    capacity_limits_energy TEXT NULL CHECK (json_valid(capacity_limits_energy)), -- Units: MWh
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    duration_limits TEXT NULL CHECK (json_valid(duration_limits)), -- Units: min
    efficiency TEXT NULL CHECK (json_valid(efficiency)), -- Units: 1
    min_discharge_fraction REAL NOT NULL DEFAULT 0.0, -- Units: 1
    losses REAL NOT NULL DEFAULT 1.0, -- Units: 1
    capital_costs_charge TEXT NULL,
    capital_costs_discharge TEXT NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    capital_costs_energy TEXT NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    interconnection_cost REAL NOT NULL DEFAULT 0.0,
    operation_costs TEXT NOT NULL DEFAULT '{"cost_type":"THERMAL","fixed":0,"shut_down":0,"start_up":0,"variable":{"power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}}}' CHECK (json_valid(operation_costs)), -- Units: USD/MWh
    financial_data TEXT NOT NULL CHECK (json_valid(financial_data))
) STRICT;

-- Components: NodalACTransportTechnology, NodalHVDCTransportTechnology, AggregateTransportTechnology
-- Attributes: resistance, voltage, reactance
DROP TABLE IF EXISTS transport_technologies;
CREATE TABLE transport_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    power_systems_type TEXT NOT NULL,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    capital_costs TEXT NOT NULL DEFAULT '{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0}}' CHECK (json_valid(capital_costs)),
    financial_data TEXT NOT NULL CHECK (json_valid(financial_data)),
    unit_size REAL NULL DEFAULT 0.0, -- Units: MW
    start_node INTEGER NULL REFERENCES entities (id) ON DELETE CASCADE,
    end_node INTEGER NULL REFERENCES entities (id) ON DELETE CASCADE,
    capacity_limits TEXT NULL CHECK (json_valid(capacity_limits)), -- Units: MW
    line_loss TEXT NULL CHECK (json_valid(line_loss)), -- Units: 1
    start_region INTEGER NULL REFERENCES entities (id) ON DELETE CASCADE,
    end_region INTEGER NULL REFERENCES entities (id) ON DELETE CASCADE
) STRICT;

-- Components: DemandRequirement
-- Attributes: conformity, growth_rate, new_demand_mw, new_construction_year, value_of_lost_load, unserved_demand_curve
DROP TABLE IF EXISTS demand_technologies;
CREATE TABLE demand_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    region TEXT NOT NULL CHECK (json_valid(region)),
    power_systems_type TEXT NOT NULL
) STRICT;

-- Named market trading hub (PSY TradingHub): a set of member buses at which
-- hub-settled bids are priced. Membership is trading_hub_associations rows,
-- not a list column, matching plant_associations/combined_cycle_associations.
-- Components: TradingHub
DROP TABLE IF EXISTS trading_hubs;
CREATE TABLE trading_hubs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE
) STRICT;

-- A virtual (convergence) market participant (PSY VirtualParticipant). Settles
-- at settlement_point_id or via trading_hub_associations rows -- mutually
-- exclusive upstream, not enforced here. operation_cost is the schemas'
-- discriminated MarketBidCost / MarketBidTimeSeriesCost payload verbatim,
-- guarded by validate_virtual_participants_cost_units_* like sources'
-- ImportExportCost.
-- Components: VirtualParticipant
DROP TABLE IF EXISTS virtual_participants;
CREATE TABLE virtual_participants (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    settlement_point_id INTEGER NULL REFERENCES entities (id) ON DELETE SET NULL,
    max_supply REAL NOT NULL CHECK (max_supply >= 0), -- Units: MW
    max_demand REAL NOT NULL CHECK (max_demand >= 0), -- Units: MW
    operation_cost TEXT NOT NULL CHECK (json_valid(operation_cost)) CHECK (json_extract(operation_cost, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES')) CHECK (ifnull(json_extract(operation_cost, '$.cost_type'), '') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES'))
) STRICT;

-- A priced point-to-point spread bid (PSY PointToPointBid): a
-- willingness-to-pay curve on the price spread between a source (from_id)
-- and sink (to_id), each resolved through the entities supertype. spread_bid
-- mirrors virtual_participants.operation_cost and is guarded the same way.
-- Components: PointToPointBid
DROP TABLE IF EXISTS point_to_point_bids;
CREATE TABLE point_to_point_bids (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    from_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    to_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    max_active_power REAL NOT NULL CHECK (max_active_power >= 0), -- Units: MW
    spread_bid TEXT NOT NULL CHECK (json_valid(spread_bid)) CHECK (json_extract(spread_bid, '$.cost_type') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES')) CHECK (ifnull(json_extract(spread_bid, '$.cost_type'), '') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES')),
    price_limits TEXT NOT NULL CHECK (json_valid(price_limits)), -- Units: USD/MWh
    linked_crr TEXT NULL,
    CHECK (from_id <> to_id)
) STRICT;

-- Attribute-channel properties with no unit and a structured value
-- (references, curves): exempt from the attributes unit rule.
INSERT INTO attribute_identifiers (TYPE, name)
VALUES
    ('HydroReservoir', 'downstream_turbines'),
    ('HydroReservoir', 'upstream_reservoirs'),
    ('HydroReservoir', 'upstream_turbines'),
    ('InterconnectingConverter', 'loss_function'),
    ('InterruptiblePowerLoad', 'operation_cost'),
    ('InterruptibleStandardLoad', 'operation_cost'),
    ('ShiftablePowerLoad', 'operation_cost'),
    ('TwoTerminalGenericHVDCLine', 'loss'),
    ('TwoTerminalLCCLine', 'loss'),
    ('TwoTerminalVSCLine', 'converter_loss_from'),
    ('TwoTerminalVSCLine', 'converter_loss_to');

-- END GENERATED COMPONENT TABLES
