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
        'planning_regions.id must exist in entities with entity_table planning_regions before insert'
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
        'balancing_topologies.id must exist in entities with entity_table balancing_topologies before insert'
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
        'arcs.id must exist in entities with entity_table arcs before insert'
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
        'transmission_lines.id must exist in entities with entity_table transmission_lines before insert'
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
        'discrete_controlled_ac_branches.id must exist in entities with entity_table discrete_controlled_ac_branches before insert'
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
        'transformer_circuits.id must exist in entities with entity_table transformer_circuits before insert'
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
        'two_winding_transformers.id must exist in entities with entity_table two_winding_transformers before insert'
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
        'three_winding_transformers.id must exist in entities with entity_table three_winding_transformers before insert'
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
        'transmission_interchanges.id must exist in entities with entity_table transmission_interchanges before insert'
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
        'thermal_generators.id must exist in entities with entity_table thermal_generators before insert'
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
        'renewable_generators.id must exist in entities with entity_table renewable_generators before insert'
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
        'hydro_generators.id must exist in entities with entity_table hydro_generators before insert'
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
        'storage_units.id must exist in entities with entity_table storage_units before insert'
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
        'hydro_reservoirs.id must exist in entities with entity_table hydro_reservoirs before insert'
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
        'supply_technologies.id must exist in entities with entity_table supply_technologies before insert'
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
        'transport_technologies.id must exist in entities with entity_table transport_technologies before insert'
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
        'storage_technologies.id must exist in entities with entity_table storage_technologies before insert'
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
        'demand_technologies.id must exist in entities with entity_table demand_technologies before insert'
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
        'supplemental_attributes.id must exist in entities with entity_table supplemental_attributes before insert'
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
        'plants.id must exist in entities with entity_table plants before insert'
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
        'loads.id must exist in entities with entity_table loads before insert'
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
        'fixed_admittance.id must exist in entities with entity_table fixed_admittance before insert'
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
        'switched_admittance.id must exist in entities with entity_table switched_admittance before insert'
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
        'sources.id must exist in entities with entity_table sources before insert'
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
        'two_terminal_hvdc_lines.id must exist in entities with entity_table two_terminal_hvdc_lines before insert'
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
        'synchronous_condensers.id must exist in entities with entity_table synchronous_condensers before insert'
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
        'tmodel_hvdc_lines.id must exist in entities with entity_table tmodel_hvdc_lines before insert'
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
        'facts_control_devices.id must exist in entities with entity_table facts_control_devices before insert'
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
        'interconnecting_converters.id must exist in entities with entity_table interconnecting_converters before insert'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_trading_hubs_entity_exists BEFORE
INSERT
    ON trading_hubs
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'trading_hubs'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'trading_hubs.id must exist in entities with entity_table trading_hubs before insert'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_virtual_participants_entity_exists BEFORE
INSERT
    ON virtual_participants
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'virtual_participants'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'virtual_participants.id must exist in entities with entity_table virtual_participants before insert'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_point_to_point_bids_entity_exists BEFORE
INSERT
    ON point_to_point_bids
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            entities
        WHERE
            id = NEW.id
            AND entity_table = 'point_to_point_bids'
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'point_to_point_bids.id must exist in entities with entity_table point_to_point_bids before insert'
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
        ) THEN RAISE(ABORT, 'arcs.from_id must reference an existing entity')
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.to_id
        ) THEN RAISE(ABORT, 'arcs.to_id must reference an existing entity')
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
            'arcs.from_id must reference a topology entity (entity_types.is_topology = 1)'
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
            'arcs.to_id must reference a topology entity (entity_types.is_topology = 1)'
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
        ) THEN RAISE(ABORT, 'arcs.from_id must reference an existing entity')
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                entities
            WHERE
                id = NEW.to_id
        ) THEN RAISE(ABORT, 'arcs.to_id must reference an existing entity')
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
            'arcs.from_id must reference a topology entity (entity_types.is_topology = 1)'
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
            'arcs.to_id must reference a topology entity (entity_types.is_topology = 1)'
        )
    END;

END;

-- A turbine (hydro_generators or storage_units) may draw from at most one upstream reservoir.
CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_upstream_reservoir BEFORE
INSERT
    ON hydro_reservoir_connections
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
        ) THEN RAISE(
            ABORT,
            'A turbine may have at most one upstream reservoir.'
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
            'A turbine may have at most one upstream reservoir.'
        )
    END;

