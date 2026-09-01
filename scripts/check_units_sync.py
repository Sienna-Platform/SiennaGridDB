#!/usr/bin/env python3
"""Cross-repo units consistency check: SiennaSchemas <-> GridDB registry <-> PowerSystems.jl descriptor.

Three layers:

  L1  schemas <-> registry  For every column_conventions row whose table is mapped in
      schema_map.json, resolve the column to the same-named property on each mapped schema
      component and compare unit + quantity. Contradiction (different unit for same mapped
      pair) => FAIL. Gap (unmapped column/property, missing annotation) => WARN.

  L2  registry <-> DB       Every non-attributes (table, column) row with no '.' must exist
      per pragma_table_info on a DB built in-memory from schema/*.sql. JSON-path rows
      (table, column with '.') check the base column exists. attributes rows are whitelisted.

  L3  schemas <-> PSY       (--psy-path; SKIPPED cleanly when absent). Per mapped is_psy
      component with a same-named PSY struct:
        (a) schema property with x-unit in {MW, MVAr, MVA} must map to a PSY field whose
            conversion_unit is ':mva', OR a documented natural-unit field (base_power, whose
            PSY comment says MVA; a device quantity "at unity voltage"; or any field on a
            component whose schema carries no power_units property at all, so it has no
            per-component power base by design). Contradiction => FAIL.
        (b) schema property whose $ref names a common.json definition that mirrors a PSY type
            (FunctionData / ValueCurve / MinMax classes) must match the PSY field's data_type
            string. Mismatch => FAIL.  (HydroReservoir.head_to_volume_factor is the regression
            fixture; see --self-test.)
        (c) PSY needs_conversion field whose mapped schema property lacks any x-unit/x-units
            => WARN list.

Stdlib only. Deterministic ordering. Exit non-zero on any FAIL, zero on warns-only.
"""

import argparse
import json
import os
import re
import sqlite3
import sys

from _common import load_json

POWER_UNITS = ("MW", "MVAr", "MVA")

# common.json definition names that mirror a PSY struct data_type; L3(b) compares these
# against the PSY field's data_type string.
PSY_MIRRORED_DEFS = frozenset({
    "FunctionData",
    "ValueCurve",
    "MinMax",
})


# --------------------------------------------------------------------------- loading


def build_units_vocabulary(units_json):
    """Return {(quantity_type, unit)} membership set."""
    allowed_pairs = set()
    for row in units_json.get("allowed_units", []):
        allowed_pairs.add((row["quantity_type"], row["unit"]))
    return allowed_pairs


def schema_property_annotation(prop):
    """Return dict with resolved annotation for a schema property node.

    Keys: has_annotation(bool), unit(str or None), units_map(dict or None),
    discriminator(str or None), ref(str or None), is_pu(bool).
    """
    unit = prop.get("x-unit")
    units_map = prop.get("x-units")
    disc = prop.get("x-unit-discriminator")
    ref = prop.get("$ref")
    is_pu = unit == "pu"
    has_annotation = (unit is not None) or (units_map is not None)
    return {
        "has_annotation": has_annotation,
        "unit": unit,
        "units_map": units_map,
        "discriminator": disc,
        "ref": ref,
        "is_pu": is_pu,
    }


def ref_definition_name(ref):
    """Extract the trailing definition name from a $ref like
    '../../Core/common.json#/definitions/FunctionData' -> 'FunctionData'."""
    if not ref:
        return None
    return ref.rsplit("/", 1)[-1]


# --------------------------------------------------------------------------- result plumbing


class Report:
    def __init__(self):
        self.fails = []   # list of (layer, message)
        self.warns = []   # list of (layer, message)

    def fail(self, layer, message):
        self.fails.append((layer, message))

    def warn(self, layer, message):
        self.warns.append((layer, message))


# --------------------------------------------------------------------------- L1


def resolve_schema_property(schemas_path, entry, prop_name, cache):
    """Return the property node dict for prop_name on the mapped component, or None."""
    file_rel = entry["file"]
    if file_rel not in cache:
        full = os.path.join(schemas_path, file_rel)
        cache[file_rel] = load_json(full)
    doc = cache[file_rel]
    return doc.get("properties", {}).get(prop_name)


