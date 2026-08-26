-- DISCLAIMER
-- The current version of this schema only works for SQLITE >=3.45
-- When adding new functionality, think about the following:
--      1. Simplicity and ease of use over complexity,
--      2. Clear, consice and strict fields but allow for extensability,
--      3. User friendly over peformance, but consider performance always,
-- WARNING: This script should only be used while testing the schema and should not
-- be applied to existing dataset since it drops all the information it has.
-- Schema/registry revision; bump on every future registry or schema change.
PRAGMA user_version = 12;

DROP TABLE IF EXISTS thermal_generators;

DROP TABLE IF EXISTS renewable_generators;

DROP TABLE IF EXISTS hydro_generators;

DROP TABLE IF EXISTS storage_units;

DROP TABLE IF EXISTS prime_mover_types;

DROP TABLE IF EXISTS balancing_topologies;

DROP TABLE IF EXISTS supply_technologies;

DROP TABLE IF EXISTS storage_technology_types;

DROP TABLE IF EXISTS storage_technologies;

DROP TABLE IF EXISTS demand_technologies;

DROP TABLE IF EXISTS transmission_lines;

DROP TABLE IF EXISTS two_winding_transformers;

DROP TABLE IF EXISTS three_winding_transformers;

DROP TABLE IF EXISTS transformer_circuits;

DROP TABLE IF EXISTS planning_regions;

DROP TABLE IF EXISTS transmission_interchanges;

DROP TABLE IF EXISTS entities;

DROP VIEW IF EXISTS time_series_readable;

DROP TABLE IF EXISTS time_series_associations;

DROP TABLE IF EXISTS feature_sets;

DROP TABLE IF EXISTS timestamp_sets;

DROP TABLE IF EXISTS attribute_identifiers;

DROP TABLE IF EXISTS attributes;

DROP TABLE IF EXISTS loads;

DROP TABLE IF EXISTS fixed_admittance;

DROP TABLE IF EXISTS switched_admittance;

DROP TABLE IF EXISTS synchronous_condensers;

DROP TABLE IF EXISTS sources;

DROP TABLE IF EXISTS two_terminal_hvdc_lines;

DROP TABLE IF EXISTS two_terminal_lcc_lines;

DROP TABLE IF EXISTS tmodel_hvdc_lines;

DROP TABLE IF EXISTS two_terminal_vsc_lines;

DROP TABLE IF EXISTS facts_control_devices;

DROP TABLE IF EXISTS interconnecting_converters;

DROP TABLE IF EXISTS static_time_series;

DROP TABLE IF EXISTS allowed_units;

DROP TABLE IF EXISTS entity_types;

DROP TABLE IF EXISTS supplemental_attributes;

DROP TABLE IF EXISTS arcs;

DROP TABLE IF EXISTS hydro_reservoirs;

DROP TABLE IF EXISTS hydro_reservoir_connections;

DROP TABLE IF EXISTS fuels;

DROP TABLE IF EXISTS supplemental_attribute_associations;

DROP TABLE IF EXISTS transport_technologies;

DROP TABLE IF EXISTS combined_cycle_associations;

DROP TABLE IF EXISTS plant_associations;

DROP TABLE IF EXISTS plants;

DROP TABLE IF EXISTS unit_conventions;

DROP TABLE IF EXISTS unit_basis_rules;

DROP TABLE IF EXISTS quantity_types;

DROP TABLE IF EXISTS unit_management_metadata;

PRAGMA foreign_keys = ON;

-- NOTE: This table should not be interacted directly since it gets populated
-- automatically.
-- Table of certain entities of griddb schema.
CREATE TABLE entities (
    id INTEGER PRIMARY KEY,
    entity_table TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    FOREIGN KEY (entity_type) REFERENCES entity_types (name)
) strict;

-- Table of possible entity types
-- is_dc marks the DC side of the network (PSY DCBus). It is a property of the
-- type, not of the row, and it is what separates the two HVDC families: a
-- tmodel_hvdc_lines arc runs between is_dc = 1 topologies, every AC branch and
-- point-to-point HVDC arc between is_dc = 0 ones.
CREATE TABLE entity_types (
    name TEXT PRIMARY KEY,
    is_topology BOOLEAN NOT NULL DEFAULT FALSE,
    is_dc BOOLEAN NOT NULL DEFAULT FALSE,
    -- Only a topology type can be a DC bus:
    CHECK (is_dc = FALSE OR is_topology = TRUE)
);

-- NOTE: Sienna-griddb follows the convention of the EIA prime mover where we
-- have a `prime_mover` and `fuel` to classify generators/storage units.
-- However, users could use any combination of `prime_mover` and `fuel` for
-- their own application. The only constraint is that the uniqueness is enforced
-- by the combination of (prime_mover, fuel)
-- Categories to classify generating units and supply technologies
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

-- Investment regions
CREATE TABLE planning_regions (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    description TEXT NULL
) strict;

-- Balancing topologies for the system. Could be either buses, or larger
-- aggregated regions.
CREATE TABLE balancing_topologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    area INTEGER NULL REFERENCES planning_regions (id) ON DELETE
    SET
        NULL,
        description TEXT NULL,
        base_voltage REAL NULL CHECK (base_voltage IS NULL OR base_voltage > 0) -- Units: kV
) strict;

-- NOTE: The purpose of this table is to provide links different entities that
-- naturally have a relantionship not model dependent (e.g., transmission lines,
-- transmission interchanges, etc.).
-- Physical connection between entities.
CREATE TABLE arcs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    from_id INTEGER NOT NULL,
    to_id INTEGER NOT NULL,
    CHECK (from_id <> to_id),
    FOREIGN KEY (from_id) REFERENCES entities (id) ON DELETE CASCADE,
    FOREIGN KEY (to_id) REFERENCES entities (id) ON DELETE CASCADE
) strict;

-- Existing transmission lines
-- Branch electrical parameters r/x/b/g are stored flexibly per unit_basis
-- (COMPONENT_BASE -> pu on base_power; NATURAL_UNITS -> ohm for r/x, S for
-- b/g). All of r/x/b/g on a line share one basis (PSY stores them all
-- COMPONENT_BASE; a matpower import is all NATURAL_UNITS). r and x are scalar
-- REAL; b and g are shunt halves stored as JSON {"from": ..., "to": ...} text
-- (json_valid-checked, STRICT-legal), mirroring the schema FromTo payload.
-- base_power is a per-row snapshot of the base the COMPONENT_BASE arm of
-- r/x/b/g is normalized against; every COMPONENT_BASE row in the database is
-- expected to carry the same value, but that agreement is not
-- trigger-enforced across rows.
CREATE TABLE transmission_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL,
    continuous_rating REAL NOT NULL CHECK (continuous_rating >= 0),
    ste_rating REAL NULL CHECK (ste_rating >= 0),
    lte_rating REAL NULL CHECK (lte_rating >= 0),
    line_length REAL NULL CHECK (line_length >= 0),
    r REAL NOT NULL CHECK (r >= 0),
    x REAL NOT NULL,
    b TEXT NULL CHECK (b IS NULL OR json_valid(b)),
    g TEXT NULL DEFAULT '{"from": 0.0, "to": 0.0}' CHECK (g IS NULL OR json_valid(g)),
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    FOREIGN KEY (arc_id) REFERENCES arcs (id) ON DELETE CASCADE
) strict;

