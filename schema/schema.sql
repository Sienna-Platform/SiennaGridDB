-- DISCLAIMER
-- The current version of this schema only works for SQLITE >=3.45
-- When adding new functionality, think about the following:
--      1. Simplicity and ease of use over complexity,
--      2. Clear, consice and strict fields but allow for extensability,
--      3. User friendly over peformance, but consider performance always,
-- WARNING: This script should only be used while testing the schema and should not
-- be applied to existing dataset since it drops all the information it has.
-- Schema/registry revision; bump on every future registry or schema change.
PRAGMA user_version = 1;

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

DROP TABLE IF EXISTS time_series_associations;

DROP TABLE IF EXISTS attribute_identifiers;

DROP TABLE IF EXISTS attributes;

DROP TABLE IF EXISTS loads;

DROP TABLE IF EXISTS fixed_admittance;

DROP TABLE IF EXISTS switched_admittance;

DROP TABLE IF EXISTS synchronous_condensers;

DROP TABLE IF EXISTS sources;

DROP TABLE IF EXISTS two_terminal_hvdc_lines;


DROP TABLE IF EXISTS tmodel_hvdc_lines;


DROP TABLE IF EXISTS facts_control_devices;

DROP TABLE IF EXISTS interconnecting_converters;

DROP TABLE IF EXISTS static_time_series;

DROP TABLE IF EXISTS time_series_metadata;

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

DROP TABLE IF EXISTS trading_hub_associations;

DROP TABLE IF EXISTS trading_hubs;

DROP TABLE IF EXISTS virtual_participants;

DROP TABLE IF EXISTS point_to_point_bids;

DROP TABLE IF EXISTS unit_conventions;

DROP TABLE IF EXISTS quantity_types;

DROP TABLE IF EXISTS unit_management_metadata;

PRAGMA foreign_keys = ON;

-- NOTE: This table should not be interacted directly since it gets populated
-- automatically.
CREATE TABLE entities (
    id INTEGER PRIMARY KEY,
    entity_table TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    FOREIGN KEY (entity_type) REFERENCES entity_types (name)
) strict;

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
-- power_units is a second, independent discriminator: it governs this row's
-- power-family values (active/reactive/apparent power, ratings, limits, ramp
-- rates) -- COMPONENT_BASE -> pu on base_power; NATURAL_UNITS -> the field's
-- physical unit (MW/MVAr/MVA/...) -- while unit_basis continues to govern
-- impedances only. The DDL default below is a DB-side convenience; the wire
-- schema requires the field with no default.
CREATE TABLE transmission_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL,
    continuous_rating REAL NOT NULL CHECK (continuous_rating >= 0), -- Units: per power_units
    ste_rating REAL NULL CHECK (ste_rating >= 0),
    lte_rating REAL NULL CHECK (lte_rating >= 0),
    line_length REAL NULL CHECK (line_length >= 0),
    r REAL NOT NULL CHECK (r >= 0),
    x REAL NOT NULL,
    b TEXT NULL CHECK (b IS NULL OR json_valid(b)),
    g TEXT NULL DEFAULT '{"from": 0.0, "to": 0.0}' CHECK (g IS NULL OR json_valid(g)),
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    FOREIGN KEY (arc_id) REFERENCES arcs (id) ON DELETE CASCADE
) strict;

