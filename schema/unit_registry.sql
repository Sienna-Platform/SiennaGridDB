-- Unit Registry Seed Data
-- Populates the 3 registry tables with unit metadata for all physical columns.
-- Must be run AFTER schema.sql and triggers.sql, BEFORE views.sql.
-- The checksum INSERT at the end seals the registry (activates INSERT triggers).
-- 1. System metadata
INSERT INTO
    system_metadata
VALUES
    (
        'convention',
        'sienna-griddb-1.0',
        'Schema unit convention version'
    ),
    (
        'unit_system',
        'https://units-of-measurement.org',
        'UCUM as unit coding system'
    );

-- 2. Quantity types (CIM Domain classes with single UCUM codes)
INSERT INTO
    quantity_types (name, default_unit, dimension, description)
VALUES
    (
        'ActivePower',
        'MW',
        'power',
        'Active power'
    ),
    (
        'ReactivePower',
        'MVAr',
        'power',
        'Reactive power'
    ),
    (
        'ApparentPower',
        'MVA',
        'power',
        'Apparent power'
    ),
    (
        'ActivePowerChangeRate',
        'MW/min',
        'power_rate',
        'Rate of change of active power'
    ),
    (
        'RealEnergy',
        'MWh',
        'energy',
        'Real energy'
    ),
    (
        'Voltage',
        'kV',
        'voltage',
        'Voltage'
    ),
    (
        'CurrentFlow',
        'kA',
        'current',
        'Current flow'
    ),
    (
        'Resistance',
        'ohm',
        'impedance',
        'Resistance'
    ),
    (
        'Reactance',
        'ohm',
        'impedance',
        'Reactance'
    ),
    (
        'Impedance',
        'ohm',
        'impedance',
        'Impedance'
    ),
    (
        'Conductance',
        'S',
        'admittance',
        'Conductance'
    ),
    (
        'Susceptance',
        'S',
        'admittance',
        'Susceptance'
    ),
    (
        'AngleDegrees',
        'deg',
        'angle',
        'Angle in degrees'
    ),
    (
        'AngleRadians',
        'rad',
        'angle',
        'Angle in radians'
    ),
    (
        'Frequency',
        'Hz',
        'frequency',
        'Frequency'
    ),
    (
        'Length',
        'km',
        'length',
        'Length'
    ),
    (
        'Elevation',
        'm',
        'length',
        'Elevation'
    ),
    (
        'Duration',
        'h',
        'time',
        'Duration in hours'
    ),
    (
        'DurationSeconds',
        's',
        'time',
        'Duration in seconds'
    ),
    (
        'PerUnit',
        'pu',
        'dimensionless',
        'Per-unit quantity'
    ),
    (
        'Dimensionless',
        '1',
        'dimensionless',
        'Dimensionless quantity'
    ),
    (
        'Fraction',
        '1',
        'dimensionless',
        'Fractional quantity (efficiency, losses, etc.)'
    ),
    (
        'PowerFactor',
        '1',
        'dimensionless',
        'Power factor'
    ),
    (
        'HeatRate',
        'MMBtu/MWh',
        'heat_rate',
        'Heat rate'
    ),
    (
        'VolumeFlowRate',
        'm3/s',
        'volume_flow',
        'Volume flow rate'
    ),
    (
        'Volume',
        'm3',
        'volume',
        'Volume'
    ),
    (
        'Inductance',
        'H',
        'inductance',
        'Inductance'
    ),
    (
        'Capacitance',
        'F',
        'capacitance',
        'Capacitance'
    ),
    (
        'CostPerEnergyUnit',
        'USD/MWh',
        'cost_rate',
        'Cost per unit of energy'
    ),
    (
        'CapitalCost',
        'USD/MW',
        'cost_rate',
        'Capital cost per unit of capacity'
    ),
    (
        'OperationCost',
        'USD/MWh',
        'cost_rate',
        'Operational cost per unit of energy'
    ),
    (
        'CO2Emissions',
        't/MMBtu',
        'emissions',
        'CO2 emission rate'
    ),
    (
        'Money',
        'USD',
        'currency',
        'Monetary value'
    ),
    (
        'Temperature',
        'degC',
        'temperature',
        'Temperature'
    );

