# Shared by runtests.jl and ext/ext_tests.jl: the golden insert fixtures are
# generated on the fly by test/prepare_fixtures.py and are gitignored.
const FIXTURES_UTIL_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const GOLDEN_DIR = joinpath(FIXTURES_UTIL_REPO_ROOT, "test", "fixtures", "insert")
const GOLDEN_CASES = ("NATURAL_UNITS", "COMPONENT_BASE")

function golden_available()
    return all(isfile(joinpath(GOLDEN_DIR, "case14_$case.json")) for case in GOLDEN_CASES)
end

function ensure_golden_fixtures()
    if golden_available()
        return true
    end
    generator = joinpath(FIXTURES_UTIL_REPO_ROOT, "test", "prepare_fixtures.py")
    try
        run(`python3 $generator`)
    catch
        @warn "golden fixture generation failed (python3 or the " *
              "power-openapi-models checkout is missing); golden testsets are skipped"
        return false
    end
    if !golden_available()
        @warn "golden fixture generation produced no files; golden testsets are skipped"
        return false
    end
    return true
end
