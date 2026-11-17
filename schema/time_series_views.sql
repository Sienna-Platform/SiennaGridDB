-- Views over infrastore's SQLite exports of the time series values, one export per
-- store under its time_series_stores.values_prefix. Not part of new-db: they read
-- time_series_export_series and time_series_export_values, the views uniting every
-- store's export, which the SDKs rebuild after each export (insert_manifest.json
-- time_series.export_views) before they run these statements.
-- A view over a table that does not exist makes ALTER TABLE ... RENAME COLUMN fail.

-- Time series values, found by association id alone: an export's series id is the
-- association id. The timestamps are spelled in UTC; a 'zoneless' time_reference
-- means wall-clock time. A forecast value also has its issue_time.
CREATE VIEW IF NOT EXISTS time_series_values AS
SELECT
    a.id AS association_id,
    a.store_id,
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
    JOIN time_series_export_series s ON s.id = a.id
    JOIN time_series_export_values v ON v.store_id = s.store_id
    AND v.partition_name = s.partition_name
    AND v.array_id = s.array_id;

-- Exported series no association names any more (an owner was deleted, say): their
-- values are left behind, since the export's tables have no foreign key into GridDB.
CREATE VIEW IF NOT EXISTS orphaned_time_series AS
SELECT
    s.store_id,
    s.partition_name,
    s.id AS association_id,
    s.owner_id,
    s.name
FROM
    time_series_export_series s
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations a
        WHERE
            a.id = s.id
    );
