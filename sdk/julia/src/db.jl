const MIN_SQLITE = v"3.45.0"
const SCHEMA_FILES = ("schema.sql", "triggers.sql", "unit_registry.sql", "views.sql")

function scalar(db::SQLite.DB, sql::AbstractString)
    return first(DBInterface.execute(db, sql))[1]
end

function connect(path::AbstractString)
    db = SQLite.DB(path)
    found = VersionNumber(scalar(db, "SELECT sqlite_version()"))
    if found < MIN_SQLITE
        throw(SQLiteVersionError("SQLite $found is older than the required $MIN_SQLITE"))
    end
    DBInterface.execute(db, "PRAGMA foreign_keys = ON")
    return db
end

"""
Run a multi-statement SQL script. `DBInterface.execute` and `DBInterface.executemultiple`
run only the first statement of a string (verified with SQLite.jl 1.6), so a schema file
would silently apply one CREATE TABLE and stop; `sqlite3_exec` runs all of it.
"""
function execute_script(db::SQLite.DB, sql::AbstractString)
    errmsg = Ref{Ptr{Cchar}}(C_NULL)
    rc = SQLite.C.sqlite3_exec(db.handle, sql, C_NULL, C_NULL, errmsg)
    if rc != SQLite.C.SQLITE_OK
        msg = unsafe_string(errmsg[])
        SQLite.C.sqlite3_free(errmsg[])
        throw(InsertError("schema script failed: $msg"))
    end
    return nothing
end

function open_database(path::AbstractString)
    db = connect(path)
    found = scalar(db, "PRAGMA user_version")
    expected = manifest().schema_user_version
    if found != expected
        close(db)
        throw(
            ManifestMismatchError(
                "$path has user_version $found; this package writes schema version $expected",
            ),
        )
    end
    return db
end

function seed_vocabulary!(db::SQLite.DB)
    vocab = manifest().vocabulary
    stmt = SQLite.Stmt(
        db,
        "INSERT OR IGNORE INTO entity_types (name, is_topology, is_dc) VALUES (?, ?, ?)",
    )
    for t in vocab["entity_types"]
        DBInterface.execute(stmt, (t["name"], Int(t["is_topology"]), Int(t["is_dc"])))
    end
    DBInterface.close!(stmt)
    for (table, names) in vocab
        if table == "entity_types"
            continue
        end
        stmt = SQLite.Stmt(db, "INSERT OR IGNORE INTO $table (name) VALUES (?)")
        for name in names
            DBInterface.execute(stmt, (name,))
        end
        DBInterface.close!(stmt)
    end
    return db
end

function create_database(path::AbstractString)
    if ispath(path)
        throw(DatabaseExistsError("$path already exists; create_database never overwrites"))
    end
    db = connect(path)
    for name in SCHEMA_FILES
        execute_script(db, read(joinpath(DATA_DIR, name), String))
    end
    seed_vocabulary!(db)
    return db
end
