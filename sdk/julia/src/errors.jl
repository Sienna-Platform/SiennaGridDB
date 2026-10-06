"""
A database could not be created or opened.
"""
struct GridDBToolsError <: Exception
    msg::String
end

"""
A row or field could not be written, or `strict=true` met data GridDB cannot store.
"""
struct InsertError <: Exception
    msg::String
end

Base.showerror(io::IO, e::GridDBToolsError) = print(io, "GridDBToolsError: ", e.msg)
Base.showerror(io::IO, e::InsertError) = print(io, "InsertError: ", e.msg)

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
