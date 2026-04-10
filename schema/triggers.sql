CREATE TRIGGER IF NOT EXISTS check_planning_regions_entity_exists BEFORE
INSERT ON planning_regions
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'planning_regions'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table planning_regions before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_balancing_topologies_entity_exists BEFORE
INSERT ON balancing_topologies
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'balancing_topologies'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table balancing_topologies before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_arcs_entity_exists BEFORE
INSERT ON arcs
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'arcs'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table arcs before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_transmission_lines_entity_exists BEFORE
INSERT ON transmission_lines
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'transmission_lines'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transmission_lines before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_transmission_interchanges_entity_exists BEFORE
INSERT ON transmission_interchanges
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'transmission_interchanges'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transmission_interchanges before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_thermal_generators_entity_exists BEFORE
INSERT ON thermal_generators
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'thermal_generators'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table thermal_generators before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_renewable_generators_entity_exists BEFORE
INSERT ON renewable_generators
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'renewable_generators'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table renewable_generators before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_hydro_generators_entity_exists BEFORE
INSERT ON hydro_generators
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'hydro_generators'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table hydro_generators before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_storage_units_entity_exists BEFORE
INSERT ON storage_units
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'storage_units'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table storage_units before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_hydro_reservoirs_entity_exists BEFORE
INSERT ON hydro_reservoirs
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'hydro_reservoirs'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table hydro_reservoirs before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_supply_technologies_entity_exists BEFORE
INSERT ON supply_technologies
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'supply_technologies'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table supply_technologies before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_transport_technologies_entity_exists BEFORE
INSERT ON transport_technologies
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'transport_technologies'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transport_technologies before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_supplemental_attributes_entity_exists BEFORE
INSERT ON supplemental_attributes
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'supplemental_attributes'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table supplemental_attributes before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_plants_entity_exists BEFORE
INSERT ON plants
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'plants'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table plants before insertion'
    );
END;

CREATE TRIGGER IF NOT EXISTS check_loads_entity_exists BEFORE
INSERT ON loads
    WHEN NOT EXISTS (
        SELECT 1
        FROM entities
        WHERE id = NEW.id
            AND entity_table = 'loads'
    ) BEGIN
SELECT RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table loads before insertion'
    );
END;