-- Switches and breakers connecting AC buses (PSY DiscreteControlledACBranch).
-- r/x are per-unit on system base (this component has no natural-units option
-- in PSY, unlike transmission_lines); rating is stored per power_units
-- (COMPONENT_BASE -> pu, NATURAL_UNITS -> MVA), mirroring
-- transmission_lines.continuous_rating. base_power is the same per-row
-- system-base snapshot as transmission_lines.base_power.
CREATE TABLE discrete_controlled_ac_branches (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL CHECK (r >= 0),
    x REAL NOT NULL CHECK (x >= 0),
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
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
-- follow control_objective, see unit_conventions.
CREATE TABLE transformer_circuits (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    -- available is INTEGER for STRICT (BOOLEAN is not a legal STRICT column
    -- type; it survives only in the legacy non-strict generator tables). The
    -- same idiom recurs on every strict table with a boolean flag.
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    -- Normalized tap position, 1 centered at nominal voltage:
    tap REAL NOT NULL DEFAULT 1.0 CHECK (tap >= 0 AND tap <= 2), -- Units: 1
    alpha REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r REAL NOT NULL DEFAULT 0.0, -- Units: per unit_basis
    -- Star-leg equivalent reactance of a three-winding transformer may be
    -- negative, so no sign CHECK on r/x:
    x REAL NOT NULL DEFAULT 0.0, -- Units: per unit_basis
    -- r/x are stored flexibly in per-unit on the component base (base_power
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
    rating REAL NULL CHECK (rating >= 0), -- Units: per power_units
    rating_b REAL NULL CHECK (rating_b >= 0), -- Units: per power_units
    rating_c REAL NULL CHECK (rating_c >= 0), -- Units: per power_units
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
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
CREATE TABLE transmission_interchanges (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER REFERENCES arcs(id) ON DELETE CASCADE,
    max_flow_from REAL NOT NULL,
    max_flow_to REAL NOT NULL,
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS'))
) strict;

-- NOTE: The purpose of these tables is to capture data of **existing units only**.
-- Table of thermal generation units (ThermalStandard, ThermalMultiStart)
CREATE TABLE thermal_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    fuel TEXT NOT NULL DEFAULT 'OTHER' REFERENCES fuels(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits JSON NOT NULL, -- Units: per power_units
    reactive_power_limits JSON NULL, -- Units: per power_units
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL, -- Units: per power_units
    -- Time limits (JSON: {"up": ..., "down": ...}, minutes):
    time_limits JSON NULL,
    must_run BOOLEAN NOT NULL DEFAULT FALSE,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    "status" BOOLEAN NOT NULL DEFAULT FALSE,
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- NOMENCLATURE: the schemas define ONE OperationalCost object per device,
    -- and operation_cost stores it verbatim -- fixed, start-up, shut-down and
    -- the variable_operation_cost curve (the schemas' ProductionVariableCostCurve,
    -- Core/common.json) all in the same blob, exactly as SiennaSchemas shapes it.
    -- production_cost below is a GENERATED column, not a second copy: it
    -- derives json_extract(operation_cost, '$.variable_operation_cost') so the
    -- curve -- the part that gets read, compared and repriced -- keeps a
    -- queryable column of its own with zero stored duplication. The derived
    -- column exists only where the cost object has a single production curve
    -- to pull out (the three generator tables); cost objects without one --
    -- StorageCost's charge/discharge pair, ImportExportCost's offer curves --
    -- stay whole in operation_cost, and `operation_costs` (plural) on the
    -- technology tables is the schemas' own plural field name, not a DB
    -- variation.
    -- The payload states which kind of curve it is: COST is money, FUEL is a
    -- heat rate whose money comes from fuel_cost -- so a reader never has to
    -- guess the unit of value_curve. The curve form matters too: INPUT_OUTPUT y
    -- is a cost rate at a power level, INCREMENTAL and AVERAGE_RATE are
    -- per-energy (see column_conventions.json).
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable_operation_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}'
        CHECK (json_valid(operation_cost))
        -- ifnull, not a bare IN: json_extract returns NULL for an absent key
        -- (including a missing variable_operation_cost member) and a CHECK
        -- passes on NULL, so an unlabelled or absent curve would slip through.
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '')
            IN ('COST', 'FUEL'))
        -- Three static ValueCurve forms plus their time-series-backed counterparts.
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '')
            IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                'TIME_SERIES_AVERAGE_RATE'))
        -- A FuelCurve needs exactly one price source: fuel_cost or
        -- fuel_cost_time_series, never both, never neither. Not enforced upstream.
        CHECK (json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type') <> 'FUEL'
            OR (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost') IS NOT NULL)
             <> (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost_time_series') IS NOT NULL)),
    -- Derived, not stored: the production (variable) cost curve, pulled out of
    -- operation_cost for a queryable column with zero duplication.
    production_cost JSON GENERATED ALWAYS AS (
        json_extract(operation_cost, '$.variable_operation_cost')
    ) VIRTUAL
);

-- Table of renewable generation units (RenewableDispatch, RenewableNonDispatch)
CREATE TABLE renewable_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    power_factor REAL NOT NULL DEFAULT 1.0 CHECK (
        power_factor > 0
        AND power_factor <= 1.0
    ),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    reactive_power_limits JSON NULL, -- Units: per power_units
    available BOOLEAN NOT NULL DEFAULT TRUE,
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- operation_cost is the schemas' RenewableGenerationCost object verbatim
    -- (fixed, curtailment_cost, variable_operation_cost); see the NOMENCLATURE
    -- note on thermal_generators.operation_cost. NULL for RenewableNonDispatch,
    -- which has no cost at all. variable_operation_cost is restricted to COST:
    -- RenewableGenerationCost.variable_operation_cost is a CostCurve, never a
    -- FuelCurve, and allowing FUEL here would admit rows with no registered unit.
    operation_cost JSON NULL DEFAULT '{"cost_type":"RENEWABLE","fixed":0,"curtailment_cost":{"variable_cost_type":"COST","power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}},"vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}},"variable_operation_cost":{"variable_cost_type":"COST","power_units":"NATURAL_UNITS","value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}},"vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"function_type":"LINEAR","proportional_term":0,"constant_term":0}}}}'
        CHECK (operation_cost IS NULL OR json_valid(operation_cost))
        CHECK (operation_cost IS NULL
            OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '') = 'COST')
        CHECK (operation_cost IS NULL
            OR ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '')
                IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                    'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                    'TIME_SERIES_AVERAGE_RATE')),
    -- Derived, not stored: the production (variable) cost curve, pulled out of
    -- operation_cost. NULL when operation_cost is NULL (RenewableNonDispatch).
    production_cost JSON GENERATED ALWAYS AS (
        json_extract(operation_cost, '$.variable_operation_cost')
    ) VIRTUAL
);

