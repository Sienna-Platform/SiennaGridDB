abstract type Encoding end
struct IntEncoding <: Encoding end
struct RealEncoding <: Encoding end
struct TextEncoding <: Encoding end
struct BoolEncoding <: Encoding end
struct JSONEncoding <: Encoding end

const ENCODINGS = Dict{String, Encoding}(
    "int" => IntEncoding(),
    "real" => RealEncoding(),
    "text" => TextEncoding(),
    "bool" => BoolEncoding(),
    "json" => JSONEncoding(),
)

canonical_json(value) = JSON.json(value)

encode(::IntEncoding, v::Integer) = Int(v)
encode(::IntEncoding, v::Bool) = throw(EncodeError("expected an integer, got $(repr(v))"))
function encode(::IntEncoding, v::AbstractFloat)
    if !isinteger(v)
        throw(EncodeError("expected an integer, got $(repr(v))"))
    end
    return Int(v)
end
encode(::IntEncoding, v) = throw(EncodeError("expected an integer, got $(repr(v))"))
encode(::RealEncoding, v::Real) = Float64(v)
encode(::RealEncoding, v::Bool) = throw(EncodeError("expected a number, got $(repr(v))"))
encode(::RealEncoding, v) = throw(EncodeError("expected a number, got $(repr(v))"))
encode(::TextEncoding, v::AbstractString) = String(v)
encode(::TextEncoding, v) = throw(EncodeError("expected a string, got $(repr(v))"))
encode(::BoolEncoding, v::Bool) = Int(v)
encode(::BoolEncoding, v) = throw(EncodeError("expected a boolean, got $(repr(v))"))
encode(::JSONEncoding, v) = canonical_json(v)

is_object(::AbstractDict) = true
is_object(_) = false

"""
JSON null binds SQL NULL; anything else goes through `encode`. Kept apart from `encode`
so a `Nothing` method there cannot be ambiguous with each encoding's catch-all method.
"""
bind_value(::Encoding, ::Nothing) = missing
bind_value(encoding::Encoding, v) = encode(encoding, v)

"""
The encoded value at the path `segments`, or `missing` when any segment is absent.
"""
function bound_value(encoding::Encoding, obj::AbstractDict, segments::Vector{String})
    node = obj
    for segment in segments
        if !is_object(node) || !haskey(node, segment)
            return missing
        end
        node = node[segment]
    end
    return bind_value(encoding, node)
end

"""
Values GridDB accepts in an attribute row without a registered unit.
"""
unit_free_value(::AbstractString) = true
unit_free_value(::Bool) = true
unit_free_value(_) = false
