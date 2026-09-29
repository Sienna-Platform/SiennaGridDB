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

const SERVICE_TYPES =
    ("OnlineReserve", "OfflineReserve", "GroupReserve", "TransmissionInterface")

# The golden document plus an online and an offline reserve on a generator, a
# group over both, and an interface on a line, with their memberships.
function with_services(doc::Dict{String, Any})
    comps = doc["components"]
    top = maximum(Int(o["id"]) for objs in values(comps) for o in objs)
    top = max(top, maximum(Int(a["id"]) for a in doc["supplemental_attributes"]))
    online, offline, group, iface = top + 1, top + 2, top + 3, top + 4
    thermal = first_of(doc, "ThermalStandard")["id"]
    line = first_of(doc, "Line")
    service(id, name; fields...) = Dict{String, Any}(
        "id" => id,
        "name" => name,
        "available" => true,
        (String(k) => v for (k, v) in fields)...,
    )
    comps["OnlineReserve"] = Any[service(
        online,
        "online_up";
        time_frame=5.0,
        requirement=10.0,
        reserve_direction="UP",
    )]
    comps["OfflineReserve"] = Any[service(offline, "offline_up"; time_frame=30.0)]
    comps["GroupReserve"] =
        Any[service(group, "group_up"; requirement=0.0, reserve_direction="UP")]
    comps["TransmissionInterface"] = Any[service(
        iface,
        "IFACE";
        active_power_flow_limits=Dict{String, Any}("min" => -100.0, "max" => 100.0),
        violation_penalty=1e5,
        direction_mapping=Dict{String, Any}(line["name"] => -1),
        base_power=100.0,
        power_units="NATURAL_UNITS",
    )]
    pairs = (
        (online, thermal),
        (offline, thermal),
        (group, online),
        (group, offline),
        (iface, line["id"]),
    )
    doc["service_associations"] =
        Any[Dict{String, Any}("service_id" => s, "entity_id" => e) for (s, e) in pairs]
    return doc
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
            agc = [Dict{String, Any}("id" => 1)]
            report = insert_components!(db, "AGC", agc)
            @test report.unsupported == Dict("AGC" => 1)
            @test_throws UnsupportedComponentError insert_components!(
                db,
                "AGC",
                agc;
                strict=true,
            )
        end
    end
end

if HAS_GOLDEN
    # AGC has no table, so an association row naming one, on either side, is counted
    # under its section instead of failing the document.
    @testset "rows naming an unsupported component" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                thermal = first_of(doc, "ThermalStandard")["id"]
                agc, plant = 9001, 9002
                doc["components"]["AGC"] =
                    Any[Dict{String, Any}("id" => agc, "name" => "agc")]
                cc = Dict{String, Any}(
                    "id" => plant,
                    "name" => "cc1",
                    "configuration" => "SeparateShaftCombustionSteam",
                )
                push!(doc["supplemental_attributes"], cc)
                for (c, t) in ((thermal, "ThermalStandard"), (agc, "AGC"))
                    row = Dict{String, Any}(
                        "component_id" => c,
                        "component_type" => t,
                        "attribute_id" => plant,
                        "attribute_type" => "CombinedCycleBlock",
                    )
                    push!(doc["supplemental_attribute_associations"], row)
                end
                doc["combined_cycle_associations"] = Any[
                    Dict{String, Any}(
                        "plant_id" => plant,
                        "entity_id" => e,
                        "role" => "CT",
                        "hrsg_index" => i,
                    ) for (i, e) in enumerate((thermal, agc))
                ]
                report = insert_document!(db, doc)
                @test report.unsupported["AGC"] == 1
                @test report.unsupported["supplemental_attribute_associations"] == 1
                @test report.unsupported["combined_cycle_associations"] == 1
                @test count_rows(db, "combined_cycle_associations") == 1
            end
        end
    end

    # The skip reads ids by the int encoder's rule, so the three SDKs agree on odd ids.
    @testset "unsupported reference id $(repr(ref))" for (agc_id, ref, skipped) in (
        (9001, 9001.0, true),
        ("9001", "9001", false),
        (1, true, false),
        (1e20, 1e20, false),
        (9001, Any[9001], false),
        (9001, Dict{String, Any}("id" => 9001), false),
    )
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                agc = Dict{String, Any}("id" => agc_id, "name" => "agc")
                doc["components"]["AGC"] = Any[agc]
                rows = doc["supplemental_attribute_associations"]
                push!(
                    rows,
                    merge(rows[1], Dict("component_id" => ref, "component_type" => "AGC")),
                )
                if skipped
                    report = insert_document!(db, doc)
                    @test report.unsupported["supplemental_attribute_associations"] == 1
                else
                    @test_throws InsertError insert_document!(db, doc)
                    @test_throws r"expected an integer" insert_document!(db, doc)
                end
            end
        end
    end

    @testset "non-object entries of an unsupported type are counted" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                doc["components"]["AGC"] = Any[nothing, 5, Any[1]]
                @test insert_document!(db, doc).unsupported["AGC"] == 3
            end
        end
    end

    @testset "non-object entry $(repr(value)) in $where" for where in (
            "ThermalStandard",
            "supplemental_attributes",
            "supplemental_attribute_associations",
            "plant_associations",
            "combined_cycle_associations",
            "trading_hub_associations",
            "service_associations",
        ),
        value in (nothing, 5, Any[1])

        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                owner = haskey(doc["components"], where) ? doc["components"] : doc
                push!(owner[where], value)
                @test_throws InsertError insert_document!(db, doc)
                @test_throws r"not an object" insert_document!(db, doc)
                @test count_rows(db, "entities") == 0
            end
        end
    end

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

    @testset "services and memberships" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = with_services(golden())
                report = insert_document!(db, doc)
                for type_name in SERVICE_TYPES
                    @test report.inserted[type_name] == 1
                    @test !haskey(report.skipped_fields, type_name)
                end
                @test report.inserted["service_associations"] == 5
                @test collect(keys(report.unsupported)) == ["ext"]
                line = first_of(doc, "Line")["id"]
                row = first(
                    DBInterface.execute(
                        db,
                        "SELECT branch_id, direction FROM interface_branch_directions",
                    ),
                )
                @test (row[1], row[2]) == (line, -1)
            end
        end
    end

    # AGC has no table, so its membership rows are counted, not inserted.
    @testset "membership of an unsupported service" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = with_services(golden())
                online = first_of(doc, "OnlineReserve")["id"]
                agc = Dict{String, Any}("id" => online + 10, "name" => "agc")
                doc["components"]["AGC"] = Any[agc]
                push!(
                    doc["service_associations"],
                    Dict{String, Any}("service_id" => online + 10, "entity_id" => online),
                )
                report = insert_document!(db, doc)
                @test report.unsupported["AGC"] == 1
                @test report.unsupported["service_associations"] == 1
                @test report.inserted["service_associations"] == 5
                @test count_rows(db, "service_associations") == 5
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

    @testset "null sections read as empty" begin
        mktempdir() do dir
            fresh(dir) do db
                doc = golden()
                sections = (
                    "supplemental_attributes",
                    "supplemental_attribute_associations",
                    "plant_associations",
                )
                for key in sections
                    doc[key] = nothing
                end
                report = insert_document!(db, doc)
                @test report.inserted["ThermalStandard"] == 7
                @test count_rows(db, "supplemental_attribute_associations") == 0
                empty = Dict{String, Any}("components" => nothing)
                @test isempty(insert_document!(db, empty).inserted)
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