-- Table of hydro generation units (HydroDispatch, HydroTurbine, HydroPumpTurbine)
CREATE TABLE hydro_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'HY' REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits JSON NOT NULL, -- Units: per power_units
    reactive_power_limits JSON NULL, -- Units: per power_units
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL, -- Units: per power_units
    -- Time limits (JSON: {"up": ..., "down": ...}, minutes):
    time_limits JSON NULL,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- HydroTurbine/HydroPumpTurbine fields (nullable for HydroDispatch):
    powerhouse_elevation REAL NULL DEFAULT 0.0 CHECK (powerhouse_elevation >= 0),
    -- Outflow limits (JSON: {"min": ..., "max": ...}):
    outflow_limits JSON NULL,
    conversion_factor REAL NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    travel_time REAL NULL CHECK (travel_time >= 0),
    -- operation_cost is the schemas' HydroGenerationCost object verbatim
    -- (fixed, variable_operation_cost); see the NOMENCLATURE note on
    -- thermal_generators.operation_cost. HydroGenerationCost.variable_operation_cost
    -- is a ProductionVariableCostCurve, so FUEL is admissible here as well.
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "HYDRO_GEN", "fixed": 0.0, "variable_operation_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}'
        CHECK (json_valid(operation_cost))
        -- Same CHECKs as thermal_generators.operation_cost; see the rationale there.
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '')
            IN ('COST', 'FUEL'))
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '')
            IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                'TIME_SERIES_AVERAGE_RATE'))
        CHECK (json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type') <> 'FUEL'
            OR (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost') IS NOT NULL)
             <> (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost_time_series') IS NOT NULL)),
    -- Derived, not stored: the production (variable) cost curve, pulled out of
    -- operation_cost for a queryable column with zero duplication.
    production_cost JSON GENERATED ALWAYS AS (
        json_extract(operation_cost, '$.variable_operation_cost')
    ) VIRTUAL
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
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Storage capacity and limits (JSON: {"min": ..., "max": ...}):
    storage_capacity REAL NOT NULL CHECK (storage_capacity >= 0),
    -- Unit basis for storage_capacity: MWH is the conventional interchange form;
    -- MWMIN is the minutes basis, so duration = energy / power comes out in minutes
    -- with no hidden factor of 60.
    energy_units TEXT NOT NULL DEFAULT 'MWH' CHECK (energy_units IN ('MWH', 'MWMIN')),
    storage_level_limits JSON NOT NULL,
    initial_storage_capacity_level REAL NOT NULL CHECK (initial_storage_capacity_level >= 0),
    -- Power limits (JSON: {"min": ..., "max": ...}, input = charging, output = discharging):
    input_active_power_limits JSON NOT NULL, -- Units: per power_units
    output_active_power_limits JSON NOT NULL, -- Units: per power_units
    -- Efficiency (JSON: {"in": ..., "out": ...}):
    efficiency JSON NOT NULL,
    -- Reactive power (JSON: {"min": ..., "max": ...}):
    reactive_power_limits JSON NULL, -- Units: per power_units
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    available BOOLEAN NOT NULL DEFAULT TRUE,
    conversion_factor REAL NOT NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    storage_target REAL NOT NULL DEFAULT 0.0,
    cycle_limits INTEGER NOT NULL DEFAULT 10000 CHECK (cycle_limits > 0),
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL, -- Units: per power_units
    -- Leakage loss (fraction of stored energy lost per minute) and constant
    -- standing-loss power, both PSY-defaulted to 0.0:
    self_discharge REAL NOT NULL DEFAULT 0.0 CHECK (self_discharge >= 0),
    standing_loss REAL NOT NULL DEFAULT 0.0 CHECK (standing_loss >= 0), -- Units: per power_units
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
    -- Standing loss from evaporation, a plain fraction of stored volume/energy
    -- (the upstream schema annotates no time basis):
    evaporative_loss REAL NOT NULL DEFAULT 0.0 CHECK (evaporative_loss >= 0)
);

CREATE TABLE hydro_reservoir_connections (
    source_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    sink_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    CHECK (source_id <> sink_id),
    PRIMARY KEY (source_id, sink_id)
) strict;

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
    fuel TEXT NOT NULL DEFAULT '["OTHER"]',
    start_fuel_mmbtu_per_mw REAL NULL,
    -- Fuel cofire limits (JSON: {"fuel1": {"min": ..., "max": ...}, "fuel2": {"min": ..., "max": ...}}):
    cofire_level_limits JSON NULL,
    -- Fuel cofire start limits (JSON: {"fuel1": ..., "fuel2": ...}):
    cofire_start_limits JSON NULL,
    -- CO2 emissions (JSON: {"fuel1": ..., "fuel2": ...}, tons per MMBTU):
    co2 JSON NULL,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Ramp limits (JSON: {"up": ..., "down": ...}, MW/min):
    ramp_limits JSON NULL,
    -- Time limits (JSON: {"up": ..., "down": ...}, minutes):
    time_limits JSON NULL,
    outage_factor REAL NULL,
    min_generation_fraction REAL NULL,
    capital_costs JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    operation_costs JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}',
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
    available BOOLEAN NOT NULL DEFAULT TRUE,
    -- Duration limits (JSON: {"min": ..., "max": ...}, minutes):
    duration_limits JSON NULL,
    -- Efficiency (JSON: {"in": ..., "out": ...}, fraction):
    efficiency JSON NULL,
    min_discharge_fraction REAL NULL,
    losses REAL NULL,
    capital_costs_charge JSON NULL,
    capital_costs_discharge JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    capital_costs_energy JSON NOT NULL DEFAULT '{"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}',
    operation_costs JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}',
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

