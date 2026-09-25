function fresh(f, dir)
    db = create_database(joinpath(dir, "t.sqlite"))
    try
        f(db)
    finally
        close(db)
    end
    return nothing
end

function lone_bus(doc)
    bus = first_of(doc, "ACBus")
    delete!(bus, "area")
    return bus
end

if HAS_GOLDEN
    @testset "golden $case" for case in CASES
        mktempdir() do dir
            fresh(dir) do db
                report = insert_document!(db, golden(case))
                expected = load_json(joinpath(FIXTURES, "case14_$case.report.json"))
                @test G.report_dict(report) == expected
                dump = load_json(joinpath(FIXTURES, "case14_$case.dump.json"))
                for (table, content) in dump
                    @test count_rows(db, table) == length(content["rows"])
                end
            end
        end
    end

    @testset "strict gap rolls back" begin
        mktempdir() do dir
            fresh(dir) do db
                bus = lone_bus(golden())
                @test_throws GapValueError insert_component!(db, "ACBus", bus; strict=true)
                @test count_rows(db, "entities") == 0
            end
        end
    end
end

@testset "unsupported type" begin
    mktempdir() do dir
        fresh(dir) do db
            iface = [Dict{String, Any}("id" => 1)]
            report = insert_components!(db, "TransmissionInterface", iface)
            @test report.unsupported == Dict("TransmissionInterface" => 1)
            @test_throws UnsupportedComponentError insert_components!(
                db,
                "TransmissionInterface",
                iface;
                strict=true,
            )
        end
    end
end

if HAS_GOLDEN
    # Review Focus 1
    @testset "duplicate id across types" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                bus = lone_bus(doc)
                area = first_of(doc, "Area")
                area["id"] = bus["id"]
                input = Dict{String, Any}(
                    "components" =>
                        Dict{String, Any}("ACBus" => Any[bus], "Area" => Any[area]),
                )
                @test_throws r"ACBus id=" insert_document!(db, input)
                @test count_rows(db, "entities") == 0
            end
        end
    end

    # Review Focus 2
    @testset "dangling bus reference" begin
        mktempdir() do dir
            fresh(dir) do db
                thermal = first_of(golden(), "ThermalStandard")
                thermal["bus"] = 999999
                input = Dict{String, Any}(
                    "components" =>
                        Dict{String, Any}("ThermalStandard" => Any[thermal]),
                )
                @test_throws InsertError insert_document!(db, input)
                @test_throws r"ThermalStandard id=.*FOREIGN KEY" insert_document!(db, input)
                @test count_rows(db, "entities") == 0
            end
        end
    end

    # Review Focus 3
    @testset "integral float ids" begin
        mktempdir() do dir
            fresh(dir) do db
                bus = lone_bus(golden())
                bus["id"] = 5.0
                insert_component!(db, "ACBus", bus)
                row = first(DBInterface.execute(db, "SELECT typeof(id), id FROM entities"))
                @test row[1] == "integer"
                @test row[2] == 5
                arc = Dict{String, Any}("id" => 6, "from_id" => 1.5, "to_id" => 5)
                @test_throws r"expected an integer" insert_component!(db, "Arc", arc)
            end
        end
    end

    @testset "explicit JSON null binds NULL" begin
        mktempdir() do dir
            fresh(dir) do db
                bus = lone_bus(golden())
                bus["base_voltage"] = nothing
                insert_component!(db, "ACBus", bus)
                row = first(
                    DBInterface.execute(
                        db,
                        "SELECT base_voltage FROM balancing_topologies",
                    ),
                )
                @test ismissing(row[1])
            end
        end
    end

    # Review Focus 4
    @testset "reinsert keeps the first copy" begin
        mktempdir() do dir
            fresh(dir) do db
                insert_document!(db, golden())
                before = count_rows(db, "entities")
                @test_throws InsertError insert_document!(db, golden())
                @test count_rows(db, "entities") == before
            end
        end
    end
end

# Review Focus 5
@testset "misspelled field" begin
    mktempdir() do dir
        fresh(dir) do db
            area(id, name, numbr) =
                Dict{String, Any}("id" => id, "name" => name, "numbr" => numbr)
            report = insert_component!(db, "Area", area(900, "a", 3))
            @test report.skipped_fields == Dict("Area" => Dict("numbr" => 1))
            @test_throws r"numbr" insert_component!(
                db,
                "Area",
                area(901, "b", 3);
                strict=true,
            )
            report = insert_component!(db, "Area", area(902, "c", nothing))
            @test isempty(report.skipped_fields)
        end
    end
end
