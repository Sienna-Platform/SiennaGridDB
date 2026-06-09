-- GENERATED FILE -- DO NOT EDIT.
-- Produced by scripts/generate_sql_schema.py from the SiennaSchemas JSON
-- Schemas (schema/schema_map.json x schema/sql_codegen_map.json).
--
-- This is a REFERENCE projection of the schemas into SQLite DDL. The
-- production DDL is the hand-written schema/schema.sql; compare the two with
--     python3 scripts/generate_sql_schema.py --diff
-- to see where the hand-written schema has drifted from the schemas.

-- thermal_generators: generated from ThermalStandard, ThermalMultiStart
CREATE TABLE thermal_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    status BOOLEAN NOT NULL,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    active_power REAL NOT NULL, -- Units: MW
    reactive_power REAL NOT NULL, -- Units: MVAr
    rating REAL NOT NULL, -- Units: MVA
    active_power_limits JSON NOT NULL, -- Units: MW
    reactive_power_limits JSON NULL, -- Units: MVAr
    ramp_limits JSON NULL, -- Units: MW/min
    operation_cost JSON NOT NULL,
    base_power REAL NOT NULL, -- Units: MVA
    time_limits JSON NULL, -- Units: h
    must_run BOOLEAN NULL DEFAULT FALSE,
    prime_mover_type TEXT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types (name),
    fuel TEXT NULL DEFAULT 'OTHER' CHECK (fuel IN ('ANTHRACITE_COAL', 'BITUMINOUS_COAL', 'LIGNITE_COAL', 'SUBBITUMINOUS_COAL', 'WASTE_COAL', 'REFINED_COAL', 'SYNTHESIS_GAS_COAL', 'DISTILLATE_FUEL_OIL', 'JET_FUEL', 'KEROSENE', 'PETROLEUM_COKE', 'RESIDUAL_FUEL_OIL', 'PROPANE', 'SYNTHESIS_GAS_PETROLEUM_COKE', 'WASTE_OIL', 'BLASTE_FURNACE_GAS', 'NATURAL_GAS', 'OTHER_GAS', 'AG_BYPRODUCT', 'MUNICIPAL_WASTE', 'OTHER_BIOMASS_SOLIDS', 'WOOD_WASTE_SOLIDS', 'OTHER_BIOMASS_LIQUIDS', 'SLUDGE_WASTE', 'BLACK_LIQUOR', 'WOOD_WASTE_LIQUIDS', 'LANDFILL_GAS', 'OTHEHR_BIOMASS_GAS', 'NUCLEAR', 'WASTE_HEAT', 'TIREDERIVED_FUEL', 'COAL', 'GEOTHERMAL', 'OTHER')) REFERENCES fuels (name),
    time_at_status REAL NULL DEFAULT 10000.0, -- Units: h
    dynamic_injector INTEGER NULL,
    power_trajectory JSON NULL, -- Units: MW
    start_time_limits JSON NULL, -- Units: h
    start_types INTEGER NULL
);

-- renewable_generators: generated from RenewableDispatch, RenewableNonDispatch
CREATE TABLE renewable_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    active_power REAL NOT NULL, -- Units: MW
    reactive_power REAL NOT NULL, -- Units: MVAr
    rating REAL NOT NULL, -- Units: MVA
    prime_mover_type TEXT NOT NULL CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types (name),
    reactive_power_limits JSON NULL, -- Units: MVAr
    power_factor REAL NOT NULL, -- Units: 1
    operation_cost JSON NULL,
    base_power REAL NOT NULL, -- Units: MVA
    dynamic_injector INTEGER NULL
);

