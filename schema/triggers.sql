CREATE TRIGGER IF NOT EXISTS check_planning_regions_entity_exists BEFORE
INSERT
    ON planning_regions
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'planning_regions'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table planning_regions before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_balancing_topologies_entity_exists BEFORE
INSERT
    ON balancing_topologies
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'balancing_topologies'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table balancing_topologies before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_arcs_entity_exists BEFORE
INSERT
    ON arcs
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'arcs'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table arcs before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_transmission_lines_entity_exists BEFORE
INSERT
    ON transmission_lines
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'transmission_lines'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transmission_lines before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_discrete_controlled_ac_branches_entity_exists BEFORE
INSERT
    ON discrete_controlled_ac_branches
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'discrete_controlled_ac_branches'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table discrete_controlled_ac_branches before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_transformer_circuits_entity_exists BEFORE
INSERT
    ON transformer_circuits
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'transformer_circuits'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transformer_circuits before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_two_winding_transformers_entity_exists BEFORE
INSERT
    ON two_winding_transformers
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'two_winding_transformers'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table two_winding_transformers before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_three_winding_transformers_entity_exists BEFORE
INSERT
    ON three_winding_transformers
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'three_winding_transformers'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table three_winding_transformers before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_transmission_interchanges_entity_exists BEFORE
INSERT
    ON transmission_interchanges
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'transmission_interchanges'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transmission_interchanges before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_thermal_generators_entity_exists BEFORE
INSERT
    ON thermal_generators
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'thermal_generators'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table thermal_generators before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_renewable_generators_entity_exists BEFORE
INSERT
    ON renewable_generators
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'renewable_generators'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table renewable_generators before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_hydro_generators_entity_exists BEFORE
INSERT
    ON hydro_generators
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'hydro_generators'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table hydro_generators before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_storage_units_entity_exists BEFORE
INSERT
    ON storage_units
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'storage_units'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table storage_units before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_hydro_reservoirs_entity_exists BEFORE
INSERT
    ON hydro_reservoirs
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'hydro_reservoirs'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table hydro_reservoirs before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_supply_technologies_entity_exists BEFORE
INSERT
    ON supply_technologies
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'supply_technologies'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table supply_technologies before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_transport_technologies_entity_exists BEFORE
INSERT
    ON transport_technologies
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'transport_technologies'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table transport_technologies before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_storage_technologies_entity_exists BEFORE
INSERT
    ON storage_technologies
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'storage_technologies'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table storage_technologies before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_demand_technologies_entity_exists BEFORE
INSERT
    ON demand_technologies
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'demand_technologies'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table demand_technologies before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_supplemental_attributes_entity_exists BEFORE
INSERT
    ON supplemental_attributes
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'supplemental_attributes'
    )
BEGIN
SELECT
    RAISE(
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
INSERT
    ON loads
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'loads'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table loads before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_fixed_admittance_entity_exists BEFORE
INSERT
    ON fixed_admittance
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'fixed_admittance'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table fixed_admittance before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_switched_admittance_entity_exists BEFORE
INSERT
    ON switched_admittance
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'switched_admittance'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table switched_admittance before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_sources_entity_exists BEFORE
INSERT
    ON sources
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'sources'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table sources before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_two_terminal_hvdc_lines_entity_exists BEFORE
INSERT
    ON two_terminal_hvdc_lines
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'two_terminal_hvdc_lines'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table two_terminal_hvdc_lines before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_synchronous_condensers_entity_exists BEFORE
INSERT
    ON synchronous_condensers
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'synchronous_condensers'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table synchronous_condensers before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_tmodel_hvdc_lines_entity_exists BEFORE
INSERT
    ON tmodel_hvdc_lines
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'tmodel_hvdc_lines'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table tmodel_hvdc_lines before insertion'
    );

END;


CREATE TRIGGER IF NOT EXISTS check_facts_control_devices_entity_exists BEFORE
INSERT
    ON facts_control_devices
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'facts_control_devices'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table facts_control_devices before insertion'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_interconnecting_converters_entity_exists BEFORE
INSERT
    ON interconnecting_converters
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'interconnecting_converters'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'Entity ID must exist in entities table with entity_table interconnecting_converters before insertion'
    );

