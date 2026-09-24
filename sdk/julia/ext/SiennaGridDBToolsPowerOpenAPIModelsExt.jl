module SiennaGridDBToolsPowerOpenAPIModelsExt

import PowerOpenAPIModels
import SiennaGridDBTools
import SQLite

const OpenAPI = PowerOpenAPIModels.OpenAPI

function SiennaGridDBTools.insert_document!(
    db::SQLite.DB,
    doc::PowerOpenAPIModels.SystemDocument;
    strict::Bool=false,
)
    tree = PowerOpenAPIModels.document_tree(doc)
    return SiennaGridDBTools.insert_document!(db, tree; strict=strict)
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