-- Optional entity data that may or may not be used for modeling
-- (geolocation, outages, ...).
CREATE TABLE supplemental_attributes (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    TYPE TEXT NOT NULL,
    value JSON NOT NULL,
    json_type TEXT generated always AS (json_type (value)) virtual
);

-- Association tables carry a surrogate `id` rather than keying on the pair alone:
-- a consumer stores that id in its own model, and AUTOINCREMENT never reissues one a
-- delete freed, so a stored reference cannot later resolve to a different, valid row.
-- The natural key stays as UNIQUE, so identity is unchanged by the surrogate.
-- Mirrors infrastore's supplemental_attribute_associations column-for-column so
-- rows deserialize straight into a store at the modeling stage. Identity is the
-- (component_id, attribute_id) pair; the type columns are denormalized labels
-- carried for filtering, not part of identity. The FKs are GridDB-side
-- integrity infrastore deliberately omits (its endpoints live in the consumer's
-- object graph; here they live in this database).
CREATE TABLE supplemental_attribute_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
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

-- Surrogate id + UNIQUE natural key; see the note above supplemental_attribute_associations.
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

-- Surrogate id + UNIQUE natural key; see the note above supplemental_attribute_associations.
CREATE TABLE time_series_associations(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    time_series_uuid TEXT NOT NULL,
    time_series_type TEXT NOT NULL,
    initial_timestamp TEXT NOT NULL,
    resolution TEXT NOT NULL,
    horizon TEXT,
    "interval" TEXT,
    window_count INTEGER,
    length INTEGER,
    name TEXT NOT NULL,
    owner_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    owner_type TEXT NOT NULL,
    owner_category TEXT NOT NULL,
    features TEXT NOT NULL,
    scaling_factor_multiplier TEXT NULL,
    metadata_uuid TEXT NOT NULL,
    units TEXT NULL
);

