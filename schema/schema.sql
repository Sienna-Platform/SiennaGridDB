-- Requires SQLite >= 3.45. Test-only: drops every table below, so never run
-- against a live dataset.
PRAGMA user_version = 15; -- bump on every schema or registry change

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

-- Generic from/to link between entities, reused by transmission lines,
-- interchanges, HVDC lines, and other arc-based devices.
CREATE TABLE arcs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    from_id INTEGER NOT NULL,
    to_id INTEGER NOT NULL,
    CHECK (from_id <> to_id),
    FOREIGN KEY (from_id) REFERENCES entities (id) ON DELETE CASCADE,
    FOREIGN KEY (to_id) REFERENCES entities (id) ON DELETE CASCADE
) strict;

-- r/x/b/g follow parameter_units: COMPONENT_BASE is per-unit on base_power;
-- NATURAL_UNITS is ohm (r/x) or siemens (b/g). All four share one row's basis
-- (PSY writes COMPONENT_BASE; a matpower import is NATURAL_UNITS). b/g are
-- JSON {"from": ..., "to": ...}; base_power is expected equal across every
-- COMPONENT_BASE row, though that is not trigger-enforced.
-- power_units is independent of parameter_units: it governs only the power-family
-- columns (ratings, limits, ramp rates). parameter_units's DEFAULT is a DB
-- convenience; the wire schema requires the field with no default.
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
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    FOREIGN KEY (arc_id) REFERENCES arcs (id) ON DELETE CASCADE
) strict;

-- Switches and breakers connecting AC buses (PSY DiscreteControlledACBranch).
-- r/x are always per-unit on base_power -- this component has no
-- natural-units option in PSY, unlike transmission_lines. rating follows
-- power_units, like transmission_lines.continuous_rating.
CREATE TABLE discrete_controlled_ac_branches (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL CHECK (r >= 0),
    x REAL NOT NULL CHECK (x >= 0),
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    discrete_branch_type TEXT NOT NULL DEFAULT 'OTHER'
        CHECK (discrete_branch_type IN ('SWITCH', 'BREAKER', 'OTHER')),
    branch_status TEXT NOT NULL DEFAULT 'CLOSED'
        CHECK (branch_status IN ('OPEN', 'CLOSED')),
    normal_branch_status TEXT NOT NULL DEFAULT 'CLOSED'
        CHECK (normal_branch_status IN ('OPEN', 'CLOSED'))
) strict;

