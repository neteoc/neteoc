#!/usr/bin/env python3
"""Mutation check for the feature edit protections (issue #14).

Each mutation breaks one protection in a copy of a migration, builds a scratch
database from the copies, and runs the suite that covers that protection. A
protection is proven non-vacuous only if its suite FAILS, and fails with the
mutation's intended label. The control run builds the unmutated migrations and
must pass every suite. A mutation whose anchor text is missing or ambiguous stops
the run, so a stale anchor cannot count as a kill.

Expected strings are exact assertion labels or messages from the suites. A
generic string would match many failures, so it cannot show the mutant died for
its own reason.

Not part of CI: it builds a database for every mutation (about a minute). Run it
after changing a migration or a suite:

    PGHOST=127.0.0.1 PGPORT=54322 PGUSER=postgres PGPASSWORD=postgres \\
      python3 -I tests/sql/feature_edits_mutations.py [name ...]

Scratch database: neteoc_test_mutation, created from template0 and dropped at the
end. The race script runs only under NETEOC_DISPOSABLE_DATABASE=1 and a name the
guard accepts, so the harness sets both. The build loads ci-bootstrap.sql, which
creates the roles anon and authenticated cluster-wide when they are missing. CI
and Supabase already have them, so this is harmless there.
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
FEATURES = "20261020193000_transactional_feature_edits.sql"
STORAGE = "20261020171500_feature_storage.sql"
DB = "neteoc_test_mutation"
TRUNCATE_MESSAGE = "feature rows cannot be truncated; delete each feature so the deletion is audited"

# An edit is (old, new, occurrence). occurrence None requires old to occur once.
MUTATIONS = [
    # Revision discipline.
    ("update-skips-revision-predicate", FEATURES, "sql", "public.update_feature does not check the revision inside its write statement", [
        ("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.",
         "    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None)]),
    # The predicate text stays inside the write statement, but as a comment, so the
    # structural check passes. The behavioural assertions must catch the lost predicate.
    ("update-predicate-commented-out", FEATURES, "sql", "a replayed update was accepted", [
        ("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.",
         "    -- and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None)]),
    ("delete-predicate-commented-out", FEATURES, "sql", "delete with a stale revision", [
        ("  where f.id = p_feature_id\n    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision",
         "  where f.id = p_feature_id\n    -- and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision", None)]),
    ("update-reads-then-writes", FEATURES, "race", "update/update: the second editor overwrote", [
        ("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.",
         "    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None),
        ("  if p_changes = '{}'::jsonb then", "  select f.revision into v_current from public.features as f where f.id = p_feature_id;\n  if v_current is distinct from p_expected_revision then\n    raise exception 'feature revision conflict'\n      using errcode = 'PT409', detail = format('current revision %s', v_current);\n  end if;\n  if p_changes = '{}'::jsonb then", None)]),
    ("delete-skips-revision-predicate", FEATURES, "sql", "public.delete_feature does not check the revision inside its write statement", [
        ("  where f.id = p_feature_id\n    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision",
         "  where f.id = p_feature_id\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision", None)]),
    ("expected-revision-not-validated", FEATURES, "sql", "expected revision null", [
        ("  if p_expected_revision is null or p_expected_revision < 1 then\n    raise exception 'expected revision must be a positive whole number' using errcode = 'invalid_parameter_value';\n  end if;\n  -- Argument shape",
         "  -- Argument shape", None)]),
    # Authorization.
    ("create-probe-removed", FEATURES, "sql", "cross-tenant create with invalid payload", [
        ("  if not exists (\n    select 1\n    from public.layers as l\n    where l.id = p_layer_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = l.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    raise insufficient_privilege using message = 'layer not found or not editable';\n  end if;\n\n  v_geom",
         "  v_geom", None)]),
    ("update-pre-check-removed", FEATURES, "sql", "cross-tenant update, invalid payload", [
        ("  if not exists (\n    select 1\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n", "", None)]),
    # create_feature checks membership twice: before the payload is read, and again in
    # the insert. Widening one leaves the other as a barrier, so both are widened.
    ("viewer-may-create", FEATURES, "sql", "viewer create:", [
        (lambda t: t[t.index("create function public.create_feature("):t.index("-- ---------------------------------------------------------------------------\n-- update_feature")],
         lambda old: old.replace("m.role in ('admin', 'editor')", "m.role in ('admin', 'editor', 'viewer')"), None)]),
    ("viewer-may-update", FEATURES, "sql", "update by viewer_a on feat_point answered", [
        ("      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n\n  if p_changes = '{}'::jsonb then",
         "      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor', 'viewer')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n\n  if p_changes = '{}'::jsonb then", None),
        ("  update public.features as f\n  set geom = case when v_set_geom then v_geom else f.geom end,", "  update public.features as f\n  set geom = case when v_set_geom then v_geom else f.geom end,", None),
        ("    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.",
         "    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor', 'viewer')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    -- Nothing matched.", None)]),
    ("viewer-may-delete", FEATURES, "sql", "delete by viewer_a on feat_point answered", [
        ("  where f.id = p_feature_id\n    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision",
         "  where f.id = p_feature_id\n    and f.revision = p_expected_revision\n    and exists (\n      select 1 from public.memberships as m\n      where m.organization_id = f.organization_id\n        and m.user_id = v_user_id\n        and m.role in ('admin', 'editor', 'viewer')\n    )\n  returning f.* into v_row;\n\n  if v_row.id is null then\n    select f.revision", None)]),
    # The whole update policy, both USING and WITH CHECK. Widening only USING would
    # let the WITH CHECK refuse the viewer, which is a different refusal.
    ("policy-lets-viewer-update", STORAGE, "storage", "viewer updated a feature through the policy", [
        (lambda t: t[t.index("create policy features_update_editor"):t.index("create policy features_delete_editor")],
         lambda old: old.replace("('admin', 'editor')", "('admin', 'editor', 'viewer')"), None)]),
    ("tombstone-visible-to-any-member", FEATURES, "sql", "viewer updates a deleted feature", [
        ("      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = a.organization_id\n          and m.user_id = p_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    raise exception 'feature was deleted'",
         "  ) then\n    raise exception 'feature was deleted'", None)]),
    ("conflict-revealed-to-other-organizations", FEATURES, "sql", "update by viewer_a on feat_point answered", [
        ("    select f.revision into v_current\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      );\n    if found then\n      raise exception 'feature revision conflict'\n        using errcode = 'PT409', detail = format('current revision %s', v_current);\n    end if;\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n  return app_private.feature_json(v_row);",
         "    select f.revision into v_current\n    from public.features as f\n    where f.id = p_feature_id;\n    if found then\n      raise exception 'feature revision conflict'\n        using errcode = 'PT409', detail = format('current revision %s', v_current);\n    end if;\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n  return app_private.feature_json(v_row);", None),
        ("  if not exists (\n    select 1\n    from public.features as f\n    where f.id = p_feature_id\n      and exists (\n        select 1 from public.memberships as m\n        where m.organization_id = f.organization_id\n          and m.user_id = v_user_id\n          and m.role in ('admin', 'editor')\n      )\n  ) then\n    perform app_private.raise_feature_unavailable(p_feature_id, v_user_id);\n  end if;\n", "", None)]),
    # Audit and deletion.
    ("audit-trigger-dropped", FEATURES, "sql", "features lacks the deletion audit trigger", [
        ("create trigger features_audit_deletion\n  after delete on public.features\n  for each row execute function app_private.record_feature_deletion();\n", "", None)]),
    ("audit-immutability-dropped", FEATURES, "sql", "the audit table lacks its append-only triggers", [
        ("create trigger feature_audit_events_immutable\n  before update or delete on app_private.feature_audit_events\n  for each row execute function app_private.reject_feature_audit_change();\n", "", None)]),
    ("audit-truncate-allowed", FEATURES, "sql", "the audit table lacks its append-only triggers", [
        ("create trigger feature_audit_events_no_truncate\n  before truncate on app_private.feature_audit_events\n  for each statement execute function app_private.reject_feature_audit_change();\n", "", None)]),
    ("truncate-trigger-dropped", FEATURES, "sql", "features lacks the BEFORE TRUNCATE statement trigger", [
        ("create trigger features_refuse_truncate\n  before truncate on public.features\n  for each statement execute function app_private.refuse_feature_truncate();\n", "", None)]),
    ("truncate-guard-silenced", FEATURES, "sql", "owner truncates features: expected", [
        ("  raise exception 'feature rows cannot be truncated; delete each feature so the deletion is audited'\n    using errcode = 'feature_not_supported';",
         "  null;", None)]),
    ("audit-summary-carries-title", FEATURES, "sql", "audit summary leaks content", [
        ("format('deleted %s feature at revision %s', extensions.geometrytype(old.geom), old.revision)",
         "format('deleted %s feature at revision %s', old.title, old.revision)", None)]),
    ("audit-without-actor-allowed", FEATURES, "sql", "owner delete without an actor", [
        ("  if v_actor is null then\n    raise insufficient_privilege using message = 'feature deletion requires an authenticated actor';\n  end if;\n  insert",
         "  insert", None)]),
    # Grants and privileges.
    ("direct-writes-restored", FEATURES, "sql", "authenticated holds a table-level write privilege on features", [
        ("revoke insert, update, delete on table public.features from authenticated;\n", "", None)]),
    ("anon-may-execute", FEATURES, "sql", "anon can execute public.create_feature", [
        ("revoke all on function public.create_feature(uuid, jsonb, text, text, text, jsonb),\n  public.update_feature(uuid, integer, jsonb),\n  public.delete_feature(uuid, integer)\n  from public, anon;",
         "revoke all on function public.create_feature(uuid, jsonb, text, text, text, jsonb),\n  public.update_feature(uuid, integer, jsonb),\n  public.delete_feature(uuid, integer)\n  from public;", None)]),
    ("rpc-search-path-unpinned", FEATURES, "sql", "create_feature(uuid, jsonb, text, text, text, jsonb) must be security definer", [
        ("returns jsonb\nlanguage plpgsql\nvolatile\nsecurity definer\nset search_path = ''\nas $$\ndeclare\n  v_user_id uuid := auth.uid();\n  v_geom public.wgs84_geometry;",
         "returns jsonb\nlanguage plpgsql\nvolatile\nsecurity definer\nas $$\ndeclare\n  v_user_id uuid := auth.uid();\n  v_geom public.wgs84_geometry;", None)]),
    # Numbers.
    ("numbers-not-checked", FEATURES, "sql", "attribute beyond double range", [
        ("      if ((v_number::double precision)::text)::numeric is distinct from v_number then\n        return false;\n      end if;",
         "      null;", None)]),
    ("float-setting-not-pinned", FEATURES, "sql", "the number check must pin extra_float_digits", [
        ("set search_path = ''\nset extra_float_digits = 1\nas $$", "set search_path = ''\nas $$", None)]),
    # Geometry bounds.
    ("geometry-byte-ceiling-removed", FEATURES, "sql", "geometry over the byte ceiling", [
        ("  if octet_length(p_geometry::text) > 131072 then", "  if false then", None)]),
    ("vertex-limit-removed", FEATURES, "sql", "geometry: line 2001 vertices", [
        ("  if extensions.st_npoints(v_geom) > 2000 then", "  if false then", None)]),
    ("coordinate-range-removed", FEATURES, "sql", "geometry: swapped lon lat", [
        ("  if jsonb_path_exists(v_coordinates, (format('strict %s[0] ? (@ < -180 || @ > 180)', v_prefix))::jsonpath)\n    or jsonb_path_exists(v_coordinates, (format('strict %s[1] ? (@ < -90 || @ > 90)', v_prefix))::jsonpath) then",
         "  if false then", None),
        ("  if extensions.st_xmin(v_geom) < -180 or extensions.st_xmax(v_geom) > 180\n    or extensions.st_ymin(v_geom) < -90 or extensions.st_ymax(v_geom) > 90 then",
         "  if false then", None)]),
    # With the function's check gone, the one-vertex line reaches the table's
    # features_geom_valid CHECK, which uses the one-argument ST_IsValid and raises the
    # NOTICE. That is the owner-only path the doc records, and the wrapper catches it
    # first. The label the suite would otherwise report is "geometry: one-vertex line".
    ("validity-check-removed", FEATURES, "sql", "the server raised a NOTICE", [
        ("  if not extensions.st_isvalid(v_geom, 0) then", "  if false then", None)]),
    # The one-argument ST_IsValid raises a NOTICE with the reason and the location of a
    # self-intersection, which includes the submitted coordinates. The suite must fail
    # on that notice, through the same wrapper CI runs.
    ("one-arg-isvalid-notice", FEATURES, "sql", "the server raised a NOTICE", [
        ("  if not extensions.st_isvalid(v_geom, 0) then", "  if not extensions.st_isvalid(v_geom) then", None)]),
    ("shape-check-removed", FEATURES, "sql", "geometry: missing type", [
        ("    or (select array_agg(k order by k) from jsonb_object_keys(p_geometry) as k)\n      is distinct from array['coordinates', 'type']\n",
         "\n", None)]),
    # Patch and text bounds.
    ("update-patch-size-removed", FEATURES, "sql", "update: patch one byte over the ceiling", [
        ("  if octet_length(p_changes::text) > 147456 then", "  if false then", None)]),
    ("unknown-update-field-allowed", FEATURES, "sql", "update: unknown field", [
        ("    where k not in ('geometry', 'title', 'description', 'status', 'attributes')", "    where false", None)]),
    ("create-title-check-removed", FEATURES, "sql", "title null:", [
        ("  perform app_private.check_feature_title(p_title);\n  perform app_private.check_feature_description(p_description);\n  perform app_private.check_feature_status(p_status);\n  perform app_private.validate_feature_attributes(p_attributes);\n\n  begin",
         "  begin", None)]),
    ("whitespace-trim-spaces-only", FEATURES, "sql", "title tab: expected", [
        ("p_title <> btrim(p_title, app_private.feature_whitespace()) then",
         "p_title <> btrim(p_title, ' ') then", None)]),
]


def psql(args, db):
    env = dict(os.environ, PGDATABASE=db)
    return subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"] + args,
                          env=env, capture_output=True, text=True)


def read_migrations():
    return {path.name: path.read_text() for path in sorted(MIGRATIONS.glob("*.sql"))}


def build(texts):
    psql(["-c", f"drop database if exists {DB}", "-c", f"create database {DB} template template0"], "postgres")
    # Creates the roles and the auth schema when they are missing. Existing ones are
    # left alone, so a failure here is ignored and the migrations decide the result.
    subprocess.run(["psql", "-X", "-q", "-f", str(ROOT / "tests/sql/ci-bootstrap.sql")],
                   env=dict(os.environ, PGDATABASE=DB), capture_output=True, text=True)
    for name, text in texts.items():
        result = psql(["-c", text], DB)
        if result.returncode != 0:
            raise SystemExit(f"migration {name} failed to build: {result.stderr.strip()}")


def apply_edits(original, edits, name):
    text = original
    for old, new, occurrence in edits:
        if callable(old):
            old = old(text)
        if callable(new):
            new = new(old)
        count = text.count(old)
        if occurrence is None:
            if count != 1:
                raise SystemExit(f"{name}: mutation anchor matched {count} times, expected 1: {old[:70]!r}")
            text = text.replace(old, new, 1)
        else:
            if count <= occurrence:
                raise SystemExit(f"{name}: mutation anchor has {count} matches, wanted index {occurrence}")
            parts = text.split(old)
            text = old.join(parts[:occurrence + 1]) + new + old.join(parts[occurrence + 1:])
    if text == original:
        raise SystemExit(f"{name}: mutation changed nothing")
    return text


def run_suite(kind):
    if kind == "sql":
        # The wrapper is what CI runs: it fails on any notice besides the cascade one.
        env = dict(os.environ, PGDATABASE=DB)
        result = subprocess.run(["bash", str(ROOT / "tests/sql/feature_edits_run.sh")],
                                env=env, capture_output=True, text=True)
    elif kind == "storage":
        result = psql(["-v", "VERBOSITY=verbose", "-f", str(ROOT / "tests/sql/feature_storage.sql")], DB)
    else:
        env = dict(os.environ, PGDATABASE=DB, NETEOC_DISPOSABLE_DATABASE="1")
        result = subprocess.run(["bash", str(ROOT / "tests/sql/feature_edits_race.sh")],
                                env=env, capture_output=True, text=True)
    return result.returncode, result.stderr + result.stdout


def first_error(output):
    for line in output.splitlines():
        if "ERROR" in line or "feature race test" in line:
            return line.strip()[:240]
    return output.strip()[:240]


def main():
    wanted = set(sys.argv[1:])
    originals = read_migrations()
    failures = []

    build(originals)
    for kind in ("sql", "storage", "race"):
        code, out = run_suite(kind)
        if code != 0:
            raise SystemExit(f"control run ({kind}) failed on the unmutated migrations:\n{out}")
    print("control      ok    unmutated migrations pass the SQL suites and the race script")

    for name, target, kind, expect, edits in MUTATIONS:
        if wanted and name not in wanted:
            continue
        texts = dict(originals)
        texts[target] = apply_edits(originals[target], edits, name)
        build(texts)
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
