-- Unit Registry Seed Data
-- Populates the 3 registry tables with unit metadata for all physical columns.
-- Must be run AFTER schema.sql and triggers.sql, BEFORE views.sql.
--
-- The bulk seed data lives in sibling CSV files so this stays reviewable:
--   schema/quantity_types.csv    -> quantity_types
--   schema/unit_conventions.csv  -> unit_conventions
-- Each CSV has a header row (skipped on import). Edit the CSVs to change the
-- registry; this script only wires them in and seals the result.
--
-- NOTE: the .import paths are relative to the process working directory
-- (the repo root, per the justfile recipes), not to this file.
--
-- The checksum INSERT at the end seals the registry (activates INSERT triggers).
-- 1. System metadata
INSERT INTO
    unit_management_metadata
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
-- Loaded from schema/quantity_types.csv via a staging table so empty fields
-- become NULL and the table's own column defaults still apply.
CREATE TEMP TABLE quantity_types_import (
    name TEXT,
    default_unit TEXT,
    dimension TEXT,
    description TEXT
);

.import --csv --skip 1 schema/quantity_types.csv quantity_types_import

INSERT INTO
    quantity_types (name, default_unit, dimension, description)
SELECT
    name,
    default_unit,
    dimension,
    NULLIF(description, '')
FROM
    quantity_types_import;

DROP TABLE quantity_types_import;

-- 3. Unit conventions — entity table columns and well-known attribute names.
-- Loaded from schema/unit_conventions.csv. CAST/NULLIF normalize CSV text into
-- the STRICT table's INTEGER / nullable columns.
CREATE TEMP TABLE unit_conventions_import (
    table_name TEXT,
    column_name TEXT,
    quantity_type TEXT,
    unit TEXT,
    is_per_unit TEXT,
    per_unit_base_column TEXT,
    description TEXT
);

.import --csv --skip 1 schema/unit_conventions.csv unit_conventions_import

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
SELECT
    table_name,
    column_name,
    quantity_type,
    unit,
    CAST(is_per_unit AS INTEGER),
    NULLIF(per_unit_base_column, ''),
    NULLIF(description, '')
FROM
    unit_conventions_import;

DROP TABLE unit_conventions_import;

-- 4. Seal the registry — compute and store checksum
-- Once this row exists, INSERT triggers on registry tables activate.
INSERT INTO
    unit_management_metadata (KEY, value, description)
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
