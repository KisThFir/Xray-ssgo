#!/usr/bin/env bash
set -euo pipefail

# ========== Color ==========
C_RST="\033[0m"
C_BAD="\033[1;91m"
C_OK="\033[1;32m"
C_WARN="\033[1;33m"
C_INFO="\033[1;36m"
C_SUB="\033[1;35m"
C_DIM="\033[0;90m"

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

# ========== Smart Menu Render ==========
C_NUM="\033[1;36m"
C_TXT="$C_RST"     # 基础文本颜色=终端默认色（Alpine 终端自然色）

# 高亮池：排除白色
KW_POOL=("\033[1;32m" "\033[1;35m" "\033[1;36m" "\033[1;33m")
_LAST_KW_IDX=-1

pick_kw_color(){
  local idx=$((RANDOM % ${#KW_POOL[@]}))
  [ "$idx" -eq "$_LAST_KW_IDX" ] && idx=$(((idx + 1) % ${#KW_POOL[@]}))
  _LAST_KW_IDX="$idx"
  printf '%b' "${KW_POOL[$idx]}"
}

auto_hl(){
  local s="$1"
  local pre kw c left right

  # 返回/退出固定红色
  case "$s" in
    返回|退出)
      printf "%b%s%b" "$C_BAD" "$s" "$C_RST"; return
      ;;
  esac

  # 任何包含“卸载”的文本都高危红色处理
  if [[ "$s" == *卸载* ]]; then
    # 尽量仅把“卸载”及对象标红；前缀普通
    left="${s%%卸载*}"
    right="${s#*卸载}"
    printf "%b%s%b%b卸载%s%b" "$C_TXT" "$left" "$C_RST" "$C_BAD" "$right" "$C_RST"
    return
  fi

  # 动作词 + 关键对象词
  for pre in 管理 安装 查看 修改 重启 设置 创建 实时 配置 启用 关闭 删除 添加 定时 彻底; do
    if [[ "$s" == ${pre}* ]]; then
      kw="${s#$pre}"
      [ -z "$kw" ] && { printf "%b%s%b" "$C_TXT" "$s" "$C_RST"; return; }
      c="$(pick_kw_color)"
      printf "%b%s%b%b%s%b" "$C_TXT" "$pre" "$C_RST" "$c" "$kw" "$C_RST"
      return
    fi
  done

  # 默认整词高亮
  c="$(pick_kw_color)"
  printf "%b%s%b" "$c" "$s" "$C_RST"
}

menu_row2_auto(){
  local lnum="$1" ltxt="$2" rnum="$3" rtxt="$4"
  local left right
  left=$(printf "%b%2s.%b %s" "$C_NUM" "$lnum" "$C_RST" "$(auto_hl "$ltxt")")
  right=$(printf "%b%2s.%b %s" "$C_NUM" "$rnum" "$C_RST" "$(auto_hl "$rtxt")")
  printf "%-54b%s\n" "$left" "$right"    # 加宽列间距
}

menu_item_auto(){
  local num="$1" txt="$2"
  printf "%b%2s.%b %s\n" "$C_NUM" "$num" "$C_RST" "$(auto_hl "$txt")"
}

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
HY2_STATE="${WORK}/hy2_state.conf"

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

# YouTube 模式：0关闭 1兼容 2严格
YOUTUBE_MODE=0
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

    command -v curl >/dev/null 2>&1 && curl -L --connect-timeout 10 --max-time 120 -o "$out" "$url" >/dev/null 2>&1 || true
    if [ ! -s "$out" ] && command -v wget >/dev/null 2>&1; then
      if wget --help 2>&1 | grep -q -- '--show-progress'; then
        wget -q --show-progress --timeout=30 --tries=1 -O "$out" "$url" || true
      else
        wget -q -T 30 -O "$out" "$url" || true
      fi
    fi

    if [ -f "$out" ]; then
      local sz; sz=$(wc -c < "$out" 2>/dev/null || echo 0)
      [ "${sz:-0}" -ge "$min" ] && return 0
    fi
    t=$((t+1)); sleep 2
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
normalize_country_code(){
  local c="$(echo "${1:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local cu="$(echo "$c" | tr '[:lower:]' '[:upper:]')"
  if [ ${#cu} -eq 2 ] && echo "$cu" | grep -Eq '^[A-Z]{2}$'; then
    echo "$cu"; return
  fi
  case "$c" in
    新加坡) echo "SG" ;;
    日本) echo "JP" ;;
    香港) echo "HK" ;;
    台湾) echo "TW" ;;
    美国) echo "US" ;;
    英国) echo "GB" ;;
    德国) echo "DE" ;;
    法国) echo "FR" ;;
    韩国) echo "KR" ;;
    马来西亚) echo "MY" ;;
    印度) echo "IN" ;;
    俄罗斯) echo "RU" ;;
    *) echo "$cu" ;;
  esac
}
clean_isp(){
  local s="$1"
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
  [ -z "$emo" ] && emo="$(country_flag "$cc" 2>/dev/null || true)"
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
    cc="$(normalize_country_code "$cc")"
    if [ "$fam" = "4" ]; then
      WAN4="$ip"; COUNTRY4="$cc"
      EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
      ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
    else
      WAN6="$ip"; COUNTRY6="$cc"
      EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"
      ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
    fi
    return 0
  fi

  cc="$(echo "$j" | jq -r '.country // empty' 2>/dev/null || true)"
  cc="$(normalize_country_code "$cc")"
  org="$(echo "$j" | jq -r '.org // empty' 2>/dev/null || true)"
  if [ "$fam" = "4" ]; then
    WAN4="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY4="$cc"
    EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
    ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY6="$cc"
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
  cc="$(normalize_country_code "$cc")"
  emo="$(echo "$j" | jq -r '.emoji // empty' 2>/dev/null || true)"
  asn="$(echo "$j" | jq -r '.asn // empty' 2>/dev/null || true)"
  isp="$(echo "$j" | jq -r '.isp // empty' 2>/dev/null || true)"
  [ -z "$ip" ] && return 1

  if ! printf '%s' "$emo" | grep -q '[🇦-🇿]'; then emo=""; fi

  if [ "$fam" = "4" ]; then
    WAN4="$ip"; COUNTRY4="$cc"
    EMOJI4="$emo"; [ -z "$EMOJI4" ] && EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"
    ISP4="$(clean_isp "${asn:+AS${asn} }${isp}")"; [ -z "$ISP4" ] && ISP4="$(clean_isp "$isp")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$ip"; COUNTRY6="$cc"
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

# ========== 输出策略 ==========
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
yt_domains_csv(){ echo "youtube.com,youtu.be,googlevideo.com,ytimg.com"; }
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
yt_mode_str(){
  case "$YOUTUBE_MODE" in
    0) echo "关闭" ;;
    1) echo "兼容" ;;
    2) echo "严格" ;;
    *) echo "关闭" ;;
  esac
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

  if [ "$(echo "$strict" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$strict" \
      '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"ip":["0.0.0.0/0"],"outboundTag":"block-v4","tag":"v6-strict-reject-rule"}]'
    update_xray --argjson d "$strict" \
      '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-strict-route-rule"}]'
  fi

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

# ========== Outbound menu ==========
manage_outbound_menu(){
  while true; do
    cls
    local merged_list merged_json merged_disp
    merged_list="$(merge_csv "$V6_COMPAT_SITES" "$V6_STRICT_SITES")"
    merged_json="$(csv_to_json_unique "$merged_list")"
    merged_disp="$(echo "$merged_json" | jq -r 'join(",")')"
    [ -z "$merged_disp" ] && merged_disp="（空）"

    echo -e "${C_WARN}========== 出站管理（Xray + Sbox）==========${C_RST}"
    echo -e "默认出站: \033[1;36mIPv4\033[0m"
    echo -e "YouTube模式: \033[1;36m$(yt_mode_str)\033[0m"
    echo -e "IPv6出站列表: \033[1;36m${merged_disp}\033[0m"
    echo "-----------------------------------------------"
    menu_item_auto "1" "设置YouTube模式"
    menu_item_auto "2" "添加IPv6规则"
    menu_item_auto "3" "删除IPv6规则"
    menu_item_auto "4" "重启服务应用规则"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "输入模式(0关闭/1兼容/2严格): " m
        [[ "$m" =~ ^[012]$ ]] || { red "输入无效"; pause; continue; }
        YOUTUBE_MODE="$m"; save_outbound; apply_policy_all; green "已更新并应用"; pause
        ;;
      2)
        local s md
        prompt "输入域名(逗号分隔): " s
        [ -z "$s" ] && { red "不能为空"; pause; continue; }
        echo "选择模式：1=兼容 2=严格"
        prompt "输入模式: " md
        case "$md" in
          1)
            [ -z "$V6_COMPAT_SITES" ] && V6_COMPAT_SITES="$s" || V6_COMPAT_SITES="${V6_COMPAT_SITES},${s}"
            V6_COMPAT_SITES="$(echo "$V6_COMPAT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
            ;;
          2)
            [ -z "$V6_STRICT_SITES" ] && V6_STRICT_SITES="$s" || V6_STRICT_SITES="${V6_STRICT_SITES},${s}"
            V6_STRICT_SITES="$(echo "$V6_STRICT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
            ;;
          *) red "模式无效"; pause; continue ;;
        esac
        save_outbound; apply_policy_all; green "已添加并应用"; pause
        ;;
      3)
        local all_json
        all_json="$(csv_to_json_unique "$(merge_csv "$V6_COMPAT_SITES" "$V6_STRICT_SITES")")"
        if [ "$(echo "$all_json" | jq 'length')" -eq 0 ]; then
          red "规则为空"; pause; continue
        fi
        echo "当前IPv6规则："
        echo "$all_json" | jq -r '.[]' | nl -w2 -s'. '
        echo " 0. 取消"
        prompt "输入序号: " idx
        [[ "$idx" =~ ^[0-9]+$ ]] || { red "输入无效"; pause; continue; }
        [ "$idx" -eq 0 ] && continue

        local target
        target="$(echo "$all_json" | jq -r ".[$((idx-1))] // empty")"
        [ -z "$target" ] && { red "序号无效"; pause; continue; }

        local cjson sjson
        cjson="$(csv_to_json_unique "$V6_COMPAT_SITES")"
        V6_COMPAT_SITES="$(echo "$cjson" | jq -r --arg t "$target" '[.[]|select(.!=$t)]|join(",")')"
        sjson="$(csv_to_json_unique "$V6_STRICT_SITES")"
        V6_STRICT_SITES="$(echo "$sjson" | jq -r --arg t "$target" '[.[]|select(.!=$t)]|join(",")')"

        save_outbound; apply_policy_all
        green "已删除并应用: $target"
        pause
        ;;
      4) apply_policy_all; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Menus ==========
