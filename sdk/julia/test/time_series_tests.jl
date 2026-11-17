function series(owner_id, association_id; fields...)
    row = Dict{String, Any}(
        "association_id" => association_id,
        "owner_id" => owner_id,
        "owner_type" => "ThermalStandard",
        "owner_category" => "Component",
        "time_series_type" => "SingleTimeSeries",
        "name" => "max_active_power",
        "features" => Dict{String, Any}("scenario" => "base", "year" => 2030),
        "uri" => "/arrays/a",
        "element_type" => "f64",
        "element_shape" => Any[],
        "initial_timestamp" => "2030-01-01T00:00:00",
        "resolution" => "PT1H",
        "length" => 24,
    )
    for (k, v) in fields
        row[String(k)] = v
    end
    return row
end

query_rows(db, sql) = [Tuple(r) for r in DBInterface.execute(db, sql)]

if HAS_GOLDEN
    @testset "time series associations and feature sets" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] =
                    Any[series(gen, 7), series(gen, 8; name="min_active_power")]
                report = insert_document!(db, doc)
                @test report.inserted["time_series_associations"] == 2
                hash =
                    G.features_hash(Dict{String, Any}("scenario" => "base", "year" => 2030))
                sql = "SELECT owner_id, name, features_hash FROM time_series_associations WHERE id = 7"
                @test query_rows(db, sql) == [(gen, "max_active_power", hash)]
                sql = "SELECT key, value_kind, value_int, value_str FROM feature_sets ORDER BY key"
                rows = query_rows(db, sql)
                @test isequal(
                    rows,
                    [("scenario", "str", missing, "base"), ("year", "int", 2030, missing)],
                )
            end
        end
    end

    @testset "a mislabelled time series owner raises" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] =
                    Any[series(gen, 7; owner_type="RenewableDispatch")]
                @test_throws r"is ThermalStandard" insert_document!(db, doc)
                @test count_rows(db, "entities") == 0
            end
        end
    end

    @testset "a series of an unsupported owner is reported" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                doc["components"]["AGC"] =
                    Any[Dict{String, Any}("id" => 9001, "name" => "agc")]
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] =
                    Any[series(9001, 7; owner_type="AGC"), series(gen, 8)]
                report = insert_document!(db, doc)
                @test report.unsupported["time_series_associations"] == 1
                @test count_rows(db, "time_series_associations") == 1
            end
        end
    end

    @testset "an unsupported series type is reported, and strict raises" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                row = series(gen, 7; time_series_type="NonSequentialTimeSeries")
                delete!(row, "initial_timestamp")
                delete!(row, "resolution")
                doc["time_series_associations"] = Any[row]
                delete!(doc, "ext")
                report = insert_document!(db, doc)
                @test report.unsupported["NonSequentialTimeSeries"] == 1
                @test count_rows(db, "time_series_associations") == 0
                @test_throws r"timestamps_uri" insert_document!(db, doc; strict=true)
            end
        end
    end

    @testset "a plant owns series as a supplemental attribute" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                push!(
                    doc["supplemental_attributes"],
                    Dict{String, Any}("id" => 9100, "name" => "plant1"),
                )
                push!(
                    doc["supplemental_attribute_associations"],
                    Dict{String, Any}(
                        "component_id" => gen,
                        "component_type" => "ThermalStandard",
                        "attribute_id" => 9100,
                        "attribute_type" => "ThermalPowerPlant",
                    ),
                )
                doc["time_series_associations"] = Any[series(
                    9100,
                    7;
                    owner_type="ThermalPowerPlant",
                    owner_category="SupplementalAttribute",
                )]
                insert_document!(db, doc)
                @test count_rows(db, "time_series_associations") == 1
            end
        end
    end

    # A thermal whose fuel cost is the series 7, with a DeterministicSingleTimeSeries 8
    # derived from it: same array, owner, name and features, plus forecast windows.
    function fuel_cost_series!(doc)
        gen = doc["components"]["ThermalStandard"][1]
        cost = gen["operation_cost"]["variable_operation_cost"]
        cost["variable_cost_type"] = "FUEL"
        cost["fuel_cost"] = nothing
        cost["fuel_cost_time_series"] = 8
        derived = series(
            gen["id"],
            8;
            name="fuel_cost",
            time_series_type="DeterministicSingleTimeSeries",
            horizon="PT24H",
            interval="PT24H",
            count=1,
        )
        doc["time_series_associations"] =
            Any[series(gen["id"], 7; name="fuel_cost"), derived]
        delete!(doc, "ext")
        return gen
    end

    @testset "a derived series is reported, and strict raises" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                fuel_cost_series!(doc)
                report = insert_document!(db, doc)
                @test report.unsupported["DeterministicSingleTimeSeries"] == 1
                @test query_rows(db, "SELECT id FROM time_series_associations") == [(7,)]
                @test_throws r"transform_single_time_series" insert_document!(
                    db,
                    doc;
                    strict=true,
                )
            end
        end
    end

    @testset "a reference to a derived series points at its source" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = fuel_cost_series!(doc)
                insert_document!(db, doc)
                sql = "SELECT operation_cost FROM thermal_generators WHERE id = $(gen["id"])"
                stored = JSON.parse(only(query_rows(db, sql))[1])
                @test stored["variable_operation_cost"]["fuel_cost_time_series"] == 7
                @test gen["operation_cost"]["variable_operation_cost"]["fuel_cost_time_series"] ==
                      8
            end
        end
    end

    @testset "a reference no stored series has is reported, and strict raises" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = fuel_cost_series!(doc)
                # The payload names 8, but the document holds no series.
                doc["time_series_associations"] = Any[]
                report = insert_document!(db, doc)
                @test report.unsupported["dangling_time_series_references"] == 1
                sql = "SELECT association_id FROM dangling_time_series_references"
                @test query_rows(db, sql) == [(8,)]
                first = "first: entity $(gen["id"]) fuel_cost_time_series=8"
                @test_throws Regex(first) insert_document!(db, doc; strict=true)
            end
        end
    end

    @testset "remap_references copies only what changes" begin
        untouched = Dict{String, Any}("curve" => Any[1, 2], "association_id" => 3)
        node = Dict{String, Any}(
            "a" => untouched,
            "b" => Any[Dict{String, Any}("fuel_cost_time_series" => 8)],
            "c" => 8,
        )
        remap = G.SeriesRemap(Dict(8 => 7), 0)
        out = G.remap_references(node, remap)
        @test out["b"][1]["fuel_cost_time_series"] == 7
        @test out["c"] == 8
        @test out["a"] === untouched
        @test node["b"][1]["fuel_cost_time_series"] == 8
        @test G.remap_references(untouched, remap) === untouched
        @test G.remap_references(node, G.SeriesRemap(Dict{Int, Int}(), 0)) === node
        @test G.remap_references(node, G.SeriesRemap(Dict(8 => 7), 10))["c"] == 8
        @test G.remap_references(node, G.SeriesRemap(Dict(8 => 7), 10))["b"][1]["fuel_cost_time_series"] ==
              17
    end
