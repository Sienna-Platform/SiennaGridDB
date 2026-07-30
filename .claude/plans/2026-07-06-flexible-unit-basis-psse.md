# Flexible Unit-Basis for PSS/E-Sourced Fields — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the electrical fields that PSS/E ships in a non-per-unit basis (DC-line impedances in ohm, shunt admittances in Mvar-at-unity-voltage, FACTS voltage setpoint in pu) storable in their native basis via an explicit per-row discriminator — so a PSS/E RAW case round-trips through SiennaSchemas → SiennaGridDB with **zero unit conversion**.

**Architecture:** Mirror the existing `transmission_lines.parameter_units` pattern. In **SiennaSchemas** each unit-flexible field gains an `x-unit-discriminator` pointing at a new sibling enum property (the "unit basis"), with an `x-units` map from basis → unit. In **SiennaGridDB** each such column gets a paired discriminator column (`CHECK (... IN (...))`) plus one `column_conventions.json` row per basis value; the sealed `unit_registry.sql` is regenerated. The discriminator **value strings are identical in both layers** (the sync check requires it).

**Tech Stack:** JSON Schema (SiennaSchemas), SQLite ≥3.45 DDL + JSON (SiennaGridDB), Python generators (`generate_unit_registry.py`, `check_units_sync.py`), pytest.

## Global Constraints

- **Merge order is load-bearing.** Any `units.json` change (Phase 0) must land + be tagged as a SiennaSchemas release **before** SiennaGridDB regenerates its registry (Phase 2). Never regenerate GridDB against an untagged SiennaSchemas. Source: `SiennaGridDB/.claude/CLAUDE.md`.
- **Discriminator-key identity.** For every flexible field, the SiennaSchemas `x-units` map keys MUST equal, string-for-string, the SiennaGridDB `column_conventions` `discriminator_value`s for that column. `check_units_sync.py` L1 fails on `discriminator key mismatch` otherwise (`scripts/check_units_sync.py:257`).
- **Every `(quantity_type, unit)` used in `column_conventions.json` must already exist in `units.json allowed_units`** or `generate_unit_registry.py` refuses it.
- **`unit_registry.sql` is generated + checksum-sealed.** After any convention change: `python3 scripts/generate_unit_registry.py`, then `python3 scripts/verify_unit_registry.py <db>`. Never hand-edit it.
- **Bump `PRAGMA user_version`** in `schema/schema.sql` on any schema/registry change (currently `2` → `3`).
- **Basis vocabulary (canonical, reuse verbatim):**
  - Impedance fields — discriminator enum `ImpedanceUnitBasis`, values `SYSTEM_BASE`→`pu`, `NATURAL_UNITS`→`ohm`.
  - Shunt-admittance fields — discriminator enum `AdmittanceUnitBasis`, values `SYSTEM_BASE`→`pu`, `NATURAL_UNITS`→`S`, `DEVICE_MVAR`→Mvar-at-unity-voltage (`ReactivePower/MVAr` for susceptance parts, `ActivePower/MW` for conductance parts).
  - Voltage-setpoint fields — discriminator enum `VoltageUnitBasis`, values `NATURAL_UNITS`→`kV`, `SYSTEM_BASE`→`pu`.
- **PSS/E is the anchor.** Native units, confirmed against PSS®E 36.0.1 `raw_descriptor.md`: `RDC/RCR/XCR/XCAPR/RCOMP`=ohm; `EBASR/VSCHD/VCMOD`=kV; `BINIT/Bi`, bus `GL/BL`=Mvar/MW at unity voltage; FACTS `VSET`, VSC `ACSET`=pu; VSC `DCSET`=kV/MW.

## Field Inventory (the spec)

Only these fields are in scope. Each row: component → field(s) → basis enum → default basis.

| Component (SiennaSchemas file) | Flexible fields | Basis enum | Default |
|---|---|---|---|
| `Operations/Branch/TwoTerminalLCCLine.json` | `r`, `rectifier_rc`, `rectifier_xc`, `inverter_rc`, `inverter_xc`, `rectifier_capacitor_reactance`, `inverter_capacitor_reactance`, `compounding_resistance` | `ImpedanceUnitBasis` | `NATURAL_UNITS` (PSS/E ohm) |
| `Operations/Branch/TModelHVDCLine.json` | `r` | `ImpedanceUnitBasis` | `NATURAL_UNITS` |
| `Operations/StaticInjection/Source.json` | `R_th`, `X_th` | `ImpedanceUnitBasis` | `SYSTEM_BASE` (PSY-native pu) |
| `Operations/StaticInjection/FixedAdmittance.json` | `Y` | `AdmittanceUnitBasis` | `DEVICE_MVAR` (PSS/E Mvar) |
| `Operations/StaticInjection/SwitchedAdmittance.json` | `Y`, `Y_increase`, `admittance_limits` | `AdmittanceUnitBasis` | `DEVICE_MVAR` |
| `Operations/Branch/TwoTerminalVSCLine.json` | `g` | `AdmittanceUnitBasis` | `NATURAL_UNITS` |
| `Operations/StaticInjection/FACTSControlDevice.json` | `voltage_setpoint` | `VoltageUnitBasis` | `SYSTEM_BASE` (PSS/E pu) |

