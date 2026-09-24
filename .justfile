db-name := "griddb-example.sqlite"
sqlite-options := "--table"
sqlite-command := "sqlite3"
python-command := "python3"
SQLITE_REQUIRED_VERSION := "3.45.0"

# Fail if the installed sqlite3 is older than SQLITE_REQUIRED_VERSION.
assert-sqlite-version:
    #!/usr/bin/env bash
    set -euo pipefail
    installed="$({{sqlite-command}} --version | cut -d' ' -f1)"
    required="{{SQLITE_REQUIRED_VERSION}}"
    echo "sqlite3 installed=${installed} required>=${required}"
    older="$(printf '%s\n%s\n' "$required" "$installed" | sort -V | head -n1)"
    if [ "$installed" != "$required" ] && [ "$older" != "$required" ]; then
        echo "ERROR: sqlite3 ${installed} is older than required ${required}" >&2
        exit 1
    fi

create-schema db=db-name: assert-sqlite-version
    @echo "Creating schema"
    @touch {{db}} && rm {{db}}
    @{{sqlite-command}} {{db}} < schema/schema.sql

create-triggers db=db-name: create-schema
    @echo "Adding triggers to schema"
    @{{sqlite-command}} {{db}} < schema/triggers.sql

create-unit-registry db=db-name: create-triggers
    @echo "Populating unit registry"
    @{{sqlite-command}} {{db}} < schema/unit_registry.sql

create-views db=db-name: create-unit-registry
    @echo "Adding views to schema"
    @{{sqlite-command}} {{db}} < schema/views.sql

new-db db=db-name: create-schema create-triggers create-unit-registry create-views
    @{{sqlite-command}} {{sqlite-options}} {{db}} "select count(*) from entities;"

# Regenerate the checked-in unit registry from units.json + column_conventions.json.
generate-registry:
    @{{python-command}} scripts/generate_unit_registry.py

# Verify a built database's registry seal against its live table contents.
verify-registry db=db-name:
    @{{python-command}} scripts/verify_unit_registry.py {{db}}

format sql-schema:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Formatting code {{sql-schema}}"
    if command -v sleek &> /dev/null; then
        sleek {{sql-schema}}
    else
        echo "SQL formatter does not exist. Installed it using `cargo install sleek`"
        exit 1
    fi

# Regenerate the insert manifest + gap report (SiennaSchemas at the CI-pinned tag).
generate-insert-manifest schemas="../SiennaSchemas":
    {{python-command}} scripts/generate_insert_manifest.py --schemas-path {{schemas}}

check-insert-manifest schemas="../SiennaSchemas":
    {{python-command}} scripts/generate_insert_manifest.py --schemas-path {{schemas}} --check

# Copy the manifest + schema files into sdk/*/data (rerun after generate-insert-manifest).
sync-sdk-data:
    {{python-command}} scripts/sync_sdk_data.py

# Local-only large-system insertion smoke test: CATS is far too large for CI, so
# this never runs there. Set the CATS source directory with CATS_DIR or pass
# --cats-dir through, e.g. `CATS_DIR=../CATS just insert-cats --strict`.
insert-cats db="/tmp/griddb-cats.sqlite" *args:
    {{python-command}} scripts/insert_experiment.py --db {{db}} --overwrite --dump {{db}}.dump.json {{args}}
