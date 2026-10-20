# Feature writes: create, update, delete, and revision conflicts

Status: implemented for issue #14 (PRD MVP-04). The database functions are the
only write path. No route exists yet; #15 (editing UI) and the write API are
built on these functions. Read [layer feature reads](layer-feature-queries.md)
first for the read contract.

## Functions

| Function                                                                            | Caller                                        | Returns                                 |
| ----------------------------------------------------------------------------------- | --------------------------------------------- | --------------------------------------- |
| `public.create_feature(layer_id, geometry, title, description, status, attributes)` | admin or editor of the layer's organization   | the feature, in the read document shape |
| `public.update_feature(feature_id, expected_revision, changes)`                     | admin or editor of the feature's organization | the feature after the write             |
| `public.delete_feature(feature_id, expected_revision)`                              | admin or editor of the feature's organization | `{id, deleted, revision}`               |

All three are `security definer` with `search_path = ''`, granted to
`authenticated` only. Each is a public API in its own right, so every bound,
authorization check, and revision check lives in the function. The migration
removes the table-level insert, update, and delete grants from `authenticated`,
so no client can skip the revision check by writing the table directly. Definer
is a deliberate deviation from the invoker default: with no table grant, an
invoker function could not write at all, and the authorization has to live in
the same statement as the write either way.

`changes` is a patch. Present keys set a field, absent keys leave it alone.
`description` and `status` accept `null` to clear. The keys are `geometry`,
`title`, `description`, `status`, and `attributes`. Any other key, including
`revision`, `layer_id`, `organization_id`, and actor fields, is refused.

## Revision check

The expected revision is part of the write statement, not a separate check. The
UPDATE or DELETE filters on `id`, `revision`, and the editor membership in one
WHERE clause. Under concurrency the second writer waits on the row lock, then
re-reads the committed row, finds the revision has moved, and changes nothing.
There is no read followed by a write, so there is no window for a lost update.
Classification (conflict, deleted, or not editable) runs only after the
statement matched no row, and it only chooses which error to raise.

`tests/sql/feature_edits_race.sh` proves this with real sessions: an update
against an update, a delete against an update, an update against a delete, and
six simultaneous writers all at the same revision. In each race exactly one
writer succeeds, the loser gets `PT409` with the current revision, and the
winner's data is intact.

## Error contract

Every refusal is raised by the function with a fixed message and SQLSTATE. A
route can map them one-to-one.

| Condition                                                                                                                   | SQLSTATE | Message                                                                 |
| --------------------------------------------------------------------------------------------------------------------------- | -------- | ----------------------------------------------------------------------- |
| No authenticated user                                                                                                       | 42501    | `sign in to edit features`                                              |
| Caller is not an admin or editor of the organization, the feature or layer does not exist, or it is in another organization | 42501    | `feature not found or not editable` / `layer not found or not editable` |
| Feature was deleted and the caller is an admin or editor of its organization                                                | PT410    | `feature was deleted`                                                   |
| Expected revision does not match the current revision                                                                       | PT409    | `feature revision conflict`, detail `current revision N`                |
| Geometry shape, coordinates, range, vertices, byte ceiling, or validity                                                     | 22023    | one message per rule, see below                                         |
| Title, description, status, attribute, or patch bounds                                                                      | 22023    | one message per rule                                                    |

For a caller who may not know the feature exists, the first refusal row gives
one answer: SQLSTATE `42501` and one message, whether the feature is absent,
hidden in another organization, or visible to the caller as a viewer.
`tests/sql/feature_edits.sql` asserts those three outcomes are identical,
including the detail field.

The answers are the same. The time they take is not proven identical. The
latency of each case was measured in the database, with
[`tests/perf/feature_write_timing.sql`](../tests/perf/feature_write_timing.sql):
2,000 interleaved calls per case, on a local Supabase stack (PostgreSQL
17.11.0.004, Apple silicon), 2026-10-20. Medians:

| Operation | Absent feature or layer | Live, another organization | Live, same organization, viewer |
| --------- | ----------------------- | -------------------------- | ------------------------------- |
| update    | 22 us                   | 23 us                      | 22 us                           |
| delete    | 26 us                   | 29 us                      | 28 us                           |
| create    | 13 us                   | 14 us                      | 14 us                           |

The gap is 1 to 3 microseconds, and it is not zero. This is not a constant-time
claim, and the figures cover database time only, without network time. Run the
script again on the target host before relying on a finer difference.

A caller who is an admin or editor of the feature's organization is told that a
deleted feature was deleted (`PT410`), because the audit trail records the
deletion for them. That answer is different from the others by design. Its
latency was not measured. A viewer or outsider never learns the revision, and a
conflict is not revealed to a caller who cannot see the feature.