**Explicitly out of scope** (note only, no tasks): `TModelHVDCLine.l/c` (needs `Inductance/pu` + `Capacitance/pu` vocabulary that does not exist — separate decision); `TwoTerminalGenericHVDCLine` (no impedance fields; loss-model only); VSC `dc_setpoint_*`/`ac_setpoint_*`/`voltage_limits_*` (already discriminated by control mode — leave as-is, but see Note A); the OpenAPI converter (`SiennaOpenAPIModels.jl`, separate repo) — see Note B.

> **Note A (converter contradiction, do NOT propagate):** PR NLR-Sienna/PowerSystemSchemas#76 force-converts VSC `ac_setpoint` and FACTS `voltage_setpoint` to kV, but PSS/E and the SiennaSchemas discriminator both say pu. This plan keeps them pu-capable; the converter fix is tracked separately.
> **Note B:** "Parse PSS/E without conversion" is completed at the schema+DB layer here. The importer that writes rows with the correct basis lives in the OpenAPI converter repo and is a downstream consumer of this contract.

---

## Phase 0 — Vocabulary (SiennaSchemas `Core/units.json`)

### Task 0.1: Add the `(Voltage, pu)` allowed-unit pair

**Files:**
- Modify: `SiennaSchemas/Core/units.json` (the `allowed_units` array)

**Interfaces:**
- Produces: allowed pair `(Voltage, pu)`, consumed by Phase 2 FACTS `voltage_setpoint` `SYSTEM_BASE` convention row.

- [ ] **Step 1: Verify the pair is absent**

Run: `python3 -c "import json;u=json.load(open('SiennaSchemas/Core/units.json'));print(('Voltage','pu') in {(a['quantity_type'],a['unit']) for a in u['allowed_units']})"`
Expected: `False`

- [ ] **Step 2: Add the pair**

In `SiennaSchemas/Core/units.json`, in `allowed_units`, immediately after the `{"quantity_type": "Voltage", "unit": "kV", ...}` row, add:

```json
    {"quantity_type": "Voltage", "unit": "pu", "to_default": null},
```

(Use `null` for `to_default` — pu↔kV is context-dependent on base voltage, not a fixed factor. Match the `to_default` style of other pu rows in the file; if pu rows use a different sentinel, copy that sentinel instead.)

- [ ] **Step 3: Verify JSON validity + pair present**

Run: `python3 -c "import json;u=json.load(open('SiennaSchemas/Core/units.json'));print(('Voltage','pu') in {(a['quantity_type'],a['unit']) for a in u['allowed_units']})"`
Expected: `True`

- [ ] **Step 4: Commit** (SiennaSchemas repo)

```bash
cd SiennaSchemas && git add Core/units.json
git commit -m "units: allow (Voltage, pu) for flexible voltage-setpoint basis"
```

---

## Phase 1 — SiennaSchemas contract (enums + field annotations)

### Task 1.1: Define the three unit-basis enums

**Files:**
- Modify: `SiennaSchemas/Core/common.json` (the `definitions` object)

**Interfaces:**
- Produces: `#/definitions/ImpedanceUnitBasis`, `#/definitions/AdmittanceUnitBasis`, `#/definitions/VoltageUnitBasis` — referenced by every Phase 1 component task via `$ref: "../../Core/common.json#/definitions/<Name>"`.

- [ ] **Step 1: Add the three definitions**

In `SiennaSchemas/Core/common.json` under `definitions`, add (mirroring the existing `VSCDCControlModes` shape — `enum`/`title`/`type`/`description`):

```json
    "ImpedanceUnitBasis": {
      "description": "Unit basis a branch/injection impedance is stored in. SYSTEM_BASE: per-unit on the system MVA/voltage base. NATURAL_UNITS: physical ohms (PSS/E RAW native for DC-line impedances).",
      "enum": ["SYSTEM_BASE", "NATURAL_UNITS"],
      "title": "ImpedanceUnitBasis",
      "type": "string"
    },
    "AdmittanceUnitBasis": {
      "description": "Unit basis a shunt admittance is stored in. SYSTEM_BASE: per-unit on the system base. NATURAL_UNITS: physical siemens. DEVICE_MVAR: reactive power at unity voltage (Mvar for susceptance, MW for conductance) — PSS/E RAW native for fixed/switched shunts.",
      "enum": ["SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"],
      "title": "AdmittanceUnitBasis",
      "type": "string"
    },
    "VoltageUnitBasis": {
      "description": "Unit basis a voltage setpoint is stored in. SYSTEM_BASE: per-unit on the bus base voltage (PSS/E RAW native for FACTS VSET). NATURAL_UNITS: kilovolts.",
      "enum": ["SYSTEM_BASE", "NATURAL_UNITS"],
      "title": "VoltageUnitBasis",
      "type": "string"
    },
```

- [ ] **Step 2: Verify JSON validity**

