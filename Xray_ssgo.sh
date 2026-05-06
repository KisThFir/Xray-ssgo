#!/usr/bin/env bash
set -euo pipefail

# ========== Color ==========
C_RST="\033[0m"
C_INSTALL="\033[1;36m"
C_MODIFY="\033[1;36m"
C_VIEW="\033[1;36m"
C_MANAGE="\033[1;36m"
C_RESTART="\033[1;33m"

C_XRAY="\033[1;32m"
C_ARGO="\033[1;35m"
C_NODE="\033[1;35m"
C_TUIC="\033[1;35m"
C_SBOX="\033[1;35m"
C_POLICY="\033[1;35m"
C_SHORTCUT="\033[1;35m"

C_OUTBOUND="\033[1;33m"
C_FREEFLOW="\033[1;33m"
C_SOCKS5="\033[1;33m"
C_UUID="\033[1;33m"
C_SWAP="\033[1;33m"

C_BAD="\033[1;91m"

red(){ printf '\033[1;91m%s\033[0m\n' "$1"; }
green(){ printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$1"; }
purple(){ printf '\033[1;35m%s\033[0m\n' "$1"; }

clear_buffer(){ while read -r -t 0.08 -n 10000 _d </dev/tty 2>/dev/null; do :; done; }
prompt(){ clear_buffer; printf '\033[1;91m%s\033[0m' "$1" >&2; read -r "$2" </dev/tty; }
pause(){ printf '\n\033[1;91m按回车继续...\033[0m\n' >&2; clear_buffer; read -r _d </dev/tty; }
cls(){ clear; printf '\033[3J\033[2J\033[H'; }
url_encode(){ jq -rn --arg x "$1" '$x|@uri'; }

[ "$EUID" -ne 0 ] && red "请用 root 运行" && exit 1
[ -t 0 ] || { red "请在交互终端运行"; exit 1; }

# ========== Paths ==========
WORK="/etc/xray"
XRAY_BIN="${WORK}/xray"
XRAY_CONF="${WORK}/config.json"

SB="/etc/sing-box"
SB_BIN="${SB}/sing-box"
SB_CONF="${SB}/config.json"
SB_STATE="${SB}/tuic_state.conf"

TLS_DIR="/etc/tuic/tls"

ARGO_DOMAIN="${WORK}/domain_argo.txt"
ARGO_YML="${WORK}/tunnel_argo.yml"
ARGO_JSON="${WORK}/tunnel_argo.json"

FREEFLOW_CONF="${WORK}/freeflow.conf"
RESTART_CONF="${WORK}/restart.conf"
OUTBOUND_CONF="${WORK}/outbound_policy.conf"
IPCACHE="${WORK}/ip_cache.conf"

SWAP_LOG="/tmp/swap.log"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}
SS_FIXED_IP="104.18.40.49"

SB_FIXED_VER="v1.13.11"

FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_HOURS=0
XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

# YouTube 模式：0=关闭 1=兼容(优先v6可回落) 2=严格(禁v4回落)
YOUTUBE_MODE=0
# 手动域名列表：逗号分隔
V6_COMPAT_SITES=""
V6_STRICT_SITES=""

IP_CHECKED=0
IP_CACHE_MTIME=0
WAN4="" WAN6=""
COUNTRY4="" COUNTRY6=""
ISP4="" ISP6=""
EMOJI4="" EMOJI6=""
BASE_REGION="Node"
BASE_FULL="Node"

# ========== Service ==========
is_alpine(){ [ -f /etc/alpine-release ]; }

service_exists(){
  local s="$1"
  if is_alpine; then
    [ -f "/etc/init.d/${s}" ]
  else
    [ -f "/etc/systemd/system/${s}.service" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"
  fi
}
svc(){
  local act="$1" s="$2"
  if is_alpine; then
    case "$act" in
      start|stop|restart) rc-service "$s" "$act" >/dev/null 2>&1 || true ;;
      enable) rc-update add "$s" default >/dev/null 2>&1 || true ;;
      disable) rc-update del "$s" default >/dev/null 2>&1 || true ;;
    esac
  else
    case "$act" in
      enable) systemctl enable "$s" >/dev/null 2>&1 || true; systemctl daemon-reload >/dev/null 2>&1 || true ;;
      disable) systemctl disable "$s" >/dev/null 2>&1 || true; systemctl daemon-reload >/dev/null 2>&1 || true ;;
      *) systemctl "$act" "$s" >/dev/null 2>&1 || true ;;
    esac
  fi
}
is_running(){
  if is_alpine; then
    rc-service "$1" status 2>/dev/null | grep -q started
  else
    [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]
  fi
}

# ========== Package ==========
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

pkg_install(){
  local p
  for p in "$@"; do
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y "$p" >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "$p" >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "$p" >/dev/null 2>&1 || true
    fi
  done
}

ensure_deps(){
  need_cmd jq || pkg_install jq
  need_cmd wget || pkg_install wget
  need_cmd curl || pkg_install curl
  need_cmd ip || pkg_install iproute2
  need_cmd base64 || pkg_install coreutils
  need_cmd tar || pkg_install tar
  need_cmd unzip || pkg_install unzip
  need_cmd openssl || pkg_install openssl
  [ -f /etc/alpine-release ] && pkg_install ca-certificates || true

  for c in jq wget curl ip base64 tar unzip openssl; do
    command -v "$c" >/dev/null 2>&1 || { red "依赖缺失: $c"; return 1; }
  done
  return 0
}

