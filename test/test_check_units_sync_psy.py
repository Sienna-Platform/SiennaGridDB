"""check_units_sync.py L3(d): a field PSY converts by the power base, annotated with
another unit, fails only when GridDB stores it under that unit."""

import sys

import pytest
from conftest import SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
from check_units_sync import Report, layer3

SCHEMA_MAP = {"tables": {"converters": [{"component": "Conv", "file": "Conv.json", "is_psy": True}]}}
DOC = {"properties": {"dc_current": {"type": "number", "x-unit": "A"}}}
PSY = {"Conv": {"dc_current": {"needs_conversion": True, "conversion_unit": ":mva"}}}


@pytest.mark.parametrize("stored,fails,warns", [({"Conv": {"dc_current"}}, 1, 0), ({}, 0, 1)])
def test_power_base_field_under_another_unit(stored, fails, warns):
    report = Report()
    layer3(report, SCHEMA_MAP, "unused", PSY, {"Conv.json": DOC}, stored)
    assert (len(report.fails), len(report.warns)) == (fails, warns)
