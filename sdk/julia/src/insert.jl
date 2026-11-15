const SAVEPOINT = "sienna_griddb_tools_insert"

# The caller's connection may have foreign keys off. The PRAGMA does nothing inside an
# open transaction, so read it back.
function require_foreign_keys(db::SQLite.DB)
    DBInterface.execute(db, "PRAGMA foreign_keys = ON")
    if scalar(db, "PRAGMA foreign_keys") != 1
        msg = "foreign keys are off and cannot be turned on inside an open transaction"
        throw(InsertError(msg))
    end
    return nothing
end

function require_schema_version(db::SQLite.DB)
    found = scalar(db, "PRAGMA user_version")
    expected = manifest().schema_user_version
    if found != expected
        throw(
            InsertError("database has user_version $found; this package writes $expected"),
        )
    end
    return nothing
end

function with_savepoint(f::Function, db::SQLite.DB)
    require_foreign_keys(db)
    require_schema_version(db)
    DBInterface.execute(db, "SAVEPOINT $SAVEPOINT")
    result = try
        f()
    catch e
        rollback!(db, e)
        rethrow()
    end
    # RELEASE of the outermost savepoint is the commit: deferred foreign keys fail here.
    try
        DBInterface.execute(db, "RELEASE $SAVEPOINT")
    catch e
        rollback!(db, e)
        throw(InsertError("the insert fails its commit checks: $(sprint(showerror, e))"))
    end
    return result
end

function rollback!(db::SQLite.DB, cause)
    try
        DBInterface.execute(db, "ROLLBACK TO $SAVEPOINT")
        DBInterface.execute(db, "RELEASE $SAVEPOINT")
    catch e
        first_error = sprint(showerror, cause)
        throw(InsertError("rollback failed ($(sprint(showerror, e))) after: $first_error"))
    end
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
        return with_savepoint(() -> f(cache), db)
    finally
        close_statements!(cache)
    end
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

function json_text(value, what::AbstractString)
    try
        return canonical_json(value)
    catch e
        throw(wrap_error(e, what))
    end
end

function attribute_params(
    attr::AttributePlan,
    plan::ComponentPlan,
    obj,
    value,
    unit_cols,
    what,
)
    return Any[obj["id"], plan.type_name, attr.field, json_text(value, what), unit_cols...]
end

function write_attribute!(cache, report, strict, plan, attr::AttributePlan, obj, what)
    value = get(obj, attr.field, nothing)
    if isnothing(value)
        return nothing
    end
    key = arm_key(attr, obj)
    if haskey(attr.arms, key)
        arm = attr.arms[key]
        units = Any[arm.unit, arm.quantity_kind]
        params = attribute_params(attr, plan, obj, value, units, what)
        run_sql(cache, manifest().attribute_sql, params, what)
        return nothing
    end
    if attr.exempt || unit_free_value(value)
        params = attribute_params(attr, plan, obj, value, Any[missing, missing], what)
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

# An id the insert needs before it writes a row, by the int encoder's rule.
function required_id(row::AbstractDict, key::String, what::String)
    value = get(row, key, nothing)
    if isnothing(value)
        throw(InsertError("$what: no $key"))
    end
    if !is_int_value(value)
        throw(InsertError("$what: $key: expected an integer, got $(repr(value))"))
    end
    return Int(value)
end

entry_list(objs::AbstractVector, ::AbstractString) = objs
function entry_list(_, type_name::AbstractString)
    throw(InsertError("components.$type_name: not a list"))
end

function attribute_types(doc::AbstractDict)
    types = Dict{Int, String}()
    for assoc in section_rows(doc, "supplemental_attribute_associations")
        id = required_id(assoc, "attribute_id", "supplemental_attribute_associations row")
        types[id] = assoc["attribute_type"]
    end
    return types
end

# Rows in a list section; a non-empty object or scalar is one.
section_size(rows::AbstractVector) = length(rows)
function section_size(value::Union{AbstractDict, AbstractString})
    if isempty(value)
        return 0
    end
    return 1
end
section_size(::Nothing) = 0
function section_size(value::Number)
    if iszero(value)
        return 0
    end
    return 1
end