# ========== Helpers ==========
detect_xray_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    i?86) echo "32" ;;
    armv7l|armv7|armhf) echo "arm32-v7a" ;;
    armv6l|armv6) echo "arm32-v6" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) echo "" ;;
  esac
}
detect_cloudflared_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    i?86) echo "386" ;;
    armv7l|armv7|armhf) echo "arm" ;;
    *) echo "" ;;
  esac
}
# Alpine 用 musl 包
detect_singbox_suffix(){
  case "$(uname -m)" in
    x86_64|amd64)
      if is_alpine; then echo "-linux-amd64-musl"; else echo "-linux-amd64"; fi
      ;;
    aarch64|arm64)
      if is_alpine; then echo "-linux-arm64-musl"; else echo "-linux-arm64"; fi
      ;;
    *)
      echo ""
      ;;
  esac
}
normalize_path(){ [ -z "${1:-}" ] && echo "/" || { case "$1" in /*) echo "$1" ;; *) echo "/$1" ;; esac; }; }
gen_uuid(){ cat /proc/sys/kernel/random/uuid; }

smart_download(){
  local out="$1" url="$2" min="$3"
  local t=0
  while [ "$t" -lt 3 ]; do
    rm -f "$out"

    if command -v curl >/dev/null 2>&1; then
      curl -L --connect-timeout 10 --max-time 120 -o "$out" "$url" >/dev/null 2>&1 || true
    fi

    if [ ! -s "$out" ] && command -v wget >/dev/null 2>&1; then
      if wget --help 2>&1 | grep -q -- '--show-progress'; then
        wget -q --show-progress --timeout=30 --tries=1 -O "$out" "$url" || true
      else
        wget -q -T 30 -O "$out" "$url" || true
      fi
    fi

    if [ -f "$out" ]; then
      local sz
      sz=$(wc -c < "$out" 2>/dev/null || echo 0)
      [ "${sz:-0}" -ge "$min" ] && return 0
    fi

    t=$((t+1))
    sleep 2
  done
  return 1
}

update_xray(){
  if ! jq "$@" "$XRAY_CONF" > "${XRAY_CONF}.tmp"; then
    rm -f "${XRAY_CONF}.tmp"
    red "配置更新失败"
    return 1
  fi
  mv "${XRAY_CONF}.tmp" "$XRAY_CONF"
}

# ========== State ==========
load_state(){
  if [ -f "$FREEFLOW_CONF" ]; then
    read -r FREEFLOW_MODE < "$FREEFLOW_CONF" || true
    read -r FF_PATH < <(sed -n '2p' "$FREEFLOW_CONF") || true
    [ -z "${FF_PATH:-}" ] && FF_PATH="/"
    [[ "$FREEFLOW_MODE" =~ ^(ws|httpupgrade)$ ]] || FREEFLOW_MODE="none"
  fi
  if [ -f "$RESTART_CONF" ]; then
    RESTART_HOURS="$(cat "$RESTART_CONF" 2>/dev/null || echo 0)"
    [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
  fi
  if [ -f "$OUTBOUND_CONF" ]; then
    YOUTUBE_MODE="$(awk -F= '/^YOUTUBE_MODE=/{print $2}' "$OUTBOUND_CONF" 2>/dev/null)"
    V6_COMPAT_SITES="$(awk -F= '/^V6_COMPAT_SITES=/{sub(/^V6_COMPAT_SITES=/,""); print}' "$OUTBOUND_CONF" 2>/dev/null)"
    V6_STRICT_SITES="$(awk -F= '/^V6_STRICT_SITES=/{sub(/^V6_STRICT_SITES=/,""); print}' "$OUTBOUND_CONF" 2>/dev/null)"
    [[ "$YOUTUBE_MODE" =~ ^[012]$ ]] || YOUTUBE_MODE=0
  fi
}
save_outbound(){
  mkdir -p "$WORK"
  {
    echo "YOUTUBE_MODE=${YOUTUBE_MODE}"
    echo "V6_COMPAT_SITES=${V6_COMPAT_SITES}"
    echo "V6_STRICT_SITES=${V6_STRICT_SITES}"
  } > "$OUTBOUND_CONF"
}

# ========== IP / ISP ==========
country_flag(){
  local cc="${1^^}"
  [ ${#cc} -ne 2 ] && { echo ""; return; }
  local o1 o2
  o1=$(printf '%d' "'${cc:0:1}")
  o2=$(printf '%d' "'${cc:1:1}")
  printf "\\U1F1$(printf '%X' $((o1-65+0xE6)))\\U1F1$(printf '%X' $((o2-65+0xE6)))"
}
clean_isp(){
  local s="$1"
  # 去除前缀 AS12345 / ASAS12345 等异常样式
  s="$(echo "$s" | sed -E 's/^AS(AS)?[0-9]+[[:space:]]+//I')"
  s="${s#AS[0-9]* }"
  s="$(echo "$s" | sed -E 's/[[:space:],]+$//; s/^[[:space:],]+//')"
  s="$(echo "$s" | sed -E 's/[[:space:]]+(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|GmbH|SAS|PLC|Co\.?)$//I')"
  s="$(echo "$s" | sed -E 's/[[:space:],]+$//; s/^[[:space:],]+//')"
  echo "$s"
}
save_ip_cache(){
  mkdir -p "$WORK"
  cat > "$IPCACHE" <<EOF
WAN4=$(printf '%q' "$WAN4")
WAN6=$(printf '%q' "$WAN6")
COUNTRY4=$(printf '%q' "$COUNTRY4")
COUNTRY6=$(printf '%q' "$COUNTRY6")
ISP4=$(printf '%q' "$ISP4")
ISP6=$(printf '%q' "$ISP6")
EMOJI4=$(printf '%q' "$EMOJI4")
EMOJI6=$(printf '%q' "$EMOJI6")
BASE_REGION=$(printf '%q' "$BASE_REGION")
BASE_FULL=$(printf '%q' "$BASE_FULL")
EOF
}
load_ip_cache(){
  [ -f "$IPCACHE" ] || return 1
  # shellcheck disable=SC1090
  . "$IPCACHE" 2>/dev/null || return 1
  [ -n "${WAN4}${WAN6}" ] || return 1
  IP_CHECKED=1
  return 0
}
apply_base_name(){
  local cc isp emo
  if [ -n "$COUNTRY4" ] || [ -n "$ISP4" ]; then
    cc="${COUNTRY4^^}"; isp="$ISP4"; emo="$EMOJI4"
  else
    cc="${COUNTRY6^^}"; isp="$ISP6"; emo="$EMOJI6"
  fi
  if [ -n "$emo" ] && [ -n "$cc" ]; then
    BASE_REGION="${emo} ${cc}"
  elif [ -n "$cc" ]; then
    BASE_REGION="${cc}"
  else
    BASE_REGION="Node"
  fi
  [ -n "$isp" ] && BASE_FULL="${BASE_REGION} ${isp}" || BASE_FULL="$BASE_REGION"
}

_G_CACHED_REALIP=""
platform_get_realip() {
  [ -n "${_G_CACHED_REALIP:-}" ] && { printf '%s' "${_G_CACHED_REALIP}"; return 0; }
  local _ip _v6 _org _res=""
  _ip="$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -n "${_ip:-}" ]; then
    _org="$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null || true)"
    if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
      _v6="$(curl -6 -sf --max-time 5 https://api6.ipify.org 2>/dev/null || true)"
      [ -n "${_v6:-}" ] && _res="${_v6}" || _res="${_ip}"
    else
      _res="${_ip}"
    fi
  else
    _v6="$(curl -6 -sf --max-time 5 https://api6.ipify.org 2>/dev/null || true)"
    [ -n "${_v6:-}" ] && _res="${_v6}"
  fi
  _G_CACHED_REALIP="${_res}"
  printf '%s' "${_G_CACHED_REALIP}"
}

fill_by_ipinfo_ip(){
  local fam="$1" ip="$2"
  [ -z "$ip" ] && return 1
  local j cc org
  j="$(curl -sf --max-time 6 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)"
  if [ -z "$j" ] || ! echo "$j" | jq -e '.ip' >/dev/null 2>&1; then
    org="$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org" 2>/dev/null || true)"
    cc="$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/country" 2>/dev/null || true)"
    if [ "$fam" = "4" ]; then
      WAN4="$ip"; COUNTRY4="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
      EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
      ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
    else
      WAN6="$ip"; COUNTRY6="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
      EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"
      ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
    fi
    return 0
  fi

  cc="$(echo "$j" | jq -r '.country // empty' 2>/dev/null || true)"
  org="$(echo "$j" | jq -r '.org // empty' 2>/dev/null || true)"
  if [ "$fam" = "4" ]; then
    WAN4="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY4="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
    EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
    ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY6="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
    EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"
    ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
  fi
}

parse_cf_json(){
  local fam="$1" j="$2"
  [ -z "$j" ] && return 1
  echo "$j" | jq -e '.ip' >/dev/null 2>&1 || return 1

  local ip cc emo asn isp
  ip="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
  cc="$(echo "$j" | jq -r '.country // empty' 2>/dev/null || true)"
  emo="$(echo "$j" | jq -r '.emoji // empty' 2>/dev/null || true)"
  asn="$(echo "$j" | jq -r '.asn // empty' 2>/dev/null || true)"
  isp="$(echo "$j" | jq -r '.isp // empty' 2>/dev/null || true)"
  [ -z "$ip" ] && return 1

  if [ "$fam" = "4" ]; then
    WAN4="$ip"; COUNTRY4="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
    EMOJI4="$emo"; [ -z "$EMOJI4" ] && EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
    ISP4="$(clean_isp "${asn:+AS${asn} }${isp}")"; [ -z "$ISP4" ] && ISP4="$(clean_isp "$isp")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$ip"; COUNTRY6="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"
    EMOJI6="$emo"; [ -z "$EMOJI6" ] && EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"
    ISP6="$(clean_isp "${asn:+AS${asn} }${isp}")"; [ -z "$ISP6" ] && ISP6="$(clean_isp "$isp")"; [ -z "$ISP6" ] && ISP6="unknown"
  fi
  return 0
}

get_local_ipv6_fallback(){
  local ip6=""
  ip6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [ -z "$ip6" ] && ip6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -v '^fe80:' | head -n1 || true)"
  echo "$ip6"
}

check_ip(){
  [ "${IP_CHECKED:-0}" = "1" ] && return 0

  WAN4=""; WAN6=""
  COUNTRY4=""; COUNTRY6=""
  ISP4=""; ISP6=""
  EMOJI4=""; EMOJI6=""

  local IF4="" L4=""
  IF4="$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  if [ -n "$IF4" ]; then
    L4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    [ -z "$L4" ] && L4="$(ip -4 addr show "$IF4" 2>/dev/null | awk '/inet / && /global/ {print $2}' | awk -F/ '{print $1}' | head -n1 || true)"
  fi

  local j4=""
  if [ -n "${L4:-}" ]; then
    j4="$(curl -4 -sk --interface "$L4" --connect-timeout 2 --max-time 3 "https://ip.cloudflare.now.cc?lang=zh-CN" 2>/dev/null || true)"
  else
    j4="$(curl -4 -sk --connect-timeout 2 --max-time 3 "https://ip.cloudflare.now.cc?lang=zh-CN" 2>/dev/null || true)"
  fi
  parse_cf_json 4 "$j4" || true

  if [ -z "${WAN4:-}" ]; then
    local ip4=""
    ip4="$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip4" ] && fill_by_ipinfo_ip 4 "$ip4" || true
  fi

  local ip6=""
  ip6="$(curl -6 -sf --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  if [ -n "$ip6" ]; then
    WAN6="$ip6"
    fill_by_ipinfo_ip 6 "$WAN6" || true
  else
    ip6="$(get_local_ipv6_fallback || true)"
    if [ -n "$ip6" ]; then
      WAN6="$ip6"
      fill_by_ipinfo_ip 6 "$WAN6" || true
    fi
  fi

  if [ -z "${WAN4:-}" ] && [ -z "${WAN6:-}" ]; then
    local rip=""
    rip="$(platform_get_realip 2>/dev/null || true)"
    if [ -n "$rip" ]; then
      if [[ "$rip" == *:* ]]; then
        WAN6="$rip"; fill_by_ipinfo_ip 6 "$WAN6" || true
      else
        WAN4="$rip"; fill_by_ipinfo_ip 4 "$WAN4" || true
      fi
    fi
  fi

  apply_base_name || true
  IP_CHECKED=1
  save_ip_cache || true
  return 0
}

# ========== Xray ==========
init_xray_conf(){
  mkdir -p "$WORK"
  [ -f "$XRAY_CONF" ] && return
  cat > "$XRAY_CONF" <<'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "dns": {
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4" },
      { "address": "https+local://8.8.8.8/dns-query", "queryStrategy": "UseIPv4" }
    ],
    "queryStrategy": "UseIPv4",
    "enableParallelQuery": true,
    "disableFallback": true,
    "serveStale": true,
    "serveExpiredTTL": 0
  },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "dns", "tag": "dns-out" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "port": "53", "outboundTag": "dns-out" },
      { "type": "field", "protocol": "dns", "outboundTag": "dns-out" }
    ]
  }
}
EOF
}
ensure_dns_rule(){
  init_xray_conf
  local has_dnsout
  has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "$XRAY_CONF" 2>/dev/null || echo false)
  [ "$has_dnsout" = "true" ] || update_xray '.outbounds += [{"protocol":"dns","tag":"dns-out"}]'
  jq -e '.routing' "$XRAY_CONF" >/dev/null 2>&1 || update_xray '.routing={"rules":[]}'
  update_xray 'del(.routing.rules[]? | select(.port=="53" or .protocol=="dns"))'
  update_xray '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]'
}
xray_uuid(){
  if [ -f "$XRAY_CONF" ]; then
    local u
    u=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "$XRAY_CONF" 2>/dev/null || true)
    [ -n "$u" ] && { echo "$u"; return; }
  fi
  echo "$UUID_FALLBACK"
}
set_xray_uuid(){
  local u="$1"
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return 1; }
  update_xray --arg uuid "$u" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'
  svc restart xray
  green "UUID已更新: $u"
}
install_xray(){
  ensure_deps || return 1
  mkdir -p "$WORK"
  init_xray_conf
  ensure_dns_rule

  if [ ! -x "$XRAY_BIN" ]; then
    local arch url
    arch="$(detect_xray_arch)"
    [ -z "$arch" ] && { red "架构不支持Xray"; return 1; }
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    smart_download "${WORK}/xray.zip" "$url" 5000000 || { red "下载Xray失败"; return 1; }
    unzip -o "${WORK}/xray.zip" -d "${WORK}/" >/dev/null 2>&1 || return 1
    chmod +x "$XRAY_BIN"
    rm -f "${WORK}/xray.zip" "${WORK}/geosite.dat" "${WORK}/geoip.dat" "${WORK}/README.md" "${WORK}/LICENSE"
  fi

  if ! service_exists xray; then
    if is_alpine; then
      cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONF}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
      chmod +x /etc/init.d/xray
    else
      cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    fi
    svc enable xray
  fi
  svc restart xray
  green "Xray 安装完成"
}

# ========== Outbound ==========
normalize_domain_item(){
  local s="$1"
  s="${s#http://}"; s="${s#https://}"
  s="${s%%/*}"; s="${s%%:*}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//;s/^\.*//')"
  echo "$s"
}
merge_csv(){
  local a="$1" b="$2"
  if [ -z "$a" ]; then echo "$b"; return; fi
  if [ -z "$b" ]; then echo "$a"; return; fi
  echo "${a},${b}"
}
csv_to_json_unique(){
  local d="$1"
  local raw_arr=() clean_arr=() item
  IFS=',' read -r -a raw_arr <<< "$d"
  for item in "${raw_arr[@]}"; do
    item="$(normalize_domain_item "$item")"
    [ -z "$item" ] && continue
    clean_arr+=("$item")
  done
  printf '%s\n' "${clean_arr[@]}" | awk 'NF' | sort -u | jq -Rsc 'split("\n")|map(select(length>0))'
}
yt_domains_csv(){
  echo "youtube.com,youtu.be,googlevideo.com,ytimg.com"
}
build_v6_compat_domains_json(){
  local d="$V6_COMPAT_SITES"
  [ "$YOUTUBE_MODE" = "1" ] && d="$(merge_csv "$d" "$(yt_domains_csv)")"
  csv_to_json_unique "$d"
}
build_v6_strict_domains_json(){
  local d="$V6_STRICT_SITES"
  [ "$YOUTUBE_MODE" = "2" ] && d="$(merge_csv "$d" "$(yt_domains_csv)")"
  csv_to_json_unique "$d"
}

apply_policy_xray(){
  [ -f "$XRAY_CONF" ] || return 0
  ensure_dns_rule
  update_xray '
    .outbounds |= (
      map(select(.tag!="direct" and .tag!="direct-v4" and .tag!="direct-v6" and .tag!="block-v4"))
      + [{"protocol":"freedom","tag":"direct-v4","settings":{"domainStrategy":"UseIPv4"}}]
      + [{"protocol":"freedom","tag":"direct-v6","settings":{"domainStrategy":"UseIPv6"}}]
      + [{"protocol":"blackhole","tag":"block-v4"}]
    )'

  update_xray 'del(.routing.rules[]? | select(.tag=="v6-compat-rule" or .tag=="v6-strict-route-rule" or .tag=="v6-strict-reject-rule"))'

  local compat strict
  compat="$(build_v6_compat_domains_json)"
  strict="$(build_v6_strict_domains_json)"

  # 严格：先拒绝 IPv4 目的，再路由 IPv6
  if [ "$(echo "$strict" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$strict" \
      '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"ip":["0.0.0.0/0"],"outboundTag":"block-v4","tag":"v6-strict-reject-rule"}]'
    update_xray --argjson d "$strict" \
      '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-strict-route-rule"}]'
  fi

  # 兼容：仅路由 IPv6，不 reject IPv4
  if [ "$(echo "$compat" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$compat" \
      '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-compat-rule"}]'
  fi
}

apply_policy_sbox(){
  [ -f "$SB_CONF" ] || return 0

  local compat strict
  compat="$(build_v6_compat_domains_json)"
  strict="$(build_v6_strict_domains_json)"

  jq '
    .outbounds |= (
      map(select(.tag!="direct_ipv4" and .tag!="direct_ipv6"))
      + [{
          "type":"direct",
          "tag":"direct_ipv4",
          "domain_resolver":{"server":"dns_cf","strategy":"ipv4_only"}
        }]
      + [{
          "type":"direct",
          "tag":"direct_ipv6",
          "domain_resolver":{"server":"dns_cf","strategy":"ipv6_only"}
        }]
    )
  ' "$SB_CONF" > "${SB_CONF}.tmp" && mv "${SB_CONF}.tmp" "$SB_CONF"

  jq --argjson c "$compat" --argjson s "$strict" '
    .dns = (.dns // {})
    | .dns.rules = (
        (if ($s|length)>0 then [{"domain_suffix":$s,"server":"dns_cf"}] else [] end)
        + (if ($c|length)>0 then [{"domain_suffix":$c,"server":"dns_cf"}] else [] end)
      )
    | .route = (.route // {})
    | .route.rules = (
        [{"action":"sniff"}]
        + (if ($s|length)>0 then [{"domain_suffix":$s,"ip_version":4,"action":"reject","method":"default"}] else [] end)
        + (if ($s|length)>0 then [{"domain_suffix":$s,"action":"route","outbound":"direct_ipv6"}] else [] end)
        + (if ($c|length)>0 then [{"domain_suffix":$c,"action":"route","outbound":"direct_ipv6"}] else [] end)
      )
    | .route.final = "direct_ipv4"
  ' "$SB_CONF" > "${SB_CONF}.tmp" && mv "${SB_CONF}.tmp" "$SB_CONF"
}

apply_policy_all(){
  apply_policy_xray || true
  apply_policy_sbox || true

  if [ -x "$SB_BIN" ] && [ -f "$SB_CONF" ]; then
    if ! "$SB_BIN" check -c "$SB_CONF" >/tmp/sb_check_apply.log 2>&1; then
      red "sing-box 配置校验失败，已跳过重启 tuic-box"
      tail -n 50 /tmp/sb_check_apply.log 2>/dev/null || true
    else
      service_exists tuic-box && svc restart tuic-box
    fi
  fi

  service_exists xray && svc restart xray
  green "出站规则已应用（Xray + Sbox）"
}

# ========== Argo ==========
install_argo(){
  install_xray || return 1
  ensure_dns_rule || return 1

  if [ ! -x "${WORK}/argo" ]; then
    local a u
    a="$(detect_cloudflared_arch)"
    [ -z "$a" ] && { red "架构不支持cloudflared"; return 1; }
    u="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${a}"
    smart_download "${WORK}/argo" "$u" 15000000 || { red "下载cloudflared失败"; return 1; }
    chmod +x "${WORK}/argo"
  fi

  local domain auth ss_pass mc ss_method tunnel_id uuid
  prompt "Argo域名: " domain
  [ -z "$domain" ] && { red "不能为空"; return 1; }
  prompt "Argo JSON凭证: " auth
  echo "$auth" | grep -q "TunnelSecret" || { red "必须是JSON凭证"; return 1; }

  prompt "SS密码(回车随机UUID): " ss_pass
  [ -z "$ss_pass" ] && ss_pass="$(gen_uuid)"
  prompt "SS加密(1:aes-128-gcm/2:aes-256-gcm): " mc
  ss_method="aes-128-gcm"; [ "$mc" = "2" ] && ss_method="aes-256-gcm"

  echo "$domain" > "$ARGO_DOMAIN"
  tunnel_id="$(echo "$auth" | jq -r '.TunnelID' 2>/dev/null || true)"
  [ -z "$tunnel_id" ] && tunnel_id="$(echo "$auth" | cut -d'"' -f12)"
  echo "$auth" > "$ARGO_JSON"

  cat > "$ARGO_YML" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${ARGO_JSON}
protocol: http2
ingress:
  - hostname: ${domain}
    path: /argo
    service: http://localhost:8080
    originRequest: { noTLSVerify: true }
  - hostname: ${domain}
    path: /xgo
    service: http://localhost:8081
    originRequest: { noTLSVerify: true }
  - hostname: ${domain}
    path: /ssgo
    service: http://localhost:8082
    originRequest: { noTLSVerify: true }
  - service: http_status:404
EOF

  uuid="$(xray_uuid)"
  update_xray 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))'

  local ws xh ss
  ws='{"port":8080,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
  xh=$(jq -nc --arg uuid "$uuid" --arg mode "$XHTTP_MODE" --argjson extra "$XHTTP_EXTRA_JSON" \
      '{"port":8081,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')
  ss='{"port":8082,"listen":"127.0.0.1","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
  update_xray --argjson ws "$ws" --argjson xh "$xh" --argjson ss "$ss" '.inbounds += [$ws,$xh,$ss]'

  local cmd svcname="tunnel-argo"
  cmd="${WORK}/argo tunnel --edge-ip-version auto --no-autoupdate --config ${ARGO_YML} run"
  if ! service_exists "$svcname"; then
    if is_alpine; then
      cat > "${WORK}/argo_start.sh" <<EOF
#!/bin/sh
exec ${cmd}
EOF
      chmod +x "${WORK}/argo_start.sh"
      cat > /etc/init.d/${svcname} <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="${WORK}/argo_start.sh"
command_background=true
pidfile="/var/run/${svcname}.pid"
EOF
      chmod +x /etc/init.d/${svcname}
    else
      cat > /etc/systemd/system/${svcname}.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=${cmd}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    fi
    svc enable "$svcname"
  fi

  svc restart xray
  svc restart "$svcname"
  apply_policy_all || true
  green "Argo 配置完成"
}

uninstall_argo(){
  svc stop tunnel-argo
  svc disable tunnel-argo
  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service "${WORK}/argo_start.sh" "${WORK}/argo"
  rm -f "$ARGO_DOMAIN" "$ARGO_YML" "$ARGO_JSON"
  if [ -f "$XRAY_CONF" ]; then
    update_xray 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))'
    svc restart xray
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  green "Argo 已卸载"
}

# ========== Nodes ==========
show_xray_nodes(){
  cls
  [ "$IP_CHECKED" = "1" ] || load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || check_ip || true
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return; }

  local ip="" uuid cnt=0
  [ -n "$WAN4" ] && ip="$WAN4" || ip="$WAN6"
  uuid="$(xray_uuid)"
  [ -z "$BASE_FULL" ] && BASE_FULL="Node"

  green "=============== 节点链接 ================"
  if [ -f "$ARGO_DOMAIN" ]; then
    local d xextra nx nw ns
    d="$(cat "$ARGO_DOMAIN")"
    xextra="$(url_encode "$XHTTP_EXTRA_JSON")"
    nx="${BASE_FULL} - ArgoXHTTP"
    nw="${BASE_FULL} - ArgoWS"
    ns="${BASE_FULL} - ArgoSS"
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&alpn=h2&fp=chrome&type=xhttp&host=${d}&path=%2Fxgo&mode=${XHTTP_MODE}&extra=${xextra}#$(url_encode "$nx")"; echo
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2Fargo%3Fed%3D2560#$(url_encode "$nw")"; echo
    cnt=$((cnt+2))
    local ssib
    ssib="$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8082)' "$XRAY_CONF" 2>/dev/null || true)"
    if [ -n "$ssib" ]; then
      local m pw b64
      m="$(echo "$ssib" | jq -r '.settings.method')"
      pw="$(echo "$ssib" | jq -r '.settings.password')"
      b64="$(echo -n "${m}:${pw}" | base64 | tr -d '\n')"
      purple "ss://${b64}@${SS_FIXED_IP}:80?type=ws&security=none&host=${d}&path=%2Fssgo#$(url_encode "$ns")"; echo
      cnt=$((cnt+1))
    fi
  fi

  if [ -f "$FREEFLOW_CONF" ]; then
    local f1 f2
    f1="$(sed -n '1p' "$FREEFLOW_CONF" 2>/dev/null || true)"
    f2="$(sed -n '2p' "$FREEFLOW_CONF" 2>/dev/null || true)"
    [ -z "$f2" ] && f2="/"
    if [[ "$f1" =~ ^(ws|httpupgrade)$ ]] && [ -n "$ip" ]; then
      local nm mode
      mode="${f1^^}"; [ "$mode" = "HTTPUPGRADE" ] && mode="HTTP+"
      nm="${BASE_FULL} - ${mode}"
      purple "vless://${uuid}@${ip}:80?encryption=none&security=none&type=${f1}&host=${ip}&path=$(url_encode "$f2")#$(url_encode "$nm")"; echo
      cnt=$((cnt+1))
    fi
  fi

  local sl
  sl="$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$XRAY_CONF" 2>/dev/null || true)"
  if [ -n "$sl" ] && [ -n "$ip" ]; then
    while read -r line; do
      [ -z "$line" ] && continue
      local p u pw n
      p="$(echo "$line" | jq -r '.port')"
      u="$(echo "$line" | jq -r '.settings.accounts[0].user')"
      pw="$(echo "$line" | jq -r '.settings.accounts[0].pass')"
      n="${BASE_FULL} - Socks5-${p}"
      purple "socks5://${u}:${pw}@${ip}:${p}#$(url_encode "$n")"; echo
      cnt=$((cnt+1))
    done <<< "$sl"
  fi

  [ "$cnt" -eq 0 ] && yellow "暂无配置节点"
  echo "=========================================="
}