-- hydro_generators: generated from HydroDispatch, HydroTurbine, HydroPumpTurbine
-- Stored via the generic `attributes` table (registered attribute-name
-- conventions), not as columns: efficiency, active_power_limits_pump, turbine_type
CREATE TABLE hydro_generators (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    active_power REAL NOT NULL, -- Units: MW
    reactive_power REAL NOT NULL, -- Units: MVAr
    rating REAL NOT NULL, -- Units: MVA
    prime_mover_type TEXT NULL CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types (name),
    active_power_limits JSON NOT NULL, -- Units: MW
    reactive_power_limits JSON NULL, -- Units: MVAr
    ramp_limits JSON NULL, -- Units: MW/min
    time_limits JSON NULL, -- Units: h
    base_power REAL NOT NULL, -- Units: MVA
    status BOOLEAN NULL DEFAULT FALSE,
    time_at_status REAL NULL DEFAULT 10000.0, -- Units: h
    operation_cost JSON NOT NULL DEFAULT '{"variable":{"value_curve":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0},"input_at_zero":0},"variable_cost_type":"COST","vom_cost":{"curve_type":"INPUT_OUTPUT","function_data":{"constant_term":0,"function_type":"LINEAR","proportional_term":0},"input_at_zero":0}}}',
    dynamic_injector INTEGER NULL,
    powerhouse_elevation REAL NULL DEFAULT 0.0, -- Units: m
    outflow_limits JSON NULL, -- Units: m3/s
    conversion_factor REAL NULL DEFAULT 1.0, -- Units: 1
    travel_time REAL NULL, -- Units: h
    active_power_pump REAL NULL DEFAULT 0.0, -- Units: MW
    transition_time JSON NULL DEFAULT '{"pump":0.0,"turbine":0.0}', -- Units: h
    minimum_time JSON NULL DEFAULT '{"pump":0.0,"turbine":0.0}', -- Units: h
    must_run BOOLEAN NULL DEFAULT FALSE
);

-- storage_units: generated from EnergyReservoirStorage
CREATE TABLE storage_units (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    prime_mover_type TEXT NOT NULL CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types (name),
    storage_technology_type TEXT NOT NULL CHECK (storage_technology_type IN ('PTES', 'LIB', 'LAB', 'FLWB', 'SIB', 'ZIB', 'HGS', 'LAES', 'OTHER_CHEM', 'OTHER_MECH', 'OTHER_THERM')) REFERENCES storage_technology_types (name),
    storage_capacity REAL NOT NULL, -- Units: MWh
    storage_level_limits JSON NOT NULL,
    initial_storage_capacity_level REAL NOT NULL, -- Units: 1
    rating REAL NOT NULL, -- Units: MVA
    active_power REAL NOT NULL, -- Units: MW
    input_active_power_limits JSON NOT NULL, -- Units: MW
    output_active_power_limits JSON NOT NULL, -- Units: MW
    efficiency JSON NOT NULL,
    reactive_power REAL NOT NULL, -- Units: MVAr
    reactive_power_limits JSON NULL, -- Units: MVAr
    base_power REAL NOT NULL, -- Units: MVA
    operation_cost JSON NOT NULL,
    conversion_factor REAL NULL DEFAULT 1.0, -- Units: 1
    storage_target REAL NULL DEFAULT 0.0, -- Units: 1
    cycle_limits INTEGER NULL DEFAULT 10000, -- Units: 1
    dynamic_injector INTEGER NULL
);

-- hydro_reservoirs: generated from HydroReservoir
CREATE TABLE hydro_reservoirs (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    storage_level_limits JSON NOT NULL, -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    initial_level REAL NOT NULL, -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    spillage_limits JSON NULL, -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    inflow REAL NOT NULL, -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    outflow REAL NOT NULL, -- Units: per level_data_type (ENERGY: MW, HEAD: m/s, TOTAL_VOLUME: m3/s, USABLE_VOLUME: m3/s)
    level_targets REAL NULL, -- Units: per level_data_type (ENERGY: MWh, HEAD: m, TOTAL_VOLUME: m3, USABLE_VOLUME: m3)
    intake_elevation REAL NOT NULL, -- Units: m
    head_to_volume_factor JSON NOT NULL,
    upstream_turbines JSON NULL,
    downstream_turbines JSON NULL,
    upstream_reservoirs JSON NULL,
    operation_cost JSON NOT NULL,
    level_data_type TEXT NULL DEFAULT 'USABLE_VOLUME' CHECK (level_data_type IN ('USABLE_VOLUME', 'TOTAL_VOLUME', 'HEAD', 'ENERGY'))
);

