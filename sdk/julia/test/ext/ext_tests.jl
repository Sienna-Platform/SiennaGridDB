using Test
using PowerOpenAPIModels
using SiennaGridDBTools

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
            @test r.skipped_fields == Dict("ACBus" => Dict("number" => 1, "available" => 1))
            close(db)
        end
    end
end
