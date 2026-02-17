#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/ike666888/DDNS"
RAW_BASE_MAIN="https://raw.githubusercontent.com/ike666888/DDNS/main"
RAW_BASE_MASTER="https://raw.githubusercontent.com/ike666888/DDNS/master"

BIN_DIR="/usr/local/bin"
DDNS_BIN="${BIN_DIR}/cf-ddns.sh"
CONF_FILE="${BIN_DIR}/cf-ddns.conf"
LOG_FILE="/var/log/cf-ddns.log"

# default cron: every 5 minutes
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
CRON_CMD="${DDNS_BIN} --run >> ${LOG_FILE} 2>&1"
CRON_LINE="${CRON_SCHEDULE} ${CRON_CMD}"
CRON_MARK="# cf-ddns (cloudflare ddns) managed by install.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run as root: sudo bash install.sh"
  fi
}

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    die "Need curl or wget to download files."
  fi
}

fetch_script() {
  local tmp="$1"
  # try main then master
  if download "${RAW_BASE_MAIN}/cf-ddns.sh" "$tmp"; then
    return 0
  fi
  download "${RAW_BASE_MASTER}/cf-ddns.sh" "$tmp"
}

ensure_log_file() {
  # create log file if not exists
  touch "$LOG_FILE"
  chmod 0644 "$LOG_FILE" || true
}

install_ddns() {
  info "Installing cf-ddns.sh to ${DDNS_BIN}"
  mkdir -p "$BIN_DIR"

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  fetch_script "$tmp"
  # sanity check
  grep -q "Cloudflare DDNS" "$tmp" || info "Warning: downloaded script doesn't contain expected banner (still installing)."

  install -m 0755 "$tmp" "$DDNS_BIN"

  # ensure config file lives alongside the script (script reads ./cf-ddns.conf by default)
  # Our interactive script saves config relative to its own directory if placed there.
  # We'll run setup from BIN_DIR so it writes ${BIN_DIR}/cf-ddns.conf.
  info "Installed: ${DDNS_BIN}"
}

setup_config_if_missing() {
  if [ -f "$CONF_FILE" ]; then
    info "Config exists: ${CONF_FILE} (skip interactive setup)"
    return 0
  fi

  info "No config found. Launching interactive setup..."
  info "Config will be saved to: ${CONF_FILE}"
  ( cd "$BIN_DIR" && "$DDNS_BIN" --setup )
}

install_cron() {
  info "Installing cron job (idempotent)..."

  # Ensure crontab exists and avoid duplicates
  local current
  current="$(crontab -l 2>/dev/null || true)"

  # Remove any old lines for cf-ddns.sh (optional cleanup), then add ours once
  local cleaned
  cleaned="$(echo "$current" | grep -v -F "$DDNS_BIN" || true)"

  # If already has our exact command, skip
  if echo "$current" | grep -Fq "$CRON_CMD"; then
    info "Cron already contains cf-ddns job. Skip."
    return 0
  fi

  # Write new crontab
  {
    echo "$cleaned"
    echo "$CRON_MARK"
    echo "$CRON_LINE"
  } | crontab -

  info "Cron installed:"
  info "  ${CRON_LINE}"
}

run_once() {
  info "Running once now..."
  ( cd "$BIN_DIR" && "$DDNS_BIN" --run )
  info "Done. Logs: ${LOG_FILE}"
}

print_next_steps() {
  cat <<EOF

All set ✅

Binary:
  ${DDNS_BIN}

Config (DO NOT COMMIT to GitHub):
  ${CONF_FILE}

Cron:
  ${CRON_LINE}

View logs:
  tail -n 50 ${LOG_FILE}

If you need to reconfigure:
  cd ${BIN_DIR} && ${DDNS_BIN} --setup

EOF
}

main() {
  need_root
  ensure_log_file
  install_ddns
  setup_config_if_missing
  install_cron
  run_once
  print_next_steps
}

main "$@"