-- Switches and breakers connecting AC buses (PSY DiscreteControlledACBranch).
-- r/x are per-unit on system base (this component has no natural-units option
-- in PSY, unlike transmission_lines); rating is stored in MVA (natural units),
-- mirroring transmission_lines.continuous_rating. base_power is the same
-- per-row system-base snapshot as transmission_lines.base_power.
CREATE TABLE discrete_controlled_ac_branches (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL CHECK (r >= 0),
    x REAL NOT NULL CHECK (x >= 0),
    rating REAL NOT NULL CHECK (rating >= 0),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    discrete_branch_type TEXT NOT NULL DEFAULT 'OTHER'
        CHECK (discrete_branch_type IN ('SWITCH', 'BREAKER', 'OTHER')),
    branch_status TEXT NOT NULL DEFAULT 'CLOSED'
        CHECK (branch_status IN ('OPEN', 'CLOSED')),
    normal_branch_status TEXT NOT NULL DEFAULT 'CLOSED'
        CHECK (normal_branch_status IN ('OPEN', 'CLOSED'))
) strict;

-- One modeled arc of a transformer (PSY TransformerCircuit). Circuits are
-- unnamed subcomponents, so no name column. r/x are stored flexibly per the
-- unit_basis discriminator (COMPONENT_BASE -> pu on base_power/
-- base_voltage_primary; NATURAL_UNITS -> ohm); the MinMax band columns' units
-- follow control_objective, see unit_conventions. `available` is INTEGER for
-- STRICT (BOOLEAN only exists in the legacy non-strict generator tables).
CREATE TABLE transformer_circuits (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    -- Normalized tap position, 1 centered at nominal voltage:
    tap REAL NOT NULL DEFAULT 1.0 CHECK (tap >= 0 AND tap <= 2), -- Units: 1
    alpha REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r REAL NOT NULL DEFAULT 0.0, -- Units: per unit_basis
    -- Star-leg equivalent reactance of a three-winding transformer may be
    -- negative, so no sign CHECK on r/x:
    x REAL NOT NULL DEFAULT 0.0, -- Units: per unit_basis
    -- r/x are stored flexibly in per-unit on the device base (base_power
    -- referenced to base_voltage_primary) OR natural-units ohm, exactly as
    -- transmission_lines does it; both share the one basis this column records.
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    control_objective TEXT NOT NULL DEFAULT 'UNDEFINED'
        CHECK (control_objective IN ('UNDEFINED', 'VOLTAGE_DISABLED',
            'REACTIVE_POWER_FLOW_DISABLED', 'ACTIVE_POWER_FLOW_DISABLED',
            'CONTROL_OF_DC_LINE_DISABLED',
            'ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED', 'FIXED', 'VOLTAGE',
            'REACTIVE_POWER_FLOW', 'ACTIVE_POWER_FLOW', 'CONTROL_OF_DC_LINE',
            'ASYMMETRIC_ACTIVE_POWER_FLOW')),
    -- Controlled bus number (sign = regulation side):
    regulated_bus_number INTEGER NOT NULL DEFAULT 0,
    -- Control band, JSON {"min": ..., "max": ...}:
    control_limits TEXT NULL DEFAULT '{"min": 0.9, "max": 1.1}'
        CHECK (control_limits IS NULL OR json_valid(control_limits)), -- Units: per control_objective (tap ratio 1 / angle rad)
    -- Controlled-quantity band, JSON {"min": ..., "max": ...}:
    controlled_quantity_limits TEXT NULL DEFAULT '{"min": 0.9, "max": 1.1}'
        CHECK (controlled_quantity_limits IS NULL OR json_valid(controlled_quantity_limits)), -- Units: per control_objective (pu / MVAr / MW)
    number_of_tap_positions INTEGER NOT NULL DEFAULT 33,
    rating REAL NULL CHECK (rating >= 0), -- Units: MVA
    rating_b REAL NULL CHECK (rating_b >= 0), -- Units: MVA
    rating_c REAL NULL CHECK (rating_c >= 0), -- Units: MVA
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: MW
    reactive_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: MVAr
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    base_voltage_primary REAL NULL CHECK (base_voltage_primary > 0), -- Units: kV
    base_voltage_secondary REAL NULL CHECK (base_voltage_secondary > 0) -- Units: kV
) strict;

-- Two-winding transformer (PSY TwoWindingTransformer); series data lives on
-- the referenced circuit. magnetizing_shunt is a complex admittance as JSON
-- {"real": ..., "imag": ...} (real = conductance, imag = susceptance).
CREATE TABLE two_winding_transformers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    magnetizing_shunt TEXT NULL DEFAULT '{"real": 0.0, "imag": 0.0}'
        CHECK (magnetizing_shunt IS NULL OR json_valid(magnetizing_shunt)), -- Units: pu
    shunt_location TEXT NOT NULL DEFAULT 'PRIMARY'
        CHECK (shunt_location IN ('PRIMARY', 'SECONDARY', 'SPLIT'))
) strict;

-- Three-winding transformer (PSY ThreeWindingTransformer), star model: each
-- circuit connects a terminal bus to the star bus. The pairwise measured-impedance
-- fields are all-or-none (table CHECK); star-leg impedances derived from them
-- live on the circuits and are not synced back.
CREATE TABLE three_winding_transformers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    primary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    secondary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    tertiary_circuit INTEGER NOT NULL REFERENCES transformer_circuits (id) ON DELETE CASCADE,
    star_bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    r_12 REAL NULL, -- Units: per unit_basis
    x_12 REAL NULL, -- Units: per unit_basis
    r_23 REAL NULL, -- Units: per unit_basis
    x_23 REAL NULL, -- Units: per unit_basis
    r_31 REAL NULL, -- Units: per unit_basis
    x_31 REAL NULL, -- Units: per unit_basis
    -- Pairwise measured r/x are stored flexibly per the unit_basis
    -- discriminator (COMPONENT_BASE -> pu on base_power_12/_23/_31, all three
    -- referred to the primary winding's voltage base per PSSE convention;
    -- NATURAL_UNITS -> ohm); all six share the one basis this column records.
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power_12 REAL NULL CHECK (base_power_12 > 0), -- Units: MVA
    base_power_23 REAL NULL CHECK (base_power_23 > 0), -- Units: MVA
    base_power_31 REAL NULL CHECK (base_power_31 > 0), -- Units: MVA
    magnetizing_shunt TEXT NULL DEFAULT '{"real": 0.0, "imag": 0.0}'
        CHECK (magnetizing_shunt IS NULL OR json_valid(magnetizing_shunt)), -- Units: pu
    shunt_location TEXT NOT NULL DEFAULT 'PRIMARY'
        CHECK (shunt_location IN ('PRIMARY', 'STAR')),
    CHECK (primary_circuit <> secondary_circuit
        AND primary_circuit <> tertiary_circuit
        AND secondary_circuit <> tertiary_circuit),
    -- All nine pairwise measured-impedance fields set together or all absent:
    CHECK (
        (r_12 IS NULL) + (x_12 IS NULL) + (r_23 IS NULL) + (x_23 IS NULL)
        + (r_31 IS NULL) + (x_31 IS NULL) + (base_power_12 IS NULL)
        + (base_power_23 IS NULL) + (base_power_31 IS NULL) IN (0, 9)
    )
) strict;

