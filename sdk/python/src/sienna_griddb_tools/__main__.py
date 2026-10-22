"""CLI: python3 -m sienna_griddb_tools build <document.json> <out.sqlite> [--strict]
[--time-series <sidecar.h5>]"""

import argparse
import json
import os
import sys

from .db import create_database
from .insert import insert_document


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sienna_griddb_tools")
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="create a DB and insert one SystemDocument")
    build.add_argument("document")
    build.add_argument("out")
    build.add_argument("--strict", action="store_true")
    build.add_argument(
        "--time-series",
        help="HDF5 sidecar; default: the document's time_series_storage_file beside it",
    )
    args = parser.parse_args(argv)
    with open(args.document, encoding="utf-8") as handle:
        doc = json.load(handle)
    sidecar = args.time_series
    stored = doc.get("time_series_storage_file")
    if sidecar is None and stored:
        beside = os.path.join(os.path.dirname(os.path.abspath(args.document)), stored)
        sidecar = beside if os.path.isfile(beside) else None
    conn = create_database(args.out)
    report = insert_document(conn, doc, strict=args.strict, time_series=sidecar)
    conn.close()
    sys.stdout.write(report.to_json())
    return 0


if __name__ == "__main__":
    sys.exit(main())
