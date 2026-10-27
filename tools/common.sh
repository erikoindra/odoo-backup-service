# shellcheck shell=bash
# Shared helpers for tools/*.sh (sourced, not executed).
# They read how an Odoo container reaches its database the same way the official
# odoo image does: odoo.conf first, then the HOST / PORT / USER variables.

log() { echo ">> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null || die "docker CLI not found"
  docker info >/dev/null 2>&1 || die "cannot talk to Docker (try again with sudo)"
}

# container_env <container> <VAR>: value of VAR in the container's config
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p" | head -n1
}

# load_odoo_conf <odoo-container>: read odoo.conf into ODOO_CONF (empty if unreadable)
load_odoo_conf() {
  local rc
  rc="$(container_env "$1" ODOO_RC)"
  ODOO_CONF="$(docker exec "$1" cat "${rc:-/etc/odoo/odoo.conf}" 2>/dev/null || true)"
}

# conf_value <key>: last uncommented "key = value" in ODOO_CONF ("False" counts as unset)
conf_value() {
  local v
  v="$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" <<< "${ODOO_CONF:-}" | tail -n1 | sed -E 's/[[:space:]]+$//')"
  if [[ "$v" == "False" ]]; then v=""; fi
  printf '%s\n' "$v"
}

# odoo_setting <odoo-container> <conf-key> <env-var> <default>
odoo_setting() {
  local v
  v="$(conf_value "$2")"
  if [[ -z "$v" ]]; then v="$(container_env "$1" "$3")"; fi
  printf '%s\n' "${v:-$4}"
}

# odoo_data_dir: Odoo's data_dir from ODOO_CONF, without a trailing slash
odoo_data_dir() {
  local d
  d="$(conf_value data_dir)"
  d="${d:-/var/lib/odoo}"
  printf '%s\n' "${d%/}"
}
