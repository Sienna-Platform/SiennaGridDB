#!/usr/bin/env bash
# Schema Sync Validation Script
# Ensures all copies of schema files match the canonical source in schema/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_DIR="$REPO_ROOT/schema"
JULIA_DBINTERFACE_DIR="$REPO_ROOT/SiennaOpenAPIModels.jl/src/dbinterface"

# Files to check
FILES=("schema.sql" "triggers.sql" "unit_registry.sql" "views.sql")

# If the Julia package copy dir is absent, there is nothing to sync against.
if [[ ! -d "$JULIA_DBINTERFACE_DIR" ]]; then
    echo "SKIP: Julia package dir not found: $JULIA_DBINTERFACE_DIR"
    echo "Nothing to sync; downstream must ship these files where its copy lives."
    exit 0
fi

# Track if any files are out of sync
OUT_OF_SYNC=0

for file in "${FILES[@]}"; do
    canonical="$CANONICAL_DIR/$file"
    julia_copy="$JULIA_DBINTERFACE_DIR/$file"

    # Check canonical exists
    if [[ ! -f "$canonical" ]]; then
        echo "ERROR: Canonical file missing: $canonical"
        OUT_OF_SYNC=1
        continue
    fi

    # Check Julia copy exists
    if [[ ! -f "$julia_copy" ]]; then
        echo "ERROR: Julia package copy missing: $julia_copy"
        OUT_OF_SYNC=1
        continue
    fi

    # Compare files
    if ! diff -q "$canonical" "$julia_copy" > /dev/null 2>&1; then
        echo "ERROR: Schema files out of sync:"
        echo "  Canonical: $canonical"
        echo "  Copy:      $julia_copy"
        echo ""
        echo "To fix, copy from canonical to package:"
        echo "  cp $canonical $julia_copy"
        echo ""
        OUT_OF_SYNC=1
    fi
done

if [[ $OUT_OF_SYNC -eq 1 ]]; then
    echo "Schema sync validation FAILED"
    echo "The canonical schema is in schema/"
    echo "Package copies must match exactly."
    exit 1
fi

echo "Schema sync validation passed"
exit 0