# ========== Socks5 ==========
manage_socks5(){
  [ -f "$XRAY_CONF" ] || { red "请先安装xray"; pause; return; }
  ensure_dns_rule || { red "初始化失败"; pause; return; }

  while true; do
    cls
    local list
    list="$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$XRAY_CONF" 2>/dev/null || true)"
    echo -e "${C_SOCKS5}=============== Socks5管理 ===============${C_RST}"
    if [ -z "$list" ]; then
      echo -e "当前: ${C_BAD}未配置${C_RST}"
    else
      echo "-----------------------------------------------"
      echo "  端口    | 用户名    | 密码"
      echo "-----------------------------------------------"
      while read -r line; do
        [ -z "$line" ] && continue
        printf "  %-8s| %-10s| %s\n" \
          "$(echo "$line" | jq -r '.port')" \
          "$(echo "$line" | jq -r '.settings.accounts[0].user')" \
          "$(echo "$line" | jq -r '.settings.accounts[0].pass')"
      done <<< "$list"
    fi
    echo "-----------------------------------------------"
    echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_SOCKS5}Socks5${C_RST}"
    echo -e "${C_MODIFY} 2.${C_RST} ${C_MODIFY}修改${C_RST}${C_SOCKS5}Socks5${C_RST}"
    echo -e "${C_BAD} 3.${C_RST} ${C_BAD}卸载${C_RST}${C_SOCKS5}Socks5${C_RST}"
    echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "端口: " p; prompt "用户名: " u; prompt "密码: " pw
        if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
          local ex
          ex="$(jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$XRAY_CONF")"
          if [ "$ex" -gt 0 ]; then red "端口已存在"
          else
            update_xray --argjson p "$p" --arg u "$u" --arg pw "$pw" \
              '.inbounds += [{"tag":("socks-"+($p|tostring)),"port":$p,"listen":"0.0.0.0","protocol":"socks","settings":{"auth":"password","accounts":[{"user":$u,"pass":$pw}],"udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false}}]'
            svc restart xray; green "添加成功"
          fi
        else red "输入无效"; fi
        pause
        ;;
      2)
        prompt "端口: " p; prompt "新用户名: " u; prompt "新密码: " pw
        if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
          update_xray --argjson p "$p" --arg u "$u" --arg pw "$pw" \
            '(.inbounds[]? | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user":$u,"pass":$pw}'
          svc restart xray; green "修改成功"
        else red "输入无效"; fi
        pause
        ;;
      3)
        if [ -z "$list" ]; then red "无可删项"; pause; continue; fi
        local i=1; declare -a ports=()
        while read -r line; do
          [ -z "$line" ] && continue
          local p; p="$(echo "$line" | jq -r '.port')"
          echo "  ${i}. 端口 ${p}"; ports[$i]="$p"; i=$((i+1))
        done <<< "$list"
        echo "  0. 取消"
        prompt "序号: " idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -gt 0 ] && [ "$idx" -lt "$i" ]; then
          update_xray --argjson p "${ports[$idx]}" 'del(.inbounds[]? | select(.protocol=="socks" and .port==$p))'
          svc restart xray; green "已删除"
        fi
        pause
        ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Freeflow ==========
