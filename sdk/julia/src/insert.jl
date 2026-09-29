const SAVEPOINT = "sienna_griddb_tools_insert"

function with_savepoint(f::Function, db::SQLite.DB)
    DBInterface.execute(db, "SAVEPOINT $SAVEPOINT")
    try
        f()
    catch
        DBInterface.execute(db, "ROLLBACK TO $SAVEPOINT")
        DBInterface.execute(db, "RELEASE $SAVEPOINT")
        rethrow()
    end
    DBInterface.execute(db, "RELEASE $SAVEPOINT")
    return nothing
end

wrap_error(e::SQLite.SQLiteException, what::AbstractString) = InsertError("$what: $(e.msg)")
wrap_error(e::EncodeError, what::AbstractString) = InsertError("$what: $(e.msg)")
wrap_error(e, ::AbstractString) = e

"""
Prepared statements for one insert call, keyed by SQL text, so each is compiled once.
"""
struct StatementCache
    db::SQLite.DB
    stmts::Dict{String, SQLite.Stmt}
end

StatementCache(db::SQLite.DB) = StatementCache(db, Dict{String, SQLite.Stmt}())

function close_statements!(cache::StatementCache)
    foreach(DBInterface.close!, values(cache.stmts))
    empty!(cache.stmts)
    return nothing
end

function with_statements(f::Function, db::SQLite.DB)
    cache = StatementCache(db)
    try
        with_savepoint(() -> f(cache), db)
    finally
        close_statements!(cache)
    end
    return nothing
end

function run_sql(
    cache::StatementCache,
    sql::AbstractString,
    params::Vector,
    what::AbstractString,
)
    try
        stmt = get!(() -> SQLite.Stmt(cache.db, sql), cache.stmts, sql)
        DBInterface.execute(stmt, params)
    catch e
        throw(wrap_error(e, what))
    end
    return nothing
end

function bound_params(bindings::Vector{Binding}, obj::AbstractDict, what::AbstractString)
    try
        return Any[bound_value(b.encoding, obj, b.segments) for b in bindings]
    catch e
        throw(wrap_error(e, what))
    end
end

function skip_field!(
    report::InsertReport,
    strict::Bool,
    type_name,
    field,
    what,
    reason="has no column in GridDB",
)
    if strict
        throw(GapValueError("$what: field $(repr(field)) $reason"))
    end
    add_skipped!(report, type_name, field)
    return nothing
end

function mark_unsupported!(report::InsertReport, strict::Bool, key, n::Int, reason)
    if strict
        throw(UnsupportedComponentError("$key ($n rows): $reason"))
    end
    add_unsupported!(report, key, n)
    return nothing
end

discriminator_key(value::AbstractString, ::String) = String(value)
discriminator_key(::Nothing, default::String) = default
discriminator_key(value, ::String) = canonical_json(value)

"""
The spec that fixes one attribute row's unit, following discriminator arms; `nothing`
when a discriminating field's value has no arm.
"""
function resolve_unit(spec::UnitSpec, obj::AbstractDict)
    while !isempty(spec.discriminator)
        key = discriminator_key(get(obj, spec.discriminator, nothing), spec.default)
        arm = get(spec.arms, key, nothing)
        if isnothing(arm)
            return nothing
        end
        spec = arm
    end
    return spec
end

function unit_columns(spec::UnitSpec)
    if isempty(spec.unit)
        return Any[missing, missing]
    end
    return Any[spec.unit, spec.quantity_kind]
end

function write_attribute!(cache, report, strict, plan, attr::AttributePlan, obj, what)
    value = get(obj, attr.field, nothing)
    if isnothing(value)
        return nothing
    end
    if attr.unit_free && !(value isa Union{AbstractString, Bool})
        reason = "needs a string or boolean value"
        skip_field!(report, strict, plan.type_name, attr.field, what, reason)
        return nothing
    end
    spec = resolve_unit(attr.spec, obj)
    if isnothing(spec)
        reason = "has no unit for its discriminator value"
        skip_field!(report, strict, plan.type_name, attr.field, what, reason)
        return nothing
    end
    params = Any[obj["id"], plan.type_name, attr.field, canonical_json(value)]
    append!(params, unit_columns(spec))
    run_sql(cache, manifest().attribute_sql, params, what)
    return nothing
end

