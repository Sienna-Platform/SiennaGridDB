#!/usr/bin/env python3
"""A small SystemDocument plus HDF5 sidecar covering every storable time series shape.

Built with infrastore itself: one array shared by two owners and by both their
SingleTimeSeries and DeterministicSingleTimeSeries, feature maps of every kind,
composite elements, a Deterministic forecast, one all-zero array read as both a
scalar forecast and a composite series, a supplemental-attribute owner, and the
rows GridDB reports unsupported (a NonSequentialTimeSeries, an owner type with no
table, an i64 series).

    python3 test/time_series_case.py OUT_DIR

writes case.json and case.h5, plus the Python runtime's case.dump.json and
case.report.json (the parity oracle for the other runtimes). Needs infrastore.
"""

import datetime
import json
import os
import sys

import infrastore
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

T0 = datetime.datetime(2026, 1, 1)
SHARED = [1.0, 2.0, 3.0]
LINEAR = [{"proportional": float(i), "constant": 2.0} for i in range(3)]
STEPS = [{"x": [0.0, 5.0, 9.0], "y": [1.0, 2.0]}, {"x": [0.0, 4.0], "y": [3.0]}] * 2
STEPS = STEPS[:3]
TUPLES = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]
FORECAST = [[1.0, 10.0], [2.0, 20.0], [3.0, 30.0]]  # (horizon steps, windows)
MIXED = {"flag": True, "n": -3, "w": 1.0, "x": 0.5, "zone": "north"}
UNSTORED_OWNER = "AGC"  # a component type no GridDB table maps


def _sts(data, name, **kwargs):
    return infrastore.SingleTimeSeries(T0, "PT1H", np.array(data), name, **kwargs)


def build(out_dir):
    """Write case.json and its sidecar case.h5 into out_dir; return the JSON path."""
    comp = infrastore.OwnerCategory.Component
    attr = infrastore.OwnerCategory.SupplementalAttribute
    store = infrastore.Store.create(in_memory=True)
    add = store.add_time_series
    add(1, "Area", comp, _sts(SHARED, "max_active_power", unit_system="component_base"))
    add(2, "Area", comp, _sts(SHARED, "max_active_power"))
    add(1, "Area", comp, _sts([4.0, 5.0, 6.0], "load"), features={"bus": 7})
    linear = infrastore.encode_element_values(LINEAR, "linear_function")
    add(1, "Area", comp, _sts(linear, "linear", element_type="linear_function"))
    steps = infrastore.encode_element_values(STEPS, "piecewise_step")
    add(1, "Area", comp, _sts(steps, "steps", element_type="piecewise_step"))
    tuples = _sts(TUPLES, "tuples", element_type="tuple(3,f64)")
    add(1, "Area", comp, tuples, features=MIXED)
    zero_linear = [{"proportional": 0.0, "constant": 0.0}] * 3
    zeros = infrastore.encode_element_values(zero_linear, "linear_function")
    add(2, "Area", comp, _sts(zeros, "zero_linear", element_type="linear_function"))
    add(1, "Area", comp, _sts(np.array([1, 2, 3], dtype=np.int64), "counts"))
    add(3, "GeographicInfo", attr, _sts([7.0, 8.0, 9.0], "geo"))
    add(9, UNSTORED_OWNER, comp, _sts([5.0, 5.0, 5.0], "limit"))
    store.transform_single_time_series("PT3H", "PT3H")
    forecast = infrastore.Deterministic(
        T0, "PT1H", "PT3H", "PT1H", 2, np.array(FORECAST), "forecast"
    )
    add(2, "Area", comp, forecast)
    # Byte-identical to zero_linear's array, so both name one uri
    zero = infrastore.Deterministic(T0, "PT1H", "PT3H", "PT1H", 2, np.zeros((3, 2)), "zero")
    add(1, "Area", comp, zero)
    stamps = [T0, T0 + datetime.timedelta(hours=5)]
    add(
        1,
        "Area",
        comp,
        infrastore.NonSequentialTimeSeries(stamps, np.array([1.0, 2.0]), "ns"),
    )
    store.persist_arrays_to(os.path.join(out_dir, "case.h5"))
    rows = json.loads(store.export_time_series_associations_openapi())
    store.close()
    for row in rows:
        if row.get("unit_system"):
            row["unit_system"] = row[
                "unit_system"
            ].upper()  # the wire's UnitSystem spelling
    area = {"base_power": 100.0, "power_units": "NATURAL_UNITS"}
    agc = {"available": True, "bias": 1.0, "K_p": 1.0, "K_i": 1.0, "K_d": 1.0, "delta_t": 1.0}
    doc = {
        "components": {
            "Area": [{"id": 1, "name": "a1", **area}, {"id": 2, "name": "a2", **area}],
            UNSTORED_OWNER: [{"id": 9, "name": "i", **agc}],
        },
        "supplemental_attributes": [{"id": 3, "geo_json": {"type": "Point"}}],
        "supplemental_attribute_associations": [
            {
                "component_id": 1,
                "component_type": "Area",
                "attribute_id": 3,
                "attribute_type": "GeographicInfo",
            }
        ],
        "time_series_associations": rows,
        "time_series_storage_file": "case.h5",
        # Empty, so the SDK models decode the document too
        "combined_cycle_associations": [],
        "ext": {},
        "plant_associations": [],
        "service_associations": [],
        "trading_hub_associations": [],
    }
    path = os.path.join(out_dir, "case.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=1, sort_keys=True)
    return path


def expected_outputs(path, db_path):
    """Insert the case with the Python runtime; return (dump text, report text)."""
    sys.path.insert(0, os.path.join(REPO_ROOT, "sdk", "python", "src"))
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    import sienna_griddb_tools as griddb
    from canonical_dump import dump

    conn = griddb.create_database(db_path)
    report = griddb.insert_document(conn, path)
    conn.close()
    return dump(db_path), report.to_json()


def main():
    out_dir = sys.argv[1]
    path = build(out_dir)
    dump_text, report_text = expected_outputs(path, os.path.join(out_dir, "case.sqlite"))
    for name, text in (("case.dump.json", dump_text), ("case.report.json", report_text)):
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
