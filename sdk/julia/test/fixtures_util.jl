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

# The time series case needs infrastore: prefer the repo's .venv, which the README
# setup installs it into, unless SIENNA_GRIDDB_PYTHON names another interpreter.
const PYTHON = get(ENV, "SIENNA_GRIDDB_PYTHON") do
    venv = joinpath(FIXTURES_UTIL_REPO_ROOT, ".venv", "bin", "python")
    return isfile(venv) ? venv : "python3"
end

function python_dump(db_path)
    script = joinpath(FIXTURES_UTIL_REPO_ROOT, "scripts", "canonical_dump.py")
    return read(`$PYTHON $script $db_path`, String)
end

function infrastore_importable()
    probe = pipeline(`$PYTHON -c "import infrastore"`; stdout=devnull, stderr=devnull)
    try
        return success(probe)
    catch  # no such interpreter
        return false
    end
end

"""
Build the synthetic time series case (test/time_series_case.py) into `dir`; false,
with a warning, only when `PYTHON` cannot import infrastore, and never under CI.
"""
function build_time_series_case(dir::AbstractString)
    if !infrastore_importable()
        haskey(ENV, "CI") && error("$PYTHON cannot import infrastore, which CI installs")
        @warn "$PYTHON cannot import infrastore; time series parity testsets are skipped"
        return false
    end
    script = joinpath(FIXTURES_UTIL_REPO_ROOT, "test", "time_series_case.py")
    run(`$PYTHON $script $dir`)
    return true
end