function write_row!(cache, plan::ComponentPlan, obj::AbstractDict, report, strict::Bool)
    what = describe(plan.type_name, obj)
    run_sql(cache, plan.row_sql, bound_params(plan.bindings, obj, what), what)
    for attr in plan.attributes
        write_attribute!(cache, report, strict, plan, attr, obj, what)
    end
    for gap in plan.gaps
        if !isnothing(get(obj, gap, nothing))
            skip_field!(report, strict, plan.type_name, gap, what)
        end
    end
    unknown = String[k for k in keys(obj) if !(k in plan.known_fields || isnothing(obj[k]))]
    for key in sort!(unknown)
        skip_field!(report, strict, plan.type_name, key, what)
    end
    add_inserted!(report, plan.type_name)
    return nothing
end

# Every document entry is a JSON object; anything else is schema-invalid input.
function require_object(entry, what::AbstractString)
    is_object(entry) || throw(InsertError("$what $(JSON.json(entry)): not an object"))
    return nothing
end

function write_entity!(cache, plan::ComponentPlan, obj)
    require_object(obj, "$(plan.type_name) entry")
    what = describe(plan.type_name, obj)
    run_sql(cache, plan.entity_sql, bound_params(plan.entity_bindings, obj, what), what)
    return nothing
end

function note_unsupported!(report, strict, type_name::AbstractString, n::Int)
    reason =
        get(manifest().unsupported_components, type_name, "not a GridDB component type")
    mark_unsupported!(report, strict, type_name, n, reason)
    return nothing
end

"""
    insert_components!(db, type_name, objs; strict=false) -> InsertReport

Insert JSON-shaped objects of one SDK component type, in one savepoint.
"""
function insert_components!(
    db::SQLite.DB,
    type_name::AbstractString,
    objs::AbstractVector;
    strict::Bool=false,
)
    report = InsertReport()
    components = manifest().components
    if !haskey(components, type_name)
        note_unsupported!(report, strict, type_name, length(objs))
        return report
    end
    plan = components[type_name]
    with_statements(db) do cache
        for obj in objs
            write_entity!(cache, plan, obj)
            write_row!(cache, plan, obj, report, strict)
        end
    end
    return report
end

"""
    insert_component!(db, type_name, obj; strict=false) -> InsertReport
"""
function insert_component!(
    db::SQLite.DB,
    type_name::AbstractString,
    obj::AbstractDict;
    strict::Bool=false,
)
    return insert_components!(db, type_name, [obj]; strict=strict)
end

# A section given as JSON null reads as empty, as in the Python and TypeScript SDKs.
function section_rows(doc::AbstractDict, key::AbstractString)
    rows = something(get(doc, key, nothing), Any[])
    what = "$key row"
    foreach(row -> require_object(row, what), rows)
    return rows
end

function attribute_types(doc::AbstractDict)
    types = Dict{Int, String}()
    for assoc in section_rows(doc, "supplemental_attribute_associations")
        types[Int(assoc["attribute_id"])] = assoc["attribute_type"]
    end
    return types
end

section_size(rows) = length(rows)
section_size(::Nothing) = 0

# Ids of components the insert does not write. Ids follow the int encoder's rule, so
# any other value is never skipped: it reaches the encoder and fails there.
function push_id!(ids::Set{Int}, id)
    if is_int_value(id)
        push!(ids, Int(id))
    end
    return ids
end

# The one rule for association and time series rows; strict mode never gets here, as
# the component itself raised.
names_unsupported(row::AbstractDict, references::Vector{String}, ids::Set{Int}) =
    any(references) do r
        id = get(row, r, nothing)
        return is_int_value(id) && Int(id) in ids
    end

function supplemental_table(attr_type::AbstractString)
    if attr_type in manifest().plant_types
        return "plants"
    end
    return "supplemental_attributes"
end

function write_supplemental!(cache, table::AbstractString, attr_type, attr, what)
    m = manifest()
    if table == "plants"
        value = Dict(k => v for (k, v) in attr if k != "id" && k != "name")
        params = Any[attr["id"], attr["name"], attr_type, canonical_json(value)]
        run_sql(cache, m.plant_sql, params, what)
        return nothing
    end
    value = Dict(k => v for (k, v) in attr if k != "id")
    params = Any[attr["id"], attr_type, canonical_json(value)]
    run_sql(cache, m.supplemental_attribute_sql, params, what)
    return nothing
end

