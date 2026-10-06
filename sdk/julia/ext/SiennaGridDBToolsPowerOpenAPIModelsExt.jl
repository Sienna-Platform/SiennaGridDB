module SiennaGridDBToolsPowerOpenAPIModelsExt

import PowerOpenAPIModels
import SiennaGridDBTools
import SQLite

# PowerOpenAPIModels 0.2 is a re-export umbrella: the document container lives in
# PowerCoreOpenAPIModels, and the model supertype and encoder in InfrastructureCoreOpenAPIModels.
const PowerCore = PowerOpenAPIModels.PowerCoreOpenAPIModels
const InfraCore = PowerOpenAPIModels.InfrastructureCoreOpenAPIModels

function SiennaGridDBTools.insert_document!(
    db::SQLite.DB,
    doc::PowerCore.SystemDocument;
    strict::Bool=false,
)
    tree = PowerCore.document_tree(doc)
    return SiennaGridDBTools.insert_document!(db, tree; strict=strict)
end

function SiennaGridDBTools.insert_component!(
    db::SQLite.DB,
    model::InfraCore.APIModel;
    strict::Bool=false,
)
    type_name = String(nameof(typeof(model)))
    obj = InfraCore._encode(model)
    return SiennaGridDBTools.insert_component!(db, type_name, obj; strict=strict)
end

end