END;

-- A turbine (hydro_generators or storage_units) may feed at most one downstream reservoir.
CREATE TRIGGER IF NOT EXISTS enforce_turbine_single_downstream_reservoir BEFORE
INSERT
    ON hydro_reservoir_connections
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
        ) THEN RAISE(
            ABORT,
            'A turbine may have at most one downstream reservoir.'
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
            'A turbine may have at most one downstream reservoir.'
        )
    END;

END;

-- Deleting a child row also deletes its entities row; entities has no cascading FK of its own.
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

CREATE TRIGGER IF NOT EXISTS delete_trading_hubs_entity
AFTER
    DELETE ON trading_hubs FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_virtual_participants_entity
AFTER
    DELETE ON virtual_participants FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

CREATE TRIGGER IF NOT EXISTS delete_point_to_point_bids_entity
AFTER
    DELETE ON point_to_point_bids FOR EACH ROW
BEGIN
DELETE FROM
    entities
WHERE
    id = OLD.id;

END;

-- =============================================================================
-- Unit Registry Immutability Triggers
-- UPDATE and DELETE are always blocked; INSERT is blocked once the registry is
-- sealed (a checksum row exists).
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS prevent_unit_management_metadata_update BEFORE
UPDATE
    ON unit_management_metadata
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_management_metadata is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_management_metadata_delete BEFORE DELETE ON unit_management_metadata
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_management_metadata is immutable outside scripts/generate_unit_registry.py.'
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
        'unit_management_metadata is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_update BEFORE
UPDATE
    ON quantity_types
