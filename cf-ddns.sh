#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Cloudflare DDNS (Interactive + Token) - suitable for dynamic home IP (e.g., HiNet)
# - First run: interactive setup, writes ./cf-ddns.conf
# - Next runs: reads config and updates DNS when IP changes
#
# Usage:
#   ./cf-ddns.sh               # run (will prompt if config missing)
#   ./cf-ddns.sh --setup       # force interactive setup
#   ./cf-ddns.sh --run         # run update using existing config
#   ./cf-ddns.sh --print       # print loaded config (token masked)
#
# Recommended cron (every 5 min):
#   */5 * * * * /path/cf-ddns.sh --run >/dev/null 2>&1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cf-ddns.conf"
CACHE_DIR="${HOME:-/tmp}"

# Defaults
CF_API_TOKEN="${CF_API_TOKEN:-}"
CFZONE_ID="${CFZONE_ID:-}"
CFZONE_NAME="${CFZONE_NAME:-}"
CFRECORD_NAME="${CFRECORD_NAME:-}"
CFSUBDOMAIN="${CFSUBDOMAIN:-}"
CFRECORD_TYPE="${CFRECORD_TYPE:-A}"   # A | AAAA | BOTH
CFTTL="${CFTTL:-120}"
FORCE="${FORCE:-false}"               # true | false
PROXIED="${PROXIED:-keep}"            # keep | true | false

WANIPSITE_V4="${WANIPSITE_V4:-https://api.ipify.org}"
WANIPSITE_V6="${WANIPSITE_V6:-https://api64.ipify.org}"
CURL_OPTS=(-fsS --max-time 12 --retry 2 --retry-delay 1 --retry-all-errors)

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

mask_token() {
  local t="$1"
  if [ "${#t}" -le 8 ]; then echo "********"; return; fi
  echo "${t:0:4}********${t: -4}"
}

cache_key() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

is_ipv6() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$ip" == *:* ]] || return 1
  return 0
}

json_get_first_string() {
  local json="$1" key="$2"
  echo "$json" | tr '\n' ' ' | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" | head -n 1
}

cf_api() {
  local method="$1" url="$2" data="${3:-}"
  local auth_header=( -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" )

  if [ -n "$data" ]; then
    if curl "${CURL_OPTS[@]}" -X "$method" "$url" "${auth_header[@]}" --data "$data"; then
      return 0
    fi
    warn "Cloudflare API request failed, retrying with HTTP/1.1 ..."
    curl "${CURL_OPTS[@]}" --http1.1 -X "$method" "$url" "${auth_header[@]}" --data "$data"
  else
    if curl "${CURL_OPTS[@]}" -X "$method" "$url" "${auth_header[@]}"; then
      return 0
    fi
    warn "Cloudflare API request failed, retrying with HTTP/1.1 ..."
    curl "${CURL_OPTS[@]}" --http1.1 -X "$method" "$url" "${auth_header[@]}"
  fi
}



validate_api_token() {
  local verify_json ok status
  verify_json="$(cf_api GET "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null || true)"
  [ -n "$verify_json" ] || return 1

  if has_cmd jq; then
    ok="$(echo "$verify_json" | jq -r '.success // false')"
    status="$(echo "$verify_json" | jq -r '.result.status // empty')"
  else
    if printf '%s' "$verify_json" | grep -q '"success":true'; then
      ok="true"
    else
      ok="false"
    fi
    status="$(json_get_first_string "$verify_json" "status")"
  fi

  [ "$ok" = "true" ] || return 1
  [ -z "$status" ] || [ "$status" = "active" ] || return 1
  return 0
}


get_wan_ip_v4() { curl "${CURL_OPTS[@]}" "$WANIPSITE_V4"; }
get_wan_ip_v6() { curl "${CURL_OPTS[@]}" "$WANIPSITE_V6"; }

normalize_fqdn() {
  # If user enters prefix only, make it FQDN: prefix.zone
  if [ -z "$CFSUBDOMAIN" ]; then
    if [[ "$CFRECORD_NAME" != *".${CFZONE_NAME}" ]]; then
      CFRECORD_NAME="${CFRECORD_NAME}.${CFZONE_NAME}"
    fi
    return
  fi

  if [ "$CFSUBDOMAIN" = "@" ]; then
    CFRECORD_NAME="$CFZONE_NAME"
    return
  fi

  CFRECORD_NAME="${CFSUBDOMAIN}.${CFZONE_NAME}"
}