-- 3. Unit conventions — entity table columns
-- transmission_lines
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'transmission_lines',
        'continuous_rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Continuous thermal rating'
    ),
    (
        'transmission_lines',
        'ste_rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Short-term emergency rating'
    ),
    (
        'transmission_lines',
        'lte_rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Long-term emergency rating'
    ),
    (
        'transmission_lines',
        'line_length',
        'Length',
        'km',
        0,
        NULL,
        'Line length'
    );

-- transmission_interchanges
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'transmission_interchanges',
        'max_flow_from',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Maximum flow from'
    ),
    (
        'transmission_interchanges',
        'max_flow_to',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Maximum flow to'
    );

-- thermal_generators
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'thermal_generators',
        'rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Nameplate rating'
    ),
    (
        'thermal_generators',
        'base_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Per-unit base for this device'
    ),
    (
        'thermal_generators',
        'active_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Initial active power setpoint'
    ),
    (
        'thermal_generators',
        'reactive_power',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'Initial reactive power setpoint'
    ),
    (
        'thermal_generators',
        'active_power_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'thermal_generators',
        'reactive_power_limits',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'thermal_generators',
        'ramp_limits',
        'ActivePowerChangeRate',
        'MW/min',
        0,
        NULL,
        'JSON {up, down}'
    ),
    (
        'thermal_generators',
        'time_limits',
        'Duration',
        'h',
        0,
        NULL,
        'JSON {up, down}'
    ),
    (
        'thermal_generators',
        'operation_cost',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- renewable_generators
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'renewable_generators',
        'rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Nameplate rating'
    ),
    (
        'renewable_generators',
        'base_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Per-unit base for this device'
    ),
    (
        'renewable_generators',
        'power_factor',
        'PowerFactor',
        '1',
        0,
        NULL,
        'Power factor'
    ),
    (
        'renewable_generators',
        'active_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Initial active power setpoint'
    ),
    (
        'renewable_generators',
        'reactive_power',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'Initial reactive power setpoint'
    ),
    (
        'renewable_generators',
        'reactive_power_limits',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'renewable_generators',
        'operation_cost',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- hydro_generators
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'hydro_generators',
        'rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Nameplate rating'
    ),
    (
        'hydro_generators',
        'base_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Per-unit base for this device'
    ),
    (
        'hydro_generators',
        'active_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Initial active power setpoint'
    ),
    (
        'hydro_generators',
        'reactive_power',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'Initial reactive power setpoint'
    ),
    (
        'hydro_generators',
        'active_power_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'hydro_generators',
        'reactive_power_limits',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'hydro_generators',
        'ramp_limits',
        'ActivePowerChangeRate',
        'MW/min',
        0,
        NULL,
        'JSON {up, down}'
    ),
    (
        'hydro_generators',
        'time_limits',
        'Duration',
        'h',
        0,
        NULL,
        'JSON {up, down}'
    ),
    (
        'hydro_generators',
        'powerhouse_elevation',
        'Elevation',
        'm',
        0,
        NULL,
        'Powerhouse elevation'
    ),
    (
        'hydro_generators',
        'outflow_limits',
        'VolumeFlowRate',
        'm3/s',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'hydro_generators',
        'conversion_factor',
        'Dimensionless',
        '1',
        0,
        NULL,
        'Conversion factor'
    ),
    (
        'hydro_generators',
        'travel_time',
        'Duration',
        'h',
        0,
        NULL,
        'Water travel time'
    ),
    (
        'hydro_generators',
        'operation_cost',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- storage_units
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'storage_units',
        'rating',
        'ApparentPower',
        'MVA',
        0,
        NULL,
        'Nameplate rating'
    ),
    (
        'storage_units',
        'base_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Per-unit base for this device'
    ),
    (
        'storage_units',
        'storage_capacity',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'Total storage capacity'
    ),
    (
        'storage_units',
        'storage_level_limits',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'storage_units',
        'initial_storage_capacity_level',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'Initial storage level'
    ),
    (
        'storage_units',
        'input_active_power_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max} charging'
    ),
    (
        'storage_units',
        'output_active_power_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max} discharging'
    ),
    (
        'storage_units',
        'efficiency',
        'Dimensionless',
        '1',
        0,
        NULL,
        'JSON {in, out}'
    ),
    (
        'storage_units',
        'reactive_power_limits',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'storage_units',
        'active_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Initial active power setpoint'
    ),
    (
        'storage_units',
        'reactive_power',
        'ReactivePower',
        'MVAr',
        0,
        NULL,
        'Initial reactive power setpoint'
    ),
    (
        'storage_units',
        'conversion_factor',
        'Dimensionless',
        '1',
        0,
        NULL,
        'Conversion factor'
    ),
    (
        'storage_units',
        'storage_target',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'Storage target level'
    ),
    (
        'storage_units',
        'operation_cost',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- hydro_reservoirs
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'hydro_reservoirs',
        'storage_level_limits',
        'Volume',
        'm3',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'hydro_reservoirs',
        'initial_level',
        'Volume',
        'm3',
        0,
        NULL,
        'Initial reservoir level'
    ),
    (
        'hydro_reservoirs',
        'spillage_limits',
        'VolumeFlowRate',
        'm3/s',
        0,
        NULL,
        'JSON {min, max}'
    ),
    (
        'hydro_reservoirs',
        'inflow',
        'VolumeFlowRate',
        'm3/s',
        0,
        NULL,
        'Inflow rate'
    ),
    (
        'hydro_reservoirs',
        'outflow',
        'VolumeFlowRate',
        'm3/s',
        0,
        NULL,
        'Outflow rate'
    ),
    (
        'hydro_reservoirs',
        'intake_elevation',
        'Elevation',
        'm',
        0,
        NULL,
        'Intake elevation'
    ),
    (
        'hydro_reservoirs',
        'level_targets',
        'Volume',
        'm3',
        0,
        NULL,
        'Reservoir level targets'
    ),
    (
        'hydro_reservoirs',
        'head_to_volume_factor',
        'Dimensionless',
        '1',
        0,
        NULL,
        'Head to volume conversion factor'
    ),
    (
        'hydro_reservoirs',
        'operation_cost',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- loads
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'loads',
        'base_power',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Base power'
    );

