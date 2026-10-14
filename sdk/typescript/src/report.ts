export class InsertReport {
  inserted: Record<string, number> = {};
  skipped_fields: Record<string, Record<string, number>> = {};
  unsupported: Record<string, number> = {};

  addInserted(key: string, n = 1): void {
    this.inserted[key] = (this.inserted[key] ?? 0) + n;
  }

  addSkipped(typeName: string, field: string): void {
    const fields = (this.skipped_fields[typeName] ??= {});
    fields[field] = (fields[field] ?? 0) + 1;
  }

  addUnsupported(key: string, n: number): void {
    this.unsupported[key] = (this.unsupported[key] ?? 0) + n;
  }

  toJSON(): object {
    return {
      inserted: sortKeys(this.inserted),
      skipped_fields: Object.fromEntries(
        Object.keys(this.skipped_fields)
          .sort()
          .map((k) => [k, sortKeys(this.skipped_fields[k])]),
      ),
      unsupported: sortKeys(this.unsupported),
    };
  }
}

function sortKeys(o: Record<string, number>): Record<string, number> {
  return Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]));
}