Run: `python3 -c "import json;d=json.load(open('SiennaSchemas/Core/common.json'));print(sorted(k for k in d['definitions'] if 'UnitBasis' in k))"`
Expected: `['AdmittanceUnitBasis', 'ImpedanceUnitBasis', 'VoltageUnitBasis']`

- [ ] **Step 3: Commit**

```bash
cd SiennaSchemas && git add Core/common.json
git commit -m "schemas: add Impedance/Admittance/Voltage unit-basis enums"
```

### Task 1.2: Annotate `TwoTerminalLCCLine` impedances

**Files:**
- Modify: `SiennaSchemas/Operations/Branch/TwoTerminalLCCLine.json`

**Interfaces:**
- Consumes: `#/definitions/ImpedanceUnitBasis` (Task 1.1).
- Produces: `parameter_units` property + `x-unit-discriminator: parameter_units`, `x-units: {"SYSTEM_BASE":"pu","NATURAL_UNITS":"ohm"}` on the 8 listed fields. GridDB Task 2.4 relies on discriminator name `parameter_units` and these two keys.

- [ ] **Step 1: Add the discriminator property**

In the `properties` block, add:

```json
    "parameter_units": {
      "description": "Unit basis for this line's impedance fields (r, rectifier/inverter rc/xc, capacitor reactances, compounding_resistance).",
      "default": "NATURAL_UNITS",
      "$ref": "../../Core/common.json#/definitions/ImpedanceUnitBasis"
    },
```

- [ ] **Step 2: Convert each impedance field's `x-unit` → discriminated form**

For each of `r`, `rectifier_rc`, `rectifier_xc`, `inverter_rc`, `inverter_xc`, `rectifier_capacitor_reactance`, `inverter_capacitor_reactance`, `compounding_resistance`: remove `"x-unit": "pu"` and add:

```json
      "x-unit-discriminator": "parameter_units",
      "x-units": {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "ohm"},
```

Append to each field's `description`: `" Units: per parameter_units — SYSTEM_BASE: pu, NATURAL_UNITS: ohm."`

- [ ] **Step 3: Verify structure**

Run:
```bash
python3 - <<'PY'
import json
d=json.load(open('SiennaSchemas/Operations/Branch/TwoTerminalLCCLine.json'))
p=d['properties']; ok=True
for f in ["r","rectifier_rc","rectifier_xc","inverter_rc","inverter_xc","rectifier_capacitor_reactance","inverter_capacitor_reactance","compounding_resistance"]:
    v=p[f]; ok &= v.get("x-unit-discriminator")=="parameter_units" and v.get("x-units")=={"SYSTEM_BASE":"pu","NATURAL_UNITS":"ohm"} and "x-unit" not in v
print("OK" if ok and p["parameter_units"]["$ref"].endswith("ImpedanceUnitBasis") else "FAIL")
PY
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
cd SiennaSchemas && git add Operations/Branch/TwoTerminalLCCLine.json
git commit -m "schemas: flexible impedance basis for TwoTerminalLCCLine"
```

### Task 1.3: Annotate `TModelHVDCLine.r`

**Files:**
- Modify: `SiennaSchemas/Operations/Branch/TModelHVDCLine.json`

**Interfaces:** Consumes `ImpedanceUnitBasis`. Produces `parameter_units` + discriminated `r`.

- [ ] **Step 1: Add `parameter_units` property** (identical block to Task 1.2 Step 1, `default": "NATURAL_UNITS"`, description referencing `r`).
- [ ] **Step 2:** On `r`, remove `"x-unit":"pu"`, add `"x-unit-discriminator":"parameter_units"`, `"x-units":{"SYSTEM_BASE":"pu","NATURAL_UNITS":"ohm"}`, and append the Units sentence to its description. Leave `l` and `c` unchanged (out of scope).
- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/Branch/TModelHVDCLine.json'))['properties'];print('OK' if p['r'].get('x-unit-discriminator')=='parameter_units' and 'x-unit' not in p['r'] else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible impedance basis for TModelHVDCLine.r"`

### Task 1.4: Annotate `Source.R_th`/`X_th`

**Files:** Modify `SiennaSchemas/Operations/StaticInjection/Source.json`
**Interfaces:** Consumes `ImpedanceUnitBasis`. Produces `parameter_units` + discriminated `R_th`,`X_th`.

- [ ] **Step 1:** Add `parameter_units` property, `"default":"SYSTEM_BASE"` (PSY stores Source impedance in pu; PSS/E has no Source record), description referencing `R_th`/`X_th`.
- [ ] **Step 2:** On `R_th` and `X_th`, remove `"x-unit":"pu"`, add the `x-unit-discriminator`/`x-units` pair and Units sentence. Leave `internal_voltage` (`x-unit-base`) untouched.
- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/StaticInjection/Source.json'))['properties'];print('OK' if all(p[f].get('x-unit-discriminator')=='parameter_units' and 'x-unit' not in p[f] for f in ('R_th','X_th')) else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible impedance basis for Source R_th/X_th"`

### Task 1.5: Annotate `FixedAdmittance.Y`

**Files:** Modify `SiennaSchemas/Operations/StaticInjection/FixedAdmittance.json`
**Interfaces:** Consumes `AdmittanceUnitBasis`. Produces `admittance_units` + discriminated `Y` with keys `SYSTEM_BASE/NATURAL_UNITS/DEVICE_MVAR`.

