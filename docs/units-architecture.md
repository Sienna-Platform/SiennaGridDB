# Units in SiennaGridDB

How SiennaGridDB declares, generates, and enforces physical units — for `time-series-store` to
mirror the pattern, and to match the schema when a time series ends up stored inside GridDB itself.

## 1. Vocabulary and generation

One shared vocabulary, generated into a sealed SQL file, loaded like any other schema file.

```mermaid
flowchart LR
    subgraph Source of truth
        U[SiennaSchemas<br/>Core/units.json]
    end
    subgraph GridDB-owned
        C[schema/column_conventions.json<br/>column → quantity_type, unit]
    end
    U --> G[generate_unit_registry.py]
    C --> G
    G -->|sha256 seal| R[schema/unit_registry.sql]
    R --> DB[(griddb.sqlite)]
    U -.sync check.-> S[check_units_sync.py]
    R -.sync check.-> S
    PSY[PowerSystems.jl descriptor] -.optional layer.-> S
```

`generate_unit_registry.py` refuses any `(quantity_type, unit)` pair absent from `units.json` — the
registry can never invent vocabulary. Regeneration is deterministic: same inputs, byte-identical
output, same seal.

## 2. Schema

Five tables carry the vocabulary and the column map; two more attach units to data rather than to
a fixed schema column.

```mermaid
erDiagram
    quantity_types ||--o{ allowed_units : constrains
    quantity_types ||--o{ unit_conventions : "typed by"
    quantity_types ||--o{ unit_basis_rules : "typed by"
    quantity_types ||--o{ attributes : "typed by"
    quantity_types }o..o{ time_series_associations : "guarded when name is registered"
    allowed_units ||--o{ attributes : validates
    allowed_units }o..o{ time_series_associations : "validates registered kinds"
    unit_basis_rules }o..o{ unit_conventions : "quantity_type match, not FK"
    entities ||--o{ attributes : has
    time_series_associations ||--o{ static_time_series : "values for (by uri)"
    entities ||--o{ time_series_associations : owns

    quantity_types {
        text name PK
        text default_unit
        text dimension
        text description
    }
    allowed_units {
        text quantity_type FK
        text unit
    }
    unit_conventions {
        int id PK
        text table_name
        text column_name
        text quantity_type FK
        text unit
        text discriminator_column
        text discriminator_value
        text base_power_ref
        text base_voltage_ref
    }
    unit_basis_rules {
        text quantity_type PK_FK
        text base_expression
        text description
    }
    attributes {
        int id PK
        int entity_id FK
        text name
        json value
        text unit
        text quantity_type FK
    }
    time_series_associations {
        int association_id UK
        int owner_id FK
        int owner_category
        int time_series_type
        text name
        int scenario_count
        text units
        text quantity_kind
        text unit_system
        text uri
        blob data_hash
        blob features_hash
    }
    static_time_series {
        text uri
        int idx
        real value
    }
```

Two ways a column gets its unit:

- **Fixed schema column** (`transmission_lines.continuous_rating`) — one `unit_conventions` row,
  joined for display through the `column_units` view.
- **Polymorphic column** (`transformer_circuits.r`, whose unit depends on `unit_basis`) — one
  `unit_conventions` row per discriminator value. `attributes` rows follow the same idea but carry
  their own `unit`/`quantity_type` inline, because the sibling discriminator doesn't exist in the
  generic attribute table.

Time series don't use either — see §4. `unit_basis` and the pu resolution mechanism are §5.

## 3. Enforcement

The registry tables are read-only after the seal row is inserted; `attributes` and
`time_series_associations` writes are checked against the vocabulary by triggers, not by
application code.

```mermaid
flowchart TD
    W[INSERT/UPDATE attributes or time_series_associations] --> T{BEFORE trigger}
    T -->|known column/attribute name| M[unit + quantity_type must match\nthe registered unit_conventions row]
    T -->|unregistered attribute, physical value| A[unit + quantity_type must be\na valid pair in allowed_units]
    T -->|association with REGISTERED quantity_kind| V[quantity_kind, units must be\na valid pair in allowed_units]
    T -->|association with free-form quantity_kind| OK
    M -->|mismatch| X[RAISE ABORT]
    A -->|mismatch| X
    V -->|mismatch| X
    M -->|match| OK[write proceeds]
    A -->|match| OK
    V -->|match| OK
```

