#!/usr/bin/env bash
set -euo pipefail

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

# package behavior
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-true}"   # true|false
AUTO_APT_UPDATE="${AUTO_APT_UPDATE:-true}"       # true|false (for apt)
AUTO_APT_UPGRADE="${AUTO_APT_UPGRADE:-false}"    # true|false (for apt)

UPDATED_APT="false"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run as root: sudo bash install.sh"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_apt_update_once() {
  if [ "$UPDATED_APT" = "true" ]; then
    return 0
  fi
  if [ "$AUTO_APT_UPDATE" = "true" ]; then
    info "Running apt-get update ..."
    apt-get update -y
  else
    info "Skip apt-get update (AUTO_APT_UPDATE=false)"
  fi
  UPDATED_APT="true"
}

install_with_apt() {
  local pkg="$1"
  run_apt_update_once
  info "Installing package via apt: $pkg"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

install_with_dnf() {
  local pkg="$1"
  info "Installing package via dnf: $pkg"
  dnf install -y "$pkg"
}

install_with_yum() {
  local pkg="$1"
  info "Installing package via yum: $pkg"
  yum install -y "$pkg"
}

install_pkg() {
  local apt_pkg="$1" dnf_pkg="$2" yum_pkg="$3"
  if has_cmd apt-get; then
    install_with_apt "$apt_pkg"
  elif has_cmd dnf; then
    install_with_dnf "$dnf_pkg"
  elif has_cmd yum; then
    install_with_yum "$yum_pkg"
  else
    die "No supported package manager found (apt-get/dnf/yum)."
  fi
}

ensure_dependencies() {
  if [ "$AUTO_INSTALL_DEPS" != "true" ]; then
    info "Skip dependency auto-install (AUTO_INSTALL_DEPS=false)"
    return 0
  fi

  info "Checking runtime dependencies..."

  # Need one downloader: curl or wget
  if ! has_cmd curl && ! has_cmd wget; then
    info "Neither curl nor wget found, trying to install curl..."
    install_pkg "curl" "curl" "curl"
  fi

  # Need crontab command
  if ! has_cmd crontab; then
    info "crontab not found, trying to install cron package..."
    # Debian/Ubuntu: cron, RHEL/Fedora: cronie
    if has_cmd apt-get; then
      install_pkg "cron" "cronie" "cronie"
    else
      install_pkg "cronie" "cronie" "cronie"
    fi
  fi

  if [ "$AUTO_APT_UPGRADE" = "true" ] && has_cmd apt-get; then
    run_apt_update_once
    info "Running apt-get upgrade ..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi

  # hard check
  has_cmd curl || has_cmd wget || die "Need curl or wget."
  has_cmd crontab || die "Need crontab command."
}

download() {
  local url="$1"
  local out="$2"
  if has_cmd curl; then
    curl -fsSL --max-time 30 "$url" -o "$out"
  elif has_cmd wget; then
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
  trap "rm -f '$tmp'" EXIT

  fetch_script "$tmp"
  # sanity check
  grep -q "Cloudflare DDNS" "$tmp" || warn "downloaded script doesn't contain expected banner (still installing)."

  install -m 0755 "$tmp" "$DDNS_BIN"

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

  local current
  current="$(crontab -l 2>/dev/null || true)"

  local cleaned
  cleaned="$(echo "$current" | grep -v -F "$DDNS_BIN" || true)"

  if echo "$current" | grep -Fq "$CRON_CMD"; then
    info "Cron already contains cf-ddns job. Skip."
    return 0
  fi

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
  if ( cd "$BIN_DIR" && "$DDNS_BIN" --run ); then
    info "Done. Logs: ${LOG_FILE}"
  else
    warn "Initial run failed (network/API may be temporarily unavailable)."
    warn "Installer will continue. You can retry manually: ${DDNS_BIN} --run"
  fi
}

print_next_steps() {
  cat <<EOF2

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

EOF2
}

main() {
  need_root
  ensure_dependencies
  ensure_log_file
  install_ddns
  setup_config_if_missing
  install_cron
  run_once
  print_next_steps
}

main "$@"
