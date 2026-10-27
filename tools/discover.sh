#!/usr/bin/env bash
# Print the stack variables for an existing Odoo container, ready to paste into
# Portainer or to save as an env file. Read-only: it only inspects containers,
# reads odoo.conf and lists the filestore. It never prints the DB password.
#
#   tools/discover.sh <odoo-container> > my-backup.env
#
# Run it on the Docker host (with sudo if your user is not in the docker group).
set -Eeuo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/erikoindra/odoo-backup-service}"

need_docker
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <odoo-container>" >&2
  echo "running containers that look like Odoo:" >&2
  docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($2) ~ /odoo/ {print "  " $1 "  (" $2 ")"}' >&2
  exit 2
fi
docker inspect "$1" >/dev/null 2>&1 || die "container not found: $1"
odoo="$(docker inspect -f '{{.Name}}' "$1")"
odoo="${odoo#/}"
[[ "$(docker inspect -f '{{.State.Running}}' "$odoo")" == true ]] \
  || warn "$odoo is not running: odoo.conf and the filestore cannot be read, defaults are shown"

load_odoo_conf "$odoo"
pghost="$(odoo_setting "$odoo" db_host HOST db)"
pgport="$(odoo_setting "$odoo" db_port PORT 5432)"
pguser="$(odoo_setting "$odoo" db_user USER odoo)"
data_dir="$(odoo_data_dir)"

# --- the mount that holds data_dir: the deepest mount point at or above it ---
best="" best_len=0
while IFS='|' read -r mtype mname msource mdest; do
  [[ -n "$mdest" ]] || continue
  if [[ "$data_dir" == "$mdest" || "$data_dir" == "$mdest"/* ]] && (( ${#mdest} > best_len )); then
    best="$mtype|$mname|$msource|$mdest"
    best_len=${#mdest}
  fi
done < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' "$odoo")

data_volume="" filestore_root=""
if [[ -z "$best" ]]; then
  warn "no volume holds $data_dir in $odoo, so the filestore only lives inside the container. Mount a volume at $data_dir first."
else
  IFS='|' read -r mtype mname msource mdest <<< "$best"
  rel="${data_dir#"$mdest"}"
  if [[ -n "$rel" ]]; then filestore_root="/odoo-data${rel}/filestore"; fi
  if [[ "$mtype" == volume ]]; then
    data_volume="$mname"
  else
    warn "$data_dir is a $mtype mount of $msource, not a named volume. In the compose file, replace the odoo_data volume with \"$msource:/odoo-data:ro\"."
  fi
fi

# --- the DB container: named or aliased PGHOST on one of Odoo's networks ---
mapfile -t odoo_nets < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$odoo" | sed '/^$/d')
db_container="" db_network=""
for net in "${odoo_nets[@]}"; do
  read -r -a members <<< "$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net")"
  for c in "${members[@]}"; do
    if [[ "$c" == "$odoo" ]]; then continue; fi
    aliases="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{join .Aliases \" \"}}{{end}}" "$c")"
    if [[ "$c" == "$pghost" || " $aliases " == *" $pghost "* ]]; then
      db_container="$c" db_network="$net"
      break 2
    fi
  done
done
if [[ -z "$db_container" ]]; then
  warn "no container named or aliased '$pghost' shares a network with $odoo. If PostgreSQL runs elsewhere, check PGHOST and pick a DB_NETWORK that can reach it."
  db_network="${odoo_nets[0]:-}"
fi

# --- PostgreSQL major version -> image tag ---
pg_major=""
if [[ -n "$db_container" ]]; then
  pg_major="$(container_env "$db_container" PG_MAJOR)"
  if [[ -z "$pg_major" ]]; then
    pg_major="$(docker exec "$db_container" postgres --version 2>/dev/null | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p' || true)"
  fi
fi
if [[ -z "$pg_major" ]]; then
  warn "PostgreSQL version unknown: check it and set the matching IMAGE tag (pg14 ... pg18)"
elif (( pg_major < 14 || pg_major > 18 )); then
  warn "PostgreSQL $pg_major has no image tag yet (pg14 ... pg18)"
fi

# --- databases that have a filestore ---
dbs=()
if [[ -n "$best" ]]; then
  mapfile -t dbs < <(docker exec "$odoo" ls -1 "$data_dir/filestore" 2>/dev/null || true)
fi
project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$odoo")"

echo "# odoo-backup-service settings discovered from Odoo container '$odoo'"
echo "# database container: ${db_container:-not found}, PostgreSQL ${pg_major:-unknown}"
echo "IMAGE=$IMAGE_REPO:pg${pg_major:-17}"
echo "PGHOST=$pghost"
echo "PGPORT=$pgport"
echo "PGUSER=$pguser"
echo "# fill in the database password yourself (this tool never prints it)"
echo "PGPASSWORD="
echo "ODOO_DATA_VOLUME=$data_volume"
echo "DB_NETWORK=$db_network"
if (( ${#dbs[@]} == 1 )); then
  echo "DB_NAME=${dbs[0]}"
else
  echo "# databases with a filestore: ${dbs[*]:-none found}. Empty DB_NAME backs up all of them."
  echo "DB_NAME="
fi
if [[ -n "$filestore_root" ]]; then echo "FILESTORE_ROOT=$filestore_root"; fi
echo "BACKUP_VOLUME=${project:-odoo}_backups"
echo "# schedule and retention (change TZ to your local zone, e.g. Asia/Jakarta)"
echo "CRON_SCHEDULE=0 2 * * *"
echo "TZ=UTC"
echo "RETENTION_DAYS=3"
