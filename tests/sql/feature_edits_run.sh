#!/usr/bin/env bash
# Runs the feature edit SQL suite and fails if the server raises a NOTICE other
# than the TRUNCATE cascade announcement. A notice is a log path, and feature
# content must never reach a log. PostgreSQL
# raises one from ST_IsValid's one-argument form with the reason and the location
# of a self-intersection, which includes the submitted coordinates, so the suite
# fails on any notice rather than trusting the function alone. The notice text is
# withheld from this script's output for the same reason. Connection settings come
# from PGHOST, PGPORT, PGUSER, and PGDATABASE, as for the other suites.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

status=0
psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
  -c 'set client_min_messages = notice' \
  -f "$dir/feature_edits.sql" 2>"$err" || status=$?

# The TRUNCATE ... CASCADE assertion makes PostgreSQL announce the cascaded table
# names. Those carry no feature content, so exactly that notice is allowed. Every
# other notice fails the suite.
if grep 'NOTICE' "$err" | grep -v 'truncate cascades to table "[a-z_]*"' | grep -q .; then
  echo "feature_edits: the server raised a NOTICE. Its text is withheld because it can carry submitted feature content." >&2
  exit 1
fi
if [ "$status" -ne 0 ]; then
  cat "$err" >&2
  exit "$status"
fi
echo "feature_edits: passed with no notices"