-- loads: generated from PowerLoad, StandardLoad, InterruptiblePowerLoad, InterruptibleStandardLoad, MotorLoad, ExponentialLoad, ShiftablePowerLoad
CREATE TABLE loads (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    balancing_topology INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    active_power REAL NULL, -- Units: MW
    reactive_power REAL NULL, -- Units: MVAr
    base_power REAL NOT NULL, -- Units: MVA
    max_active_power REAL NULL, -- Units: MW
    max_reactive_power REAL NULL, -- Units: MVAr
    conformity TEXT NULL DEFAULT 'UNDEFINED' CHECK (conformity IN ('NON_CONFORMING', 'CONFORMING', 'UNDEFINED')),
    dynamic_injector INTEGER NULL,
    constant_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    constant_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    impedance_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    impedance_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    current_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    current_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    max_constant_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    max_constant_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    max_impedance_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    max_impedance_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    max_current_active_power REAL NULL DEFAULT 0.0, -- Units: MW
    max_current_reactive_power REAL NULL DEFAULT 0.0, -- Units: MVAr
    operation_cost JSON NULL,
    rating REAL NULL, -- Units: MVA
    reactive_power_limits JSON NULL, -- Units: MVAr
    motor_technology TEXT NULL DEFAULT 'UNDETERMINED' CHECK (motor_technology IN ('INDUCTION', 'SYNCHRONOUS', 'UNDETERMINED')),
    alpha REAL NULL,
    beta REAL NULL,
    active_power_limits JSON NULL, -- Units: MW
    load_balance_time_horizon INTEGER NULL
);

-- transmission_lines: generated from Line, MonitoredLine
CREATE TABLE transmission_lines (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    active_power_flow REAL NOT NULL, -- Units: MW
    reactive_power_flow REAL NOT NULL, -- Units: MVAr
    arc_id INTEGER NOT NULL REFERENCES arcs (id) ON DELETE CASCADE,
    r REAL NOT NULL, -- Units: pu
    x REAL NOT NULL, -- Units: pu
    b JSON NULL, -- Units: pu
    continuous_rating REAL NOT NULL, -- Units: MVA
    rating_b REAL NULL, -- Units: MVA
    rating_c REAL NULL, -- Units: MVA
    angle_limits JSON NOT NULL, -- Units: rad
    g JSON NULL DEFAULT '{"from":0.0,"to":0.0}', -- Units: pu
    flow_limits JSON NULL -- Units: MW
);

-- transmission_interchanges: generated from AreaInterchange
CREATE TABLE transmission_interchanges (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    active_power_flow REAL NOT NULL, -- Units: MW
    from_area INTEGER NOT NULL,
    to_area INTEGER NOT NULL,
    flow_limits JSON NOT NULL -- Units: MW
);

-- balancing_topologies: generated from ACBus
CREATE TABLE balancing_topologies (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    number INTEGER NOT NULL,
    name TEXT NOT NULL UNIQUE,
    available BOOLEAN NOT NULL,
    bustype TEXT NULL CHECK (bustype IN ('PQ', 'PV', 'REF', 'ISOLATED', 'SLACK')),
    angle REAL NULL, -- Units: rad
    magnitude REAL NULL, -- Units: pu
    voltage_limits JSON NULL, -- Units: pu
    base_voltage REAL NULL, -- Units: kV
    area INTEGER NULL,
    load_zone INTEGER NULL
);