-- NOTE: The purpose of this table is to provide physical limits to flows
-- between areas or balancing topologies. In contrast with the transmission
-- lines, this entities are used to enforce given physical limits of certain
-- markets.
-- Transmission interchanges between two balancing topologies or areas
CREATE TABLE transmission_interchanges (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER REFERENCES arcs(id) ON DELETE CASCADE,
    max_flow_from REAL NOT NULL,
    max_flow_to REAL NOT NULL
) strict;

-- NOTE: The purpose of these tables is to capture data of **existing units only**.
-- Table of thermal generation units (ThermalStandard, ThermalMultiStart)
CREATE TABLE thermal_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    fuel TEXT NOT NULL DEFAULT 'OTHER' REFERENCES fuels(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0),
    base_power REAL NOT NULL CHECK (base_power > 0),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits JSON NOT NULL,
    reactive_power_limits JSON NULL,
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL,
    -- Time limits (JSON: {"up": ..., "down": ...}, hours):
    time_limits JSON NULL,
    -- Operational flags:
    must_run BOOLEAN NOT NULL DEFAULT FALSE,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    "status" BOOLEAN NOT NULL DEFAULT FALSE,
    -- Initial setpoints:
    active_power REAL NOT NULL DEFAULT 0.0,
    reactive_power REAL NOT NULL DEFAULT 0.0,
    -- Production (variable) cost curve: the schemas' ProductionVariableCostCurve
    -- (Core/common.json). It is its own column rather than a member of the
    -- operation_cost blob because it
    -- is the part that gets read, compared and repriced. The payload states which
    -- kind of curve it is: COST is money, FUEL is a heat rate whose money comes
    -- from fuel_cost -- so a reader never has to guess the unit of value_curve.
    -- The curve form matters too: INPUT_OUTPUT y is a cost rate at a power level,
    -- INCREMENTAL and AVERAGE_RATE are per-energy (see column_conventions.json).
    production_cost JSON NOT NULL DEFAULT '{"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}'
        CHECK (json_valid(production_cost))
        -- ifnull, not a bare IN: json_extract returns NULL for an absent key and
        -- a CHECK passes on NULL, so an unlabelled curve would slip through.
        CHECK (ifnull(json_extract(production_cost, '$.variable_cost_type'), '')
            IN ('COST', 'FUEL'))
        -- Six ValueCurve forms: the three static ones and their time-series-backed
        -- counterparts, whose function_data carries an association_id instead of
        -- coefficients (SiennaSchemas Core/common.json ValueCurve).
        CHECK (ifnull(json_extract(production_cost, '$.value_curve.curve_type'), '')
            IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                'TIME_SERIES_AVERAGE_RATE'))
        -- A FuelCurve without a fuel price cannot be turned into money. The price
        -- is either a fixed number (fuel_cost) or a time series (fuel_cost_time_series),
        -- never both and never neither. Upstream states "exactly one is set" only in
        -- prose -- no oneOf, no dependentSchemas -- so this CHECK is the only place
        -- the rule is actually enforced.
        CHECK (json_extract(production_cost, '$.variable_cost_type') <> 'FUEL'
            OR (json_extract(production_cost, '$.fuel_cost') IS NOT NULL)
             <> (json_extract(production_cost, '$.fuel_cost_time_series') IS NOT NULL)),
    -- The remaining cost members (fixed, start-up, shut-down). The production
    -- curve lives in production_cost; a copy here would be a second source of
    -- truth, so the CHECK forbids one.
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0}'
        CHECK (json_extract(operation_cost, '$.variable') IS NULL)
);

-- Table of renewable generation units (RenewableDispatch, RenewableNonDispatch)
CREATE TABLE renewable_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0),
    base_power REAL NOT NULL CHECK (base_power > 0),
    -- Renewable-specific:
    power_factor REAL NOT NULL DEFAULT 1.0 CHECK (
        power_factor > 0
        AND power_factor <= 1.0
    ),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    reactive_power_limits JSON NULL,
    -- Operational flags:
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Initial setpoints:
    active_power REAL NOT NULL DEFAULT 0.0,
    reactive_power REAL NOT NULL DEFAULT 0.0,
    -- Production (variable) cost curve; see thermal_generators.production_cost.
    -- NULL for RenewableNonDispatch, which has no cost at all. Restricted to
    -- COST: RenewableGenerationCost.variable is a CostCurve, never a FuelCurve,
    -- and allowing FUEL here would admit rows with no registered unit.
    production_cost JSON NULL
        CHECK (production_cost IS NULL OR json_valid(production_cost))
        CHECK (production_cost IS NULL
            OR ifnull(json_extract(production_cost, '$.variable_cost_type'), '') = 'COST')
        CHECK (production_cost IS NULL
            OR ifnull(json_extract(production_cost, '$.value_curve.curve_type'), '')
                IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                    'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                    'TIME_SERIES_AVERAGE_RATE')),
    -- Remaining cost members (fixed, curtailment_cost). NULL for
    -- RenewableNonDispatch:
    operation_cost JSON NULL DEFAULT '{"cost_type":"RENEWABLE","fixed":0,"curtailment_cost":{"variable_cost_type":"COST","power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}},"vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}}'
        CHECK (operation_cost IS NULL
            OR json_extract(operation_cost, '$.variable') IS NULL)
);

-- Table of hydro generation units (HydroDispatch, HydroTurbine, HydroPumpTurbine)
CREATE TABLE hydro_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'HY' REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0),
    base_power REAL NOT NULL CHECK (base_power > 0),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits JSON NOT NULL,
    reactive_power_limits JSON NULL,
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL,
    -- Time limits (JSON: {"up": ..., "down": ...}, hours):
    time_limits JSON NULL,
    -- Operational flags:
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Initial setpoints:
    active_power REAL NOT NULL DEFAULT 0.0,
    reactive_power REAL NOT NULL DEFAULT 0.0,
    -- HydroTurbine/HydroPumpTurbine fields (nullable for HydroDispatch):
    powerhouse_elevation REAL NULL DEFAULT 0.0 CHECK (powerhouse_elevation >= 0),
    -- Outflow limits (JSON: {"min": ..., "max": ...}):
    outflow_limits JSON NULL,
    conversion_factor REAL NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    travel_time REAL NULL CHECK (travel_time >= 0),
    -- Production (variable) cost curve; see thermal_generators.production_cost.
    -- HydroGenerationCost.variable is a ProductionVariableCostCurve, so FUEL is
    -- admissible here as well.
    production_cost JSON NOT NULL DEFAULT '{"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}'
        CHECK (json_valid(production_cost))
        -- ifnull, not a bare IN: json_extract returns NULL for an absent key and
        -- a CHECK passes on NULL, so an unlabelled curve would slip through.
        CHECK (ifnull(json_extract(production_cost, '$.variable_cost_type'), '')
            IN ('COST', 'FUEL'))
        -- Six ValueCurve forms: the three static ones and their time-series-backed
        -- counterparts, whose function_data carries an association_id instead of
        -- coefficients (SiennaSchemas Core/common.json ValueCurve).
        CHECK (ifnull(json_extract(production_cost, '$.value_curve.curve_type'), '')
            IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                'TIME_SERIES_AVERAGE_RATE'))
        -- A FuelCurve without a fuel price cannot be turned into money. The price
        -- is either a fixed number (fuel_cost) or a time series (fuel_cost_time_series),
        -- never both and never neither. Upstream states "exactly one is set" only in
        -- prose -- no oneOf, no dependentSchemas -- so this CHECK is the only place
        -- the rule is actually enforced.
        CHECK (json_extract(production_cost, '$.variable_cost_type') <> 'FUEL'
            OR (json_extract(production_cost, '$.fuel_cost') IS NOT NULL)
             <> (json_extract(production_cost, '$.fuel_cost_time_series') IS NOT NULL)),
    -- Remaining cost members (fixed):
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "HYDRO_GEN", "fixed": 0.0}'
        CHECK (json_extract(operation_cost, '$.variable') IS NULL)
    -- Note: efficiency (varies by type), turbine_type, and HydroPumpTurbine-specific
    -- fields (active_power_limits_pump, etc.) are stored in the attributes table
);