CREATE UNIQUE INDEX uq_time_series_assoc_owner_type_name_res_feat ON time_series_associations (
    owner_id,
    time_series_type,
    name,
    resolution,
    features
);

CREATE INDEX idx_time_series_assoc_uuid ON time_series_associations (time_series_uuid);

CREATE TABLE loads (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    balancing_topology INTEGER NOT NULL,
    base_power REAL NOT NULL,
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
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
-- rating/reactive_power/reactive_power_limits/active_power_losses are stored
-- flexibly per power_units (COMPONENT_BASE -> pu on base_power; NATURAL_UNITS
-- -> the field's physical unit).
CREATE TABLE synchronous_condensers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    rating REAL NOT NULL CHECK (rating > 0), -- Units: per power_units
    base_power REAL NOT NULL DEFAULT 100.0 CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Reactive power limits (JSON: {"min": ..., "max": ...}), NULL when not applicable:
    reactive_power_limits TEXT NULL
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: per power_units
    active_power_losses REAL NOT NULL DEFAULT 0.0 CHECK (active_power_losses >= 0) -- Units: per power_units
) strict;

-- Thevenin equivalent source (PSY Source). r_th/x_th are stored flexibly in pu on
-- the component base OR natural-units ohm, recorded per row by unit_basis. PSY has
-- no native external representation for this component, so COMPONENT_BASE (pu) is
-- the default.
-- Column names are lowercase: the schemas spell these properties R_th/X_th
-- (Operations/StaticInjection/Source.json), a naming difference this schema does
-- not follow, not a semantic one -- see the sources renames in sql_codegen_map.json.
-- active_power/reactive_power/active_power_limits/reactive_power_limits are
-- stored flexibly per power_units (COMPONENT_BASE -> pu on base_power;
-- NATURAL_UNITS -> MW/MVAr), independent of unit_basis, which governs r_th/x_th.
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
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- Power limits (JSON: {"min": ..., "max": ...}), NULL when not applicable:
    active_power_limits TEXT NULL
        CHECK (active_power_limits IS NULL OR json_valid(active_power_limits)), -- Units: per power_units
    reactive_power_limits TEXT NULL
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: per power_units
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

-- Named market trading hub (PSY TradingHub): a set of member buses at which
-- hub-settled bids are priced. Membership is carried as trading_hub_associations
-- rows, not a list column, matching the existing service/plant membership
-- convention (plant_associations, combined_cycle_associations).
CREATE TABLE trading_hubs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE
) strict;

-- One (trading hub, member) pair (PSY TradingHubAssociation). entity_id may name
-- a bus (hub membership) or a market transaction settling at the hub, resolved
-- through the entities supertype, mirroring plant_associations/
-- combined_cycle_associations.
-- Surrogate id + UNIQUE natural key; see the note above supplemental_attribute_associations.
CREATE TABLE trading_hub_associations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trading_hub_id INTEGER NOT NULL,
    entity_id INTEGER NOT NULL,
    FOREIGN KEY (trading_hub_id) REFERENCES trading_hubs (id) ON DELETE CASCADE,
    FOREIGN KEY (entity_id) REFERENCES entities (id) ON DELETE CASCADE,
    UNIQUE (trading_hub_id, entity_id)
) strict;