apply_freeflow(){
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return 1; }
  ensure_dns_rule || return 1
  local uuid ff
  uuid="$(xray_uuid)"
  update_xray 'del(.inbounds[]? | select(.tag=="ff-in"))'
  if [ "$FREEFLOW_MODE" != "none" ]; then
    ff='{"tag":"ff-in","port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"'"${FREEFLOW_MODE}"'","security":"none","'"${FREEFLOW_MODE}"'Settings":{"path":"'"${FF_PATH}"'"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}'
    update_xray --argjson ib "$ff" '.inbounds += [$ib]'
  fi
  svc restart xray
}
manage_freeflow(){
  [ -f "$XRAY_CONF" ] || { red "请先安装xray"; pause; return; }
  while true; do
    cls
    local s="${C_BAD}未配置${C_RST}"
    if [ "$FREEFLOW_MODE" != "none" ]; then
      local m="${FREEFLOW_MODE^^}"; [ "$m" = "HTTPUPGRADE" ] && m="HTTP+"
      s="${C_FREEFLOW}${m}${C_RST} path=${FF_PATH}"
    fi
    echo -e "${C_FREEFLOW}=============== 免流管理 ===============${C_RST}"
    printf "当前: %b\n" "$s"
    echo "-----------------------------------------------"
    echo -e "${C_MODIFY} 1.${C_RST} ${C_MODIFY}修改${C_RST}${C_FREEFLOW}免流方式${C_RST}"
    echo -e "${C_MODIFY} 2.${C_RST} ${C_MODIFY}修改${C_RST}${C_FREEFLOW}免流路径${C_RST}"
    echo -e "${C_BAD} 3.${C_RST} ${C_BAD}卸载${C_RST}${C_FREEFLOW}免流${C_RST}"
    echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        echo; green "请选择免流方式"
        echo "-----------------------------------------------"
        echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_FREEFLOW}免流${C_RST} + WS"
        echo -e "${C_INSTALL} 2.${C_RST} ${C_INSTALL}安装${C_RST}${C_FREEFLOW}免流${C_RST} + HTTPUpgrade"
        echo -e "${C_BAD} 3.${C_RST} ${C_BAD}卸载${C_RST}${C_FREEFLOW}免流${C_RST}"
        echo "-----------------------------------------------"
        prompt "请选择: " k
        case "$k" in
          1) FREEFLOW_MODE="ws" ;;
          2) FREEFLOW_MODE="httpupgrade" ;;
          *) FREEFLOW_MODE="none" ;;
        esac
        if [ "$FREEFLOW_MODE" != "none" ]; then
          prompt "path(回车默认/): " p
          FF_PATH="$(normalize_path "$p")"
        else
          FF_PATH="/"
        fi
        printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$FREEFLOW_CONF"
        apply_freeflow; green "已更新"; pause
        ;;
      2)
        [ "$FREEFLOW_MODE" = "none" ] && { red "请先启用"; pause; continue; }
        prompt "新path(回车保持): " p
        [ -n "$p" ] && FF_PATH="$(normalize_path "$p")"
        printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$FREEFLOW_CONF"
        apply_freeflow; green "路径已更新"; pause
        ;;
      3)
        FREEFLOW_MODE="none"; FF_PATH="/"
        printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$FREEFLOW_CONF"
        apply_freeflow; green "已卸载"; pause
        ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Tuic / sing-box ==========