- [ ] **Step 1: Add discriminator property**

```json
    "admittance_units": {
      "description": "Unit basis for the shunt admittance Y. DEVICE_MVAR is PSS/E RAW native (Mvar/MW at unity voltage).",
      "default": "DEVICE_MVAR",
      "$ref": "../../Core/common.json#/definitions/AdmittanceUnitBasis"
    },
```

- [ ] **Step 2:** On `Y`, remove `"x-unit":"pu"` and add:

```json
      "x-unit-discriminator": "admittance_units",
      "x-units": {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "S", "DEVICE_MVAR": "MVAr"},
```

Append Units sentence: `" Units: per admittance_units — SYSTEM_BASE: pu, NATURAL_UNITS: S, DEVICE_MVAR: MVAr (reactive part; conductance part is MW at unity voltage)."`

- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/StaticInjection/FixedAdmittance.json'))['properties'];print('OK' if p['Y'].get('x-units')=={'SYSTEM_BASE':'pu','NATURAL_UNITS':'S','DEVICE_MVAR':'MVAr'} else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible admittance basis for FixedAdmittance.Y"`

### Task 1.6: Annotate `SwitchedAdmittance` (`Y`, `Y_increase`, `admittance_limits`)

**Files:** Modify `SiennaSchemas/Operations/StaticInjection/SwitchedAdmittance.json`
**Interfaces:** Consumes `AdmittanceUnitBasis`. Produces `admittance_units` + 3 discriminated fields.

- [ ] **Step 1:** Add `admittance_units` property (identical to Task 1.5 Step 1).
- [ ] **Step 2:** On each of `Y`, `Y_increase`, `admittance_limits`: remove `"x-unit":"pu"`, add the same `x-unit-discriminator`/`x-units` block as Task 1.5 Step 2, append the Units sentence.
- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/StaticInjection/SwitchedAdmittance.json'))['properties'];print('OK' if all(p[f].get('x-unit-discriminator')=='admittance_units' and 'x-unit' not in p[f] for f in ('Y','Y_increase','admittance_limits')) else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible admittance basis for SwitchedAdmittance"`

### Task 1.7: Annotate `TwoTerminalVSCLine.g`

**Files:** Modify `SiennaSchemas/Operations/Branch/TwoTerminalVSCLine.json`
**Interfaces:** Consumes `AdmittanceUnitBasis`. Produces `admittance_units` + discriminated `g`.

- [ ] **Step 1:** Add `admittance_units` property, `"default":"NATURAL_UNITS"`, description referencing `g`.
- [ ] **Step 2:** On `g`, remove `"x-unit":"pu"`, add the `x-unit-discriminator: admittance_units` + `x-units {SYSTEM_BASE:pu, NATURAL_UNITS:S, DEVICE_MVAR:MVAr}` block + Units sentence. Leave `dc_setpoint_*`/`ac_setpoint_*`/`voltage_limits_*` untouched.
- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/Branch/TwoTerminalVSCLine.json'))['properties'];print('OK' if p['g'].get('x-unit-discriminator')=='admittance_units' and 'x-unit' not in p['g'] else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible admittance basis for TwoTerminalVSCLine.g"`

### Task 1.8: Annotate `FACTSControlDevice.voltage_setpoint`

**Files:** Modify `SiennaSchemas/Operations/StaticInjection/FACTSControlDevice.json`
**Interfaces:** Consumes `VoltageUnitBasis` + Phase 0 `(Voltage, pu)`. Produces `voltage_setpoint_units` + discriminated `voltage_setpoint`.

- [ ] **Step 1:** Add discriminator property:

```json
    "voltage_setpoint_units": {
      "description": "Unit basis for voltage_setpoint. SYSTEM_BASE (pu) is PSS/E RAW native (VSET).",
      "default": "SYSTEM_BASE",
      "$ref": "../../Core/common.json#/definitions/VoltageUnitBasis"
    },
```

- [ ] **Step 2:** On `voltage_setpoint`, remove `"x-unit":"kV"`, add `"x-unit-discriminator":"voltage_setpoint_units"`, `"x-units":{"SYSTEM_BASE":"pu","NATURAL_UNITS":"kV"}`, Units sentence.
- [ ] **Step 3: Verify**

Run: `python3 -c "import json;p=json.load(open('SiennaSchemas/Operations/StaticInjection/FACTSControlDevice.json'))['properties'];print('OK' if p['voltage_setpoint'].get('x-units')=={'SYSTEM_BASE':'pu','NATURAL_UNITS':'kV'} else 'FAIL')"`
Expected: `OK`

- [ ] **Step 4: Commit** `-m "schemas: flexible voltage-setpoint basis for FACTSControlDevice"`

### Task 1.9: Tag a SiennaSchemas release

**Files:** none (git tag + `dist/` bundle per SiennaSchemas release process).

