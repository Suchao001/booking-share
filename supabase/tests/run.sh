#!/usr/bin/env bash
# Runs the schema tests against a throwaway PostgreSQL 16 container (needs Docker + psql).
set -euo pipefail
cd "$(dirname "$0")/../.."

NAME=booking-share-test-pg
PORT=${PORT:-54399}
export PGPASSWORD=pw

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=pw -p "$PORT:5432" postgres:16 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
  psql -h localhost -p "$PORT" -U postgres -c 'select 1' >/dev/null 2>&1 && break
  sleep 1
done

psql -q -h localhost -p "$PORT" -U postgres -v ON_ERROR_STOP=1 \
  -f supabase/tests/stubs.sql \
  $(for f in supabase/migrations/*.sql; do printf -- '-f %s ' "$f"; done) \
  -f supabase/tests/booking_flow.sql \
  -f supabase/tests/rooms.sql 2>&1 | grep -E "NOTICE:  ok|FAIL|ERROR|PASSED"
