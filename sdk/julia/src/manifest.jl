const SUPPORTED_MANIFEST_VERSION = 1

struct Binding
    segments::Vector{String}
    encoding::Encoding
end

struct AttributePlan
    field::String
    registered::Bool
    unit::String
    quantity_kind::String
end

struct ComponentPlan
    type_name::String
    rank::Int
    entity_sql::String
    row_sql::String
    bindings::Vector{Binding}
    entity_bindings::Vector{Binding}
    attributes::Vector{AttributePlan}
    gaps::Vector{String}
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
    unsupported_components::Dict{String, String}
    attribute_sql::String
    plant_types::Set{String}
    plant_sql::String
    supplemental_attribute_sql::String
    associations::Vector{AssociationPlan}
    unsupported_sections::Dict{String, String}
end

parse_bindings(raw) =
    Binding[Binding(String.(split(b["path"], '.')), ENCODINGS[b["encode"]]) for b in raw]

parse_attribute(raw, ::Nothing) = AttributePlan(raw["field"], false, "", "")
parse_attribute(raw, unit::AbstractString) =
    AttributePlan(raw["field"], true, unit, raw["quantity_kind"])

function parse_component(type_name::String, raw::AbstractDict)
    bindings = parse_bindings(raw["bindings"])
    attributes = AttributePlan[parse_attribute(a, a["unit"]) for a in raw["attributes"]]
    known = Set{String}()
    for b in bindings
        push!(known, first(b.segments))
    end
    for a in attributes
        push!(known, a.field)
    end
    union!(known, String.(raw["skip"]), String.(raw["gaps"]))
    return ComponentPlan(
        type_name,
        raw["rank"],
        raw["entity_sql"],
        raw["row_sql"],
        bindings,
        bindings[1:1],
        attributes,
        String.(raw["gaps"]),
        known,
    )
end

function parse_manifest(raw::AbstractDict)
    if raw["manifest_version"] != SUPPORTED_MANIFEST_VERSION
        throw(
            ManifestMismatchError(
                "manifest_version $(raw["manifest_version"]) is not $SUPPORTED_MANIFEST_VERSION",
            ),
        )
    end
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
        Dict{String, String}(raw["unsupported_components"]),
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
