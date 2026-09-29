# CLI: julia --project=sdk/julia sdk/julia/bin/build_db.jl <document.json> <out.sqlite> [--strict]
import JSON
using SiennaGridDBTools
# Time series need InfraStore.jl: load it when the active environment provides it.
isnothing(Base.find_package("InfraStore")) || @eval import InfraStore

function main(args::Vector{String})
    strict = "--strict" in args
    positional = filter(a -> !startswith(a, "--"), args)
    if length(positional) != 2
        println(stderr, "usage: build_db.jl <document.json> <out.sqlite> [--strict]")
        return 2
    end
    db = create_database(positional[2])
    report = insert_document!(db, positional[1]; strict=strict)
    close(db)
    JSON.print(stdout, SiennaGridDBTools.report_dict(report), 2)
    println(stdout)
    return 0
end

exit(main(ARGS))