-- supply_technologies
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'supply_technologies',
        'lifetime',
        'Duration',
        'yr',
        0,
        NULL,
        'Technology lifetime'
    ),
    (
        'supply_technologies',
        'unit_size',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Unit nameplate capacity'
    ),
    (
        'supply_technologies',
        'capacity_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max} capacity limits'
    ),
    (
        'supply_technologies',
        'start_fuel_mmbtu_per_mwh',
        'HeatRate',
        'MMBtu/MWh',
        0,
        NULL,
        'Start-up fuel heat rate'
    ),
    (
        'supply_technologies',
        'cofire_level_limits',
        'Fraction',
        '1',
        0,
        NULL,
        'JSON fuel cofire level limits'
    ),
    (
        'supply_technologies',
        'cofire_start_limits',
        'Fraction',
        '1',
        0,
        NULL,
        'JSON fuel cofire start limits'
    ),
    (
        'supply_technologies',
        'co2',
        'CO2Emissions',
        't/MMBtu',
        0,
        NULL,
        'JSON CO2 emission rates per fuel'
    ),
    (
        'supply_technologies',
        'ramp_limits',
        'ActivePowerChangeRate',
        'MW/min',
        0,
        NULL,
        'JSON {up, down} ramp limits'
    ),
    (
        'supply_technologies',
        'time_limits',
        'Duration',
        'h',
        0,
        NULL,
        'JSON {up, down} time limits'
    ),
    (
        'supply_technologies',
        'outage_factor',
        'Fraction',
        '1',
        0,
        NULL,
        'Outage factor'
    ),
    (
        'supply_technologies',
        'min_generation_fraction',
        'Fraction',
        '1',
        0,
        NULL,
        'Minimum generation fraction'
    ),
    (
        'supply_technologies',
        'capital_costs',
        'CapitalCost',
        'USD/MW',
        0,
        NULL,
        'Capital cost structure'
    ),
    (
        'supply_technologies',
        'operation_costs',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- storage_technologies
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'storage_technologies',
        'lifetime',
        'Duration',
        'yr',
        0,
        NULL,
        'Technology lifetime'
    ),
    (
        'storage_technologies',
        'unit_size_charge',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Charging unit size'
    ),
    (
        'storage_technologies',
        'unit_size_discharge',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Discharging unit size'
    ),
    (
        'storage_technologies',
        'unit_size_energy',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'Energy storage unit size'
    ),
    (
        'storage_technologies',
        'capacity_limits_charge',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max} charge capacity limits'
    ),
    (
        'storage_technologies',
        'capacity_limits_discharge',
        'ActivePower',
        'MW',
        0,
        NULL,
        'JSON {min, max} discharge capacity limits'
    ),
    (
        'storage_technologies',
        'capacity_limits_energy',
        'RealEnergy',
        'MWh',
        0,
        NULL,
        'JSON {min, max} energy capacity limits'
    ),
    (
        'storage_technologies',
        'duration_limits',
        'Duration',
        'h',
        0,
        NULL,
        'JSON {min, max} duration limits'
    ),
    (
        'storage_technologies',
        'efficiency',
        'Fraction',
        '1',
        0,
        NULL,
        'JSON {in, out} efficiency'
    ),
    (
        'storage_technologies',
        'min_discharge_fraction',
        'Fraction',
        '1',
        0,
        NULL,
        'Minimum discharge fraction'
    ),
    (
        'storage_technologies',
        'losses',
        'Fraction',
        '1',
        0,
        NULL,
        'Storage losses'
    ),
    (
        'storage_technologies',
        'capital_costs_charge',
        'CapitalCost',
        'USD/MW',
        0,
        NULL,
        'Charging capital cost structure'
    ),
    (
        'storage_technologies',
        'capital_costs_discharge',
        'CapitalCost',
        'USD/MW',
        0,
        NULL,
        'Discharging capital cost structure'
    ),
    (
        'storage_technologies',
        'capital_costs_energy',
        'CapitalCost',
        'USD/MWh',
        0,
        NULL,
        'Energy capital cost structure'
    ),
    (
        'storage_technologies',
        'operation_costs',
        'OperationCost',
        'USD/MWh',
        0,
        NULL,
        'Operation cost structure'
    );