- [ ] **Step 1:** Confirm Phases 0–1 committed: `cd SiennaSchemas && git status --short` → clean.
- [ ] **Step 2:** Build/refresh the `dist/` bundles per SiennaSchemas' own release script (check its `README`/`Makefile`), then tag: `git tag <next-version>` and push tag. **This gate unblocks Phase 2** (merge-order constraint).

---

## Phase 2 — SiennaGridDB (tables, conventions, registry)

> Each Phase-2 task's test cycle is the same 4-gate rebuild. Define this helper once at the top of your shell session:
> ```bash
> gridtest(){ set -e; cd /Users/jdlara/cache/psy6/SiennaGridDB; DB=$(mktemp -u).db
>   sqlite3 "$DB" < schema/schema.sql; sqlite3 "$DB" < schema/triggers.sql
>   sqlite3 "$DB" < schema/unit_registry.sql; sqlite3 "$DB" < schema/views.sql
>   python3 scripts/verify_unit_registry.py "$DB"
>   python3 scripts/check_units_sync.py --schemas-path ../SiennaSchemas --psy-path ../PowerSystems.jl | tail -3
>   <PYTEST> test/ -q | tail -3; rm -f "$DB"; }
> ```
> Replace `<PYTEST>` with the venv pytest path.

### Task 2.1: Create the `fixed_admittance` table (3-way admittance template)

**Files:**
- Modify: `SiennaGridDB/schema/schema.sql` (add table + its `DROP TABLE`)
- Modify: `SiennaGridDB/schema/column_conventions.json`
- Modify: `SiennaGridDB/schema/schema.sql` (bump `PRAGMA user_version`)
- Regenerate: `SiennaGridDB/schema/unit_registry.sql`

**Interfaces:**
- Consumes: SiennaSchemas `FixedAdmittance` contract (Task 1.5) — discriminator name `admittance_units`, keys `SYSTEM_BASE/NATURAL_UNITS/DEVICE_MVAR`.
- Produces: table `fixed_admittance(id, name, bus, y_g, y_b, admittance_units)`; six convention rows (`y_g` and `y_b` × 3 bases). Complex OpenAPI `Y` maps to `(y_g, y_b)` (mirrors `transmission_lines` `g`/`b` split).

- [ ] **Step 1: Add the `DROP TABLE`** near the other injection drops in `schema/schema.sql`:

```sql
DROP TABLE IF EXISTS fixed_admittance;
```

- [ ] **Step 2: Add the table** (place after `loads`, before the units tables):

```sql
-- Fixed shunt admittance (PSY FixedAdmittance). Complex Y is stored as conductance
-- (y_g) and susceptance (y_b) halves; admittance_units records the basis so PSS/E
-- data (Mvar/MW at unity voltage) is stored without conversion.
CREATE TABLE fixed_admittance (
    id INTEGER PRIMARY KEY REFERENCES entities (id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE,
    bus INTEGER NOT NULL REFERENCES balancing_topologies (id) ON DELETE CASCADE,
    y_g REAL NOT NULL DEFAULT 0.0,
    y_b REAL NOT NULL DEFAULT 0.0,
    admittance_units TEXT NOT NULL DEFAULT 'DEVICE_MVAR'
        CHECK (admittance_units IN ('SYSTEM_BASE', 'NATURAL_UNITS', 'DEVICE_MVAR'))
) strict;
```

- [ ] **Step 3: Add the six convention rows** to `schema/column_conventions.json` `conventions` array:

```json
    {"table": "fixed_admittance", "column": "y_g", "quantity_type": "Conductance", "unit": "pu", "discriminator_column": "admittance_units", "discriminator_value": "SYSTEM_BASE", "description": "Shunt conductance, per-unit on system base"},
    {"table": "fixed_admittance", "column": "y_g", "quantity_type": "Conductance", "unit": "S", "discriminator_column": "admittance_units", "discriminator_value": "NATURAL_UNITS", "description": "Shunt conductance in siemens"},
    {"table": "fixed_admittance", "column": "y_g", "quantity_type": "ActivePower", "unit": "MW", "discriminator_column": "admittance_units", "discriminator_value": "DEVICE_MVAR", "description": "Shunt conductance as MW at unity voltage (PSS/E GL)"},
    {"table": "fixed_admittance", "column": "y_b", "quantity_type": "Susceptance", "unit": "pu", "discriminator_column": "admittance_units", "discriminator_value": "SYSTEM_BASE", "description": "Shunt susceptance, per-unit on system base"},
    {"table": "fixed_admittance", "column": "y_b", "quantity_type": "Susceptance", "unit": "S", "discriminator_column": "admittance_units", "discriminator_value": "NATURAL_UNITS", "description": "Shunt susceptance in siemens"},
    {"table": "fixed_admittance", "column": "y_b", "quantity_type": "ReactivePower", "unit": "MVAr", "discriminator_column": "admittance_units", "discriminator_value": "DEVICE_MVAR", "description": "Shunt susceptance as Mvar at unity voltage (PSS/E BL)"},
```

- [ ] **Step 4: Register `fixed_admittance` as an entity type** if the schema requires it (mirror how `loads` is seeded — check `schema/schema.sql` for an `entity_types` INSERT or a trigger). If `loads` needs no seed row, skip. Add the analogous line for `fixed_admittance` if present.