# An entry's id, by the int encoder's rule; any other value is never skipped, it
# reaches the encoder and fails there.
function push_id!(ids::Set{Int}, id)
    if is_int_value(id)
        push!(ids, Int(id))
    end
    return ids
end
push_entry_id!(ids::Set{Int}, obj::AbstractDict) = push_id!(ids, get(obj, "id", nothing))
push_entry_id!(ids::Set{Int}, _) = ids

function names_unsupported(row::AbstractDict, references::Vector{String}, ids::Set{Int})
    return any(references) do r
        id = get(row, r, nothing)
        return is_int_value(id) && Int(id) in ids
    end
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
        params = Any[attr["id"], attr["name"], attr_type, json_text(value, what)]
        run_sql(cache, m.plant_sql, params, what)
        return nothing
    end
    value = Dict(k => v for (k, v) in attr if k != "id")
    params = Any[attr["id"], attr_type, json_text(value, what)]
    run_sql(cache, m.supplemental_attribute_sql, params, what)
    return nothing
end

# A foreign key cannot reach into JSON, so the insert is the only place that sees a payload
# reference to an association it does not store. Ids are the document's own: a reference
# to a derived series resolves to its stored source.
function report_dangling!(report::InsertReport, strict::Bool, plans, attrs, series, sources)
    stored_ids = Set{Int}(
        Int(r["association_id"]) for
        r in series if is_int_value(get(r, "association_id", nothing))
    )
    for (derived, source) in sources
        if source in stored_ids
            push!(stored_ids, derived)
        end
    end
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

# The insert's entity ids must miss the ones stored, so a portfolio numbers its own above
# its base system's; the UNIQUE failure alone would not say why.
function require_new_ids(db::SQLite.DB, plans, attrs)
    ids = Set{Int}()
    foreach(o -> push_entry_id!(ids, o), Iterators.flatten(objs for (_, objs) in plans))
    foreach(o -> push_entry_id!(ids, o), attrs)
    sql = "SELECT id FROM entities WHERE id IN (SELECT value FROM json_each(?)) ORDER BY id"
    taken = [r.id for r in DBInterface.execute(db, sql, (JSON.json(collect(ids)),))]
    isempty(taken) && return nothing
    throw(
        InsertError(
            "$(length(taken)) ids are already in the database (first: $(first(taken))): " *
            "a document's ids must miss the stored ones, so a portfolio numbers its own " *
            "above its base system's",
        ),
    )
end

