module SiennaGridDBToolsPowerOpenAPIModelsExt

import PowerOpenAPIModels
import SiennaGridDBTools
import SQLite

const OpenAPI = PowerOpenAPIModels.OpenAPI

"""
Insert a `SystemDocument` through its JSON tree. Its time series are not parity-safe:
PowerOpenAPIModels.jl decodes an integral float feature (`1.0`) as an Int, which changes
its features_hash, and respells `initial_timestamp` with milliseconds (`.000Z`).
"""
function SiennaGridDBTools.insert_document!(
    db::SQLite.DB,
    doc::PowerOpenAPIModels.SystemDocument;
    strict::Bool=false,
    time_series::Union{Nothing, AbstractString}=nothing,
)
    tree = PowerOpenAPIModels.document_tree(doc)
    return SiennaGridDBTools.insert_document!(
        db,
        tree;
        strict=strict,
        time_series=time_series,
    )
end

function SiennaGridDBTools.insert_component!(
    db::SQLite.DB,
    model::PowerOpenAPIModels.APIModel;
    strict::Bool=false,
)
    type_name = String(nameof(typeof(model)))
    obj = OpenAPI.Runtime._encode(model)
    return SiennaGridDBTools.insert_component!(db, type_name, obj; strict=strict)
end

end
