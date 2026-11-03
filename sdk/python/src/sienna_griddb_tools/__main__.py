"""CLI: python3 -m sienna_griddb_tools build <document.json | bundle dir> <out.sqlite>
[--strict] [--time-series <sidecar.h5>]"""

import argparse
import sys

from .db import create_database
from .insert import insert_file


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sienna_griddb_tools")
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser(
        "build",
        help="create a DB and insert one document; a portfolio's base system goes in first",
    )
    build.add_argument("document", help="a document file, or a bundle directory holding one")
    build.add_argument("out")
    build.add_argument("--strict", action="store_true")
    build.add_argument(
        "--time-series",
        help="HDF5 sidecar; default: the document's time_series_storage_file beside it",
    )
    args = parser.parse_args(argv)
    conn = create_database(args.out)
    report = insert_file(conn, args.document, strict=args.strict, time_series=args.time_series)
    conn.close()
    sys.stdout.write(report.to_json())
    return 0


if __name__ == "__main__":
    sys.exit(main())
