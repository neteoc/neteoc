#!/usr/bin/env python3
"""Mutation check for the feature edit protections (issue #14).

Each mutation breaks one protection in a copy of the migration, builds a scratch
database from the mutated copy, and runs the suite. A protection is proven
non-vacuous only if the suite FAILS, and fails for the stated reason. The control
run builds the unmutated migration and must pass. A mutation whose edit changes
nothing is an error, so a stale anchor cannot make a mutation pass by doing nothing.

Not part of CI: it builds a database per mutation. Run it after changing the
migration or the tests:

    PGHOST=127.0.0.1 PGPORT=54322 PGUSER=postgres PGPASSWORD=postgres \
      python3 -I tests/sql/feature_edits_mutations.py [name ...]

The scratch database is created from template0 and dropped afterwards, and it
needs the roles anon and authenticated, as CI and the Supabase stack have.
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
TARGET = "20261020193000_transactional_feature_edits.sql"
DB = "neteoc_mutation"
ROLE = "m.role in ('admin', 'editor')"
VIEWER = "m.role in ('admin', 'editor', 'viewer')"


def role_edit(occurrence):
    return (ROLE, VIEWER, occurrence)


# (name, edits, runner, text the failure must contain)
# An edit is (old, new, occurrence); occurrence None means the text must be unique.
# Edits apply in order and each one removes a match, so a second edit of the same
# anchor uses the same index. The role anchors, in file order, are: 0 the tombstone
# check, 1 the create probe, 2 the create insert, 3 the update pre-check, 4 the
# update compare-and-set, 5 the update classification, 6 the delete compare-and-set,
# 7 the delete classification.
MUTATIONS = [
    ("update-skips-revision-predicate",
     [("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", "    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None)],
     "sql", "a replayed update was accepted"),
    ("update-reads-then-writes",
     # A check-then-act version: the revision is compared in a separate statement
     # before the UPDATE, and the UPDATE no longer carries it. Sequential tests pass.
     [("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", "    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None),
      ("  if p_changes = '{}'::jsonb then", "  select f.revision into v_current from public.features as f where f.id = p_feature_id;\n  if v_current is distinct from p_expected_revision then\n    raise exception 'feature revision conflict'\n      using errcode = 'PT409', detail = format('current revision %s', v_current);\n  end if;\n  if p_changes = '{}'::jsonb then", None)],
     "race", "update/update"),
    ("delete-skips-revision-predicate",
     [("  where f.id = p_feature_id\n    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision", "  where f.id = p_feature_id\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision", None)],
     "sql", "delete"),
    ("update-pre-check-removed",
     [("  if not exists (\n    select 1\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n", "", None)],
     "sql", "cross-tenant update, invalid payload"),
    ("create-probe-removed",
     [("  if not exists (\n    select 1\n    from public.layers as l\n    where l.id = p_layer_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = l.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    raise insufficient_privilege using message = 'layer not found or not editable';\n  end if;\n\n  v_geom", "  v_geom", None)],
     "sql", "cross-tenant create with invalid payload"),
    ("viewer-may-create", [role_edit(1), role_edit(1)], "sql", "viewer create"),
    ("viewer-may-update", [role_edit(3), role_edit(3)], "sql", "update by viewer_a"),
    ("viewer-may-delete", [role_edit(6)], "sql", "delete by viewer_a"),
    ("tombstone-visible-to-any-member",
     [("      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = a.organization_id\n          and m.user_id = p_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    raise exception 'feature was deleted'", "  ) then\n    raise exception 'feature was deleted'", None)],
     "sql", "viewer updates a deleted feature"),
    ("conflict-revealed-to-other-organizations",
     [("    select f.revision into v_current\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      );\n    if found then\n      raise exception 'feature revision conflict'\n        using errcode = 'PT409', detail = format('current revision %s', v_current);\n    end if;\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n  return app_private.feature_json(v_row);", "    select f.revision into v_current\n    from public.features as f\n    where f.id = p_feature_id;\n    if found then\n      raise exception 'feature revision conflict'\n        using errcode = 'PT409', detail = format('current revision %s', v_current);\n    end if;\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n  return app_private.feature_json(v_row);", None),
      ("  if not exists (\n    select 1\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n", "", None)],
     "sql", "update by"),
    ("audit-trigger-dropped",
     [("create trigger features_audit_deletion\n  after delete on public.features\n  for each row execute function app_private.record_feature_deletion();\n", "", None)],
     "sql", "features lacks the deletion audit trigger"),
    ("audit-immutability-dropped",
     [("create trigger feature_audit_events_immutable\n  before update or delete on app_private.feature_audit_events\n  for each row execute function app_private.reject_feature_audit_change();\n", "", None)],
     "sql", "the audit table lacks its append-only triggers"),
    ("audit-truncate-allowed",
     [("create trigger feature_audit_events_no_truncate\n  before truncate on app_private.feature_audit_events\n  for each statement execute function app_private.reject_feature_audit_change();\n", "", None)],
     "sql", "the audit table lacks its append-only triggers"),
    ("audit-summary-carries-title",
     [("format('deleted %s feature at revision %s', extensions.geometrytype(old.geom), old.revision)", "format('deleted %s feature at revision %s', old.title, old.revision)", None)],
     "sql", "audit summary leaks content"),
    ("audit-without-actor-allowed",
     [("  if v_actor is null then\n    raise insufficient_privilege using message = 'feature deletion requires an authenticated actor';\n  end if;\n  insert", "  insert", None)],
     "sql", "owner delete without an actor"),
    ("direct-writes-restored",
     [("revoke insert, update, delete on table public.features from authenticated;\n", "", None)],
     "sql", "authenticated holds a table-level write privilege on features"),
    ("anon-may-execute",
     [("revoke all on function public.create_feature(uuid, jsonb, text, text, text, jsonb),\n  public.update_feature(uuid, integer, jsonb),\n  public.delete_feature(uuid, integer)\n  from public, anon;", "revoke all on function public.create_feature(uuid, jsonb, text, text, text, jsonb),\n  public.update_feature(uuid, integer, jsonb),\n  public.delete_feature(uuid, integer)\n  from public;", None)],
     "sql", "anon can execute"),
    ("rpc-search-path-unpinned",
     [("returns jsonb\nlanguage plpgsql\nvolatile\nsecurity definer\nset search_path = ''\nas $$\ndeclare\n  v_user_id uuid := auth.uid();\n  v_geom public.wgs84_geometry;", "returns jsonb\nlanguage plpgsql\nvolatile\nsecurity definer\nas $$\ndeclare\n  v_user_id uuid := auth.uid();\n  v_geom public.wgs84_geometry;", None)],
     "sql", "must be security definer with search_path pinned"),
    ("numbers-not-checked",
     [("      if ((v_number::double precision)::text)::numeric is distinct from v_number then\n        return false;\n      end if;", "      null;", None)],
     "sql", "attribute beyond double range"),
    ("float-setting-not-pinned",
     [("set search_path = ''\nset extra_float_digits = 1\nas $$", "set search_path = ''\nas $$", None)],
     "sql", "the number check must pin extra_float_digits"),
    ("geometry-byte-ceiling-removed",
     [("  if octet_length(p_geometry::text) > 131072 then", "  if false then", None)],
     "sql", "geometry over the byte ceiling"),
    ("vertex-limit-removed",
     [("  if extensions.st_npoints(v_geom) > 2000 then", "  if false then", None)],
     "sql", "features_geom_npoints_limit"),
    ("coordinate-range-removed",
     [("  if jsonb_path_exists(v_coordinates, (format('strict %s[0] ? (@ < -180 || @ > 180)', v_prefix))::jsonpath)\n    or jsonb_path_exists(v_coordinates, (format('strict %s[1] ? (@ < -90 || @ > 90)', v_prefix))::jsonpath) then", "  if false then", None),
      ("  if extensions.st_xmin(v_geom) < -180 or extensions.st_xmax(v_geom) > 180\n    or extensions.st_ymin(v_geom) < -90 or extensions.st_ymax(v_geom) > 90 then", "  if false then", None)],
     "sql", "features_geom_lon_lat_range"),
    ("validity-check-removed",
     [("  if not extensions.st_isvalid(v_geom) then", "  if false then", None)],
     "sql", "features_geom_valid"),
    ("shape-check-removed",
     [("    or (select array_agg(k order by k) from jsonb_object_keys(p_geometry) as k)\n      is distinct from array['coordinates', 'type']\n", "\n", None)],
     "sql", "geometry: missing type"),
    ("expected-revision-not-validated",
     [("  if p_expected_revision is null or p_expected_revision < 1 then\n    raise exception 'expected revision must be a positive whole number' using errcode = 'invalid_parameter_value';\n  end if;\n  -- Argument shape", "  -- Argument shape", None)],
     "sql", "expected revision null"),
    ("update-patch-size-removed",
     [("  if octet_length(p_changes::text) > 147456 then", "  if false then", None)],
     "sql", "patch one byte over the ceiling"),
    ("unknown-update-field-allowed",
     [("    where k not in ('geometry', 'title', 'description', 'status', 'attributes')", "    where false", None)],
     "sql", "unknown field"),
    ("create-title-check-removed",
     [("  perform app_private.check_feature_title(p_title);\n  perform app_private.check_feature_description(p_description);\n  perform app_private.check_feature_status(p_status);\n  perform app_private.validate_feature_attributes(p_attributes);\n\n  begin", "  begin", None)],
     "sql", "title null: expected"),
]


def psql(args, db, **kw):
    env = dict(os.environ, PGDATABASE=db)
    return subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"] + args,
                          env=env, capture_output=True, text=True, **kw)


def build(mutated_text):
    psql(["-c", f"drop database if exists {DB}", "-c", f"create database {DB} template template0"], "postgres")
    # The roles may already exist in a shared cluster, which makes the first two
    # statements fail. The remaining statements must still run, so this call does
    # not stop on error. A missing auth schema fails the first migration instead.
    subprocess.run(["psql", "-X", "-q", "-f", str(ROOT / "tests/sql/ci-bootstrap.sql")],
                   env=dict(os.environ, PGDATABASE=DB), capture_output=True, text=True)
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = mutated_text if path.name == TARGET else path.read_text()
        result = psql(["-c", text], DB)
        if result.returncode != 0:
            raise SystemExit(f"migration {path.name} failed to build: {result.stderr.strip()}")


def apply_edits(original, edits):
    text = original
    for old, new, occurrence in edits:
        count = text.count(old)
        if occurrence is None:
            if count != 1:
                raise SystemExit(f"mutation anchor matched {count} times, expected 1: {old[:70]!r}")
            text = text.replace(old, new, 1)
        else:
            if count <= occurrence:
                raise SystemExit(f"mutation anchor has {count} matches, wanted index {occurrence}: {old[:70]!r}")
            parts = text.split(old)
            text = old.join(parts[:occurrence + 1]) + new + old.join(parts[occurrence + 1:])
    if text == original:
        raise SystemExit("mutation changed nothing")
    return text


def run_suite(kind):
    if kind == "sql":
        result = psql(["-v", "VERBOSITY=verbose", "-f", str(ROOT / "tests/sql/feature_edits.sql")], DB)
    else:
        env = dict(os.environ, PGDATABASE=DB)
        result = subprocess.run(["bash", str(ROOT / "tests/sql/feature_edits_race.sh")],
                                env=env, capture_output=True, text=True)
    return result.returncode, (result.stderr + result.stdout)


def first_error(output):
    for line in output.splitlines():
        if "ERROR" in line or "feature race test" in line:
            return line.strip()[:240]
    return output.strip()[:240]


def main():
    wanted = set(sys.argv[1:])
    original = (MIGRATIONS / TARGET).read_text()
    failures = []

    build(original)
    for kind in ("sql", "race"):
        code, out = run_suite(kind)
        if code != 0:
            raise SystemExit(f"control run ({kind}) failed on the unmutated migration:\n{out}")
    print("control      ok    unmutated migration passes the SQL suite and the race script")

    for name, edits, kind, expect in MUTATIONS:
        if wanted and name not in wanted:
            continue
        build(apply_edits(original, edits))
        code, out = run_suite(kind)
        if code == 0:
            failures.append(f"{name}: SURVIVED ({kind} suite passed with the protection removed)")
            print(f"SURVIVED     {name}")
        elif expect not in out:
            failures.append(f"{name}: failed for another reason, expected {expect!r}: {first_error(out)}")
            print(f"WRONG REASON {name}\n             {first_error(out)}")
        else:
            print(f"killed       {name}\n             {first_error(out)}")
    psql(["-c", f"drop database if exists {DB}"], "postgres")
    if failures:
        print("\n" + "\n".join(failures))
        raise SystemExit(1)


main()
