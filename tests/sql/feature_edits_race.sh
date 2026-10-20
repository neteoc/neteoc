#!/usr/bin/env bash
# Concurrent writes to one feature by real database sessions. Connection settings
# come from PGHOST, PGPORT, PGUSER, and PGDATABASE. The fixtures are committed, so
# the EXIT trap removes them even when an assertion fails.
#
# The revision check is the UPDATE or DELETE statement itself, so the loser of a
# race must wait on the row lock and then find the revision moved on. Every
# scenario below checks the loser's error and the winner's data, because a
# conflict that also lost the winner's data would be worse than no check.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
psql_flags=(-X -q -At -v ON_ERROR_STOP=1)
editor_one='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c01'
editor_two='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c02'
organization='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c10'
feature_update_update='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c31'
feature_delete_update='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c32'
feature_update_delete='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c33'
feature_burst='b2c3d4e5-f6a7-4b89-9c0d-1e2f3a4b5c34'
work="$(mktemp -d)"
trap 'rm -rf "$work"; psql "${psql_flags[@]}" -f "$dir/feature_edits_race_cleanup.sql" >/dev/null || echo "feature race fixture cleanup failed" >&2' EXIT

fail() {
  echo "feature race test: $*" >&2
  exit 1
}

query() {
  psql "${psql_flags[@]}" -c "$1"
}

# Wait until a condition holds in the database, for up to ten seconds.
wait_for() {
  local sql="$1" attempt
  for attempt in $(seq 1 20); do
    if [ "$(query "$sql")" = "t" ]; then
      return 0
    fi
    sleep 0.5
  done
  fail "timed out waiting for: $sql"
}

psql "${psql_flags[@]}" -f "$dir/feature_edits_race_setup.sql" >"$work/setup.log" 2>&1 || fail "setup failed: $(cat "$work/setup.log")"

# Starts the holder, waits until it sleeps with the row lock, then starts the racer
# and waits until the racer is blocked on a lock. Both finish, and the logs stay in
# $work for the caller to inspect.
hold_then_race() {
  local name="$1" hold_file="$2" race_file="$3" feature="$4"
  local hold_user="$5" hold_changes="$6" race_user="$7" race_changes="$8"
  PGAPPNAME="race-$name-holder" psql -X -q -v ON_ERROR_STOP=1 \
    -v feature="$feature" -v revision=1 -v user_id="$hold_user" -v changes="$hold_changes" \
    -f "$dir/$hold_file" >"$work/$name-holder.log" 2>&1 &
  local holder=$!
  wait_for "select exists (select 1 from pg_stat_activity
    where application_name = 'race-$name-holder' and query like '%pg_sleep%' and state = 'active')"

  PGAPPNAME="race-$name-racer" psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
    -v feature="$feature" -v revision=1 -v user_id="$race_user" -v changes="$race_changes" \
    -f "$dir/$race_file" >"$work/$name-racer.log" 2>&1 &
  local racer=$!
  wait_for "select exists (select 1 from pg_stat_activity
    where application_name = 'race-$name-racer' and wait_event_type = 'Lock')"

  holder_status=0
  wait "$holder" || holder_status=$?
  racer_status=0
  wait "$racer" || racer_status=$?
  [ "$holder_status" -eq 0 ] || fail "$name: holder failed: $(cat "$work/$name-holder.log")"
}

# Scenario 1: update against update. The second editor read revision 1 and sent a
# change while the first editor's write was still open. It must wait, then conflict.
hold_then_race update-update feature_edits_race_hold_update.sql feature_edits_race_update.sql \
  "$feature_update_update" "$editor_one" '{"title": "First editor wins"}' "$editor_two" '{"title": "Second editor loses"}'
[ "$racer_status" -ne 0 ] || fail "update/update: the second editor overwrote the first editor's change"
grep -q 'PT409' "$work/update-update-racer.log" && grep -q 'feature revision conflict' "$work/update-update-racer.log" \
  && grep -q 'current revision 2' "$work/update-update-racer.log" \
  || fail "update/update: loser did not report a revision conflict: $(cat "$work/update-update-racer.log")"
