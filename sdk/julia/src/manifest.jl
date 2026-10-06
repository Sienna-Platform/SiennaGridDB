struct Binding
    segments::Vector{String}
    encoding::Encoding
end

struct UnitArm
    unit::String
    quantity_kind::String
end

"""
How to write one attribute-channel field. `arms` maps the row's value of
`unit_field` (or "" when `unit_field` is empty) to its registered unit; `exempt`
marks a unitless structured value that attribute_identifiers lets through.
"""
struct AttributePlan
    field::String
    unit_field::String
    arms::Dict{String, UnitArm}
    exempt::Bool
end

struct ComponentPlan
    type_name::String
    rank::Int
    entity_sql::String
    row_sql::String
    bindings::Vector{Binding}
    entity_bindings::Vector{Binding}
    attributes::Vector{AttributePlan}
    known_fields::Set{String}
end

struct AssociationPlan
    section::String
    row_sql::String
    bindings::Vector{Binding}
end

struct Manifest
    schema_user_version::Int
    vocabulary::Dict{String, Any}
    components::Dict{String, ComponentPlan}
    attribute_sql::String
    plant_types::Set{String}
    plant_sql::String
    supplemental_attribute_sql::String
    associations::Vector{AssociationPlan}
    unsupported_sections::Dict{String, String}
end

parse_bindings(raw) =
    Binding[Binding(String.(split(b["path"], '.')), ENCODINGS[b["encode"]]) for b in raw]

unit_field_name(::Nothing) = ""
unit_field_name(name::AbstractString) = String(name)

function parse_attribute(raw::AbstractDict)
    arms = Dict{String, UnitArm}(
        String(k) => UnitArm(v["unit"], v["quantity_kind"]) for (k, v) in raw["arms"]
    )
    return AttributePlan(
        raw["field"],
        unit_field_name(raw["unit_field"]),
        arms,
        raw["exempt"],
    )
end

function parse_component(type_name::String, raw::AbstractDict)
    bindings = parse_bindings(raw["bindings"])
    attributes = AttributePlan[parse_attribute(a) for a in raw["attributes"]]
    known = Set{String}()
    for b in bindings
        push!(known, first(b.segments))
    end
    for a in attributes
        push!(known, a.field)
    end
    union!(known, String.(raw["skip"]))
    return ComponentPlan(
        type_name,
        raw["rank"],
        raw["entity_sql"],
        raw["row_sql"],
        bindings,
        bindings[1:1],
        attributes,
        known,
    )
end

function parse_manifest(raw::AbstractDict)
    components = Dict{String, ComponentPlan}(
        String(n) => parse_component(String(n), e) for (n, e) in raw["components"]
    )
    supplemental = raw["supplemental_attributes"]
    associations = AssociationPlan[
        AssociationPlan(a["section"], a["row_sql"], parse_bindings(a["bindings"])) for
        a in raw["associations"]
    ]
    return Manifest(
        raw["schema_user_version"],
        raw["vocabulary"],
        components,
        raw["attribute_sql"],
        Set{String}(supplemental["plant_types"]),
        supplemental["plant_sql"],
        supplemental["attribute_sql"],
        associations,
        Dict{String, String}(raw["unsupported_sections"]),
    )
end

const MANIFEST = Ref{Manifest}()

function manifest()
    if !isassigned(MANIFEST)
        path = joinpath(DATA_DIR, "insert_manifest.json")
        MANIFEST[] = parse_manifest(JSON.parsefile(path; dicttype=Dict{String, Any}))
    end
    return MANIFEST[]
end