-- One modeled arc of a transformer (PSY TransformerCircuit); unnamed
-- subcomponents, so no name column. r/x follow parameter_units (COMPONENT_BASE ->
-- pu on base_power/base_voltage_primary; NATURAL_UNITS -> ohm). The MinMax
-- band columns' units follow control_objective; see unit_conventions.
CREATE TABLE transformer_circuits (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    -- available is INTEGER, not BOOLEAN: STRICT tables reject BOOLEAN as a
    -- column type. The same idiom recurs on every strict table with a flag.
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    -- Normalized tap position, 1 centered at nominal voltage:
    tap REAL NOT NULL DEFAULT 1.0 CHECK (tap >= 0 AND tap <= 2), -- Units: 1
    alpha REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units
    -- Star-leg equivalent reactance of a three-winding transformer may be
    -- negative, so no sign CHECK on r/x:
    x REAL NOT NULL DEFAULT 0.0, -- Units: per parameter_units
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    control_objective TEXT NOT NULL DEFAULT 'UNDEFINED'
        CHECK (control_objective IN ('UNDEFINED', 'VOLTAGE_DISABLED',
            'REACTIVE_POWER_FLOW_DISABLED', 'ACTIVE_POWER_FLOW_DISABLED',
            'CONTROL_OF_DC_LINE_DISABLED',
            'ASYMMETRIC_ACTIVE_POWER_FLOW_DISABLED', 'FIXED', 'VOLTAGE',
            'REACTIVE_POWER_FLOW', 'ACTIVE_POWER_FLOW', 'CONTROL_OF_DC_LINE',
            'ASYMMETRIC_ACTIVE_POWER_FLOW')),
    -- Controlled bus number (sign = regulation side):
    regulated_bus_number INTEGER NOT NULL DEFAULT 0,
    control_limits TEXT NULL DEFAULT '{"min": 0.9, "max": 1.1}'
        CHECK (control_limits IS NULL OR json_valid(control_limits)), -- Units: per control_objective (tap ratio 1 / angle rad)
    controlled_quantity_limits TEXT NULL DEFAULT '{"min": 0.9, "max": 1.1}'
        CHECK (controlled_quantity_limits IS NULL OR json_valid(controlled_quantity_limits)), -- Units: per control_objective (pu / MVAr / MW)
    number_of_tap_positions INTEGER NOT NULL DEFAULT 33,
    rating REAL NULL CHECK (rating >= 0), -- Units: per power_units
    rating_b REAL NULL CHECK (rating_b >= 0), -- Units: per power_units
    rating_c REAL NULL CHECK (rating_c >= 0), -- Units: per power_units
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
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
    r_12 REAL NULL, -- Units: per parameter_units
    x_12 REAL NULL, -- Units: per parameter_units
    r_23 REAL NULL, -- Units: per parameter_units
    x_23 REAL NULL, -- Units: per parameter_units
    r_31 REAL NULL, -- Units: per parameter_units
    x_31 REAL NULL, -- Units: per parameter_units
    -- Pairwise measured r/x follow parameter_units: COMPONENT_BASE is pu on
    -- base_power_12/_23/_31, all three referred to the primary winding's
    -- voltage base per PSSE convention; NATURAL_UNITS is ohm.
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
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

-- Physical flow limits between areas or balancing topologies, distinct from
-- transmission_lines: these enforce market-level interchange limits.
CREATE TABLE transmission_interchanges (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER REFERENCES arcs(id) ON DELETE CASCADE,
    max_flow_from REAL NOT NULL,
    max_flow_to REAL NOT NULL,
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS'))
) strict;

-- Existing thermal generation units (ThermalStandard, ThermalMultiStart).
CREATE TABLE thermal_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    fuel TEXT NOT NULL DEFAULT 'OTHER' REFERENCES fuels(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_limits JSON NOT NULL, -- {"min": ..., "max": ...}; Units: per power_units
    reactive_power_limits JSON NULL, -- {"min": ..., "max": ...}; Units: per power_units
    ramp_limits JSON NULL, -- {"up": ..., "down": ...}; Units: per power_units
    time_limits JSON NULL, -- {"up": ..., "down": ...}, minutes
    available BOOLEAN NOT NULL DEFAULT TRUE,
    status TEXT NOT NULL CHECK (status IN ('OFFLINE', 'ONLINE', 'STARTUP', 'SHUTDOWN')),
    commitment_mode TEXT NOT NULL DEFAULT 'COMMITTED'
        CHECK (commitment_mode IN ('UNCOMMITTED', 'COMMITTED', 'SELF_SCHEDULED', 'RELIABILITY', 'MUST_RUN')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- operation_cost stores the schemas' OperationalCost object verbatim
    -- (fixed, start-up, shut-down, variable_operation_cost). production_cost
    -- is a GENERATED column pulling out variable_operation_cost -- the curve
    -- that gets read, compared, and repriced -- with zero stored duplication;
    -- only tables with a single production curve get one (StorageCost and
    -- ImportExportCost keep their curves inline instead).
    -- The curve states its own kind: COST is money, FUEL is a heat rate
    -- priced via fuel_cost. INPUT_OUTPUT is a cost rate at a power level;
    -- INCREMENTAL and AVERAGE_RATE are per-energy (see column_conventions.json).
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "THERMAL", "fixed": 0, "shut_down": 0, "start_up": 0, "variable_operation_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}, "vom_cost": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}'
        CHECK (json_valid(operation_cost))
        -- ifnull, not a bare IN: json_extract returns NULL for an absent key,
        -- and a CHECK passes on NULL, so an absent curve would slip through.
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type'), '')
            IN ('COST', 'FUEL'))
        CHECK (ifnull(json_extract(operation_cost, '$.variable_operation_cost.value_curve.curve_type'), '')
            IN ('INPUT_OUTPUT', 'INCREMENTAL', 'AVERAGE_RATE',
                'TIME_SERIES_INPUT_OUTPUT', 'TIME_SERIES_INCREMENTAL',
                'TIME_SERIES_AVERAGE_RATE'))
        -- A FuelCurve needs exactly one price source: fuel_cost or
        -- fuel_cost_time_series, never both, never neither. Not enforced upstream.
        CHECK (json_extract(operation_cost, '$.variable_operation_cost.variable_cost_type') <> 'FUEL'
            OR (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost') IS NOT NULL)
             <> (json_extract(operation_cost, '$.variable_operation_cost.fuel_cost_time_series') IS NOT NULL)),
    production_cost JSON GENERATED ALWAYS AS (
        json_extract(operation_cost, '$.variable_operation_cost')
    ) VIRTUAL
);

-- Existing renewable generation units (RenewableDispatch, RenewableNonDispatch).
CREATE TABLE renewable_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    power_factor REAL NOT NULL DEFAULT 1.0 CHECK (
        power_factor > 0
        AND power_factor <= 1.0
    ),
    reactive_power_limits JSON NULL, -- {"min": ..., "max": ...}; Units: per power_units
    available BOOLEAN NOT NULL DEFAULT TRUE,
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- operation_cost is the schemas' RenewableGenerationCost object verbatim;
    -- see thermal_generators.operation_cost. NULL for RenewableNonDispatch,
    -- which has no cost. variable_operation_cost is restricted to COST:
    -- RenewableGenerationCost's curve is always a CostCurve, never a
    -- FuelCurve, and FUEL here would admit rows with no registered unit.
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

-- Existing hydro generation units (HydroDispatch, HydroTurbine, HydroPumpTurbine).
CREATE TABLE hydro_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL DEFAULT 'HY' REFERENCES prime_mover_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_limits JSON NOT NULL, -- {"min": ..., "max": ...}; Units: per power_units
    reactive_power_limits JSON NULL, -- {"min": ..., "max": ...}; Units: per power_units
    ramp_limits JSON NULL, -- {"up": ..., "down": ...}; Units: per power_units
    time_limits JSON NULL, -- {"up": ..., "down": ...}, minutes
    available BOOLEAN NOT NULL DEFAULT TRUE,
    status TEXT NOT NULL DEFAULT 'OFFLINE' CHECK (status IN ('OFFLINE', 'ONLINE', 'STARTUP', 'SHUTDOWN')),
    commitment_mode TEXT NOT NULL DEFAULT 'COMMITTED'
        CHECK (commitment_mode IN ('UNCOMMITTED', 'COMMITTED', 'SELF_SCHEDULED', 'RELIABILITY', 'MUST_RUN')),
    operating_mode TEXT NULL CHECK (operating_mode IS NULL OR operating_mode IN ('PUMP', 'GEN', 'OFF')), -- HydroPumpTurbine only
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- HydroTurbine/HydroPumpTurbine fields (nullable for HydroDispatch):
    powerhouse_elevation REAL NULL DEFAULT 0.0 CHECK (powerhouse_elevation >= 0),
    outflow_limits JSON NULL, -- {"min": ..., "max": ...}
    conversion_factor REAL NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    travel_time REAL NULL CHECK (travel_time >= 0),
    -- operation_cost is the schemas' HydroGenerationCost object verbatim
    -- (fixed, variable_operation_cost); see thermal_generators.operation_cost.
    -- Its curve is a ProductionVariableCostCurve, so FUEL is admissible too.
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
    production_cost JSON GENERATED ALWAYS AS (
        json_extract(operation_cost, '$.variable_operation_cost')
    ) VIRTUAL
    -- efficiency (varies by type), turbine_type, and HydroPumpTurbine-specific
    -- fields (active_power_limits_pump, etc.) live in the attributes table.
);

-- Existing energy storage units, including PHES and other kinds.
CREATE TABLE storage_units (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    prime_mover_type TEXT NOT NULL REFERENCES prime_mover_types(name),
    storage_technology_type TEXT NOT NULL REFERENCES storage_technology_types(name),
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    rating REAL NOT NULL CHECK (rating >= 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0),
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    storage_capacity REAL NOT NULL CHECK (storage_capacity >= 0),
    -- energy_units for storage_capacity: MWMIN makes duration = energy / power
    -- come out in minutes with no hidden factor of 60.
    energy_units TEXT NOT NULL DEFAULT 'MWH' CHECK (energy_units IN ('MWH', 'MWMIN')),
    storage_level_limits JSON NOT NULL, -- {"min": ..., "max": ...}
    initial_storage_capacity_level REAL NOT NULL CHECK (initial_storage_capacity_level >= 0),
    -- input = charging, output = discharging:
    input_active_power_limits JSON NOT NULL, -- Units: per power_units
    output_active_power_limits JSON NOT NULL, -- Units: per power_units
    efficiency JSON NOT NULL, -- {"in": ..., "out": ...}
    reactive_power_limits JSON NULL, -- Units: per power_units
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    available BOOLEAN NOT NULL DEFAULT TRUE,
    conversion_factor REAL NOT NULL DEFAULT 1.0 CHECK (conversion_factor > 0),
    storage_target REAL NOT NULL DEFAULT 0.0,
    cycle_limits INTEGER NOT NULL DEFAULT 10000 CHECK (cycle_limits > 0),
    ramp_limits JSON NULL, -- {"up": ..., "down": ...}; Units: per power_units
    -- Leakage loss (fraction of stored energy lost per minute) and constant
    -- standing-loss power, both PSY-defaulted to 0.0:
    self_discharge REAL NOT NULL DEFAULT 0.0 CHECK (self_discharge >= 0),
    standing_loss REAL NOT NULL DEFAULT 0.0 CHECK (standing_loss >= 0), -- Units: per power_units
    -- The whole StorageCost object, both curves included -- two curves, not
    -- one, so neither promotes to production_cost. Paths are registered in
    -- column_conventions.json (operation_cost.charge_variable_cost /
    -- .discharge_variable_cost) and guarded by validate_storage_units_cost_units_*.
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "STORAGE", "charge_variable_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}, "discharge_variable_cost": {"variable_cost_type": "COST", "power_units": "NATURAL_UNITS", "value_curve": {"curve_type": "INPUT_OUTPUT", "function_data": {"function_type": "LINEAR", "proportional_term": 0, "constant_term": 0}}}}'
);

-- Topological hydro reservoirs
CREATE TABLE hydro_reservoirs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL DEFAULT TRUE,
    storage_level_limits JSON NOT NULL, -- {"min": ..., "max": ...}
    initial_level REAL NOT NULL,
    spillage_limits JSON NULL, -- {"min": ..., "max": ...}
    inflow REAL NOT NULL DEFAULT 0.0,
    outflow REAL NOT NULL DEFAULT 0.0,
    level_targets REAL NULL,
    intake_elevation REAL NOT NULL DEFAULT 0.0,
    head_to_volume_factor JSON NOT NULL, -- ValueCurve
    -- Always USD/MWh regardless of level_data_type; level-native values
    -- convert to energy via head_to_volume_factor before costing:
    operation_cost JSON NOT NULL DEFAULT '{"cost_type": "HYDRO_RES", "level_shortage_cost": 0.0, "level_surplus_cost": 0.0, "spillage_cost": 0.0}',
    level_data_type TEXT NOT NULL DEFAULT 'USABLE_VOLUME' CHECK (
        level_data_type IN ('USABLE_VOLUME', 'TOTAL_VOLUME', 'HEAD', 'ENERGY')
    ),
    -- Evaporation loss, a plain fraction of stored volume/energy with no time basis:
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
    capacity_limits JSON NULL, -- Units: MW
    fuel TEXT NOT NULL DEFAULT '["OTHER"]',
    start_fuel_mmbtu_per_mw REAL NULL,
    cofire_level_limits JSON NULL, -- {"fuel1": {min,max}, "fuel2": {min,max}}
    cofire_start_limits JSON NULL, -- {"fuel1": ..., "fuel2": ...}
    co2 JSON NULL, -- {"fuel1": ..., "fuel2": ...}, tons per MMBTU
    available BOOLEAN NOT NULL DEFAULT TRUE,
    ramp_limits JSON NULL, -- {"up": ..., "down": ...}, MW/min
    time_limits JSON NULL, -- {"up": ..., "down": ...}, minutes
    outage_factor JSON NULL, -- {"forced": ..., "planned": ...}, fraction
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
    capacity_limits_charge JSON NULL, -- Units: MW
    capacity_limits_discharge JSON NULL, -- Units: MW
    capacity_limits_energy JSON NULL, -- Units: MW
    available BOOLEAN NOT NULL DEFAULT TRUE,
    duration_limits JSON NULL, -- Units: minutes
    efficiency JSON NULL, -- {"in": ..., "out": ...}, fraction
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
    quantity_type TEXT NULL REFERENCES quantity_types (name),
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

INSERT INTO
    attribute_identifiers (TYPE, name, description)
VALUES
    ('ACBus', 'number', 'Bus number'),
    ('DCBus', 'number', 'Bus number'),
    ('ACBus', 'load_zone', 'Load zone reference'),
    ('DCBus', 'load_zone', 'Load zone reference'),
    ('NodalACTransportTechnology', 'start_node', 'Transport technology from-node reference'),
    ('NodalHVDCTransportTechnology', 'start_node', 'Transport technology from-node reference'),
    ('NodalACTransportTechnology', 'end_node', 'Transport technology to-node reference'),
    ('NodalHVDCTransportTechnology', 'end_node', 'Transport technology to-node reference');

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

CREATE TABLE time_series_associations(
    id INTEGER PRIMARY KEY,
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
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    FOREIGN KEY(balancing_topology) REFERENCES balancing_topologies (id) ON DELETE CASCADE
);

-- Fixed shunt admittance (PSY FixedAdmittance): Y as conductance (y_g) and
-- susceptance (y_b). admittance_units is NATURAL_UNITS (siemens) or
-- COMPONENT_MVAR (MW/MVAr at unity voltage, PSS/E native) -- no per-unit arm,
-- since a shunt has no MVA rating; base_power is just the recorded base.
CREATE TABLE fixed_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    y_g REAL NOT NULL DEFAULT 0.0, -- Units: per admittance_units
    y_b REAL NOT NULL DEFAULT 0.0, -- Units: per admittance_units
    admittance_units TEXT NOT NULL DEFAULT 'COMPONENT_MVAR'
        CHECK (admittance_units IN ('NATURAL_UNITS', 'COMPONENT_MVAR')),
    base_power REAL NOT NULL CHECK (base_power > 0) -- Units: MVA
) strict;

