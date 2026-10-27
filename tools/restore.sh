#!/usr/bin/env bash
# Restore a backup zip into a NEW database + filestore, on a Docker host where
# Odoo and PostgreSQL run in containers. It never overwrites or deletes
# anything: it stops if the database or its filestore folder already exists,
# and if a step fails it tells you what it created so you can inspect it.
#
#   tools/restore.sh <backup.zip> <new-db-name> <odoo-container> <db-container>
#
# The DB user comes from the Odoo container (odoo.conf db_user, then env USER),
# or set PGUSER. psql runs inside the DB container over its local socket; set
# PGPASSWORD if that socket asks for a password. Needs: docker, unzip.
set -Eeuo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <backup.zip> <new-db-name> <odoo-container> <db-container>" >&2
  exit 2
fi
zip="$1" newdb="$2" odoo="$3" dbc="$4"

need_docker
command -v unzip >/dev/null || die "unzip not found on this host"
[[ -r "$zip" ]] || die "cannot read $zip"
[[ "$newdb" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid database name: $newdb"
for c in "$odoo" "$dbc"; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] || die "container is not running: $c"
done
unzip -Z1 "$zip" | grep -qx 'dump.sql' || die "$zip has no dump.sql at its top level"

load_odoo_conf "$odoo"
pguser="${PGUSER:-$(odoo_setting "$odoo" db_user USER odoo)}"
pghost="$(odoo_setting "$odoo" db_host HOST db)"
data_dir="$(odoo_data_dir)"
target="$data_dir/filestore/$newdb"

# -e PGPASSWORD passes the host value only when it is set
psql_in() { docker exec -i -e PGPASSWORD "$dbc" psql -X -q -v ON_ERROR_STOP=1 -U "$pguser" "$@"; }

exists="$(psql_in -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$newdb'")" \
  || die "cannot connect to PostgreSQL in $dbc as $pguser"
[[ -z "$exists" ]] || die "database $newdb already exists"
if docker exec "$odoo" test -e "$target"; then die "filestore folder already exists: $odoo:$target"; fi

tmp="$(mktemp -d)"
step="extract"
on_exit() {
  local rc=$?
  rm -rf "$tmp"
  if (( rc != 0 )); then
    warn "restore failed during: $step"
    case "$step" in
      load | filestore)
        warn "database $newdb was created in $dbc but is incomplete; check it, then remove it yourself if needed" ;;
    esac
    if [[ "$step" == filestore ]]; then
      warn "the filestore folder $odoo:$target may be incomplete"
    fi
  fi
}
trap on_exit EXIT

log "extracting $(basename "$zip")"
unzip -q "$zip" -d "$tmp"

step="createdb"
log "creating database $newdb (owner $pguser)"
docker exec -e PGPASSWORD "$dbc" createdb -U "$pguser" "$newdb"
step="load"
log "loading dump.sql"
psql_in -d "$newdb" < "$tmp/dump.sql" > /dev/null

if [[ -d "$tmp/filestore" ]]; then
  step="filestore"
  # shellcheck disable=SC2016 # expanded inside the container
  owner="$(docker exec "$odoo" sh -c 'echo "$(id -u):$(id -g)"')"
  log "copying filestore to $odoo:$target"
  docker exec -u 0 "$odoo" mkdir -p "$data_dir/filestore"
  docker cp "$tmp/filestore" "$odoo:$target" > /dev/null
  docker exec -u 0 "$odoo" chown -R "$owner" "$target"
else
  warn "the zip has no filestore/, so attachments stored on disk will be missing"
fi
step="done"

log "restored into database '$newdb'"
cat <<MSG
Next:
  - open it in Odoo (?db=$newdb, or adjust db_name / dbfilter in odoo.conf)
  - a copy of production? Neutralize it first so it sends no mail and runs no payments:
      docker exec $odoo odoo neutralize -d $newdb --db_host $pghost --db_user $pguser --db_password '<password>'
MSG
