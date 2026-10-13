# julia sdk/julia/test/infrastore/run_infrastore_tests.jl
# Needs an infrastore checkout with the SQLite export (after 0.14.1): INFRASTORE_PATH,
# default a sibling of this repository, and INFRASTORE_LIB naming its built
# libinfrastore_ffi. Builds a temporary environment that devs InfraStore.jl and
# SiennaGridDBTools.
using Pkg

const HERE = @__DIR__
const PKG_ROOT = normpath(joinpath(HERE, "..", ".."))
const REPO_ROOT = normpath(joinpath(PKG_ROOT, "..", ".."))
const INFRASTORE =
    get(ENV, "INFRASTORE_PATH", normpath(joinpath(REPO_ROOT, "..", "infrastore")))

Pkg.activate(; temp=true)
Pkg.develop([
    PackageSpec(; path=joinpath(INFRASTORE, "julia", "InfraStore.jl")),
    PackageSpec(; path=PKG_ROOT),
])
Pkg.add(["Test", "DBInterface", "JSON", "SQLite", "Dates"])
include(joinpath(HERE, "infrastore_tests.jl"))