BEGIN
SELECT
    RAISE(
        ABORT,
        'quantity_types is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_quantity_types_delete BEFORE DELETE ON quantity_types
BEGIN
SELECT
    RAISE(
        ABORT,
        'quantity_types is immutable outside scripts/generate_unit_registry.py.'
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
        'quantity_types is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_update BEFORE
UPDATE
    ON unit_conventions
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_conventions is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_conventions_delete BEFORE DELETE ON unit_conventions
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_conventions is immutable outside scripts/generate_unit_registry.py.'
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
        'unit_conventions is immutable outside scripts/generate_unit_registry.py.'
    );

END;

-- allowed_units is the registry vocabulary table, sealed the same way.
CREATE TRIGGER IF NOT EXISTS prevent_allowed_units_update BEFORE
UPDATE
    ON allowed_units
BEGIN
SELECT
    RAISE(
        ABORT,
        'allowed_units is immutable outside scripts/generate_unit_registry.py.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_allowed_units_delete BEFORE DELETE ON allowed_units
BEGIN
SELECT
    RAISE(
        ABORT,
        'allowed_units is immutable outside scripts/generate_unit_registry.py.'
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
        'allowed_units is immutable outside scripts/generate_unit_registry.py.'
    );

END;

-- unit_basis_rules (registry-linked): UPDATE and DELETE are blocked
-- unconditionally; INSERT is blocked only after the registry is sealed.
CREATE TRIGGER IF NOT EXISTS prevent_unit_basis_rules_update BEFORE
UPDATE
    ON unit_basis_rules
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_basis_rules is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_basis_rules_delete BEFORE DELETE ON unit_basis_rules
BEGIN
SELECT
    RAISE(
        ABORT,
        'unit_basis_rules is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

CREATE TRIGGER IF NOT EXISTS prevent_unit_basis_rules_insert BEFORE
INSERT
    ON unit_basis_rules
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
        'unit_basis_rules is protected against ad-hoc edits. Regenerate the registry via scripts/generate_unit_registry.py and rebuild the database.'
    );

END;

-- =============================================================================
-- Time Series Association Unit Validation Triggers (registry-linked)
-- quantity_kind is deliberately free-form (mirroring infrastore's catalog):
-- composite economic quantities ($/MWh, MMBtu/MWh) must not require a schema
-- migration. But a row that uses a REGISTERED quantity-type name must pair it
-- with a registered unit -- a typo'd or contradictory unit on a known quantity
-- is a defect, not a new vocabulary.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_time_series_associations_units_insert BEFORE
INSERT
    ON time_series_associations
    WHEN NEW.quantity_kind IS NOT NULL
    AND EXISTS (
        SELECT
            1
        FROM
            quantity_types
        WHERE
            name = NEW.quantity_kind
    )
    AND (
        NEW.units IS NULL
        OR NOT EXISTS (
            SELECT
                1
            FROM
                allowed_units au
            WHERE
                au.quantity_type = NEW.quantity_kind
                AND au.unit = NEW.units
        )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations rows using a registered quantity_kind must carry a units value matching a registered (quantity_type, unit) pair in allowed_units.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_time_series_associations_units_update BEFORE
UPDATE
    ON time_series_associations
    WHEN NEW.quantity_kind IS NOT NULL
    AND EXISTS (
        SELECT
            1
        FROM
            quantity_types
        WHERE
            name = NEW.quantity_kind
    )
    AND (
        NEW.units IS NULL
        OR NOT EXISTS (
            SELECT
                1
            FROM
                allowed_units au
            WHERE
                au.quantity_type = NEW.quantity_kind
                AND au.unit = NEW.units
        )
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations rows using a registered quantity_kind must carry a units value matching a registered (quantity_type, unit) pair in allowed_units.'
    );

END;

-- =============================================================================
-- Time Series Association Owner-Domain Triggers
-- owner_id references entities (both categories share the entities id-space
-- here, unlike infrastore's independent streams), but a 'SupplementalAttribute'
-- owner must actually be a supplemental attribute.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS enforce_time_series_associations_owner_domain BEFORE
INSERT
    ON time_series_associations
    WHEN NEW.owner_category = 'SupplementalAttribute'
    AND NOT EXISTS (
        SELECT
            1
        FROM
            supplemental_attributes
        WHERE
            id = NEW.owner_id
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations.owner_id must exist in supplemental_attributes when owner_category = ''SupplementalAttribute''.'
    );

END;

CREATE TRIGGER IF NOT EXISTS enforce_time_series_associations_owner_domain_update BEFORE
UPDATE
    OF owner_id,
    owner_category ON time_series_associations
    WHEN NEW.owner_category = 'SupplementalAttribute'
    AND NOT EXISTS (
        SELECT
            1
        FROM
            supplemental_attributes
        WHERE
            id = NEW.owner_id
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'time_series_associations.owner_id must exist in supplemental_attributes when owner_category = ''SupplementalAttribute''.'
    );

END;

-- =============================================================================
-- Attribute Unit Validation Triggers
-- A known attribute name must use its registered unit and quantity_type from
-- unit_conventions. An unknown attribute with a numeric or structured value
-- needs a vocabulary-valid pair from allowed_units, unless attribute_identifiers
-- lists it as a non-physical identifier. Boolean, text, and null values are exempt.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_insert BEFORE
INSERT
    ON attributes
BEGIN
SELECT
    CASE
        -- Polymorphic attribute names have multiple registered rows; matching any one is enough.
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
            'attributes.name is a known name and must use its registered unit and quantity_type.'
        )
        -- A numeric identifier (e.g. a bus number) isn't a physical quantity;
        -- attribute_identifiers exempts it from needing a unit.
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
                attribute_identifiers ai
            WHERE
                LOWER(ai.TYPE) = LOWER(NEW.TYPE)
                AND LOWER(ai.name) = LOWER(NEW.name)
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
            'attributes.value, when numeric or structured, needs a vocabulary-valid unit and quantity_type from allowed_units (use unit=1, quantity_type=Dimensionless when none applies).'
        )
        -- An exempt identifier does not have to carry a unit, but if it carries
        -- one anyway the pair is still held to the vocabulary: exemption relieves
        -- the requirement, it does not license an unregistered unit.
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND EXISTS (
            SELECT
                1
            FROM
                attribute_identifiers ai
            WHERE
                LOWER(ai.TYPE) = LOWER(NEW.TYPE)
                AND LOWER(ai.name) = LOWER(NEW.name)
        )
        AND (
            NEW.unit IS NOT NULL
            OR NEW.quantity_type IS NOT NULL
        )
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
            'attributes.name is an exempt identifier, so a unit is optional -- but a supplied unit and quantity_type must still be a registered allowed_units pair.'
        )
    END;

END;

CREATE TRIGGER IF NOT EXISTS validate_attribute_unit_update BEFORE
UPDATE
    ON attributes
BEGIN
SELECT
    CASE
        -- Polymorphic attribute names have multiple registered rows; matching any one is enough.
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
            'attributes.name is a known name and must use its registered unit and quantity_type.'
        )
        -- A numeric identifier (e.g. a bus number) isn't a physical quantity;
        -- attribute_identifiers exempts it from needing a unit.
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
                attribute_identifiers ai
            WHERE
                LOWER(ai.TYPE) = LOWER(NEW.TYPE)
                AND LOWER(ai.name) = LOWER(NEW.name)
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
            'attributes.value, when numeric or structured, needs a vocabulary-valid unit and quantity_type from allowed_units (use unit=1, quantity_type=Dimensionless when none applies).'
        )
        -- An exempt identifier does not have to carry a unit, but if it carries
        -- one anyway the pair is still held to the vocabulary: exemption relieves
        -- the requirement, it does not license an unregistered unit.
        WHEN NOT EXISTS (
            SELECT
                1
            FROM
                unit_conventions
            WHERE
                table_name = 'attributes'
                AND LOWER(column_name) = LOWER(NEW.name)
        )
        AND EXISTS (
            SELECT
                1
            FROM
                attribute_identifiers ai
            WHERE
                LOWER(ai.TYPE) = LOWER(NEW.TYPE)
                AND LOWER(ai.name) = LOWER(NEW.name)
        )
        AND (
            NEW.unit IS NOT NULL
            OR NEW.quantity_type IS NOT NULL
        )
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
            'attributes.name is an exempt identifier, so a unit is optional -- but a supplied unit and quantity_type must still be a registered allowed_units pair.'
        )
    END;

