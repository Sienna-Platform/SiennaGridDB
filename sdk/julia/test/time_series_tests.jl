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
end