-- Business Logic Validation Triggers
CREATE TRIGGER enforce_arc_entity_types_insert
AFTER
INSERT ON arcs BEGIN
SELECT CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM entities
            WHERE id = NEW.from_id
        ) THEN RAISE(ABORT, 'from_id entity does not exist')
        WHEN NOT EXISTS (
            SELECT 1
            FROM entities
            WHERE id = NEW.to_id
        ) THEN RAISE(ABORT, 'to_id entity does not exist')
        WHEN (
            SELECT et.is_topology
            FROM entities e
            JOIN entity_types et ON e.entity_type = et.name
            WHERE e.id = NEW.from_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid from_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
        WHEN (
            SELECT et.is_topology
            FROM entities e
            JOIN entity_types et ON e.entity_type = et.name
            WHERE e.id = NEW.to_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid to_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
    END;
END;

CREATE TRIGGER enforce_arc_entity_types_update
AFTER UPDATE OF from_id, to_id ON arcs BEGIN
SELECT CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM entities
            WHERE id = NEW.from_id
        ) THEN RAISE(ABORT, 'from_id entity does not exist')
        WHEN NOT EXISTS (
            SELECT 1
            FROM entities
            WHERE id = NEW.to_id
        ) THEN RAISE(ABORT, 'to_id entity does not exist')
        WHEN (
            SELECT et.is_topology
            FROM entities e
            JOIN entity_types et ON e.entity_type = et.name
            WHERE e.id = NEW.from_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid from_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
        WHEN (
            SELECT et.is_topology
            FROM entities e
            JOIN entity_types et ON e.entity_type = et.name
            WHERE e.id = NEW.to_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid to_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
    END;
END;

-- Enforce that a turbine can have at most 1 upstream reservoir
-- (i.e., at most 1 row where sink is a turbine and source is a reservoir)
CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_upstream_reservoir BEFORE
INSERT ON hydro_reservoir_connections
    WHEN (
        -- Check if sink is a turbine (hydro_generators or storage_units)
        SELECT entity_table
        FROM entities
        WHERE id = NEW.sink_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        -- Check if source is a reservoir
        SELECT entity_table
        FROM entities
        WHERE id = NEW.source_id
    ) = 'hydro_reservoirs' BEGIN
SELECT CASE
        WHEN EXISTS (
            SELECT 1
            FROM hydro_reservoir_connections hrc
                JOIN entities e_source ON hrc.source_id = e_source.id
            WHERE hrc.sink_id = NEW.sink_id
                AND e_source.entity_table = 'hydro_reservoirs'
        ) THEN RAISE(
            ABORT,
            'Turbine already has an upstream reservoir. Each turbine can have at most 1 upstream reservoir.'
        )
    END;
END;

CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_upstream_reservoir_update
BEFORE UPDATE OF source_id, sink_id ON hydro_reservoir_connections
    WHEN (
        SELECT entity_table
        FROM entities
        WHERE id = NEW.sink_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        SELECT entity_table
        FROM entities
        WHERE id = NEW.source_id
    ) = 'hydro_reservoirs' BEGIN
SELECT CASE
        WHEN EXISTS (
            SELECT 1
            FROM hydro_reservoir_connections hrc
                JOIN entities e_source ON hrc.source_id = e_source.id
            WHERE hrc.sink_id = NEW.sink_id
                AND e_source.entity_table = 'hydro_reservoirs'
                AND hrc.rowid != OLD.rowid
        ) THEN RAISE(
            ABORT,
            'Turbine already has an upstream reservoir. Each turbine can have at most 1 upstream reservoir.'
        )
    END;
END;

-- Enforce that a turbine can have at most 1 downstream reservoir
-- (i.e., at most 1 row where source is a turbine and sink is a reservoir)
CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_downstream_reservoir BEFORE
INSERT ON hydro_reservoir_connections
    WHEN (
        -- Check if source is a turbine (hydro_generators or storage_units)
        SELECT entity_table
        FROM entities
        WHERE id = NEW.source_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        -- Check if sink is a reservoir
        SELECT entity_table
        FROM entities
        WHERE id = NEW.sink_id
    ) = 'hydro_reservoirs' BEGIN
SELECT CASE
        WHEN EXISTS (
            SELECT 1
            FROM hydro_reservoir_connections hrc
                JOIN entities e_sink ON hrc.sink_id = e_sink.id
            WHERE hrc.source_id = NEW.source_id
                AND e_sink.entity_table = 'hydro_reservoirs'
        ) THEN RAISE(
            ABORT,
            'Turbine already has a downstream reservoir. Each turbine can have at most 1 downstream reservoir.'
        )
    END;
END;

CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_downstream_reservoir_update
BEFORE UPDATE OF source_id, sink_id ON hydro_reservoir_connections
    WHEN (
        SELECT entity_table
        FROM entities
        WHERE id = NEW.source_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        SELECT entity_table
        FROM entities
        WHERE id = NEW.sink_id
    ) = 'hydro_reservoirs' BEGIN
SELECT CASE
        WHEN EXISTS (
            SELECT 1
            FROM hydro_reservoir_connections hrc
                JOIN entities e_sink ON hrc.sink_id = e_sink.id
            WHERE hrc.source_id = NEW.source_id
                AND e_sink.entity_table = 'hydro_reservoirs'
                AND hrc.rowid != OLD.rowid
        ) THEN RAISE(
            ABORT,
            'Turbine already has a downstream reservoir. Each turbine can have at most 1 downstream reservoir.'
        )
    END;
END;

-- Reverse cascade triggers: delete from entities when child table row is deleted
CREATE TRIGGER IF NOT EXISTS delete_planning_regions_entity
AFTER DELETE ON planning_regions
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_balancing_topologies_entity
AFTER DELETE ON balancing_topologies
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_arcs_entity
AFTER DELETE ON arcs
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_transmission_lines_entity
AFTER DELETE ON transmission_lines
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_transmission_interchanges_entity
AFTER DELETE ON transmission_interchanges
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_thermal_generators_entity
AFTER DELETE ON thermal_generators
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_renewable_generators_entity
AFTER DELETE ON renewable_generators
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_hydro_generators_entity
AFTER DELETE ON hydro_generators
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_storage_units_entity
AFTER DELETE ON storage_units
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_hydro_reservoirs_entity
AFTER DELETE ON hydro_reservoirs
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_supply_technologies_entity
AFTER DELETE ON supply_technologies
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_transport_technologies_entity
AFTER DELETE ON transport_technologies
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_storage_technologies_entity
AFTER DELETE ON storage_technologies
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_demand_technologies_entity
AFTER DELETE ON demand_technologies
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_supplemental_attributes_entity
AFTER DELETE ON supplemental_attributes
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_plants_entity
AFTER DELETE ON plants
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_loads_entity
AFTER DELETE ON loads
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

-- =============================================================================
-- Unit Registry Immutability Triggers
-- UPDATE and DELETE are blocked unconditionally.
-- INSERT is blocked only after the registry is sealed (checksum exists).
-- =============================================================================

-- system_metadata
CREATE TRIGGER IF NOT EXISTS prevent_system_metadata_update
BEFORE UPDATE ON system_metadata
BEGIN
    SELECT RAISE(ABORT,
        'system_metadata is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_system_metadata_delete
BEFORE DELETE ON system_metadata
BEGIN
    SELECT RAISE(ABORT,
        'system_metadata is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_system_metadata_insert
BEFORE INSERT ON system_metadata
WHEN EXISTS (
    SELECT 1 FROM system_metadata
    WHERE key = 'unit_conventions_checksum'
)
BEGIN
    SELECT RAISE(ABORT,
        'system_metadata is sealed. New entries require a schema migration.');
END;

-- quantity_types
CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_update
BEFORE UPDATE ON quantity_types
BEGIN
    SELECT RAISE(ABORT,
        'quantity_types is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_delete
BEFORE DELETE ON quantity_types
BEGIN
    SELECT RAISE(ABORT,
        'quantity_types is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_insert
BEFORE INSERT ON quantity_types
WHEN EXISTS (
    SELECT 1 FROM system_metadata
    WHERE key = 'unit_conventions_checksum'
)
BEGIN
    SELECT RAISE(ABORT,
        'quantity_types is sealed. New entries require a schema migration.');
END;

-- unit_conventions
CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_update
BEFORE UPDATE ON unit_conventions
BEGIN
    SELECT RAISE(ABORT,
        'unit_conventions is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_delete
BEFORE DELETE ON unit_conventions
BEGIN
    SELECT RAISE(ABORT,
        'unit_conventions is immutable. Changes require a schema migration.');
END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_insert
BEFORE INSERT ON unit_conventions
WHEN EXISTS (
    SELECT 1 FROM system_metadata
    WHERE key = 'unit_conventions_checksum'
)
BEGIN
    SELECT RAISE(ABORT,
        'unit_conventions is sealed. New entries require a schema migration.');
END;

-- =============================================================================
-- Unit Convention Validation Triggers
-- =============================================================================

-- unique policy requires a companion column
CREATE TRIGGER IF NOT EXISTS validate_unit_convention_companion
BEFORE INSERT ON unit_conventions
WHEN NEW.unit = 'unique' AND NEW.companion_column IS NULL
BEGIN
    SELECT RAISE(ABORT, 'unit_policy unique requires companion_column.');
END;

-- =============================================================================
-- Attribute Unit Validation Triggers (registry-linked)
-- Known attribute names must match registered unit and quantity_type.
-- Unknown attributes with numeric or structured (non-boolean, non-text, non-null) JSON values
-- must provide unit and quantity_type. Boolean, text, and null-valued attributes pass freely.
-- =============================================================================

CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_insert
BEFORE INSERT ON attributes
BEGIN
    SELECT CASE
        -- Known attribute name: must match registered unit and quantity_type
        WHEN EXISTS (
            SELECT 1 FROM unit_conventions
            WHERE table_name = 'attributes' AND column_name = NEW.name
        ) AND (
            NEW.unit IS NULL
            OR NEW.unit != (
                SELECT unit FROM unit_conventions
                WHERE table_name = 'attributes' AND column_name = NEW.name
            )
            OR NEW.quantity_type IS NULL
            OR NEW.quantity_type != (
                SELECT quantity_type FROM unit_conventions
                WHERE table_name = 'attributes' AND column_name = NEW.name
            )
        )
        THEN RAISE(ABORT,
            'Known attribute must use the registered unit and quantity_type from unit_conventions.')
        -- Unknown attribute with physical value: must have unit and quantity_type
        -- Physical = anything except boolean, text, or null
        WHEN NOT EXISTS (
            SELECT 1 FROM unit_conventions
            WHERE table_name = 'attributes' AND column_name = NEW.name
        )
        AND json_type(NEW.value) NOT IN ('true', 'false', 'null', 'text')
        AND (NEW.unit IS NULL OR NEW.quantity_type IS NULL)
        THEN RAISE(ABORT,
            'Attributes with numeric or structured values require unit and quantity_type. Use unit=1 and quantity_type=Dimensionless for dimensionless quantities.')
    END;
END;

CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_update
BEFORE UPDATE ON attributes
BEGIN
    SELECT CASE
        -- Known attribute name: must match registered unit and quantity_type
        WHEN EXISTS (
            SELECT 1 FROM unit_conventions
            WHERE table_name = 'attributes' AND column_name = NEW.name
        ) AND (
            NEW.unit IS NULL
            OR NEW.unit != (
                SELECT unit FROM unit_conventions
                WHERE table_name = 'attributes' AND column_name = NEW.name
            )
            OR NEW.quantity_type IS NULL
            OR NEW.quantity_type != (
                SELECT quantity_type FROM unit_conventions
                WHERE table_name = 'attributes' AND column_name = NEW.name
            )
        )
        THEN RAISE(ABORT,
            'Known attribute must use the registered unit and quantity_type from unit_conventions.')
        -- Unknown attribute with physical value: must have unit and quantity_type
        WHEN NOT EXISTS (
            SELECT 1 FROM unit_conventions
            WHERE table_name = 'attributes' AND column_name = NEW.name
        )
        AND json_type(NEW.value) NOT IN ('true', 'false', 'null', 'text')
        AND (NEW.unit IS NULL OR NEW.quantity_type IS NULL)
        THEN RAISE(ABORT,
            'Attributes with numeric or structured values require unit and quantity_type. Use unit=1 and quantity_type=Dimensionless for dimensionless quantities.')
    END;
END;
