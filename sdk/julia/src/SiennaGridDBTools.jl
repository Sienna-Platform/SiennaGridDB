"""
Insert Sienna OpenAPI SDK objects into a SiennaGridDB SQLite database.

All mapping lives in the bundled `data/insert_manifest.json`; this package only binds
values into the manifest's SQL. Load `PowerOpenAPIModels` as well to insert SDK models
and `SystemDocument`s directly.
"""
module SiennaGridDBTools

import DBInterface
import JSON
import SQLite

export create_database,
    open_database,
    seed_vocabulary!,
    insert_component!,
    insert_components!,
    insert_document!,
    InsertReport,
    GridDBToolsError,
    DatabaseExistsError,
    SQLiteVersionError,
    ManifestMismatchError,
    InsertError,
    UnsupportedComponentError,
    GapValueError

const DATA_DIR = joinpath(@__DIR__, "..", "data")

include("errors.jl")
include("report.jl")
include("encode.jl")
include("manifest.jl")
include("db.jl")
include("insert.jl")

end