install_sbox_core(){
  ensure_deps || return 1
  mkdir -p "$SB" "$WORK"
  if [ ! -x "$SB_BIN" ]; then
    local sf ver url tgz
    sf="$(detect_singbox_suffix)"
    [ -z "$sf" ] && { red "架构不支持sing-box"; return 1; }

    ver="$SB_FIXED_VER"
    tgz="${SB}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}${sf}.tar.gz"
    smart_download "$tgz" "$url" 5000000 || { red "下载sing-box失败"; return 1; }
    tar -xzf "$tgz" -C "$SB" >/dev/null 2>&1 || return 1
    mv "${SB}/sing-box-${ver#v}${sf}/sing-box" "$SB_BIN" 2>/dev/null || return 1
    chmod +x "$SB_BIN"
    rm -rf "$tgz" "${SB}/sing-box-${ver#v}${sf}"
  fi
  green "sing-box 已安装（固定版本 ${SB_FIXED_VER}）"
}
ensure_acme(){
  need_cmd openssl || pkg_install openssl
  command -v openssl >/dev/null 2>&1 || { red "缺少 openssl，无法安装 acme.sh"; return 1; }

  [ -x "$HOME/.acme.sh/acme.sh" ] && return 0

  if ! command -v crontab >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      pkg_install cron
      svc enable cron; svc start cron
    elif command -v apk >/dev/null 2>&1; then
      pkg_install dcron
      rc-service dcron start >/dev/null 2>&1 || true
      rc-update add dcron default >/dev/null 2>&1 || true
    else
      pkg_install cronie
      svc enable crond; svc start crond
    fi
  fi

  yellow "安装 acme.sh..."
  curl -s https://get.acme.sh | sh >/tmp/acme_install.log 2>&1 || true
  [ -x "$HOME/.acme.sh/acme.sh" ] || { red "acme.sh 安装失败"; tail -n 80 /tmp/acme_install.log 2>/dev/null || true; return 1; }
  return 0
}
issue_cert_cf(){
  local d="$1" token="$2"
  local crt="${TLS_DIR}/${d}.crt" key="${TLS_DIR}/${d}.key"
  mkdir -p "$TLS_DIR"
  [ -s "$crt" ] && [ -s "$key" ] && { green "证书已存在: $d"; return 0; }

  ensure_acme || return 1
  export CF_Token="$token"
  yellow "申请证书: $d"
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --issue -d "$d" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1 || {
    red "签发失败"; tail -n 80 /tmp/acme_issue.log 2>/dev/null || true; return 1; }
  "$HOME/.acme.sh/acme.sh" --installcert -d "$d" --fullchainpath "$crt" --keypath "$key" --ecc >/tmp/acme_installcert.log 2>&1 || true
  [ -s "$crt" ] && [ -s "$key" ] || { red "安装证书失败"; tail -n 80 /tmp/acme_installcert.log 2>/dev/null || true; return 1; }
  green "证书安装成功"
}
open_port(){
  local p="$1" proto="${2:-tcp}"
  command -v ufw >/dev/null 2>&1 && ufw allow "${p}/${proto}" >/dev/null 2>&1 || true
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-port="${p}/${proto}" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

build_sbox_dns_servers_json(){
  jq -nc '[
    {"type":"https","tag":"dns_cf","server":"1.1.1.1","server_port":443,"path":"/dns-query","detour":"direct_ipv4"},
    {"type":"https","tag":"dns_gg","server":"8.8.8.8","server_port":443,"path":"/dns-query","detour":"direct_ipv4"},
    {"type":"https","tag":"dns_q9","server":"9.9.9.9","server_port":443,"path":"/dns-query","detour":"direct_ipv4"}
  ]'
}

write_tuic_conf(){
  local domain="$1" port="$2" cc="$3" uuid="$4"
  local crt="${TLS_DIR}/${domain}.crt" key="${TLS_DIR}/${domain}.key"
  local v6_compat v6_strict dns_servers dns_rules_json route_rules_json
  v6_compat="$(build_v6_compat_domains_json)"
  v6_strict="$(build_v6_strict_domains_json)"
  dns_servers="$(build_sbox_dns_servers_json)"

  dns_rules_json="$(jq -nc --argjson c "$v6_compat" --argjson s "$v6_strict" '
    (if ($s|length)>0 then [{"domain_suffix":$s,"server":"dns_cf"}] else [] end)
    +
    (if ($c|length)>0 then [{"domain_suffix":$c,"server":"dns_cf"}] else [] end)
  ')"

  route_rules_json="$(jq -nc --argjson c "$v6_compat" --argjson s "$v6_strict" '
    [{"action":"sniff"}]
    +
    (if ($s|length)>0 then [{"domain_suffix":$s,"ip_version":4,"action":"reject","method":"default"}] else [] end)
    +
    (if ($s|length)>0 then [{"domain_suffix":$s,"action":"route","outbound":"direct_ipv6"}] else [] end)
    +
    (if ($c|length)>0 then [{"domain_suffix":$c,"action":"route","outbound":"direct_ipv6"}] else [] end)
  ')"

  cat > "$SB_CONF" <<EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "dns": {
    "servers": ${dns_servers},
    "rules": ${dns_rules_json},
    "final": "dns_cf",
    "strategy": "ipv4_only",
    "independent_cache": true,
    "cache_capacity": 8192
  },
  "inbounds": [
    {
      "type":"tuic",
      "listen":"::",
      "tag":"tuic-in",
      "listen_port":${port},
      "users":[{"uuid":"${uuid}","password":"${uuid}"}],
      "congestion_control":"${cc}",
      "tls":{
        "enabled":true,
        "server_name":"${domain}",
        "alpn":["h3"],
        "certificate_path":"${crt}",
        "key_path":"${key}"
      }
    }
  ],
  "outbounds":[
    {"type":"direct","tag":"direct_ipv4","domain_resolver":{"server":"dns_cf","strategy":"ipv4_only"}},
    {"type":"direct","tag":"direct_ipv6","domain_resolver":{"server":"dns_cf","strategy":"ipv6_only"}}
  ],
  "route":{"rules": ${route_rules_json},"final":"direct_ipv4"}
}
EOF
}

