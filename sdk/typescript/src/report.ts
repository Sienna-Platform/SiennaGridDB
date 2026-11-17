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

  merge(other: InsertReport): void {
    for (const [k, n] of Object.entries(other.inserted)) this.addInserted(k, n);
    for (const [t, fields] of Object.entries(other.skipped_fields)) {
      const mine = (this.skipped_fields[t] ??= {});
      for (const [f, n] of Object.entries(fields)) mine[f] = (mine[f] ?? 0) + n;
    }
    for (const [k, n] of Object.entries(other.unsupported)) this.addUnsupported(k, n);
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