validate_config() {
  [ -n "$CF_API_TOKEN" ] || die "Missing CF_API_TOKEN"
  [ -n "$CFZONE_NAME" ]  || die "Missing CFZONE_NAME"
  [ -n "$CFRECORD_NAME" ]|| die "Missing CFRECORD_NAME"

  case "$CFRECORD_TYPE" in
    A|AAAA|BOTH) : ;;
    *) die "CFRECORD_TYPE must be A|AAAA|BOTH" ;;
  esac

  [ "$CFTTL" -ge 120 ] 2>/dev/null || die "CFTTL too small (min 120)"
  [ "$CFTTL" -le 86400 ] 2>/dev/null || die "CFTTL too large (max 86400)"

  case "$FORCE" in true|false) : ;; *) die "FORCE must be true|false" ;; esac
  case "$PROXIED" in keep|true|false) : ;; *) die "PROXIED must be keep|true|false" ;; esac
}

write_config() {
  umask 077
  cat > "$CONF_FILE" <<EOF
# Cloudflare DDNS config (DO NOT COMMIT to GitHub)
CF_API_TOKEN='$CF_API_TOKEN'
CFZONE_ID='$CFZONE_ID'
CFZONE_NAME='$CFZONE_NAME'
CFSUBDOMAIN='$CFSUBDOMAIN'
CFRECORD_NAME='$CFRECORD_NAME'
CFRECORD_TYPE='$CFRECORD_TYPE'
CFTTL='$CFTTL'
FORCE='$FORCE'
PROXIED='$PROXIED'
WANIPSITE_V4='$WANIPSITE_V4'
WANIPSITE_V6='$WANIPSITE_V6'
EOF
  info "Config saved: $CONF_FILE"
  info "Tip: add this to .gitignore => cf-ddns.conf"
}

load_config_if_exists() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi
}

prompt() {
  local label="$1" default="${2:-}" secret="${3:-false}"
  local val=""
  local input_fd="/dev/stdin"
  if [ -r /dev/tty ]; then
    input_fd="/dev/tty"
  fi

  if [ "$secret" = "true" ]; then
    if [ -n "$default" ]; then
      read -r -s -p "$label (留空保持现有): " val < "$input_fd"; echo
      [ -z "$val" ] && val="$default"
    else
      read -r -s -p "$label: " val < "$input_fd"; echo
    fi
  else
    if [ -n "$default" ]; then
      read -r -p "$label [$default]: " val < "$input_fd"
      [ -z "$val" ] && val="$default"
    else
      read -r -p "$label: " val < "$input_fd"
    fi
  fi
  echo "$val"
}


interactive_setup() {
  info "Cloudflare DDNS 交互配置"
  info "（建议使用 Zone -> DNS -> Edit 的 API Token；不要把 token 提交到 GitHub）"
  load_config_if_exists

  CF_API_TOKEN="$(prompt "1) 输入 CF API Token（不是 Global API Key）" "${CF_API_TOKEN:-}" true)"
  while [ -z "$CF_API_TOKEN" ]; do
    warn "CF_API_TOKEN 不能为空"
    CF_API_TOKEN="$(prompt "1) 输入 CF API Token（不是 Global API Key）" "${CF_API_TOKEN:-}" true)"
  done
  CFZONE_ID="$(prompt "2) 输入 Zone ID（可选，留空自动查询；不要填账户ID）" "${CFZONE_ID:-}")"
  CFZONE_NAME="$(prompt "3) 输入主域名 (例: example.com)" "${CFZONE_NAME:-}")"
  CFSUBDOMAIN="$(prompt "4) 输入二级域名前缀 (例: home，根域名填 @)" "${CFSUBDOMAIN:-}")"
  CFRECORD_TYPE="$(prompt "5) 记录类型 A / AAAA / BOTH" "${CFRECORD_TYPE:-A}")"
  CFTTL="$(prompt "6) TTL 秒数 (120-86400)" "${CFTTL:-120}")"
  FORCE="$(prompt "7) 是否强制更新 true/false" "${FORCE:-false}")"
  PROXIED="$(prompt "8) 是否开启代理 keep/true/false (一般 keep)" "${PROXIED:-keep}")"

  # Normalize common user input forms
  CFRECORD_TYPE="$(echo "$CFRECORD_TYPE" | tr '[:lower:]' '[:upper:]')"
  FORCE="$(echo "$FORCE" | tr '[:upper:]' '[:lower:]')"
  PROXIED="$(echo "$PROXIED" | tr '[:upper:]' '[:lower:]')"

  normalize_fqdn
  validate_config

  info "正在校验 API Token..."
  validate_api_token || die "CF_API_TOKEN 无效或权限不足。请使用 API Token（Zone DNS Edit + Zone Read），不要填 Global API Key/账户ID。"

  info "将更新的记录：$CFRECORD_NAME  类型：$CFRECORD_TYPE  TTL：$CFTTL  PROXIED：$PROXIED"
  write_config
}