Argument shape is checked before authorization. These checks are the feature ID,
the expected revision, and the patch's type and size. None of them depends on
any row, so every caller gets the same answer for them. Every answer that
depends on the feature or layer comes after authorization, including the field
checks. An invalid payload from an unauthorized caller gets the authorization
refusal, so it cannot reveal whether a layer or feature exists.

## Limits

The ceilings are literals in the migration. Each is enforced in the function,
and `tests/sql/feature_edits.sql` asserts each one with a pair at the boundary.

| Bound                       | Ceiling                                                                                                                           |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Geometry JSON text          | 131,072 bytes                                                                                                                     |
| Vertices per geometry       | 2,000                                                                                                                             |
| Patch JSON text (`changes`) | 147,456 bytes                                                                                                                     |
| Title                       | 1 to 120 characters, with no leading or trailing whitespace (Unicode White_Space, including tab, newline, and non-breaking space) |
| Description                 | at most 2,000 characters                                                                                                          |
| Status                      | 1 to 40 characters, with no leading or trailing whitespace (same set as the title)                                                |
| Attributes JSON text        | 4,096 bytes, a JSON object                                                                                                        |
| Geometry types              | GeoJSON Point, LineString, Polygon                                                                                                |
| Coordinates                 | 2D, WGS84 range, PostGIS-valid                                                                                                    |

The geometry ceiling is checked before any JSON shape work, and the vertex limit
before `ST_IsValid`, which is the expensive check. Table constraints remain as a
backstop, but a request that reaches one of them is a validator gap:
`features_geom_npoints_limit` and the other constraints would raise `23514` with
the failing row in the error DETAIL, which a log would record.

## Attribute numbers: refused at write time

