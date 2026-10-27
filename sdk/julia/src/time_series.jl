feature_row(hash, key, v::Bool) = Any[hash, key, "bool", missing, missing, Int(v), missing]
feature_row(hash, key, v::Integer) =
    Any[hash, key, "int", Int64(v), missing, missing, missing]
function feature_row(hash, key, v::AbstractFloat)
    return Any[hash, key, "float", missing, Float64(v), missing, missing]
end
function feature_row(hash, key, v::AbstractString)
    return Any[hash, key, "str", missing, missing, missing, String(v)]
end

# A row whose owner the document holds names that owner's type and category; a
# mislabel is invalid data, like a dangling reference.
function require_owner_label(row::AbstractDict, owners::Dict{Int, Tuple{String, String}})
    owner = get(row, "owner_id", nothing)
    (is_int_value(owner) && haskey(owners, Int(owner))) || return nothing
    held = owners[Int(owner)]
    label = (get(row, "owner_type", nothing), get(row, "owner_category", nothing))
    if label != held
        what = "time series association id=$(get(row, "association_id", nothing))"
        is = "owner_id $owner is $(held[1]) ($(held[2]))"
        throw(InsertError("$what: $is, not $(label[1]) ($(label[2]))"))
    end
    return nothing
end

"""
The association rows to insert, after reporting the ones GridDB cannot store:
unsupported series types and rows naming a component in `unsupported_ids`. `owners`
maps each id the document holds to its `(owner_type, owner_category)`.
"""
function storable_time_series(
    doc::AbstractDict,
    report::InsertReport,
    strict::Bool,
    unsupported_ids::Set{Int},
    owners::Dict{Int, Tuple{String, String}},
)
    plan = manifest().time_series
    rows = section_rows(doc, plan.section)
    foreach(row -> require_owner_label(row, owners), rows)
    counts = Dict{String, Int}()
    stored = Any[]
    for row in rows
        series_type = get(row, "time_series_type", "")
        if haskey(plan.unsupported_types, series_type)
            counts[series_type] = get(counts, series_type, 0) + 1
        elseif names_unsupported(row, plan.references, unsupported_ids)
            add_unsupported!(report, plan.section, 1)
        else
            push!(stored, row)
        end
    end
    for series_type in sort!(collect(keys(counts)))
        reason = plan.unsupported_types[series_type]
        mark_unsupported!(report, strict, series_type, counts[series_type], reason)
    end
    return stored
end

"""
Association rows, then each feature set the first time its hash appears.
"""
function insert_associations!(
    cache::StatementCache,
    plan::TimeSeriesPlan,
    rows::Vector{Any},
    report::InsertReport,
)
    hash_at = findfirst(b -> b.encoding isa FeaturesHashEncoding, plan.bindings)
    features_seen = Set{String}()
    for row in rows
        what = "time series association id=$(get(row, "association_id", nothing))"
        params = bound_params(plan.bindings, row, what)
        run_sql(cache, plan.row_sql, params, what)
        hash = params[hash_at]::String
        if !(hash in features_seen)
            push!(features_seen, hash)
            for (key, value) in row["features"]
                run_sql(cache, plan.feature_sql, feature_row(hash, key, value), what)
            end
        end
        add_inserted!(report, plan.section)
    end
    return nothing
end

const DERIVED = "DeterministicSingleTimeSeries"

series_key(row::AbstractDict) = (
    get(row, "owner_id", nothing),
    get(row, "owner_category", nothing),
    get(row, "name", nothing),
    feature_key(get(row, "features", nothing)),
    get(row, "uri", nothing),
)

# Tells 1, 1.0 and true apart, as features_hash does.
feature_key(d::AbstractDict) = sort!([(String(k), typeof(v), v) for (k, v) in d]; by=first)
feature_key(_) = nothing

"""
`DeterministicSingleTimeSeries` id => its `SingleTimeSeries` id. A derived series is a
view over its source's array: same owner, name, features and uri.
"""
function derived_sources(rows)
    sources = Dict(
        series_key(r) => r["association_id"] for
        r in rows if get(r, "time_series_type", nothing) == "SingleTimeSeries"
    )
    derived = Dict{Int, Int}()
    for r in rows
        get(r, "time_series_type", nothing) == DERIVED || continue
        source = get(sources, series_key(r), nothing)
        id = get(r, "association_id", nothing)
        if is_int_value(source) && is_int_value(id)
            derived[Int(id)] = Int(source)
        end
    end
    return derived
end

is_reference(key::AbstractString) =
    key in ("association_id", "fuel_cost_time_series") || endswith(key, "_association_id")

"""
`node` with its time series references to a derived series naming the source instead
(the keys `dangling_time_series_references` reads). A dict or vector is copied only
when something inside it changes; the caller's stays as it was.
"""
function point_at_sources(
    node::Union{AbstractDict, AbstractVector},
    sources::Dict{Int, Int},
)
    isempty(sources) && return node
    out = nothing
    for (k, v) in pairs(node)
        new =
            if k isa AbstractString &&
               is_reference(k) &&
               is_int_value(v) &&
               haskey(sources, Int(v))
                sources[Int(v)]
            else
                point_at_sources(v, sources)
            end
        new === v && continue
        if isnothing(out)
            out = node isa AbstractDict ? Dict{String, Any}(node) : Vector{Any}(node)
        end
        out[k] = new
    end
    return isnothing(out) ? node : out
end
point_at_sources(node, ::Dict{Int, Int}) = node
