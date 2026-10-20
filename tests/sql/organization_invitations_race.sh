#!/usr/bin/env bash
# Concurrent acceptance of one invitation by real database sessions. Connection
# settings come from PGHOST, PGPORT, PGUSER, and PGDATABASE. The fixtures are
# committed, so the EXIT trap removes them even when an assertion fails.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
psql_flags=(-X -q -At -v ON_ERROR_STOP=1)
# The script commits fixtures, deletes audit rows, and disables the audit
# immutability trigger for its cleanup. Those writes must never reach a database
# that holds anything else. Refuse unless the caller opts in and the server reports
# a throwaway database name. Both checks run before any write, and before the EXIT
# trap is installed, so a refusal touches nothing.
disposable_pattern='^neteoc_(test|race)[a-z0-9_]*$'
if [ "${NETEOC_DISPOSABLE_DATABASE:-}" != "1" ]; then
  echo "refusing to run: set NETEOC_DISPOSABLE_DATABASE=1 to confirm the target is a throwaway database. This script commits fixtures and clears audit rows." >&2
  exit 2
fi
actual_database="$(psql -X -q -At -v ON_ERROR_STOP=1 -c 'select current_database()')" \
  || { echo "refusing to run: cannot read the target database name" >&2; exit 2; }
if ! [[ "$actual_database" =~ $disposable_pattern ]]; then
  echo "refusing to run against \"$actual_database\": the database name must match $disposable_pattern" >&2
  exit 2
fi
invitee_one='f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a02'
invitee_two='f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a03'
organization='f0e1d2c3-b4a5-4968-8a7b-6c5d4e3f2a10'
work="$(mktemp -d)"
trap 'rm -rf "$work"; psql "${psql_flags[@]}" -f "$dir/organization_invitations_race_cleanup.sql" >/dev/null || echo "race fixture cleanup failed" >&2' EXIT

fail() {
  echo "race test: $*" >&2
  exit 1
}

# Wait until a condition holds in the database, for up to ten seconds.
wait_for() {
  local query="$1" attempt
  for attempt in $(seq 1 20); do
    if [ "$(psql "${psql_flags[@]}" -c "$query")" = "t" ]; then
      return 0
    fi
    sleep 0.5
  done
  fail "timed out waiting for: $query"
}

psql "${psql_flags[@]}" -f "$dir/organization_invitations_race_setup.sql" >"$work/setup.log" 2>&1 \
  || fail "setup failed"
token_one="$(sed -n 's/^token_one://p' "$work/setup.log")"
token_two="$(sed -n 's/^token_two://p' "$work/setup.log")"
[ "${#token_one}" -eq 64 ] && [ "${#token_two}" -eq 64 ] || fail "setup did not issue two tokens"

# Scenario 1: the holder keeps the row lock while a second session attempts the
# same invitation. The second session must wait, then fail with the used message.
PGAPPNAME=race-holder psql -X -q -v ON_ERROR_STOP=1 \
  -v token="$token_one" -v user_id="$invitee_one" \
  -f "$dir/organization_invitations_race_hold.sql" >"$work/holder.log" 2>&1 &
holder=$!
wait_for "select exists (select 1 from pg_stat_activity
  where application_name = 'race-holder' and query like '%pg_sleep%' and state = 'active')"

PGAPPNAME=race-racer psql -X -q -v ON_ERROR_STOP=1 \
  -v token="$token_one" -v user_id="$invitee_one" \
  -f "$dir/organization_invitations_race_accept.sql" >"$work/racer.log" 2>&1 &
racer=$!
wait_for "select exists (select 1 from pg_stat_activity
  where application_name = 'race-racer' and wait_event_type = 'Lock')"

holder_status=0
wait "$holder" || holder_status=$?
racer_status=0
wait "$racer" || racer_status=$?
[ "$holder_status" -eq 0 ] || fail "holder session failed: $(cat "$work/holder.log")"
[ "$racer_status" -ne 0 ] || fail "second session accepted an invitation the first session had accepted"
grep -q 'invitation already used' "$work/racer.log" \
  || fail "second session failed for the wrong reason: $(cat "$work/racer.log")"

# Scenario 2: two sessions start together for a second invitation. Exactly one
# may succeed, and the other must report the used message.
PGAPPNAME=race-burst-a psql -X -q -v ON_ERROR_STOP=1 \
  -v token="$token_two" -v user_id="$invitee_two" \
  -f "$dir/organization_invitations_race_accept.sql" >"$work/burst-a.log" 2>&1 &
burst_a=$!
PGAPPNAME=race-burst-b psql -X -q -v ON_ERROR_STOP=1 \
  -v token="$token_two" -v user_id="$invitee_two" \
  -f "$dir/organization_invitations_race_accept.sql" >"$work/burst-b.log" 2>&1 &
burst_b=$!
burst_a_status=0
wait "$burst_a" || burst_a_status=$?
burst_b_status=0
wait "$burst_b" || burst_b_status=$?
successes=0
[ "$burst_a_status" -eq 0 ] && successes=$((successes + 1))
[ "$burst_b_status" -eq 0 ] && successes=$((successes + 1))
[ "$successes" -eq 1 ] || fail "expected exactly one of two concurrent acceptances to succeed, got $successes"
if [ "$burst_a_status" -ne 0 ]; then loser="$work/burst-a.log"; else loser="$work/burst-b.log"; fi
grep -q 'invitation already used' "$loser" \
  || fail "losing session failed for the wrong reason: $(cat "$loser")"

# Each invitation produced exactly one membership and one consumption event.
for invitee in "$invitee_one" "$invitee_two"; do
  members="$(psql "${psql_flags[@]}" -c "select count(*) from public.memberships
    where organization_id = '$organization' and user_id = '$invitee'")"
  [ "$members" -eq 1 ] || fail "invitee has $members memberships after concurrent acceptance, expected 1"
done
consumed="$(psql "${psql_flags[@]}" -c "select count(*) from app_private.invitation_audit_events
  where organization_id = '$organization' and action = 'consumed'")"
[ "$consumed" -eq 2 ] || fail "expected 2 consumption audit events, got $consumed"

echo "race test: one membership per invitation under concurrent acceptance"
