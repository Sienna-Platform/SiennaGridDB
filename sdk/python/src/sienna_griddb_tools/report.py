"""InsertReport: what an insert call wrote, and what it could not."""

import json
from dataclasses import dataclass, field


@dataclass
class InsertReport:
    inserted: dict = field(default_factory=dict)
    skipped_fields: dict = field(default_factory=dict)
    unsupported: dict = field(default_factory=dict)

    def add_inserted(self, key, n=1):
        self.inserted[key] = self.inserted.get(key, 0) + n

    def add_skipped(self, type_name, field_name, n=1):
        fields = self.skipped_fields.setdefault(type_name, {})
        fields[field_name] = fields.get(field_name, 0) + n

    def add_unsupported(self, key, n):
        self.unsupported[key] = self.unsupported.get(key, 0) + n

    def merge(self, other):
        for key, n in other.inserted.items():
            self.add_inserted(key, n)
        for type_name, fields in other.skipped_fields.items():
            for field_name, n in fields.items():
                self.add_skipped(type_name, field_name, n)
        for key, n in other.unsupported.items():
            self.add_unsupported(key, n)

    def to_dict(self):
        return {
            "inserted": self.inserted,
            "skipped_fields": self.skipped_fields,
            "unsupported": self.unsupported,
        }

    def to_json(self):
        return json.dumps(self.to_dict(), indent=2, sort_keys=True) + "\n"
