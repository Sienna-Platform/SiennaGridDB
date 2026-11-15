"""The five manifest encodings: JSON-shaped value -> SQLite parameter."""

import hashlib
import json
import math
import struct


class EncodeError(ValueError):
    pass


def canonical_json(value):
    """RFC 8785 (JCS) text, the form the three SDKs write: keys in UTF-16 code-unit
    order, numbers as ECMAScript writes them (1.0 -> 1), no whitespace."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical_json(v) for v in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: k.encode("utf-16-be"))
        items = (json.dumps(k, ensure_ascii=False) + ":" + canonical_json(value[k]) for k in keys)
        return "{" + ",".join(items) + "}"
    raise EncodeError(f"not a JSON value: {value!r}")


def _number(x):
    """ECMAScript Number::toString, from the shortest round-trip digits repr gives."""
    if not math.isfinite(x):
        raise EncodeError(f"{x!r}: GridDB stores finite numbers only")
    if x == 0:
        return "0"
    sign = "-" if x < 0 else ""
    mantissa, _, exponent = repr(abs(x)).partition("e")
    whole, _, fraction = mantissa.partition(".")
    all_digits = whole + fraction
    digits = all_digits.lstrip("0")
    # n: where the decimal point sits relative to the first significant digit.
    n = len(whole) + int(exponent or 0) - (len(all_digits) - len(digits))
    digits = digits.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * -n + digits
    e = n - 1
    mark = "+" if e >= 0 else "-"
    if k == 1:
        return f"{sign}{digits}e{mark}{abs(e)}"
    return f"{sign}{digits[0]}.{digits[1:]}e{mark}{abs(e)}"


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
    if not math.isfinite(value):
        raise EncodeError(f"expected a finite number, got {value!r}")
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