- [ ] **Step 5: Add `fixed_admittance` to the completeness allow-list decision.** `y_g`/`y_b` are registered, so no allow-list entry is needed. Confirm no other REAL/JSON column on the table is unregistered (only `y_g`,`y_b` are REAL — both registered).

- [ ] **Step 6: Bump `PRAGMA user_version`** in `schema/schema.sql`: `2` → `3`.

- [ ] **Step 7: Regenerate + seal the registry**

Run: `python3 scripts/generate_unit_registry.py`
Expected: `Wrote .../schema/unit_registry.sql`

- [ ] **Step 8: Run the 4-gate test**

Run: `gridtest`
Expected: registry `MATCH`; sync check `0 FAIL`; pytest all pass (completeness test now sees `fixed_admittance.y_g/y_b` registered).

- [ ] **Step 9: Commit**

```bash
cd SiennaGridDB && git add schema/schema.sql schema/column_conventions.json schema/unit_registry.sql
git commit -m "griddb: fixed_admittance table with 3-way admittance_units basis"
```

### Task 2.2: Create the `switched_admittance` table

**Files:** same set as Task 2.1.
**Interfaces:** Consumes SiennaSchemas Task 1.6. Produces table `switched_admittance(id, name, bus, y_g, y_b, admittance_units, ...)` and the six `y_g`/`y_b` convention rows (identical `(quantity_type, unit, discriminator_value)` triples as Task 2.1, `table` = `switched_admittance`).

- [ ] **Step 1:** Add `DROP TABLE IF EXISTS switched_admittance;`.
- [ ] **Step 2:** Add table — same identity/bus/`admittance_units` columns and CHECK as Task 2.1 Step 2. Store the primary `Y` as `y_g`/`y_b`. (Represent `Y_increase`/`admittance_limits` as JSON columns `y_increase`/`admittance_limits` if included; if so, add them as `TEXT ... CHECK(json_valid(...))` and register each under `Susceptance` per basis — repeat the `y_b` rows for those column names. If deferring the step arrays, note it in the commit and register only `y_g`/`y_b`.)
- [ ] **Step 3:** Add the six `y_g`/`y_b` convention rows (copy Task 2.1 Step 3, replace `"table": "fixed_admittance"` → `"switched_admittance"`).
- [ ] **Step 4:** Entity-type seed if required (as Task 2.1 Step 4).
- [ ] **Step 5:** Regenerate registry: `python3 scripts/generate_unit_registry.py`.
- [ ] **Step 6:** Run `gridtest`. Expected: `MATCH`, `0 FAIL`, pytest pass.
- [ ] **Step 7:** Commit `-m "griddb: switched_admittance table with admittance_units basis"`.

### Task 2.3: Create the `sources` table (impedance template)

**Files:** same set.
**Interfaces:** Consumes SiennaSchemas Task 1.4. Produces `sources(id, name, bus, r_th, x_th, parameter_units, ...)` + four convention rows (`r_th`/`x_th` × `SYSTEM_BASE`/`NATURAL_UNITS`).

- [ ] **Step 1:** `DROP TABLE IF EXISTS sources;`.
- [ ] **Step 2:** Add table with identity/bus columns, `r_th REAL`, `x_th REAL`, and `parameter_units TEXT NOT NULL DEFAULT 'SYSTEM_BASE' CHECK (parameter_units IN ('SYSTEM_BASE','NATURAL_UNITS'))`.
- [ ] **Step 3:** Add convention rows:

```json
    {"table": "sources", "column": "r_th", "quantity_type": "Resistance", "unit": "pu", "discriminator_column": "parameter_units", "discriminator_value": "SYSTEM_BASE", "description": "Thevenin resistance, pu on system base"},
    {"table": "sources", "column": "r_th", "quantity_type": "Resistance", "unit": "ohm", "discriminator_column": "parameter_units", "discriminator_value": "NATURAL_UNITS", "description": "Thevenin resistance in ohm"},
    {"table": "sources", "column": "x_th", "quantity_type": "Reactance", "unit": "pu", "discriminator_column": "parameter_units", "discriminator_value": "SYSTEM_BASE", "description": "Thevenin reactance, pu on system base"},
    {"table": "sources", "column": "x_th", "quantity_type": "Reactance", "unit": "ohm", "discriminator_column": "parameter_units", "discriminator_value": "NATURAL_UNITS", "description": "Thevenin reactance in ohm"},
```

- [ ] **Step 4:** Entity-type seed if required.
- [ ] **Step 5:** Regenerate registry.
- [ ] **Step 6:** Run `gridtest`. Expected pass.
- [ ] **Step 7:** Commit `-m "griddb: sources table with parameter_units impedance basis"`.

### Task 2.4: Create the `two_terminal_lcc_lines` table

**Files:** same set.
**Interfaces:** Consumes SiennaSchemas Task 1.2. Produces table with the 8 impedance columns + `parameter_units` + 16 convention rows (8 fields × 2 bases).