Registry writes themselves (`quantity_types`, `allowed_units`, `unit_conventions`) are blocked
outright once `unit_management_metadata.unit_conventions_checksum` exists — the only way to change
the vocabulary is regenerate-and-reload. The seal is **detection, not prevention**: SQLite has no
privilege model, so `verify_unit_registry.py` is what actually catches tampering.

## 4. Time series: unit-per-association, not unit-per-column

A time series column can't have one fixed unit — the same `static_time_series` table holds load,
wind, price, and reserve data. So the unit lives on the association row, exactly where infrastore's
catalog puts it (`units`, `quantity_kind`, `unit_system`):

```mermaid
sequenceDiagram
    participant App as Writer
    participant Assoc as time_series_associations
    participant Reg as allowed_units
    participant Data as static_time_series

    App->>Assoc: INSERT (owner, name, units, quantity_kind, uri, ...)
    Assoc->>Reg: trigger checks (quantity_kind, units) when quantity_kind is registered
    Reg-->>Assoc: OK or ABORT
    App->>Data: INSERT (uri, idx, value)
    Data->>Assoc: trigger checks uri exists on some association
    Assoc-->>Data: OK or ABORT
```

Alongside those, `association_id` carries the store-minted surrogate id. It is not decoration: a
time-series-backed cost payload names its series by this number — a `TIME_SERIES_*` function data's
`association_id`, `FuelCurve.fuel_cost_time_series`, `MarketBidTimeSeriesCost.start_up_association_id`,
and the two `*_association_id` fields on the incremental and average-rate curves. The rowid `id` is
not a substitute: SQLite may reuse it after a delete, and a reused reference resolving to a
different series is the failure the minted id exists to prevent.

`quantity_kind` is deliberately free-form, mirroring infrastore: composite economic quantities
($/MWh, MMBtu/MWh) must not require a vocabulary migration. The guard fires only when a row uses a
REGISTERED quantity-type name with an unregistered (or missing) unit — a typo on a known quantity
is a defect, not new vocabulary. Dense values are located by `uri` (the SiennaSchemas wire form's
required locator; here it keys `static_time_series` directly): inserts are rejected until some
association declares the `uri`, so associations load first and arrays shared by many associations
are stored once. The association's optional `data_hash` is an integrity hash of the array, not the
key.

## 5. Basis: per-unit vs. natural units, and where the base number lives

A pu value is meaningless without knowing what it's normalized against. GridDB expresses that with
two orthogonal axes, not one: **basis** (is this pu or a physical unit?) and **quantity** (which
physical quantity, and — under `NATURAL_UNITS` — which representation of it?).

### Axis 1: `unit_basis`, exactly two values