-- Switched shunt admittance (PSY SwitchedAdmittance). Effective admittance is
-- number_engaged * Y_increase, or solved_admittance when present.
-- admittance_units is NATURAL_UNITS (siemens) or COMPONENT_MVAR (MW/MVAr at
-- unity voltage, PSS/E native). No base_power: neither basis needs one.
CREATE TABLE switched_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    admittance_units TEXT NOT NULL DEFAULT 'COMPONENT_MVAR'
        CHECK (admittance_units IN ('NATURAL_UNITS', 'COMPONENT_MVAR')),
    Y_increase TEXT NULL -- Units: per admittance_units
        CHECK (Y_increase IS NULL OR json_valid(Y_increase)),
    number_engaged TEXT NULL
        CHECK (number_engaged IS NULL OR json_valid(number_engaged)),
    number_of_steps TEXT NULL
        CHECK (number_of_steps IS NULL OR json_valid(number_of_steps)),
    solved_admittance REAL NULL, -- Units: per admittance_units
    admittance_limits TEXT NULL DEFAULT '{"min": 1.0, "max": 1.0}' -- Units: per admittance_units
        CHECK (admittance_limits IS NULL OR json_valid(admittance_limits)),
    control_mode TEXT NOT NULL DEFAULT 'FIXED'
        CHECK (control_mode IN ('UNDEFINED', 'FIXED', 'DISCRETE_VOLTAGE',
            'CONTINUOUS_VOLTAGE', 'DISCRETE_REACTIVE_PLANT',
            'DISCRETE_REACTIVE_VSC', 'DISCRETE_ADMITTANCE_REMOTE')),
    -- 0 = local bus:
    regulated_bus_number INTEGER NOT NULL DEFAULT 0
) strict;

