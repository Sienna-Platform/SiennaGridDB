# julia sdk/julia/test/ext/run_ext_tests.jl
# Needs a PowerOpenAPIModels monorepo checkout: POWER_OPENAPI_MODELS_PATH, default a
# sibling of this repository. The SDK packages are unregistered, so this builds a
# temporary environment that devs all seven plus SiennaGridDBTools.
using Pkg

const HERE = @__DIR__
const PKG_ROOT = normpath(joinpath(HERE, "..", ".."))
const REPO_ROOT = normpath(joinpath(PKG_ROOT, "..", ".."))
const SDK = get(
    ENV,
    "POWER_OPENAPI_MODELS_PATH",
    normpath(joinpath(REPO_ROOT, "..", "PowerOpenAPIModels")),
)
const SUBPACKAGES = [
    "InfrastructureCoreOpenAPIModels.jl",
    "InfrastructureTimeSeriesOpenAPIModels.jl",
    "PowerCoreOpenAPIModels.jl",
    "PowerOperationsOpenAPIModels.jl",
    "PowerInvestmentsOpenAPIModels.jl",
    "PowerDynamicsOpenAPIModels.jl",
    "PowerOpenAPIModels.jl",
]

Pkg.activate(; temp=true)
Pkg.develop([PackageSpec(; path=joinpath(SDK, p)) for p in SUBPACKAGES])
Pkg.develop(; path=PKG_ROOT)
Pkg.add("Test")
include(joinpath(HERE, "ext_tests.jl"))
