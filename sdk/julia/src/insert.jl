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
        throw(GapValueError("$what: field $(repr(field)) has no column in GridDB"))
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

function unit_columns(attr::AttributePlan)
    if attr.registered
        return Any[attr.unit, attr.quantity_kind]
    end
    return Any[missing, missing]
end

function attribute_params(attr::AttributePlan, plan::ComponentPlan, obj, value)
    return Any[
        obj["id"],
        plan.type_name,
        attr.field,
        canonical_json(value),
        unit_columns(attr)...,
    ]
end

function write_attribute!(cache, report, strict, plan, attr::AttributePlan, obj, what)
    value = get(obj, attr.field, nothing)
    if isnothing(value)
        return nothing
    end
    if !attr.registered && !unit_free_value(value)
        skip_field!(report, strict, plan.type_name, attr.field, what)
        return nothing
    end
    run_sql(cache, manifest().attribute_sql, attribute_params(attr, plan, obj, value), what)
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

function write_entity!(cache, plan::ComponentPlan, obj::AbstractDict)
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

function attribute_types(doc::AbstractDict)
    types = Dict{Int, String}()
    for assoc in get(doc, "supplemental_attribute_associations", Any[])
        types[Int(assoc["attribute_id"])] = assoc["attribute_type"]
    end
    return types
end

section_size(rows) = length(rows)
section_size(::Nothing) = 0

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
    insert_document!(db, doc; strict=false) -> InsertReport

Insert a whole `SystemDocument` (as parsed JSON) in one savepoint: vocabulary, every
entity row, typed rows in foreign-key rank order, supplemental attributes, associations.
Any failure rolls back the whole document.
"""
function insert_document!(db::SQLite.DB, doc::AbstractDict; strict::Bool=false)
    m = manifest()
    report = InsertReport()
    components = get(doc, "components", Dict{String, Any}())
    plans = Tuple{ComponentPlan, Vector{Any}}[]
    for type_name in sort!(collect(keys(components)))
        objs = components[type_name]
        if haskey(m.components, type_name)
            push!(plans, (m.components[type_name], collect(Any, objs)))
        else
            note_unsupported!(report, strict, type_name, length(objs))
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
    with_statements(db) do cache
        seed_vocabulary!(db)
        for (plan, objs) in plans
            for obj in objs
                write_entity!(cache, plan, obj)
            end
        end
        routed = Tuple{String, String, Any, String}[]
        for attr in get(doc, "supplemental_attributes", Any[])
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
            for row in get(doc, section.section, Any[])
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
    end
    return report
end
