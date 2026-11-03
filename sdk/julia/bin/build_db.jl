# CLI: julia --project=sdk/julia sdk/julia/bin/build_db.jl <document.json> <out.sqlite>
#   [--strict] [--time-series <sidecar.h5>]
# The sidecar defaults to the document's time_series_storage_file, beside the document.
import JSON
using SiennaGridDBTools

const USAGE = "usage: build_db.jl <document.json> <out.sqlite> [--strict] [--time-series <sidecar.h5>]"

function main(args::Vector{String})
    strict = "--strict" in args
    sidecar = nothing
    at = findfirst(==("--time-series"), args)
    if !isnothing(at)
        if at == length(args)
            println(stderr, USAGE)
            return 2
        end
        sidecar = args[at + 1]
        args = args[setdiff(eachindex(args), (at, at + 1))]
    end
    positional = filter(a -> !startswith(a, "--"), args)
    if length(positional) != 2
        println(stderr, USAGE)
        return 2
    end
    doc = JSON.parsefile(positional[1]; dicttype=Dict{String, Any})
    stored = something(get(doc, "time_series_storage_file", nothing), "")
    if isnothing(sidecar) && !isempty(stored)
        sidecar = joinpath(dirname(abspath(positional[1])), stored)
    end
    db = create_database(positional[2])
    report = insert_document!(db, doc; strict=strict, time_series=sidecar)
    close(db)
    JSON.print(stdout, SiennaGridDBTools.report_dict(report), 2)
    println(stdout)
    return 0
end

exit(main(ARGS))
