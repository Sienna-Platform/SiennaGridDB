using Test
using SiennaGridDBTools
import DBInterface
import InfraStore
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
        @test G.encode(G.IntEncoding(), typemax(Int)) == typemax(Int)
        @test G.encode(G.IntEncoding(), -2.0^63) == typemin(Int)
        @test_throws G.EncodeError G.encode(G.IntEncoding(), big(2)^63)
        @test_throws G.EncodeError G.encode(G.IntEncoding(), 1e20)
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

    @testset "features_hash" begin
        vectors = load_json(joinpath(REPO_ROOT, "test", "features_hash_vectors.json"))
        for v in vectors["vectors"]
            @test G.features_hash(v["features"]) == v["hash"]
        end
        hashes =
            Set(G.features_hash(Dict{String, Any}("a" => v)) for v in (1, 1.0, true, "1"))
        @test length(hashes) == 4
        @test_throws G.EncodeError G.features_hash(Dict{String, Any}("a" => nothing))
        @test_throws G.EncodeError G.features_hash(Dict{String, Any}("a" => big(2)^63))
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
            @test first(DBInterface.execute(db, "PRAGMA temp_store"))[1] == 2
            DBInterface.execute(db, "PRAGMA user_version = 99")
            close(db)
            @test_throws ManifestMismatchError open_database(path)
        end
    end

    include("insert_tests.jl")
    include("time_series_tests.jl")
end