def group_conventions(conventions):
    """Group column_conventions rows by (table, column). Returns ordered list of
    ((table, column), [rows])."""
    grouped = {}
    for row in conventions:
        key = (row["table"], row["column"])
        grouped.setdefault(key, []).append(row)
    return [(k, grouped[k]) for k in sorted(grouped)]


def layer1(report, conventions, schema_map, schemas_path, allowed_pairs, doc_cache):
    """schemas <-> registry."""
    tables = schema_map["tables"]
    checked_pairs = 0
    contradiction = 0
    gap = 0

    for (table, column), rows in group_conventions(conventions):
        if table == "attributes":
            continue  # attribute-name conventions, not schema properties
        if table not in tables:
            report.warn("L1", "unmapped table (no schema_map entry): %s.%s" % (table, column))
            gap += 1
            continue

        is_json_path = "." in column
        base_column = column.split(".", 1)[0] if is_json_path else column

        # discriminated rows carry discriminator_value; collect them into a map for L1 compare.
        discriminated = [r for r in rows if r.get("discriminator_value")]

        for entry in tables[table]:
            comp = entry["component"]
            prop = resolve_schema_property(schemas_path, entry, base_column, doc_cache)
            if prop is None:
                report.warn(
                    "L1",
                    "no schema property '%s' on %s (table %s) for column %s"
                    % (base_column, comp, table, column),
                )
                gap += 1
                continue

            ann = schema_property_annotation(prop)

            if is_json_path:
                # structurally-exempt: compare only against the base property presence,
                # skip sub-path unit comparison.
                report.warn(
                    "L1",
                    "structurally-exempt JSON-path row %s.%s: base property '%s' exists on "
                    "%s; sub-path unit not compared" % (table, column, base_column, comp),
                )
                gap += 1
                continue

            if discriminated:
                disc_warns = _l1_discriminated(report, table, column, comp, ann, discriminated,
                                               allowed_pairs)
                gap += disc_warns
                if disc_warns == 0:
                    checked_pairs += 1
                continue

            # non-discriminated single row — read registry values.
            row = rows[0]
            reg_qt = row["quantity_type"]
            reg_unit = row["unit"]

            if not ann["has_annotation"]:
                report.warn(
                    "L1",
                    "no unit annotation on %s.%s (registry says %s/%s)"
                    % (comp, base_column, reg_qt, reg_unit),
                )
                gap += 1
                continue

            checked_pairs += 1
            schema_unit = ann["unit"]
            if schema_unit != reg_unit:
                report.fail(
                    "L1",
                    "unit contradiction %s.%s: schema x-unit=%s vs registry unit=%s (%s/%s)"
                    % (comp, base_column, schema_unit, reg_unit, reg_qt, reg_unit),
                )
                contradiction += 1
                continue
            # unit matches; verify the (quantity, unit) pair is coherent in the vocabulary.
            if (reg_qt, schema_unit) not in allowed_pairs:
                report.fail(
                    "L1",
                    "quantity/unit not in vocabulary for %s.%s: registry (%s, %s) but schema "
                    "x-unit=%s has no matching allowed_units row" % (
                        comp, base_column, reg_qt, reg_unit, schema_unit),
                )
                contradiction += 1

    return {"checked": checked_pairs, "contradictions": contradiction, "gaps": gap}


def _expand_schema_units_map(units_map):
    """Expand a (possibly nested) schema x-units map into a flat
    {(primary_value, secondary_value): unit} map.

    A flat entry (`{"SYSTEM_BASE": "pu", ...}`) expands to (primary_value, None).
    A nested entry (a field whose unit depends on a SECOND discriminator, e.g.
    `dc_setpoint_from`'s `DC_VOLTAGE` value being `{"x-unit-discriminator":
    "voltage_units", "x-units": {"SYSTEM_BASE": "pu", "NATURAL_UNITS": "kV"}}`)
    expands to one (primary_value, secondary_value) entry per secondary key.
    Must not choke on a dict value -- that is the whole point of this helper.
    """
    expanded = {}
    for primary_value, value in units_map.items():
        if isinstance(value, dict):
            for secondary_value, unit in value.get("x-units", {}).items():
                if isinstance(unit, dict):
                    raise ValueError(
                        "x-units nesting deeper than two levels is not representable "
                        "in the registry (only discriminator_value_2 exists); found a "
                        "third level under %r/%r" % (primary_value, secondary_value)
                    )
                expanded[(primary_value, secondary_value)] = unit
        else:
            expanded[(primary_value, None)] = value
    return expanded


