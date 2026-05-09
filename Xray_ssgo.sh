#!/usr/bin/env bash
set -euo pipefail

# ---- UTF-8 bootstrap (for emoji/Unicode) ----
ensure_utf8_locale() {
  # 已是 UTF-8 就不动
  case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) return 0 ;;
  esac

  # 优先 C.UTF-8（Debian/Ubuntu/Alpine 常见）
  if locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    return 0
  fi

  # 其次 en_US.UTF-8
  if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    return 0
  fi

  # 再其次 zh_CN.UTF-8（有些中文环境只有这个）
  if locale -a 2>/dev/null | grep -qi '^zh_CN\.utf8$'; then
    export LANG=zh_CN.UTF-8
    export LC_ALL=zh_CN.UTF-8
    return 0
  fi
}
ensure_utf8_locale

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
C_TXT="\033[1;36m"

KW_POOL=("\033[1;32m" "\033[1;35m" "\033[1;33m" "\033[1;91m" "\033[1;92m")
_LAST_KW_IDX=-1

pick_kw_color(){
  local idx=$((RANDOM % ${#KW_POOL[@]}))
  [ "$idx" -eq "$_LAST_KW_IDX" ] && idx=$(((idx+1) % ${#KW_POOL[@]}))
  _LAST_KW_IDX="$idx"
  printf '%b' "${KW_POOL[$idx]}"
}

auto_hl(){
  local s="$1"
  local pre kw c left right

  case "$s" in
    返回|退出)
      printf "%b%s%b" "$C_BAD" "$s" "$C_RST"
      return
      ;;
  esac

  # 含“卸载”固定红色
  if [[ "$s" == *卸载* ]]; then
    left="${s%%卸载*}"
    right="${s#*卸载}"
    printf "%b%s%b%b卸载%b%b%s%b" \
      "$C_TXT" "$left" "$C_RST" \
      "$C_BAD" "$C_RST" \
      "$C_TXT" "$right" "$C_RST"
    return
  fi

  # 前缀 + 关键词高亮
  for pre in 管理 安装 查看 修改 重启 设置 创建 实时 配置 启用 关闭 删除 添加 定时 彻底; do
    if [[ "$s" == "$pre"* ]]; then
      kw="${s#$pre}"
      if [ -z "$kw" ]; then
        printf "%b%s%b" "$C_TXT" "$s" "$C_RST"
      else
        c="$(pick_kw_color)"
        printf "%b%s%b%b%s%b" "$C_TXT" "$pre" "$C_RST" "$c" "$kw" "$C_RST"
      fi
      return
    fi
  done

  printf "%b%s%b" "$C_TXT" "$s" "$C_RST"
}

strip_ansi(){ sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'; }
vlen(){ printf '%s' "$1" | strip_ansi | awk '{print length}'; }

term_cols(){
  local c
  c="$(tput cols 2>/dev/null || stty size 2>/dev/null | awk '{print $2}' || echo 80)"
  [ -z "$c" ] && c=80
  echo "$c"
}

menu_row2_auto(){
  local lnum="$1" ltxt="$2" rnum="${3:-}" rtxt="${4:-}"
  local left right right_col=20

  left="$(printf "%b%2s.%b %s" "$C_NUM" "$lnum" "$C_RST" "$(auto_hl "$ltxt")")"

  if [ -z "$rnum" ] || [ -z "$rtxt" ]; then
    printf "%s\n" "$left"
    return
  fi

  right="$(printf "%b%2s.%b %s" "$C_NUM" "$rnum" "$C_RST" "$(auto_hl "$rtxt")")"
  printf "%s\033[%sG%s\n" "$left" "$right_col" "$right"
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

TLS_BASE="/etc/ssgo/tls"
TLS_DIR_TUIC="${TLS_BASE}/tuic"
TLS_DIR_HY2="${TLS_BASE}/hy2"

ARGO_DOMAIN="${WORK}/domain_argo.txt"
ARGO_YML="${WORK}/tunnel_argo.yml"
ARGO_JSON="${WORK}/tunnel_argo.json"

FREEFLOW_CONF="${WORK}/freeflow.conf"
RESTART_CONF="${WORK}/restart.conf"
OUTBOUND_CONF="${WORK}/outbound_policy.conf"
IPCACHE="${WORK}/ip_cache.conf"
HY2_STATE="${WORK}/hy2_state.conf"
HY2_HOP_STATE="${WORK}/hy2_hop_state.conf"

SWAP_LOG="/tmp/swap.log"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}
SS_FIXED_IP="172.64.147.74"

SB_FIXED_VER="v1.13.11"
HY2_SELF_SNI_DEFAULT="www.amd.com"

# GitHub 下载加速策略
GHFAST_PREFIX="https://ghfast.top/"
GH_SPEED_THRESHOLD_MBPS=20          # 低于该速度切备用
GH_SPEED_THRESHOLD_BPS=2500000      # 20*1000*1000/8
GH_USE_FAST_MIRROR=0                # 0=主站优先 1=已锁定备用（不回切）

# 快捷方式拉取源（可通过环境变量覆盖）
SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/KisThFir/Xray-ssgo/refs/heads/main/Xray_ssgo.sh"
SCRIPT_URL="${SCRIPT_URL:-$SCRIPT_URL_DEFAULT}"

FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_HOURS=0
XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

# YouTube 模式：1=关闭(默认) 2=严格
YOUTUBE_MODE=1
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
# CPU usage cache
CPU_LAST_TOTAL=0
CPU_LAST_IDLE=0

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
  if is_alpine; then rc-service "$1" status 2>/dev/null | grep -q started
  else [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]
  fi
}

# ========== Package ==========
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

pkg_install(){
  [ "$#" -eq 0 ] && return 0

  local mgr=""
  if command -v apt-get >/dev/null 2>&1; then
    mgr="apt"
  elif command -v dnf >/dev/null 2>&1; then
    mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then
    mgr="yum"
  elif command -v apk >/dev/null 2>&1; then
    mgr="apk"
  else
    red "未找到可用包管理器"
    return 1
  fi

  local pkgs=() p mapped
  for p in "$@"; do
    mapped="$p"
    case "$mgr:$p" in
      dnf:iproute2|yum:iproute2) mapped="iproute" ;;   # RHEL系包名
      apk:coreutils) mapped="coreutils" ;;             # 保留
      apt:iproute2|apk:iproute2) mapped="iproute2" ;;  # Debian/Alpine
    esac
    pkgs+=("$mapped")
  done

  case "$mgr" in
    apt)
      apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf install -y "${pkgs[@]}" >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y "${pkgs[@]}" >/dev/null 2>&1 || true
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 || true
      ;;
  esac
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
  need_cmd ss || pkg_install iproute2
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
      if is_alpine; then echo "-linux-amd64-musl"; else echo "-linux-amd64"; fi ;;
    aarch64|arm64)
      if is_alpine; then echo "-linux-arm64-musl"; else echo "-linux-arm64"; fi ;;
    *)
      echo "" ;;
  esac
}
normalize_path(){ [ -z "${1:-}" ] && echo "/" || { case "$1" in /*) echo "$1" ;; *) echo "/$1" ;; esac; }; }
gen_uuid(){ cat /proc/sys/kernel/random/uuid; }

is_github_url(){
  case "$1" in
    https://github.com/*|https://raw.githubusercontent.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

ghfast_url(){
  local u="$1"
  echo "${GHFAST_PREFIX}${u}"
}

smart_download(){
  local out="$1" url="$2" min="$3"
  local t=0 u="" is_gh=0 elapsed sz speed

  is_github_url "$url" && is_gh=1 || is_gh=0

  while [ "$t" -lt 3 ]; do
    rm -f "$out"

    # 已锁定备用：GitHub 链接一律走 ghfast，不再回主站
    if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 1 ]; then
      u="$(ghfast_url "$url")"
    else
      u="$url"
    fi

    local ts_start ts_end
    ts_start="$(date +%s)"

    # 下载（curl 优先，wget 兜底）
    if command -v curl >/dev/null 2>&1; then
      curl -L --connect-timeout 10 --max-time 180 -o "$out" "$u" >/dev/null 2>&1 || true
    fi
    if [ ! -s "$out" ] && command -v wget >/dev/null 2>&1; then
      if wget --help 2>&1 | grep -q -- '--show-progress'; then
        wget -q --show-progress --timeout=40 --tries=1 -O "$out" "$u" || true
      else
        wget -q -T 40 -O "$out" "$u" || true
      fi
    fi

    ts_end="$(date +%s)"
    elapsed=$((ts_end - ts_start))
    [ "$elapsed" -le 0 ] && elapsed=1

    if [ -f "$out" ]; then
      sz="$(wc -c < "$out" 2>/dev/null || echo 0)"
      speed=$((sz / elapsed))   # Bytes/s

      # 文件合格
      if [ "${sz:-0}" -ge "$min" ]; then
        # 仅对 GitHub 主站测速，低于阈值则切备用并重下一轮
        if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 0 ] && [ "$u" = "$url" ]; then
          if [ "$speed" -lt "${GH_SPEED_THRESHOLD_BPS:-2500000}" ]; then
            yellow "GitHub主站速度低于${GH_SPEED_THRESHOLD_MBPS}Mbps，切换并锁定 ghfast 备用源"
            GH_USE_FAST_MIRROR=1
            rm -f "$out"
            t=$((t+1))
            sleep 1
            continue
          fi
        fi
        return 0
      fi
    fi

    # 如果主站失败且是 GitHub，立即切备用并锁定（避免后续反复失败）
    if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 0 ] && [ "$u" = "$url" ]; then
      yellow "GitHub主站下载失败，切换并锁定 ghfast 备用源"
      GH_USE_FAST_MIRROR=1
    fi

    rm -f "$out"
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

# ========== HY2 hop helper ==========
is_lxc_env(){
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v="$(systemd-detect-virt --container 2>/dev/null || true)"
    echo "$v" | grep -qi '^lxc$' && return 0
  fi
  tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=lxc$' && return 0
  grep -qa 'lxc' /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

iptables_nat_writable(){
  command -v iptables >/dev/null 2>&1 || return 1
  local tp=65530
  if iptables -t nat -A PREROUTING -p udp --dport "$tp" -j REDIRECT --to-ports "$tp" 2>/dev/null; then
    iptables -t nat -D PREROUTING -p udp --dport "$tp" -j REDIRECT --to-ports "$tp" 2>/dev/null || true
    return 0
  fi
  return 1
}

save_hy2_hop_state(){
  local mode="$1" base="$2" spec="$3" _unused="$4"
  cat > "$HY2_HOP_STATE" <<EOF
mode=${mode}
base=${base}
spec=${spec}
EOF
}

clear_hy2_hop_rules(){
  [ -f "$HY2_HOP_STATE" ] || return 0
  # shellcheck disable=SC1090
  . "$HY2_HOP_STATE" 2>/dev/null || true
  [ -z "${mode:-}" ] && return 0

  if [ "${mode}" = "iptables" ]; then
    if [ -n "${spec:-}" ] && command -v iptables >/dev/null 2>&1; then
      if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        iptables -t nat -D PREROUTING -p udp --dport "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" -j REDIRECT --to-ports "${base}" 2>/dev/null || true
      else
        local IFS=',' p
        for p in $spec; do
          p="$(echo "$p" | sed 's/[[:space:]]//g')"
          [[ "$p" =~ ^[0-9]+$ ]] || continue
          iptables -t nat -D PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "${base}" 2>/dev/null || true
        done
      fi
    fi
  else
    [ -f "$XRAY_CONF" ] && update_xray 'del(.inbounds[]? | select(.tag|startswith("hy2-in-hop-")))' || true
  fi
  rm -f "$HY2_HOP_STATE"
}

apply_hy2_hop(){
  local base_port="$1" auth="$2" obfs="$3" domain="$4" crt="$5" key="$6" hop_spec="${7:-}"

  clear_hy2_hop_rules || true
  [ -z "$hop_spec" ] && return 0

  # 解析 hop_spec：支持 "a-b" 或 "a,b,c"
  local ports=()
  if [[ "$hop_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}" p
    [ "$s" -gt "$e" ] && { red "端口范围无效: $hop_spec"; return 1; }
    for ((p=s; p<=e; p++)); do ports+=("$p"); done
  else
    local IFS=',' one
    for one in $hop_spec; do
      one="$(echo "$one" | sed 's/[[:space:]]//g')"
      [[ "$one" =~ ^[0-9]+$ ]] || continue
      ports+=("$one")
    done
    [ "${#ports[@]}" -eq 0 ] && { red "端口列表无效: $hop_spec"; return 1; }
  fi

  # 无权限/LXC => native 多入站（只加你输入的端口）
  if is_lxc_env || ! iptables_nat_writable; then
    yellow "HY2端口跳跃：检测到LXC/NAT受限，使用应用层多端口监听模式"
    local p hops='[]'
    for p in "${ports[@]}"; do
      [ "$p" -eq "$base_port" ] && continue
      hops="$(echo "$hops" | jq \
        --argjson pp "$p" \
        --arg auth "$auth" \
        --arg obfs "$obfs" \
        --arg d "$domain" \
        --arg crt "$crt" \
        --arg key "$key" \
        '. + [{
          "tag":"hy2-in-hop-"+($pp|tostring),
          "listen":"::",
          "port":$pp,
          "protocol":"hysteria",
          "settings":{"version":2,"clients":[{"auth":$auth,"email":"hy2@local"}]},
          "streamSettings":{
            "network":"hysteria",
            "security":"tls",
            "tlsSettings":{
              "serverName":$d,
              "alpn":["h3"],
              "certificates":[{"certificateFile":$crt,"keyFile":$key}]
            },
            "hysteriaSettings":{"version":2},
            "finalmask":{
              "udp":[{"type":"salamander","settings":{"password":$obfs}}],
              "quicParams":{
                "congestion":"bbr",
                "bbrProfile":"standard",
                "maxIdleTimeout":30,
                "keepAlivePeriod":10,
                "disablePathMTUDiscovery":false
              }
            }
          },
          "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}
        }]')"
    done
    update_xray --argjson hs "$hops" '.inbounds += $hs'
    save_hy2_hop_state "native" "$base_port" "$hop_spec" ""
  else
    # iptables 模式：只做 IPv4，不加 ip6tables（IPv6 直连 base port）
    yellow "HY2端口跳跃：使用iptables REDIRECT模式（仅IPv4）"
    if [[ "$hop_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
      iptables -t nat -A PREROUTING -p udp --dport "${s}:${e}" -j REDIRECT --to-ports "${base_port}" 2>/dev/null || true
    else
      local p
      for p in "${ports[@]}"; do
        iptables -t nat -A PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "${base_port}" 2>/dev/null || true
      done
    fi
    save_hy2_hop_state "iptables" "$base_port" "$hop_spec" ""
  fi
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
    [[ "$YOUTUBE_MODE" =~ ^[12]$ ]] || YOUTUBE_MODE=1
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
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || { echo ""; return; }

  # 非 UTF-8 环境不输出 emoji，避免 F1EFF1F5
  case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) ;;
    *) echo ""; return ;;
  esac

  local o1 o2 cp1 cp2
  o1=$(printf '%d' "'${cc:0:1}")
  o2=$(printf '%d' "'${cc:1:1}")

  # Regional Indicator: U+1F1E6..U+1F1FF
  cp1=$((0x1F1E6 + o1 - 65))
  cp2=$((0x1F1E6 + o2 - 65))

  eval "printf '%s' \$'\\U$(printf '%08X' "$cp1")\\U$(printf '%08X' "$cp2")'"
}

normalize_country_code(){
  local c="$(echo "${1:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local cu="$(echo "$c" | tr '[:lower:]' '[:upper:]')"
  if [ ${#cu} -eq 2 ] && echo "$cu" | grep -Eq '^[A-Z]{2}$'; then echo "$cu"; return; fi
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
  local cc isp emo short_isp
  if [ -n "$COUNTRY4" ] || [ -n "$ISP4" ]; then
    cc="${COUNTRY4^^}"; isp="$ISP4"; emo="$EMOJI4"
  else
    cc="${COUNTRY6^^}"; isp="$ISP6"; emo="$EMOJI6"
  fi
  [ -z "$emo" ] && emo="$(country_flag "$cc" 2>/dev/null || true)"

  # 精简ISP名称：只保留第一个单词（通常为公司名称核心部分）
  if [ -n "$isp" ]; then
    # 使用awk截取第一个单词，并转换为首字母大写
    short_isp=$(echo "$isp" | awk '{print toupper(substr($1,1,1)) tolower(substr($1,2))}')
    BASE_FULL="${emo} ${cc} ${short_isp}"
  else
    BASE_FULL="${emo} ${cc}"
  fi

  [ -z "$BASE_FULL" ] && BASE_FULL="Node"
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
      WAN4="$ip"; COUNTRY4="$cc"; EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"; ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
    else
      WAN6="$ip"; COUNTRY6="$cc"; EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"; ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
    fi
    return 0
  fi

  cc="$(echo "$j" | jq -r '.country // empty' 2>/dev/null || true)"
  cc="$(normalize_country_code "$cc")"
  org="$(echo "$j" | jq -r '.org // empty' 2>/dev/null || true)"
  if [ "$fam" = "4" ]; then
    WAN4="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY4="$cc"; EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"; ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"
    COUNTRY6="$cc"; EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"; ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
  fi
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

  local ip4 ip6
  ip4="$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip4" ] && fill_by_ipinfo_ip 4 "$ip4" || true

  ip6="$(curl -6 -sf --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  if [ -n "$ip6" ]; then
    WAN6="$ip6"; fill_by_ipinfo_ip 6 "$WAN6" || true
  else
    ip6="$(get_local_ipv6_fallback || true)"
    [ -n "$ip6" ] && { WAN6="$ip6"; fill_by_ipinfo_ip 6 "$WAN6" || true; }
  fi

  apply_base_name || true
  IP_CHECKED=1
  save_ip_cache || true
  return 0
}

# 节点地址：优先IPv6（URL中需要[]），无IPv6再IPv4
pick_node_host(){
  if [ -n "${WAN6:-}" ]; then
    echo "[${WAN6}]"
  elif [ -n "${WAN4:-}" ]; then
    echo "${WAN4}"
  else
    echo ""
  fi
}

# ========== Domain helpers ==========
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

build_v6_compat_domains_json(){
  csv_to_json_unique "$V6_COMPAT_SITES"
}
build_v6_strict_domains_json(){
  csv_to_json_unique "$V6_STRICT_SITES"
}
yt_mode_str(){
  case "$YOUTUBE_MODE" in
    2) echo "严格" ;;
    *) echo "关闭" ;;
  esac
}

# ========== Xray core ==========
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

ensure_geosite(){
  [ -s "${WORK}/geosite.dat" ] && return 0
  yellow "未检测到 geosite.dat，尝试下载..."

  # 常用规则源（稳定）
  if smart_download "${WORK}/geosite.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" 1000000; then
    green "geosite.dat 已就绪"
    return 0
  fi

  red "geosite.dat 下载失败"
  return 1
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
    rm -f "${WORK}/xray.zip" "${WORK}/README.md" "${WORK}/LICENSE"
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

# ========== Outbound apply ==========
apply_policy_xray(){
  [ -f "$XRAY_CONF" ] || return 0
  ensure_dns_rule

  # 保证默认出站顺序（direct-v4 在前）
  update_xray '
    .outbounds = (
      [
        {"protocol":"freedom","tag":"direct-v4","settings":{"domainStrategy":"UseIPv4"}},
        {"protocol":"freedom","tag":"direct-v6","settings":{"domainStrategy":"UseIPv6"}},
        {"protocol":"blackhole","tag":"block-v4"}
      ]
      + (
          [ .outbounds[]? | select(.tag=="dns-out") ]
          | if length>0 then . else [{"protocol":"dns","tag":"dns-out"}] end
        )
      + [ .outbounds[]? | select(.tag!="direct" and .tag!="direct-v4" and .tag!="direct-v6" and .tag!="block-v4" and .tag!="dns-out") ]
    )'

  # 清理旧规则（含 geosite 新tag）
  update_xray 'del(.routing.rules[]? | select(
    .tag=="v6-compat-rule" or
    .tag=="v6-strict-route-rule" or
    .tag=="v6-strict-reject-rule" or
    .tag=="v6-geosite-compat-rule" or
    .tag=="v6-geosite-strict-route-rule" or
    .tag=="v6-geosite-strict-reject-rule"
  ))'

  local compat strict
  compat="$(build_v6_compat_domains_json)"
  strict="$(build_v6_strict_domains_json)"

  # YouTube：仅关闭/严格
  if [ "$YOUTUBE_MODE" = "2" ]; then
    if ensure_geosite; then
      update_xray '.routing.rules += [{"type":"field","domain":["geosite:youtube"],"ip":["0.0.0.0/0"],"outboundTag":"block-v4","tag":"v6-geosite-strict-reject-rule"}]'
      update_xray '.routing.rules += [{"type":"field","domain":["geosite:youtube"],"outboundTag":"direct-v6","tag":"v6-geosite-strict-route-rule"}]'
    else
      red "geosite 不可用，YouTube 严格规则未应用"
    fi
  fi

  # 你手动加的自定义域名规则（原逻辑保留）
  if [ "$(echo "$strict" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$strict" '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"ip":["0.0.0.0/0"],"outboundTag":"block-v4","tag":"v6-strict-reject-rule"}]'
    update_xray --argjson d "$strict" '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-strict-route-rule"}]'
  fi
  if [ "$(echo "$compat" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$compat" '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-compat-rule"}]'
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
      + [{"type":"direct","tag":"direct_ipv4","domain_resolver":{"server":"dns_cf","strategy":"ipv4_only"}}]
      + [{"type":"direct","tag":"direct_ipv6","domain_resolver":{"server":"dns_cf","strategy":"ipv6_only"}}]
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

# 安装协议时询问是否开启 YouTube 严格V6出站
ask_enable_youtube_strict(){
  local yn
  prompt "是否开启 YouTube 严格V6出站? (1=关闭 2=严格，默认1): " yn
  case "$yn" in
    2) YOUTUBE_MODE=2 ;;
    *) YOUTUBE_MODE=1 ;;
  esac
  save_outbound
  apply_policy_all || true
}

# ========== Argo ==========
install_cloudflared(){
  mkdir -p "$WORK"

  local arch url tmp bin
  bin="${WORK}/argo"

  arch="$(detect_cloudflared_arch)"
  [ -z "$arch" ] && { red "架构不支持 cloudflared"; return 1; }

  case "$arch" in
    amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    386)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
    arm)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *) red "未知架构: $arch"; return 1 ;;
  esac

  # 已存在且可执行则复用
  if [ -x "$bin" ] && "$bin" --version >/dev/null 2>&1; then
    green "cloudflared 已存在，跳过下载"
    return 0
  fi

  tmp="${WORK}/argo.tmp"
  smart_download "$tmp" "$url" 10000000 || { red "下载 cloudflared 失败"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$bin"
  chmod +x "$bin"

  "$bin" --version >/dev/null 2>&1 || { red "cloudflared 校验失败"; rm -f "$bin"; return 1; }
  green "cloudflared 安装完成"
}

install_argo(){
  install_xray || return 1
  ensure_dns_rule || return 1
  install_cloudflared || return 1
    
  local domain auth ss_pass mc ss_method tunnel_id uuid
  prompt "Argo域名: " domain; [ -z "$domain" ] && { red "不能为空"; return 1; }
  prompt "Argo JSON凭证: " auth; echo "$auth" | grep -q "TunnelSecret" || { red "必须是JSON凭证"; return 1; }
  prompt "SS密码(回车随机UUID): " ss_pass; [ -z "$ss_pass" ] && ss_pass="$(gen_uuid)"
    prompt "SS加密(1=aes-128-gcm 2=aes-256-gcm，默认1): " mc; [ -z "$mc" ] && mc=1; ss_method="aes-128-gcm"; [ "$mc" = "2" ] && ss_method="aes-256-gcm"

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

  [ -x "${WORK}/argo" ] || { red "cloudflared 不存在: ${WORK}/argo"; return 1; }

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

  ask_enable_youtube_strict
  green "Argo 配置完成"
}

uninstall_argo(){
  svc stop tunnel-argo; svc disable tunnel-argo
  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service "${WORK}/argo_start.sh" "${WORK}/argo"
  rm -f "$ARGO_DOMAIN" "$ARGO_YML" "$ARGO_JSON"
  if [ -f "$XRAY_CONF" ]; then
    update_xray 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))'
    svc restart xray
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  green "Argo 已卸载"
}

# ========== HY2 ==========
write_hy2_state(){
  local port="$1" domain="$2" pass="$3" up="$4" down="$5" obfs="$6" cert_mode="$7"
  mkdir -p "$WORK"
  cat > "$HY2_STATE" <<EOF
PORT=$port
DOMAIN=$domain
PASS=$pass
UP=$up
DOWN=$down
OBFS=$obfs
CERT_MODE=$cert_mode
EOF
}

install_hy2(){
  install_xray || return 1
  ensure_dns_rule || return 1

  local mode cert_mode domain token port auth obfs prof up down hop cert_file key_file cert_mode_saved
  prompt "HY2模式(1=一键最简 2=自定义，默认1): " mode
  [ -z "${mode:-}" ] && mode=1
  [[ "$mode" =~ ^[12]$ ]] || mode=1

  prompt "证书模式(1=本机自签 2=CF令牌签发，默认1): " cert_mode
  [ -z "${cert_mode:-}" ] && cert_mode=1
  [[ "$cert_mode" =~ ^[12]$ ]] || cert_mode=1

  if [ "$cert_mode" = "1" ]; then
    prompt "HY2伪装域名(回车默认 ${HY2_SELF_SNI_DEFAULT}): " domain
    [ -z "$domain" ] && domain="$HY2_SELF_SNI_DEFAULT"
    issue_cert_selfsigned "$domain" "$TLS_DIR_HY2" || return 1
    cert_mode_saved="self"
  else
    prompt "HY2域名: " domain; [ -z "$domain" ] && { red "域名不能为空"; return 1; }
    prompt "Cloudflare API Token: " token; [ -z "$token" ] && { red "Token不能为空"; return 1; }
    issue_cert_cf "$domain" "$token" "$TLS_DIR_HY2" || return 1
    cert_mode_saved="cf"
  fi

  cert_file="${TLS_DIR_HY2}/${domain}.crt"
  key_file="${TLS_DIR_HY2}/${domain}.key"

  prompt "HY2端口(默认38167): " port; [ -z "$port" ] && port=38167
  [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }

  prompt "HY2认证AUTH(回车随机UUID): " auth; [ -z "$auth" ] && auth="$(gen_uuid)"

  # 默认值（Mbps）
  obfs=""
  up=50
  down=250
  hop=""

  if [ "$mode" = "2" ]; then
    prompt "HY2混淆密码OBFS(回车随机UUID): " obfs
    [ -z "$obfs" ] && obfs="$(gen_uuid)"

    echo "带宽档位: 1.默认(50/250 Mbps) 2.自定义"
    prompt "选择(默认1): " prof
    case "$prof" in
      2)
        prompt "上行Mbps(默认50): " up
        prompt "下行Mbps(默认250): " down
        [ -z "$up" ] && up=50
        [ -z "$down" ] && down=250
        [[ "$up" =~ ^[0-9]+$ ]] || up=50
        [[ "$down" =~ ^[0-9]+$ ]] || down=250
        ;;
      *) up=50; down=250 ;;
    esac

    prompt "端口跳跃(回车关闭；范围38167-38186=20个；或列表38167,38170): " hop
    hop="$(echo "${hop:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -n "$hop" ]; then
      if [[ "$hop" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        [ "${BASH_REMATCH[1]}" -gt "${BASH_REMATCH[2]}" ] && { red "跳跃范围无效"; return 1; }
      else
        local ok=1 IFS=',' one
        for one in $hop; do
          one="$(echo "$one" | sed 's/[[:space:]]//g')"
          [[ "$one" =~ ^[0-9]+$ ]] || { ok=0; break; }
        done
        [ "$ok" -eq 1 ] || { red "端口列表无效"; return 1; }
      fi
    fi
  else
    yellow "一键最简模式：无混淆、无端口跳跃、默认50/250 Mbps（客户端可改）"
  fi

  open_port "$port" udp
  if [ -n "$hop" ]; then
    if command -v ufw >/dev/null 2>&1; then
      if [[ "$hop" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        ufw allow "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}/udp" >/dev/null 2>&1 || true
      else
        IFS=',' read -r -a _arr <<< "$hop"
        for _p in "${_arr[@]}"; do
          _p="$(echo "$_p" | sed 's/[[:space:]]//g')"
          [[ "$_p" =~ ^[0-9]+$ ]] && ufw allow "${_p}/udp" >/dev/null 2>&1 || true
        done
      fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      if [[ "$hop" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        firewall-cmd --add-port="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}/udp" --permanent >/dev/null 2>&1 || true
      else
        IFS=',' read -r -a _arr <<< "$hop"
        for _p in "${_arr[@]}"; do
          _p="$(echo "$_p" | sed 's/[[:space:]]//g')"
          [[ "$_p" =~ ^[0-9]+$ ]] && firewall-cmd --add-port="${_p}/udp" --permanent >/dev/null 2>&1 || true
        done
      fi
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi

  # 删除旧HY2（含hop）
  update_xray 'del(.inbounds[]? | select(.tag=="hy2-in" or ((.tag // "")|startswith("hy2-in-hop-")) or .protocol=="hysteria" or .protocol=="hysteria2"))'
  clear_hy2_hop_rules || true

  local hy2
  if [ -n "$obfs" ]; then
    hy2="$(jq -nc \
      --argjson p "$port" \
      --arg auth "$auth" \
      --arg obfs "$obfs" \
      --arg domain "$domain" \
      --arg crt "$cert_file" \
      --arg key "$key_file" \
'{
  "tag":"hy2-in",
  "listen":"::",
  "port":$p,
  "protocol":"hysteria",
  "settings":{"version":2,"clients":[{"auth":$auth,"email":"hy2@local"}]},
  "streamSettings":{
    "network":"hysteria",
    "security":"tls",
    "tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":$crt,"keyFile":$key}],"serverName":$domain},
    "hysteriaSettings":{"version":2},
    "finalmask":{
      "udp":[{"type":"salamander","settings":{"password":$obfs}}],
      "quicParams":{"congestion":"bbr","bbrProfile":"standard","maxIdleTimeout":30,"keepAlivePeriod":10,"disablePathMTUDiscovery":false}
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}
}')"
  else
    hy2="$(jq -nc \
      --argjson p "$port" \
      --arg auth "$auth" \
      --arg domain "$domain" \
      --arg crt "$cert_file" \
      --arg key "$key_file" \
'{
  "tag":"hy2-in",
  "listen":"::",
  "port":$p,
  "protocol":"hysteria",
  "settings":{"version":2,"clients":[{"auth":$auth,"email":"hy2@local"}]},
  "streamSettings":{
    "network":"hysteria",
    "security":"tls",
    "tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":$crt,"keyFile":$key}],"serverName":$domain},
    "hysteriaSettings":{"version":2},
    "finalmask":{
      "quicParams":{"congestion":"bbr","bbrProfile":"standard","maxIdleTimeout":30,"keepAlivePeriod":10,"disablePathMTUDiscovery":false}
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}
}')"
  fi

  update_xray --argjson ib "$hy2" '.inbounds += [$ib]'

  # 仅自定义模式且填写了hop时才应用跳跃
  if [ -n "$hop" ]; then
    apply_hy2_hop "$port" "$auth" "$obfs" "$domain" "$cert_file" "$key_file" "$hop"
    echo "$hop" > "${WORK}/hy2_hop_range.txt"
  else
    rm -f "${WORK}/hy2_hop_range.txt"
  fi

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_hy2_check.log 2>&1; then
    red "Xray 配置校验失败"
    tail -n 80 /tmp/xray_hy2_check.log 2>/dev/null || true
    return 1
  fi

  svc restart xray
  write_hy2_state "$port" "$domain" "$auth" "$up" "$down" "$obfs" "$cert_mode_saved"

  ask_enable_youtube_strict

  green "HY2 安装成功（Xray）"
  if [ "$cert_mode_saved" = "self" ]; then
    green "证书模式：本机自签（客户端默认 insecure=1）"
  else
    green "证书模式：CF令牌签发（客户端默认 insecure=0）"
  fi
  if [ "$mode" = "1" ]; then
    green "当前为一键最简：无混淆 / 无跳跃 / 默认50/250 Mbps"
  else
    green "当前为自定义：UP=${up}Mbps DOWN=${down}Mbps"
  fi
}

uninstall_hy2(){
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return 1; }
  update_xray 'del(.inbounds[]? | select(.tag=="hy2-in" or (.tag|startswith("hy2-in-hop-")) or .protocol=="hysteria" or .protocol=="hysteria2"))'
  clear_hy2_hop_rules || true
  rm -f "$HY2_STATE" "${WORK}/hy2_hop_range.txt"
  svc restart xray
  green "HY2 已卸载"
}

# ========== Nodes ==========
show_xray_nodes(){
  cls
  [ "$IP_CHECKED" = "1" ] || load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || check_ip || true
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return; }

  local ip="" uuid cnt=0
  ip="$(pick_node_host)"
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
      purple "ss://${b64}@${SS_FIXED_IP}:8080?type=ws&security=none&host=${d}&path=%2Fssgo#$(url_encode "$ns")"; echo
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

  if [ -f "$HY2_STATE" ]; then
    # shellcheck disable=SC1090
    . "$HY2_STATE" 2>/dev/null || true
    if [ -n "${PORT:-}" ] && [ -n "${DOMAIN:-}" ] && [ -n "${PASS:-}" ]; then
      local hn hop_param="" insecure="0" hy_host upmbps downmbps
      hn="${BASE_FULL} - HY2"

      if [ -f "${WORK}/hy2_hop_range.txt" ]; then
        local hr
        hr="$(cat "${WORK}/hy2_hop_range.txt" 2>/dev/null || true)"
        [ -n "$hr" ] && hop_param="&mport=${hr}&ports=${hr}"
      fi

      if [ "${CERT_MODE:-cf}" = "self" ]; then
        insecure="1"
      fi

      hy_host="$ip"
      [ -z "$hy_host" ] && hy_host="$DOMAIN"  # 兜底

      upmbps="${UP:-50}"
      downmbps="${DOWN:-250}"
      [[ "$upmbps" =~ ^[0-9]+$ ]] || upmbps=50
      [[ "$downmbps" =~ ^[0-9]+$ ]] || downmbps=250

      if [ -n "${OBFS:-}" ]; then
        purple "hysteria2://${PASS}@${hy_host}:${PORT}?sni=${DOMAIN}&insecure=${insecure}&obfs=salamander&obfs-password=${OBFS}&upmbps=${upmbps}&downmbps=${downmbps}${hop_param}#$(url_encode "$hn")"; echo
      else
        purple "hysteria2://${PASS}@${hy_host}:${PORT}?sni=${DOMAIN}&insecure=${insecure}&upmbps=${upmbps}&downmbps=${downmbps}${hop_param}#$(url_encode "$hn")"; echo
      fi
      cnt=$((cnt+1))
    fi
  fi

  [ "$cnt" -eq 0 ] && yellow "暂无配置节点"
  echo "=========================================="
}

# ========== Socks5 ==========
manage_socks5(){
  if [ ! -f "$XRAY_CONF" ]; then
    cls
    red "未检测到 Xray"
    menu_item_auto "1" "安装Xray"
    menu_item_auto "0" "返回"
    prompt "请选择: " k
    case "$k" in
      1) install_xray || { red "安装失败"; pause; return; } ;;
      0) return ;;
      *) return ;;
    esac
  fi

  ensure_dns_rule || { red "初始化失败"; pause; return; }

  while true; do
    cls
    local list
    list="$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$XRAY_CONF" 2>/dev/null || true)"
    echo -e "${C_WARN}=============== Socks5管理 ===============${C_RST}"
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
    menu_item_auto "1" "安装Socks5"
    menu_item_auto "2" "修改Socks5"
    menu_item_auto "3" "卸载Socks5"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "端口: " p; prompt "用户名: " u; prompt "密码: " pw
        if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
          local ex; ex="$(jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$XRAY_CONF")"
          if [ "$ex" -gt 0 ]; then red "端口已存在"
          else
            update_xray --argjson p "$p" --arg u "$u" --arg pw "$pw" \
              '.inbounds += [{"tag":("socks-"+($p|tostring)),"port":$p,"listen":"0.0.0.0","protocol":"socks","settings":{"auth":"password","accounts":[{"user":$u,"pass":$pw}],"udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false}}]'
            svc restart xray
            ask_enable_youtube_strict
            green "添加成功"
          fi
        else red "输入无效"; fi
        pause ;;
      2)
        prompt "端口: " p; prompt "新用户名: " u; prompt "新密码: " pw
        if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
          update_xray --argjson p "$p" --arg u "$u" --arg pw "$pw" \
            '(.inbounds[]? | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user":$u,"pass":$pw}'
          svc restart xray; green "修改成功"
        else red "输入无效"; fi
        pause ;;
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
        pause ;;
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
  if [ ! -f "$XRAY_CONF" ]; then
    cls
    red "未检测到 Xray"
    menu_item_auto "1" "安装Xray"
    menu_item_auto "0" "返回"
    prompt "请选择: " k
    case "$k" in
      1) install_xray || { red "安装失败"; pause; return; } ;;
      0) return ;;
      *) return ;;
    esac
  fi

  while true; do
    cls
    local s="${C_BAD}未配置${C_RST}"
    if [ "$FREEFLOW_MODE" != "none" ]; then
      local m="${FREEFLOW_MODE^^}"; [ "$m" = "HTTPUPGRADE" ] && m="HTTP+"
      s="${C_WARN}${m}${C_RST} path=${FF_PATH}"
    fi
    echo -e "${C_WARN}=============== 免流管理 ===============${C_RST}"
    printf "当前: %b\n" "$s"
    echo "-----------------------------------------------"
    menu_item_auto "1" "修改免流方式"
    menu_item_auto "2" "修改免流路径"
    menu_item_auto "3" "卸载免流"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        echo
        green "请选择免流方式"
        echo "-----------------------------------------------"
        echo " 1. WS"
        echo " 2. HTTPUpgrade"
        echo " 3. 关闭"
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
        apply_freeflow
        if [ "$FREEFLOW_MODE" != "none" ]; then
          ask_enable_youtube_strict
        fi
        green "已更新"; pause ;;
      2)
        [ "$FREEFLOW_MODE" = "none" ] && { red "请先启用"; pause; continue; }
        prompt "新path(回车保持): " p
        [ -n "$p" ] && FF_PATH="$(normalize_path "$p")"
        printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$FREEFLOW_CONF"
        apply_freeflow; green "路径已更新"; pause ;;
      3)
        FREEFLOW_MODE="none"; FF_PATH="/"
        printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$FREEFLOW_CONF"
        apply_freeflow; green "已卸载"; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== sing-box / Tuic ==========
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
      pkg_install cron; svc enable cron; svc start cron
    elif command -v apk >/dev/null 2>&1; then
      pkg_install dcron; rc-service dcron start >/dev/null 2>&1 || true; rc-update add dcron default >/dev/null 2>&1 || true
    else
      pkg_install cronie; svc enable crond; svc start crond
    fi
  fi

  yellow "安装 acme.sh..."
  curl -s https://get.acme.sh | sh >/tmp/acme_install.log 2>&1 || true
  [ -x "$HOME/.acme.sh/acme.sh" ] || { red "acme.sh 安装失败"; tail -n 80 /tmp/acme_install.log 2>/dev/null || true; return 1; }
}

issue_cert_cf(){
  local d="$1" token="$2" cert_dir="${3:-$TLS_DIR_TUIC}"
  local crt="${cert_dir}/${d}.crt" key="${cert_dir}/${d}.key"
  mkdir -p "$cert_dir"
if [ -s "$crt" ] && [ -s "$key" ]; then
  # 证书在未来30天内仍有效则复用，否则重新签发
  if openssl x509 -in "$crt" -noout -checkend $((30*24*3600)) >/dev/null 2>&1; then
    green "证书已存在且有效(>30天): $d"
    return 0
  else
    yellow "证书即将过期或已过期，开始续签: $d"
  fi
fi

  ensure_acme || return 1
  export CF_Token="$token"
  yellow "申请证书: $d"
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --issue -d "$d" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1 || { red "签发失败"; tail -n 80 /tmp/acme_issue.log 2>/dev/null || true; return 1; }
  "$HOME/.acme.sh/acme.sh" --installcert -d "$d" --fullchainpath "$crt" --keypath "$key" --ecc >/tmp/acme_installcert.log 2>&1 || true
  [ -s "$crt" ] && [ -s "$key" ] || { red "安装证书失败"; tail -n 80 /tmp/acme_installcert.log 2>/dev/null || true; return 1; }
  green "证书安装成功"
}

issue_cert_selfsigned(){
  local d="$1" cert_dir="${2:-$TLS_DIR_HY2}"
  local crt="${cert_dir}/${d}.crt" key="${cert_dir}/${d}.key"
  mkdir -p "$cert_dir"

  if [ -s "$crt" ] && [ -s "$key" ]; then
    if openssl x509 -in "$crt" -noout -checkend $((30*24*3600)) >/dev/null 2>&1; then
      green "自签证书已存在且有效(>30天): $d"
      return 0
    else
      yellow "自签证书即将过期或已过期，重新生成: $d"
    fi
  fi

  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -subj "/CN=${d}" \
    -keyout "$key" -out "$crt" >/tmp/selfsign_issue.log 2>&1 || {
    red "自签证书生成失败"
    tail -n 80 /tmp/selfsign_issue.log 2>/dev/null || true
    return 1
  }

  [ -s "$crt" ] && [ -s "$key" ] || { red "自签证书文件异常"; return 1; }
  green "自签证书生成成功: $d"
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
  local crt="${TLS_DIR_TUIC}/${domain}.crt" key="${TLS_DIR_TUIC}/${domain}.key"
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
description="Tuic by sing-box"
command="${SB_BIN}"
command_args="run -c ${SB_CONF}"
command_background=true
pidfile="/run/tuic-box.pid"
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
  is_running tuic-box && return 0
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

  issue_cert_cf "$domain" "$token" "$TLS_DIR_TUIC" || return 1

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
  svc stop tuic-box; svc disable tuic-box
  rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$SB"
  green "Sbox 已卸载"
}

# ========== Live logs ==========
foreground_sbox_log(){
  [ -x "$SB_BIN" ] || { red "sing-box 未安装"; pause; return 1; }
  [ -f "$SB_CONF" ] || { red "缺少配置: $SB_CONF"; pause; return 1; }

  local bak="${SB_CONF}.bak.fg.$(date +%s)"
  cp -a "$SB_CONF" "$bak"

  if ! jq '.log.disabled=false | .log.level="debug" | .log.timestamp=true' "$SB_CONF" > "${SB_CONF}.tmp"; then
    red "写入日志配置失败"; rm -f "${SB_CONF}.tmp" "$bak"; pause; return 1
  fi
  mv "${SB_CONF}.tmp" "$SB_CONF"

  if ! "$SB_BIN" check -c "$SB_CONF" >/tmp/sb_check_fg.log 2>&1; then
    red "配置校验失败，无法前台运行"
    cp -f "$bak" "$SB_CONF"; rm -f "$bak"
    tail -n 80 /tmp/sb_check_fg.log 2>/dev/null || true
    pause; return 1
  fi

  yellow "即将停止 tuic-box 后台服务并前台输出日志..."
  svc stop tuic-box || true
  pkill -f "^${SB_BIN} run -c ${SB_CONF}$" >/dev/null 2>&1 || true
  pkill -x sing-box >/dev/null 2>&1 || true
  sleep 1

  green "前台日志已启动（Ctrl+C 退出）"
  echo "日志文件: /tmp/sb-live.log"

  local old_int_trap
  old_int_trap="$(trap -p INT || true)"
  trap ':' INT

  set +e
  "$SB_BIN" run -c "$SB_CONF" 2>&1 | tee /tmp/sb-live.log
  set -e

  if [ -n "$old_int_trap" ]; then eval "$old_int_trap"; else trap - INT; fi

  cp -f "$bak" "$SB_CONF"; rm -f "$bak"
  yellow "已退出前台日志，正在恢复后台服务..."
  svc start tuic-box || true
  sleep 1
  is_running tuic-box && green "tuic-box 已恢复后台运行" || red "tuic-box 恢复失败，请手动检查"
  pause
}

foreground_xray_log(){
  [ -x "$XRAY_BIN" ] || { red "xray 未安装"; pause; return 1; }
  [ -f "$XRAY_CONF" ] || { red "缺少配置: $XRAY_CONF"; pause; return 1; }

  local bak="${XRAY_CONF}.bak.fg.$(date +%s)"
  cp -a "$XRAY_CONF" "$bak"

  if ! jq '.log=(.log//{})|.log.access=""|.log.error=""|.log.loglevel="debug"|.log.dnsLog=true' "$XRAY_CONF" > "${XRAY_CONF}.tmp"; then
    red "写入 Xray 日志配置失败"; rm -f "${XRAY_CONF}.tmp" "$bak"; pause; return 1
  fi
  mv "${XRAY_CONF}.tmp" "$XRAY_CONF"

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_check_fg.log 2>&1; then
    red "Xray 配置校验失败，无法前台运行"
    cp -f "$bak" "$XRAY_CONF"; rm -f "$bak"
    tail -n 80 /tmp/xray_check_fg.log 2>/dev/null || true
    pause; return 1
  fi

  yellow "即将停止 xray 后台服务并前台输出日志..."
  svc stop xray || true
  pkill -f "^${XRAY_BIN} run -c ${XRAY_CONF}$" >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true
  sleep 1

  green "前台日志已启动（Ctrl+C 退出）"
  echo "日志文件: /tmp/xray-live.log"

  local old_int_trap
  old_int_trap="$(trap -p INT || true)"
  trap ':' INT

  set +e
  "$XRAY_BIN" run -c "$XRAY_CONF" 2>&1 | tee /tmp/xray-live.log
  set -e

  if [ -n "$old_int_trap" ]; then eval "$old_int_trap"; else trap - INT; fi

  cp -f "$bak" "$XRAY_CONF"; rm -f "$bak"
  yellow "已退出前台日志，正在恢复后台服务..."
  svc start xray || true
  sleep 1
  is_running xray && green "xray 已恢复后台运行" || red "xray 恢复失败，请手动检查"
  pause
}

# ========== Restart cron ==========
setup_cron_env(){
  command -v crontab >/dev/null 2>&1 && return
  if command -v apt-get >/dev/null 2>&1; then
    pkg_install cron; svc enable cron; svc start cron
  elif command -v apk >/dev/null 2>&1; then
    pkg_install dcron; rc-service dcron start >/dev/null 2>&1 || true; rc-update add dcron default >/dev/null 2>&1 || true
  else
    pkg_install cronie; svc enable crond; svc start crond
  fi
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

# ========== SWAP ==========
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
    echo -e "${C_WARN}=============== SWAP管理 ===============${C_RST}"
    echo "RAM: ${ram}MB  SWAP: ${sw}MB"
    echo "-----------------------------------------------"
    menu_item_auto "1" "安装SWAP"
    menu_item_auto "2" "卸载SWAP"
    menu_item_auto "0" "返回"
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
  local mark="${WORK}/.shortcut_done"
  local local_script="${WORK}/manager.sh"
  local dst="/usr/local/bin/ssgo"
  local url1="${SCRIPT_URL:-https://raw.githubusercontent.com/KisThFir/Xray-ssgo/refs/heads/main/Xray_ssgo.sh}"
  local url2="https://raw.githubusercontent.com/KisThFir/Xray-ssgo/main/Xray_ssgo.sh"

  yellow "正在拉取脚本到本地: ${local_script}"

  if ! smart_download "$local_script" "$url1" 5000; then
    yellow "主地址失败，尝试备用地址..."
    smart_download "$local_script" "$url2" 5000 || { red "拉取失败: $url1"; return 1; }
  fi

  chmod 755 "$WORK" 2>/dev/null || true
  chmod 700 "$local_script" 2>/dev/null || chmod +x "$local_script" || true
  chown root:root "$local_script" 2>/dev/null || true

  mkdir -p /usr/local/bin /usr/bin
  cat > "$dst" <<'EOF'
#!/usr/bin/env bash
exec bash /etc/xray/manager.sh "$@"
EOF
  chmod 755 "$dst"
  chown root:root "$dst" 2>/dev/null || true

  ln -sf "$dst" /usr/bin/ssgo
  chmod 755 /usr/bin/ssgo 2>/dev/null || true
  chown -h root:root /usr/bin/ssgo 2>/dev/null || true

  touch "$mark"
  chmod 600 "$mark" 2>/dev/null || true
  green "快捷方式已创建：ssgo -> /etc/xray/manager.sh"
}

full_uninstall(){
  # 1) 停服务 + 取消自启
  svc stop tunnel-argo; svc disable tunnel-argo
  svc stop xray; svc disable xray
  svc stop tuic-box; svc disable tuic-box

  # 2) 兜底杀进程（避免服务脚本失效时残留）
  pkill -f '/etc/xray/argo tunnel' >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true
  pkill -x sing-box >/dev/null 2>&1 || true

  # 3) 清 HY2 跳跃规则（iptables/native）
  clear_hy2_hop_rules >/dev/null 2>&1 || true

  # 4) 删服务文件
  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
  rm -f /etc/init.d/xray /etc/systemd/system/xray.service
  rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service

  # 5) systemd 刷新
  command -v systemctl >/dev/null 2>&1 && {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
  }

  # 6) 清本脚本加的定时任务
  command -v crontab >/dev/null 2>&1 && \
    (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab - 2>/dev/null || true

  # 7) 清 swap（脚本创建的 /swapfile + zram）
  swap_disable_all >/dev/null 2>&1 || true

  # 8) 清快捷方式
  rm -f /usr/local/bin/ssgo /usr/bin/ssgo

  # 9) 清配置/二进制目录
  rm -rf "$WORK" "$SB"
  rm -rf /etc/ssgo

  green "已彻底卸载（服务/配置/快捷方式/定时任务/SWAP 已清理）"
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
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "输入模式(1关闭/2严格): " m
        [[ "$m" =~ ^[12]$ ]] || { red "输入无效"; pause; continue; }
        YOUTUBE_MODE="$m"; save_outbound; apply_policy_all; green "已更新并应用"; pause ;;
      2)
        local s md
        prompt "输入域名(逗号分隔，支持批量): " s
        [ -z "$s" ] && { red "不能为空"; pause; continue; }
        echo "选择模式：1=兼容 2=严格"
        prompt "输入模式: " md
        case "$md" in
          1) [ -z "$V6_COMPAT_SITES" ] && V6_COMPAT_SITES="$s" || V6_COMPAT_SITES="${V6_COMPAT_SITES},${s}" ;;
          2) [ -z "$V6_STRICT_SITES" ] && V6_STRICT_SITES="$s" || V6_STRICT_SITES="${V6_STRICT_SITES},${s}" ;;
          *) red "模式无效"; pause; continue ;;
        esac
        V6_COMPAT_SITES="$(echo "$V6_COMPAT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
        V6_STRICT_SITES="$(echo "$V6_STRICT_SITES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
        save_outbound; apply_policy_all; green "已添加并应用"; pause ;;
      3)
        local all_json list
        all_json="$(csv_to_json_unique "$(merge_csv "$V6_COMPAT_SITES" "$V6_STRICT_SITES")")"
        if [ "$(echo "$all_json" | jq 'length')" -eq 0 ]; then red "规则为空"; pause; continue; fi
        echo "当前IPv6规则："
        echo "$all_json" | jq -r '.[]' | nl -w2 -s'. '
        echo "输入序号（支持 1,3,5 ）或 a 全删，0取消"
        prompt "输入: " list

        if [[ "$list" =~ ^[aA]$ ]]; then
          V6_COMPAT_SITES=""; V6_STRICT_SITES=""
          save_outbound; apply_policy_all; green "已全删并应用"; pause; continue
        fi
        [ "$list" = "0" ] && continue

        local IFS=',' one target delset=""
        for one in $list; do
          one="$(echo "$one" | sed 's/ //g')"
          [[ "$one" =~ ^[0-9]+$ ]] || continue
          target="$(echo "$all_json" | jq -r ".[$((one-1))] // empty")"
          [ -n "$target" ] && delset="${delset}${target}"$'\n'
        done
        [ -z "$delset" ] && { red "无有效序号"; pause; continue; }

        local cjson sjson
        cjson="$(csv_to_json_unique "$V6_COMPAT_SITES")"
        sjson="$(csv_to_json_unique "$V6_STRICT_SITES")"
        while read -r target; do
          [ -z "$target" ] && continue
          cjson="$(echo "$cjson" | jq -r --arg t "$target" '[.[]|select(.!=$t)]')"
          sjson="$(echo "$sjson" | jq -r --arg t "$target" '[.[]|select(.!=$t)]')"
        done <<< "$delset"

        V6_COMPAT_SITES="$(echo "$cjson" | jq -r 'join(",")')"
        V6_STRICT_SITES="$(echo "$sjson" | jq -r 'join(",")')"

        save_outbound; apply_policy_all
        green "已删除并应用"
        pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Xray menu ==========
xray_menu(){
  while true; do
    cls
    local xs as hs
    if [ -x "$XRAY_BIN" ]; then xs=$(is_running xray && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}"); else xs="${C_BAD}未安装${C_RST}"; fi
    if service_exists tunnel-argo; then as=$(is_running tunnel-argo && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}"); else as="${C_BAD}未配置${C_RST}"; fi
    if [ -f "$HY2_STATE" ]; then hs="\033[1;36m已配置\033[0m"; else hs="${C_BAD}未配置${C_RST}"; fi

    echo -e "${C_OK}=============== Xray管理 ===============${C_RST}"
    echo -e "Xray: ${xs}   Argo: ${as}   HY2: ${hs}"
    echo "-----------------------------------------------"

    menu_row2_auto "1"  "安装Argo"      "8"  "实时日志"
    menu_row2_auto "2"  "安装HY2"       "9"  "查看节点"
    menu_row2_auto "3"  "配置Socks5"    "10" "修改UUID"
    menu_row2_auto "4"  "配置免流"      "0"  "返回"
    menu_row2_auto "5"  "重启Argo"
    menu_row2_auto "6"  "重启Xray"
    menu_row2_auto "7"  "卸载Argo"
    menu_row2_auto "11" "卸载HY2"
    menu_row2_auto "12" "卸载Xray"

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
      12) full_uninstall; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Sbox menu ==========
sbox_menu(){
  while true; do
    cls
    local st
    if [ -x "$SB_BIN" ]; then st=$(is_running tuic-box && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}"); else st="${C_BAD}未安装${C_RST}"; fi
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

# ========== System info ==========
detect_virt_name(){
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
    [ -n "$v" ] && [ "$v" != "none" ] && { echo "${v^^}"; return; }
  fi

  if [ -f /run/systemd/container ]; then
    v="$(cat /run/systemd/container 2>/dev/null || true)"
    [ -n "$v" ] && { echo "${v^^}"; return; }
  fi

  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=lxc$'; then
    echo "LXC"; return
  fi
  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=docker$'; then
    echo "DOCKER"; return
  fi

  if grep -qaE '(lxc|docker|containerd|kubepods|podman)' /proc/1/cgroup 2>/dev/null; then
    if grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then echo "LXC"; return; fi
    if grep -qa 'docker' /proc/1/cgroup 2>/dev/null; then echo "DOCKER"; return; fi
    if grep -qa 'containerd' /proc/1/cgroup 2>/dev/null; then echo "CONTAINERD"; return; fi
    if grep -qa 'podman' /proc/1/cgroup 2>/dev/null; then echo "PODMAN"; return; fi
    echo "CONTAINER"; return
  fi

  [ -f /proc/1/ns/mnt ] && [ -d /dev/lxd ] && { echo "LXC"; return; }

  echo "UNKNOWN"
}

arch_disp(){
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    i?86) echo "x86" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7|armhf) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) uname -m ;;
  esac
}

os_version_disp(){
  local osv
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
  echo "$osv"
}

kernel_disp(){
  cut -d- -f1 < /proc/sys/kernel/osrelease 2>/dev/null || uname -r
}

cpu_model_disp(){
  local model
  model="$(awk -F: '
    /model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}
    /Hardware/   {gsub(/^[ \t]+/, "", $2); print $2; exit}
    /Processor/  {gsub(/^[ \t]+/, "", $2); print $2; exit}
  ' /proc/cpuinfo 2>/dev/null)"
  [ -z "$model" ] && model="$(uname -m)"
  echo "$model"
}

cpu_cores_disp(){
  nproc 2>/dev/null || awk '/^processor/{n++} END{print (n?n:1)}' /proc/cpuinfo 2>/dev/null
}

cpu_usage_percent(){
  local user nice system idle iowait irq softirq steal guest guest_nice
  local total idle_all diff_total diff_idle usage
  local s1_total s1_idle s2_total s2_idle

  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total=$((user+nice+system+idle+iowait+irq+softirq+steal))
  idle_all=$((idle+iowait))

  # 首次调用：做一次短间隔双采样，避免固定0%
  if [ "${CPU_LAST_TOTAL:-0}" -eq 0 ] || [ "${CPU_LAST_IDLE:-0}" -eq 0 ]; then
    s1_total="$total"
    s1_idle="$idle_all"

    sleep 0.2

    read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    s2_total=$((user+nice+system+idle+iowait+irq+softirq+steal))
    s2_idle=$((idle+iowait))

    diff_total=$((s2_total-s1_total))
    diff_idle=$((s2_idle-s1_idle))

    CPU_LAST_TOTAL="$s2_total"
    CPU_LAST_IDLE="$s2_idle"

    if [ "$diff_total" -le 0 ]; then
      echo "0"
      return
    fi

    usage=$(( (100*(diff_total-diff_idle))/diff_total ))
    [ "$usage" -lt 0 ] && usage=0
    [ "$usage" -gt 100 ] && usage=100
    echo "$usage"
    return
  fi

  diff_total=$((total-CPU_LAST_TOTAL))
  diff_idle=$((idle_all-CPU_LAST_IDLE))

  CPU_LAST_TOTAL="$total"
  CPU_LAST_IDLE="$idle_all"

  if [ "$diff_total" -le 0 ]; then
    echo "0"
    return
  fi

  usage=$(( (100*(diff_total-diff_idle))/diff_total ))
  [ "$usage" -lt 0 ] && usage=0
  [ "$usage" -gt 100 ] && usage=100
  echo "$usage"
}

mem_swap_used_disp(){
  awk '
    /MemTotal/      {mt=$2}
    /MemAvailable/  {ma=$2}
    /SwapTotal/     {st=$2}
    /SwapFree/      {sf=$2}
    END{
      mu=mt-ma;
      if (mt>1024*1024) mtxt=sprintf("%.1fG/%.1fG", mu/1024/1024, mt/1024/1024);
      else              mtxt=sprintf("%.0fM/%.0fM", mu/1024, mt/1024);

      if (st>0) {
        su=st-sf;
        if (st>1024*1024) stxt=sprintf("%.1fG/%.1fG", su/1024/1024, st/1024/1024);
        else              stxt=sprintf("%.0fM/%.0fM", su/1024, st/1024);
      } else {
        stxt="";
      }
      printf "%s|%s", mtxt, stxt;
    }
  ' /proc/meminfo 2>/dev/null
}

# ========== Main ==========
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

    local osver arch ker virt cpu_model cpu_cores cpu_use ms u4 u6
local mem swap

osver="$(os_version_disp)"
arch="$(arch_disp)"
ker="$(kernel_disp)"
virt="$(detect_virt_name)"
cpu_model="$(cpu_model_disp)"
cpu_cores="$(cpu_cores_disp)"
cpu_use="$(cpu_usage_percent)"
ms="$(mem_swap_used_disp)"
mem="${ms%%|*}"
swap="${ms#*|}"

# IPv4/IPv6 显示内容
if [ -n "${WAN4:-}" ]; then
  u4="${EMOJI4} ${COUNTRY4} ${WAN4}"
  [ -n "${ISP4:-}" ] && [ "${ISP4}" != "unknown" ] && u4="${u4} | ${ISP4}"
  u4="\033[1;36m${u4}\033[0m"
else
  u4="${C_BAD}未检测到${C_RST}"
fi

if [ -n "${WAN6:-}" ]; then
  u6="${EMOJI6} ${COUNTRY6} ${WAN6}"
  [ -n "${ISP6:-}" ] && [ "${ISP6}" != "unknown" ] && u6="${u6} | ${ISP6}"
  u6="\033[1;36m${u6}\033[0m"
else
  u6="${C_BAD}未检测到${C_RST}"
fi
    echo -e "${C_DIM}================ 系统信息 ================${C_RST}"
echo -e "OS   : \033[1;36m${osver} | ${arch} | ${ker} | ${virt}\033[0m"
echo -e "CPU  : \033[1;36m${cpu_model} | ${cpu_cores}C | ${cpu_use}%\033[0m"
echo -e "Mem  : \033[1;36m${mem}\033[0m"
[ -n "$swap" ] && echo -e "Swap : \033[1;36m${swap}\033[0m"
echo "-----------------------------------------------"
echo -e "IPv4 : ${u4}"
echo -e "IPv6 : ${u6}"
echo "-----------------------------------------------"

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
