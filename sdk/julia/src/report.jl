"""
What an insert call wrote (`inserted`), and what it could not (`skipped_fields`,
`unsupported`). Zero counts are never stored.
"""
struct InsertReport
    inserted::Dict{String, Int}
    skipped_fields::Dict{String, Dict{String, Int}}
    unsupported::Dict{String, Int}
end

function InsertReport()
    return InsertReport(
        Dict{String, Int}(),
        Dict{String, Dict{String, Int}}(),
        Dict{String, Int}(),
    )
end

function add_inserted!(report::InsertReport, key::AbstractString, n::Int=1)
    report.inserted[key] = get(report.inserted, key, 0) + n
    return report
end

function add_skipped!(
    report::InsertReport,
    type_name::AbstractString,
    field::AbstractString,
)
    fields = get!(report.skipped_fields, type_name, Dict{String, Int}())
    fields[field] = get(fields, field, 0) + 1
    return report
end

function add_unsupported!(report::InsertReport, key::AbstractString, n::Int)
    report.unsupported[key] = get(report.unsupported, key, 0) + n
    return report
end

function report_dict(report::InsertReport)
    return Dict(
        "inserted" => report.inserted,
        "skipped_fields" => report.skipped_fields,
        "unsupported" => report.unsupported,
    )
end

Base.:(==)(a::InsertReport, b::InsertReport) = report_dict(a) == report_dict(b)