def _discriminator_key_label(key):
    primary, secondary = key
    if secondary is None:
        return primary
    return f"{primary}/{secondary}"


def _l1_discriminated(report, table, column, comp, ann, discriminated, allowed_pairs):
    """Compare a schema x-units discriminator map against the registry's discriminator rows.

    Registry rows are keyed on (discriminator_value, discriminator_value_2); rows with no
    second discriminator carry discriminator_value_2=None (the pre-nesting shape). Flat
    schema x-units values compare on the primary discriminator only (secondary=None); a
    nested schema x-units value (a field whose unit depends on a second discriminator)
    expands into (primary_value, secondary_value) pairs via _expand_schema_units_map and
    compares against the matching registry rows.

    Returns the number of WARNs emitted (0 if none).
    """
    units_map = ann["units_map"]
    reg_map = {
        (r["discriminator_value"], r.get("discriminator_value_2")): (r["quantity_type"], r["unit"])
        for r in discriminated
    }

    if units_map is None:
        # The schema annotates a single representation (e.g. x-unit=pu for branch
        # r/x/b/g, the PSY-native basis) while the registry additionally offers
        # other units via the discriminator (SYSTEM_BASE->pu, NATURAL_UNITS->ohm/S).
        # Positive match when the schema's single x-unit appears among the
        # registered discriminated units for this column.
        schema_unit = ann["unit"]
        if schema_unit is None:
            report.warn(
                "L1",
                "discriminated registry rows for %s.%s (%s) but schema property on %s has "
                "neither x-units map nor x-unit" % (table, column, sorted(reg_map), comp),
            )
            return 1
        reg_units = {u for (_qt, u) in reg_map.values()}
        if schema_unit not in reg_units:
            report.fail(
                "L1",
                "discriminated single-unit contradiction %s.%s on %s: schema x-unit=%s not "
                "among registered discriminated units %s"
                % (table, column, comp, schema_unit, sorted(reg_units)),
            )
        return 0

    schema_map = _expand_schema_units_map(units_map)
    schema_keys = set(schema_map.keys())
    reg_keys = set(reg_map.keys())
    if schema_keys != reg_keys:
        report.fail(
            "L1",
            "discriminator key mismatch %s.%s on %s: schema x-units keys %s vs registry %s"
            % (table, column, comp,
               sorted((_discriminator_key_label(k) for k in schema_keys)),
               sorted((_discriminator_key_label(k) for k in reg_keys))),
        )
        return 0

    for key in sorted(schema_keys, key=lambda k: (k[0], k[1] or "")):
        schema_unit = schema_map[key]
        reg_qt, reg_unit = reg_map[key]
        label = _discriminator_key_label(key)
        if schema_unit != reg_unit:
            report.fail(
                "L1",
                "discriminated unit contradiction %s.%s[%s] on %s: schema=%s vs registry=%s"
                " (%s)" % (table, column, label, comp, schema_unit, reg_unit, reg_qt),
            )
        elif (reg_qt, schema_unit) not in allowed_pairs:
            report.fail(
                "L1",
                "discriminated quantity/unit not in vocabulary %s.%s[%s] on %s: (%s, %s)"
                % (table, column, label, comp, reg_qt, schema_unit),
            )
    return 0


# --------------------------------------------------------------------------- L2


ATTRIBUTES_WHITELIST_TABLE = "attributes"


def build_db(schema_dir):
    """Build an in-memory DB from the four schema/*.sql files. Returns connection."""
    con = sqlite3.connect(":memory:")
    for fname in ("schema.sql", "triggers.sql", "unit_registry.sql", "views.sql"):
        path = os.path.join(schema_dir, fname)
        with open(path, "r") as fh:
            con.executescript(fh.read())
    return con