`attributes` is `jsonb`. PostgreSQL stores its numbers exactly, but the read
path parses them with `JSON.parse`, and the read document is serialized again.
[The read contract](layer-feature-queries.md#numeric-fidelity-of-attributes)
records what that does: `1e500` comes back as `null`, `12345678901234567890` as
`12345678901234567000`, and an over-precise decimal as its nearest double.

**Decision: reject at write time.** `app_private.attribute_numbers_faithful`
refuses any attribute number that the read path would not return unchanged. The
check round-trips each number through a double and the shortest decimal text of
that double, and it refuses a number that does not come back equal. It also
refuses one outside the double range.

The reasons for refusing rather than storing:

- Storing a value the read path cannot return faithfully is the trap
  [#13](layer-feature-queries.md) warned about. A reader in #17 could not tell
  that a stored `null` was once `1e500`.
- The alternatives change the read contract for every consumer: returning raw
  `jsonb` text, or returning numbers as strings. Those are contract decisions
  for the consumers of attributes, not for the write path to make.
- A write-time refusal is a 22023 error with a fixed message, so a client sees
  it on the write, not later on a read.

Accepted: decimals that survive a double (`0.1`, `0.30000000000000004`),
integers up to 2^53 and any integer a double prints exactly (`1e22`), and the
range edges (`5e-324`, `1.5e300`). Refused: `1e500`, `-1e500`, `1e-500`
(underflow to zero), `12345678901234567890`, `9007199254740993`, and
`0.1000000000000000055511151231257827`.

The check pins `extra_float_digits = 1` on the function, because the shortest
text form depends on that session setting. The SQL suite runs a write under
`extra_float_digits = 0` and asserts the same answer.

The check is exact for the double round trip. It does not say that a JavaScript
client can store the number elsewhere. The read path returns it as a double, and
the rule above is the only guarantee.

## Audit

`app_private.feature_audit_events` records each deletion: the feature ID, the
organization, the layer, the actor, the action (`deleted`), the revision, a
bounded summary, and a timestamp. The summary has the form
`deleted POINT feature at revision 3`. It carries no title, description,
attribute, or coordinate.

The table has no foreign key to `features` or `layers`, so a record outlives the
row it describes. It has no grant to any application role and no read path in
this issue. Update, delete, and truncate raise an error, even for the table
owner. The deletion trigger runs in the deleting statement, so a delete and its
record commit or fail together, and a cascade from a layer delete is recorded
feature by feature. A deletion with no authenticated actor is refused, because
it cannot be attributed.

Creates and updates are deliberately not audited. The implementation contract's
audit row lists membership, sharing, token, and deletion changes, not ordinary
edits, and nothing in this issue changes who can read or edit a feature. A
feature's organization and layer are immutable, so access cannot change through
an edit. #19 adds the sharing audit when visibility tiers arrive. A later reader
who sees no create or update record should read that as the design, not as a
gap.

## Notices from ST_IsValid

PostgreSQL's one-argument `ST_IsValid` raises a NOTICE when a geometry is
invalid. The notice names the reason and the location, for example
`Self-intersection at or near point -104.75 39.7`, so it carries the submitted
coordinates. A notice reaches client and database logs, and feature content must
never reach either. The two-argument form with flags `0` gives the same answer
with no notice.

- `app_private.parse_feature_geometry`, which every create and update goes
  through, uses the flags form. A bad geometry produces only the fixed `22023`
  message.
- `tests/sql/feature_edits_run.sh` runs the suite and fails if the server raises
  any notice other than the one that announces a `TRUNCATE ... CASCADE` table
  name. The notice text is withheld from its output. The mutation harness proves
  the check with the one-argument call restored: the suite fails on that notice.
- The table constraint `features_geom_valid` from #42 still uses the
  one-argument form, and it can still raise the notice. Application roles cannot
  reach it, because every write goes through the functions, which validate
  first. The table owner bypasses RLS and can reach it with a direct insert.
  That constraint lives in a merged migration, and changing it would be a
  forward ALTER, which is a separate decision and is not made here.
  `tests/sql/feature_storage.sql` inserts invalid geometries as the owner, so
  its output carries those notices. The suite does not fail on them.

## Operations and retention

These consequences follow from the audit rules. They belong in the offboarding
and retention plan (threat T12).

- **A delete needs an authenticated actor.** A DELETE with no JWT actor is
  refused, including by the table owner and the Supabase SQL editor. A layer
  that still has features therefore cannot be deleted from the SQL editor,
  because its cascade deletes those features with no actor. An operator must
  remove the features through an authenticated session, one at a time, and then
  delete the layer.
- **TRUNCATE is refused for features.** A TRUNCATE of `features`, or a TRUNCATE
  of `layers` with CASCADE, is refused for every role, including the owner, with
  SQLSTATE `0A000`. TRUNCATE fires no row-level delete trigger, so it would
  remove rows with no audit record.
- **Restrict keys block hard deletion.** `feature_audit_events.organization_id`
  and `actor_user_id` are `on delete restrict`. An organization that has ever
  had a feature deleted cannot be hard-deleted. An Auth user who ever deleted a
  feature cannot be deleted, and the existing restrict on `features.created_by`
  already blocks a user who created one. Removing either needs a documented,
  audited break-glass procedure. That procedure is not built here.
- **Retention is not defined.** The audit trail keeps every deletion record. A
  retention period, and the procedure for removing old records, are open items
  for the retention plan.

## Atomicity

A write changes geometry, title, description, status, attributes, revision,
actor, and timestamp in one statement, or none of them. The revision, actor, and
timestamp are stamped by `app_private.stamp_feature_write`, which existed before
this change. The SQL suite forces a failure after validation, by adding a check
the row cannot pass, and asserts that the row is unchanged afterward. It does
the same for a create, which leaves no row.

## Compatibility

No deployed Worker writes features. The Worker reads through
`list_layer_features`, which is unchanged. This migration removes a grant, adds
functions and an audit table, and removes nothing a deployed Worker uses, so
either Worker version runs against either schema.

## Verification

- `tests/sql/feature_edits.sql`, run through `tests/sql/feature_edits_run.sh`,
  calls each function directly as `authenticated` (and as `anon`) and asserts
  each refusal by SQLSTATE and message, with a boundary pair for each ceiling.
  It asserts grants with `has_table_privilege`, `has_column_privilege`, and
  `has_function_privilege`, and asserts the pinned search paths in `proconfig`.
- `tests/sql/feature_edits_race.sh` runs concurrent sessions, described above.
  It refuses to run unless `NETEOC_DISPOSABLE_DATABASE=1` is set and the server
  reports a database name matching `^neteoc_(test|race)`. It checks both before
  any write and before its cleanup trap is installed. The cleanup disables the
  audit immutability trigger for one transaction, because the audit rows have to
  go before the organization can. The trigger is restored in the same
  transaction, and the name check is what keeps that step off a database that
  matters. The invitation race script has the same guard.
- `tests/sql/feature_storage.sql` restores the write grants for the rest of its
  rolled-back transaction, so the row policies are tested as the only barrier.
  No migration grants them. The grants stay absent from every committed schema.
- `tests/sql/feature_edits_mutations.py` breaks each protection in a copy of the
  migration, or of the feature storage migration for the policies, and checks
  that the suite fails for the stated reason. It is run by hand, not in CI,
  because it builds a database per mutation.

## Deferred

- The write routes and their origin checks: #15.
- Creates and updates in the audit trail, with the visibility tier: #19.
- A commit-ordered column for the list cursor. The write path does not make one
  free: a commit-ordered value needs a serialized counter or a lock per layer,
  which would serialize every write to the layer. The decision stays with #20,
  as the lead directed.
- Multi-layer reads and the audience contract: #19.
