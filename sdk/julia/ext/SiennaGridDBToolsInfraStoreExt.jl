module SiennaGridDBToolsInfraStoreExt

import InfraStore
import JSON
import SiennaGridDBTools

const G = SiennaGridDBTools

readable_error(e::InfraStore.TimeSeriesException) = true
readable_error(e::Union{SystemError, Base.IOError, ArgumentError}) = true
readable_error(_) = false

function sidecar_error(e, sidecar::AbstractString)
    if readable_error(e)
        return G.InsertError("time series sidecar $sidecar: $(sprint(showerror, e))")
    end
    return e
end

"""
InfraStore opens its file writable, so it reads a private copy with an in-memory
catalog: nothing is written beside the caller's sidecar, or beside its symlink target.
"""
function G.foreach_array(f::Function, sidecar::AbstractString, rows::Vector{Any})
    mktempdir() do dir
        copy = joinpath(dir, "time_series.h5")
        store = try
            cp(sidecar, copy; follow_symlinks=true)
            chmod(copy, 0o600)  # cp keeps a read-only source's mode
            InfraStore.open_store_without_catalog(copy; catalog=:memory)
        catch e
            throw(sidecar_error(e, sidecar))
        end
        try
            read_arrays(f, store, sidecar, rows)
        finally
            InfraStore.close!(store)
        end
    end
    return nothing
end

# InfraStore hands a stored array back as a Julia array of the same dims; flat and
# row-major it matches the sidecar's layout.
row_major(data::AbstractVector) = Vector{Float64}(data)
row_major(data::AbstractArray) = vec(permutedims(data, ndims(data):-1:1))

function read_arrays(f::Function, store::InfraStore.Store, sidecar, rows::Vector{Any})
    # InfraStore rejects null for an optional field, so null keys are dropped here
    # as in the Python SDK; GridDB's own rows already treat null as absent
    wire = [filter(p -> !isnothing(p.second), row) for row in rows]
    try
        InfraStore.import_time_series_associations_openapi!(store, JSON.json(wire))
    catch e
        throw(sidecar_error(e, sidecar))
    end
    for row in rows
        data = try
            InfraStore.read_by_id(store, row["association_id"]; raw=true).data
        catch e
            throw(sidecar_error(e, sidecar))
        end
        f(row, collect(Int, size(data)), row_major(data::AbstractArray{Float64}))
    end
    return nothing
end

end