def layer2(report, conventions, con):
    """registry <-> DB existence check."""
    table_columns = {}
    checked = 0
    missing = 0
    for (table, column), _rows in group_conventions(conventions):
        if table == ATTRIBUTES_WHITELIST_TABLE:
            continue  # whitelisted attribute-name conventions
        if table not in table_columns:
            # table_xinfo, not table_info: table_info hides GENERATED columns
            # (e.g. thermal_generators.production_cost), which would otherwise
            # false-fail as "registry column not in DB".
            cols = {r[1] for r in con.execute("PRAGMA table_xinfo(%s)" % table)}
            table_columns[table] = cols
        cols = table_columns[table]
        if not cols:
            report.fail("L2", "registry table does not exist in DB: %s (col %s)" % (table, column))
            missing += 1
            continue
        base_column = column.split(".", 1)[0] if "." in column else column
        checked += 1
        if base_column not in cols:
            report.fail(
                "L2",
                "registry column not in DB: %s.%s (base %s)" % (table, column, base_column),
            )
            missing += 1
    return {"checked": checked, "missing": missing}


# --------------------------------------------------------------------------- L3


def load_psy_structs(psy_path):
    """Return {struct_name: {field_name: field_dict}}."""
    descriptor = os.path.join(psy_path, "src", "descriptors", "power_system_structs.json")
    doc = load_json(descriptor)
    out = {}
    for struct in doc["auto_generated_structs"]:
        out[struct["struct_name"]] = {f["name"]: f for f in struct["fields"]}
    return out


def psy_field_is_mva_convertible(field):
    return field.get("needs_conversion") and field.get("conversion_unit") == ":mva"


def psy_field_is_documented_natural(name, field, component_props):
    """A power-valued PSY field the schema legitimately rides as fixed natural units.

    Three documented cases:
    - base_power (and the pairwise base_power_12/23/31 on ThreeWindingTransformer):
      a device MVA base itself. Exact names, not a prefix — a new base_power_*
      field must be reviewed and added here, not silently exempted.
    - a device quantity entered "at unity voltage" (e.g. FACTS max_shunt_current, a
      current expressed as MVA at unity voltage): a device basis, not a system-base
      power, so PSY deliberately stores it unconverted. The idiom is specific — only
      max_shunt_current uses it today — so it exempts exactly that pattern.
    - a component whose schema carries no `power_units` property at all: by design it
      has no per-component power base, so every power-family field on it rides the
      wire in fixed natural units regardless of what PSY's descriptor says internally
      (TModelHVDCLine is the instance — see its schema description). Mechanically
      derived from the schema data already loaded, not a hardcoded type-name list.
    """
    comment = field.get("comment") or ""
    if name in ("base_power", "base_power_12", "base_power_23", "base_power_31"):
        return "MVA" in comment
    if "at unity voltage" in comment.lower() and not field.get("needs_conversion"):
        return True
    return "power_units" not in component_props


def layer3(report, schema_map, schemas_path, psy_structs, doc_cache):
    """schemas <-> PSY descriptor."""
    tables = schema_map["tables"]
    checked_a = 0
    checked_b = 0
    fail_count = 0
    warn_c = 0

    # iterate deterministically over components
    seen_components = []
    for table in sorted(tables):
        for entry in tables[table]:
            if not entry.get("is_psy"):
                continue
            comp = entry["component"]
            if comp in psy_structs:
                seen_components.append((comp, entry))

    for comp, entry in sorted(seen_components):
        fields = psy_structs[comp]
        file_rel = entry["file"]
        if file_rel not in doc_cache:
            doc_cache[file_rel] = load_json(os.path.join(schemas_path, file_rel))
        props = doc_cache[file_rel].get("properties", {})

        # (a) + (b): schema-property driven
        for prop_name in sorted(props):
            prop = props[prop_name]
            ann = schema_property_annotation(prop)
            field = fields.get(prop_name)

            # (a) power-unit annotation must map to an mva-convertible / documented natural field
            if ann["unit"] in POWER_UNITS:
                if field is None:
                    report.warn(
                        "L3",
                        "(a) %s.%s has power x-unit=%s but no same-named PSY field"
                        % (comp, prop_name, ann["unit"]),
                    )
                    continue
                if not (psy_field_is_mva_convertible(field)
                        or psy_field_is_documented_natural(prop_name, field, props)):
                    report.fail(
                        "L3",
                        "(a) power-unit contradiction %s.%s: schema x-unit=%s but PSY field "
                        "conversion_unit=%s needs_conversion=%s comment-natural=%s"
                        % (comp, prop_name, ann["unit"], field.get("conversion_unit"),
                           field.get("needs_conversion"),
                           psy_field_is_documented_natural(prop_name, field, props)),
                    )
                    fail_count += 1
                else:
                    checked_a += 1

            # (b) $ref to a common.json def mirroring a PSY type must match PSY data_type
            def_name = ref_definition_name(ann["ref"])
            if def_name in PSY_MIRRORED_DEFS:
                if field is None:
                    report.warn(
                        "L3",
                        "(b) %s.%s $ref %s but no same-named PSY field"
                        % (comp, prop_name, def_name),
                    )
                    continue
                psy_dtype = field.get("data_type") or ""
                if not psy_type_matches(def_name, psy_dtype):
                    report.fail(
                        "L3",
                        "(b) $ref/type contradiction %s.%s: schema $ref=%s vs PSY data_type=%s"
                        % (comp, prop_name, def_name, psy_dtype),
                    )
                    fail_count += 1
                else:
                    checked_b += 1

        # (c) PSY needs_conversion field whose mapped schema property lacks any annotation
        for fname in sorted(fields):
            field = fields[fname]
            if not field.get("needs_conversion"):
                continue
            prop = props.get(fname)
            if prop is None:
                continue  # not a mapped schema property; not our concern here
            ann = schema_property_annotation(prop)
            if not ann["has_annotation"]:
                report.warn(
                    "L3",
                    "(c) %s.%s: PSY needs_conversion (%s) but schema property lacks x-unit/x-units"
                    % (comp, fname, field.get("conversion_unit")),
                )
                warn_c += 1

    return {"checked_a": checked_a, "checked_b": checked_b, "fails": fail_count,
            "warn_c": warn_c, "components": len(seen_components)}


