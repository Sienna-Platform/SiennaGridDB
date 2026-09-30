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

-- Each numeric column read from attributes comes with its row's unit, since one
-- name holds pu or MW per component (pu is on the component's base_power).
CREATE VIEW IF NOT EXISTS operational_data AS
SELECT
    e.id AS entity_id,
    e.entity_table,
    e.entity_type,
    json_extract(apl.value, '$.min') AS active_power_limit_min,
    apl.unit AS active_power_limit_unit,
    json_extract(mr.value, '$') AS must_run,
    json_extract(tl.value, '$.up') AS uptime,
    json_extract(tl.value, '$.down') AS downtime,
    tl.unit AS time_limits_unit,
    json_extract(rl.value, '$.up') AS ramp_up,
    json_extract(rl.value, '$.down') AS ramp_down,
    rl.unit AS ramp_limits_unit,
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

-- Who contributes to each service, with the type of both sides.
CREATE VIEW IF NOT EXISTS service_contributors AS
SELECT
    sa.service_id,
    s.entity_type AS service_type,
    sa.entity_id,
    m.entity_type
FROM
    service_associations sa
    JOIN entities s ON s.id = sa.service_id
    JOIN entities m ON m.id = sa.entity_id;

-- Each direction_mapping entry resolved to a member branch: the keys are branch
-- names, matched against the names of the interface's service_associations members.
CREATE VIEW IF NOT EXISTS interface_branch_directions AS
WITH branch_names (id, name) AS (
    SELECT id, name FROM transmission_lines
    UNION ALL
    SELECT id, name FROM discrete_controlled_ac_branches
    UNION ALL
    SELECT id, name FROM two_winding_transformers
    UNION ALL
    SELECT id, name FROM three_winding_transformers
    UNION ALL
    SELECT id, name FROM transmission_interchanges
    UNION ALL
    SELECT id, name FROM two_terminal_hvdc_lines
    UNION ALL
    SELECT id, name FROM tmodel_hvdc_lines
)
SELECT
    ti.id AS interface_id,
    b.id AS branch_id,
    CAST(d.value AS INTEGER) AS direction,
    b.name AS branch_name
FROM
    transmission_interfaces ti
    JOIN json_each(ti.direction_mapping) d
    JOIN service_associations sa ON sa.service_id = ti.id
    JOIN branch_names b ON b.id = sa.entity_id
    AND b.name = d.key;

-- direction_mapping names that resolve to no member branch of their interface;
-- empty for valid data.
CREATE VIEW IF NOT EXISTS interface_direction_violations AS
SELECT
    ti.id AS interface_id,
    d.key AS branch_name
FROM
    transmission_interfaces ti
    JOIN json_each(ti.direction_mapping) d
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            interface_branch_directions ibd
        WHERE
            ibd.interface_id = ti.id
            AND ibd.branch_name = d.key
    );

-- (device, service) pairs a market bid offers into: its cost's
-- ancillary_service_offers ids. Reads every cost column that can hold a bid,
-- plus operation_cost attribute rows for types whose cost has no column.
CREATE VIEW IF NOT EXISTS service_bid_offers AS
WITH costs (device_id, cost) AS (
    SELECT id, operation_cost FROM thermal_generators
    UNION ALL
    SELECT id, operation_cost FROM renewable_generators
    UNION ALL
    SELECT id, operation_cost FROM hydro_generators
    UNION ALL
    SELECT id, operation_cost FROM storage_units
    UNION ALL
    SELECT id, operation_cost FROM sources
    UNION ALL
    SELECT id, operation_cost FROM virtual_participants
    UNION ALL
    SELECT id, spread_bid FROM point_to_point_bids
    UNION ALL
    SELECT entity_id, value FROM attributes WHERE name = 'operation_cost'
)
SELECT DISTINCT
    c.device_id,
    o.value AS service_id
FROM
    costs c
    JOIN json_each(c.cost, '$.ancillary_service_offers') o
WHERE
    o.type <> 'null';

-- The bid series behind each reserve offer. PSY names a device's bid series
-- after the reserve, so they are the device's associations with that name.
CREATE VIEW IF NOT EXISTS service_bids AS
SELECT
    o.device_id,
    o.service_id,
    ts.id AS association_id,
    ts.time_series_type
FROM
    service_bid_offers o
    JOIN reserves r ON r.id = o.service_id
    JOIN time_series_associations ts ON ts.owner_id = o.device_id
    AND ts.owner_category = 'Component'
    AND ts.name = r.name;

-- Offers into a service the device is not a member of; empty for valid data. A
-- view, not a trigger: device rows insert before memberships, so a row
-- trigger would fire too early.
CREATE VIEW IF NOT EXISTS service_offer_violations AS
SELECT
    o.device_id,
    o.service_id
FROM
    service_bid_offers o
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            service_associations sa
        WHERE
            sa.service_id = o.service_id
            AND sa.entity_id = o.device_id
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
        SELECT id, 'reserves', 'variable', variable FROM reserves
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
        -- 'start of month' first: SQLite's '+N months' rolls Jan 31 over into March.
        -- t0_ms, not initial_timestamp: SQLite 3.38 reads '08.001-04:00' as 08.000.
        WHEN a.step_months IS NOT NULL THEN strftime(
            '%Y-%m-', a.t0_ms / 1000.0, 'unixepoch', 'start of month',
            printf('%+d months', v.timestep * a.step_months)
        ) || printf('%02d', min(
            CAST(strftime('%d', a.t0_ms / 1000.0, 'unixepoch') AS INTEGER),
            CAST(strftime('%d', a.t0_ms / 1000.0, 'unixepoch', 'start of month',
                printf('%+d months', v.timestep * a.step_months + 1), '-1 day') AS INTEGER)
        )) || strftime('T%H:%M:%fZ', a.t0_ms / 1000.0, 'unixepoch')
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