xray_menu(){
  while true; do
    cls
    local xs as hs
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
    if [ -f "$HY2_STATE" ]; then hs="\033[1;36m已配置\033[0m"; else hs="${C_BAD}未配置${C_RST}"; fi

    echo -e "${C_OK}=============== Xray管理 ===============${C_RST}"
    echo -e "Xray: ${xs}   Argo: ${as}   HY2: ${hs}"
    echo "-----------------------------------------------"

    # 左列：安装/配置/重启/卸载主流程
    # 右列：日志/查看/修改（辅助）
    menu_row2_auto "1" "安装Argo"      "8"  "实时日志"
    menu_row2_auto "2" "安装HY2"       "9"  "查看节点"
    menu_row2_auto "3" "配置Socks5"    "10" "修改UUID"
    menu_row2_auto "4" "配置免流"      "0"  "返回"
    menu_row2_auto "5" "重启Argo"      ""   ""
    menu_row2_auto "6" "重启Xray"      ""   ""
    menu_row2_auto "7" "卸载Argo"      ""   ""
    menu_row2_auto "11" "卸载HY2"      ""   ""
    menu_row2_auto "12" "卸载Xray"     ""   ""

    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) install_argo; pause ;;
      2) install_hy2; pause ;;
      3) manage_socks5 ;;
      4) manage_freeflow ;;
      5) service_exists tunnel-argo && svc restart tunnel-argo && green "Argo 已重启" || red "Argo未安装"; pause ;;
      6) service_exists xray && svc restart xray && green "Xray 已重启" || red "Xray未安装"; pause ;;
      7) uninstall_argo; pause ;;
      8) foreground_xray_log ;;
      9) show_xray_nodes; pause ;;
      10) prompt "新UUID(回车自动): " u; [ -z "$u" ] && u="$(gen_uuid)"; set_xray_uuid "$u"; pause ;;
      11) uninstall_hy2; pause ;;
      12)
        svc stop tunnel-argo; svc disable tunnel-argo
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service "${WORK}/argo_start.sh" "${WORK}/argo" "$ARGO_DOMAIN" "$ARGO_YML" "$ARGO_JSON"
        svc stop xray; svc disable xray
        rm -f /etc/init.d/xray /etc/systemd/system/xray.service "$XRAY_BIN" "$XRAY_CONF" "$FREEFLOW_CONF" "$HY2_STATE"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
        green "Xray已卸载"; pause ;;
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
    echo -e "${C_SUB}=============== Sbox管理 ===============${C_RST}"
    echo -e "Sbox: ${st}"
    echo "-----------------------------------------------"
    menu_row2_auto "1" "安装Tuic" "2" "查看节点"
    menu_row2_auto "3" "重启Tuic" "5" "实时日志"
    menu_row2_auto "4" "卸载Tuic" "0" "返回"
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

