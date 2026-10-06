"""Load the bundled insert manifest and precompute per-type lookups."""

import json
from functools import lru_cache
from importlib import resources


def data_text(name):
    return resources.files("sienna_griddb_tools").joinpath("data", name).read_text("utf-8")


@lru_cache(maxsize=1)
def load_manifest():
    manifest = json.loads(data_text("insert_manifest.json"))
    for type_name, plan in manifest["components"].items():
        plan["type_name"] = type_name
        plan["known_fields"] = (
            {b["path"].split(".")[0] for b in plan["bindings"]}
            | {a["field"] for a in plan["attributes"]}
            | set(plan["skip"])
        )
    return manifest
