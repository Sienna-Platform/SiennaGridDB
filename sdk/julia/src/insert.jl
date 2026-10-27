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

function skip_field!(report::InsertReport, strict::Bool, type_name, field, what)
    if strict
        throw(InsertError("$what: field $(repr(field)) has no column in GridDB"))
    end
    add_skipped!(report, type_name, field)
    return nothing
end

function mark_unsupported!(report::InsertReport, strict::Bool, key, n::Int, reason)
    if strict
        throw(InsertError("$key ($n rows): $reason"))
    end
    add_unsupported!(report, key, n)
    return nothing
end

"""
The arm key of a row: its own value of the unit field (e.g. power_units), or ""
for a field with one fixed unit.
"""
function arm_key(attr::AttributePlan, obj::AbstractDict)
    if isempty(attr.unit_field)
        return ""
    end
    return get(obj, attr.unit_field, "")
end

function attribute_params(attr::AttributePlan, plan::ComponentPlan, obj, value, unit_cols)
    return Any[obj["id"], plan.type_name, attr.field, canonical_json(value), unit_cols...]
end

function write_attribute!(cache, report, strict, plan, attr::AttributePlan, obj, what)
    value = get(obj, attr.field, nothing)
    if isnothing(value)
        return nothing
    end
    key = arm_key(attr, obj)
    if haskey(attr.arms, key)
        arm = attr.arms[key]
        params = attribute_params(attr, plan, obj, value, Any[arm.unit, arm.quantity_kind])
        run_sql(cache, manifest().attribute_sql, params, what)
        return nothing
    end
    if attr.exempt || unit_free_value(value)
        params = attribute_params(attr, plan, obj, value, Any[missing, missing])
        run_sql(cache, manifest().attribute_sql, params, what)
        return nothing
    end
    skip_field!(report, strict, plan.type_name, attr.field, what)
    return nothing
end

function write_row!(cache, plan::ComponentPlan, obj::AbstractDict, report, strict::Bool)
    what = describe(plan.type_name, obj)
    run_sql(cache, plan.row_sql, bound_params(plan.bindings, obj, what), what)
    for attr in plan.attributes
        write_attribute!(cache, report, strict, plan, attr, obj, what)
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
    mark_unsupported!(report, strict, type_name, n, "not a GridDB component type")
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

# A foreign key cannot reach into JSON, so the insert is the only place that sees a payload
# reference to an association it does not store.
function report_dangling!(report::InsertReport, strict::Bool, plans, attrs, series)
    stored_ids = Set{Int}(
        Int(r["association_id"]) for
        r in series if is_int_value(get(r, "association_id", nothing))
    )
    payloads = Tuple{Int, Any}[]
    for o in Iterators.flatten((Iterators.flatten(objs for (_, objs) in plans), attrs))
        if is_object(o) && is_int_value(get(o, "id", nothing))
            push!(payloads, (Int(o["id"]), o))
        end
    end
    dangling = dangling_references(payloads, stored_ids)
    isempty(dangling) && return nothing
    entity_id, key, ref = minimum(dangling)
    reason = "no stored time series association has the id (first: entity $entity_id $key=$ref)"
    key_name = "dangling_time_series_references"
    mark_unsupported!(report, strict, key_name, length(dangling), reason)
    return nothing
end

"""
    insert_document!(db, doc; strict=false, time_series=nothing) -> InsertReport

Insert a whole `SystemDocument` (as parsed JSON) in one savepoint: vocabulary, every
entity row, typed rows in foreign-key rank order, supplemental attributes, associations,
time series. Any failure rolls back the whole document. `time_series` is the HDF5 sidecar
holding the arrays (`time_series_storage_file`); it is only read, and needs InfraStore.jl.
"""
function insert_document!(
    db::SQLite.DB,
    doc::AbstractDict;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    m = manifest()
    report = InsertReport()
    components = something(get(doc, "components", nothing), Dict{String, Any}())
    plans = Tuple{ComponentPlan, Vector{Any}}[]
    # References to a derived series name its source, which GridDB stores instead.
    sources = derived_sources(section_rows(doc, m.time_series.section))
    unsupported_ids = Set{Int}()
    owners = Dict{Int, Tuple{String, String}}()
    for type_name in sort!(collect(keys(components)))
        objs = Any[point_at_sources(o, sources) for o in components[type_name]]
        # Ids follow the int encoder's rule, so any other value is never skipped:
        # it reaches the encoder and fails there.
        ids = Set{Int}(
            Int(o["id"]) for
            o in objs if is_object(o) && is_int_value(get(o, "id", nothing))
        )
        foreach(id -> owners[id] = (type_name, "Component"), ids)
        if haskey(m.components, type_name)
            push!(plans, (m.components[type_name], objs))
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
    attrs = point_at_sources(section_rows(doc, "supplemental_attributes"), sources)
    for attr in attrs
        id = get(attr, "id", nothing)
        if is_int_value(id) && haskey(attr_types, Int(id))
            owners[Int(id)] = (attr_types[Int(id)], "SupplementalAttribute")
        end
    end
    series = storable_time_series(doc, report, strict, unsupported_ids, owners)
    store_series = !isempty(series) && values_storable(time_series)
    if !isempty(series) && !store_series
        reason = values_missing_reason(time_series)
        mark_unsupported!(report, strict, "time_series_values", length(series), reason)
    end
    report_dangling!(report, strict, plans, attrs, series)
    with_statements(db) do cache
        seed_vocabulary!(db)
        for (plan, objs) in plans
            for obj in objs
                write_entity!(cache, plan, obj)
            end
        end
        routed = Tuple{String, String, Any, String}[]
        for attr in attrs
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
        insert_associations!(cache, m.time_series, series, report)
        if store_series
            store_values!(db, m.time_series, series, time_series)
        end
    end
    return report
end