-- A virtual (convergence) market participant (PSY VirtualParticipant). Settles
-- either at settlement_point_id (a bus, area, or load zone, resolved through the
-- entities supertype) or at trading hubs via trading_hub_associations rows --
-- the two are mutually exclusive upstream; not enforced here, matching the
-- association-membership convention used elsewhere in this schema.
-- operation_cost is the schemas' discriminated MarketBidCost /
-- MarketBidTimeSeriesCost payload verbatim: both variants nest their supply and
-- demand curves in a CostCurve-shaped incremental_offer_curves /
-- decremental_offer_curves member, each carrying its own power_units, guarded by
-- validate_virtual_participants_cost_units_* exactly like sources' ImportExportCost.
CREATE TABLE virtual_participants (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    settlement_point_id INTEGER NULL REFERENCES entities (id) ON DELETE SET NULL,
    max_supply REAL NOT NULL CHECK (max_supply >= 0), -- Units: MW
    max_demand REAL NOT NULL CHECK (max_demand >= 0), -- Units: MW
    operation_cost TEXT NOT NULL
        CHECK (json_valid(operation_cost))
        CHECK (ifnull(json_extract(operation_cost, '$.cost_type'), '') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES'))
) strict;

-- A priced point-to-point spread bid (PSY PointToPointBid; e.g. an
-- up-to-congestion or PTP obligation bid): a willingness-to-pay curve on the
-- price spread between a source (withdrawal, from_id) and sink (injection,
-- to_id) terminal, each resolved through the entities supertype (a topology
-- record or a trading hub). spread_bid mirrors virtual_participants.
-- operation_cost's discriminated MarketBidCost / MarketBidTimeSeriesCost shape
-- (incremental side only, per the schema) and is guarded the same way.
CREATE TABLE point_to_point_bids (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    from_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    to_id INTEGER NOT NULL REFERENCES entities (id) ON DELETE CASCADE,
    max_active_power REAL NOT NULL CHECK (max_active_power >= 0), -- Units: MW
    spread_bid TEXT NOT NULL
        CHECK (json_valid(spread_bid))
        CHECK (ifnull(json_extract(spread_bid, '$.cost_type'), '') IN ('MARKET_BID', 'MARKET_BID_TIME_SERIES')),
    price_limits TEXT NOT NULL CHECK (json_valid(price_limits)), -- Units: USD/MWh
    linked_crr TEXT NULL,
    CHECK (from_id <> to_id)
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
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- Terminal power limits (JSON: {"min": ..., "max": ...}):
    active_power_limits_from TEXT NULL
        CHECK (active_power_limits_from IS NULL OR json_valid(active_power_limits_from)), -- Units: per power_units
    active_power_limits_to TEXT NULL
        CHECK (active_power_limits_to IS NULL OR json_valid(active_power_limits_to)), -- Units: per power_units
    reactive_power_limits_from TEXT NULL
        CHECK (reactive_power_limits_from IS NULL OR json_valid(reactive_power_limits_from)), -- Units: per power_units
    reactive_power_limits_to TEXT NULL
        CHECK (reactive_power_limits_to IS NULL OR json_valid(reactive_power_limits_to)) -- Units: per power_units
) strict;

-- T-model HVDC line (PSY TModelHVDCLine). This is a DC-network element: both arc
-- endpoints must be DC buses (entity_types.is_dc = 1), enforced by
-- enforce_tmodel_hvdc_lines_arc_domain. It is the multi-terminal HVDC building
-- block, paired with interconnecting_converters at each AC/DC boundary -- not a
-- point-to-point device. For point-to-point HVDC use two_terminal_hvdc_lines.
-- Only r is unit-flexible: there is no Inductance/pu or Capacitance/pu
-- vocabulary for l and c.
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
-- NATURAL_UNITS: kV). power_units is a second, independent discriminator governing
-- max_reactive_power (COMPONENT_BASE: pu; NATURAL_UNITS: MVAr).
CREATE TABLE facts_control_devices (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    voltage_setpoint REAL NOT NULL,
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Independent max reactive power ceiling (non-binding sentinel default):
    max_reactive_power REAL NOT NULL DEFAULT 9999.0 CHECK (max_reactive_power >= 0), -- Units: per power_units
    shunt_control_type TEXT NOT NULL DEFAULT 'STATCOM'
        CHECK (shunt_control_type IN ('SVC', 'STATCOM')),
    -- 0 = local (sending) bus:
    regulated_bus_number INTEGER NOT NULL DEFAULT 0
) strict;

