#!/usr/bin/env python3
"""Write schema/insert_manifest.json and schema/insert_gaps.json.

    python3 scripts/generate_insert_manifest.py [--schemas-path P] [--check]

--check regenerates in memory and exits 1, naming the stale files, when either
checked-in file differs. CI runs it; never hand-edit either output.
"""

import argparse
import os
import sys

from _common import write_or_check
from generate_sql_schema import DEFAULT_SCHEMAS_PATH
from insert_manifest import SCHEMA_DIR, build_manifest, gap_report, render


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--schemas-path", default=DEFAULT_SCHEMAS_PATH)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    manifest = build_manifest(args.schemas_path)
    outputs = {
        os.path.join(SCHEMA_DIR, "insert_manifest.json"): render(manifest),
        os.path.join(SCHEMA_DIR, "insert_gaps.json"): render(gap_report(manifest)),
    }
    return write_or_check(outputs, args.check, "run scripts/generate_insert_manifest.py")


if __name__ == "__main__":
    sys.exit(main())