-- Synchronous machine for inertia or reactive support (PSY SynchronousCondenser).
-- It injects no active power, so there is no active_power column;
-- active_power_losses is the loss incurred by being online. Power-family
-- columns follow power_units (COMPONENT_BASE -> pu; NATURAL_UNITS -> physical unit).
CREATE TABLE synchronous_condensers (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    rating REAL NOT NULL CHECK (rating > 0), -- Units: per power_units
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    reactive_power_limits TEXT NULL -- {"min": ..., "max": ...}
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: per power_units
    active_power_losses REAL NOT NULL DEFAULT 0.0 CHECK (active_power_losses >= 0) -- Units: per power_units
) strict;

-- Thevenin equivalent source (PSY Source). r_th/x_th follow parameter_units: pu on
-- base_power, or natural-units ohm; COMPONENT_BASE is the default since PSY
-- has no native external representation for this component. Column names are
-- lowercase (the schemas spell R_th/X_th) -- a naming difference only, see
-- sql_codegen_map.json. Power-family columns follow power_units instead,
-- independent of parameter_units.
CREATE TABLE sources (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    -- Nullable: a source may take the voltage of the bus it connects to instead:
    base_voltage REAL NULL CHECK (base_voltage IS NULL OR base_voltage > 0), -- Units: kV
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    reactive_power REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    active_power_limits TEXT NULL -- {"min": ..., "max": ...}
        CHECK (active_power_limits IS NULL OR json_valid(active_power_limits)), -- Units: per power_units
    reactive_power_limits TEXT NULL -- {"min": ..., "max": ...}
        CHECK (reactive_power_limits IS NULL OR json_valid(reactive_power_limits)), -- Units: per power_units
    -- Internal (behind-the-impedance) voltage phasor:
    internal_voltage REAL NOT NULL DEFAULT 1.0 CHECK (internal_voltage >= 0), -- Units: pu
    internal_angle REAL NOT NULL DEFAULT 0.0, -- Units: rad
    r_th REAL NOT NULL,
    x_th REAL NOT NULL,
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- The schemas' ImportExportCost (Core/common.json). The default carries no
    -- offer curves and the schema's default weekly energy limits.
    operation_cost TEXT NOT NULL
        DEFAULT '{"import_offer_curves": null, "export_offer_curves": null, "energy_import_weekly_limit": 1000000.0, "energy_export_weekly_limit": 1000000.0, "ancillary_service_offers": []}'
        CHECK (json_valid(operation_cost))
) strict;