end

if HAS_GOLDEN
    @testset "a commit check failure rolls back and throws" begin
        mktempdir() do dir
            fresh(dir) do db
                # load_zone is a deferred foreign key: SQLite checks it only at the commit.
                bus = lone_bus(golden())
                bus["load_zone"] = 999
                @test_throws InsertError insert_component!(db, "ACBus", bus)
                @test count_rows(db, "entities") == 0
                insert_component!(db, "ACBus", lone_bus(golden()))
                @test count_rows(db, "balancing_topologies") == 1
            end
        end
    end

    @testset "a non-finite number throws" begin
        mktempdir() do dir
            fresh(dir) do db
                bus = lone_bus(golden())
                bus["magnitude"] = Inf
                @test_throws InsertError insert_component!(db, "ACBus", bus)
                @test count_rows(db, "entities") == 0
            end
        end
    end

    @testset "an insert refuses another schema version" begin
        mktempdir() do dir
            fresh(dir) do db
                DBInterface.execute(db, "PRAGMA user_version = 1")
                err = try
                    insert_component!(db, "ACBus", lone_bus(golden()))
                catch e
                    e
                end
                @test occursin("user_version 1", sprint(showerror, err))
            end
        end
    end

    @testset "an association id below one throws" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] = Any[series(gen, 0)]
                @test_throws InsertError insert_document!(db, doc)
                @test count_rows(db, "entities") == 0
            end
        end
    end

    @testset "each store tags only its own rows" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] =
                    Any[series(gen, 2), series(gen, 3; name="min_active_power")]
                insert_document!(db, doc)
                rows = Any[series(gen, 2; name="a"), series(gen, 3; name="b")]
                second = Dict{String, Any}(
                    "components" => Dict{String, Any}(),
                    "time_series_associations" => rows,
                )
                insert_document!(db, second)
                sql = "SELECT id, store_id FROM time_series_associations ORDER BY id"
                @test query_rows(db, sql) == [(2, 1), (3, 1), (5, 2), (6, 2)]
            end
        end
    end

    @testset "a dangling reference names the document's own id" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                gen = first_of(doc, "ThermalStandard")["id"]
                doc["time_series_associations"] =
                    Any[series(gen, 2), series(gen, 3; name="min_active_power")]
                insert_document!(db, doc)
                # Stored past offset 3, the plant's 7 would read 10; the report names the 7.
                second = Dict{String, Any}(
                    "components" => Dict{String, Any}(),
                    "supplemental_attributes" => Any[Dict{String, Any}(
                        "id" => 9200,
                        "name" => "p",
                        "fuel_cost_time_series" => 7,
                    )],
                    "supplemental_attribute_associations" => Any[Dict{String, Any}(
                        "component_id" => gen,
                        "component_type" => "ThermalStandard",
                        "attribute_id" => 9200,
                        "attribute_type" => "ThermalPowerPlant",
                    )],
                    "time_series_associations" => Any[],
                )
                err = try
                    insert_document!(db, second; strict=true)
                catch e
                    e
                end
                @test occursin("fuel_cost_time_series=7", sprint(showerror, err))
            end
        end
    end
end

@testset "opening a missing database creates no file" begin
    mktempdir() do dir
        path = joinpath(dir, "typo.sqlite")
        @test_throws GridDBToolsError open_database(path)
        @test !isfile(path)
    end
end