-- NOTE: The purpose of this table is to capture data of **existing storage units only**.
-- Table of energy storage units (including PHES or other kinds),
CREATE TABLE storage_units (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    storage_technology_type TEXT NOT NULL REFERENCES storage_technology_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0),
    base_power REAL NOT NULL CHECK (base_power > 0),
    -- Storage capacity and limits (JSON: {"min": ..., "max": ...}):
    storage_capacity REAL NOT NULL CHECK (storage_capacity >= 0),
    -- Unit basis for storage_capacity: MWH is the conventional interchange form;
    -- MWMIN is the minutes basis, so duration = energy / power comes out in minutes
    -- with no hidden factor of 60.
    energy_units TEXT NOT NULL DEFAULT 'MWH' CHECK (energy_units IN ('MWH', 'MWMIN')),
    storage_level_limits JSON NOT NULL,
    initial_storage_capacity_level REAL NOT NULL CHECK (initial_storage_capacity_level >= 0),
    -- Power limits (JSON: {"min": ..., "max": ...}, input = charging, output = discharging):
    input_active_power_limits JSON NOT NULL,
    output_active_power_limits JSON NOT NULL,
    -- Efficiency (JSON: {"in": ..., "out": ...}):
    efficiency JSON NOT NULL,
    -- Reactive power (JSON: {"min": ..., "max": ...}):
    reactive_power_limits JSON NULL,
    -- Initial setpoints:
    active_power REAL NOT NULL DEFAULT 0.0,
    reactive_power REAL NOT NULL DEFAULT 0.0,
    -- Status:
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Storage-specific with defaults:
    conversion_factor REAL NOT NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    storage_target REAL NOT NULL DEFAULT 0.0,
    cycle_limits INTEGER NOT NULL DEFAULT 10000 CHECK (cycle_limits > 0),
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL,
    -- Leakage loss (fraction of stored energy lost per hour) and constant
    -- standing-loss power (MW), both PSY-defaulted to 0.0:
    self_discharge REAL NOT NULL DEFAULT 0.0 CHECK (self_discharge >= 0),
    standing_loss REAL NOT NULL DEFAULT 0.0 CHECK (standing_loss >= 0),
    -- Cost: the whole StorageCost object as the schemas define it, charge and
    -- discharge curves
    -- included. Unlike the generator tables, storage keeps its curves inside this
    -- blob -- this column IS the StorageCost schema, so do not promote them to
    -- production_cost columns. The curve paths are registered and guarded where
    -- they live (column_conventions.json operation_cost.charge_variable_cost /
    -- .discharge_variable_cost, and validate_storage_units_cost_units_*).
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "STORAGE", "charge_variable_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}, "discharge_variable_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}'
);

-- Topological hydro reservoirs
CREATE TABLE hydro_reservoirs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Storage level limits (JSON: {"min": ..., "max": ...}):
    storage_level_limits JSON NOT NULL,
    initial_level REAL NOT NULL,
    -- Spillage limits (JSON: {"min": ..., "max": ...}, nullable):
    spillage_limits JSON NULL,
    inflow REAL NOT NULL DEFAULT 0.0,
    outflow REAL NOT NULL DEFAULT 0.0,
    level_targets REAL NULL,
    intake_elevation REAL NOT NULL DEFAULT 0.0,
    -- Head to volume relationship (JSON ValueCurve):
    head_to_volume_factor JSON NOT NULL,
    -- Cost (HydroReservoirCost), always USD/MWh regardless of level_data_type --
    -- level-native values convert to energy via head_to_volume_factor before costing:
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "HYDRO_RES", "level_shortage_cost": 0.0, "level_surplus_cost": 0.0, "spillage_cost": 0.0}',
    level_data_type TEXT NOT NULL DEFAULT 'USABLE_VOLUME' CHECK (
        level_data_type IN ('USABLE_VOLUME', 'TOTAL_VOLUME', 'HEAD', 'ENERGY')
    ),
    -- Standing loss from evaporation (fraction of stored volume/energy lost per hour):
    evaporative_loss REAL NOT NULL DEFAULT 0.0 CHECK (evaporative_loss >= 0)
);

CREATE TABLE hydro_reservoir_connections (
    source_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    sink_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    CHECK (source_id <> sink_id),
    PRIMARY KEY (source_id, sink_id)
) strict;

-- investment for expansion problems.
-- Investment technology options for expansion problems
CREATE TABLE supply_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    region JSON NOT NULL,
    power_systems_type TEXT NOT NULL,
    lifetime INTEGER NULL,
    unit_size REAL NULL,
    -- Capacity limits (JSON: {"min": ..., "max": ...}, MW):
    capacity_limits JSON NULL,
    -- Fuel information:
    fuel TEXT NOT NULL DEFAULT '["OTHER"]',
    start_fuel_mmbtu_per_mw REAL NULL,
    -- Fuel cofire limits (JSON: {"fuel1": {"min": ..., "max": ...}, "fuel2": {"min": ..., "max": ...}}):
    cofire_level_limits JSON NULL,
    -- Fuel cofire start limits (JSON: {"fuel1": ..., "fuel2": ...}):
    cofire_start_limits JSON NULL,
    -- CO2 emissions (JSON: {"fuel1": ..., "fuel2": ...}, tons per MMBTU):
    co2 JSON NULL,
    -- Operational information:
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL,
    -- Time limits (JSON: {"up": ..., "down": ...}, hours):
    time_limits JSON NULL,
    outage_factor REAL NULL,
    min_generation_fraction REAL NULL,
    -- Financial data:
    -- Capital cost (complex structure, stored as JSON):
    capital_costs JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    -- Cost (complex structure, stored as JSON):
    operation_costs JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}',
    -- Other financial parameters (complex structure, stored as JSON):
    financial_data JSON NOT NULL
);

