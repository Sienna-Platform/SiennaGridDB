"""scripts/_common.py writes generated JSON defaults in the SDKs' canonical form."""

import json
import sys

from conftest import REPO_ROOT, SCRIPTS_DIR

sys.path.insert(0, str(SCRIPTS_DIR))
from _common import canonical_json  # noqa: E402


def test_generated_defaults_use_the_rfc_8785_vectors():
    path = REPO_ROOT / "test" / "canonical_json_vectors.json"
    for v in json.loads(path.read_text("utf-8"))["vectors"]:
        assert canonical_json(json.loads(v["input"])) == v["expected"]
