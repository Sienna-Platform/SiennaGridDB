abstract type Encoding end
struct IntEncoding <: Encoding end
struct RealEncoding <: Encoding end
struct TextEncoding <: Encoding end
struct BoolEncoding <: Encoding end
struct JSONEncoding <: Encoding end
struct FeaturesHashEncoding <: Encoding end

const ENCODINGS = Dict{String, Encoding}(
    "int" => IntEncoding(),
    "real" => RealEncoding(),
    "text" => TextEncoding(),
    "bool" => BoolEncoding(),
    "json" => JSONEncoding(),
    "features_hash" => FeaturesHashEncoding(),
)

canonical_json(value) = JSON.json(value)

"""
What the int encoder accepts: an integer or integral float, not a `Bool`, in Int64.
"""
is_int_value(v::Real) = !(v isa Bool) && isinteger(v) && typemin(Int) <= v <= typemax(Int)
is_int_value(_) = false

function encode(::IntEncoding, v)
    if !is_int_value(v)
        throw(EncodeError("expected an integer, got $(repr(v))"))
    end
    return Int(v)
end
encode(::RealEncoding, v::Real) = Float64(v)
encode(::RealEncoding, v::Bool) = throw(EncodeError("expected a number, got $(repr(v))"))
encode(::RealEncoding, v) = throw(EncodeError("expected a number, got $(repr(v))"))
encode(::TextEncoding, v::AbstractString) = String(v)
encode(::TextEncoding, v) = throw(EncodeError("expected a string, got $(repr(v))"))
encode(::BoolEncoding, v::Bool) = Int(v)
encode(::BoolEncoding, v) = throw(EncodeError("expected a boolean, got $(repr(v))"))
encode(::JSONEncoding, v) = canonical_json(v)
encode(::FeaturesHashEncoding, v) = features_hash(v)

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
    features_hash(features) -> String

infrastore's content hash of a feature map (crates/infrastore-core/src/hash.rs) as
lowercase hex. Keys go in UTF-8 byte order (`String` `isless` compares bytes); an
`Integer` hashes as Int and an `AbstractFloat` as Float, as JSON.jl parses them.
"""
function features_hash(features::AbstractDict)
    io = IOBuffer()
    write(io, "features\0", htol(UInt64(length(features))))
    for key in sort!(String[k for k in keys(features)])
        write(io, htol(UInt64(ncodeunits(key))), key)
        write_feature(io, features[key])
    end
    return bytes2hex(SHA.sha256(take!(io)))
end
features_hash(v) = throw(EncodeError("expected a feature map, got $(repr(v))"))

write_feature(io::IO, v::Bool) = write(io, UInt8('b'), UInt8(v))
function write_feature(io::IO, v::Integer)
    if !(typemin(Int64) <= v <= typemax(Int64))
        throw(EncodeError("feature integer $v does not fit in 64 bits"))
    end
    return write(io, UInt8('i'), htol(Int64(v)))
end
# Any NaN hashes as Rust's f64::NAN, which is Julia's NaN.
function write_feature(io::IO, v::AbstractFloat)
    bits = isnan(v) ? reinterpret(UInt64, NaN) : reinterpret(UInt64, Float64(v))
    return write(io, UInt8('f'), htol(bits))
end
function write_feature(io::IO, v::AbstractString)
    return write(io, UInt8('s'), htol(UInt64(ncodeunits(v))), v)
end
function write_feature(::IO, v)
    throw(EncodeError("expected an int, float, bool or string feature, got $(repr(v))"))
end
