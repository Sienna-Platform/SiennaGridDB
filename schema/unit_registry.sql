-- Unit Registry Seed Data
-- Populates the 4 registry tables with unit metadata for all physical columns.
-- Must be run AFTER schema.sql and triggers.sql, BEFORE views.sql.
-- The checksum INSERT at the end seals the registry (activates INSERT triggers).

-- 1. System metadata
INSERT INTO system_metadata VALUES
    ('convention',        'sienna-griddb-1.0',          'Schema unit convention version'),
    ('unit_system',       'https://units-of-measurement.org',  'UCUM as unit coding system');

-- 2. Quantity types (CIM Domain classes with single UCUM codes)
INSERT INTO quantity_types (name, default_unit, dimension, description) VALUES
    ('ActivePower',            'MW',           'power',        'Active power'),
    ('ReactivePower',          'MVAr',         'power',        'Reactive power'),
    ('ApparentPower',          'MVA',          'power',        'Apparent power'),
    ('ActivePowerChangeRate',  'MW/min',       'power_rate',   'Rate of change of active power'),
    ('RealEnergy',             'MWh',          'energy',       'Real energy'),
    ('Voltage',                'kV',           'voltage',      'Voltage'),
    ('CurrentFlow',            'kA',           'current',      'Current flow'),
    ('Resistance',             'ohm',          'impedance',    'Resistance'),
    ('Reactance',              'ohm',          'impedance',    'Reactance'),
    ('Impedance',              'ohm',          'impedance',    'Impedance'),
    ('Conductance',            'S',            'admittance',   'Conductance'),
    ('Susceptance',            'S',            'admittance',   'Susceptance'),
    ('AngleDegrees',           'deg',          'angle',        'Angle in degrees'),
    ('AngleRadians',           'rad',          'angle',        'Angle in radians'),
    ('Frequency',              'Hz',           'frequency',    'Frequency'),
    ('Length',                 'km',           'length',       'Length'),
    ('Elevation',              'm',            'length',       'Elevation'),
    ('Duration',               'h',            'time',         'Duration in hours'),
    ('DurationSeconds',        's',            'time',         'Duration in seconds'),
    ('PerUnit',                'pu',           'dimensionless','Per-unit quantity'),
    ('Dimensionless',          '1',            'dimensionless','Dimensionless quantity'),
    ('PowerFactor',            '1',            'dimensionless','Power factor'),
    ('HeatRate',               '[Btu_th]/MWh', 'heat_rate',   'Heat rate'),
    ('VolumeFlowRate',         'm3/s',         'volume_flow',  'Volume flow rate'),
    ('Volume',                 'm3',           'volume',       'Volume'),
    ('Inductance',             'H',            'inductance',   'Inductance'),
    ('Capacitance',            'F',            'capacitance',  'Capacitance'),
    ('CostPerEnergyUnit',      'USD/MWh',      'cost_rate',    'Cost per unit of energy'),
    ('Money',                  'USD',          'currency',     'Monetary value'),
    ('Temperature',            'degC',         'temperature',  'Temperature');

-- 3. Unit conventions — entity table columns

-- transmission_lines
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('transmission_lines', 'continuous_rating', 'ApparentPower',        'MVA',    'fixed', 'Continuous thermal rating'),
    ('transmission_lines', 'ste_rating',        'ApparentPower',        'MVA',    'fixed', 'Short-term emergency rating'),
    ('transmission_lines', 'lte_rating',        'ApparentPower',        'MVA',    'fixed', 'Long-term emergency rating'),
    ('transmission_lines', 'line_length',       'Length',               'km',     'fixed', 'Line length');

-- transmission_interchanges
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('transmission_interchanges', 'max_flow_from', 'ActivePower', 'MW', 'fixed', 'Maximum flow from'),
    ('transmission_interchanges', 'max_flow_to',   'ActivePower', 'MW', 'fixed', 'Maximum flow to');

-- thermal_generators
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('thermal_generators', 'rating',                'ApparentPower',        'MVA',    'fixed', 'Nameplate rating'),
    ('thermal_generators', 'base_power',            'ActivePower',          'MW',     'fixed', 'Per-unit base for this device'),
    ('thermal_generators', 'active_power',          'ActivePower',          'MW',     'fixed', 'Initial active power setpoint'),
    ('thermal_generators', 'reactive_power',        'ReactivePower',        'MVAr',   'fixed', 'Initial reactive power setpoint'),
    ('thermal_generators', 'active_power_limits',   'ActivePower',          'MW',     'fixed', 'JSON {min, max}'),
    ('thermal_generators', 'reactive_power_limits', 'ReactivePower',        'MVAr',   'fixed', 'JSON {min, max}'),
    ('thermal_generators', 'ramp_limits',           'ActivePowerChangeRate','MW/min', 'fixed', 'JSON {up, down}'),
    ('thermal_generators', 'time_limits',           'Duration',             'h',      'fixed', 'JSON {up, down}');

-- renewable_generators
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('renewable_generators', 'rating',                'ApparentPower', 'MVA',  'fixed', 'Nameplate rating'),
    ('renewable_generators', 'base_power',            'ActivePower',   'MW',   'fixed', 'Per-unit base for this device'),
    ('renewable_generators', 'power_factor',          'PowerFactor',   '1',    'fixed', 'Power factor'),
    ('renewable_generators', 'active_power',          'ActivePower',   'MW',   'fixed', 'Initial active power setpoint'),
    ('renewable_generators', 'reactive_power',        'ReactivePower', 'MVAr', 'fixed', 'Initial reactive power setpoint'),
    ('renewable_generators', 'reactive_power_limits', 'ReactivePower', 'MVAr', 'fixed', 'JSON {min, max}');