-- supply_technologies: generated from SupplyTechnology
CREATE TABLE supply_technologies (
    name TEXT NOT NULL UNIQUE,
    power_systems_type TEXT NOT NULL,
    region JSON NULL,
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    available BOOLEAN NOT NULL,
    prime_mover_type TEXT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')) REFERENCES prime_mover_types (name),
    fuel JSON NULL,
    co2 JSON NULL, -- Units: t/MMBtu
    cofire_start_limits JSON NULL, -- Units: 1
    cofire_level_limits JSON NULL, -- Units: 1
    capital_costs JSON NULL, -- Units: USD/MW
    operation_costs JSON NULL, -- Units: USD/MWh
    unit_size REAL NULL DEFAULT '0.0', -- Units: MW
    capacity_limits JSON NULL, -- Units: MW
    outage_factor REAL NULL DEFAULT '1.0', -- Units: 1
    min_generation_fraction REAL NULL DEFAULT '0.0', -- Units: 1
    ramp_limits JSON NULL, -- Units: MW/min
    time_limits JSON NULL, -- Units: h
    start_fuel_mmbtu_per_mw REAL NULL DEFAULT '0.0', -- Units: MMBtu/MW
    lifetime INTEGER NULL DEFAULT '100', -- Units: yr
    financial_data JSON NULL
);

-- storage_technologies: generated from StorageTechnology
CREATE TABLE storage_technologies (
    name TEXT NOT NULL UNIQUE,
    region JSON NULL,
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    available BOOLEAN NOT NULL,
    power_systems_type TEXT NOT NULL,
    min_discharge_fraction REAL NULL DEFAULT '0.0', -- Units: 1
    prime_mover_type TEXT NULL DEFAULT 'OT' CHECK (prime_mover_type IN ('BA', 'BT', 'CA', 'CC', 'CE', 'CP', 'CS', 'CT', 'ES', 'FC', 'FW', 'GT', 'HA', 'HB', 'HK', 'HY', 'IC', 'PS', 'OT', 'ST', 'PVe', 'WT', 'WS')),
    storage_tech TEXT NULL CHECK (storage_tech IN ('PTES', 'LIB', 'LAB', 'FLWB', 'SIB', 'ZIB', 'HGS', 'LAES', 'OTHER_CHEM', 'OTHER_MECH', 'OTHER_THERM')),
    capital_costs_energy JSON NULL, -- Units: USD/MWh
    capital_costs_charge JSON NULL, -- Units: USD/MW
    capital_costs_discharge JSON NULL, -- Units: USD/MW
    operation_costs JSON NULL, -- Units: USD/MWh
    unit_size_discharge REAL NULL DEFAULT '0.0', -- Units: MW
    unit_size_charge REAL NULL DEFAULT '0.0', -- Units: MW
    unit_size_energy REAL NULL DEFAULT '0.0', -- Units: MWh
    capacity_limits_charge JSON NULL, -- Units: MW
    capacity_limits_discharge JSON NULL, -- Units: MW
    capacity_limits_energy JSON NULL, -- Units: MWh
    duration_limits JSON NULL, -- Units: h
    efficiency JSON NULL, -- Units: 1
    losses REAL NULL DEFAULT '1.0', -- Units: 1
    lifetime INTEGER NULL DEFAULT '100', -- Units: yr
    financial_data JSON NULL
);

-- transport_technologies: generated from NodalACTransportTechnology, NodalHVDCTransportTechnology, AggregateTransportTechnology
CREATE TABLE transport_technologies (
    name TEXT NOT NULL UNIQUE,
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    available BOOLEAN NOT NULL,
    power_systems_type TEXT NULL,
    start_node INTEGER NULL,
    end_node INTEGER NULL,
    capacity_limits JSON NULL,
    capital_costs JSON NULL, -- Units: USD/MW
    resistance REAL NULL DEFAULT '0.0', -- Units: pu
    voltage REAL NULL DEFAULT '0.0', -- Units: kV
    unit_size REAL NULL DEFAULT '0.0', -- Units: MW
    reactance REAL NULL DEFAULT '0.0', -- Units: pu
    financial_data JSON NULL,
    line_loss JSON NULL, -- Units: 1
    start_region INTEGER NULL,
    end_region INTEGER NULL
);
