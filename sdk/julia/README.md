# SiennaGridDBTools.jl

Insert Sienna OpenAPI SDK objects into a SiennaGridDB SQLite database.

```julia
using PowerOpenAPIModels, SiennaGridDBTools
db = create_database("system.sqlite")
report = insert_document!(db, PowerOpenAPIModels.read_document("system.json"))
```

Without `PowerOpenAPIModels`, pass parsed JSON:
`insert_document!(db, JSON.parsefile("system.json"; dicttype=Dict{String,Any}))`.
Fields GridDB has no column for yet are counted in `report.skipped_fields`; pass `strict=true` to throw instead.
Time series need `InfraStore.jl` loaded (`import InfraStore`, a weak dependency): pass the document's path, `insert_document!(db, "system.json")`, so its HDF5 sidecar resolves beside it, or `time_series="system.h5"` with a parsed document or `SystemDocument`.
The sidecar is only read (InfraStore works on a private copy).
Without InfraStore or a sidecar (a `time_series_storage_file` that does not exist counts as none), time series are reported in `report.unsupported`; an explicit `time_series` path that does not exist throws.
A `SystemDocument` is not parity-safe for time series: PowerOpenAPIModels.jl decodes an integral float feature (`1.0`) as an Int, which changes its `features_hash`, and respells `initial_timestamp` with milliseconds (`.000Z`).
Pass the path or parsed JSON when the database must match the other SDKs.
CLI: `julia --project=sdk/julia sdk/julia/bin/build_db.jl system.json out.sqlite`.
The CLI stores time series only when its environment provides InfraStore.jl, which `sdk/julia` does not (a weak dependency): use `--project=sdk/julia/test`, or an environment with both packages.