- [ ] **Step 1:** `DROP TABLE IF EXISTS two_terminal_lcc_lines;`.
- [ ] **Step 2:** Add table: identity + `arc_id INTEGER NOT NULL REFERENCES arcs(id) ON DELETE CASCADE`, the 8 REAL impedance columns (`r`, `rectifier_rc`, `rectifier_xc`, `inverter_rc`, `inverter_xc`, `rectifier_capacitor_reactance`, `inverter_capacitor_reactance`, `compounding_resistance`), and `parameter_units TEXT NOT NULL DEFAULT 'NATURAL_UNITS' CHECK (parameter_units IN ('SYSTEM_BASE','NATURAL_UNITS'))`. (Non-unit columns of the full PSY component are out of scope for this task — add a `-- TODO(non-unit fields)` comment.)
- [ ] **Step 3:** Add 16 convention rows — for each field `F` in the 8, two rows using `quantity_type` `Resistance` for `r`/`*_rc`/`compounding_resistance` and `Reactance` for `*_xc`/`*_capacitor_reactance`, with `unit` `pu`@`SYSTEM_BASE` and `ohm`@`NATURAL_UNITS`. Pattern per field:

```json
    {"table": "two_terminal_lcc_lines", "column": "<F>", "quantity_type": "<Resistance|Reactance>", "unit": "pu", "discriminator_column": "parameter_units", "discriminator_value": "SYSTEM_BASE", "description": "<F>, pu on system base"},
    {"table": "two_terminal_lcc_lines", "column": "<F>", "quantity_type": "<Resistance|Reactance>", "unit": "ohm", "discriminator_column": "parameter_units", "discriminator_value": "NATURAL_UNITS", "description": "<F> in ohm (PSS/E native)"},
```
Quantity mapping: `r`,`rectifier_rc`,`inverter_rc`,`compounding_resistance` → `Resistance`; `rectifier_xc`,`inverter_xc`,`rectifier_capacitor_reactance`,`inverter_capacitor_reactance` → `Reactance`.

- [ ] **Step 4:** Entity-type seed if required.
- [ ] **Step 5:** Regenerate registry.
- [ ] **Step 6:** Run `gridtest`. Expected pass.
- [ ] **Step 7:** Commit `-m "griddb: two_terminal_lcc_lines with parameter_units impedance basis"`.

### Task 2.5: Create the `tmodel_hvdc_lines` table

**Files:** same set.
**Interfaces:** Consumes Task 1.3. Produces table with `r` + `parameter_units` + 2 rows.

- [ ] **Step 1:** `DROP TABLE IF EXISTS tmodel_hvdc_lines;`.
- [ ] **Step 2:** Add table: identity + `arc_id` FK + `r REAL NOT NULL` + `parameter_units` (2-value CHECK, default `NATURAL_UNITS`). `-- TODO(l, c and non-unit fields)`.
- [ ] **Step 3:** Add the two `r` rows (`Resistance` pu@SYSTEM_BASE, ohm@NATURAL_UNITS) — copy Task 2.3 `r_th` rows, rename table/column/desc.
- [ ] **Step 4–7:** Entity seed if required; regenerate; `gridtest`; commit `-m "griddb: tmodel_hvdc_lines with parameter_units basis for r"`.

### Task 2.6: Create the `two_terminal_vsc_lines` table (conductance `g`)

**Files:** same set.
**Interfaces:** Consumes Task 1.7. Produces table with `g` + `admittance_units` + 3 rows.

- [ ] **Step 1:** `DROP TABLE IF EXISTS two_terminal_vsc_lines;`.
- [ ] **Step 2:** Add table: identity + `arc_id` FK + `g REAL NOT NULL DEFAULT 0.0` + `admittance_units TEXT NOT NULL DEFAULT 'NATURAL_UNITS' CHECK (admittance_units IN ('SYSTEM_BASE','NATURAL_UNITS','DEVICE_MVAR'))`. `-- TODO(non-unit fields)`.
- [ ] **Step 3:** Add three `g` rows:

```json
    {"table": "two_terminal_vsc_lines", "column": "g", "quantity_type": "Conductance", "unit": "pu", "discriminator_column": "admittance_units", "discriminator_value": "SYSTEM_BASE", "description": "Converter conductance, pu on system base"},
    {"table": "two_terminal_vsc_lines", "column": "g", "quantity_type": "Conductance", "unit": "S", "discriminator_column": "admittance_units", "discriminator_value": "NATURAL_UNITS", "description": "Converter conductance in siemens"},
    {"table": "two_terminal_vsc_lines", "column": "g", "quantity_type": "ActivePower", "unit": "MW", "discriminator_column": "admittance_units", "discriminator_value": "DEVICE_MVAR", "description": "Converter conductance as MW at unity voltage"},
```

- [ ] **Step 4–7:** Entity seed if required; regenerate; `gridtest`; commit `-m "griddb: two_terminal_vsc_lines with admittance_units basis for g"`.

### Task 2.7: Create the `facts_control_devices` table (voltage-setpoint basis)

**Files:** same set.
**Interfaces:** Consumes Task 1.8 + Phase 0 `(Voltage, pu)`. Produces table with `voltage_setpoint` + `voltage_setpoint_units` + 2 rows.