One discriminator column, `unit_basis`, on eight tables — `transmission_lines`,
`transformer_circuits`, `fixed_admittance`, `switched_admittance`, `sources`, `tmodel_hvdc_lines`,
`facts_control_devices`, `interconnecting_converters` (time series carry the same two-valued
choice as `time_series_associations.unit_system`, in infrastore's lowercase spelling — see §6):

- **`NATURAL_UNITS`** — a physical unit (ohm, S, MVAr, MW, kV). Self-contained, no base needed.
- **`COMPONENT_BASE`** — dimensionless pu against bases reachable from the row.

This replaced three differently-named, differently-valued columns: `parameter_units`
(`SYSTEM_BASE`/`NATURAL_UNITS`), `admittance_units` (`SYSTEM_BASE`/`NATURAL_UNITS`/`DEVICE_MVAR`),
and `voltage_setpoint_units` (`SYSTEM_BASE`/`NATURAL_UNITS`).

### Why two values, where upstream SiennaSchemas has three

Upstream distinguishes `DEVICE_BASE` / `SYSTEM_BASE` / `NATURAL_UNITS`. `DEVICE_BASE` and
`SYSTEM_BASE` differ *only* in **which number** the base is — a transformer winding's own
`SBASE1-2` versus a line's `SBASE` — not in how the pu value is interpreted once that number is
known. Once a row stores or can reach the number, the label recording *where the value came from*
is redundant; two values suffice where upstream needs three.

### Axis 2: `quantity_type` also selects the natural-unit representation

Under `NATURAL_UNITS`, `quantity_type` picks *which* physical representation a column holds. This is
how the old `admittance_units` value `DEVICE_MVAR` was absorbed without a third basis value:
`fixed_admittance.y_b` (and `switched_admittance.y_b`) each carry three `unit_conventions` rows —

| quantity_type | unit | unit_basis |
|---|---|---|
| `Susceptance` | `S` | `NATURAL_UNITS` |
| `ReactivePower` | `MVAr` | `NATURAL_UNITS` |
| `Susceptance` | `pu` | `COMPONENT_BASE` |

— the electrical form and the PSS/E form (MVAr at 1.0 pu voltage) are both natural units,
distinguished only by `quantity_type`. This required widening `unit_conventions`' uniqueness key
from `(table_name, column_name, discriminator_value, discriminator_value_2)` to also include
`quantity_type`.

### PSSE grounding: why transformers are the exception

Verified in `PowerFlowFileParser.jl`, `src/pm_io/psse.jl` (~line 276): a transformer winding record
carries its own base (`SBASE1-2`/`2-3`/`3-1`, `NOMV1`/`2`/`3`, with `CZ` selecting the convention),
so `three_winding_transformers.base_power_12`/`_23`/`_31` store that base verbatim. A BRANCH record
declares no MVA base of its own — `SBASE`, the system base, is the only base available — and a fixed
or switched shunt's `GL`/`BL` are MW/MVAr at unity voltage, so both take the system base written in
at parse time instead. That's why `transmission_lines`, `fixed_admittance`, and `switched_admittance`
carry a `base_power` column that is a *snapshot* rather than a device-native quantity.

### There is still no system base stored in the database

No `systems`/`cases` table exists, and none was added. A single shared `base_power` row would be
mutable state that silently reinterprets every `COMPONENT_BASE` row the moment two callers assume
different values. "System base" remains a property of the model an application builds
(`PSY.get_base_power(sys)`), decided once at load time. What changed is that each row now *carries
or can reach* the number it was normalized against — not that GridDB now knows the system's one true
base.

**Accepted limitation.** Nothing enforces that every row's `base_power` agrees. A writer that
inserts one line at 100 MVA and another at 138 MVA produces two internally consistent rows that
contradict each other, silently. Cross-row agreement is an application responsibility; a future
trigger could enforce it but does not exist today.

**Accepted limitation.** The base columns a `COMPONENT_BASE` row resolves against —
`balancing_topologies.base_voltage`, `sources.base_voltage`,
`transformer_circuits.base_voltage_primary`/`base_voltage_secondary` — are nullable, and nothing
enforces that they are actually set. An ordinary insert of a `transmission_lines` row whose buses
have no `base_voltage` set succeeds: `unit_basis` defaults to `COMPONENT_BASE`, `base_power`
defaults to 100.0, and `r`/`x` are stored as pu — but the resolved `base_voltage` is NULL, and
since `Resistance`/`Reactance` resolve via `base_voltage^2/base_power`, that pu value cannot be
converted at all. This is strictly worse than the cross-row disagreement above: the value is
absent, not merely inconsistent. Closing it would require either per-table triggers asserting the
resolved base is non-null when `unit_basis = 'COMPONENT_BASE'`, or making
`balancing_topologies.base_voltage` `NOT NULL`; both are open decisions, not yet taken.

### Mechanical resolution: rules + base references

A sealed table, `unit_basis_rules` (5 rows), maps the five quantity types that ever carry pu to the
base expression that resolves them:

| quantity_type | base_expression |
|---|---|
| `Voltage` | `base_voltage` |
| `Resistance`, `Reactance` | `base_voltage^2/base_power` |
| `Susceptance`, `Conductance` | `base_power/base_voltage^2` |

`unit_conventions` gained nullable `base_power_ref` / `base_voltage_ref` naming *which* bases apply.
No arrow means a same-row column; an arrow is an FK hop, each segment after the first written
`table.column`, the last segment naming the base column itself:

```
base_power_ref   = 'base_power_12'                                            -- same row
base_power_ref   = 'circuit->transformer_circuits.base_power'                 -- one hop
base_voltage_ref = 'arc_id->arcs.from_id->balancing_topologies.base_voltage'  -- two hops
```

The rule: a base must be reachable **without leaving the database** — same-row and FK-path both
satisfy that; only "in the modeling application" doesn't. `balancing_topologies.base_voltage` is new
— bus base voltage previously lived only as an `attributes` row — and is the target of most
two-winding and line paths. `transmission_lines`, `fixed_admittance`, `switched_admittance`, and
`tmodel_hvdc_lines` also gained their own same-row `base_power`.

Together these give one invariant, checked by `test_pu_conventions_have_resolvable_basis`: every
`unit='pu'` convention has a `unit_basis_rules` row for its quantity type, and every base reference
it names resolves *structurally* — the named column exists, or every FK hop's table/column/FK
exists. That is a schema-shape guarantee, not a data guarantee: it says the base is reachable, not
that any given row's base is populated — see the second Accepted limitation above. Not every pu
column carries a `unit_basis` discriminator, though — `two_winding_transformers.magnetizing_shunt`
and `three_winding_transformers.r_12`/`x_12`/etc. are pu-only, with no `NATURAL_UNITS` sibling row,
because their governing table has no such column to discriminate on.

`attributes` rows are exempt from base references: an attribute's owner is polymorphic (`entity_id`
→ `entities`), so no single static path applies regardless of which table is on the other end. They
keep their inline `unit`/`quantity_type` instead; the exemption is recorded in
`coverage_decisions.json`.

