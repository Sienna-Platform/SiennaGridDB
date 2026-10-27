module SiennaGridDBToolsInfraStoreExt

import InfraStore
import JSON
import SiennaGridDBTools

const G = SiennaGridDBTools

readable_error(::InfraStore.TimeSeriesException) = true
readable_error(::Union{SystemError, Base.IOError, ArgumentError}) = true
readable_error(_) = false

"""
InfraStore opens its file writable, so it reads a private copy with an in-memory catalog:
nothing is written beside the caller's sidecar, or beside its symlink target.
"""
function G.export_values(f::Function, sidecar::AbstractString, rows::Vector{Any}, prefix)
    mktempdir() do dir
        copy = joinpath(dir, "time_series.h5")
        out = joinpath(dir, "export.sqlite")
        try
            cp(sidecar, copy; follow_symlinks=true)
            chmod(copy, 0o600)  # cp keeps a read-only source's mode
            store = InfraStore.open_store_without_catalog(copy; catalog=:memory)
            try
                # InfraStore rejects null for an optional field; GridDB treats it as absent
                wire = [filter(p -> !isnothing(p.second), row) for row in rows]
                InfraStore.import_time_series_associations_openapi!(store, JSON.json(wire))
                InfraStore.export_sqlite(store, out; table_prefix=prefix)
            finally
                InfraStore.close!(store)
            end
        catch e
            readable_error(e) || rethrow()
            throw(G.InsertError("time series sidecar $sidecar: $(sprint(showerror, e))"))
        end
        f(out)
    end
    return nothing
end

end