ensure_tuic_service(){
  if service_exists tuic-box; then return; fi
  if is_alpine; then
    cat > /etc/init.d/tuic-box <<EOF
#!/sbin/openrc-run

name="tuic-box"
description="Tuic by sing-box"

SINGBOX_BIN="${SB_BIN}"
SINGBOX_CFG="${SB_CONF}"
PIDFILE="/run/\${RC_SVCNAME}.pid"

command="\${SINGBOX_BIN}"
command_args="run -c \${SINGBOX_CFG}"
command_background="yes"
pidfile="\${PIDFILE}"

depend() {
  need net
  use dns logger
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /run
  [ -x "\${SINGBOX_BIN}" ] || { eerror "binary not found: \${SINGBOX_BIN}"; return 1; }
  [ -f "\${SINGBOX_CFG}" ] || { eerror "config not found: \${SINGBOX_CFG}"; return 1; }

  ebegin "Checking sing-box config"
  "\${SINGBOX_BIN}" check -c "\${SINGBOX_CFG}" >/dev/null 2>&1
  eend \$? "Config check failed"
}

stop() {
  ebegin "Stopping \${RC_SVCNAME}"

  if [ -f "\${PIDFILE}" ]; then
    start-stop-daemon --stop --pidfile "\${PIDFILE}" --retry TERM/20/KILL/5 >/dev/null 2>&1 || true
  fi

  pkill -f "^\${SINGBOX_BIN} run -c \${SINGBOX_CFG}\$" >/dev/null 2>&1 || true
  pkill -x sing-box >/dev/null 2>&1 || true

  rm -f "\${PIDFILE}"

  if pgrep -f "^\${SINGBOX_BIN} run -c \${SINGBOX_CFG}\$" >/dev/null 2>&1; then
    eend 1 "Process still alive"
    return 1
  fi

  eend 0
  return 0
}
EOF
    chmod +x /etc/init.d/tuic-box
  else
    cat > /etc/systemd/system/tuic-box.service <<EOF
[Unit]
Description=Tuic by sing-box
After=network.target
[Service]
ExecStart=${SB_BIN} run -c ${SB_CONF}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  fi
  svc enable tuic-box
}
start_tuic_check(){
  if ! "$SB_BIN" check -c "$SB_CONF" >/tmp/sb_check.log 2>&1; then
    red "sing-box 配置校验失败"
    tail -n 80 /tmp/sb_check.log 2>/dev/null || true
    return 1
  fi
  svc restart tuic-box
  sleep 1
  if is_running tuic-box; then return 0; fi
  red "Tuic 启动失败"
  if is_alpine; then rc-service tuic-box status 2>/dev/null || true
  else journalctl -u tuic-box -n 80 --no-pager || true; fi
  return 1
}
install_tuic(){
  install_sbox_core || return 1
  local domain token port cc uuid def
  prompt "Tuic域名: " domain; [ -z "$domain" ] && { red "域名不能为空"; return 1; }
  prompt "Cloudflare API Token: " token; [ -z "$token" ] && { red "Token不能为空"; return 1; }
  prompt "Tuic端口(默认18443): " port; [ -z "$port" ] && port=18443
  [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }

  echo "拥塞算法: 1.bbr 2.cubic 3.new_reno"
  prompt "选择(默认1): " s
  case "$s" in 2) cc="cubic" ;; 3) cc="new_reno" ;; *) cc="bbr" ;; esac

  def="$(xray_uuid)"
  prompt "Tuic UUID(回车默认 ${def}): " uuid
  [ -z "$uuid" ] && uuid="$def"

  issue_cert_cf "$domain" "$token" || return 1
  open_port "$port" udp
  write_tuic_conf "$domain" "$port" "$cc" "$uuid"
  ensure_tuic_service

  apply_policy_sbox || true

  start_tuic_check || return 1
  mkdir -p "$SB"
  printf '%s|%s|%s|%s\n' "$port" "$cc" "$domain" "$uuid" > "$SB_STATE"
  green "Tuic 安装成功（sing-box ${SB_FIXED_VER}）"
}
show_tuic_node(){
  cls
  [ -f "$SB_STATE" ] || { red "Tuic未安装"; return; }
  local port cc domain uuid
  IFS='|' read -r port cc domain uuid < "$SB_STATE"
  [ -z "$port" ] || [ -z "$domain" ] || [ -z "$uuid" ] && { red "Tuic状态文件不完整"; return; }
  [ -z "$BASE_FULL" ] && BASE_FULL="Node"
  local name link
  name="${BASE_FULL} - Tuic"
  link="tuic://${uuid}:${uuid}@${domain}:${port}?congestion_control=${cc:-bbr}&alpn=h3&sni=${domain}&udp_relay_mode=quic&allow_insecure=0#$(url_encode "$name")"
  green "=============== Tuic 节点 ==============="
  purple "$link"
  echo "=========================================="
}
uninstall_tuic(){
  svc stop tuic-box
  svc disable tuic-box
  rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$SB"
  green "Sbox 已卸载"
}

# 前台查看 sing-box 日志（DEBUG）
foreground_sbox_log(){
  [ -x "$SB_BIN" ] || { red "sing-box 未安装"; pause; return 1; }
  [ -f "$SB_CONF" ] || { red "缺少配置: $SB_CONF"; pause; return 1; }

  local bak="${SB_CONF}.bak.fg.$(date +%s)"
  cp -a "$SB_CONF" "$bak"

  if ! jq '.log.disabled=false | .log.level="debug" | .log.timestamp=true' \
      "$SB_CONF" > "${SB_CONF}.tmp"; then
    red "写入 DEBUG 日志配置失败"
    rm -f "${SB_CONF}.tmp" "$bak"
    pause
    return 1
  fi
  mv "${SB_CONF}.tmp" "$SB_CONF"

  if ! "$SB_BIN" check -c "$SB_CONF" >/tmp/sb_check_fg.log 2>&1; then
    red "配置校验失败，无法前台运行"
    cp -f "$bak" "$SB_CONF"
    rm -f "$bak"
    tail -n 80 /tmp/sb_check_fg.log 2>/dev/null || true
    pause
    return 1
  fi

  yellow "即将停止 tuic-box 后台服务并前台输出 DEBUG 日志..."
  svc stop tuic-box || true
  pkill -f "^${SB_BIN} run -c ${SB_CONF}$" >/dev/null 2>&1 || true
  pkill -x sing-box >/dev/null 2>&1 || true
  sleep 1

  green "前台 DEBUG 日志已启动（Ctrl+C 退出）"
  echo "日志文件: /tmp/sb-live.log"

  local old_int_trap
  old_int_trap="$(trap -p INT || true)"
  trap ':' INT

  set +e
  "$SB_BIN" run -c "$SB_CONF" 2>&1 | tee /tmp/sb-live.log
  set -e

  if [ -n "$old_int_trap" ]; then
    eval "$old_int_trap"
  else
    trap - INT
  fi

  cp -f "$bak" "$SB_CONF"
  rm -f "$bak"

  yellow "已退出前台日志，正在恢复后台服务..."
  svc start tuic-box || true
  sleep 1
  if is_running tuic-box; then
    green "tuic-box 已恢复后台运行"
  else
    red "tuic-box 恢复失败，请手动检查"
  fi
  pause
}

