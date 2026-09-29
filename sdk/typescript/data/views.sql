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