print_config() {
  load_config_if_exists
  [ -f "$CONF_FILE" ] || die "Config not found: $CONF_FILE"
  echo "CONF_FILE=$CONF_FILE"
  echo "CF_API_TOKEN=$(mask_token "${CF_API_TOKEN:-}")"
  echo "CFZONE_ID=${CFZONE_ID:-}"
  echo "CFZONE_NAME=${CFZONE_NAME:-}"
  echo "CFSUBDOMAIN=${CFSUBDOMAIN:-}"
  echo "CFRECORD_NAME=${CFRECORD_NAME:-}"
  echo "CFRECORD_TYPE=${CFRECORD_TYPE:-}"
  echo "CFTTL=${CFTTL:-}"
  echo "FORCE=${FORCE:-}"
  echo "PROXIED=${PROXIED:-}"
  echo "WANIPSITE_V4=${WANIPSITE_V4:-}"
  echo "WANIPSITE_V6=${WANIPSITE_V6:-}"
}

verify_zone_id() {
  local zid="$1" verify_json ok
  verify_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/$zid")" || return 1
  if has_cmd jq; then
    ok="$(echo "$verify_json" | jq -r '.success // false')"
  else
    if printf '%s' "$verify_json" | grep -q '"success":true'; then
      ok="true"
    else
      ok="false"
    fi
  fi
  [ "$ok" = "true" ]
}


get_zone_id() {
  if [ -n "$CFZONE_ID" ]; then
    if verify_zone_id "$CFZONE_ID"; then
      echo "$CFZONE_ID"
      return 0
    fi
    warn "Configured CFZONE_ID seems invalid (可能填成账户ID), fallback to zone-name lookup"
  fi

  local zone_json zone_id
  zone_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME")" || die "Zone query failed. 请确认 Token 权限正确，且 Zone ID 不是账户ID。"
  if has_cmd jq; then
    zone_id="$(echo "$zone_json" | jq -r '.result[0].id // empty')"
  else
    zone_id="$(json_get_first_string "$zone_json" "id")"
  fi
  [ -n "$zone_id" ] || die "Cannot find zone id. Response: $zone_json"
  echo "$zone_id"
}

get_record_id() {
  local zone_id="$1" rtype="$2"
  local rec_json rec_id
  rec_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$rtype&name=$CFRECORD_NAME")" || return 1
  if has_cmd jq; then
    rec_id="$(echo "$rec_json" | jq -r '.result[0].id // empty')"
  else
    rec_id="$(json_get_first_string "$rec_json" "id")"
  fi
  [ -n "$rec_id" ] || return 1
  echo "$rec_id"
}

create_record() {
  local zone_id="$1" rtype="$2" wan_ip="$3"
  local payload resp ok rec_id

  if [ "$PROXIED" = "keep" ]; then
    payload="$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s}' "$rtype" "$CFRECORD_NAME" "$wan_ip" "$CFTTL")"
  else
    payload="$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' "$rtype" "$CFRECORD_NAME" "$wan_ip" "$CFTTL" "$PROXIED")"
  fi

  resp="$(cf_api POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" "$payload")" || die "Create record request failed"
  if has_cmd jq; then
    ok="$(echo "$resp" | jq -r '.success // false')"
    rec_id="$(echo "$resp" | jq -r '.result.id // empty')"
  else
    if printf '%s' "$resp" | grep -q '"success":true'; then
      ok="true"
    else
      ok="false"
    fi
    rec_id="$(json_get_first_string "$resp" "id")"
  fi
  [ "$ok" = "true" ] || die "Create record failed. Response: $resp"
  [ -n "$rec_id" ] || die "Create record success but no id found. Response: $resp"
  echo "$rec_id"
}


get_record_current() {
  local zone_id="$1" record_id="$2"
  local rec_json
  rec_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id")" || die "Get record failed"
  echo "$rec_json"
}

update_record() {
  local zone_id="$1" record_id="$2" rtype="$3" wan_ip="$4"
  local payload resp ok

  # Build payload; optionally set proxied if user requests
  if [ "$PROXIED" = "keep" ]; then
    payload="{\"type\":\"$rtype\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$wan_ip\",\"ttl\":$CFTTL}"
  else
    payload="{\"type\":\"$rtype\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$wan_ip\",\"ttl\":$CFTTL,\"proxied\":$PROXIED}"
  fi

  resp="$(cf_api PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" "$payload")" || die "Update request failed"
  if has_cmd jq; then
    ok="$(echo "$resp" | jq -r '.success // false')"
  else
    ok="$(echo "$resp" | tr '\n' ' ' | grep -q '"success":true' && echo true || echo false)"
  fi
  [ "$ok" = "true" ] || die "Update failed. Response: $resp"
}

