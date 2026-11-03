-- Views over infrastore's SQLite export of the time series values. Not part of
-- new-db: they read the ts_all_* views the export creates, so the SDKs run these
-- statements (insert_manifest.json time_series.views_sql) after they copy an export in.
-- A view over a table that does not exist makes ALTER TABLE ... RENAME COLUMN fail.

-- Time series values, from infrastore's SQLite export under the ts_ prefix. ts_all_series.id
-- is the association id. The timestamps are spelled in UTC; a 'zoneless' time_reference
-- means wall-clock time. A forecast value also has its issue_time.
CREATE VIEW IF NOT EXISTS time_series_values AS
SELECT
    a.id AS association_id,
    a.owner_id,
    a.owner_type,
    a.owner_category,
    a.name,
    a.time_series_type,
    strftime('%Y-%m-%dT%H:%M:%fZ', v.timestamp / 1000.0, 'unixepoch') AS timestamp,
    strftime('%Y-%m-%dT%H:%M:%fZ', v.issue_time / 1000.0, 'unixepoch') AS issue_time,
    v.percentile,
    v.scenario,
    v.value,
    a.units,
    s.time_reference
FROM
    time_series_associations a
    JOIN ts_all_series s ON s.id = a.id
    JOIN ts_all_values v ON v.partition_name = s.partition_name
    AND v.array_id = s.array_id;

-- Exported series no association names any more (an owner was deleted, say): their
-- values are left behind, since the export's tables have no foreign key into GridDB.
CREATE VIEW IF NOT EXISTS orphaned_time_series AS
SELECT
    s.partition_name,
    s.id AS association_id,
    s.owner_id,
    s.name
FROM
    ts_all_series s
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations a
        WHERE
            a.id = s.id
    );