- [ ] **Step 1:** `DROP TABLE IF EXISTS facts_control_devices;`.
- [ ] **Step 2:** Add table: identity + `bus INTEGER NOT NULL REFERENCES balancing_topologies(id) ON DELETE CASCADE` + `voltage_setpoint REAL NOT NULL` + `voltage_setpoint_units TEXT NOT NULL DEFAULT 'SYSTEM_BASE' CHECK (voltage_setpoint_units IN ('SYSTEM_BASE','NATURAL_UNITS'))`. `-- TODO(non-unit fields)`.
- [ ] **Step 3:** Add two rows:

```json
    {"table": "facts_control_devices", "column": "voltage_setpoint", "quantity_type": "Voltage", "unit": "pu", "discriminator_column": "voltage_setpoint_units", "discriminator_value": "SYSTEM_BASE", "description": "Sending-end voltage setpoint, pu on bus base (PSS/E VSET)"},
    {"table": "facts_control_devices", "column": "voltage_setpoint", "quantity_type": "Voltage", "unit": "kV", "discriminator_column": "voltage_setpoint_units", "discriminator_value": "NATURAL_UNITS", "description": "Sending-end voltage setpoint in kV"},
```

- [ ] **Step 4–7:** Entity seed if required; regenerate; `gridtest`; commit `-m "griddb: facts_control_devices with voltage_setpoint_units basis"`.

### Task 2.8: Add a regression test for discriminated basis round-trip

**Files:**
- Modify: `SiennaGridDB/test/test_unit_registry.py`

**Interfaces:** Consumes the seven new tables' registry rows.

- [ ] **Step 1: Write the failing test** — asserts every new discriminated column has exactly the expected basis rows in `unit_conventions`:

```python
def test_flexible_basis_columns_registered(db):
    expected = {
        ("fixed_admittance", "y_b"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("fixed_admittance", "y_g"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("sources", "r_th"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("sources", "x_th"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_lcc_lines", "r"): {"SYSTEM_BASE", "NATURAL_UNITS"},
        ("two_terminal_vsc_lines", "g"): {"SYSTEM_BASE", "NATURAL_UNITS", "DEVICE_MVAR"},
        ("facts_control_devices", "voltage_setpoint"): {"SYSTEM_BASE", "NATURAL_UNITS"},
    }
    for (table, col), bases in expected.items():
        rows = db.execute(
            "SELECT discriminator_value FROM unit_conventions "
            "WHERE table_name=? AND column_name=?", (table, col)
        ).fetchall()
        got = {r[0] for r in rows}
        assert got == bases, f"{table}.{col}: {got} != {bases}"
```

- [ ] **Step 2: Run to verify it passes** (rows exist from Tasks 2.1–2.7)

Run: `<PYTEST> test/test_unit_registry.py::test_flexible_basis_columns_registered -v`
Expected: PASS

- [ ] **Step 3: Full suite**

Run: `gridtest`
Expected: `MATCH`, `0 FAIL`, all pytest pass.

- [ ] **Step 4: Commit** `-m "griddb: regression test for flexible unit-basis columns"`.

---

## Self-Review

**Spec coverage:** Every Field-Inventory row has a SiennaSchemas task (1.2–1.8) and a GridDB task (2.1–2.7); vocabulary gap `(Voltage, pu)` → Task 0.1; regression → Task 2.8. Out-of-scope items (l/c, generic HVDC, VSC setpoints, converter) are explicitly noted, not silently dropped.

**Placeholder scan:** GridDB DDL for full non-unit columns is intentionally deferred with `-- TODO` markers and called out in each task's Step 2 — these tables are unit-focused slices by design (per the campaign theme), not hidden placeholders. Convention-row JSON and enum JSON are given verbatim.

**Type/key consistency:** Discriminator names are identical across layers — `parameter_units` (impedances: Tasks 1.2/1.3/1.4 ↔ 2.3/2.4/2.5), `admittance_units` (Tasks 1.5/1.6/1.7 ↔ 2.1/2.2/2.6), `voltage_setpoint_units` (1.8 ↔ 2.7). `x-units` map keys equal `discriminator_value`s (`SYSTEM_BASE/NATURAL_UNITS/DEVICE_MVAR`), satisfying `check_units_sync.py:257`. Every `(quantity_type, unit)` used is present in `units.json` after Task 0.1.

## Open risks for the executor

1. **Complex `Y` split** (`y_g`/`y_b`) diverges from the single OpenAPI `Y` field. The importer/converter must map `Y = y_g + j·y_b`. If the team prefers a single JSON `Y` column, collapse the six rows to three (register under `Susceptance` as representative) — but that loses the conductance quantity_type. Confirm with the schema owner before Task 2.1.
2. **Entity-type registration** (Task 2.x Step 4) depends on how `loads`/`transmission_lines` seed `entity_types` — inspect before assuming.
3. **DEVICE_MVAR semantics:** it is reactive power at unity voltage, dimensionally `ReactivePower`, not an admittance. The registry accepts it because it validates `(quantity_type, unit)` pairs independently per row; downstream unit-conversion code must special-case this basis (Q = |V|²·B).
