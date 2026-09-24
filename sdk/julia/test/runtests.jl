using Test
using SiennaGridDBTools
import DBInterface
import JSON
import SQLite

const G = SiennaGridDBTools
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
include("fixtures_util.jl")
const FIXTURES = GOLDEN_DIR
const CASES = ("NATURAL_UNITS", "COMPONENT_BASE")
const HAS_GOLDEN = ensure_golden_fixtures()

load_json(path) = JSON.parsefile(path; dicttype=Dict{String, Any})
count_rows(db, table) = first(DBInterface.execute(db, "SELECT count(*) FROM $table"))[1]
golden(case="NATURAL_UNITS") = load_json(joinpath(FIXTURES, "case14_$case.json"))
first_of(doc, type_name) = deepcopy(doc["components"][type_name][1])

@testset "SiennaGridDBTools" begin
    @testset "encodings" begin
        @test G.encode(G.IntEncoding(), 3) == 3
        @test G.encode(G.IntEncoding(), 5.0) == 5
        @test_throws G.EncodeError G.encode(G.IntEncoding(), 1.5)
        @test_throws G.EncodeError G.encode(G.IntEncoding(), true)
        @test G.encode(G.RealEncoding(), 2) == 2.0
        @test_throws G.EncodeError G.encode(G.RealEncoding(), "1")
        @test G.encode(G.BoolEncoding(), false) == 0
        @test_throws G.EncodeError G.encode(G.BoolEncoding(), 1)
        @test ismissing(G.bind_value(G.TextEncoding(), nothing))
        @test G.bind_value(G.TextEncoding(), "x") == "x"
        @test G.bound_value(
            G.IntEncoding(),
            Dict{String, Any}("a" => Dict{String, Any}("b" => 1)),
            ["a", "b"],
        ) == 1
        @test ismissing(
            G.bound_value(G.IntEncoding(), Dict{String, Any}("a" => 1), ["a", "b"]),
        )
    end

    @testset "create and open" begin
        mktempdir() do dir
            path = joinpath(dir, "a.sqlite")
            db = create_database(path)
            n = length(G.manifest().vocabulary["entity_types"])
            @test count_rows(db, "entity_types") == n
            seed_vocabulary!(db)
            @test count_rows(db, "entity_types") == n
            close(db)
            @test_throws DatabaseExistsError create_database(path)
            db = open_database(path)
            @test first(DBInterface.execute(db, "PRAGMA foreign_keys"))[1] == 1
            DBInterface.execute(db, "PRAGMA user_version = 99")
            close(db)
            @test_throws ManifestMismatchError open_database(path)
        end
    end

    include("insert_tests.jl")
end
