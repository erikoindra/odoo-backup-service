#!/usr/bin/env bash
# odoo-backup: back up Odoo database(s) into Odoo-compatible zip files.
#
# One zip per database:
#   <BACKUP_PREFIX><db>_<YYYYmmdd_HHMMSS>.zip
#   ├── dump.sql     pg_dump --no-owner, plain SQL (same as Odoo's own backup)
#   └── filestore/   contents of <FILESTORE_ROOT>/<db>/
#
# Configured through environment variables (see README.md).
# Exit code: 0 when every database succeeded, 1 otherwise.
set -Eeuo pipefail
umask 077 # backups contain the whole database: owner-only by default

BACKUP_DIR="${BACKUP_DIR:-/backups}"
FILESTORE_ROOT="${FILESTORE_ROOT:-/odoo-data/filestore}"
BACKUP_PREFIX="${BACKUP_PREFIX:-}"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
DB_NAME="${DB_NAME:-}"
export PGPORT="${PGPORT:-5432}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ---- settings -------------------------------------------------------------
[[ -n "${PGHOST:-}" ]] || die "PGHOST is not set"
[[ -n "${PGUSER:-}" ]] || die "PGUSER is not set"
if [[ -n "${PGPASSWORD_FILE:-}" ]]; then
  [[ -r "$PGPASSWORD_FILE" ]] || die "PGPASSWORD_FILE is not readable: $PGPASSWORD_FILE"
  PGPASSWORD="$(<"$PGPASSWORD_FILE")"
  export PGPASSWORD
fi
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS must be a whole number, got '$RETENTION_DAYS'"
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die "MIN_FREE_MB must be a whole number, got '$MIN_FREE_MB'"
[[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] || die "BACKUP_DIR is not a writable directory: $BACKUP_DIR"
[[ -d "$FILESTORE_ROOT" ]] || die "FILESTORE_ROOT not found: $FILESTORE_ROOT (is the Odoo data volume mounted?)"

log "odoo-backup ${ODOO_BACKUP_VERSION:-dev} start: $PGUSER@$PGHOST:$PGPORT, retention ${RETENTION_DAYS} day(s)"

# ---- one run at a time (also across containers sharing BACKUP_DIR) --------
exec 9>"$BACKUP_DIR/.odoo-backup.lock"
flock -n 9 || die "another backup is already running"

# We hold the lock, so anything left here comes from a run that was killed.
find "$BACKUP_DIR" -maxdepth 1 \( -name '.work-*' -o -name '.*.zip.partial' \) -exec rm -rf {} \;

# ---- preflight ------------------------------------------------------------
pg_isready -q -t 15 || die "PostgreSQL is not accepting connections at $PGHOST:$PGPORT"

server_num="$(psql -X -At -d "${PGDATABASE:-postgres}" -c 'SHOW server_version_num')" \
  || die "cannot connect as '$PGUSER' (check PGUSER / PGPASSWORD)"
server_major=$(( server_num / 10000 ))
client_major="$(pg_dump --version | sed -E 's/.* ([0-9]+)\..*/\1/')"
if (( server_major > client_major )); then
  die "PostgreSQL server is $server_major but this image has pg_dump $client_major; use the pg$server_major image tag"
elif (( server_major < client_major )); then
  log "WARN: pg_dump $client_major is newer than server $server_major; dump.sql may not load into a PostgreSQL $server_major server (use the pg$server_major image tag)"
fi

free_mb="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
(( free_mb >= MIN_FREE_MB )) || die "only ${free_mb} MB free in $BACKUP_DIR (MIN_FREE_MB=$MIN_FREE_MB)"

# ---- which databases ------------------------------------------------------
dbs=()
if [[ -n "$DB_NAME" ]]; then
  read -r -a dbs <<< "${DB_NAME//,/ }"
else
  # Auto-detect: every real database that also has a filestore folder.
  all="$(psql -X -At -v ON_ERROR_STOP=1 -d "${PGDATABASE:-postgres}" -c \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' ORDER BY 1")" \
    || die "cannot list databases as '$PGUSER'"
  while IFS= read -r d; do
    if [[ -n "$d" && -d "$FILESTORE_ROOT/$d" ]]; then
      dbs+=("$d")
    fi
  done <<< "$all"
  (( ${#dbs[@]} > 0 )) || die "auto-detect found no database with a folder in $FILESTORE_ROOT; set DB_NAME"
  log "auto-detected database(s): ${dbs[*]}"
fi
(( ${#dbs[@]} > 0 )) || die "DB_NAME is set but contains no database name"

# ---- back up one database (runs in a subshell: own traps, own failure) ----
backup_one() (
  set -Eeuo pipefail
  db="$1"
  src="$FILESTORE_ROOT/$db"
  name="${BACKUP_PREFIX}${db}_$(date +%Y%m%d_%H%M%S).zip"
  final="$BACKUP_DIR/$name"
  partial="$BACKUP_DIR/.$name.partial"

  [[ -d "$src" ]] || die "[$db] filestore folder not found: $src"

  work="$(mktemp -d "$BACKUP_DIR/.work-XXXXXX")"
  trap 'rm -rf -- "$work" "$partial"' EXIT
  trap 'log "ERROR: [$db] command failed (exit $?): $BASH_COMMAND" >&2' ERR

  # 1) Database first. A file written after the dump only becomes an orphan
  #    (harmless); copying the filestore first could miss files the dump references.
  log "[$db] dumping database"
  pg_dump --no-owner --format=plain --file="$work/dump.sql" "$db"
  grep -q 'PostgreSQL database dump' "$work/dump.sql" || die "[$db] dump.sql does not look like a pg_dump file"
  log "[$db] dump.sql $(du -h "$work/dump.sql" | cut -f1)"

  # 2) Filestore through a symlink: zip reads it straight from the read-only mount.
  ln -s "$src" "$work/filestore"
  log "[$db] zipping dump.sql + filestore/"
  (cd "$work" && zip -q -r "$partial" dump.sql filestore)

  # 3) Verify before publishing the file under its final name.
  unzip -tqq "$partial" || die "[$db] zip integrity check failed"
  layout="$(unzip -Z1 "$partial" | cut -d/ -f1 | sort -u | tr '\n' ' ')"
  [[ "$layout" == "dump.sql filestore " ]] || die "[$db] unexpected zip layout: $layout"
  nfiles="$(unzip -Z1 "$partial" | grep -c '^filestore/.*[^/]$' || true)"

  mv -f "$partial" "$final"
  log "[$db] OK $name ($(du -h "$final" | cut -f1), $nfiles filestore files)"

  # 4) Retention, only after a successful backup so the newest one always stays.
  #    The exact name pattern keeps db "shop" from touching "shop_test" backups.
  if (( RETENTION_DAYS > 0 )); then
    find "$BACKUP_DIR" -maxdepth 1 -type f \
      -name "${BACKUP_PREFIX}${db}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].zip" \
      -mmin +$(( RETENTION_DAYS * 1440 )) |
      while IFS= read -r old; do
        rm -f -- "$old"
        log "[$db] retention: removed $(basename "$old")"
      done
  fi
)

# ---- main -----------------------------------------------------------------
# errexit off here so one failing database does not stop the others;
# backup_one turns it back on inside its own subshell.
failed=0
set +e
for db in "${dbs[@]}"; do
  backup_one "$db"
  rc=$?
  (( rc == 0 )) || failed=$(( failed + 1 ))
done
set -e

(( failed == 0 )) || die "$failed of ${#dbs[@]} database(s) failed"
log "finished: ${#dbs[@]} database(s) backed up to $BACKUP_DIR"