-- hydro_generators
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('hydro_generators', 'rating',                'ApparentPower',        'MVA',    'fixed', 'Nameplate rating'),
    ('hydro_generators', 'base_power',            'ActivePower',          'MW',     'fixed', 'Per-unit base for this device'),
    ('hydro_generators', 'active_power',          'ActivePower',          'MW',     'fixed', 'Initial active power setpoint'),
    ('hydro_generators', 'reactive_power',        'ReactivePower',        'MVAr',   'fixed', 'Initial reactive power setpoint'),
    ('hydro_generators', 'active_power_limits',   'ActivePower',          'MW',     'fixed', 'JSON {min, max}'),
    ('hydro_generators', 'reactive_power_limits', 'ReactivePower',        'MVAr',   'fixed', 'JSON {min, max}'),
    ('hydro_generators', 'ramp_limits',           'ActivePowerChangeRate','MW/min', 'fixed', 'JSON {up, down}'),
    ('hydro_generators', 'time_limits',           'Duration',             'h',      'fixed', 'JSON {up, down}'),
    ('hydro_generators', 'powerhouse_elevation',  'Elevation',            'm',      'fixed', 'Powerhouse elevation'),
    ('hydro_generators', 'outflow_limits',        'VolumeFlowRate',       'm3/s',   'fixed', 'JSON {min, max}'),
    ('hydro_generators', 'conversion_factor',     'Dimensionless',        '1',      'fixed', 'Conversion factor'),
    ('hydro_generators', 'travel_time',           'Duration',             'h',      'fixed', 'Water travel time');

-- storage_units
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('storage_units', 'rating',                        'ApparentPower', 'MVA',  'fixed', 'Nameplate rating'),
    ('storage_units', 'base_power',                    'ActivePower',   'MW',   'fixed', 'Per-unit base for this device'),
    ('storage_units', 'storage_capacity',              'RealEnergy',    'MWh',  'fixed', 'Total storage capacity'),
    ('storage_units', 'storage_level_limits',          'RealEnergy',    'MWh',  'fixed', 'JSON {min, max}'),
    ('storage_units', 'initial_storage_capacity_level','RealEnergy',    'MWh',  'fixed', 'Initial storage level'),
    ('storage_units', 'input_active_power_limits',     'ActivePower',   'MW',   'fixed', 'JSON {min, max} charging'),
    ('storage_units', 'output_active_power_limits',    'ActivePower',   'MW',   'fixed', 'JSON {min, max} discharging'),
    ('storage_units', 'efficiency',                    'Dimensionless', '1',    'fixed', 'JSON {in, out}'),
    ('storage_units', 'reactive_power_limits',         'ReactivePower', 'MVAr', 'fixed', 'JSON {min, max}'),
    ('storage_units', 'active_power',                  'ActivePower',   'MW',   'fixed', 'Initial active power setpoint'),
    ('storage_units', 'reactive_power',                'ReactivePower', 'MVAr', 'fixed', 'Initial reactive power setpoint'),
    ('storage_units', 'conversion_factor',             'Dimensionless', '1',    'fixed', 'Conversion factor'),
    ('storage_units', 'storage_target',                'RealEnergy',    'MWh',  'fixed', 'Storage target level');

-- hydro_reservoirs
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('hydro_reservoirs', 'storage_level_limits', 'Volume',         'm3',   'fixed', 'JSON {min, max}'),
    ('hydro_reservoirs', 'initial_level',        'Volume',         'm3',   'fixed', 'Initial reservoir level'),
    ('hydro_reservoirs', 'spillage_limits',      'VolumeFlowRate', 'm3/s', 'fixed', 'JSON {min, max}'),
    ('hydro_reservoirs', 'inflow',               'VolumeFlowRate', 'm3/s', 'fixed', 'Inflow rate'),
    ('hydro_reservoirs', 'outflow',              'VolumeFlowRate', 'm3/s', 'fixed', 'Outflow rate'),
    ('hydro_reservoirs', 'intake_elevation',     'Elevation',      'm',    'fixed', 'Intake elevation');

-- loads
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('loads', 'base_power', 'ActivePower', 'MW', 'fixed', 'Base power');

-- Well-known attribute names (registry-linked validation)
INSERT INTO unit_conventions (table_name, column_name, quantity_type, unit, unit_policy, description) VALUES
    ('attributes', 'active_power_limits',      'ActivePower',          'MW',     'fixed', 'Active power limits stored as attribute'),
    ('attributes', 'time_limits',              'Duration',             'h',      'fixed', 'Time limits stored as attribute'),
    ('attributes', 'ramp_limits',              'ActivePowerChangeRate','MW/min', 'fixed', 'Ramp limits stored as attribute'),
    ('attributes', 'efficiency',               'Dimensionless',        '1',      'fixed', 'Efficiency stored as attribute'),
    ('attributes', 'active_power_limits_pump', 'ActivePower',          'MW',     'fixed', 'HydroPumpTurbine pump limits stored as attribute');

-- 4. Seal the registry — compute and store checksum
-- Once this row exists, INSERT triggers on registry tables activate.
INSERT INTO system_metadata (key, value, description) VALUES (
    'unit_conventions_checksum',
    (SELECT group_concat(
        table_name || '.' || column_name || ':' ||
        quantity_type || ':' || unit || ':' || unit_policy,
        ';'
    ) FROM unit_conventions ORDER BY table_name, column_name),
    'Registry content fingerprint — recompute to verify integrity'
);