# 新增：前台查看 xray 日志（DEBUG）
foreground_xray_log(){
  [ -x "$XRAY_BIN" ] || { red "xray 未安装"; pause; return 1; }
  [ -f "$XRAY_CONF" ] || { red "缺少配置: $XRAY_CONF"; pause; return 1; }

  local bak="${XRAY_CONF}.bak.fg.$(date +%s)"
  cp -a "$XRAY_CONF" "$bak"

  # 为了前台可见，临时把 access/error 输出到 stdout（空字符串）+ debug
  if ! jq '
      .log = (.log // {})
      | .log.access = ""
      | .log.error = ""
      | .log.loglevel = "debug"
      | .log.dnsLog = true
    ' "$XRAY_CONF" > "${XRAY_CONF}.tmp"; then
    red "写入 Xray DEBUG 日志配置失败"
    rm -f "${XRAY_CONF}.tmp" "$bak"
    pause
    return 1
  fi
  mv "${XRAY_CONF}.tmp" "$XRAY_CONF"

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_check_fg.log 2>&1; then
    red "Xray 配置校验失败，无法前台运行"
    cp -f "$bak" "$XRAY_CONF"
    rm -f "$bak"
    tail -n 80 /tmp/xray_check_fg.log 2>/dev/null || true
    pause
    return 1
  fi

  yellow "即将停止 xray 后台服务并前台输出 DEBUG 日志..."
  svc stop xray || true
  pkill -f "^${XRAY_BIN} run -c ${XRAY_CONF}$" >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true
  sleep 1

  green "前台 DEBUG 日志已启动（Ctrl+C 退出）"
  echo "日志文件: /tmp/xray-live.log"

  local old_int_trap
  old_int_trap="$(trap -p INT || true)"
  trap ':' INT

  set +e
  "$XRAY_BIN" run -c "$XRAY_CONF" 2>&1 | tee /tmp/xray-live.log
  set -e

  if [ -n "$old_int_trap" ]; then
    eval "$old_int_trap"
  else
    trap - INT
  fi

  cp -f "$bak" "$XRAY_CONF"
  rm -f "$bak"

  yellow "已退出前台日志，正在恢复后台服务..."
  svc start xray || true
  sleep 1
  if is_running xray; then
    green "xray 已恢复后台运行"
  else
    red "xray 恢复失败，请手动检查"
  fi
  pause
}

# ========== Restart Cron ==========
setup_cron_env(){
  command -v crontab >/dev/null 2>&1 && return
  if command -v apt-get >/dev/null 2>&1; then pkg_install cron; svc enable cron; svc start cron
  elif command -v apk >/dev/null 2>&1; then pkg_install dcron; rc-service dcron start >/dev/null 2>&1 || true; rc-update add dcron default >/dev/null 2>&1 || true
  else pkg_install cronie; svc enable crond; svc start crond; fi
}
manage_restart_hours(){
  cls
  green "当前间隔: ${RESTART_HOURS}小时 (0=关闭)"
  prompt "输入间隔小时: " h
  [[ "$h" =~ ^[0-9]+$ ]] || { red "输入无效"; return; }
  RESTART_HOURS="$h"
  echo "$RESTART_HOURS" > "$RESTART_CONF"

  if [ "$RESTART_HOURS" -eq 0 ]; then
    command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab -
    green "已关闭"
    return
  fi

  setup_cron_env
  command -v crontab >/dev/null 2>&1 || { red "crontab不可用"; return; }

  local cmd exp
  if is_alpine; then
    cmd='[ -f /etc/init.d/xray ] && rc-service xray restart; [ -f /etc/init.d/tuic-box ] && rc-service tuic-box restart; [ -f /etc/init.d/tunnel-argo ] && rc-service tunnel-argo restart'
  else
    cmd='systemctl list-unit-files | grep -q "^xray.service" && systemctl restart xray; systemctl list-unit-files | grep -q "^tuic-box.service" && systemctl restart tuic-box; systemctl list-unit-files | grep -q "^tunnel-argo.service" && systemctl restart tunnel-argo'
  fi
  exp="0 */${RESTART_HOURS} * * *"
  (crontab -l 2>/dev/null | sed '/#svc-restart-all/d'; echo "${exp} ${cmd} >/dev/null 2>&1 #svc-restart-all") | crontab -
  green "已设置每${RESTART_HOURS}小时重启（xray/tuic-box/argo）"
}

# ========== Swap ==========
swap_cleanup_fstab(){ [ -f /etc/fstab ] && sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab; }
swap_disable_all(){
  awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | while read -r d; do [ -n "$d" ] && swapoff "$d" >/dev/null 2>&1 || true; done
  [ -f /swapfile ] && rm -f /swapfile
  swap_cleanup_fstab
  if [ -d /sys/class/zram-control ] || [ -e /dev/zram0 ]; then
    for z in /sys/block/zram*; do [ -d "$z" ] || continue; echo 1 > "$z/reset" 2>/dev/null || true; done
  fi
}
zram_supported(){
  [ -e /dev/zram0 ] && return 0
  command -v modprobe >/dev/null 2>&1 && modprobe zram >/dev/null 2>&1 || true
  [ -e /dev/zram0 ] && return 0
  [ -w /sys/class/zram-control/hot_add ] && return 0
  return 1
}
create_zram_swap(){
  local mb="$1" zdev=""
  if [ -e /dev/zram0 ]; then zdev="/dev/zram0"
  elif [ -w /sys/class/zram-control/hot_add ]; then
    local id; id="$(cat /sys/class/zram-control/hot_add 2>/dev/null || true)"; [ -n "$id" ] && zdev="/dev/zram${id}"
  fi
  [ -z "$zdev" ] && return 1
  local zn="${zdev#/dev/}"
  echo 1 > "/sys/block/${zn}/reset" 2>/dev/null || true
  [ -w "/sys/block/${zn}/comp_algorithm" ] && echo lz4 > "/sys/block/${zn}/comp_algorithm" 2>/dev/null || true
  echo "$((mb*1024*1024))" > "/sys/block/${zn}/disksize" 2>/dev/null || return 1
  mkswap "$zdev" >/dev/null 2>&1 || return 1
  swapon "$zdev" >/dev/null 2>&1 || return 1
}
create_swap_dd(){
  local mb="$1"
  dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>"$SWAP_LOG" || return 1
  chmod 600 /swapfile || return 1
  mkswap /swapfile >/dev/null 2>&1 || return 1
  swapon /swapfile >/dev/null 2>&1 || return 1
  grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swap_fallocate(){
  local mb="$1"
  command -v fallocate >/dev/null 2>&1 || return 1
  fallocate -l "${mb}M" /swapfile 2>"$SWAP_LOG" || return 1
  chmod 600 /swapfile || return 1
  mkswap -f /swapfile >/dev/null 2>&1 || return 1
  swapon /swapfile >/dev/null 2>&1 || return 1
  grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swap_best(){
  local mb="${1:-256}"
  swap_disable_all
  if zram_supported && create_zram_swap "$mb"; then green "SWAP成功(ZRAM ${mb}MB)"; return 0; fi
  if create_swap_dd "$mb"; then green "SWAP成功(dd ${mb}MB)"; return 0; fi
  rm -f /swapfile
  if create_swap_fallocate "$mb"; then green "SWAP成功(fallocate ${mb}MB)"; return 0; fi
  red "SWAP失败"; return 1
}
manage_swap(){
  while true; do
    cls
    local ram sw
    ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$ram" ] && ram=0
    sw=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$sw" ] && sw=0
    echo -e "${C_SWAP}=============== SWAP管理 ===============${C_RST}"
    echo "RAM: ${ram}MB  SWAP: ${sw}MB"
    echo "-----------------------------------------------"
    echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}/${C_MODIFY}修改${C_RST}${C_SWAP}SWAP${C_RST}"
    echo -e "${C_BAD} 2.${C_RST} ${C_BAD}卸载${C_RST}${C_SWAP}SWAP${C_RST}"
    echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) prompt "大小MB(默认256): " mb; mb=${mb:-256}; [[ "$mb" =~ ^[0-9]+$ ]] && [ "$mb" -gt 0 ] && create_swap_best "$mb" || red "输入无效"; pause ;;
      2) swap_disable_all; green "已清理"; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Shortcut / Uninstall ==========
install_shortcut(){
  mkdir -p "$WORK"
  local mark="${WORK}/.shortcut_done" src dst="/usr/local/bin/ssgo"
  [ -f "$mark" ] && { green "快捷方式已存在：ssgo"; return; }
  src="$(readlink -f "$0" 2>/dev/null || true)"
  [ -z "$src" ] && src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp -f "$src" "${WORK}/manager.sh" 2>/dev/null || true
    cat > "$dst" <<'EOF'
#!/usr/bin/env bash
bash /etc/xray/manager.sh "$@"
EOF
    chmod +x "$dst"
    ln -sf "$dst" /usr/bin/ssgo 2>/dev/null || true
    touch "$mark"
    green "快捷方式已创建：ssgo"
  else
    yellow "无法识别脚本源路径，稍后可手动创建"
  fi
}

full_uninstall(){
  svc stop tunnel-argo; svc disable tunnel-argo
  svc stop xray; svc disable xray
  svc stop tuic-box; svc disable tuic-box

  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
  rm -f /etc/init.d/xray /etc/systemd/system/xray.service
  rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service

  command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload >/dev/null 2>&1 || true; systemctl reset-failed >/dev/null 2>&1 || true; }

  command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab - 2>/dev/null || true
  swap_disable_all >/dev/null 2>&1 || true

  rm -f /usr/local/bin/ssgo /usr/bin/ssgo
  rm -rf "$WORK" "$SB" "$TLS_DIR"

  green "已彻底卸载"
}

# ========== Menus ==========
yt_mode_str(){
  case "$YOUTUBE_MODE" in
    0) echo "关闭" ;;
    1) echo "兼容" ;;
    2) echo "严格" ;;
    *) echo "关闭" ;;
  esac
}
manage_outbound_menu(){
  while true; do
    cls
    local yst
    yst="$(yt_mode_str)"
    echo -e "${C_OUTBOUND}========== 出站管理（Xray + Sbox）==========${C_RST}"
    echo -e "默认出站: \033[1;36mIPv4\033[0m"
    echo -e "YouTube模式: \033[1;36m${yst}\033[0m"
    echo -e "IPv6兼容规则: \033[1;36m${V6_COMPAT_SITES:-（空）}\033[0m"
    echo -e "IPv6严格规则: \033[1;36m${V6_STRICT_SITES:-（空）}\033[0m"
    echo "-----------------------------------------------"
    echo -e "\033[1;32m 1.\033[0m 设置YouTube模式（0关闭/1兼容/2严格）"
    echo -e "\033[1;36m 2.\033[0m 添加IPv6兼容规则"
    echo -e "\033[1;36m 3.\033[0m 添加IPv6严格规则"
    echo -e "\033[1;91m 4.\033[0m 删除IPv6兼容规则"
    echo -e "\033[1;91m 5.\033[0m 删除IPv6严格规则"
    echo -e "${C_BAD} 6.${C_RST} ${C_BAD}重启${C_RST}${C_OUTBOUND}服务应用规则${C_RST}"
    echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "输入模式(0/1/2): " m
        [[ "$m" =~ ^[012]$ ]] || { red "输入无效"; pause; continue; }
        YOUTUBE_MODE="$m"; save_outbound; apply_policy_all; green "YouTube模式已更新并应用"; pause
        ;;
      2)
        prompt "输入域名(逗号分隔): " s
        [ -z "$s" ] && { red "不能为空"; pause; continue; }
        [ -z "$V6_COMPAT_SITES" ] && V6_COMPAT_SITES="$s" || V6_COMPAT_SITES="${V6_COMPAT_SITES},${s}"
        V6_COMPAT_SITES="$(echo "$V6_COMPAT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
        save_outbound; apply_policy_all; green "已添加兼容规则并应用"; pause
        ;;
      3)
        prompt "输入域名(逗号分隔): " s
        [ -z "$s" ] && { red "不能为空"; pause; continue; }
        [ -z "$V6_STRICT_SITES" ] && V6_STRICT_SITES="$s" || V6_STRICT_SITES="${V6_STRICT_SITES},${s}"
        V6_STRICT_SITES="$(echo "$V6_STRICT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
        save_outbound; apply_policy_all; green "已添加严格规则并应用"; pause
        ;;
      4)
        if [ -z "$V6_COMPAT_SITES" ]; then red "规则为空"; pause; continue; fi
        local arr i=1
        IFS=',' read -r -a arr <<< "$V6_COMPAT_SITES"
        echo "当前兼容规则："
        for d in "${arr[@]}"; do d="$(echo "$d" | sed 's/^ *//; s/ *$//')"; [ -z "$d" ] && continue; echo "  $i. $d"; i=$((i+1)); done
        echo "  a. 全部删除"; echo "  0. 取消"
        prompt "请输入序号或a: " idx
        if [[ "$idx" =~ ^[aA]$ ]]; then V6_COMPAT_SITES=""; save_outbound; apply_policy_all; green "已全删并应用"; pause; continue; fi
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -le 0 ] || [ "$idx" -ge "$i" ]; then [ "$idx" = "0" ] && continue; red "序号无效"; pause; continue; fi
        local new="" j=1
        for d in "${arr[@]}"; do
          d="$(echo "$d" | sed 's/^ *//; s/ *$//')"; [ -z "$d" ] && continue
          [ "$j" -ne "$idx" ] && { [ -z "$new" ] && new="$d" || new="${new},${d}"; }
          j=$((j+1))
        done
        V6_COMPAT_SITES="$new"; save_outbound; apply_policy_all; green "已删除并应用"; pause
        ;;
      5)
        if [ -z "$V6_STRICT_SITES" ]; then red "规则为空"; pause; continue; fi
        local arr2 i2=1
        IFS=',' read -r -a arr2 <<< "$V6_STRICT_SITES"
        echo "当前严格规则："
        for d in "${arr2[@]}"; do d="$(echo "$d" | sed 's/^ *//; s/ *$//')"; [ -z "$d" ] && continue; echo "  $i2. $d"; i2=$((i2+1)); done
        echo "  a. 全部删除"; echo "  0. 取消"
        prompt "请输入序号或a: " idx2
        if [[ "$idx2" =~ ^[aA]$ ]]; then V6_STRICT_SITES=""; save_outbound; apply_policy_all; green "已全删并应用"; pause; continue; fi
        if ! [[ "$idx2" =~ ^[0-9]+$ ]] || [ "$idx2" -le 0 ] || [ "$idx2" -ge "$i2" ]; then [ "$idx2" = "0" ] && continue; red "序号无效"; pause; continue; fi
        local new2="" j2=1
        for d in "${arr2[@]}"; do
          d="$(echo "$d" | sed 's/^ *//; s/ *$//')"; [ -z "$d" ] && continue
          [ "$j2" -ne "$idx2" ] && { [ -z "$new2" ] && new2="$d" || new2="${new2},${d}"; }
          j2=$((j2+1))
        done
        V6_STRICT_SITES="$new2"; save_outbound; apply_policy_all; green "已删除并应用"; pause
        ;;
      6) apply_policy_all; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

