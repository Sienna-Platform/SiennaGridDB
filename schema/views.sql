CREATE VIEW IF NOT EXISTS column_units AS
SELECT
    uc.table_name,
    uc.column_name,
    uc.unit,
    uc.companion_column,
    uc.quantity_type,
    qt.dimension,
    uc.is_per_unit,
    uc.per_unit_base_column,
    uc.description
FROM
    unit_conventions uc
    JOIN quantity_types qt ON uc.quantity_type = qt.name
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