END;

-- =============================================================================
-- Time Series Data Validation Triggers
-- Dense values are located by uri: each static_time_series row must belong to
-- an array some association row declares via uri. Ingest order is therefore
-- association first, values second -- an orphan array is a loader bug surfaced
-- loudly, not data to keep.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS check_static_time_series_association_exists BEFORE
INSERT
    ON static_time_series
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations
        WHERE
            uri = NEW.uri
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'static_time_series.uri must exist in time_series_associations before insertion.'
    );

END;

CREATE TRIGGER IF NOT EXISTS check_static_time_series_association_exists_update BEFORE
UPDATE
    OF uri ON static_time_series
    WHEN NOT EXISTS (
        SELECT
            1
        FROM
            time_series_associations
        WHERE
            uri = NEW.uri
    )
BEGIN
SELECT
    RAISE(
        ABORT,
        'static_time_series.uri must exist in time_series_associations before insertion.'
    );

END;

-- =============================================================================
-- Cost Payload Power-Units Guard
-- column_conventions.json registers cost curves in natural units only, with no
-- power_units discriminator, so only NATURAL_UNITS passes; a NULL or absent
-- power_units passes too, since the payload may be a plain curve. Keep this
-- trigger set in sync with column_conventions.json's production_cost /
-- operation_cost* rows.
-- =============================================================================
CREATE TRIGGER IF NOT EXISTS validate_thermal_generators_cost_units_insert BEFORE
INSERT
    ON thermal_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_thermal_generators_cost_units_update BEFORE
UPDATE
    ON thermal_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_renewable_generators_cost_units_insert BEFORE
INSERT
    ON renewable_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.curtailment_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_renewable_generators_cost_units_update BEFORE
UPDATE
    ON renewable_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.curtailment_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_generators_cost_units_insert BEFORE
INSERT
    ON hydro_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_generators_cost_units_update BEFORE
