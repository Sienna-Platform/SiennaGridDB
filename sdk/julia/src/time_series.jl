const DST = "DeterministicSingleTimeSeries"
const TUPLE_ELEMENT = r"^tuple\(\d+,\s*(\w+)\)$"

"""
    foreach_array(f, sidecar, rows)

Call `f(row, shape::Vector{Int}, values::Vector{Float64})` with each row's array, in
the shape infrastore stores it and flattened row-major, read from the HDF5 `sidecar`,
which is only ever read. Defined by the InfraStore extension.
"""
function foreach_array end

"""
Why arrays cannot be read in this session, or `nothing` when InfraStore is loaded.
"""
function reader_missing()
    if isnothing(Base.get_extension(@__MODULE__, :SiennaGridDBToolsInfraStoreExt))
        return "load InfraStore.jl to read the HDF5 sidecar"
    end
    return nothing
end

"""
The dtype inside `tuple(N,dtype)`, else the element type itself.
"""
function element_dtype(element_type::AbstractString)
    m = match(TUPLE_ELEMENT, element_type)
    return isnothing(m) ? String(element_type) : String(m.captures[1])
end
element_dtype(_) = ""

feature_row(hash, key, v::Bool) = Any[hash, key, "bool", missing, missing, Int(v), missing]
feature_row(hash, key, v::Integer) =
    Any[hash, key, "int", Int64(v), missing, missing, missing]
function feature_row(hash, key, v::AbstractFloat)
    return Any[hash, key, "float", missing, Float64(v), missing, missing]
end
function feature_row(hash, key, v::AbstractString)
    return Any[hash, key, "str", missing, missing, missing, String(v)]
end

count!(counts::Dict{String, Int}, key) = counts[key] = get(counts, key, 0) + 1

"""
The association rows to insert, after reporting the ones GridDB cannot store: every
row without a sidecar (`no_sidecar` says why) or reader, unsupported series types,
rows naming a component in `unsupported_ids`, element types GridDB does not hold.
"""
function storable_time_series(
    doc::AbstractDict,
    sidecar,
    no_sidecar::AbstractString,
    report::InsertReport,
    strict,
    unsupported_ids::Set{Int},
)
    plan = manifest().time_series
    rows = get(doc, plan.section, nothing)
    stored = Any[]
    if isnothing(rows) || isempty(rows)
        return stored
    end
    missing_reason = isnothing(sidecar) ? no_sidecar : reader_missing()
    if !isnothing(missing_reason)
        mark_unsupported!(report, strict, plan.section, length(rows), missing_reason)
        return stored
    end
    foreach(row -> require_object(row, "$(plan.section) row"), rows)
    counts = Dict{String, Int}()
    dtypes = Dict{String, Int}()
    for row in rows
        series_type = get(row, "time_series_type", "")
        element_type = get(row, "element_type", nothing)
        if haskey(plan.unsupported_types, series_type)
            count!(counts, series_type)
        elseif names_unsupported(row, plan.references, unsupported_ids)
            add_unsupported!(report, plan.section, 1)
        elseif haskey(plan.unsupported_dtypes, element_dtype(element_type))
            count!(dtypes, element_type)
        else
            push!(stored, row)
        end
    end
    for series_type in sort!(collect(keys(counts)))
        reason = plan.unsupported_types[series_type]
        mark_unsupported!(report, strict, series_type, counts[series_type], reason)
    end
    for element_type in sort!(collect(keys(dtypes)))
        why = plan.unsupported_dtypes[element_dtype(element_type)]
        reason = "element_type $element_type: $why"
        mark_unsupported!(report, strict, plan.section, dtypes[element_type], reason)
    end
    return stored
end

function write_association!(cache::StatementCache, plan::TimeSeriesPlan, row::AbstractDict)
    try
        params = Any[bound_value(b.encoding, row, b.segments) for b in plan.bindings]
        stmt = get!(() -> SQLite.Stmt(cache.db, plan.row_sql), cache.stmts, plan.row_sql)
        DBInterface.execute(stmt, params)
        return params
    catch e
        what = "time series association id=$(get(row, "association_id", nothing))"
        throw(wrap_error(e, what))
    end
end

function write_values!(stmt::SQLite.Stmt, uri::String, width::Int, values::Vector{Float64})
    for (i, v) in enumerate(values)
        DBInterface.execute(stmt, (uri, (i - 1) ÷ width, (i - 1) % width, v))
    end
    return nothing
end

function array_stored(cache::StatementCache, uri::String)
    sql = "SELECT count(*) FROM (SELECT 1 FROM static_time_series WHERE uri = ? LIMIT 1)"
    stmt = get!(() -> SQLite.Stmt(cache.db, sql), cache.stmts, sql)
    return first(DBInterface.execute(stmt, (uri,)))[1] > 0
end

"""
Association rows, their feature sets, then each array's values the first time its uri
appears (arrays are shared by uri).
"""
function insert_time_series!(
    cache::StatementCache,
    plan::TimeSeriesPlan,
    rows::Vector{Any},
    sidecar::AbstractString,
    report::InsertReport,
)
    hash_at = findfirst(b -> b.encoding isa FeaturesHashEncoding, plan.bindings)
    features_seen = Set{String}()
    chosen = Dict{String, Int}()  # uri => index in first_rows, the row InfraStore imports
    first_rows = Any[]
    declared = Dict{String, Dict{Vector{Int}, Any}}()  # uri => array_shape => association id
    for row in rows
        params = write_association!(cache, plan, row)
        add_inserted!(report, plan.section)
        hash = params[hash_at]::String
        if !(hash in features_seen)
            push!(features_seen, hash)
            for (key, value) in row["features"]
                what = "time series association id=$(row["association_id"])"
                run_sql(cache, plan.feature_sql, feature_row(hash, key, value), what)
            end
        end
        uri = String(row["uri"])
        at = get!(chosen, uri) do
            push!(first_rows, row)
            return length(first_rows)
        end
        # InfraStore imports a DeterministicSingleTimeSeries only beside its source
        if first_rows[at]["time_series_type"] == DST
            first_rows[at] = row
        end
        array_shape = get(row, "array_shape", nothing)
        if array_shape isa AbstractVector && !isempty(array_shape)
            shapes = get!(() -> Dict{Vector{Int}, Any}(), declared, uri)
            get!(shapes, Vector{Int}(array_shape), row["association_id"])
        end
    end
    held = Set{String}(uri for uri in keys(chosen) if array_stored(cache, uri))
    # An array already stored is read again only to check the shapes declared for it
    wanted(uri) = !(uri in held) || haskey(declared, uri)
    read_rows = Any[r for r in first_rows if wanted(String(r["uri"]))]
    if isempty(read_rows)
        return nothing
    end
    stmt = get!(() -> SQLite.Stmt(cache.db, plan.value_sql), cache.stmts, plan.value_sql)
    foreach_array(sidecar, read_rows) do row, shape, values
        uri = String(row["uri"])
        # InfraStore checks the imported row's element_type and shape, not the rest
        for (declared_shape, id) in get(declared, uri, Dict{Vector{Int}, Any}())
            if declared_shape != shape
                throw(
                    InsertError(
                        "time series association id=$id: array_shape $declared_shape " *
                        "is not the sidecar's $shape for $uri",
                    ),
                )
            end
        end
        uri in held && return nothing
        # One split per uri, from the stored shape: its last axis is element.
        width = length(shape) > 1 ? last(shape) : 1
        try
            write_values!(stmt, uri, width, values)
        catch e
            throw(wrap_error(e, "time series $uri"))
        end
        add_inserted!(report, "static_time_series", length(values))
    end
    return nothing
end
