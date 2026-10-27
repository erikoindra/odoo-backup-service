#!/usr/bin/env bash
# Container entrypoint for odoo-docker-backup.
#   cron (default)  install the crontab from CRON_SCHEDULE and run crond in the foreground
#   backup [...]    run one backup now and exit (e.g. docker run --rm IMAGE backup)
#   anything else   exec it as-is (e.g. sh)
set -Eeuo pipefail

ENV_SNAPSHOT=/run/odoo-backup.env

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

is_true() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# crond starts jobs with an almost empty environment, so a cron job would not
# see PGHOST, PGPASSWORD, ... Save the variables the backup needs in a file the
# job sources first. Values are single-quoted so any character survives.
save_env() {
  local var value sq="'" esc="'\\''"
  (umask 077 && : > "$ENV_SNAPSHOT")
  while IFS= read -r var; do
    case "$var" in
      PATH | TZ | LANG | PG* | DB_NAME | BACKUP_* | FILESTORE_ROOT | RETENTION_DAYS | MIN_FREE_MB | ODOO_BACKUP_*)
        value="${!var}"
        printf "export %s='%s'\n" "$var" "${value//$sq/$esc}" >> "$ENV_SNAPSHOT"
        ;;
    esac
  done < <(compgen -e)
}

install_crontab() {
  local schedule="${CRON_SCHEDULE:-0 2 * * *}" fields
  read -r -a fields <<< "$schedule"
  (( ${#fields[@]} == 5 )) || die "CRON_SCHEDULE needs 5 fields (minute hour day month weekday), got '$schedule'"
  mkdir -p /etc/crontabs
  # Job output goes to PID 1's stdout/stderr, i.e. the container log.
  printf '%s . %s && /usr/local/bin/odoo-backup >/proc/1/fd/1 2>/proc/1/fd/2\n' \
    "${fields[*]}" "$ENV_SNAPSHOT" > /etc/crontabs/root
}

case "${1:-cron}" in
  cron)
    save_env
    install_crontab
    log "odoo-docker-backup ${ODOO_BACKUP_VERSION:-dev}: schedule '${CRON_SCHEDULE:-0 2 * * *}' (TZ=${TZ:-UTC}), retention ${RETENTION_DAYS:-3} day(s), target ${BACKUP_DIR:-/backups}"
    log "run a backup now with: docker exec <container> odoo-backup"
    if is_true "${RUN_ON_START:-false}"; then
      log "RUN_ON_START is on: running one backup now"
      /usr/local/bin/odoo-backup || log "WARN: startup backup failed; the schedule stays active"
    fi
    exec crond -f -d 8
    ;;
  backup)
    shift
    exec /usr/local/bin/odoo-backup "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
