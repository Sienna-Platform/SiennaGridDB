# SiennaGridDBTools.jl

The Julia CRUD SDK for SiennaGridDB: it stores Sienna OpenAPI SDK objects in a
SiennaGridDB SQLite database. Today it implements create (insert); read, update and
delete come next. It is not a general database client: use SQLite directly for anything
else.

```julia
using PowerOpenAPIModels, SiennaGridDBTools
db = create_database("system.sqlite")
report = insert_document!(db, PowerOpenAPIModels.read_document("system.json"))
```

Without `PowerOpenAPIModels`, pass parsed JSON:
`insert_document!(db, JSON.parsefile("system.json"; dicttype=Dict{String,Any}))`.
Fields GridDB has no column for yet are counted in `get_skipped_fields(report)`; pass
`strict=true` to throw instead. CLI: `julia --project=sdk/julia sdk/julia/bin/build_db.jl system.json out.sqlite`.
A portfolio, its base system first, each with its time series: `insert_file!(db, "portfolio_dir")`, or the CLI with the directory.
