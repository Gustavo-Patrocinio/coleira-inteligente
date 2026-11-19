#!/usr/bin/env bash
# Restore drill: takes the newest encrypted off-site dump, restores it into a throwaway
# database next to the real one, checks the tables are there with their rows, and drops it.
# The live database is not touched. Run it on the server, in this folder, now and then:
#
#   bash restore-check.sh
set -euo pipefail
cd "$(dirname "$0")"
dc() { docker compose --profile offsite "$@"; }
sql() { dc exec -T db psql -U collar -d "$1" -tAqc "$2"; }
db=restore_check

latest=$(dc run --rm -T offsite lsf safe: --include 'collar-*.dump' 2>/dev/null | sort | tail -1)
[ -n "$latest" ] || { echo "FAIL: no off-site dump found (is the offsite service set up?)" >&2; exit 1; }
echo "newest off-site dump: $latest"

sql collar "DROP DATABASE IF EXISTS $db" >/dev/null
sql collar "CREATE DATABASE $db" >/dev/null
trap 'sql collar "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null || true' EXIT
sql "$db" "SELECT timescaledb_pre_restore()" >/dev/null
# custom-format dumps restore from a pipe: download, decrypt and restore in one go.
# pg_restore warns about TimescaleDB's circular catalog keys (expected), so its exit code
# is not the verdict; the row counts below are.
dc run --rm -T offsite cat "safe:$latest" 2>/dev/null |
  dc exec -T db pg_restore -U collar -d "$db" --no-owner 2>/dev/null || true
sql "$db" "SELECT timescaledb_post_restore()" >/dev/null

ok=1
for t in schema_migrations users dogs devices activity_minute alerts; do
  if n=$(sql "$db" "SELECT count(*) FROM $t" 2>/dev/null); then
    printf '  %-18s %s rows\n' "$t" "$n"
  else
    printf '  %-18s MISSING\n' "$t"; ok=0
  fi
done
migrations=$(sql "$db" "SELECT count(*) FROM schema_migrations" 2>/dev/null || echo 0)
[ "$migrations" -gt 0 ] || ok=0
if [ "$ok" = 1 ]; then
  echo "OK: $latest restores (throwaway database dropped again)"
else
  echo "FAIL: the restore is incomplete; see DEPLOY.md, Backups and restore" >&2
  exit 1
fi