-- Named market trading hub (PSY TradingHub): a set of member buses at which
-- hub-settled bids are priced. Membership is trading_hub_associations rows,
-- not a list column, matching plant_associations/combined_cycle_associations.
CREATE TABLE trading_hubs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE
) strict;

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

-- A virtual (convergence) market participant (PSY VirtualParticipant). Settles
-- at settlement_point_id or via trading_hub_associations rows -- mutually
-- exclusive upstream, not enforced here. operation_cost is the schemas'
-- discriminated MarketBidCost / MarketBidTimeSeriesCost payload verbatim,
-- guarded by validate_virtual_participants_cost_units_* like sources'
-- ImportExportCost.
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

-- A priced point-to-point spread bid (PSY PointToPointBid): a
-- willingness-to-pay curve on the price spread between a source (from_id)
-- and sink (to_id), each resolved through the entities supertype. spread_bid
-- mirrors virtual_participants.operation_cost and is guarded the same way.
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

-- Point-to-point (two-terminal) HVDC line, one table for all three PSY variants
-- (Generic/LCC/VSC), discriminated by converter_type. Only fields common to
-- all three are columns; variant-specific fields (LCC rectifier/inverter
-- detail, VSC controls, loss curves) live in the generic attributes table.
-- Both terminals are AC buses, DC side internal -- unlike tmodel_hvdc_lines,
-- which runs between DC buses for multi-terminal networks.
-- Some attribute units depend on a basis choice or a sibling control mode
-- (LCC impedances, VSC dc_setpoint_*) and are left unregistered in
-- column_conventions.json: the registry can't reach a sibling that is itself
-- an attribute, so each such row states its own unit.
CREATE TABLE two_terminal_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    converter_type TEXT NOT NULL DEFAULT 'GENERIC'
        CHECK (converter_type IN ('GENERIC', 'LCC', 'VSC')),
    available INTEGER NOT NULL DEFAULT 1 CHECK (available IN (0, 1)),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    active_power_flow REAL NOT NULL DEFAULT 0.0, -- Units: per power_units
    -- {"min": ..., "max": ...}:
    active_power_limits_from TEXT NULL
        CHECK (active_power_limits_from IS NULL OR json_valid(active_power_limits_from)), -- Units: per power_units
    active_power_limits_to TEXT NULL
        CHECK (active_power_limits_to IS NULL OR json_valid(active_power_limits_to)), -- Units: per power_units
    reactive_power_limits_from TEXT NULL
        CHECK (reactive_power_limits_from IS NULL OR json_valid(reactive_power_limits_from)), -- Units: per power_units
    reactive_power_limits_to TEXT NULL
        CHECK (reactive_power_limits_to IS NULL OR json_valid(reactive_power_limits_to)) -- Units: per power_units
) strict;

