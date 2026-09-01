"""Tests for scripts/check_units_sync.py's handling of NESTED x-units (a field
whose unit depends on TWO discriminators). The live example is
InterconnectingConverter.dc_setpoint, discriminated by dc_control and then by
voltage_setpoint_units.

These exercise `_l1_discriminated` (and its `_expand_schema_units_map` helper)
directly with in-memory fixtures -- deliberately NOT via schema_map.json /
sql_codegen_map.json. The table, column and component names passed below are
inert labels used only in the failure messages: the fixture is synthetic and the
assertions never read them, so they are modelled on the old
TwoTerminalVSCLine.dc_setpoint_from field (folded into two_terminal_hvdc_lines,
where the variant-specific setpoints now live in the attributes channel) and left
alone to keep the nested shape unambiguous.
"""

import sys

from conftest import SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
from check_units_sync import (
    Report,
    _expand_schema_units_map,
    _l1_discriminated,
    schema_property_annotation,
)

# Mirrors TwoTerminalVSCLine.json's dc_setpoint_from / InterconnectingConverter.json's
# dc_setpoint: a field whose unit depends on dc_control_from (primary), and, only when
# that selects a voltage mode, on voltage_units (secondary).
NESTED_PROP = {
    "type": "number",
    "x-unit-discriminator": "dc_control_from",
    "x-units": {
        "DC_POWER": "MW",
        "DC_VOLTAGE": {
            "x-unit-discriminator": "voltage_units",
            "x-units": {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "kV"},
        },
        "DC_VOLTAGE_DROOP": {
            "x-unit-discriminator": "voltage_units",
            "x-units": {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "kV"},
        },
    },
}

ALLOWED_PAIRS = {
    ("ActivePower", "MW"),
    ("Voltage", "pu"),
    ("Voltage", "kV"),
}


def _matching_registry_rows():
    """Registry rows matching NESTED_PROP exactly (the sync-clean case).

    Both sides speak the same two-value basis vocabulary (COMPONENT_BASE |
    NATURAL_UNITS), so the registry fixture mirrors the schema map key-for-key.
    """
    return [
        {"discriminator_value": "DC_POWER", "quantity_type": "ActivePower", "unit": "MW"},
        {
            "discriminator_value": "DC_VOLTAGE",
            "discriminator_value_2": "COMPONENT_BASE",
            "quantity_type": "Voltage",
            "unit": "pu",
        },
        {
            "discriminator_value": "DC_VOLTAGE",
            "discriminator_value_2": "NATURAL_UNITS",
            "quantity_type": "Voltage",
            "unit": "kV",
        },
        {
            "discriminator_value": "DC_VOLTAGE_DROOP",
            "discriminator_value_2": "COMPONENT_BASE",
            "quantity_type": "Voltage",
            "unit": "pu",
        },
        {
            "discriminator_value": "DC_VOLTAGE_DROOP",
            "discriminator_value_2": "NATURAL_UNITS",
            "quantity_type": "Voltage",
            "unit": "kV",
        },
    ]


def test_expand_schema_units_map_nested():
    expanded = _expand_schema_units_map(NESTED_PROP["x-units"])
    assert expanded == {
        ("DC_POWER", None): "MW",
        ("DC_VOLTAGE", "COMPONENT_BASE"): "pu",
        ("DC_VOLTAGE", "NATURAL_UNITS"): "kV",
        ("DC_VOLTAGE_DROOP", "COMPONENT_BASE"): "pu",
        ("DC_VOLTAGE_DROOP", "NATURAL_UNITS"): "kV",
    }


def test_expand_schema_units_map_flat_unchanged():
    flat = {"COMPONENT_BASE": "pu", "NATURAL_UNITS": "ohm"}
    assert _expand_schema_units_map(flat) == {
        ("COMPONENT_BASE", None): "pu",
        ("NATURAL_UNITS", None): "ohm",
    }


def test_l1_discriminated_nested_matches_registry():
    ann = schema_property_annotation(NESTED_PROP)
    report = Report()
    warns = _l1_discriminated(
        report,
        "two_terminal_vsc_lines",
        "dc_setpoint_from",
        "TwoTerminalVSCLine",
        ann,
        _matching_registry_rows(),
        ALLOWED_PAIRS,
    )
    assert warns == 0
    assert report.fails == []


def test_l1_discriminated_nested_unit_contradiction():
    """A registry row whose unit disagrees with the nested schema value is a FAIL."""
    ann = schema_property_annotation(NESTED_PROP)
    rows = _matching_registry_rows()
    for row in rows:
        if row["discriminator_value"] == "DC_VOLTAGE_DROOP" and row["discriminator_value_2"] == "NATURAL_UNITS":
            row["unit"] = "V"  # wrong: schema says kV

    report = Report()
    _l1_discriminated(
        report,
        "two_terminal_vsc_lines",
        "dc_setpoint_from",
        "TwoTerminalVSCLine",
        ann,
        rows,
        ALLOWED_PAIRS,
    )
    assert len(report.fails) == 1
    layer, message = report.fails[0]
    assert layer == "L1"
    assert "DC_VOLTAGE_DROOP/NATURAL_UNITS" in message
    assert "schema=kV" in message
    assert "registry=V" in message


def test_l1_discriminated_nested_missing_registry_key_is_fail():
    """Dropping a registry row for one nested (primary, secondary) pair is a key-mismatch FAIL."""
    ann = schema_property_annotation(NESTED_PROP)
    rows = [
        r for r in _matching_registry_rows()
        if not (r["discriminator_value"] == "DC_VOLTAGE_DROOP" and r["discriminator_value_2"] == "NATURAL_UNITS")
    ]

    report = Report()
    _l1_discriminated(
        report,
        "two_terminal_vsc_lines",
        "dc_setpoint_from",
        "TwoTerminalVSCLine",
        ann,
        rows,
        ALLOWED_PAIRS,
    )
    assert len(report.fails) == 1
    layer, message = report.fails[0]
    assert layer == "L1"
    assert "discriminator key mismatch" in message


def test_l1_flat_x_unit_with_registry_superset_warns():
    """A flat schema x-unit matching one registry arm passes, but the arms the
    schema cannot express are surfaced as a WARN -- the representability gap
    that hid the Line r/x/b/g natural-units arm."""
    ann = schema_property_annotation({"type": "number", "x-unit": "pu"})
    rows = [
        {"discriminator_value": "COMPONENT_BASE", "quantity_type": "Resistance", "unit": "pu"},
        {"discriminator_value": "NATURAL_UNITS", "quantity_type": "Resistance", "unit": "ohm"},
    ]
    report = Report()
    warns = _l1_discriminated(
        report, "transmission_lines", "r", "Line", ann, rows,
        {("Resistance", "pu"), ("Resistance", "ohm")},
    )
    assert warns == 1
    assert report.fails == []
    layer, message = report.warns[0]
    assert layer == "L1"
    assert "cannot express" in message
    assert "ohm" in message


def test_l1_flat_x_unit_exact_registry_match_is_silent():
    """A flat schema x-unit whose unit is the registry's only arm is fully clean."""
    ann = schema_property_annotation({"type": "number", "x-unit": "pu"})
    rows = [
        {"discriminator_value": "COMPONENT_BASE", "quantity_type": "Resistance", "unit": "pu"},
    ]
    report = Report()
    warns = _l1_discriminated(
        report, "discrete_controlled_ac_branches", "r", "DiscreteControlledACBranch",
        ann, rows, {("Resistance", "pu")},
    )
    assert warns == 0
    assert report.fails == []
    assert report.warns == []