row="$(query "select title || '|' || revision || '|' || updated_by from public.features where id = '$feature_update_update'")"
[ "$row" = "First editor wins|2|$editor_one" ] || fail "update/update: winner's data was not intact: $row"

# Scenario 2: delete against update. The update waits for the delete, then finds
# the feature gone. The editor is told it was deleted, not that it was forbidden.
hold_then_race delete-update feature_edits_race_hold_delete.sql feature_edits_race_update.sql \
  "$feature_delete_update" "$editor_one" '{}' "$editor_two" '{"title": "Edit after delete"}'
[ "$racer_status" -ne 0 ] || fail "delete/update: an update succeeded against a deleted feature"
grep -q 'PT410' "$work/delete-update-racer.log" && grep -q 'feature was deleted' "$work/delete-update-racer.log" \
  || fail "delete/update: loser was not told the feature was deleted: $(cat "$work/delete-update-racer.log")"
[ "$(query "select count(*) from public.features where id = '$feature_delete_update'")" -eq 0 ] \
  || fail "delete/update: the feature came back"
[ "$(query "select count(*) from app_private.feature_audit_events where feature_id = '$feature_delete_update' and action = 'deleted' and actor_user_id = '$editor_one'")" -eq 1 ] \
  || fail "delete/update: expected exactly one deletion event for the winner"

# Scenario 3: update against delete. The delete waits for the update, then finds the
# revision moved on. The feature stays, with the update's data, and nothing is audited.
hold_then_race update-delete feature_edits_race_hold_update.sql feature_edits_race_delete.sql \
  "$feature_update_delete" "$editor_one" '{"title": "Update survives"}' "$editor_two" '{}'
[ "$racer_status" -ne 0 ] || fail "update/delete: a delete removed a feature another editor had just changed"
grep -q 'PT409' "$work/update-delete-racer.log" && grep -q 'current revision 2' "$work/update-delete-racer.log" \
  || fail "update/delete: loser did not report a revision conflict: $(cat "$work/update-delete-racer.log")"
row="$(query "select title || '|' || revision from public.features where id = '$feature_update_delete'")"
[ "$row" = "Update survives|2" ] || fail "update/delete: the update was not intact: $row"
[ "$(query "select count(*) from app_private.feature_audit_events where feature_id = '$feature_update_delete'")" -eq 0 ] \
  || fail "update/delete: a refused delete was audited"

# Scenario 4: six sessions start together, all with revision 1. Exactly one may
# write. The revision moves by exactly one, and the stored title is the winner's.
sessions=6
for i in $(seq 1 "$sessions"); do
  user="$editor_one"
  if [ $((i % 2)) -eq 0 ]; then user="$editor_two"; fi
  PGAPPNAME="race-burst-$i" psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
    -v feature="$feature_burst" -v revision=1 -v user_id="$user" -v changes="{\"title\": \"Burst $i\"}" \
    -f "$dir/feature_edits_race_update.sql" >"$work/burst-$i.log" 2>&1 &
  burst_pids[$i]=$!
done
successes=0
winner=""
for i in $(seq 1 "$sessions"); do
  status=0
  wait "${burst_pids[$i]}" || status=$?
  if [ "$status" -eq 0 ]; then
    successes=$((successes + 1))
    winner="$i"
  else
    grep -q 'PT409' "$work/burst-$i.log" && grep -q 'feature revision conflict' "$work/burst-$i.log" \
      || fail "burst: session $i failed for the wrong reason: $(cat "$work/burst-$i.log")"
  fi
done
[ "$successes" -eq 1 ] || fail "burst: expected exactly one of $sessions sessions to write, got $successes"
row="$(query "select title || '|' || revision from public.features where id = '$feature_burst'")"
[ "$row" = "Burst $winner|2" ] || fail "burst: stored [$row] but session $winner won"

echo "feature race test: one writer wins each race, losers conflict, winner's data intact"
