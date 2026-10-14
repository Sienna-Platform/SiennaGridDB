#!/usr/bin/env python3
"""Prepare a GridDB release for a SiennaSchemas release.

  python3 .github/scripts/bump_version.py v0.2.0 v0.3.0

Bumps pyproject.toml by the same level as the schema release, increments
PRAGMA user_version, and adds the release heading to CHANGELOG.md. Prints the
new version. GridDB mirrors the schema's bump LEVEL, not its number; the
numbers drift apart once a hand-bumped GridDB-only fix ships.
"""

import datetime
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REPO_URL = "https://github.com/Sienna-Platform/SiennaGridDB"
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def parse_tag(tag: str) -> tuple[int, int, int]:
    match = TAG.match(tag)
    if match is None:
        fail(f"{tag!r} is not a vMAJOR.MINOR.PATCH release tag")
    return tuple(int(part) for part in match.groups())


def bumped(version: str, old_tag: str, new_tag: str) -> str:
    old, new = parse_tag(old_tag), parse_tag(new_tag)
    if new <= old:
        fail(f"schema {new_tag} is not newer than {old_tag}")
    major, minor, patch = (int(part) for part in version.split("."))
    if new[0] > old[0]:
        return f"{major + 1}.0.0"
    if new[1] > old[1]:
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def substitute(path: Path, pattern: str, repl) -> None:
    """Replace the one match of pattern in path. A miss is a release with a stale field."""
    text, count = re.subn(pattern, repl, path.read_text(), count=1, flags=re.MULTILINE)
    if count != 1:
        fail(f"{path.relative_to(REPO_ROOT)}: no match for {pattern!r}")
    path.write_text(text)


def main() -> int:
    if len(sys.argv) != 3:
        fail("usage: bump_version.py <old schema tag> <new schema tag>")
    old_tag, new_tag = sys.argv[1:]

    pyproject = REPO_ROOT / "pyproject.toml"
    current = re.search(r'^version = "([^"]+)"$', pyproject.read_text(), re.MULTILINE).group(1)
    new = bumped(current, old_tag, new_tag)
    substitute(pyproject, rf'^version = "{re.escape(current)}"$', f'version = "{new}"')

    user_version = 0

    def increment(match: re.Match) -> str:
        nonlocal user_version
        user_version = int(match.group(2)) + 1
        return f"{match.group(1)}{user_version}"

    substitute(REPO_ROOT / "schema" / "schema.sql", r"^(PRAGMA user_version = )(\d+)", increment)

    # Entries already under [Unreleased] land under the new heading.
    changelog = REPO_ROOT / "CHANGELOG.md"
    today = datetime.date.today().isoformat()
    substitute(
        changelog,
        r"^## \[Unreleased\]\n",
        f"## [Unreleased]\n\n## [{new}] - {today}\n\n"
        f"Built from SiennaSchemas {new_tag}. `PRAGMA user_version = {user_version}`.\n",
    )
    substitute(
        changelog,
        rf"^\[Unreleased\]: {re.escape(REPO_URL)}/compare/v{re.escape(current)}\.\.\.HEAD$",
        f"[Unreleased]: {REPO_URL}/compare/v{new}...HEAD\n"
        f"[{new}]: {REPO_URL}/compare/v{current}...v{new}",
    )

    print(new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