def psy_type_matches(def_name, psy_dtype):
    """A common.json definition name matches a PSY data_type string.

    PSY data_type may be wrapped (e.g. 'Union{Nothing, MinMax}'); match by word boundary.
    FunctionData/ValueCurve/MinMax are the mirrored classes. A ValueCurve $ref against a
    FunctionData PSY field (the historical drift) must NOT match.
    """
    return bool(re.search(r"\b" + re.escape(def_name) + r"\b", psy_dtype))


# --------------------------------------------------------------------------- self-test


def run_self_test(schema_map, schemas_path, psy_structs):
    """Regression fixture: HydroReservoir.head_to_volume_factor.

    Inject a stale ValueCurve $ref in memory (the historical drift) and assert L3(b) flags it
    as a FAIL. The live schema currently $refs FunctionData (matching PSY), so we mutate a
    copy in memory to simulate the pre-fix state.
    """
    print("=== SELF-TEST: regression fixture (HydroReservoir.head_to_volume_factor) ===")
    comp = "HydroReservoir"
    if comp not in psy_structs:
        print("  FAIL: HydroReservoir not found in PSY descriptor; cannot run self-test")
        return False
    field = psy_structs[comp].get("head_to_volume_factor")
    if field is None:
        print("  FAIL: head_to_volume_factor not a PSY field")
        return False
    psy_dtype = field.get("data_type") or ""
    print("  PSY field head_to_volume_factor data_type = %s" % psy_dtype)

    # stale state: schema $ref names ValueCurve
    stale_ref_def = "ValueCurve"
    detected = not psy_type_matches(stale_ref_def, psy_dtype)
    if detected:
        print("  PASS: stale $ref=ValueCurve vs PSY data_type=%s is detected as a mismatch (FAIL)"
              % psy_dtype)
    else:
        print("  FAIL: stale $ref=ValueCurve was NOT detected as a mismatch")

    # sanity: the current (fixed) state must NOT flag
    current_ref_def = "FunctionData"
    ok_current = psy_type_matches(current_ref_def, psy_dtype)
    if ok_current:
        print("  PASS: current $ref=FunctionData matches PSY data_type=%s (no false positive)"
              % psy_dtype)
    else:
        print("  FAIL: current $ref=FunctionData unexpectedly flagged against %s" % psy_dtype)

    passed = detected and ok_current
    print("  SELF-TEST %s" % ("PASSED" if passed else "FAILED"))
    return passed


# --------------------------------------------------------------------------- validation


def verify_map_files(schema_map, schemas_path):
    """Every mapped file must exist; error out loudly otherwise."""
    missing = []
    for table in sorted(schema_map["tables"]):
        for entry in schema_map["tables"][table]:
            full = os.path.join(schemas_path, entry["file"])
            if not os.path.isfile(full):
                missing.append(entry["file"])
    return missing


