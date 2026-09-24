"""Load the bundled insert manifest and precompute per-type lookups."""

import json
from functools import lru_cache
from importlib import resources

from .errors import ManifestMismatchError

SUPPORTED_MANIFEST_VERSION = 1


def data_text(name):
    return resources.files("sienna_griddb_tools").joinpath("data", name).read_text("utf-8")


class ComponentPlan:
    def __init__(self, type_name, entry):
        self.type_name = type_name
        self.rank = entry["rank"]
        self.entity_sql = entry["entity_sql"]
        self.row_sql = entry["row_sql"]
        self.bindings = entry["bindings"]
        self.entity_bindings = self.bindings[:1]
        self.attributes = entry["attributes"]
        self.gaps = entry["gaps"]
        self.known_fields = (
            {b["path"].split(".")[0] for b in self.bindings}
            | {a["field"] for a in self.attributes}
            | set(entry["skip"])
            | set(entry["gaps"])
        )


class Manifest:
    def __init__(self, raw):
        if raw["manifest_version"] != SUPPORTED_MANIFEST_VERSION:
            raise ManifestMismatchError(
                f"manifest_version {raw['manifest_version']} is not "
                f"{SUPPORTED_MANIFEST_VERSION}"
            )
        self.schema_user_version = raw["schema_user_version"]
        self.vocabulary = raw["vocabulary"]
        self.components = {n: ComponentPlan(n, e) for n, e in raw["components"].items()}
        self.unsupported_components = raw["unsupported_components"]
        self.attribute_sql = raw["attribute_sql"]
        self.supplemental = raw["supplemental_attributes"]
        self.associations = raw["associations"]
        self.unsupported_sections = raw["unsupported_sections"]


@lru_cache(maxsize=1)
def load_manifest():
    return Manifest(json.loads(data_text("insert_manifest.json")))
