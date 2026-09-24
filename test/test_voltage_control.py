"""Remote and shared voltage control: the remote regulated bus references on devices and
transformer circuits, and the voltage control groups with their memberships.

Rule numbers follow the remote-control design: R1 (a device never names its own bus as
remote), R2 (every referenced bus or transformer exists), R4 (a transformer names a
regulated bus exactly when it regulates voltage and a side exactly when that bus is off
its arc), R7 (one group per member or converter terminal), R9 (positive weights) and R13
(droop members are generators)."""

import json
import sqlite3

import pytest

from conftest import make_arc, make_bus, make_circuit, make_entity

DEVICE_TABLES_WITH_REMOTE_BUS = [
    "thermal_generators",
    "renewable_generators",
    "hydro_generators",
    "storage_units",
    "synchronous_condensers",
    "sources",
    "switched_admittance",
    "facts_control_devices",
    "interconnecting_converters",
]

GENERATOR_TABLES = [
    "thermal_generators",
    "renewable_generators",
    "hydro_generators",
    "storage_units",
    "synchronous_condensers",
    "sources",
]


def _columns(conn, table):
    return {row[1]: row for row in conn.execute(f"PRAGMA table_info({table})")}


def _thermal(conn, gen_id, bus_id, entity_type="ThermalStandard", **extra):
    make_entity(conn, gen_id, "thermal_generators", entity_type)
    conn.execute("INSERT OR IGNORE INTO prime_mover_types(name) VALUES ('ST')")
    conn.execute("INSERT OR IGNORE INTO fuels(name) VALUES ('NATURAL_GAS')")
    columns = {
        "id": gen_id,
        "name": f"gen_{gen_id}",
        "prime_mover_type": "ST",
        "fuel": "NATURAL_GAS",
        "balancing_topology": bus_id,
        "rating": 1.0,
        "base_power": 100.0,
        "power_units": "COMPONENT_BASE",
        "active_power_limits": '{"min": 0.0, "max": 1.0}',
        "status": "ONLINE",
        **extra,
    }
    conn.execute(
        f"INSERT INTO thermal_generators({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return gen_id


def _shunt(conn, shunt_id, bus_id, **extra):
    make_entity(conn, shunt_id, "switched_admittance", "SwitchedAdmittance")
    columns = {"id": shunt_id, "name": f"shunt_{shunt_id}", "bus": bus_id, **extra}
    conn.execute(
        f"INSERT INTO switched_admittance({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return shunt_id


def _facts(conn, facts_id, bus_id, **extra):
    make_entity(conn, facts_id, "facts_control_devices", "FACTSControlDevice")
    columns = {
        "id": facts_id,
        "name": f"facts_{facts_id}",
        "bus": bus_id,
        "voltage_setpoint": 1.0,
        "power_units": "COMPONENT_BASE",
        "base_power": 100.0,
        **extra,
    }
    conn.execute(
        f"INSERT INTO facts_control_devices({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return facts_id


def _hvdc_line(conn, line_id, arc_id, converter_type, **extra):
    make_entity(conn, line_id, "two_terminal_hvdc_lines", f"TwoTerminal{converter_type}Line")
    columns = {
        "id": line_id,
        "name": f"dc_{line_id}",
        "arc_id": arc_id,
        "converter_type": converter_type,
        "power_units": "COMPONENT_BASE",
        "base_power": 100.0,
        **extra,
    }
    conn.execute(
        f"INSERT INTO two_terminal_hvdc_lines({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return line_id


def _control_circuit(conn, circuit_id, arc_id, **extra):
    make_entity(conn, circuit_id, "transformer_circuits", "TransformerCircuit")
    columns = {
        "id": circuit_id,
        "arc_id": arc_id,
        "power_units": "COMPONENT_BASE",
        "base_power": 100.0,
        **extra,
    }
    conn.execute(
        f"INSERT INTO transformer_circuits({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return circuit_id


def _two_winding(conn, transformer_id, circuit_id):
    make_entity(conn, transformer_id, "two_winding_transformers", "TwoWindingTransformer")
    conn.execute(
        "INSERT INTO two_winding_transformers(id, name, circuit) VALUES (?, ?, ?)",
        (transformer_id, f"xf_{transformer_id}", circuit_id),
    )
    return transformer_id


def _sharing_group(conn, group_id, name=None):
    make_entity(conn, group_id, "voltage_control_groups", "ReactivePowerSharing")
    conn.execute(
        "INSERT INTO voltage_control_groups(id, name, TYPE) VALUES (?, ?, 'ReactivePowerSharing')",
        (group_id, name or f"share_{group_id}"),
    )
    return group_id


def _droop_group(conn, group_id, bus_id, **extra):
    make_entity(conn, group_id, "voltage_control_groups", "VoltageDroopControl")
    columns = {
        "id": group_id,
        "name": f"droop_{group_id}",
        "TYPE": "VoltageDroopControl",
        "regulated_bus_id": bus_id,
        "reactive_power_limits": '{"min": -50.0, "max": 50.0}',
        "deadband_reactive_power": 0.0,
        "voltage_units": "COMPONENT_BASE",
        "deadband_voltage_limits": '{"min": 0.99, "max": 1.01}',
        "voltage_limits": '{"min": 0.95, "max": 1.05}',
        **extra,
    }
    conn.execute(
        f"INSERT INTO voltage_control_groups({', '.join(columns)}) "
        f"VALUES ({', '.join('?' * len(columns))})",
        list(columns.values()),
    )
    return group_id


def _member(conn, group_id, entity_id, weight=1.0, terminal="UNDEFINED"):
    conn.execute(
        "INSERT INTO voltage_control_associations(control_id, entity_id, weight, terminal) "
        "VALUES (?, ?, ?, ?)",
        (group_id, entity_id, weight, terminal),
    )


# Remote regulated bus references on devices


@pytest.mark.parametrize("table", DEVICE_TABLES_WITH_REMOTE_BUS)
def test_device_tables_reference_the_remote_regulated_bus(db, table):
    """The remote bus is a nullable foreign key to the bus table; the plain bus-number
    and percentage columns it replaces are gone."""
    columns = _columns(db, table)
    assert "remote_regulated_bus_id" in columns
    assert columns["remote_regulated_bus_id"][3] == 0, "must be nullable: null means own bus"
    for legacy in ("regulated_bus_number", "remote_bus_control", "rmpct"):
        assert legacy not in columns, f"{table}.{legacy} was replaced"
    foreign_keys = {
        row[3]: row[2] for row in db.execute(f"PRAGMA foreign_key_list({table})")
    }
    assert foreign_keys.get("remote_regulated_bus_id") == "balancing_topologies"


@pytest.mark.parametrize("table", GENERATOR_TABLES)
def test_generator_tables_carry_a_voltage_setpoint(db, table):
    columns = _columns(db, table)
    assert columns["voltage_setpoint"][4] == "1.0"
    assert columns["voltage_setpoint_units"][4] == "'COMPONENT_BASE'"


def test_generator_regulates_its_own_bus_by_default(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    _thermal(fresh_db, 2, bus)
    row = fresh_db.execute(
        "SELECT remote_regulated_bus_id, voltage_setpoint, voltage_setpoint_units "
        "FROM thermal_generators WHERE id = 2"
    ).fetchone()
    assert row == (None, 1.0, "COMPONENT_BASE")


def test_generator_remote_bus_round_trips(fresh_db):
    own = make_bus(fresh_db, 1, "b1")
    remote = make_bus(fresh_db, 2, "b2")
    _thermal(
        fresh_db, 3, own, remote_regulated_bus_id=remote, voltage_setpoint=138.0,
        voltage_setpoint_units="NATURAL_UNITS",
    )
    row = fresh_db.execute(
        "SELECT remote_regulated_bus_id, voltage_setpoint, voltage_setpoint_units "
        "FROM thermal_generators WHERE id = 3"
    ).fetchone()
    assert row == (remote, 138.0, "NATURAL_UNITS")


def test_generator_remote_bus_must_exist(fresh_db):
    """R2: the remote bus is a foreign key, not a free integer."""
    bus = make_bus(fresh_db, 1, "b1")
    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        _thermal(fresh_db, 2, bus, remote_regulated_bus_id=999)


def test_generator_cannot_name_its_own_bus_as_remote(fresh_db):
    """R1: null already means the own bus."""
    bus = make_bus(fresh_db, 1, "b1")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _thermal(fresh_db, 2, bus, remote_regulated_bus_id=bus)


def test_generator_voltage_setpoint_units_is_a_voltage_basis(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _thermal(fresh_db, 2, bus, voltage_setpoint_units="SYSTEM_BASE")


def test_shunt_cannot_name_its_own_bus_as_remote(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    remote = make_bus(fresh_db, 2, "b2")
    _shunt(fresh_db, 3, bus, remote_regulated_bus_id=remote)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _shunt(fresh_db, 4, bus, remote_regulated_bus_id=bus)


def test_facts_cannot_name_its_own_bus_as_remote(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    remote = make_bus(fresh_db, 2, "b2")
    _facts(fresh_db, 3, bus, remote_regulated_bus_id=remote)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _facts(fresh_db, 4, bus, remote_regulated_bus_id=bus)


def test_deleting_a_droop_controllers_bus_removes_the_controller(fresh_db):
    """A droop controller exists for its regulated bus the way a device exists on its bus,
    so that reference cascades instead of clearing."""
    bus = make_bus(fresh_db, 1, "b1")
    _droop_group(fresh_db, 10, bus)
    fresh_db.execute("DELETE FROM balancing_topologies WHERE id = ?", (bus,))
    (count,) = fresh_db.execute(
        "SELECT COUNT(*) FROM voltage_control_groups WHERE id = 10"
    ).fetchone()
    assert count == 0


def test_deleting_a_remote_bus_clears_the_reference(fresh_db):
    """A remote regulated bus is a non-owning reference like settlement_point_id: deleting
    the bus clears it, and null already means the device regulates its own bus."""
    own = make_bus(fresh_db, 1, "b1")
    remote = make_bus(fresh_db, 2, "b2")
    _thermal(fresh_db, 3, own, remote_regulated_bus_id=remote)
    fresh_db.execute("DELETE FROM balancing_topologies WHERE id = ?", (remote,))
    (cleared,) = fresh_db.execute(
        "SELECT remote_regulated_bus_id FROM thermal_generators WHERE id = 3"
    ).fetchone()
    assert cleared is None


# Transformer circuits


def test_transformer_circuit_control_columns(db):
    columns = _columns(db, "transformer_circuits")
    assert "regulated_bus_number" not in columns
    assert columns["regulated_bus_id"][3] == 0
    assert columns["regulated_bus_side"][3] == 1
    assert columns["regulated_bus_side"][4] == "'UNDEFINED'"
    assert columns["load_drop_compensation_r"][4] == "0.0"
    assert columns["load_drop_compensation_x"][4] == "0.0"
    foreign_keys = {
        row[3]: row[2] for row in db.execute("PRAGMA foreign_key_list(transformer_circuits)")
    }
    assert foreign_keys["regulated_bus_id"] == "balancing_topologies"


def test_voltage_objective_requires_a_regulated_bus(fresh_db):
    """R4: a voltage-regulating circuit names its bus; a circuit that regulates no voltage
    names none."""
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _control_circuit(fresh_db, 4, arc, control_objective="VOLTAGE")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _control_circuit(fresh_db, 5, arc, control_objective="VOLTAGE_DISABLED")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _control_circuit(fresh_db, 6, arc, control_objective="ACTIVE_POWER_FLOW", regulated_bus_id=1)
    _control_circuit(fresh_db, 7, arc, control_objective="VOLTAGE", regulated_bus_id=1)
    _control_circuit(fresh_db, 8, arc, control_objective="VOLTAGE_DISABLED", regulated_bus_id=2)
    _control_circuit(fresh_db, 9, arc, control_objective="ACTIVE_POWER_FLOW")


def test_regulated_bus_side_requires_a_regulated_bus(fresh_db):
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _control_circuit(fresh_db, 4, arc, regulated_bus_side="OPPOSITE_WINDING")


def test_regulated_bus_side_is_an_enum(fresh_db):
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    make_bus(fresh_db, 9, "far")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _control_circuit(
            fresh_db, 4, arc, control_objective="VOLTAGE", regulated_bus_id=9,
            regulated_bus_side="PRIMARY",
        )


def test_own_bus_regulation_carries_no_side(fresh_db):
    """R4: when the regulated bus is an end of the circuit's arc the side follows from
    the arc, so storing one is a contradiction waiting to happen."""
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    _control_circuit(fresh_db, 4, arc, control_objective="VOLTAGE", regulated_bus_id=2)
    with pytest.raises(sqlite3.IntegrityError, match="regulated_bus_side"):
        _control_circuit(
            fresh_db, 5, arc, control_objective="VOLTAGE", regulated_bus_id=1,
            regulated_bus_side="CONTROLLING_WINDING",
        )


def test_off_arc_regulation_requires_a_side(fresh_db):
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    far = make_bus(fresh_db, 9, "far")
    with pytest.raises(sqlite3.IntegrityError, match="regulated_bus_side"):
        _control_circuit(fresh_db, 4, arc, control_objective="VOLTAGE", regulated_bus_id=far)
    _control_circuit(
        fresh_db, 5, arc, control_objective="VOLTAGE", regulated_bus_id=far,
        regulated_bus_side="OPPOSITE_WINDING",
    )


def test_regulated_bus_side_is_rechecked_on_update(fresh_db):
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    far = make_bus(fresh_db, 9, "far")
    _control_circuit(fresh_db, 4, arc, control_objective="VOLTAGE", regulated_bus_id=2)
    with pytest.raises(sqlite3.IntegrityError, match="regulated_bus_side"):
        fresh_db.execute(
            "UPDATE transformer_circuits SET regulated_bus_id = ? WHERE id = 4", (far,)
        )


def test_load_drop_compensation_round_trips_as_two_columns(fresh_db):
    arc = make_arc(fresh_db, 3, make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2"))
    _control_circuit(
        fresh_db, 4, arc, control_objective="VOLTAGE", regulated_bus_id=1,
        load_drop_compensation_r=0.01, load_drop_compensation_x=0.02,
    )
    assert fresh_db.execute(
        "SELECT load_drop_compensation_r, load_drop_compensation_x "
        "FROM transformer_circuits WHERE id = 4"
    ).fetchone() == (0.01, 0.02)
    _control_circuit(fresh_db, 5, arc, control_objective="VOLTAGE", regulated_bus_id=1)
    assert fresh_db.execute(
        "SELECT load_drop_compensation_r, load_drop_compensation_x "
        "FROM transformer_circuits WHERE id = 5"
    ).fetchone() == (0.0, 0.0)


# Two-terminal HVDC lines


def test_vsc_line_remote_buses_are_foreign_keys(db):
    foreign_keys = {
        row[3]: row[2] for row in db.execute("PRAGMA foreign_key_list(two_terminal_hvdc_lines)")
    }
    assert foreign_keys["remote_regulated_bus_id_from"] == "balancing_topologies"
    assert foreign_keys["remote_regulated_bus_id_to"] == "balancing_topologies"
    assert foreign_keys["rectifier_commutating_bus_id"] == "balancing_topologies"
    assert foreign_keys["inverter_commutating_bus_id"] == "balancing_topologies"
    assert foreign_keys["rectifier_tap_transformer_id"] == "two_winding_transformers"
    assert foreign_keys["inverter_tap_transformer_id"] == "two_winding_transformers"


def test_vsc_converter_cannot_name_its_own_terminal_bus(fresh_db):
    """R1 per terminal: the from converter's own bus is the arc's from bus."""
    b1, b2, b3 = (make_bus(fresh_db, i, f"b{i}") for i in (1, 2, 3))
    arc = make_arc(fresh_db, 4, b1, b2)
    _hvdc_line(fresh_db, 5, arc, "VSC", remote_regulated_bus_id_from=b3, remote_regulated_bus_id_to=b1)
    with pytest.raises(sqlite3.IntegrityError, match="remote_regulated_bus_id_from"):
        _hvdc_line(fresh_db, 6, arc, "VSC", remote_regulated_bus_id_from=b1)
    with pytest.raises(sqlite3.IntegrityError, match="remote_regulated_bus_id_to"):
        _hvdc_line(fresh_db, 7, arc, "VSC", remote_regulated_bus_id_to=b2)


def test_remote_buses_belong_to_vsc_lines_only(fresh_db):
    b1, b2, b3 = (make_bus(fresh_db, i, f"b{i}") for i in (1, 2, 3))
    arc = make_arc(fresh_db, 4, b1, b2)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _hvdc_line(fresh_db, 5, arc, "LCC", remote_regulated_bus_id_from=b3)


def test_lcc_references_commutating_bus_and_tap_transformer(fresh_db):
    b1, b2, b3, b4 = (make_bus(fresh_db, i, f"b{i}") for i in (1, 2, 3, 4))
    dc_arc = make_arc(fresh_db, 5, b1, b2)
    tap_arc = make_arc(fresh_db, 6, b3, b4)
    transformer = _two_winding(fresh_db, 8, make_circuit(fresh_db, 7, tap_arc))
    _hvdc_line(
        fresh_db, 9, dc_arc, "LCC", rectifier_commutating_bus_id=b3,
        rectifier_tap_transformer_id=transformer,
    )
    row = fresh_db.execute(
        "SELECT rectifier_commutating_bus_id, rectifier_tap_transformer_id, "
        "inverter_commutating_bus_id, inverter_tap_transformer_id "
        "FROM two_terminal_hvdc_lines WHERE id = 9"
    ).fetchone()
    assert row == (b3, transformer, None, None)
    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        _hvdc_line(fresh_db, 10, dc_arc, "LCC", inverter_tap_transformer_id=999)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _hvdc_line(fresh_db, 11, dc_arc, "VSC", rectifier_commutating_bus_id=b3)


# Voltage control groups and memberships


def test_voltage_control_group_tables_exist(db):
    tables = {
        row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    assert {"voltage_control_groups", "voltage_control_associations"} <= tables


def test_sharing_group_has_no_droop_parameters(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    _sharing_group(fresh_db, 2)
    row = fresh_db.execute(
        "SELECT regulated_bus_id, reactive_power_limits, voltage_limits, available "
        "FROM voltage_control_groups WHERE id = 2"
    ).fetchone()
    assert row == (None, None, None, 1)
    make_entity(fresh_db, 3, "voltage_control_groups", "ReactivePowerSharing")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        fresh_db.execute(
            "INSERT INTO voltage_control_groups(id, name, TYPE, regulated_bus_id) "
            "VALUES (3, 'share_3', 'ReactivePowerSharing', ?)",
            (bus,),
        )


def test_droop_group_carries_its_characteristic(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    _droop_group(fresh_db, 2, bus, voltage_units="NATURAL_UNITS", deadband_reactive_power=5.0)
    row = fresh_db.execute(
        "SELECT regulated_bus_id, deadband_reactive_power, voltage_units, "
        "json_extract(voltage_limits, '$.max') FROM voltage_control_groups WHERE id = 2"
    ).fetchone()
    assert row == (bus, 5.0, "NATURAL_UNITS", 1.05)


def test_droop_group_requires_its_regulated_bus_and_limits(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _droop_group(fresh_db, 2, None)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _droop_group(fresh_db, 3, bus, voltage_limits=None)
    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        _droop_group(fresh_db, 4, 999)


def test_group_type_is_one_of_the_two_attributes(fresh_db):
    make_entity(fresh_db, 2, "voltage_control_groups", "PlantAttribute")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        fresh_db.execute(
            "INSERT INTO voltage_control_groups(id, name, TYPE) VALUES (2, 'x', 'PlantAttribute')"
        )


def test_member_weight_is_positive(fresh_db):
    """R9."""
    bus = make_bus(fresh_db, 1, "b1")
    gen = _thermal(fresh_db, 2, bus)
    group = _sharing_group(fresh_db, 3)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _member(fresh_db, group, gen, weight=0.0)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _member(fresh_db, group, gen, weight=-0.5)
    _member(fresh_db, group, gen, weight=0.6)
    (weight,) = fresh_db.execute(
        "SELECT weight FROM voltage_control_associations WHERE entity_id = ?", (gen,)
    ).fetchone()
    assert weight == 0.6


def test_member_weight_defaults_to_one(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    gen = _thermal(fresh_db, 2, bus)
    group = _sharing_group(fresh_db, 3)
    fresh_db.execute(
        "INSERT INTO voltage_control_associations(control_id, entity_id) VALUES (?, ?)",
        (group, gen),
    )
    (weight,) = fresh_db.execute(
        "SELECT weight FROM voltage_control_associations WHERE entity_id = ?", (gen,)
    ).fetchone()
    assert weight == 1.0


def test_device_belongs_to_at_most_one_group(fresh_db):
    """R7 across both kinds of group."""
    bus = make_bus(fresh_db, 1, "b1")
    gen = _thermal(fresh_db, 2, bus)
    sharing = _sharing_group(fresh_db, 3)
    droop = _droop_group(fresh_db, 4, make_bus(fresh_db, 5, "b5"))
    _member(fresh_db, sharing, gen)
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        _member(fresh_db, droop, gen)


def test_each_vsc_terminal_belongs_to_at_most_one_group(fresh_db):
    """R7 per converter: the two terminals of one line may sit in different groups, but
    one terminal joins only once."""
    b1, b2 = make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2")
    line = _hvdc_line(fresh_db, 4, make_arc(fresh_db, 3, b1, b2), "VSC")
    first, second = _sharing_group(fresh_db, 5), _sharing_group(fresh_db, 6)
    _member(fresh_db, first, line, terminal="FROM")
    _member(fresh_db, second, line, terminal="TO")
    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE"):
        _member(fresh_db, second, line, terminal="FROM")


def test_terminal_is_never_null(fresh_db):
    """UNDEFINED, not NULL, is how a single-bus member says it names no converter."""
    b1 = make_bus(fresh_db, 1, "b1")
    gen = _thermal(fresh_db, 3, b1)
    group = _sharing_group(fresh_db, 8)
    with pytest.raises(sqlite3.IntegrityError, match="NOT NULL"):
        _member(fresh_db, group, gen, terminal=None)
    _member(fresh_db, group, gen)
    (terminal,) = fresh_db.execute(
        "SELECT terminal FROM voltage_control_associations WHERE entity_id = 3"
    ).fetchone()
    assert terminal == "UNDEFINED"


def test_terminal_names_a_vsc_converter_only(fresh_db):
    b1, b2 = make_bus(fresh_db, 1, "b1"), make_bus(fresh_db, 2, "b2")
    gen = _thermal(fresh_db, 3, b1)
    line = _hvdc_line(fresh_db, 5, make_arc(fresh_db, 4, b1, b2), "VSC")
    lcc = _hvdc_line(fresh_db, 7, make_arc(fresh_db, 6, b2, b1), "LCC")
    group = _sharing_group(fresh_db, 8)
    with pytest.raises(sqlite3.IntegrityError, match="terminal"):
        _member(fresh_db, group, gen, terminal="FROM")
    with pytest.raises(sqlite3.IntegrityError, match="terminal"):
        _member(fresh_db, group, line)
    with pytest.raises(sqlite3.IntegrityError, match="terminal|member"):
        _member(fresh_db, group, lcc, terminal="FROM")
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _member(fresh_db, group, line, terminal="RECTIFIER")


def test_sharing_members_are_voltage_control_devices(fresh_db):
    """A load or a bus has no reactive power to share."""
    bus = make_bus(fresh_db, 1, "b1")
    make_entity(fresh_db, 2, "loads", "PowerLoad")
    group = _sharing_group(fresh_db, 3)
    with pytest.raises(sqlite3.IntegrityError, match="member"):
        _member(fresh_db, group, 2)
    with pytest.raises(sqlite3.IntegrityError, match="member"):
        _member(fresh_db, group, bus)
    shunt = _shunt(fresh_db, 4, bus)
    facts = _facts(fresh_db, 5, bus)
    _member(fresh_db, group, shunt, weight=2.0)
    _member(fresh_db, group, facts)


def test_droop_members_are_generators_only(fresh_db):
    """R13."""
    bus = make_bus(fresh_db, 1, "b1")
    droop = _droop_group(fresh_db, 2, make_bus(fresh_db, 9, "regulated"))
    gen = _thermal(fresh_db, 3, bus)
    shunt = _shunt(fresh_db, 4, bus)
    facts = _facts(fresh_db, 5, bus)
    _member(fresh_db, droop, gen, weight=0.7)
    with pytest.raises(sqlite3.IntegrityError, match="generator"):
        _member(fresh_db, droop, shunt)
    with pytest.raises(sqlite3.IntegrityError, match="generator"):
        _member(fresh_db, droop, facts)


def test_non_dispatch_renewable_cannot_join_a_droop_controller(fresh_db):
    """The renewable table also holds RenewableNonDispatch, a fixed injection with no
    voltage control, so membership is judged by the entity type, not the table."""
    bus = make_bus(fresh_db, 1, "b1")
    droop = _droop_group(fresh_db, 2, make_bus(fresh_db, 9, "regulated"))
    make_entity(fresh_db, 3, "renewable_generators", "RenewableNonDispatch")
    make_entity(fresh_db, 4, "renewable_generators", "RenewableDispatch")
    with pytest.raises(sqlite3.IntegrityError, match="generator"):
        _member(fresh_db, droop, 3)
    _member(fresh_db, droop, 4)


def test_membership_is_rechecked_on_update(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    droop = _droop_group(fresh_db, 2, make_bus(fresh_db, 9, "regulated"))
    gen = _thermal(fresh_db, 3, bus)
    shunt = _shunt(fresh_db, 4, bus)
    _member(fresh_db, droop, gen)
    with pytest.raises(sqlite3.IntegrityError, match="generator"):
        fresh_db.execute(
            "UPDATE voltage_control_associations SET entity_id = ? WHERE entity_id = ?",
            (shunt, gen),
        )


def test_memberships_follow_their_group_and_member(fresh_db):
    bus = make_bus(fresh_db, 1, "b1")
    first = _thermal(fresh_db, 2, bus)
    second = _thermal(fresh_db, 3, bus)
    group = _sharing_group(fresh_db, 4)
    _member(fresh_db, group, first)
    _member(fresh_db, group, second)
    fresh_db.execute("DELETE FROM thermal_generators WHERE id = ?", (first,))
    remaining = [
        row[0]
        for row in fresh_db.execute(
            "SELECT entity_id FROM voltage_control_associations ORDER BY entity_id"
        )
    ]
    assert remaining == [second]
    fresh_db.execute("DELETE FROM voltage_control_groups WHERE id = ?", (group,))
    assert fresh_db.execute("SELECT count(*) FROM voltage_control_associations").fetchone() == (0,)
    assert fresh_db.execute("SELECT count(*) FROM entities WHERE id = ?", (group,)).fetchone() == (0,)


def test_group_row_requires_its_entity(fresh_db):
    with pytest.raises(sqlite3.IntegrityError, match="voltage_control_groups"):
        fresh_db.execute(
            "INSERT INTO voltage_control_groups(id, name, TYPE) VALUES (7, 'orphan', 'ReactivePowerSharing')"
        )


def test_schema_version_bumped_for_voltage_control(db):
    (version,) = db.execute("PRAGMA user_version").fetchone()
    assert version >= 2
