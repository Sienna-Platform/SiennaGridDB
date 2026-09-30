CREATE VIEW IF NOT EXISTS column_units AS
SELECT
    uc.table_name,
    uc.column_name,
    uc.unit,
    uc.quantity_kind,
    qt.dimension,
    uc.discriminator_column,
    uc.discriminator_value,
    uc.description,
    uc.base_power_ref,
    uc.base_voltage_ref,
    ubr.base_expression
FROM
    unit_conventions uc
    JOIN quantity_kinds qt ON uc.quantity_kind = qt.name
    LEFT JOIN unit_basis_rules ubr ON uc.quantity_kind = ubr.quantity_kind
ORDER BY
    uc.table_name,
    uc.column_name;

CREATE VIEW IF NOT EXISTS operational_data AS
SELECT
    e.id AS entity_id,
    e.entity_table,
    e.entity_type,
    json_extract(apl.value, '$.min') AS active_power_limit_min,
    json_extract(mr.value, '$') AS must_run,
    json_extract(tl.value, '$.up') AS uptime,
    json_extract(tl.value, '$.down') AS downtime,
    json_extract(rl.value, '$.up') AS ramp_up,
    json_extract(rl.value, '$.down') AS ramp_down,
    oc.value AS operational_cost,
    json_type(oc.value) AS operational_cost_type
FROM
    entities e
    LEFT JOIN attributes apl ON e.id = apl.entity_id
    AND apl.name = 'active_power_limits'
    LEFT JOIN attributes mr ON e.id = mr.entity_id
    AND mr.name = 'must_run'
    LEFT JOIN attributes tl ON e.id = tl.entity_id
    AND tl.name = 'time_limits'
    LEFT JOIN attributes rl ON e.id = rl.entity_id
    AND rl.name = 'ramp_limits'
    LEFT JOIN attributes oc ON e.id = oc.entity_id
    AND oc.name = 'operation_cost'
WHERE
    -- Only include entities that have at least one operational attribute
    (
        apl.entity_id IS NOT NULL
        OR mr.entity_id IS NOT NULL
        OR tl.entity_id IS NOT NULL
        OR rl.entity_id IS NOT NULL
        OR oc.entity_id IS NOT NULL
    );

-- Every time series reference in a stored payload (association_id,
-- *_association_id, fuel_cost_time_series) no association resolves; empty after
-- a complete insert. test_dangling_view_covers_every_reference_column checks it.
CREATE VIEW IF NOT EXISTS dangling_time_series_references AS
WITH
    payloads (entity_id, source_table, source_column, payload) AS (
        SELECT entity_id, 'attributes', name, value FROM attributes
        UNION ALL
        SELECT id, 'hydro_generators', 'operation_cost', operation_cost FROM hydro_generators
        UNION ALL
        SELECT id, 'hydro_reservoirs', 'head_to_volume_factor', head_to_volume_factor
        FROM hydro_reservoirs
        UNION ALL
        SELECT id, 'hydro_reservoirs', 'operation_cost', operation_cost FROM hydro_reservoirs
        UNION ALL
        SELECT id, 'plants', 'value', value FROM plants
        UNION ALL
        SELECT id, 'point_to_point_bids', 'spread_bid', spread_bid FROM point_to_point_bids
        UNION ALL
        SELECT id, 'renewable_generators', 'operation_cost', operation_cost
        FROM renewable_generators
        UNION ALL
        SELECT id, 'sources', 'operation_cost', operation_cost FROM sources
        UNION ALL
        SELECT id, 'storage_technologies', 'operation_costs', operation_costs
        FROM storage_technologies
        UNION ALL
        SELECT id, 'storage_units', 'operation_cost', operation_cost FROM storage_units
        UNION ALL
        SELECT id, 'supplemental_attributes', 'value', value FROM supplemental_attributes
        UNION ALL
        SELECT id, 'supply_technologies', 'capital_costs', capital_costs FROM supply_technologies
        UNION ALL
        SELECT id, 'supply_technologies', 'operation_costs', operation_costs
        FROM supply_technologies
        UNION ALL
        SELECT id, 'thermal_generators', 'operation_cost', operation_cost FROM thermal_generators
        UNION ALL
        SELECT id, 'transport_technologies', 'capital_costs', capital_costs
        FROM transport_technologies
        UNION ALL
        SELECT id, 'virtual_participants', 'operation_cost', operation_cost
        FROM virtual_participants
    )
SELECT
    p.entity_id,
    p.source_table,
    p.source_column,
    t.fullkey AS path,
    t.value AS association_id
FROM
    payloads p,
    json_tree(p.payload) t
WHERE
    json_valid(p.payload)
    AND t.type = 'integer'
    -- A bare integer payload has no key: its column (or attribute) names it.
    AND (
        coalesce(t.key, p.source_column) IN ('association_id', 'fuel_cost_time_series')
        OR coalesce(t.key, p.source_column) GLOB '*_association_id'
    )
    AND NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations a
        WHERE
            a.id = t.value
    );

-- Values no association names, and associations whose uri has no values: what
-- the orphan cleanup triggers cannot see (INSERT OR REPLACE, a one-statement uri
-- swap). Empty after an SDK insert.
CREATE VIEW IF NOT EXISTS orphaned_time_series AS
SELECT
    'values without association' AS problem,
    v.uri,
    NULL AS association_id
FROM
    (SELECT DISTINCT uri FROM static_time_series) v
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations a
        WHERE
            a.uri = v.uri
    )
UNION ALL
SELECT
    'association without values',
    a.uri,
    a.id
FROM
    time_series_associations a
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            static_time_series v
        WHERE
            v.uri = a.uri
    );

-- Every stored SingleTimeSeries value with its UTC timestamp, 'YYYY-MM-DDTHH:MM:SS.sssZ':
-- step k is initial_timestamp + k * resolution as in infrastore (Period::add_to), a calendar
-- step keeping the day, clamped to the month's end (2024-01-31 + 1 month = 2024-02-29).
CREATE VIEW IF NOT EXISTS time_series_values AS
SELECT
    a.id AS association_id,
    a.owner_id,
    a.owner_type,
    a.owner_category,
    a.name,
    a.time_series_type,
    CASE
        WHEN a.step_ms IS NOT NULL THEN strftime(
            '%Y-%m-%dT%H:%M:%fZ', (a.t0_ms + v.timestep * a.step_ms) / 1000.0, 'unixepoch'
        )
        -- 'start of month' first: SQLite's '+N months' rolls Jan 31 over into March
        ELSE strftime(
            '%Y-%m-', a.initial_timestamp, 'start of month',
            printf('%+d months', v.timestep * a.step_months)
        ) || printf('%02d', min(
            CAST(strftime('%d', a.initial_timestamp) AS INTEGER),
            CAST(strftime('%d', a.initial_timestamp, 'start of month',
                printf('%+d months', v.timestep * a.step_months + 1), '-1 day') AS INTEGER)
        )) || strftime('T%H:%M:%fZ', a.initial_timestamp)
    END AS timestamp,
    v.timestep,
    v.element,
    v.value,
    a.units
FROM
    time_series_associations a
    -- The value layout: only this source would change if values were stored another way.
    -- CROSS JOIN keeps associations outermost, so each one's steps are read once.
    CROSS JOIN static_time_series v ON v.uri = a.uri
WHERE
    -- Forecasts are left out: a forecast value also has an issue time, and overlapping
    -- DeterministicSingleTimeSeries windows would make one stored value several rows.
    a.time_series_type = 'SingleTimeSeries';