-- T-model HVDC line (PSY TModelHVDCLine): a DC-network element whose arc
-- endpoints must both be DC buses (entity_types.is_dc = 1), enforced by
-- enforce_tmodel_hvdc_lines_arc_domain. It is the multi-terminal building
-- block, paired with interconnecting_converters at each AC/DC boundary --
-- use two_terminal_hvdc_lines for point-to-point HVDC. Only r is
-- unit-flexible; l and c have no Inductance/pu or Capacitance/pu vocabulary.
CREATE TABLE tmodel_hvdc_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL,
    parameter_units TEXT NOT NULL DEFAULT 'NATURAL_UNITS'
        CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- The one exception to the per-row base_power rule: a DC line's per-unit
    -- fields resolve against a current base, not a power base, because the DC
    -- line current is the value that is actually known. Upstream
    -- TModelHVDCLine carries base_current and no base_power at all.
    base_current REAL NOT NULL CHECK (base_current > 0) -- Units: A
) strict;

-- FACTS control device (PSY FACTSControlDevice). voltage_setpoint is stored flexibly
-- per parameter_units (COMPONENT_BASE: pu on bus base_voltage, the native external form;
-- NATURAL_UNITS: kV). power_units is a second, independent discriminator governing
-- max_reactive_power (COMPONENT_BASE: pu; NATURAL_UNITS: MVAr).
CREATE TABLE facts_control_devices (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    voltage_setpoint REAL NOT NULL,
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE'
        CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Independent max reactive power ceiling (non-binding sentinel default):
    max_reactive_power REAL NOT NULL DEFAULT 9999.0 CHECK (max_reactive_power >= 0), -- Units: per power_units
    shunt_control_type TEXT NOT NULL DEFAULT 'STATCOM'
        CHECK (shunt_control_type IN ('SVC', 'STATCOM')),
    -- 0 = local (sending) bus:
    regulated_bus_number INTEGER NOT NULL DEFAULT 0
) strict;