"""
    insert_document!(db, doc; strict=false, time_series=nothing) -> InsertReport

Insert a whole `SystemDocument` (as parsed JSON) in one savepoint: vocabulary, every
entity row, typed rows in foreign-key rank order, supplemental attributes, associations,
time series. Any failure rolls back the whole document. `time_series` is the HDF5 sidecar
holding the arrays (`time_series_storage_file`); it is only read, and needs InfraStore.jl.
The sidecar is a `time_series_stores` row, and its series ids move past every id stored.
"""
function insert_document!(
    db::SQLite.DB,
    doc::AbstractDict;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    return with_statements(db) do cache
        return insert_document_rows!(cache, doc, strict, time_series)
    end
end

function insert_document_rows!(
    cache::StatementCache,
    doc::AbstractDict,
    strict::Bool,
    time_series,
)
    db = cache.db
    m = manifest()
    report = InsertReport()
    components = something(get(doc, "components", nothing), Dict{String, Any}())
    plans = Tuple{ComponentPlan, Vector{Any}}[]
    unsupported_ids = Set{Int}()
    owners = Dict{Int, Tuple{String, String}}()
    for type_name in sort!(collect(keys(components)))
        objs = Any[o for o in entry_list(components[type_name], type_name)]
        ids = Set{Int}()
        foreach(o -> push_entry_id!(ids, o), objs)
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
    attrs = section_rows(doc, "supplemental_attributes")
    for attr in attrs
        id = get(attr, "id", nothing)
        if is_int_value(id) && haskey(attr_types, Int(id))
            owners[Int(id)] = (attr_types[Int(id)], "SupplementalAttribute")
        end
    end
    sources = derived_sources(section_rows(doc, m.time_series.section))
    series = storable_time_series(doc, report, strict, unsupported_ids, owners)
    store_series = !isempty(series) && values_storable(time_series)
    if !isempty(series) && !store_series
        reason = values_missing_reason(time_series)
        mark_unsupported!(report, strict, "time_series_values", length(series), reason)
    end
    report_dangling!(report, strict, plans, attrs, series, sources)
    # Read inside the savepoint, so no other writer can store ids past it first. Series ids
    # move past every id stored, and references to a derived series name its source, which
    # GridDB stores instead.
    offset = Int(scalar(db, m.time_series.id_offset_sql))
    remap = SeriesRemap(sources, offset)
    plans =
        [(plan, Any[remap_references(o, remap) for o in objs]) for (plan, objs) in plans]
    attrs = remap_references(attrs, remap)
    series = shift_ids(series, offset)
    require_new_ids(db, plans, attrs)
    seed_vocabulary!(db)
    for (plan, objs) in plans
        for obj in objs
            write_entity!(cache, plan, obj)
        end
    end
    routed = Tuple{String, String, Any, String}[]
    for attr in attrs
        id = required_id(attr, "id", "supplemental attribute")
        if !haskey(attr_types, id)
            throw(
                InsertError("supplemental attribute id=$id: no association names its type"),
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
            run_sql(cache, section.row_sql, bound_params(section.bindings, row, what), what)
            add_inserted!(report, section.section)
        end
    end
    if !isempty(series)
        ts = m.time_series
        DBInterface.execute(db, ts.store_sql, (offset, something(time_series, missing)))
        store_id = Int(SQLite.last_insert_rowid(db))
        insert_associations!(cache, ts, series, report)
        ids = JSON.json([r["association_id"] for r in series])
        DBInterface.execute(db, ts.store_rows_sql, (store_id, ids))
        if store_series
            store_values!(db, ts, series, time_series, store_id)
        end
    end
    return report
end

# A document file, or the one .json document in a bundle directory (PSIP writes a
# portfolio's base system as base_system/system.json).
function document_path(path::AbstractString)
    isdir(path) || return path
    docs = sort!(filter(f -> endswith(f, ".json"), readdir(path)))
    if length(docs) != 1
        throw(InsertError("$path: expected one .json document, found $(length(docs))"))
    end
    return joinpath(path, only(docs))
end

# A file a document names by basename, resolved next to it.
names_file(::Nothing) = false
names_file(name::AbstractString) = !isempty(name)
beside(path::AbstractString, name::AbstractString) = joinpath(dirname(abspath(path)), name)

read_document(path::AbstractString) = JSON.parsefile(path; dicttype=Dict{String, Any})

# A document with its own sidecar: its time_series_storage_file, resolved next to it.
function insert_beside!(db::SQLite.DB, path::AbstractString, doc; strict::Bool)
    name = get(doc, "time_series_storage_file", nothing)
    if names_file(name)
        return insert_document!(db, doc; strict=strict, time_series=beside(path, name))
    end
    return insert_document!(db, doc; strict=strict)
end

insert_top!(db, path, doc, ::Nothing; strict::Bool) =
    insert_beside!(db, path, doc; strict=strict)
function insert_top!(db, path, doc, sidecar::AbstractString; strict::Bool)
    return insert_document!(db, doc; strict=strict, time_series=sidecar)
end

"""
    insert_file!(db, path; strict=false, time_series=nothing) -> InsertReport

Insert the document at `path` (a file or bundle directory) with its sidecar: `time_series`,
else its `time_series_storage_file`. A portfolio's `base_system_file` goes in first, with
its own sidecar; both in one savepoint.
"""
function insert_file!(
    db::SQLite.DB,
    path::AbstractString;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    path = document_path(path)
    doc = read_document(path)
    report = InsertReport()
    with_savepoint(db) do
        base_name = get(doc, "base_system_file", nothing)
        if names_file(base_name)
            base = document_path(beside(path, base_name))
            merge_report!(
                report,
                insert_beside!(db, base, read_document(base); strict=strict),
            )
        end
        merge_report!(report, insert_top!(db, path, doc, time_series; strict=strict))
        return nothing
    end
    return report
end