xray_menu(){
  while true; do
    cls
    local xs as
    if [ -x "$XRAY_BIN" ]; then
      xs=$(is_running xray && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
    else
      xs="${C_BAD}未安装${C_RST}"
    fi
    if service_exists tunnel-argo; then
      as=$(is_running tunnel-argo && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
    else
      as="${C_BAD}未配置${C_RST}"
    fi

    echo -e "${C_XRAY}=============== Xray管理 ===============${C_RST}"
    echo -e "${C_XRAY}Xray${C_RST}: ${xs}     ${C_ARGO}Argo${C_RST}: ${as}"
    echo "-----------------------------------------------"
    echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_ARGO}Argo${C_RST}              ${C_VIEW} 6.${C_RST} ${C_VIEW}查看${C_RST}${C_NODE}节点${C_RST}"
    echo -e "${C_RESTART} 8.${C_RST} ${C_RESTART}重启${C_RST}${C_XRAY}Xray${C_RST}              ${C_MODIFY} 5.${C_RST} ${C_MODIFY}修改${C_RST}${C_UUID}UUID${C_RST}"
    echo -e "${C_RESTART} 7.${C_RST} ${C_RESTART}重启${C_RST}${C_ARGO}Argo${C_RST}              ${C_MANAGE} 3.${C_RST} ${C_MANAGE}管理${C_RST}${C_SOCKS5}Socks5${C_RST}"
    echo -e "${C_RESTART} 10.${C_RST} ${C_VIEW}实时${C_RST}${C_RESTART}日志${C_RST}${C_XRAY}(DEBUG)${C_RST}       ${C_MANAGE} 4.${C_RST} ${C_MANAGE}管理${C_RST}${C_FREEFLOW}免流${C_RST}"
    echo -e "${C_BAD} 9.${C_RST} ${C_BAD}卸载${C_RST}${C_XRAY}Xray${C_RST}              ${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) install_argo; pause ;;
      2) uninstall_argo; pause ;;
      3) manage_socks5 ;;
      4) manage_freeflow ;;
      5) prompt "新UUID(回车自动): " u; [ -z "$u" ] && u="$(gen_uuid)"; set_xray_uuid "$u"; pause ;;
      6) show_xray_nodes; pause ;;
      7) service_exists tunnel-argo && svc restart tunnel-argo && green "Argo 已重启" || red "Argo未安装"; pause ;;
      8) service_exists xray && svc restart xray && green "Xray 已重启" || red "Xray未安装"; pause ;;
      9)
        svc stop tunnel-argo; svc disable tunnel-argo
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service "${WORK}/argo_start.sh" "${WORK}/argo" "$ARGO_DOMAIN" "$ARGO_YML" "$ARGO_JSON"
        svc stop xray; svc disable xray
        rm -f /etc/init.d/xray /etc/systemd/system/xray.service "$XRAY_BIN" "$XRAY_CONF" "$FREEFLOW_CONF"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
        green "Xray已卸载"; pause
        ;;
      10) foreground_xray_log ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

sbox_menu(){
  while true; do
    cls
    local st
    if [ -x "$SB_BIN" ]; then
      st=$(is_running tuic-box && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
    else
      st="${C_BAD}未安装${C_RST}"
    fi
    echo -e "${C_SBOX}=============== Sbox管理 ===============${C_RST}"
    echo -e "Sbox: ${st}"
    echo "-----------------------------------------------"
    echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_TUIC}Tuic${C_RST}"
    echo -e "${C_VIEW} 2.${C_RST} ${C_VIEW}查看${C_RST}${C_NODE}节点${C_RST}"
    echo -e "${C_RESTART} 3.${C_RST} ${C_RESTART}重启${C_RST}${C_TUIC}Tuic${C_RST}"
    echo -e "${C_RESTART} 5.${C_RST} ${C_VIEW}实时${C_RST}${C_RESTART}日志${C_RST}(DEBUG)"
    echo -e "${C_BAD} 4.${C_RST} ${C_BAD}卸载${C_RST}${C_TUIC}Tuic${C_RST}"
    echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) install_tuic; pause ;;
      2) show_tuic_node; pause ;;
      3) service_exists tuic-box && start_tuic_check && green "Tuic已重启" || red "Tuic未安装"; pause ;;
      4) uninstall_tuic; pause ;;
      5) foreground_sbox_log ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

sys_info(){
  local osv ker virt mem disk
  if is_alpine; then
    osv="Alpine $(cat /etc/alpine-release 2>/dev/null || echo "")"
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ -n "${ID:-}" ] && [ -n "${VERSION_ID:-}" ]; then
      osv="$(echo "$ID" | sed 's/^[a-z]/\U&/') ${VERSION_ID}"
    else
      osv="${PRETTY_NAME:-Linux}"
    fi
  else
    osv="Linux"
  fi

  ker="$(cut -d- -f1 < /proc/sys/kernel/osrelease 2>/dev/null || uname -r)"

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  else
    if grep -qaE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
      virt="docker"
    elif grep -qa 'lxc' /proc/1/cgroup 2>/dev/null || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
      virt="lxc"
    elif [ -f /proc/vz/version ]; then
      virt="openvz"
    elif grep -qi 'kvm' /proc/cpuinfo 2>/dev/null; then
      virt="kvm"
    else
      virt="unknown"
    fi
  fi

  mem="$(awk '/MemTotal/{m=$2/1024; if(m>1024) printf"%.1fG",m/1024; else printf"%.0fM",m}' /proc/meminfo 2>/dev/null)"
  disk="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
  echo "${osv} | ${ker} | ${virt^^} | ${mem} | ${disk}"
}
mem_used_disp(){
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{u=t-a; if(t>1024*1024) printf "%.1fG/%.1fG",u/1024/1024,t/1024/1024; else printf "%.0fM/%.0fM",u/1024,t/1024}' /proc/meminfo 2>/dev/null
}

main_menu(){
  ensure_deps || { red "依赖安装失败，请检查网络/源"; exit 1; }
  mkdir -p "$WORK"
  load_state
  load_ip_cache >/dev/null 2>&1 || true

  [ "$IP_CHECKED" = "1" ] || {
    cls
    echo -e "\033[1;33mIP信息加载中，请稍候...\033[0m"
    check_ip || { red "IP检测失败，已跳过（不影响进入菜单）"; sleep 1; }
  }

  while true; do
    cls
    [ -f "$IPCACHE" ] && {
      local mt
      mt=$(stat -c %Y "$IPCACHE" 2>/dev/null || echo 0)
      [ "$mt" -gt "${IP_CACHE_MTIME:-0}" ] && IP_CACHE_MTIME="$mt" && load_ip_cache >/dev/null 2>&1 || true
    }

    local info mem u4 u6
    info="$(sys_info)"
    mem="$(mem_used_disp)"

    if [ -n "$WAN4" ]; then
      u4="\033[1;36m${WAN4}  (${EMOJI4} ${COUNTRY4} ${ISP4})\033[0m"
    else
      u4="${C_BAD}未检出${C_RST}"
    fi
    if [ -n "$WAN6" ]; then
      u6="\033[1;36m${WAN6}  (${EMOJI6} ${COUNTRY6} ${ISP6})\033[0m"
    else
      u6="${C_BAD}未检出${C_RST}"
    fi

    echo -e "OS : \033[1;36m${info}\033[0m"
    echo -e "v4 : ${u4}"
    echo -e "v6 : ${u6}"
    echo -e "Mem: \033[1;36m${mem}\033[0m"
    echo "-----------------------------------------------"

    printf "%b\n" "${C_MANAGE} 1.${C_RST} 管理${C_XRAY}Xray${C_RST}           ${C_MANAGE} 5.${C_RST} 管理${C_SWAP}SWAP${C_RST}"
    printf "%b\n" "${C_MANAGE} 2.${C_RST} 管理${C_SBOX}Sbox${C_RST}           ${C_MANAGE} 6.${C_RST} 创建${C_SHORTCUT}快捷${C_RST}"
    printf "%b\n" "${C_MANAGE} 3.${C_RST} 管理${C_OUTBOUND}出站${C_RST}           ${C_BAD} 9.${C_RST} ${C_BAD}彻底卸载${C_RST}"
    printf "%b\n" "${C_MANAGE} 4.${C_RST} 定时${C_RESTART}重启${C_RST}           ${C_BAD} 0.${C_RST} ${C_BAD}退出${C_RST}"

    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) xray_menu ;;
      2) sbox_menu ;;
      3) manage_outbound_menu ;;
      4) manage_restart_hours; pause ;;
      5) manage_swap ;;
      6) install_shortcut; pause ;;
      9) full_uninstall; pause ;;
      0) cls; exit 0 ;;
      *) red "无效"; pause ;;
    esac
  done
}

trap 'echo; cls; red "已中断"; exit 130' INT TERM
main_menu