-- Interconnecting power converter (PSY InterconnectingConverter), an AC<->DC
-- bus converter. dc_setpoint/ac_setpoint are mode-multiplexed by
-- dc_control/ac_control; their voltage-mode values (DC_VOLTAGE,
-- DC_VOLTAGE_DROOP, AC_VOLTAGE) are further discriminated by parameter_units
-- (pu/kV) via the registry's second discriminator column.
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
    parameter_units TEXT NOT NULL DEFAULT 'COMPONENT_BASE' CHECK (parameter_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    base_power REAL NOT NULL CHECK (base_power > 0), -- Units: MVA
    power_units TEXT NOT NULL CHECK (power_units IN ('COMPONENT_BASE', 'NATURAL_UNITS')),
    -- Remote-bus voltage control, droop, and power-factor weighting:
    remote_bus_control INTEGER NULL CHECK (remote_bus_control IS NULL OR remote_bus_control >= 1),
    rmpct REAL NOT NULL DEFAULT 100.0 CHECK (rmpct >= 0),
    power_factor_weighting_fraction REAL NOT NULL DEFAULT 1.0 CHECK (power_factor_weighting_fraction >= 0),
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
    -- Timestamp spelling, per the wire schemas' TimeReference: 'utc' |
    -- 'zoneless' | a fixed offset | an IANA zone name. NULL means
    -- unspecified, deliberately not the same as utc.
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
