"""CLI: python3 -m sienna_griddb_tools build <document.json> <out.sqlite> [--strict]"""

import argparse
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
    args = parser.parse_args(argv)
    conn = create_database(args.out)
    report = insert_document(conn, args.document, strict=args.strict)
    conn.close()
    sys.stdout.write(report.to_json())
    return 0


if __name__ == "__main__":
    sys.exit(main())