# --------------------------------------------------------------------------- main


def print_section(title, lines):
    print("=" * 78)
    print(title)
    print("=" * 78)
    for line in lines:
        print(line)
    print("")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--schemas-path", default="../SiennaSchemas",
                        help="Path to the SiennaSchemas checkout (default ../SiennaSchemas)")
    parser.add_argument("--psy-path", default=None,
                        help="Path to the PowerSystems.jl checkout (optional; L3 skipped if absent)")
    parser.add_argument("--db", default=None,
                        help="Path to a prebuilt sqlite DB for L2 (default: build in-memory "
                             "from schema/*.sql)")
    parser.add_argument("--self-test", action="store_true",
                        help="Run the regression-fixture self-test and exit")
    parser.add_argument("--conventions", default=None,
                        help="Override path to column_conventions.json "
                             "(default: schema/column_conventions.json in repo root)")
    args = parser.parse_args(argv)

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    schema_dir = os.path.join(repo_root, "schema")
    schemas_path = os.path.abspath(args.schemas_path)

    schema_map = load_json(os.path.join(schema_dir, "schema_map.json"))
    units_json = load_json(os.path.join(schemas_path, "Core", "units.json"))
    conventions_path = (os.path.abspath(args.conventions) if args.conventions
                        else os.path.join(schema_dir, "column_conventions.json"))
    conventions = load_json(conventions_path)["conventions"]
    allowed_pairs = build_units_vocabulary(units_json)

    # verify mapped files
    missing_files = verify_map_files(schema_map, schemas_path)
    if missing_files:
        print("ERROR: schema_map.json references non-existent files:")
        for f in missing_files:
            print("  " + f)
        return 2

    # self-test mode
    if args.self_test:
        if args.psy_path is None:
            print("ERROR: --self-test requires --psy-path")
            return 2
        psy_structs = load_psy_structs(os.path.abspath(args.psy_path))
        ok = run_self_test(schema_map, schemas_path, psy_structs)
        return 0 if ok else 1

    report = Report()
    doc_cache = {}

    # L1
    l1_stats = layer1(report, conventions, schema_map, schemas_path, allowed_pairs,
                      doc_cache)

    # L2
    if args.db:
        con = sqlite3.connect(args.db)
    else:
        con = build_db(schema_dir)
    l2_stats = layer2(report, conventions, con)
    con.close()

    # L3
    if args.psy_path:
        psy_structs = load_psy_structs(os.path.abspath(args.psy_path))
        l3_stats = layer3(report, schema_map, schemas_path, psy_structs, doc_cache)
    else:
        l3_stats = None

    # ------- output, per layer -------
    for layer, label, stats in (
        ("L1", "L1  SCHEMAS <-> REGISTRY", l1_stats),
        ("L2", "L2  REGISTRY <-> DB", l2_stats),
    ):
        fails = sorted(m for (lyr, m) in report.fails if lyr == layer)
        warns = sorted(m for (lyr, m) in report.warns if lyr == layer)
        lines = []
        lines.append("stats: %s" % json.dumps(stats, sort_keys=True))
        lines.append("FAILs: %d" % len(fails))
        for m in fails:
            lines.append("  FAIL " + m)
        lines.append("WARNs: %d" % len(warns))
        for m in warns:
            lines.append("  WARN " + m)
        print_section(label, lines)

    # L3 section
    if l3_stats is None:
        print_section("L3  SCHEMAS <-> PSY", ["SKIPPED (no --psy-path)"])
    else:
        fails = sorted(m for (lyr, m) in report.fails if lyr == "L3")
        warns = sorted(m for (lyr, m) in report.warns if lyr == "L3")
        lines = []
        lines.append("stats: %s" % json.dumps(l3_stats, sort_keys=True))
        lines.append("FAILs: %d" % len(fails))
        for m in fails:
            lines.append("  FAIL " + m)
        lines.append("WARNs: %d" % len(warns))
        for m in warns:
            lines.append("  WARN " + m)
        print_section("L3  SCHEMAS <-> PSY", lines)

    total_fails = len(report.fails)
    total_warns = len(report.warns)
    print("=" * 78)
    print("SUMMARY: %d FAIL(s), %d WARN(s)" % (total_fails, total_warns))
    print("=" * 78)

    return 1 if total_fails else 0


if __name__ == "__main__":
    sys.exit(main())