"""
    insert_document!(db, doc; strict=false, time_series=nothing) -> InsertReport

Insert a whole `SystemDocument` (as parsed JSON) in one savepoint: vocabulary, every
entity row, typed rows in foreign-key rank order, supplemental attributes, associations,
then time series associations and their arrays, read from the HDF5 sidecar
`time_series` (only ever read, must exist; needs InfraStore.jl loaded). Any failure
rolls back the whole document.
"""
function insert_document!(
    db::SQLite.DB,
    doc::AbstractDict;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    return insert_parsed_document!(db, doc, strict, time_series, NO_SIDECAR)
end

const NO_SIDECAR = "no time series sidecar given"

# `no_sidecar` is why time series are unsupported when `time_series` is nothing.
function insert_parsed_document!(
    db::SQLite.DB,
    doc::AbstractDict,
    strict::Bool,
    time_series::Union{Nothing, AbstractString},
    no_sidecar::AbstractString,
)
    if !isnothing(time_series) && !isfile(time_series)
        throw(InsertError("time series sidecar $time_series does not exist"))
    end
    m = manifest()
    report = InsertReport()
    components = something(get(doc, "components", nothing), Dict{String, Any}())
    plans = Tuple{ComponentPlan, Vector{Any}}[]
    unsupported_ids = Set{Int}()
    owners = Dict{Int, Tuple{String, String}}()  # id => (owner_type, owner_category)
    for type_name in sort!(collect(keys(components)))
        objs = components[type_name]
        ids = Set{Int}()
        for obj in objs
            obj isa AbstractDict && push_id!(ids, get(obj, "id", nothing))
        end
        foreach(id -> owners[id] = (type_name, "Component"), ids)
        if haskey(m.components, type_name)
            push!(plans, (m.components[type_name], collect(Any, objs)))
        else
            note_unsupported!(report, strict, type_name, length(objs))
            union!(unsupported_ids, ids)
        end
    end
    sort!(plans; by=p -> (p[1].rank, p[1].type_name))
    for section in sort!(collect(keys(m.unsupported_sections)))
        n = section_size(get(doc, section, nothing))
        if n > 0
            mark_unsupported!(report, strict, section, n, m.unsupported_sections[section])
        end
    end
    attr_types = attribute_types(doc)
    for attr in section_rows(doc, "supplemental_attributes")
        id = get(attr, "id", nothing)
        if is_int_value(id) && haskey(attr_types, Int(id))
            owners[Int(id)] = (attr_types[Int(id)], "SupplementalAttribute")
        end
    end
    series = storable_time_series(
        doc,
        time_series,
        no_sidecar,
        report,
        strict,
        unsupported_ids,
        owners,
    )
    with_statements(db) do cache
        seed_vocabulary!(db)
        for (plan, objs) in plans
            for obj in objs
                write_entity!(cache, plan, obj)
            end
        end
        routed = Tuple{String, String, Any, String}[]
        for attr in section_rows(doc, "supplemental_attributes")
            id = Int(attr["id"])
            if !haskey(attr_types, id)
                throw(
                    InsertError(
                        "supplemental attribute id=$id: no association names its type",
                    ),
                )
            end
            attr_type = attr_types[id]
            table = supplemental_table(attr_type)
            what = "$attr_type id=$id"
            run_sql(
                cache,
                "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, ?, ?)",
                Any[id, table, attr_type],
                what,
            )
            push!(routed, (table, attr_type, attr, what))
        end
        for (plan, objs) in plans
            for obj in objs
                write_row!(cache, plan, obj, report, strict)
            end
        end
        for (table, attr_type, attr, what) in routed
            write_supplemental!(cache, table, attr_type, attr, what)
            add_inserted!(report, table)
        end
        for section in m.associations
            for row in section_rows(doc, section.section)
                # A row naming a component that has no table is not written either.
                if names_unsupported(row, section.references, unsupported_ids)
                    add_unsupported!(report, section.section, 1)
                    continue
                end
                what = "$(section.section) row $(JSON.json(row))"
                run_sql(
                    cache,
                    section.row_sql,
                    bound_params(section.bindings, row, what),
                    what,
                )
                add_inserted!(report, section.section)
            end
        end
        if !isempty(series)
            insert_time_series!(cache, m.time_series, series, time_series, report)
        end
    end
    return report
end

"""
    insert_document!(db, path::AbstractString; strict=false, time_series=nothing)

Parse the document at `path`; `time_series` defaults to its `time_series_storage_file`,
resolved beside it (reported unsupported when that file does not exist).
"""
function insert_document!(
    db::SQLite.DB,
    path::AbstractString;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    doc = JSON.parsefile(path; dicttype=Dict{String, Any})
    stored = get(doc, "time_series_storage_file", nothing)
    no_sidecar = NO_SIDECAR
    if isnothing(time_series) && stored isa AbstractString && !isempty(stored)
        default = joinpath(dirname(abspath(path)), stored)
        if isfile(default)
            time_series = default
        else
            no_sidecar = "time series sidecar $default does not exist"
        end
    end
    return insert_parsed_document!(db, doc, strict, time_series, no_sidecar)
end