### Open items

- `transformer_circuits.controlled_quantity_limits` resolves its pu arms against
  `base_voltage_primary`, but the PSS/E VMA/VMI controlled bus may be the *secondary* side for some
  transformers. Flagged for human review, not resolved here.
- No cross-repo check catches a pu column typed with the wrong quantity dimension (e.g. a
  `Resistance` column mistakenly registered as `Voltage`, still `unit='pu'`) — upstream x-unit
  annotations carry units, not quantity types, so there's nothing on the other side to contradict.
  `test_pu_conventions_have_resolvable_basis` only exercises columns with a `COMPONENT_BASE` +
  `NATURAL_UNITS` sibling pair; pu-only columns with no such sibling arm (the
  `three_winding_transformers.r_12`-style rows above) are not covered by any dimensional check.

## 6. The infrastore mirror: association tables are a wire contract

GridDB's `time_series_associations` (with its `feature_sets` / `timestamp_sets` companions) and
`supplemental_attribute_associations` mirror infrastore's catalog tables column-for-column
(`crates/infrastore-core/src/metadata/schema.rs`), so association rows written here deserialize
straight into a store at the modeling stage. The mirror is the contract; consequences worth
knowing:

**Integer codes and BLOB hashes are on-disk contracts.** `owner_category` (0 = Component,
1 = SupplementalAttribute) and `time_series_type` (0–5, `SingleTimeSeries` through `Scenarios`)
are infrastore's `::code` values, not names — the `time_series_readable` view decodes them for
hand inspection. `data_hash` / `features_hash` / `timestamps_hash` are SHA-256 content addresses;
`timestamp_sets.data` carries infrastore's varint delta encoding verbatim so an irregular time
axis round-trips bit-exact.

**Where the catalog and the SiennaSchemas wire form diverge, the wire form wins.** The schemas
(`TimeSeries/*.json`) require `uri` (the dense-data locator) and `element_shape`, and declare
`data_hash` an optional content hash; infrastore's catalog has no `uri` and requires `data_hash`.
GridDB follows the schemas: `uri` is NOT NULL and keys `static_time_series`, `element_shape` is
NOT NULL (default `'[]'` = scalar), `data_hash` is nullable. A row deserializing into a store that
demands a hash computes it from the dense values at ingest.

**`unit_system` uses infrastore's spelling, not the component tables'.** Lowercase
`'natural_units'` / `'component_base'`, NULL meaning unspecified, and deliberately no CHECK — a
third basis must land without a format bump. Same two-valued concept as §5's `unit_basis`, a
different vocabulary on purpose: this column is infrastore's, carried through unchanged.

**`quantity_kind` is free-form; the registry guards only registered names.** Infrastore leaves the
column unconstrained so composite economic quantities never force a migration. GridDB adds one
write-side trigger on top: a row whose `quantity_kind` names a registered quantity type must pair
it with a registered unit from `allowed_units`. Free-form kinds pass untouched; the divergence adds
integrity without changing the row shape.

**No per-series base snapshot.** A `component_base` series is interpreted against the owning
component's own base columns (`base_power`, winding voltage bases, …) — the association carries no
`base_power`/`base_voltage` of its own, matching infrastore, where the consumer's object model owns
the bases. Resolvability at the data level is the writer's responsibility, same as cross-row
`base_power` agreement in §5.

**GridDB keeps referential integrity infrastore deliberately omits.** Infrastore's endpoints live
in the consumer's object graph, so it has no FKs; here both endpoints live in this database, so
`owner_id`/`component_id`/`attribute_id` are FK-enforced (plus an owner-domain trigger for
`owner_category = 1`). FKs are GridDB-side only and vanish harmlessly on deserialization.
