snapshot(dir) =
    Dict(n => (read(joinpath(dir, n)), mtime(joinpath(dir, n))) for n in readdir(dir))

function query(db, sql)
    return [Tuple(r) for r in DBInterface.execute(db, sql)]
end

@testset "time series reader is loaded" begin
    @test isnothing(G.reader_missing())
    @test G.element_dtype("tuple(3,i64)") == "i64"
    @test G.element_dtype("linear_function") == "linear_function"
end

mktempdir() do dir
    case_dir = joinpath(dir, "case")
    mkdir(case_dir)
    if build_time_series_case(case_dir)
        doc_path = joinpath(case_dir, "case.json")
        sidecar = joinpath(case_dir, "case.h5")
        chmod(sidecar, 0o444)
        expected_dump = read(joinpath(case_dir, "case.dump.json"), String)

        @testset "time series parity with the Python runtime" begin
            before = snapshot(case_dir)
            db_path = joinpath(dir, "jl.sqlite")
            db = create_database(db_path)
            report = insert_document!(db, doc_path)
            @test count_rows(db, "orphaned_time_series") == 0
            close(db)
            @test snapshot(case_dir) == before
            expected = load_json(joinpath(case_dir, "case.report.json"))
            @test G.report_dict(report) == expected
            @test python_dump(db_path) == expected_dump
        end

        @testset "time series from a parsed document, in any row order" begin
            db_path = joinpath(mktempdir(), "reversed.sqlite")
            db = create_database(db_path)
            doc = load_json(doc_path)
            reverse!(doc["time_series_associations"])
            insert_document!(db, doc; time_series=sidecar)
            close(db)
            @test python_dump(db_path) == expected_dump
            fresh(mktempdir()) do db
                insert_document!(db, load_json(doc_path); time_series=sidecar)
                shared = DBInterface.execute(
                    db,
                    "SELECT count(*) FROM time_series_associations a JOIN " *
                    "static_time_series v ON v.uri = a.uri WHERE a.name = 'max_active_power'",
                )
                @test first(shared)[1] == 12  # 4 associations x 3 shared values
                @test count_rows(db, "dangling_time_series_references") == 0
            end
        end

        @testset "explicit null optional fields read as absent" begin
            doc = load_json(doc_path)
            optional = (
                "units",
                "quantity_kind",
                "unit_system",
                "component_field",
                "application_data",
            )
            for row in doc["time_series_associations"], key in optional
                get!(row, key, nothing)
            end
            db_path = joinpath(mktempdir(), "nulls.sqlite")
            db = create_database(db_path)
            insert_document!(db, doc; time_series=sidecar)
            close(db)
            @test python_dump(db_path) == expected_dump
        end

        @testset "a plant owns series as a supplemental attribute" begin
            # Plant-type attributes are stored in plants, not supplemental_attributes
            doc = load_json(doc_path)
            plant = "ThermalPowerPlant"
            attribute = Dict{String, Any}("id" => 3, "name" => "p3")
            doc["supplemental_attributes"] = Any[attribute]
            doc["supplemental_attribute_associations"][1]["attribute_type"] = plant
            for row in doc["time_series_associations"]
                row["owner_id"] == 3 && (row["owner_type"] = plant)
            end
            fresh(mktempdir()) do db
                report = insert_document!(db, doc; time_series=sidecar)
                @test report.inserted["plants"] == 1
                @test report.inserted["time_series_associations"] == 19
                geo = query(
                    db,
                    "SELECT v.timestep, v.element, v.value FROM time_series_associations a " *
                    "JOIN static_time_series v ON v.uri = a.uri WHERE a.owner_id = 3 " *
                    "AND a.time_series_type = 'SingleTimeSeries' ORDER BY 1, 2",
                )
                @test geo == [(0, 0, 7.0), (1, 0, 8.0), (2, 0, 9.0)]
            end
        end

        @testset "a symlinked read-only sidecar is left alone" begin
            linked = mktempdir()
            target = joinpath(mktempdir(), "elsewhere.h5")
            cp(sidecar, target)
            chmod(target, 0o444)
            cp(doc_path, joinpath(linked, "case.json"))
            symlink(target, joinpath(linked, "case.h5"))
            before = (filemode(target), mtime(target), read(target))
            fresh(mktempdir()) do db
                insert_document!(db, joinpath(linked, "case.json"))
                @test count_rows(db, "static_time_series") == 57
            end
            @test (filemode(target), mtime(target), read(target)) == before
        end

        @testset "a second document reuses stored arrays" begin
            rows = load_json(doc_path)["time_series_associations"]
            named(names...) = Any[r for r in rows if r["name"] in names]
            area(id) = Dict{String, Any}(
                "Area" => Any[Dict{String, Any}("id" => id, "name" => "a$id")],
            )
            fresh(mktempdir()) do db
                first_doc = Dict{String, Any}(
                    "components" => area(1),
                    "time_series_associations" => filter(
                        r -> r["owner_id"] == 1,
                        named("zero", "max_active_power"),
                    ),
                )
                insert_document!(db, first_doc; time_series=sidecar)
                values_sql = "SELECT uri, timestep, element, value FROM static_time_series"
                before = query(db, values_sql * " ORDER BY uri, timestep, element")
                second_doc = Dict{String, Any}(
                    "components" => area(2),
                    "time_series_associations" => filter(
                        r -> r["owner_id"] == 2,
                        named("zero_linear", "max_active_power"),
                    ),
                )
                # A declared shape is checked for an array already stored too
                transposed = deepcopy(second_doc)
                for row in transposed["time_series_associations"]
                    row["name"] == "zero_linear" && (row["array_shape"] = Any[2, 3])
                end
                @test_throws r"shape \[2, 3\]" insert_document!(
                    db,
                    transposed;
                    time_series=sidecar,
                )
                # An explicit sidecar must exist even when no array is read
                shapeless = deepcopy(second_doc)
                foreach(
                    r -> delete!(r, "array_shape"),
                    shapeless["time_series_associations"],
                )
                none = joinpath(mktempdir(), "none.h5")
                @test_throws r"none\.h5 does not exist" insert_document!(
                    db,
                    shapeless;
                    time_series=none,
                )
                @test count_rows(db, "entities") == 1
                report = insert_document!(db, second_doc; time_series=sidecar)
                @test report.inserted == Dict("Area" => 1, "time_series_associations" => 4)
                @test query(db, values_sql * " ORDER BY uri, timestep, element") == before
                zero_linear = query(
                    db,
                    "SELECT v.timestep, v.element, v.value FROM time_series_associations a " *
                    "JOIN static_time_series v ON v.uri = a.uri WHERE a.name = 'zero_linear' " *
                    "AND a.time_series_type = 'SingleTimeSeries' ORDER BY 1, 2",
                )
                @test zero_linear == [(t, e, 0.0) for t in 0:2 for e in 0:1]
            end
        end

        @testset "time series without their default sidecar are unsupported" begin
            moved = mktempdir()
            doc = load_json(doc_path)
            delete!(doc["components"], "AGC")
            write(joinpath(moved, "case.json"), JSON.json(doc))
            fresh(mktempdir()) do db
                report = insert_document!(db, joinpath(moved, "case.json"))
                @test report.unsupported == Dict("time_series_associations" => 24)
                @test_throws r"case\.h5 does not exist" insert_document!(
                    db,
                    joinpath(moved, "case.json");
                    strict=true,
                )
            end
            fresh(mktempdir()) do db
                none = joinpath(moved, "none.h5")
                @test_throws r"sidecar" insert_document!(db, doc; time_series=none)
                @test count_rows(db, "entities") == 0
            end
        end

        @testset "an owner no list holds fails its foreign key" begin
            fresh(mktempdir()) do db
                doc = load_json(doc_path)
                delete!(doc["components"], "AGC")
                @test_throws r"FOREIGN KEY" insert_document!(db, doc; time_series=sidecar)
                @test count_rows(db, "entities") == 0
            end
        end

        @testset "a row mislabelling its owner is an InsertError" begin
            function relabel(doc, owner, key, label)
                for row in doc["time_series_associations"]
                    row["owner_id"] == owner && (row[key] = label)
                end
                return doc
            end
            # The case without the component and rows strict mode rejects
            function strict_ready(doc)
                delete!(doc["components"], "AGC")
                filter!(
                    r ->
                        r["time_series_type"] != "NonSequentialTimeSeries" &&
                            r["owner_type"] != "AGC" &&
                            get(r, "element_type", nothing) != "i64",
                    doc["time_series_associations"],
                )
                return doc
            end
            mislabels = [
                (2, "owner_type", "AGC"),
                (2, "owner_type", "ThermalStandard"),
                (3, "owner_type", "Area"),
                (3, "owner_category", "Component"),
            ]
            # A row owned by an AGC, whose rows are skipped, is checked too
            unsupported_owner =
                [(9, "owner_type", "Area"), (9, "owner_category", "SupplementalAttribute")]
            for (owner, key, label) in [mislabels; unsupported_owner]
                fresh(mktempdir()) do db
                    doc = relabel(load_json(doc_path), owner, key, label)
                    @test_throws Regex("owner_id $owner is ") insert_document!(
                        db,
                        doc;
                        time_series=sidecar,
                    )
                    @test count_rows(db, "entities") == 0
                end
            end
            for (owner, key, label) in mislabels
                fresh(mktempdir()) do db
                    doc = relabel(strict_ready(load_json(doc_path)), owner, key, label)
                    @test_throws Regex("owner_id $owner is ") insert_document!(
                        db,
                        doc;
                        time_series=sidecar,
                        strict=true,
                    )
                    @test count_rows(db, "entities") == 0
                    clean = strict_ready(load_json(doc_path))
                    insert_document!(db, clean; time_series=sidecar, strict=true)
                    @test count_rows(db, "entities") == 3
                end
            end
        end

        @testset "a non-object time series row is an InsertError" begin
            for value in (nothing, 5, Any[1])
                fresh(mktempdir()) do db
                    doc = load_json(doc_path)
                    push!(doc["time_series_associations"], value)
                    @test_throws G.InsertError insert_document!(
                        db,
                        doc;
                        time_series=sidecar,
                    )
                    @test count_rows(db, "entities") == 0
                end
            end
        end

        @testset "time series strict and bad arrays roll back" begin
            fresh(mktempdir()) do db
                doc = load_json(doc_path)
                delete!(doc["components"], "AGC")
                @test_throws r"timestamp vector" insert_document!(
                    db,
                    doc;
                    time_series=sidecar,
                    strict=true,
                )
                filter!(
                    r -> r["time_series_type"] != "NonSequentialTimeSeries",
                    doc["time_series_associations"],
                )
                filter!(r -> r["owner_type"] != "AGC", doc["time_series_associations"])
                @test_throws r"element_type i64" insert_document!(
                    db,
                    doc;
                    time_series=sidecar,
                    strict=true,
                )
                reserved = deepcopy(doc)
                for row in reserved["time_series_associations"]
                    if row["name"] == "load"
                        row["features"] = Dict{String, Any}("name" => "x")
                    end
                end
                @test_throws r"association id=.*CHECK constraint" insert_document!(
                    db,
                    reserved;
                    time_series=sidecar,
                )
                transposed = deepcopy(doc)
                for row in transposed["time_series_associations"]
                    if row["name"] == "linear" &&
                       row["time_series_type"] != "SingleTimeSeries"
                        row["array_shape"] = Any[2, 3]
                    end
                end
                @test_throws r"array_shape \[2, 3\] is not" insert_document!(
                    db,
                    transposed;
                    time_series=sidecar,
                )
                for row in doc["time_series_associations"]
                    if row["name"] == "geo"
                        row["uri"] = row["data_hash"] = "ab"^32
                    end
                end
                @test_throws r"sidecar" insert_document!(db, doc; time_series=sidecar)
                @test count_rows(db, "entities") == 0
            end
        end
    end
end
