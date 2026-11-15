# @sienna-platform/griddb-tools

The TypeScript CRUD SDK for SiennaGridDB: it stores Sienna OpenAPI SDK objects in a
SiennaGridDB SQLite database (Node ≥ 22). Today it implements create (insert), without
time series values; read, update and delete come next. It is not a general database
client: use SQLite directly for anything else.

```ts
import { readDocument } from "@sienna-platform/power-openapi-models/document";
import { createDatabase, insertDocument } from "@sienna-platform/griddb-tools";

const db = createDatabase("system.sqlite");
const report = insertDocument(db, readDocument("system.json"));
console.log(JSON.stringify(report, null, 2));
```

Any plain JSON object works; zod-parsed SDK objects are plain objects. Fields GridDB
has no column for yet are counted in `report.skipped_fields`; pass `{ strict: true }`
to throw. CLI: `griddb-tools build system.json system.sqlite`.
A portfolio and its base system: `insertFile(db, "portfolio_dir")`, or the CLI with the directory.
