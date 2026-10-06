"""Exceptions raised by sienna_griddb_tools. Every error names what it was inserting."""


class GridDBToolsError(Exception):
    """Base class for every error this package raises."""


class InsertError(GridDBToolsError):
    """A row or field could not be written, or strict=True met data GridDB cannot store."""


def describe(type_name, obj):
    parts = [type_name]
    if isinstance(obj, dict):
        if "id" in obj:
            parts.append(f"id={obj['id']}")
        if "name" in obj:
            parts.append(f"name={obj['name']!r}")
    return " ".join(parts)
