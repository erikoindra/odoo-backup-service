#!/usr/bin/env bash
# Smoke test: a throwaway PostgreSQL, a fake Odoo container and fake filestore,
# then real backups and the tools/ scripts against them.
# Everything it creates is named odbk-smoke-<pid>-* and removed on exit.
#
#   tests/smoke.sh [IMAGE]       default IMAGE: odoo-backup-service:test
#   PG_MAJOR=17 tests/smoke.sh   PostgreSQL major of the test server (match the image)
# Needs: docker, unzip.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-odoo-backup-service:test}"
PG_MAJOR="${PG_MAJOR:-17}"
HELPER=alpine:3.23
ID="odbk-smoke-$$"
NET="$ID-net" DB="$ID-db" ODOO="$ID-odoo" CRON="$ID-cron" VOL_DATA="$ID-data" VOL_OUT="$ID-out"
TMPD="$(mktemp -d)"
# Quote and dollar characters on purpose: the cron env snapshot must keep them.
PASS="s3cr'et \$x\"y"

cleanup() {
  docker rm -fv "$DB" "$ODOO" "$CRON" >/dev/null 2>&1 || true # -v: also the anonymous volumes
  docker volume rm -f "$VOL_DATA" "$VOL_OUT" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--- $*"; }

psql_db() { docker exec -i "$DB" psql -U odoo -X -q -v ON_ERROR_STOP=1 "$@"; }
out_ls() { docker run --rm -v "$VOL_OUT:/out:ro" "$HELPER" ls -1A /out; }
zip_ls() { docker run --rm -v "$VOL_OUT:/out:ro" --entrypoint unzip "$IMAGE" -Z1 "/out/$1"; }
run_backup() { # run_backup <password> [extra docker run args...]
  local pw="$1"; shift
  docker run --rm --network "$NET" \
    -v "$VOL_DATA:/odoo-data:ro" -v "$VOL_OUT:/backups" \
    -e PGHOST="$DB" -e PGUSER=odoo -e PGPASSWORD="$pw" -e RETENTION_DAYS=3 -e TZ=Asia/Jakarta \
    "$@" "$IMAGE" backup
}

step "start PostgreSQL $PG_MAJOR and a fake Odoo container"
docker network create "$NET" >/dev/null
docker volume create "$VOL_DATA" >/dev/null
docker volume create "$VOL_OUT" >/dev/null
docker run -d --name "$DB" --network "$NET" --network-alias db \
  -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD="$PASS" "postgres:${PG_MAJOR}-alpine" >/dev/null
# Like the official odoo image: DB settings in HOST/USER/PASSWORD, data_dir on a volume.
docker run -d --name "$ODOO" --network "$NET" \
  -e HOST=db -e USER=odoo -e PASSWORD="$PASS" -v "$VOL_DATA:/var/lib/odoo" "$HELPER" sleep 3600 >/dev/null
for _ in $(seq 60); do
  docker exec "$DB" pg_isready -h 127.0.0.1 -U odoo -q && break
  sleep 1
done
docker exec "$DB" pg_isready -h 127.0.0.1 -U odoo -q || fail "PostgreSQL did not start"

step "seed databases, filestore and old backups"
psql_db -d postgres -c "CREATE DATABASE shop" -c "CREATE DATABASE shop_test" -c "CREATE DATABASE other"
psql_db -d shop -c "CREATE TABLE ir_attachment (id serial PRIMARY KEY, store_fname text)" \
  -c "INSERT INTO ir_attachment (store_fname) VALUES ('ab/abc123'), ('cd/cdef45')"
# shop and shop_test have a filestore; "other" has none; "ghost" has a folder but no database.
docker run --rm -v "$VOL_DATA:/data" "$HELPER" sh -c '
  mkdir -p /data/filestore/shop/ab /data/filestore/shop/cd /data/filestore/shop_test/ef /data/filestore/ghost
  echo one > /data/filestore/shop/ab/abc123
  echo two > /data/filestore/shop/cd/cdef45
  echo three > /data/filestore/shop_test/ef/ef0001
  mkdir -p /data/sessions && echo x > /data/sessions/s1'
docker run --rm -v "$VOL_OUT:/out" "$HELPER" sh -c '
  touch -d "2020-01-01 00:00:00" /out/shop_20200101_000000.zip /out/shop_test_20200101_000000.zip
  touch /out/notes.txt'

step "explicit DB_NAME=shop"
run_backup "$PASS" -e DB_NAME=shop
files="$(out_ls)"
grep -qx 'shop_20200101_000000.zip' <<< "$files" && fail "retention did not remove the old shop backup"
grep -qx 'shop_test_20200101_000000.zip' <<< "$files" || fail "retention for shop removed a shop_test backup"
grep -qx 'notes.txt' <<< "$files" || fail "retention removed an unrelated file"
zip="$(grep -E '^shop_[0-9]{8}_[0-9]{6}\.zip$' <<< "$files" | head -n1 || true)"
[[ -n "$zip" ]] || fail "no shop zip was created: $files"

step "zip layout of $zip"
expected=$'dump.sql\nfilestore/\nfilestore/ab/\nfilestore/ab/abc123\nfilestore/cd/\nfilestore/cd/cdef45'
actual="$(zip_ls "$zip")"
[[ "$(sort <<< "$actual")" == "$(sort <<< "$expected")" ]] || fail "unexpected zip content:
$actual"

step "dump.sql loads into a new database"
psql_db -d postgres -c "CREATE DATABASE restored"
docker run --rm -v "$VOL_OUT:/out:ro" --entrypoint unzip "$IMAGE" -p "/out/$zip" dump.sql | psql_db -d restored >/dev/null
[[ "$(psql_db -d restored -At -c 'SELECT count(*) FROM ir_attachment')" == 2 ]] || fail "restored ir_attachment row count is wrong"

step "auto-detect (DB_NAME empty)"
run_backup "$PASS"
files="$(out_ls)"
grep -qE '^shop_test_[0-9]{8}_[0-9]{6}\.zip$' <<< "$files" || fail "auto-detect skipped shop_test"
grep -qx 'shop_test_20200101_000000.zip' <<< "$files" && fail "retention did not remove the old shop_test backup"
grep -qE '^(other|ghost|restored)_' <<< "$files" && fail "auto-detect backed up a database without filestore, or a folder without database"
[[ "$(grep -cE '^shop_[0-9]{8}_[0-9]{6}\.zip$' <<< "$files")" == 2 ]] || fail "expected two shop backups"

step "failures exit non-zero and leave nothing behind"
run_backup "wrong-password" -e DB_NAME=shop >/dev/null 2>&1 && fail "wrong password did not fail"
run_backup "$PASS" -e DB_NAME=ghost >/dev/null 2>&1 && fail "missing database did not fail"
grep -qE '^\.(work-|.*\.partial$)' <<< "$(out_ls)" && fail "a failed run left temporary files"

step "cron mode: crontab + env snapshot work with an empty environment"
docker run -d --name "$CRON" --network "$NET" \
  -v "$VOL_DATA:/odoo-data:ro" -v "$VOL_OUT:/backups" \
  -e PGHOST="$DB" -e PGUSER=odoo -e PGPASSWORD="$PASS" -e DB_NAME=shop_test \
  -e CRON_SCHEDULE="30 2 * * 1" -e TZ=Asia/Jakarta "$IMAGE" >/dev/null
sleep 2
[[ "$(docker inspect -f '{{.State.Running}}' "$CRON")" == true ]] || { docker logs "$CRON"; fail "cron container is not running"; }
docker exec "$CRON" cat /etc/crontabs/root | grep -q '^30 2 \* \* 1 \. /run/odoo-backup.env && /usr/local/bin/odoo-backup' \
  || fail "crontab does not match CRON_SCHEDULE"
# env -i mimics crond: the job only has what the snapshot gives it.
docker exec "$CRON" env -i /bin/sh -c '. /run/odoo-backup.env && /usr/local/bin/odoo-backup' \
  || fail "backup from the env snapshot failed"

step "tools/discover.sh finds the stack values"
found="$("$ROOT/tools/discover.sh" "$ODOO")"
for want in "PGHOST=db" "PGPORT=5432" "PGUSER=odoo" "PGPASSWORD=" "ODOO_DATA_VOLUME=$VOL_DATA" "DB_NETWORK=$NET" "DB_NAME="; do
  grep -qx -- "$want" <<< "$found" || fail "discover.sh: missing '$want' in:
$found"
done
grep -qE "^IMAGE=.*:pg${PG_MAJOR}\$" <<< "$found" || fail "discover.sh: IMAGE tag is not pg$PG_MAJOR"
grep -qF -- "$PASS" <<< "$found" && fail "discover.sh printed the password"

step "tools/restore.sh restores into a new database + filestore"
docker run --rm -v "$VOL_OUT:/out:ro" "$HELPER" cat "/out/$zip" > "$TMPD/backup.zip"
"$ROOT/tools/restore.sh" "$TMPD/backup.zip" shop_copy "$ODOO" "$DB" >/dev/null
[[ "$(psql_db -d shop_copy -At -c 'SELECT count(*) FROM ir_attachment')" == 2 ]] || fail "restore.sh: wrong row count"
[[ "$(docker exec "$ODOO" cat /var/lib/odoo/filestore/shop_copy/ab/abc123)" == one ]] || fail "restore.sh: filestore not copied"
"$ROOT/tools/restore.sh" "$TMPD/backup.zip" shop_copy "$ODOO" "$DB" >/dev/null 2>&1 && fail "restore.sh overwrote an existing database"

echo "PASS: all smoke checks"