-- transport_technologies
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'transport_technologies',
        'unit_size',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Unit nameplate capacity'
    ),
    (
        'transport_technologies',
        'capital_costs',
        'CapitalCost',
        'USD/MW',
        0,
        NULL,
        'Capital cost structure'
    );

-- Well-known attribute names (registry-linked validation)
INSERT INTO
    unit_conventions (
        table_name,
        column_name,
        quantity_type,
        unit,
        is_per_unit,
        per_unit_base_column,
        description
    )
VALUES
    (
        'attributes',
        'active_power_limits',
        'ActivePower',
        'MW',
        0,
        NULL,
        'Active power limits stored as attribute'
    ),
    (
        'attributes',
        'time_limits',
        'Duration',
        'h',
        0,
        NULL,
        'Time limits stored as attribute'
    ),
    (
        'attributes',
        'ramp_limits',
        'ActivePowerChangeRate',
        'MW/min',
        0,
        NULL,
        'Ramp limits stored as attribute'
    ),
    (
        'attributes',
        'efficiency',
        'Dimensionless',
        '1',
        0,
        NULL,
        'Efficiency stored as attribute'
    ),
    (
        'attributes',
        'active_power_limits_pump',
        'ActivePower',
        'MW',
        0,
        NULL,
        'HydroPumpTurbine pump limits stored as attribute'
    );

-- 4. Seal the registry — compute and store checksum
-- Once this row exists, INSERT triggers on registry tables activate.
INSERT INTO
    system_metadata (KEY, value, description)
VALUES
    (
        'unit_conventions_checksum',
        (
            SELECT
                GROUP_CONCAT(convention_repr, ';')
            FROM
                (
                    SELECT
                        table_name || '.' || column_name || ':' || quantity_type || ':' || unit AS convention_repr
                    FROM
                        unit_conventions
                    ORDER BY
                        table_name,
                        column_name
                )
        ),
        'Registry content fingerprint — recompute to verify integrity'
    );
