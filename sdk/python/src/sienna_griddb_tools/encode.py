"""The five manifest encodings: JSON-shaped value -> SQLite parameter."""

import json


class EncodeError(ValueError):
    pass


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def is_int(value):
    """What the int encoder accepts: an int or integral float, not a bool, in Int64."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, float) and not value.is_integer():
        return False
    return -(2**63) <= value < 2**63


def _int(value):
    if not is_int(value):
        raise EncodeError(f"expected an integer, got {value!r}")
    return int(value)


def _real(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EncodeError(f"expected a number, got {value!r}")
    return float(value)


def _text(value):
    if not isinstance(value, str):
        raise EncodeError(f"expected a string, got {value!r}")
    return value


def _bool(value):
    if not isinstance(value, bool):
        raise EncodeError(f"expected a boolean, got {value!r}")
    return 1 if value else 0


ENCODERS = {
    "int": _int,
    "real": _real,
    "text": _text,
    "bool": _bool,
    "json": canonical_json,
}


def encode(encoding, value):
    """None stays None (SQL NULL); anything else goes through the named encoder."""
    if value is None:
        return None
    return ENCODERS[encoding](value)


def value_at(obj, path):
    """The value at a dotted path, or None when any segment is absent."""
    node = obj
    for segment in path.split("."):
        if not isinstance(node, dict) or segment not in node:
            return None
        node = node[segment]
    return node
