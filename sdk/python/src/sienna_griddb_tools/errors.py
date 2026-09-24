"""Exceptions raised by sienna_griddb_tools. Every error names what it was inserting."""


class GridDBToolsError(Exception):
    """Base class for every error this package raises."""


class DatabaseExistsError(GridDBToolsError):
    """create_database was pointed at a path that already exists."""


class SQLiteVersionError(GridDBToolsError):
    """The linked SQLite library is older than GridDB requires."""


class ManifestMismatchError(GridDBToolsError):
    """The database or manifest is not the version this package was built for."""


class InsertError(GridDBToolsError):
    """A row could not be written; wraps the SQLite or encoding failure."""


class UnsupportedComponentError(GridDBToolsError):
    """strict=True and the input holds a type or section GridDB cannot store."""


class GapValueError(GridDBToolsError):
    """strict=True and a field with no DB home carries a value."""


def describe(type_name, obj):
    parts = [type_name]
    if isinstance(obj, dict):
        if "id" in obj:
            parts.append(f"id={obj['id']}")
        if "name" in obj:
            parts.append(f"name={obj['name']!r}")
    return " ".join(parts)
