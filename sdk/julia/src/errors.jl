abstract type GridDBToolsError <: Exception end

for name in (
    :DatabaseExistsError,
    :SQLiteVersionError,
    :ManifestMismatchError,
    :InsertError,
    :UnsupportedComponentError,
    :GapValueError,
)
    @eval begin
        struct $name <: GridDBToolsError
            msg::String
        end
        Base.showerror(io::IO, e::$name) = print(io, $(string(name)), ": ", e.msg)
    end
end

struct EncodeError <: Exception
    msg::String
end

function describe(type_name::AbstractString, obj::AbstractDict)
    parts = String[type_name]
    if haskey(obj, "id")
        push!(parts, "id=$(obj["id"])")
    end
    if haskey(obj, "name")
        push!(parts, "name=$(repr(obj["name"]))")
    end
    return join(parts, " ")
end
