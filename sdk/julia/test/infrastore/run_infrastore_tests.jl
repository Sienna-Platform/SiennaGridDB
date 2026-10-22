# julia sdk/julia/test/infrastore/run_infrastore_tests.jl
# Tests the InfraStore extension against the registered InfraStore.jl. To test an
# infrastore checkout instead, set INFRASTORE_PATH to it and INFRASTORE_LIB to its
# built libinfrastore_ffi.
using Pkg

const HERE = @__DIR__
const PKG_ROOT = normpath(joinpath(HERE, "..", ".."))

Pkg.activate(; temp=true)
Pkg.develop(; path=PKG_ROOT)
if haskey(ENV, "INFRASTORE_PATH")
    Pkg.develop(; path=joinpath(ENV["INFRASTORE_PATH"], "julia", "InfraStore.jl"))
else
    Pkg.add(; name="InfraStore", version="0.15")
end
Pkg.add(["Test", "DBInterface", "JSON", "SQLite", "Dates"])
include(joinpath(HERE, "infrastore_tests.jl"))
