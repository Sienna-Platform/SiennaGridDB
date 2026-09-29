using Test
using PowerOpenAPIModels
using SiennaGridDBTools
import InfraStore

const EXT_JSON = SiennaGridDBTools.JSON
include(joinpath(@__DIR__, "..", "fixtures_util.jl"))
const EXT_FIXTURES = GOLDEN_DIR
const EXT_HAS_GOLDEN = ensure_golden_fixtures()

if EXT_HAS_GOLDEN
    @testset "PowerOpenAPIModels extension" begin
        mktempdir() do dir
            doc = PowerOpenAPIModels.read_document(
                joinpath(EXT_FIXTURES, "case14_NATURAL_UNITS.json"),
            )
            db = create_database(joinpath(dir, "a.sqlite"))
            report = insert_document!(db, doc)
            expected = EXT_JSON.parsefile(
                joinpath(EXT_FIXTURES, "case14_NATURAL_UNITS.report.json");
                dicttype=Dict{String, Any},
            )
            @test SiennaGridDBTools.report_dict(report) == expected
            bus = ACBus(; id=9001, name="extra", number=9001, available=true)
            r = insert_component!(db, bus)
            @test r.inserted == Dict("ACBus" => 1)
            @test isempty(r.skipped_fields)
            close(db)
        end
    end
end

@testset "SystemDocument with time series" begin
    mktempdir() do dir
        if build_time_series_case(dir)
            doc = PowerOpenAPIModels.read_document(joinpath(dir, "case.json"))
            db_path = joinpath(dir, "model.sqlite")
            db = create_database(db_path)
            report = insert_document!(db, doc; time_series=joinpath(dir, "case.h5"))
            close(db)
            # The dump spells an infinite value Infinity, as Python's json does
            load(path) = EXT_JSON.parsefile(path; dicttype=Dict{String, Any}, allownan=true)
            @test SiennaGridDBTools.report_dict(report) ==
                  load(joinpath(dir, "case.report.json"))
            ours = EXT_JSON.parse(
                python_dump(db_path);
                dicttype=Dict{String, Any},
                allownan=true,
            )
            python = load(joinpath(dir, "case.dump.json"))
            @test ours["static_time_series"] == python["static_time_series"]
            ids(d) = sort!([r[1] for r in d["time_series_associations"]["rows"]])
            @test ids(ours) == ids(python)
            # PowerOpenAPIModels.jl decodes an integral float feature as Int and respells
            # initial_timestamp (".000Z"), so features_hash and timestamps differ.
            @test_broken ours == python
        end
    end
end
