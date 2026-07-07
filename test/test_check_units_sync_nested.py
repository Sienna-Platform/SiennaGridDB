"""Tests for scripts/check_units_sync.py's handling of NESTED x-units (a field
whose unit depends on TWO discriminators, e.g. TwoTerminalVSCLine.dc_setpoint_from
and InterconnectingConverter.dc_setpoint).

These exercise `_l1_discriminated` (and its `_expand_schema_units_map` helper)
directly with in-memory fixtures -- deliberately NOT via schema_map.json/
sql_codegen_map.json, which the real TwoTerminalVSCLine/InterconnectingConverter
components must not be added to (out of scope; would trigger unrelated
generated_schema.sql churn).
"""

import sys

from conftest import SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
from check_units_sync import (  # noqa: E402
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
            "x-units": {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "kV"},
        },
        "DC_VOLTAGE_DROOP": {
            "x-unit-discriminator": "voltage_units",
            "x-units": {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "kV"},
        },
    },
}

ALLOWED_PAIRS = {
    ("ActivePower", "MW"),
    ("Voltage", "pu"),
    ("Voltage", "kV"),
}


def _matching_registry_rows():
    """Registry rows matching NESTED_PROP exactly (the sync-clean case)."""
    return [
        {"discriminator_value": "DC_POWER", "quantity_type": "ActivePower", "unit": "MW"},
        {
            "discriminator_value": "DC_VOLTAGE",
            "discriminator_value_2": "SYSTEM_BASE",
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
            "discriminator_value_2": "SYSTEM_BASE",
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
        ("DC_VOLTAGE", "SYSTEM_BASE"): "pu",
        ("DC_VOLTAGE", "NATURAL_UNITS"): "kV",
        ("DC_VOLTAGE_DROOP", "SYSTEM_BASE"): "pu",
        ("DC_VOLTAGE_DROOP", "NATURAL_UNITS"): "kV",
    }


def test_expand_schema_units_map_flat_unchanged():
    flat = {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "ohm"}
    assert _expand_schema_units_map(flat) == {
        ("SYSTEM_BASE", None): "pu",
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
