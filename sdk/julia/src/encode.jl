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

"""
RFC 8785 (JCS) text, the form the three SDKs write: keys in UTF-16 code-unit order,
numbers as ECMAScript writes them (1.0 -> 1), no whitespace.
"""
function canonical_json(value)
    io = IOBuffer()
    write_json(io, value)
    return String(take!(io))
end

write_json(io::IO, ::Nothing) = print(io, "null")
function write_json(io::IO, v::Bool)
    if v
        print(io, "true")
    else
        print(io, "false")
    end
    return nothing
end
write_json(io::IO, v::Integer) = print(io, v)
write_json(io::IO, v::AbstractFloat) = print(io, es_number(Float64(v)))
write_json(io::IO, v::AbstractString) = write_string(io, v)
function write_json(io::IO, v::AbstractVector)
    print(io, '[')
    for (i, x) in enumerate(v)
        if i > 1
            print(io, ',')
        end
        write_json(io, x)
    end
    print(io, ']')
    return nothing
end
function write_json(io::IO, d::AbstractDict)
    entries = sort!([(String(k), v) for (k, v) in d]; by=e -> transcode(UInt16, e[1]))
    print(io, '{')
    for (i, (k, v)) in enumerate(entries)
        if i > 1
            print(io, ',')
        end
        write_string(io, k)
        print(io, ':')
        write_json(io, v)
    end
    print(io, '}')
    return nothing
end
write_json(::IO, v) = throw(EncodeError("not a JSON value: $(repr(v))"))

# ECMAScript escapes only these; JSON.jl also escapes DEL, so it cannot write the text.
const SHORT_ESCAPES = Dict(
    '"' => "\\\"",
    '\\' => "\\\\",
    '\b' => "\\b",
    '\f' => "\\f",
    '\n' => "\\n",
    '\r' => "\\r",
    '\t' => "\\t",
)

function write_string(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if haskey(SHORT_ESCAPES, c)
            print(io, SHORT_ESCAPES[c])
        elseif c < ' '
            print(io, "\\u", string(UInt32(c); base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end

"""
ECMAScript Number::toString, from the shortest round-trip digits `string` gives.
"""
function es_number(x::Float64)
    if !isfinite(x)
        throw(EncodeError("$x: GridDB stores finite numbers only"))
    end
    if iszero(x)
        return "0"
    end
    sign = ""
    if signbit(x)
        sign = "-"
    end
    parts = split(string(abs(x)), 'e')
    exponent = 0
    if length(parts) == 2
        exponent = parse(Int, parts[2])
    end
    whole, fraction = split(parts[1], '.')
    all_digits = whole * fraction
    digits = lstrip(all_digits, '0')
    # n: where the decimal point sits relative to the first significant digit.
    n = length(whole) + exponent - (length(all_digits) - length(digits))
    digits = rstrip(digits, '0')
    k = length(digits)
    if k <= n <= 21
        return sign * digits * "0"^(n - k)
    elseif 0 < n <= 21
        return sign * digits[1:n] * "." * digits[(n + 1):end]
    elseif -6 < n <= 0
        return sign * "0." * "0"^(-n) * digits
    end
    e = n - 1
    mark = "-"
    if e >= 0
        mark = "+"
    end
    if k == 1
        return "$sign$(digits)e$mark$(abs(e))"
    end
    return "$sign$(digits[1]).$(digits[2:end])e$mark$(abs(e))"
end

"""
What the int encoder accepts: an integer or integral float, not a `Bool`, in Int64.
"""
is_int_value(v::Real) = isinteger(v) && typemin(Int) <= v <= typemax(Int)
is_int_value(::Bool) = false
is_int_value(_) = false

function encode(::IntEncoding, v)
    if !is_int_value(v)
        throw(EncodeError("expected an integer, got $(repr(v))"))
    end
    return Int(v)
end
function encode(::RealEncoding, v::Real)
    if !isfinite(v)
        throw(EncodeError("expected a finite number, got $(repr(v))"))
    end
    return Float64(v)
end
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
    if isnan(v)
        bits = reinterpret(UInt64, NaN)
    else
        bits = reinterpret(UInt64, Float64(v))
    end
    return write(io, UInt8('f'), htol(bits))
end
function write_feature(io::IO, v::AbstractString)
    return write(io, UInt8('s'), htol(UInt64(ncodeunits(v))), v)
end
function write_feature(::IO, v)
    throw(EncodeError("expected an int, float, bool or string feature, got $(repr(v))"))
end

encode(::FeaturesHashEncoding, v) = features_hash(v)