END;

-- Business Logic Validation Triggers
CREATE TRIGGER enforce_arc_entity_types_insert
AFTER
INSERT
    ON arcs
BEGIN
SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.from_id
        ) THEN RAISE(ABORT, 'from_id entity does not exist')
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.to_id
        ) THEN RAISE(ABORT, 'to_id entity does not exist')
        WHEN (
            SELECT
                et.is_topology
            FROM
                entities e
                JOIN entity_types et ON e.entity_type = et.name
            WHERE
                e.id = NEW.from_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid from_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
        WHEN (
            SELECT
                et.is_topology
            FROM
                entities e
                JOIN entity_types et ON e.entity_type = et.name
            WHERE
                e.id = NEW.to_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid to_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
    END;

END;

CREATE TRIGGER enforce_arc_entity_types_update
AFTER
UPDATE
    OF from_id,
    to_id ON arcs
BEGIN
SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.from_id
        ) THEN RAISE(ABORT, 'from_id entity does not exist')
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.to_id
        ) THEN RAISE(ABORT, 'to_id entity does not exist')
        WHEN (
            SELECT
                et.is_topology
            FROM
                entities e
                JOIN entity_types et ON e.entity_type = et.name
            WHERE
                e.id = NEW.from_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid from_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
        WHEN (
            SELECT
                et.is_topology
            FROM
                entities e
                JOIN entity_types et ON e.entity_type = et.name
            WHERE
                e.id = NEW.to_id
        ) = 0 THEN RAISE(
            ABORT,
            'Invalid to_id entity type: must be a topology type (entity_types.is_topology = 1)'
        )
    END;

END;

-- Enforce that a turbine can have at most 1 upstream reservoir
-- (i.e., at most 1 row where sink is a turbine and source is a reservoir)
CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_upstream_reservoir BEFORE
INSERT
    ON hydro_reservoir_connections
    WHEN (
        -- Check if sink is a turbine (hydro_generators or storage_units)
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.sink_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        -- Check if source is a reservoir
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.source_id
    ) = 'hydro_reservoirs'
BEGIN
SELECT
    CASE
        WHEN EXISTS (
            SELECT
                1
            FROM
                hydro_reservoir_connections hrc
                JOIN entities e_source ON hrc.source_id = e_source.id
            WHERE
                hrc.sink_id = NEW.sink_id
                AND e_source.entity_table = 'hydro_reservoirs'
        ) THEN RAISE(
            ABORT,
            'Turbine already has an upstream reservoir. Each turbine can have at most 1 upstream reservoir.'
        )
    END;

END;

CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_upstream_reservoir_update BEFORE
UPDATE
    OF source_id,
    sink_id ON hydro_reservoir_connections
    WHEN (
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.sink_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.source_id
    ) = 'hydro_reservoirs'
BEGIN
SELECT
    CASE
        WHEN EXISTS (
            SELECT
                1
            FROM
                hydro_reservoir_connections hrc
                JOIN entities e_source ON hrc.source_id = e_source.id
            WHERE
                hrc.sink_id = NEW.sink_id
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
INSERT
    ON hydro_reservoir_connections
    WHEN (
        -- Check if source is a turbine (hydro_generators or storage_units)
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.source_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        -- Check if sink is a reservoir
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.sink_id
    ) = 'hydro_reservoirs'
BEGIN
SELECT
    CASE
        WHEN EXISTS (
            SELECT
                1
            FROM
                hydro_reservoir_connections hrc
                JOIN entities e_sink ON hrc.sink_id = e_sink.id
            WHERE
                hrc.source_id = NEW.source_id
                AND e_sink.entity_table = 'hydro_reservoirs'
        ) THEN RAISE(
            ABORT,
            'Turbine already has a downstream reservoir. Each turbine can have at most 1 downstream reservoir.'
        )
    END;

END;

CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_downstream_reservoir_update BEFORE
UPDATE
    OF source_id,
    sink_id ON hydro_reservoir_connections
    WHEN (
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.source_id
    ) IN ('hydro_generators', 'storage_units')
    AND (
        SELECT
            entity_table
        FROM
            entities
        WHERE
            id = NEW.sink_id
    ) = 'hydro_reservoirs'
BEGIN
SELECT
    CASE
        WHEN EXISTS (
            SELECT
                1
            FROM
                hydro_reservoir_connections hrc
                JOIN entities e_sink ON hrc.sink_id = e_sink.id
            WHERE
                hrc.source_id = NEW.source_id
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
AFTER
    DELETE ON planning_regions FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_balancing_topologies_entity
AFTER
    DELETE ON balancing_topologies FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_arcs_entity
AFTER
    DELETE ON arcs FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_transmission_lines_entity
AFTER
    DELETE ON transmission_lines FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_discrete_controlled_ac_branches_entity
AFTER
    DELETE ON discrete_controlled_ac_branches FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_transformer_circuits_entity
AFTER
    DELETE ON transformer_circuits FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_two_winding_transformers_entity
AFTER
    DELETE ON two_winding_transformers FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_three_winding_transformers_entity
AFTER
    DELETE ON three_winding_transformers FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_transmission_interchanges_entity
AFTER
    DELETE ON transmission_interchanges FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_thermal_generators_entity
AFTER
    DELETE ON thermal_generators FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_renewable_generators_entity
AFTER
    DELETE ON renewable_generators FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_hydro_generators_entity
AFTER
    DELETE ON hydro_generators FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_storage_units_entity
AFTER
    DELETE ON storage_units FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_hydro_reservoirs_entity
AFTER
    DELETE ON hydro_reservoirs FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_supply_technologies_entity
AFTER
    DELETE ON supply_technologies FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_transport_technologies_entity
AFTER
    DELETE ON transport_technologies FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_storage_technologies_entity
AFTER
    DELETE ON storage_technologies FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_demand_technologies_entity
AFTER
    DELETE ON demand_technologies FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_supplemental_attributes_entity
AFTER
    DELETE ON supplemental_attributes FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_plants_entity
AFTER DELETE ON plants
FOR EACH ROW
BEGIN
    DELETE FROM entities WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS delete_loads_entity
AFTER
    DELETE ON loads FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_fixed_admittance_entity
AFTER
    DELETE ON fixed_admittance FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_switched_admittance_entity
AFTER
    DELETE ON switched_admittance FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_sources_entity
AFTER
    DELETE ON sources FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_two_terminal_hvdc_lines_entity
AFTER
    DELETE ON two_terminal_hvdc_lines FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_synchronous_condensers_entity
AFTER
    DELETE ON synchronous_condensers FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_tmodel_hvdc_lines_entity
AFTER
    DELETE ON tmodel_hvdc_lines FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_facts_control_devices_entity
AFTER
    DELETE ON facts_control_devices FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_interconnecting_converters_entity
AFTER
    DELETE ON interconnecting_converters FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

-- =============================================================================
-- Unit Registry Immutability Triggers
-- UPDATE and DELETE are blocked unconditionally.
-- INSERT is blocked only after the registry is sealed (checksum exists).
-- =============================================================================
-- unit_management_metadata
CREATE TRIGGER IF NOT EXISTS prevent_unit_management_metadata_update BEFORE
UPDATE
    ON unit_management_metadata
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_management_metadata is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_management_metadata_delete BEFORE DELETE ON unit_management_metadata
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_management_metadata is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_management_metadata_insert BEFORE
INSERT
    ON unit_management_metadata
    WHEN EXISTS (
        SELECT
            1
        FROM
            unit_management_metadata
        WHERE
            KEY = 'unit_conventions_checksum'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_management_metadata is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

-- quantity_types
CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_update BEFORE
UPDATE
    ON quantity_types
BEGIN
SELECT
    RAISE(
        ABORT,
        'quantity_types is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_delete BEFORE DELETE ON quantity_types
BEGIN
SELECT
    RAISE(
        ABORT,
        'quantity_types is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_insert BEFORE
INSERT
    ON quantity_types
    WHEN EXISTS (
        SELECT
            1
        FROM
            unit_management_metadata
        WHERE
            KEY = 'unit_conventions_checksum'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'quantity_types is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

-- unit_conventions
CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_update BEFORE
UPDATE
    ON unit_conventions
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_conventions is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_delete BEFORE DELETE ON unit_conventions
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_conventions is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_insert BEFORE
INSERT
    ON unit_conventions
    WHEN EXISTS (
        SELECT
            1
        FROM
            unit_management_metadata
        WHERE
            KEY = 'unit_conventions_checksum'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_conventions is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

-- allowed_units (registry vocabulary): UPDATE and DELETE are blocked
-- unconditionally; INSERT is blocked only after the registry is sealed.
CREATE TRIGGER IF NOT EXISTS prevent_allowed_units_update BEFORE
UPDATE
    ON allowed_units
BEGIN
SELECT
    RAISE(
        ABORT,
        'allowed_units is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_allowed_units_delete BEFORE DELETE ON allowed_units
BEGIN
SELECT
    RAISE(
        ABORT,
        'allowed_units is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_allowed_units_insert BEFORE
INSERT
    ON allowed_units
    WHEN EXISTS (
        SELECT
            1
        FROM
            unit_management_metadata
        WHERE
            KEY = 'unit_conventions_checksum'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'allowed_units is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

-- =============================================================================
-- Time Series Metadata Unit Validation Triggers (registry-linked)
-- The (quantity_type, unit) pair on each series must be a registered vocabulary
-- entry in allowed_units.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_time_series_metadata_insert BEFORE
INSERT
    ON time_series_metadata
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            allowed_units au
        WHERE
            au.quantity_type = NEW.quantity_type
            AND au.unit = NEW.unit
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_metadata (quantity_type, unit) must be a registered pair in allowed_units.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_time_series_metadata_update BEFORE
UPDATE
    ON time_series_metadata
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            allowed_units au
        WHERE
            au.quantity_type = NEW.quantity_type
            AND au.unit = NEW.unit
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_metadata (quantity_type, unit) must be a registered pair in allowed_units.'
    );

END;

-- =============================================================================
-- Attribute Unit Validation Triggers (registry-linked)
-- Known attribute names must match registered unit and quantity_type.
-- Unknown attributes with numeric or structured (non-boolean, non-text, non-null) JSON values
-- must provide unit and quantity_type. Boolean, text, and null-valued attributes pass freely.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_insert BEFORE
INSERT
    ON attributes
BEGIN
SELECT
    CASE
        -- Known attribute name: the (unit, quantity_type) must match some
        -- registered row for that name. Polymorphic names carry several rows,
        -- so any matching row satisfies the check (NOT EXISTS over the match).
        WHEN EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND (
            NEW.unit IS NULL
            OR NEW.quantity_type IS NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    unit_conventions uc
                WHERE
                    uc.table_name = 'attributes'
                    AND LOWER(uc.column_name) = LOWER(NEW.name)
                    AND uc.unit = NEW.unit
                    AND uc.quantity_type = NEW.quantity_type
            )
        ) THEN RAISE(
            ABORT,
            'Known attribute must use the registered unit and quantity_type from unit_conventions.'
        )
        -- Unknown attribute with physical value: must have a vocabulary-valid
        -- (quantity_type, unit) pair from allowed_units.
        -- Physical = anything except boolean, text, or null -- except that a
        -- numeric identifier (bus number, node reference) is not physical at all,
        -- so names listed in attribute_identifiers are exempt rather than being
        -- forced to carry a made-up unit.
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND NOT EXISTS (
            SELECT
                1
            FROM
                attribute_identifiers
            WHERE
                LOWER(name) = LOWER(NEW.name)
        )
        AND json_type(NEW.value) NOT IN ('true', 'false', 'null', 'text')
        AND (
            NEW.unit IS NULL
            OR NEW.quantity_type IS NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    allowed_units au
                WHERE
                    au.quantity_type = NEW.quantity_type
                    AND au.unit = NEW.unit
            )
        ) THEN RAISE(
            ABORT,
            'Attributes with numeric or structured values require a vocabulary-valid unit and quantity_type from allowed_units. Use unit=1 and quantity_type=Dimensionless for dimensionless quantities.'
        )
    END;

END;

CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_update BEFORE
UPDATE
    ON attributes
BEGIN
SELECT
    CASE
        -- Known attribute name: the (unit, quantity_type) must match some
        -- registered row for that name. Polymorphic names carry several rows,
        -- so any matching row satisfies the check (NOT EXISTS over the match).
        WHEN EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND (
            NEW.unit IS NULL
            OR NEW.quantity_type IS NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    unit_conventions uc
                WHERE
                    uc.table_name = 'attributes'
                    AND LOWER(uc.column_name) = LOWER(NEW.name)
                    AND uc.unit = NEW.unit
                    AND uc.quantity_type = NEW.quantity_type
            )
        ) THEN RAISE(
            ABORT,
            'Known attribute must use the registered unit and quantity_type from unit_conventions.'
        )
        -- Unknown attribute with physical value: must have a vocabulary-valid
        -- (quantity_type, unit) pair from allowed_units. Identifier names are
        -- exempt, as on insert -- see attribute_identifiers.
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND NOT EXISTS (
            SELECT
                1
            FROM
                attribute_identifiers
            WHERE
                LOWER(name) = LOWER(NEW.name)
        )
        AND json_type(NEW.value) NOT IN ('true', 'false', 'null', 'text')
        AND (
            NEW.unit IS NULL
            OR NEW.quantity_type IS NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    allowed_units au
                WHERE
                    au.quantity_type = NEW.quantity_type
                    AND au.unit = NEW.unit
            )
        ) THEN RAISE(
            ABORT,
            'Attributes with numeric or structured values require a vocabulary-valid unit and quantity_type from allowed_units. Use unit=1 and quantity_type=Dimensionless for dimensionless quantities.'
        )
    END;

END;

-- =============================================================================
-- Time Series Data Validation Triggers
-- Units live on time_series_metadata (one row per uuid), so a series cannot
-- carry mixed units. Each static_time_series row must reference an existing
-- metadata row.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS check_static_time_series_metadata_exists BEFORE
INSERT
    ON static_time_series
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            time_series_metadata
        WHERE
            uuid = NEW.uuid
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'static_time_series.uuid must exist in time_series_metadata before insertion.'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_static_time_series_metadata_exists_update BEFORE
UPDATE
    OF uuid ON static_time_series
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            time_series_metadata
        WHERE
            uuid = NEW.uuid
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'static_time_series.uuid must exist in time_series_metadata before insertion.'
    );

END;

-- =============================================================================
-- Deprecated time_series_associations.units guard
-- The column is deprecated in favor of time_series_metadata.unit. When set, it
-- must agree with the series metadata unit.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_time_series_associations_units_insert BEFORE
INSERT
    ON time_series_associations
    WHEN NEW.units IS NOT NULL
    AND EXISTS (
        SELECT
            1
        FROM
            time_series_metadata m
        WHERE
            m.uuid = NEW.time_series_uuid
    )
    AND NOT EXISTS (
        SELECT
            1
        FROM
            time_series_metadata m
        WHERE
            m.uuid = NEW.time_series_uuid
            AND m.unit = NEW.units
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations.units must equal time_series_metadata.unit for the same time_series_uuid, or no time_series_metadata row exists.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_time_series_associations_units_update BEFORE
UPDATE
    ON time_series_associations
    WHEN NEW.units IS NOT NULL
    AND EXISTS (
        SELECT
            1
        FROM
            time_series_metadata m
        WHERE
            m.uuid = NEW.time_series_uuid
    )
    AND NOT EXISTS (
        SELECT
            1
        FROM
            time_series_metadata m
        WHERE
            m.uuid = NEW.time_series_uuid
            AND m.unit = NEW.units
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations.units must equal time_series_metadata.unit for the same time_series_uuid, or no time_series_metadata row exists.'
    );

END;

-- =============================================================================
-- Cost Payload Power-Units Guard
-- The DB stores no system/component base, so cost payloads must express their
-- variable curve in NATURAL_UNITS. Relative-base payloads are uninterpretable.
-- NULL/absent power_units passes (payload may be a plain curve). Applies to the
-- nine cost-bearing columns: production_cost on the three generator tables and
-- the operation_cost(s) blobs elsewhere (renewable_generators carries two:
-- production_cost and operation_cost.curtailment_cost).
-- The authoritative list of guarded cost payload paths is
-- column_conventions.json (production_cost / operation_cost* rows); keep in sync.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_thermal_generators_cost_units_insert BEFORE
INSERT
    ON thermal_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_thermal_generators_cost_units_update BEFORE
UPDATE
    ON thermal_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_renewable_generators_cost_units_insert BEFORE
INSERT
    ON renewable_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.curtailment_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_renewable_generators_cost_units_update BEFORE
UPDATE
    ON renewable_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.curtailment_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_generators_cost_units_insert BEFORE
INSERT
    ON hydro_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_generators_cost_units_update BEFORE
UPDATE
    ON hydro_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_units_cost_units_insert BEFORE
INSERT
    ON storage_units
    WHEN json_extract(NEW.operation_cost, '$.charge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.discharge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_units_cost_units_update BEFORE
UPDATE
    ON storage_units
    WHEN json_extract(NEW.operation_cost, '$.charge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.discharge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_reservoirs_cost_units_insert BEFORE
INSERT
    ON hydro_reservoirs
    WHEN json_extract(NEW.operation_cost, '$.variable.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_reservoirs_cost_units_update BEFORE
UPDATE
    ON hydro_reservoirs
    WHEN json_extract(NEW.operation_cost, '$.variable.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_supply_technologies_cost_units_insert BEFORE
INSERT
    ON supply_technologies
    WHEN json_extract(NEW.operation_costs, '$.variable.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_supply_technologies_cost_units_update BEFORE
UPDATE
    ON supply_technologies
    WHEN json_extract(NEW.operation_costs, '$.variable.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_technologies_cost_units_insert BEFORE
INSERT
    ON storage_technologies
    WHEN json_extract(NEW.operation_costs, '$.charge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_costs, '$.discharge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_technologies_cost_units_update BEFORE
UPDATE
    ON storage_technologies
    WHEN json_extract(NEW.operation_costs, '$.charge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_costs, '$.discharge_variable_cost.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

-- sources carries PSY ImportExportCost, whose two guarded paths are the import
-- and export offer curves rather than a `variable` curve.
CREATE TRIGGER IF NOT EXISTS validate_sources_cost_units_insert BEFORE
INSERT
    ON sources
    WHEN json_extract(NEW.operation_cost, '$.import_offer_curves.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.export_offer_curves.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_sources_cost_units_update BEFORE
UPDATE
    ON sources
    WHEN json_extract(NEW.operation_cost, '$.import_offer_curves.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
    OR json_extract(NEW.operation_cost, '$.export_offer_curves.power_units') IN ('SYSTEM_BASE', 'COMPONENT_BASE')
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS; the DB stores no base to interpret relative units'
    );

END;

-- =============================================================================
-- EmissionsData supplemental-attribute payload guard
-- supplemental_attributes stores free-form JSON per TYPE; for TYPE =
-- 'EmissionsData' the payload's enum-bearing fields must use the schema enums
-- (Core/common.json MassUnit/EnergyUnit/PollutantType/EmissionBasis) and the
-- energy_unit must be consistent with the basis, mirroring the schema's allOf
-- rule. Required fields (pollutant, basis, energy_unit) are rejected when
-- absent: pollutant/basis via explicit IS NULL terms, energy_unit via the
-- NULL-safe basis-gated IS NOT checks. Absent optional fields (mass_unit) pass.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_supplemental_emissions_insert BEFORE
INSERT
    ON supplemental_attributes
    WHEN NEW.TYPE = 'EmissionsData'
    AND (
        json_extract(NEW.value, '$.mass_unit') NOT IN ('KG', 'LB', 'SHORT_TON', 'METRIC_TON')
        OR json_extract(NEW.value, '$.energy_unit') NOT IN ('MMBTU', 'GJ', 'MWH')
        OR json_extract(NEW.value, '$.pollutant') NOT IN ('CO2', 'CO2E', 'CH4', 'N2O', 'NOX', 'SO2', 'CO', 'VOC', 'PM25', 'PM10', 'HG', 'HAP', 'CUSTOM')
        OR json_extract(NEW.value, '$.basis') NOT IN ('FUEL_INPUT', 'POWER_OUTPUT')
        OR json_extract(NEW.value, '$.pollutant') IS NULL
        OR json_extract(NEW.value, '$.basis') IS NULL
        OR (
            json_extract(NEW.value, '$.basis') = 'FUEL_INPUT'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'MMBTU'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'GJ'
        )
        OR (
            json_extract(NEW.value, '$.basis') = 'POWER_OUTPUT'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'MWH'
        )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'EmissionsData payload must use MassUnit/EnergyUnit/PollutantType/EmissionBasis enum values with a basis-consistent energy_unit (FUEL_INPUT: MMBTU or GJ; POWER_OUTPUT: MWH).'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_supplemental_emissions_update BEFORE
UPDATE
    ON supplemental_attributes
    WHEN NEW.TYPE = 'EmissionsData'
    AND (
        json_extract(NEW.value, '$.mass_unit') NOT IN ('KG', 'LB', 'SHORT_TON', 'METRIC_TON')
        OR json_extract(NEW.value, '$.energy_unit') NOT IN ('MMBTU', 'GJ', 'MWH')
        OR json_extract(NEW.value, '$.pollutant') NOT IN ('CO2', 'CO2E', 'CH4', 'N2O', 'NOX', 'SO2', 'CO', 'VOC', 'PM25', 'PM10', 'HG', 'HAP', 'CUSTOM')
        OR json_extract(NEW.value, '$.basis') NOT IN ('FUEL_INPUT', 'POWER_OUTPUT')
        OR json_extract(NEW.value, '$.pollutant') IS NULL
        OR json_extract(NEW.value, '$.basis') IS NULL
        OR (
            json_extract(NEW.value, '$.basis') = 'FUEL_INPUT'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'MMBTU'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'GJ'
        )
        OR (
            json_extract(NEW.value, '$.basis') = 'POWER_OUTPUT'
            AND json_extract(NEW.value, '$.energy_unit') IS NOT 'MWH'
        )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'EmissionsData payload must use MassUnit/EnergyUnit/PollutantType/EmissionBasis enum values with a basis-consistent energy_unit (FUEL_INPUT: MMBTU or GJ; POWER_OUTPUT: MWH).'
    );

END;

-- =============================================================================
-- Bus-domain triggers (AC vs DC)
-- The two HVDC families are not interchangeable: tmodel_hvdc_lines is a
-- DC-network branch and must run between DC buses (entity_types.is_dc = 1),
-- reached from the AC side through interconnecting_converters, while every AC
-- branch and every point-to-point two_terminal_hvdc_lines row must run between
-- AC topologies (is_dc = 0). A foreign key cannot express this: arcs reference
-- entities generically, and the domain lives on the entity's type.
-- Not enforced here: transmission_interchanges, a market construct between
-- areas rather than a physical branch.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS enforce_transmission_lines_arc_domain_insert BEFORE
INSERT
    ON transmission_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'transmission_lines.arc_id must connect AC topologies (entity_types.is_dc = 0); use tmodel_hvdc_lines for DC-network branches'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_transmission_lines_arc_domain_update BEFORE
UPDATE
    OF arc_id ON transmission_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'transmission_lines.arc_id must connect AC topologies (entity_types.is_dc = 0); use tmodel_hvdc_lines for DC-network branches'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_discrete_controlled_ac_branches_arc_domain_insert BEFORE
INSERT
    ON discrete_controlled_ac_branches
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'discrete_controlled_ac_branches.arc_id must connect AC topologies (entity_types.is_dc = 0)'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_discrete_controlled_ac_branches_arc_domain_update BEFORE
UPDATE
    OF arc_id ON discrete_controlled_ac_branches
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'discrete_controlled_ac_branches.arc_id must connect AC topologies (entity_types.is_dc = 0)'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_transformer_circuits_arc_domain_insert BEFORE
INSERT
    ON transformer_circuits
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'transformer_circuits.arc_id must connect AC topologies (entity_types.is_dc = 0)'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_transformer_circuits_arc_domain_update BEFORE
UPDATE
    OF arc_id ON transformer_circuits
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'transformer_circuits.arc_id must connect AC topologies (entity_types.is_dc = 0)'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_two_terminal_hvdc_lines_arc_domain_insert BEFORE
INSERT
    ON two_terminal_hvdc_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'two_terminal_hvdc_lines.arc_id must connect AC topologies (entity_types.is_dc = 0): a point-to-point HVDC line terminates on AC buses and its DC side is internal. Use tmodel_hvdc_lines between DC buses for a multi-terminal DC network.'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_two_terminal_hvdc_lines_arc_domain_update BEFORE
UPDATE
    OF arc_id ON two_terminal_hvdc_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 0
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'two_terminal_hvdc_lines.arc_id must connect AC topologies (entity_types.is_dc = 0): a point-to-point HVDC line terminates on AC buses and its DC side is internal. Use tmodel_hvdc_lines between DC buses for a multi-terminal DC network.'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_tmodel_hvdc_lines_arc_domain_insert BEFORE
INSERT
    ON tmodel_hvdc_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 1
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'tmodel_hvdc_lines.arc_id must connect DC buses (entity_types.is_dc = 1): it is a DC-network branch, reached from the AC side through interconnecting_converters. Use two_terminal_hvdc_lines for point-to-point HVDC between AC buses.'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_tmodel_hvdc_lines_arc_domain_update BEFORE
UPDATE
    OF arc_id ON tmodel_hvdc_lines
    WHEN EXISTS (
        SELECT
            1
        FROM
            arcs a
            JOIN entities e ON e.id IN (a.from_id, a.to_id)
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            a.id = NEW.arc_id
            AND et.is_dc <> 1
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'tmodel_hvdc_lines.arc_id must connect DC buses (entity_types.is_dc = 1): it is a DC-network branch, reached from the AC side through interconnecting_converters. Use two_terminal_hvdc_lines for point-to-point HVDC between AC buses.'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_interconnecting_converters_bus_domain_insert BEFORE
INSERT
    ON interconnecting_converters
    WHEN EXISTS (
        SELECT
            1
        FROM
            entities e
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            (
                e.id = NEW.bus
                AND et.is_dc <> 0
            )
            OR (
                e.id = NEW.dc_bus
                AND et.is_dc <> 1
            )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'interconnecting_converters.bus must be an AC topology (entity_types.is_dc = 0) and dc_bus a DC bus (is_dc = 1)'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_interconnecting_converters_bus_domain_update BEFORE
UPDATE
    OF bus,
    dc_bus ON interconnecting_converters
    WHEN EXISTS (
        SELECT
            1
        FROM
            entities e
            JOIN entity_types et ON et.name = e.entity_type
        WHERE
            (
                e.id = NEW.bus
                AND et.is_dc <> 0
            )
            OR (
                e.id = NEW.dc_bus
                AND et.is_dc <> 1
            )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'interconnecting_converters.bus must be an AC topology (entity_types.is_dc = 0) and dc_bus a DC bus (is_dc = 1)'
    );

END;
