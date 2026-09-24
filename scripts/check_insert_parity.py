#!/usr/bin/env python3
"""Fail unless a runtime-built DB and its printed report match the golden outputs.

    python3 scripts/check_insert_parity.py --db D --report R \
        --expected-dump E --expected-report F
"""

import argparse
import json
import sys

from _common import load_json
from canonical_dump import dump


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--expected-dump", required=True)
    parser.add_argument("--expected-report", required=True)
    args = parser.parse_args()
    ok = True
    actual = json.loads(dump(args.db))
    expected = load_json(args.expected_dump)
    for table in sorted(set(actual) | set(expected)):
        if actual.get(table) != expected.get(table):
            sys.stderr.write(f"dump mismatch in table {table}\n")
            ok = False
    report = load_json(args.report)
    expected_report = load_json(args.expected_report)
    for key in ("inserted", "skipped_fields", "unsupported"):
        if report.get(key) != expected_report.get(key):
            sys.stderr.write(f"report mismatch in {key}\n")
            ok = False
    if ok:
        sys.stdout.write(f"parity OK: {args.db}\n")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