CREATE TABLE storage_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    storage_tech TEXT NOT NULL DEFAULT '["OTHER"]',
    region JSON NOT NULL,
    power_systems_type TEXT NOT NULL,
    lifetime INTEGER NULL,
    unit_size_charge REAL NULL,
    unit_size_discharge REAL NULL,
    unit_size_energy REAL NULL,
    -- Capacity limits (JSON: {"min": ..., "max": ...}, MW):
    capacity_limits_charge JSON NULL,
    capacity_limits_discharge JSON NULL,
    capacity_limits_energy JSON NULL,
    -- Operational information:
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Duration limits (JSON: {"min": ..., "max": ...}, hours):
    duration_limits JSON NULL,
    -- Efficiency (JSON: {"in": ..., "out": ...}, fraction):
    efficiency JSON NULL,
    min_discharge_fraction REAL NULL,
    losses REAL NULL,
    -- Financial data:
    -- Capital cost (complex structure, stored as JSON):
    capital_costs_charge JSON NULL,
    capital_costs_discharge JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    capital_costs_energy JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    -- Cost (complex structure, stored as JSON):
    operation_costs JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}',
    -- Other financial parameters (complex structure, stored as JSON):
    financial_data JSON NOT NULL
);

CREATE TABLE transport_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    power_systems_type TEXT NOT NULL,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    capital_costs JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    financial_data JSON NOT NULL,
    unit_size REAL NULL
);

CREATE TABLE demand_technologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    region TEXT NOT NULL,
    power_systems_type TEXT NOT NULL
);

-- NOTE: Attributes are additional parameters that can be linked to entities.
-- The main purpose of this is when there is an important field that is not
-- capture on the entity table that should exist on the model. Example of this
-- fields are variable or fixed operation and maintenance cost or any other
-- field that its representation is hard to fit into a `integer`, `real` or
-- `text`. It must not be used for operational details since most of the should
-- be included in the `operational_data` table.
CREATE TABLE attributes (
    id INTEGER PRIMARY KEY,
    entity_id INTEGER NOT NULL,
    TYPE TEXT NOT NULL,
    name TEXT NOT NULL,
    value JSON NOT NULL,
    unit TEXT NULL,
    quantity_type TEXT NULL REFERENCES quantity_types (name),
    json_type TEXT generated always AS (json_type(value)) virtual,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE(entity_id, name)
);

-- Attribute names that hold an identifier rather than a physical quantity (bus
-- numbers, node references, zone ids). The unit-validation triggers classify any
-- numeric JSON value as physical and demand a unit for it, which would force an
-- identifier to be labelled with one; listing the name here exempts it instead.
-- Add a row rather than inventing a Dimensionless unit for a key.
CREATE TABLE attribute_identifiers (
    name TEXT PRIMARY KEY,
    description TEXT NULL
) strict;

INSERT INTO
    attribute_identifiers (name, description)
VALUES
    ('number', 'Bus number'),
    ('start_node', 'Transport technology from-node reference'),
    ('end_node', 'Transport technology to-node reference'),
    ('load_zone', 'Load zone reference');

-- NOTE: Supplemental are optional parameters that can be linked to entities.
-- The main purpose of this is to provide a way to save relevant information
-- but that could or could not be used for modeling. not `text`. Examples of
-- this field are geolocation (e.g., lat, long), outages, etc.)
CREATE TABLE supplemental_attributes (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    TYPE TEXT NOT NULL,
    value JSON NOT NULL,
    json_type TEXT generated always AS (json_type (value)) virtual
);

-- Mirrors infrastore's supplemental_attribute_associations column-for-column so
-- rows deserialize straight into a store at the modeling stage. Identity is the
-- (component_id, attribute_id) pair; the type columns are denormalized labels
-- carried for filtering, not part of identity. The FKs are GridDB-side
-- integrity infrastore deliberately omits (its endpoints live in the consumer's
-- object graph; here they live in this database).
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