-- Interconnecting power converter (PSY InterconnectingConverter), AC<->DC bus
-- converter. dc_setpoint/ac_setpoint are mode-multiplexed by dc_control/ac_control;
-- their voltage-mode values (DC_VOLTAGE, DC_VOLTAGE_DROOP, AC_VOLTAGE) are further
-- discriminated by unit_basis (pu/kV) via the registry's second discriminator
-- column. Setpoints stay as columns here, so the sibling-column discriminator
-- resolves.
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
    unit_basis TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (unit_basis IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    power_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Remote-bus voltage control, droop, and power-factor weighting:
    remote_bus_control INTEGER NULL CHECK (remote_bus_control IS NULL OR remote_bus_control >= 1),
    rmpct REAL NOT NULL DEFAULT 100.0 CHECK (rmpct >= 0),
    power_factor_weighting_fraction REAL NOT NULL DEFAULT 1.0 CHECK (power_factor_weighting_fraction >= 0),
    -- Voltage limits (JSON: {"min": ..., "max": ...}):
    voltage_limits TEXT NULL DEFAULT '{"min": 0.0, "max": 999.9}'
        CHECK (voltage_limits IS NULL OR json_valid(voltage_limits)),
    CHECK (bus <> dc_bus)
) strict;

CREATE TABLE static_time_series (
    id INTEGER PRIMARY KEY,
    uuid TEXT NOT NULL,
    idx INTEGER NOT NULL,
    value REAL NOT NULL
) strict;

-- Series-level metadata: one row per time series uuid, so a series cannot
-- carry mixed units. Units validated against allowed_units and enforced on
-- static_time_series inserts by triggers.
CREATE TABLE time_series_metadata (
    uuid TEXT PRIMARY KEY,
    unit TEXT NOT NULL,
    quantity_type TEXT NOT NULL REFERENCES quantity_types (name),
    -- How the series' timestamps were spelled, per the wire schemas'
    -- TimeReference: 'utc' | 'zoneless' | a fixed offset | an IANA zone name.
    -- Shape is not checked here (tz-database question). NULL means
    -- unspecified, which is deliberately not the same as utc.
    time_reference TEXT NULL,
    -- Full native shape of the stored array as a JSON array of non-negative
    -- integers ([length, *element_shape] for static series). NULL means
    -- unspecified and consumers fall back to the series' field metadata.
    array_shape TEXT NULL CHECK (
        array_shape IS NULL
        OR (json_valid(array_shape) AND json_type(array_shape) = 'array')
    )
) strict;

-- UNIQUE: one value per (series, timepoint); loader double-inserts must fail
-- loudly rather than silently duplicate timepoints.
CREATE UNIQUE INDEX idx_static_time_series_uuid_idx ON static_time_series (uuid, idx);

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

-- Registry metadata, not runtime data; sealed and trigger-protected.
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
    description TEXT NULL,
    -- Distinct units per discriminator value for a polymorphic column.
    UNIQUE(table_name, column_name, discriminator_value, discriminator_value_2)
) strict;

-- For non-polymorphic columns (no discriminator) enforce one row per column.
-- A table-level UNIQUE can't do this because SQLite treats each NULL
-- discriminator_value as distinct, so guard those rows with a partial index.
CREATE UNIQUE INDEX uq_unit_conventions_no_discriminator
    ON unit_conventions (table_name, column_name)
    WHERE discriminator_value IS NULL;
