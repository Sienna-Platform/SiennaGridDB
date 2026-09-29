"""The manifest encodings: JSON-shaped value -> SQLite parameter."""

import hashlib
import json
import math
import struct


class EncodeError(ValueError):
    pass


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _int(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EncodeError(f"expected an integer, got {value!r}")
    if isinstance(value, float) and not value.is_integer():
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


def _u64(n):
    return struct.pack("<Q", n)


# Rust's f64::NAN, which infrastore hashes in place of any NaN payload.
_NAN = struct.pack("<Q", 0x7FF8000000000000)


def _feature_bytes(value):
    if isinstance(value, bool):
        return b"b" + bytes([value])
    if isinstance(value, int):
        if not -(2**63) <= value < 2**63:
            raise EncodeError(f"feature integer {value} does not fit in 64 bits")
        return b"i" + struct.pack("<q", value)
    if isinstance(value, float):
        return b"f" + (_NAN if math.isnan(value) else struct.pack("<d", value))
    if isinstance(value, str):
        raw = value.encode("utf-8")
        return b"s" + _u64(len(raw)) + raw
    raise EncodeError(f"expected an int, float, bool or string feature, got {value!r}")


def features_hash(features):
    """infrastore's features_hash (crates/infrastore-core/src/hash.rs), lowercase hex.

    Keys go in UTF-8 byte order; a Python int hashes as Int, a float as Float.
    """
    if not isinstance(features, dict):
        raise EncodeError(f"expected a feature map, got {features!r}")
    digest = hashlib.sha256(b"features\0" + _u64(len(features)))
    for key in sorted(features, key=lambda k: k.encode("utf-8")):
        raw = key.encode("utf-8")
        digest.update(_u64(len(raw)) + raw + _feature_bytes(features[key]))
    return digest.hexdigest()


ENCODERS = {
    "int": _int,
    "real": _real,
    "text": _text,
    "bool": _bool,
    "json": canonical_json,
    "features_hash": features_hash,
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
