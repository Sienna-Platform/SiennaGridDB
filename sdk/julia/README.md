# SiennaGridDBTools.jl

Insert Sienna OpenAPI SDK objects into a SiennaGridDB SQLite database.

```julia
using PowerOpenAPIModels, SiennaGridDBTools
db = create_database("system.sqlite")
report = insert_document!(db, PowerOpenAPIModels.read_document("system.json"))
```

Without `PowerOpenAPIModels`, pass parsed JSON:
`insert_document!(db, JSON.parsefile("system.json"; dicttype=Dict{String,Any}))`.
Fields GridDB has no column for yet are counted in `report.skipped_fields`; pass
`strict=true` to throw instead. CLI: `julia --project=sdk/julia sdk/julia/bin/build_db.jl system.json out.sqlite`.
