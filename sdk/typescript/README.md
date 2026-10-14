# @sienna-platform/griddb-tools

Insert Sienna OpenAPI SDK objects into a SiennaGridDB SQLite database (Node ≥ 22).

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
