using Test
using Dates
import DBInterface
import InfraStore
import JSON
import SQLite
using SiennaGridDBTools

include(joinpath(@__DIR__, "..", "fixtures_util.jl"))
const HAS_GOLDEN = ensure_golden_fixtures()

query_rows(db, sql) = [Tuple(r) for r in DBInterface.execute(db, sql)]

# The golden document with two series of its first thermal in a real InfraStore
# sidecar; a deleted series leaves a gap so ids are not 1..n.
# InfraStore returns the association rows as a JSON string or as parsed rows.
wire_rows(rows::AbstractString) = JSON.parse(rows)
wire_rows(rows) = JSON.parse(JSON.json(rows))

function sidecar_document(dir)
    doc = JSON.parsefile(
        joinpath(GOLDEN_DIR, "case14_NATURAL_UNITS.json");
        dicttype=Dict{String, Any},
    )
    gen = doc["components"]["ThermalStandard"][1]["id"]
    path = joinpath(dir, "ts.h5")
    store = InfraStore.Store(; path=path)
    t0 = DateTime(2030, 1, 1)
    add(name, values; kwargs...) = InfraStore.add_time_series!(
        store,
        gen,
        "ThermalStandard",
        InfraStore.Component,
        InfraStore.SingleTimeSeries(t0, Hour(1), values, name);
        kwargs...,
    )
    gone = add("scratch", [0.0])
    add("max_active_power", [1.0, 2.0, 3.0]; features=Dict("year" => 2030))
    add("min_active_power", [0.5, 0.5, 0.5])
    InfraStore.remove_by_ids!(store, [gone])
    rows = InfraStore.export_time_series_associations_openapi(store)
    doc["time_series_associations"] = wire_rows(rows)
    InfraStore.close!(store)
    delete!(doc, "ext")
    return doc, path
end

if HAS_GOLDEN
    @testset "InfraStore time series values" begin
        mktempdir() do dir
            doc, sidecar = sidecar_document(dir)
            db = create_database(joinpath(dir, "a.sqlite"))
            insert_document!(db, doc; time_series=sidecar)
            ids = Dict(
                r["name"] => r["association_id"] for r in doc["time_series_associations"]
            )
            @test sort!(collect(values(ids))) == [2, 3]
            sql =
                "SELECT association_id, timestamp, value FROM time_series_values " *
                "WHERE name = 'max_active_power' ORDER BY timestamp"
            @test query_rows(db, sql) == [
                (ids["max_active_power"], "2030-01-01T00:00:00.000Z", 1.0),
                (ids["max_active_power"], "2030-01-01T01:00:00.000Z", 2.0),
                (ids["max_active_power"], "2030-01-01T02:00:00.000Z", 3.0),
            ]
            @test isempty(query_rows(db, "SELECT * FROM orphaned_time_series"))
            close(db)
        end
    end

    @testset "values without a sidecar are reported, and strict raises" begin
        mktempdir() do dir
            doc, _ = sidecar_document(dir)
            db = create_database(joinpath(dir, "a.sqlite"))
            report = insert_document!(db, doc)
            @test report.unsupported["time_series_values"] == 2
            @test_throws r"no time series sidecar" insert_document!(db, doc; strict=true)
            close(db)
        end
    end

    @testset "a missing sidecar is reported by path, and strict raises" begin
        mktempdir() do dir
            doc, _ = sidecar_document(dir)
            gone = joinpath(dir, "gone.h5")
            db = create_database(joinpath(dir, "a.sqlite"))
            report = insert_document!(db, doc; time_series=gone)
            @test report.unsupported["time_series_values"] == 2
            @test_throws r"gone.h5 not found" insert_document!(
                db,
                doc;
                strict=true,
                time_series=gone,
            )
            close(db)
        end
    end
end
