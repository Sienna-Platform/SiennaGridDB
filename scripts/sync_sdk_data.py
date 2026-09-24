#!/usr/bin/env python3
"""Copy the insert manifest and the four schema files into each SDK package.

Each SDK ships its own copy so it installs and runs without this repository. The
copies are generated: never edit them; rerun this after regenerating the manifest.

    python3 scripts/sync_sdk_data.py [--check]
"""

import argparse
import os
import sys

from _common import write_or_check

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = (
    "schema.sql",
    "triggers.sql",
    "unit_registry.sql",
    "views.sql",
    "insert_manifest.json",
)
TARGETS = (
    os.path.join("sdk", "python", "src", "sienna_griddb_tools", "data"),
    os.path.join("sdk", "julia", "data"),
    os.path.join("sdk", "typescript", "data"),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = {}
    for name in FILES:
        with open(os.path.join(REPO_ROOT, "schema", name), "rb") as handle:
            source = handle.read()
        for target in TARGETS:
            outputs[os.path.join(REPO_ROOT, target, name)] = source
    return write_or_check(outputs, args.check, "run scripts/sync_sdk_data.py")


if __name__ == "__main__":
    sys.exit(main())
