#!/usr/bin/env python3
"""Generate the golden insert fixtures from power-openapi-models' case14 fixtures.

Golden inputs are the SDK fixtures unchanged, COMPONENT_BASE cost curves included.

Expected outputs (canonical dump + insert report per case) are produced by the
Python runtime, the parity oracle for the Julia and TypeScript runtimes.

Everything is written to the gitignored test/fixtures/insert/; fixtures are
generated on the fly, never checked in.

    python3 test/prepare_fixtures.py [--sdk-fixtures-path P] [--check]
"""

import argparse
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
from _common import load_json, write_or_check  # noqa: E402

OUT_DIR = os.path.join(HERE, "fixtures", "insert")
CASES = ("NATURAL_UNITS", "COMPONENT_BASE")
ARTIFACTS = tuple(
    f"case14_{case}.{suffix}"
    for case in CASES
    for suffix in ("json", "dump.json", "report.json")
)


def find_sdk_fixtures():
    """CI checks power-openapi-models out nested; locally it is a sibling."""
    for candidate in (
        os.path.join(REPO_ROOT, "power-openapi-models", "fixtures"),
        os.path.join(REPO_ROOT, "..", "power-openapi-models", "fixtures"),
    ):
        if os.path.isdir(candidate):
            return os.path.normpath(candidate)
    raise FileNotFoundError(
        "power-openapi-models checkout not found (looked nested and as a sibling); "
        "pass --sdk-fixtures-path"
    )


def render(doc):
    return json.dumps(doc, indent=1, sort_keys=True) + "\n"


def _expected_outputs(doc):
    """Run the Python runtime (the parity oracle) on one golden input."""
    sys.path.insert(0, os.path.join(REPO_ROOT, "sdk", "python", "src"))
    import sienna_griddb_tools as griddb
    from canonical_dump import dump

    with tempfile.TemporaryDirectory() as tmp:
        db_path = os.path.join(tmp, "case.sqlite")
        conn = griddb.create_database(db_path)
        report = griddb.insert_document(conn, doc)
        conn.close()
        return dump(db_path), report.to_json()


def _case_artifacts(sdk_fixtures, case):
    src = os.path.join(sdk_fixtures, f"case14_operations.{case}.json")
    doc = load_json(src)
    dump_text, report_text = _expected_outputs(doc)
    prefix = os.path.join(OUT_DIR, f"case14_{case}")
    return {
        prefix + ".json": render(doc),
        prefix + ".dump.json": dump_text,
        prefix + ".report.json": report_text,
    }


def _all_artifacts(sdk_fixtures):
    outputs = {}
    for case in CASES:
        outputs.update(_case_artifacts(sdk_fixtures, case))
    return outputs


def generate(sdk_fixtures):
    """Write all six artifacts. Returns the output directory."""
    write_or_check(_all_artifacts(sdk_fixtures), False, "")
    return OUT_DIR


def ensure_generated(sdk_fixtures=None):
    """Generate only when some artifact is missing. Returns the output directory."""
    if sdk_fixtures is None:
        sdk_fixtures = find_sdk_fixtures()
    missing = any(not os.path.exists(os.path.join(OUT_DIR, name)) for name in ARTIFACTS)
    if missing:
        return generate(sdk_fixtures)
    return OUT_DIR


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sdk-fixtures-path", default=None)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        sdk_fixtures = args.sdk_fixtures_path or find_sdk_fixtures()
    except FileNotFoundError as exc:
        sys.stderr.write(str(exc) + "\n")
        return 1
    return write_or_check(
        _all_artifacts(sdk_fixtures),
        args.check,
        "golden fixtures; run test/prepare_fixtures.py",
    )


if __name__ == "__main__":
    sys.exit(main())