# ========== Tuic menu helpers ==========
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

# ========== Restart/SWAP/Uninstall ==========
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
setup_cron_env(){
  command -v crontab >/dev/null 2>&1 && return
  if command -v apt-get >/dev/null 2>&1; then pkg_install cron; svc enable cron; svc start cron
  elif command -v apk >/dev/null 2>&1; then pkg_install dcron; rc-service dcron start >/dev/null 2>&1 || true; rc-update add dcron default >/dev/null 2>&1 || true
  else pkg_install cronie; svc enable crond; svc start crond; fi
}

# ========== Main ==========
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
  printf "%s  |  %s  |  %s  |  %s  |  %s" "$osv" "$ker" "${virt^^}" "$mem" "$disk"
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
      u4="\033[1;36m${WAN4} (${EMOJI4} ${COUNTRY4} ${ISP4})\033[0m"
    else
      u4="${C_BAD}未检出${C_RST}"
    fi
    if [ -n "$WAN6" ]; then
      u6="\033[1;36m${WAN6} (${EMOJI6} ${COUNTRY6} ${ISP6})\033[0m"
    else
      u6="${C_BAD}未检出${C_RST}"
    fi

    echo -e "${C_DIM}================ 系统信息 ================${C_RST}"
    echo -e "OS   : \033[1;36m${info}\033[0m"
    echo -e "Mem  : \033[1;36m${mem}\033[0m"
    echo "-----------------------------------------------"
    echo -e "IPv4 : ${u4}"
    echo -e "IPv6 : ${u6}"
    echo -e "${C_DIM}==========================================${C_RST}"
    echo

    menu_row2_auto "1" "管理Xray"   "5" "管理SWAP"
    menu_row2_auto "2" "管理Sbox"   "6" "创建快捷"
    menu_row2_auto "3" "管理出站"   "9" "彻底卸载"
    menu_row2_auto "4" "定时重启"   "0" "退出"
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