CREATE TABLE plant_associations (
    plant_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    group_index INTEGER NOT NULL,
    FOREIGN KEY (plant_id) REFERENCES plants (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    PRIMARY KEY (plant_id, entity_id)
) strict;

-- CombinedCycleBlock CT/CA <-> HRSG associations are n-to-m: a CT or CA can
-- feed multiple HRSGs and an HRSG can have multiple CTs/CAs. Kept in its own
-- table so (plant, entity) is not unique.
CREATE TABLE combined_cycle_associations (
    plant_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('CT', 'CA')),
    hrsg_index INTEGER NOT NULL,
    FOREIGN KEY (plant_id) REFERENCES plants (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    PRIMARY KEY (plant_id, entity_id, hrsg_index)
) strict;

-- Mirrors infrastore's catalog table column-for-column
-- (crates/infrastore-core/src/metadata/schema.rs) so a GridDB row deserializes
-- straight into an infrastore store at the modeling stage, and so the same row
-- projects onto the SiennaSchemas wire form (TimeSeries/*.json) that
-- SystemDocument.time_series_associations carries.
--
-- Audited against infrastore 2026-08-26. The deliberate divergences, so they are
-- not re-litigated:
--   * GridDB-side integrity only, no row-shape change: the owner_id FK, `strict`,
--     and the drop-and-recreate preamble (infrastore's DDL is idempotent
--     CREATE ... IF NOT EXISTS because it re-applies on every writable open).
--   * uri: GridDB has it, infrastore does not -- it derives the wire `uri` at
--     export from data_hash. The schema allows either: "No required format ...
--     the backing store decides what it means ... Never parsed or interpreted
--     here." NOT unique here on purpose: several associations may name one
--     shared array, which is what lets a dense array be stored once.
--   * data_hash nullable here, NOT NULL there; element_shape NOT NULL with a
--     json_valid CHECK here, bare nullable TEXT there. Both follow the wire form,
--     which marks data_hash optional and element_shape required.
--   * scenario_count exists here and NOT in infrastore's catalog, because
--     TimeSeries/Scenarios.json requires it. Raise upstream.
--   * infrastore's parent_child_associations has no counterpart: GridDB models
--     those edges in richer domain tables (plant_associations w/ group_index,
--     combined_cycle_associations w/ role + hrsg_index, hydro_reservoir_connections).
-- Column semantics that are on-disk contracts there:
--   * owner_category / time_series_type are small INTEGER codes
--     (OwnerCategory::code / TimeSeriesType::code), not names -- see the
--     time_series_readable CASE arms for the decode.
--   * unit_system is 'natural_units' | 'component_base' (infrastore
--     UnitSystem::as_str, lowercase -- NOT the component tables'
--     unit_basis vocabulary) and deliberately carries no CHECK, so a third
--     basis can land without a format bump.
--   * quantity_kind is free-form (QUDT local names recommended); a CHECK would
--     turn composite economic quantities ($/MWh) into schema migrations. Rows
--     that use a registered quantity-type name are trigger-validated against
--     allowed_units (see validate_time_series_associations_units_insert).
--   * uri / data_hash / element_shape follow the SiennaSchemas wire form
--     (TimeSeries/*.json), where infrastore's catalog diverges from it: uri is
--     the required locator for the dense values (here: the key into
--     static_time_series), data_hash is an OPTIONAL content hash of that
--     array, and element_shape is required ('[]' = scalar element).
--   * features_hash / timestamps_hash are content-address SHA-256 BLOBs: the
--     feature map (feature_sets) and the explicit timestamp vector
--     (timestamp_sets; NonSequentialTimeSeries only).
--   * resolution / interval / horizon are ISO-8601 duration strings ('PT1H',
--     'P1Y') so calendar periods are distinguishable from fixed ones.
--   * time_reference is 'utc', 'zoneless', a fixed offset, or an IANA zone
--     name; NULL means unspecified, not UTC.
--   * component_field names the owner's field these values vary
--     (e.g. 'max_active_power'); free-form, never interpreted here.
CREATE TABLE time_series_associations (
    id INTEGER PRIMARY KEY,
    -- The store-minted surrogate id, carried verbatim. This is the value the wire
    -- schemas require (TimeSeries/*.json association_id, readOnly) and the value a
    -- cost payload references: a TIME_SERIES_* function data, FuelCurve's
    -- fuel_cost_time_series, MarketBidTimeSeriesCost's start_up_association_id and
    -- the two curve *_association_id fields all name a series by this number.
    -- Distinct from `id` on purpose: `id` is a bare rowid SQLite may reuse after a
    -- delete, and a reused reference resolving to a different series is exactly the
    -- failure the minted id exists to prevent. Store-local -- resolve it against the
    -- store the document came from, never an independently built one.
    association_id INTEGER NOT NULL,
    owner_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    owner_type TEXT NOT NULL,
    owner_category INTEGER NOT NULL CHECK (owner_category IN (0, 1)),
    time_series_type INTEGER NOT NULL CHECK (time_series_type BETWEEN 0 AND 5),
    name TEXT NOT NULL,
    initial_timestamp TEXT,
    resolution TEXT,
    length INTEGER,
    horizon TEXT,
    interval TEXT,
    count INTEGER,
    -- Scenarios only (time_series_type = 5), which requires it alongside count.
    -- infrastore's catalog has no counterpart column yet; see the plan's Part D.
    scenario_count INTEGER,
    timestamps_hash BLOB,
    units TEXT,
    quantity_kind TEXT,
    unit_system TEXT,
    time_reference TEXT,
    component_field TEXT,
    percentiles_json TEXT,
    element_type TEXT NOT NULL DEFAULT 'f64',
    element_shape TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(element_shape)),
    application_data TEXT,
    uri TEXT NOT NULL,
    data_hash BLOB,
    features_hash BLOB NOT NULL
) strict;

-- Feature sets are content-addressed by the SHA-256 of the feature map and
-- stored once, shared by every association whose features_hash matches.
-- Deliberately NO foreign key and NO cascade (mirroring infrastore): rows are
-- shared, so deleting one association must not delete a set another still uses.
CREATE TABLE feature_sets (
    key TEXT NOT NULL,
    value_kind TEXT NOT NULL CHECK (value_kind IN ('int', 'float', 'bool', 'str')),
    value_int INTEGER,
    value_float REAL,
    value_bool INTEGER,
    value_str TEXT,
    features_hash BLOB NOT NULL,
    PRIMARY KEY (features_hash, key)
) strict;

-- The explicit timestamp vector of a NonSequentialTimeSeries, content-addressed
-- and stored once per distinct time axis. data is infrastore's varint delta
-- encoding, carried verbatim so the vector round-trips bit-exact; it is not
-- human-readable by design. No FK/cascade, same sharing rationale as
-- feature_sets.
CREATE TABLE timestamp_sets (
    timestamps_hash BLOB NOT NULL PRIMARY KEY,
    data BLOB NOT NULL
) strict;

-- The store's uniqueness invariant is (owner_id, owner_category,
-- time_series_type, name, resolution, interval, features). Two indexes enforce
-- and serve it, and BOTH must be kept: uq_ts_assoc serves equality/IS NULL
-- lookups but cannot enforce uniqueness when resolution or interval IS NULL
-- (SQLite treats NULLs as distinct); uq_ts_assoc_coalesced closes that gap by
-- COALESCE-ing to the empty string, never a valid ISO-8601 period.
-- Mirrors infrastore's uq_ts_assoc_id. With ids minted from a monotonic sequence
-- upstream a violation is unreachable, so this asserts internal consistency
-- rather than detecting a collision -- and it is what makes association_id a
-- resolvable key for the cost payloads that reference it.
CREATE UNIQUE INDEX uq_ts_assoc_id ON time_series_associations (association_id);

CREATE UNIQUE INDEX uq_ts_assoc ON time_series_associations
    (owner_id, owner_category, time_series_type, name, resolution, interval, features_hash);

CREATE UNIQUE INDEX uq_ts_assoc_coalesced ON time_series_associations
    (owner_id, owner_category, time_series_type, name,
     COALESCE(resolution, ''), COALESCE(interval, ''), features_hash);

CREATE INDEX idx_uri ON time_series_associations (uri);

-- Partial: data_hash is the optional integrity hash (SiennaSchemas wire form);
-- rows without one cost zero index entries.
CREATE INDEX idx_hash ON time_series_associations (data_hash)
    WHERE data_hash IS NOT NULL;

CREATE INDEX idx_owner ON time_series_associations (owner_id, owner_category);

CREATE INDEX idx_resolution ON time_series_associations (resolution);

CREATE INDEX idx_ts_type ON time_series_associations (time_series_type);

CREATE INDEX idx_name ON time_series_associations (name);

CREATE INDEX idx_owner_type ON time_series_associations (owner_type);

CREATE INDEX idx_category_owner ON time_series_associations (owner_category, owner_id);

CREATE INDEX idx_interval ON time_series_associations (interval);

-- Partial: component_field is optional, so unset rows cost zero index entries;
-- `component_field = ?` can still use it (never true of NULL).
CREATE INDEX idx_component_field ON time_series_associations (component_field)
    WHERE component_field IS NOT NULL;

-- Hand-inspection projection (mirrors infrastore's view of the same name):
-- decodes the integer discriminants and hex-encodes the content hashes
-- (lowercase, matching infrastore's hash_hex spelling). Nothing reads it.
CREATE VIEW time_series_readable AS
SELECT id, association_id, owner_id, owner_type,
       CASE owner_category WHEN 0 THEN 'Component'
                           WHEN 1 THEN 'SupplementalAttribute'
                           ELSE 'unknown(' || owner_category || ')' END AS owner_category,
       CASE time_series_type WHEN 0 THEN 'SingleTimeSeries'
                             WHEN 1 THEN 'NonSequentialTimeSeries'
                             WHEN 2 THEN 'Deterministic'
                             WHEN 3 THEN 'DeterministicSingleTimeSeries'
                             WHEN 4 THEN 'Probabilistic'
                             WHEN 5 THEN 'Scenarios'
                             ELSE 'unknown(' || time_series_type || ')' END AS time_series_type,
       name,
       initial_timestamp, resolution, length, horizon, interval, count,
       scenario_count,
       units, quantity_kind, unit_system, time_reference, component_field,
       element_type, element_shape, application_data, uri,
       CASE WHEN data_hash IS NULL THEN NULL
            ELSE lower(hex(data_hash)) END AS data_hash,
       lower(hex(features_hash)) AS features_hash,
       -- hex() renders NULL as '', invisible to IS NULL; keep absent hashes NULL.
       CASE WHEN timestamps_hash IS NULL THEN NULL
            ELSE lower(hex(timestamps_hash)) END AS timestamps_hash
FROM time_series_associations;

CREATE TABLE loads (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    balancing_topology INTEGER NOT NULL,
    base_power REAL NOT NULL,
    FOREIGN KEY(balancing_topology) REFERENCES balancing_topologies (id) ON DELETE CASCADE
);

-- Fixed shunt admittance (PSY FixedAdmittance). Complex Y is stored as conductance
-- (y_g) and susceptance (y_b) halves; unit_basis records the basis (COMPONENT_BASE
-- -> pu on base_power; NATURAL_UNITS -> MW/MVAr at unity voltage, the quantity_type
-- on the y_g/y_b conventions distinguishing which).
CREATE TABLE fixed_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    y_g REAL NOT NULL DEFAULT 0.0,
    y_b REAL NOT NULL DEFAULT 0.0,
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0) -- Units: MVA
) strict;

-- Switched shunt admittance (PSY SwitchedAdmittance). Same y_g/y_b + unit_basis
-- template as fixed_admittance. NOTE: initial_status, number_of_steps, Y_increase, and
-- admittance_limits remain deferred -- not yet represented as columns (pre-existing gap,
-- out of scope for this change).
CREATE TABLE switched_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    y_g REAL NOT NULL DEFAULT 0.0,
    y_b REAL NOT NULL DEFAULT 0.0,
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    control_mode TEXT NOT NULL DEFAULT 'FIXED'
        CHECK (control_mode IN ('UNDEFINED', 'FIXED', 'DISCRETE_VOLTAGE',
            'CONTINUOUS_VOLTAGE', 'DISCRETE_REACTIVE_PLANT',
            'DISCRETE_REACTIVE_VSC', 'DISCRETE_ADMITTANCE_REMOTE')),
    -- 0 = local bus:
    regulated_bus_number INTEGER NOT NULL DEFAULT 0
) strict;

-- Synchronous machine connected for inertia or reactive power support (PSY
-- SynchronousCondenser). It injects no active power, so there is no
-- active_power column; active_power_losses is the loss incurred by being online.
-- Values are natural units, as everywhere else in this schema: PSY stores
-- rating/reactive_power per-unit on the device base, so a loader multiplies by
-- base_power on the way in.
CREATE TABLE synchronous_condensers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: MVAr
    rating REAL NOT NULL CHECK (rating > 0), -- Units: MVA
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    -- Reactive power limits (JSON: {"min": ..., "max": ...}), NULL when not applicable:
    reactive_power_limits TEXT NULL
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: MVAr
    active_power_losses REAL NOT NULL DEFAULT 0.0 CHECK (active_power_losses >= 0) -- Units: MW
) strict;

-- Thevenin equivalent source (PSY Source). r_th/x_th are stored flexibly in pu on
-- the component base OR natural-units ohm, recorded per row by unit_basis. PSY has
-- no native external representation for this component, so COMPONENT_BASE (pu) is
-- the default.
-- Column names are lowercase: the schemas spell these properties R_th/X_th
-- (Operations/StaticInjection/Source.json), a naming difference this schema does
-- not follow, not a semantic one -- see the sources renames in sql_codegen_map.json.
-- Values are natural units, as everywhere else in this schema: the Source schema
-- annotates these fields x-unit MW / MVAr / MVA. A consumer holding them per-unit
-- on the device base converts at deserialization; that is not this schema's job.
CREATE TABLE sources (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    -- Nominal voltage of the source terminal. Nullable: base_voltage is absent
    -- from the Source schema's required list, and a source may take the voltage of
    -- the bus it connects to:
    base_voltage REAL NULL CHECK (base_voltage IS NULL OR base_voltage > 0), -- Units: kV
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: MW
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: MVAr
    -- Power limits (JSON: {"min": ..., "max": ...}), NULL when not applicable:
    active_power_limits TEXT NULL
        CHECK (active_power_limits IS NULL OR json_valid(active_power_limits)), -- Units: MW
    reactive_power_limits TEXT NULL
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: MVAr
    -- Internal (behind-the-impedance) voltage phasor:
    internal_voltage REAL NOT NULL DEFAULT 1.0 CHECK (internal_voltage >= 0), -- Units: pu
    internal_angle REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r_th REAL NOT NULL,
    x_th REAL NOT NULL,
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- The schemas' ImportExportCost (Core/common.json). The default carries no
    -- offer curves and the schema's default weekly energy limits.
    operation_cost TEXT NOT NULL
        DEFAULT '{"import_offer_curves": null, "export_offer_curves": null, "energy_import_weekly_limit": 1000000.0, "energy_export_weekly_limit": 1000000.0, "ancillary_service_offers": []}'
        CHECK (json_valid(operation_cost))
) strict;

-- Point-to-point (two-terminal) HVDC line, one table for all three PSY variants:
-- TwoTerminalGenericHVDCLine, TwoTerminalLCCLine, TwoTerminalVSCLine. converter_type
-- records the variant. Only the fields common to all three are columns; every
-- variant-specific field (LCC's rectifier/inverter detail, VSC's converter controls
-- and setpoints, the loss curves) lives in the generic `attributes` table.
--
-- Both terminals are AC buses -- this is an AC-to-AC device, and the DC side is
-- internal to it. A multi-terminal DC network is modelled instead with
-- tmodel_hvdc_lines between DC buses plus interconnecting_converters; the
-- enforce_*_arc_domain triggers keep the two families from being mixed up.
--
-- Attribute units: fields whose unit is unambiguous carry a fixed
-- attributes.<name> convention (see column_conventions.json). Fields whose unit
-- depends on a basis choice (LCC impedances: ohm or pu) or on a sibling control
-- mode (VSC dc_setpoint_*: MW under DC_POWER, kV/pu under DC_VOLTAGE) are
-- deliberately left unregistered, so each attributes row states its own unit and
-- quantity_type -- the registry's discriminator_column mechanism cannot reach a
-- sibling that is itself an attribute.
CREATE TABLE two_terminal_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    converter_type TEXT NOT NULL DEFAULT 'GENERIC'
        CHECK (converter_type IN ('GENERIC', 'LCC', 'VSC')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: MW
    -- Terminal power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits_from TEXT NULL
        CHECK (active_power_limits_from IS NULL OR json_valid(active_power_limits_from)), -- Units: MW
    active_power_limits_to TEXT NULL
        CHECK (active_power_limits_to IS NULL OR json_valid(active_power_limits_to)), -- Units: MW
    reactive_power_limits_from TEXT NULL
        CHECK (reactive_power_limits_from IS NULL OR json_valid(reactive_power_limits_from)), -- Units: MVAr
    reactive_power_limits_to TEXT NULL
        CHECK (reactive_power_limits_to IS NULL OR json_valid(reactive_power_limits_to)) -- Units: MVAr
) strict;

-- T-model HVDC line (PSY TModelHVDCLine). This is a DC-network element: both arc
-- endpoints must be DC buses (entity_types.is_dc = 1), enforced by
-- enforce_tmodel_hvdc_lines_arc_domain. It is the multi-terminal HVDC building
-- block, paired with interconnecting_converters at each AC/DC boundary -- not a
-- point-to-point device. For point-to-point HVDC use two_terminal_hvdc_lines.
-- Only the resistance r is unit-flexible in this slice; l/c are out of scope (no
-- Inductance/pu or Capacitance/pu vocabulary yet).
-- TODO(l, c and other non-unit fields deferred).
CREATE TABLE tmodel_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL,
    unit_basis TEXT NOT NULL DEFAULT 'NATURAL_UNITS'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0) -- Units: MVA
) strict;

-- FACTS control device (PSY FACTSControlDevice). voltage_setpoint is stored flexibly
-- per unit_basis (COMPONENT_BASE: pu on bus base_voltage, the native external form;
-- NATURAL_UNITS: kV). TODO(non-unit fields).
CREATE TABLE facts_control_devices (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    voltage_setpoint REAL NOT NULL,
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Independent max reactive power ceiling (non-binding sentinel default;
    -- not unit-converted on the PSY side, hence no discriminator/unit row):
    max_reactive_power REAL NOT NULL DEFAULT 9999.0 CHECK (max_reactive_power >= 0),
    shunt_control_type TEXT NOT NULL DEFAULT 'STATCOM'
        CHECK (shunt_control_type IN ('SVC', 'STATCOM')),
    -- 0 = local (sending) bus:
    regulated_bus_number INTEGER NOT NULL DEFAULT 0
) strict;

-- Interconnecting power converter (PSY InterconnectingConverter), AC<->DC bus
-- converter. dc_setpoint/ac_setpoint are mode-multiplexed by dc_control/ac_control;
-- their voltage-mode values (DC_VOLTAGE, DC_VOLTAGE_DROOP, AC_VOLTAGE) are further
-- discriminated by unit_basis (pu/kV) via the registry's second discriminator
-- column. This table keeps its setpoints as columns (unlike the
-- consolidated two_terminal_hvdc_lines, whose variant-specific setpoints moved to
-- attributes), so the sibling-column discriminator still resolves here.
-- TODO(non-unit fields: active_power, rating, active_power_limits, base_power,
-- reactive_power_limits, dc_current, max_dc_current, loss_function,
-- dc_voltage_droop, dynamic_injector).
CREATE TABLE interconnecting_converters (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    -- bus is the AC side, dc_bus the DC side; the domain of each is enforced by
    -- enforce_interconnecting_converters_bus_domain, since a plain FK cannot see
    -- the entity_types.is_dc flag.
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    dc_bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    dc_setpoint REAL NOT NULL DEFAULT 0.0,
    dc_control TEXT NOT NULL DEFAULT 'DC_VOLTAGE' CHECK (dc_control IN ('DC_POWER','DC_VOLTAGE','DC_VOLTAGE_DROOP')),
    ac_setpoint REAL NOT NULL DEFAULT 1.0,
    ac_control TEXT NOT NULL DEFAULT 'AC_REACTIVE_POWER' CHECK (ac_control IN ('AC_VOLTAGE','AC_REACTIVE_POWER')),
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (unit_basis IN ('COMPONENT_BASE','NATURAL_UNITS')),
    -- Remote-bus voltage control, droop compensation, and
    -- reactive/active power-factor weighting (added to PSY in e6cab24c1):
    remote_bus_control INTEGER NULL CHECK (remote_bus_control IS NULL OR remote_bus_control >= 1),
    rmpct REAL NOT NULL DEFAULT 100.0 CHECK (rmpct >= 0),
    power_factor_weighting_fraction REAL NOT NULL DEFAULT 1.0 CHECK (power_factor_weighting_fraction >= 0),
    -- Voltage limits (JSON: {"min": ..., "max": ...}):
    voltage_limits TEXT NULL DEFAULT '{"min": 0.0, "max": 999.9}'
        CHECK (voltage_limits IS NULL OR json_valid(voltage_limits)),
    CHECK (bus <> dc_bus)
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
    idx INTEGER NOT NULL,
    value REAL NOT NULL
) strict;

-- UNIQUE: one value per (array, timepoint); loader double-inserts must fail
-- loudly rather than silently duplicate timepoints.
CREATE UNIQUE INDEX idx_static_time_series_uri_idx ON static_time_series (uri, idx);

CREATE INDEX idx_arcs_from ON arcs (from_id);

CREATE INDEX idx_arcs_to ON arcs (to_id);

-- UNIQUE: a circuit is owned by exactly one transformer slot; also indexes
-- the ON DELETE CASCADE child keys so transformer_circuits deletes don't
-- full-scan. (Cross-table sharing of a circuit between a two- and a
-- three-winding transformer is not yet trigger-enforced.)
CREATE UNIQUE INDEX idx_two_winding_transformers_circuit
    ON two_winding_transformers (circuit);

CREATE UNIQUE INDEX idx_three_winding_transformers_primary_circuit
    ON three_winding_transformers (primary_circuit);

CREATE UNIQUE INDEX idx_three_winding_transformers_secondary_circuit
    ON three_winding_transformers (secondary_circuit);

CREATE UNIQUE INDEX idx_three_winding_transformers_tertiary_circuit
    ON three_winding_transformers (tertiary_circuit);

CREATE INDEX idx_three_winding_transformers_star_bus
    ON three_winding_transformers (star_bus);

-- Unit System Registry Tables
-- These tables are schema-level metadata, not runtime data.
-- They are sealed after migration and protected by immutability triggers.
CREATE TABLE unit_management_metadata (
    KEY TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    description TEXT NULL
) strict;

CREATE TABLE quantity_types (
    name TEXT PRIMARY KEY NOT NULL,
    default_unit TEXT NOT NULL,
    dimension TEXT NOT NULL,
    description TEXT NULL
) strict;

-- Vocabulary of valid (quantity_type, unit) pairs. Seeded from units.json and
-- sealed like the other registry tables; unit-string writes are validated
-- against it.
CREATE TABLE allowed_units (
    quantity_type TEXT NOT NULL REFERENCES quantity_types (name),
    unit TEXT NOT NULL,
    PRIMARY KEY (quantity_type, unit)
) strict;

CREATE TABLE unit_conventions (
    id INTEGER PRIMARY KEY,
    table_name TEXT NOT NULL,
    column_name TEXT NOT NULL,
    quantity_type TEXT NOT NULL REFERENCES quantity_types (name),
    unit TEXT NOT NULL,
    -- Polymorphic units: when a column's quantity_type/unit depends on the value
    -- of a sibling column (e.g. hydro_reservoirs.level_data_type), one row is
    -- registered per discriminator value. discriminator_column names that sibling;
    -- discriminator_value is the value this row applies to. Both NULL for the
    -- common case of a column with a single fixed unit.
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
    -- Distinct units per discriminator value (and quantity_type, for columns
    -- like admittance whose NATURAL_UNITS value is disambiguated by quantity)
    -- for a polymorphic column.
    UNIQUE(table_name, column_name, discriminator_value, discriminator_value_2, quantity_type)
) strict;

-- For non-polymorphic columns (no discriminator) enforce one row per column.
-- A table-level UNIQUE can't do this because SQLite treats each NULL
-- discriminator_value as distinct, so guard those rows with a partial index.
CREATE UNIQUE INDEX uq_unit_conventions_no_discriminator
    ON unit_conventions (table_name, column_name, quantity_type)
    WHERE discriminator_value IS NULL;

-- Per-quantity-type pu resolution rule: how to divide a COMPONENT_BASE value
-- down to a physical quantity, in terms of base_power/base_voltage (or a
-- unit_conventions base_power_ref/base_voltage_ref override).
CREATE TABLE unit_basis_rules (
    quantity_type TEXT PRIMARY KEY REFERENCES quantity_types (name),
    base_expression TEXT NOT NULL,
    description TEXT NULL
) strict;