UPDATE
    ON hydro_generators
    WHEN json_extract(NEW.production_cost, '$.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_units_cost_units_insert BEFORE
INSERT
    ON storage_units
    WHEN json_extract(NEW.operation_cost, '$.charge_variable_cost.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.discharge_variable_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_units_cost_units_update BEFORE
UPDATE
    ON storage_units
    WHEN json_extract(NEW.operation_cost, '$.charge_variable_cost.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.discharge_variable_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_reservoirs_cost_units_insert BEFORE
INSERT
    ON hydro_reservoirs
    WHEN json_extract(NEW.operation_cost, '$.variable.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_hydro_reservoirs_cost_units_update BEFORE
UPDATE
    ON hydro_reservoirs
    WHEN json_extract(NEW.operation_cost, '$.variable.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_supply_technologies_cost_units_insert BEFORE
INSERT
    ON supply_technologies
    WHEN json_extract(NEW.operation_costs, '$.variable.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_supply_technologies_cost_units_update BEFORE
UPDATE
    ON supply_technologies
    WHEN json_extract(NEW.operation_costs, '$.variable.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_technologies_cost_units_insert BEFORE
INSERT
    ON storage_technologies
    WHEN json_extract(NEW.operation_costs, '$.charge_variable_cost.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_costs, '$.discharge_variable_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_storage_technologies_cost_units_update BEFORE
UPDATE
    ON storage_technologies
    WHEN json_extract(NEW.operation_costs, '$.charge_variable_cost.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_costs, '$.discharge_variable_cost.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

-- sources' ImportExportCost payload guards import_offer_curves and
-- export_offer_curves, not a `variable` curve.
CREATE TRIGGER IF NOT EXISTS validate_sources_cost_units_insert BEFORE
INSERT
    ON sources
    WHEN json_extract(NEW.operation_cost, '$.import_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.export_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_sources_cost_units_update BEFORE
UPDATE
    ON sources
    WHEN json_extract(NEW.operation_cost, '$.import_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.export_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

-- virtual_participants' MarketBidCost payload guards incremental_offer_curves
-- and decremental_offer_curves, mirroring the sources guard above.
CREATE TRIGGER IF NOT EXISTS validate_virtual_participants_cost_units_insert BEFORE
INSERT
    ON virtual_participants
    WHEN json_extract(NEW.operation_cost, '$.incremental_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.decremental_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_virtual_participants_cost_units_update BEFORE
UPDATE
    ON virtual_participants
    WHEN json_extract(NEW.operation_cost, '$.incremental_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.operation_cost, '$.decremental_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

-- point_to_point_bids.spread_bid has the same incremental/decremental
-- offer-curve shape as virtual_participants.operation_cost, guarded the same way.
CREATE TRIGGER IF NOT EXISTS validate_point_to_point_bids_cost_units_insert BEFORE
INSERT
    ON point_to_point_bids
    WHEN json_extract(NEW.spread_bid, '$.incremental_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.spread_bid, '$.decremental_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

CREATE TRIGGER IF NOT EXISTS validate_point_to_point_bids_cost_units_update BEFORE
UPDATE
    ON point_to_point_bids
    WHEN json_extract(NEW.spread_bid, '$.incremental_offer_curves.power_units') <> 'NATURAL_UNITS'
    OR json_extract(NEW.spread_bid, '$.decremental_offer_curves.power_units') <> 'NATURAL_UNITS'
BEGIN
SELECT
    RAISE(
        ABORT,
        'cost payload power_units must be NATURAL_UNITS.'
    );

END;

-- =============================================================================
-- EmissionsData supplemental-attribute payload guard
-- For TYPE = 'EmissionsData', pollutant/basis/energy_unit must be present and
-- use the schema's enum values; energy_unit is required only for the basis it
-- matches (FUEL_INPUT: MMBTU or GJ; POWER_OUTPUT: MWH), via NULL-safe IS NOT
-- checks. mass_unit is optional and passes when absent.
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
-- tmodel_hvdc_lines must run between DC buses (is_dc = 1); every AC branch,
-- including point-to-point two_terminal_hvdc_lines, must run between AC
-- topologies (is_dc = 0). A foreign key can't express this, since arcs
-- reference entities generically and the domain lives on entity_types.
-- transmission_interchanges, a market construct rather than a physical
-- branch, is not checked here.
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
        'two_terminal_hvdc_lines.arc_id must connect AC topologies (entity_types.is_dc = 0); use tmodel_hvdc_lines for a DC-network branch instead.'
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
        'two_terminal_hvdc_lines.arc_id must connect AC topologies (entity_types.is_dc = 0); use tmodel_hvdc_lines for a DC-network branch instead.'
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
        'tmodel_hvdc_lines.arc_id must connect DC buses (entity_types.is_dc = 1); use two_terminal_hvdc_lines for point-to-point HVDC instead.'
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
        'tmodel_hvdc_lines.arc_id must connect DC buses (entity_types.is_dc = 1); use two_terminal_hvdc_lines for point-to-point HVDC instead.'
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