run_one() {
  local zone_id="$1" rtype="$2"
  local wan_ip old_ip ip_file rec_file record_id

  local ck; ck="$(cache_key "$CFRECORD_NAME")"
  ip_file="$CACHE_DIR/.cf-wan_ip_${ck}_${rtype}.txt"
  rec_file="$CACHE_DIR/.cf-rec_${ck}_${rtype}.txt"

  if [ "$rtype" = "A" ]; then
    wan_ip="$(get_wan_ip_v4)"; wan_ip="${wan_ip//$'\n'/}"
    is_ipv4 "$wan_ip" || die "Invalid IPv4 detected: '$wan_ip'"
  else
    wan_ip="$(get_wan_ip_v6)"; wan_ip="${wan_ip//$'\n'/}"
    is_ipv6 "$wan_ip" || die "Invalid IPv6 detected: '$wan_ip'"
  fi

  old_ip=""
  [ -f "$ip_file" ] && old_ip="$(cat "$ip_file" 2>/dev/null || true)"

  if [ "$wan_ip" = "$old_ip" ] && [ "$FORCE" = "false" ]; then
    echo "[$rtype] IP unchanged ($wan_ip), skip."
    return 0
  fi

  record_id=""
  if [ -f "$rec_file" ]; then
    record_id="$(cat "$rec_file" 2>/dev/null || true)"
  fi
  if [ -z "$record_id" ]; then
    record_id="$(get_record_id "$zone_id" "$rtype" || true)"
  fi

  if [ -z "$record_id" ]; then
    echo "[$rtype] Record not found, creating $CFRECORD_NAME -> $wan_ip"
    record_id="$(create_record "$zone_id" "$rtype" "$wan_ip")"
  fi

  echo "$record_id" > "$rec_file"
  echo "[$rtype] Updating $CFRECORD_NAME -> $wan_ip (ttl=$CFTTL, proxied=$PROXIED)"
  if ! update_record "$zone_id" "$record_id" "$rtype" "$wan_ip"; then
    warn "[$rtype] Update by cached record id failed, retry by querying record id"
    record_id="$(get_record_id "$zone_id" "$rtype")"
    echo "$record_id" > "$rec_file"
    update_record "$zone_id" "$record_id" "$rtype" "$wan_ip"
  fi
  echo "$wan_ip" > "$ip_file"
  echo "[$rtype] OK"
}

run_ddns() {
  load_config_if_exists
  [ -f "$CONF_FILE" ] || interactive_setup

  normalize_fqdn
  validate_config
  validate_api_token || die "CF_API_TOKEN 无效或权限不足。请确认你使用的是 API Token（不是 Global API Key），并授予 Zone DNS Edit + Zone Read。"

  # Zone ID: prefer explicit config, then cache, then API lookup
  local zid_file="${CACHE_DIR}/.cf-zone_$(cache_key "$CFZONE_NAME").txt"
  local zone_id="${CFZONE_ID:-}"
  if [ -n "$zone_id" ]; then
    if verify_zone_id "$zone_id"; then
      info "Using Zone ID from config"
    else
      warn "Configured Zone ID invalid, fallback to auto lookup"
      zone_id=""
    fi
  fi

  if [ -z "$zone_id" ]; then
    if [ -f "$zid_file" ]; then
      zone_id="$(cat "$zid_file" 2>/dev/null || true)"
      if [ -n "$zone_id" ] && ! verify_zone_id "$zone_id"; then
        warn "Cached Zone ID invalid, clearing cache"
        zone_id=""
        rm -f "$zid_file"
      fi
    fi
    if [ -n "$zone_id" ]; then
      info "Using cached Zone ID"
    else
      info "Fetching Zone ID from Cloudflare API..."
      zone_id="$(get_zone_id)"
      echo "$zone_id" > "$zid_file"
    fi
  fi

  case "$CFRECORD_TYPE" in
    A)    run_one "$zone_id" "A" ;;
    AAAA) run_one "$zone_id" "AAAA" ;;
    BOTH)
      run_one "$zone_id" "A"
      run_one "$zone_id" "AAAA"
      ;;
  esac
}

########################################
# Main
########################################
case "${1:-}" in
  --setup) interactive_setup ;;
  --print) print_config ;;
  --run|"") run_ddns ;;
  *) usage; exit 2 ;;
esac
