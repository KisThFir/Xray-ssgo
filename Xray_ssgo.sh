#!/usr/bin/env bash
set -o pipefail

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }

# ========= 语义颜色 =========
C_RST="\033[0m"
C_INSTALL="\033[1;36m"   # 安装
C_MODIFY="\033[1;36m"    # 修改
C_VIEW="\033[1;36m"      # 查看
C_MANAGE="\033[1;36m"    # 管理
C_RESTART="\033[1;33m"   # 重启

C_XRAY="\033[1;32m"      # xray
C_ARGO="\033[1;35m"      # argo
C_NODE="\033[1;35m"      # 节点
C_TUIC="\033[1;35m"      # tuic
C_SBOX="\033[1;35m"      # sbox
C_POLICY="\033[1;35m"    # 策略
C_SHORTCUT="\033[1;35m"  # 快捷

C_OUTBOUND="\033[1;33m"  # 出站
C_FREEFLOW="\033[1;33m"  # 免流
C_SOCKS5="\033[1;33m"    # socks5
C_UUID="\033[1;33m"      # uuid
C_SWAP="\033[1;33m"      # swap

C_BAD="\033[1;91m"       # 未安装/未配置/未启动/返回/退出

clear_buffer() { while read -r -t 0.1 -n 10000 _d </dev/tty 2>/dev/null; do :; done; }
prompt() { clear_buffer; printf '\033[1;91m%s\033[0m' "$1" >&2; read -r "$2" </dev/tty; }
pause() { printf '\n\033[1;91m按回车继续...\033[0m\n' >&2; clear_buffer; read -r _d </dev/tty; }
cls() { clear; printf '\033[3J\033[2J\033[H'; }
url_encode() { jq -rn --arg x "$1" '$x|@uri'; }

work_dir="/etc/xray"
xray_bin="${work_dir}/xray"
xray_conf="${work_dir}/config.json"

SB_BASE="/etc/sing-box"
sb_bin="${SB_BASE}/sing-box"
sb_conf="${SB_BASE}/config.json"
sb_state="${SB_BASE}/tuic_state.conf"

freeflow_conf="${work_dir}/freeflow.conf"
restart_conf="${work_dir}/restart.conf"
outbound_policy_conf="${work_dir}/outbound_policy.conf"
ip_cache_file="${work_dir}/ip_cache.conf"

swap_log_file="/tmp/swap.log"

argo_domain_file="${work_dir}/domain_argo.txt"
argo_yml="${work_dir}/tunnel_argo.yml"
argo_json="${work_dir}/tunnel_argo.json"

tls_dir="/etc/tuic/tls"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}
SS_FIXED_IP="104.18.40.49"

FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_HOURS=0
XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

YOUTUBE_V6=0
V6_SITE_LIST=""

IP_CHECKED=0
IP_CHECK_BG_STARTED=0
IP_CACHE_MTIME=0
WAN4="" WAN6=""
COUNTRY4="" AS_NUM4="" ISP_CLEAN4="" EMOJI4=""
COUNTRY6="" AS_NUM6="" ISP_CLEAN6="" EMOJI6=""

BASE_REGION_NAME="Node"
BASE_FULL_NAME="Node"

[ "$EUID" -ne 0 ] && red "请用 root 运行" && exit 1
[ -t 0 ] || { red "请在交互终端运行"; exit 1; }

manage_service() {
    local action="$1" svc="$2"
    if [ -f /etc/alpine-release ]; then
        case "$action" in
            start|stop|restart) rc-service "$svc" "$action" >/dev/null 2>&1 ;;
            enable) rc-update add "$svc" default >/dev/null 2>&1 ;;
            disable) rc-update del "$svc" default >/dev/null 2>&1 ;;
        esac
    else
        case "$action" in
            enable) systemctl enable "$svc" >/dev/null 2>&1; systemctl daemon-reload >/dev/null 2>&1 ;;
            disable) systemctl disable "$svc" >/dev/null 2>&1; systemctl daemon-reload >/dev/null 2>&1 ;;
            *) systemctl "$action" "$svc" >/dev/null 2>&1 ;;
        esac
    fi
}
is_service_running() {
    if [ -f /etc/alpine-release ]; then
        rc-service "$1" status 2>/dev/null | grep -q started
    else
        [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]
    fi
}
service_exists() {
    local s="$1"
    if [ -f /etc/alpine-release ]; then
        [ -f "/etc/init.d/${s}" ]
    else
        [ -f "/etc/systemd/system/${s}.service" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"
    fi
}

manage_packages() {
    local need_update=1 p c
    for p in "$@"; do
        case "$p" in
            iproute2) c="ip" ;;
            coreutils) c="base64" ;;
            *) c="$p" ;;
        esac
        command -v "$c" >/dev/null 2>&1 && continue

        if [ "$need_update" -eq 1 ]; then
            if command -v apt-get >/dev/null 2>&1; then apt-get update -y >/dev/null 2>&1
            elif command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1
            fi
            need_update=0
        fi

        yellow "安装依赖: $p"
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$p" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$p" >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add "$p" >/dev/null 2>&1
        fi
    done
}

update_config() {
    if ! jq "$@" "${xray_conf}" > "${xray_conf}.tmp"; then
        red "配置更新失败(jq错误)"
        rm -f "${xray_conf}.tmp"
        return 1
    fi
    mv "${xray_conf}.tmp" "${xray_conf}"
}

to_ghfast_url() {
    local src="$1"
    case "$src" in
        https://github.com/*|https://raw.githubusercontent.com/*) echo "https://ghfast.top/${src}" ;;
        *) echo "$src" ;;
    esac
}
smart_download() {
    local out="$1" url="$2" min="$3"
    local t=0 ok=0 cur="$url" m_used=0

    while [ "$t" -lt 3 ]; do
        rm -f "$out"
        wget -q --show-progress --timeout=30 --tries=1 -O "$out" "$cur"
        if [ -f "$out" ]; then
            local sz
            sz=$(wc -c < "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null)
            if [ -n "$sz" ] && [ "$sz" -ge "$min" ]; then ok=1; break; fi
        fi

        if [ "$m_used" -eq 0 ]; then
            local m
            m=$(to_ghfast_url "$url")
            if [ "$m" != "$url" ]; then
                yellow "切换镜像重试..."
                cur="$m"
                m_used=1
            fi
        fi
        t=$((t+1))
        sleep 2
    done

    [ "$ok" -eq 1 ] || { red "下载失败: $url"; return 1; }
    return 0
}

detect_xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        i386|i486|i586|i686) echo "32" ;;
        armv7l|armv7|armhf) echo "arm32-v7a" ;;
        armv6l|armv6) echo "arm32-v6" ;;
        s390x) echo "s390x" ;;
        riscv64) echo "riscv64" ;;
        *) echo "" ;;
    esac
}
detect_cloudflared_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i486|i586|i686) echo "386" ;;
        armv7l|armv7|armhf) echo "arm" ;;
        *) echo "" ;;
    esac
}
detect_singbox_suffix() {
    case "$(uname -m)" in
        x86_64|amd64) echo "-linux-amd64" ;;
        aarch64|arm64) echo "-linux-arm64" ;;
        *) echo "" ;;
    esac
}

generate_uuid() { cat /proc/sys/kernel/random/uuid; }
normalize_path() { [ -z "$1" ] && echo "/" || { case "$1" in /*) echo "$1" ;; *) echo "/$1" ;; esac; }; }

load_state() {
    if [ -f "$freeflow_conf" ]; then
        local a b
        { read -r a; read -r b; } < "$freeflow_conf"
        case "$a" in ws|httpupgrade) FREEFLOW_MODE="$a" ;; *) FREEFLOW_MODE="none" ;; esac
        [ -n "$b" ] && FF_PATH="$b"
    fi
    if [ -f "$restart_conf" ]; then
        RESTART_HOURS=$(cat "$restart_conf" 2>/dev/null)
        [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
    fi
}
load_state

load_outbound_policy() {
    YOUTUBE_V6=0
    V6_SITE_LIST=""
    [ -f "$outbound_policy_conf" ] || return
    YOUTUBE_V6=$(awk -F= '/^YOUTUBE_V6=/{print $2}' "$outbound_policy_conf" 2>/dev/null)
    V6_SITE_LIST=$(awk -F= '/^V6_SITES=/{sub(/^V6_SITES=/,""); print}' "$outbound_policy_conf" 2>/dev/null)
    [[ "$YOUTUBE_V6" =~ ^[01]$ ]] || YOUTUBE_V6=0
}
save_outbound_policy() {
    mkdir -p "$work_dir"
    {
        echo "YOUTUBE_V6=${YOUTUBE_V6}"
        echo "V6_SITES=${V6_SITE_LIST}"
    } > "$outbound_policy_conf"
}
load_outbound_policy

detect_virtualization() {
    local virt="UNKNOWN" v="" pn=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt 2>/dev/null)
        case "$v" in
            kvm) virt="KVM" ;;
            qemu) virt="QEMU" ;;
            vmware) virt="VMWARE" ;;
            xen) virt="XEN" ;;
            microsoft|hyperv) virt="HYPER-V" ;;
            openvz) virt="OPENVZ" ;;
            lxc|lxc-libvirt) virt="LXC" ;;
            docker) virt="DOCKER" ;;
            podman) virt="PODMAN" ;;
            wsl) virt="WSL" ;;
            none|"") virt="UNKNOWN" ;;
            *) virt=$(echo "$v" | tr '[:lower:]' '[:upper:]') ;;
        esac
    fi
    if [ "$virt" = "UNKNOWN" ] && [ -r /sys/class/dmi/id/product_name ]; then
        read -r pn < /sys/class/dmi/id/product_name
        case "$pn" in
            *KVM*|*kvm*) virt="KVM" ;;
            *QEMU*|*qemu*) virt="QEMU" ;;
            *VMware*|*vmware*) virt="VMWARE" ;;
            *Xen*|*xen*) virt="XEN" ;;
            *VirtualBox*|*virtualbox*) virt="VIRTUALBOX" ;;
            *Hyper-V*|*hyperv*|*Microsoft*) virt="HYPER-V" ;;
        esac
    fi
    echo "$virt"
}

get_sys_info() {
    [ -n "$SYS_INFO_CACHE" ] && return
    local os_ver kernel virt mem disk os_name
    if [ -f /etc/alpine-release ]; then
        read -r os_ver < /etc/alpine-release
        os_ver="Alpine ${os_ver}"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$ID" ] && [ -n "$VERSION_ID" ]; then
            os_name=$(echo "$ID" | sed -e 's/^[a-z]/\U&/')
            os_ver="${os_name} ${VERSION_ID}"
        elif [ -n "$PRETTY_NAME" ]; then
            os_ver="$PRETTY_NAME"
        else
            os_ver="Linux"
        fi
        os_ver=$(echo "$os_ver" | sed -E 's/ \([a-zA-Z0-9._-]+\)//g')
    else
        os_ver="Linux"
    fi
    read -r kernel < /proc/sys/kernel/osrelease
    kernel=${kernel%%[-+]*}
    virt=$(detect_virtualization)
    mem=$(awk '/MemTotal/{m=$2/1024; if(m>1024) printf"%.1fG",m/1024; else printf"%.0fM",m}' /proc/meminfo 2>/dev/null)
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')
    SYS_INFO_CACHE="${os_ver} | ${kernel} | ${virt} | ${mem} | ${disk}"
}

country_code_to_zh() {
    case "$1" in
        US) echo "美国" ;;
        HK) echo "香港" ;;
        JP) echo "日本" ;;
        SG) echo "新加坡" ;;
        KR) echo "韩国" ;;
        TW) echo "台湾" ;;
        DE) echo "德国" ;;
        FR) echo "法国" ;;
        GB) echo "英国" ;;
        CA) echo "加拿大" ;;
        AU) echo "澳大利亚" ;;
        NL) echo "荷兰" ;;
        RU) echo "俄罗斯" ;;
        IN) echo "印度" ;;
        BR) echo "巴西" ;;
        *) echo "$1" ;;
    esac
}
country_code_to_flag() {
    local cc="${1^^}"
    [ ${#cc} -ne 2 ] && { echo ""; return; }
    local o1 o2
    o1=$(printf '%d' "'${cc:0:1}")
    o2=$(printf '%d' "'${cc:1:1}")
    printf "\\U1F1$(printf '%X' $((o1-65+0xE6)))\\U1F1$(printf '%X' $((o2-65+0xE6)))"
}
extract_isp_from_org() {
    local org="$1"
    org="${org#AS[0-9]* }"
    org=$(echo "$org" | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    echo "$org"
}
extract_asn_from_org() {
    local org="$1"
    local asn
    asn=$(echo "$org" | grep -oE 'AS[0-9]+' | head -n1)
    echo "$asn"
}

apply_base_name_from_ip() {
    local e c isp
    if [ -n "$EMOJI4" ] || [ -n "$COUNTRY4" ]; then
        e="$EMOJI4"; c="$COUNTRY4"; isp="$ISP_CLEAN4"
    elif [ -n "$EMOJI6" ] || [ -n "$COUNTRY6" ]; then
        e="$EMOJI6"; c="$COUNTRY6"; isp="$ISP_CLEAN6"
    else
        BASE_REGION_NAME="Node"
        BASE_FULL_NAME="Node"
        return
    fi

    if [ -n "$e" ] && [ -n "$c" ]; then
        BASE_REGION_NAME="${e} [${c}]"
    elif [ -n "$c" ]; then
        BASE_REGION_NAME="[${c}]"
    elif [ -n "$e" ]; then
        BASE_REGION_NAME="${e}"
    else
        BASE_REGION_NAME="Node"
    fi

    if [ -n "$isp" ]; then
        BASE_FULL_NAME="${BASE_REGION_NAME} ${isp}"
    else
        BASE_FULL_NAME="${BASE_REGION_NAME}"
    fi
}

save_ip_cache() {
    mkdir -p "$work_dir"
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    cat > "$ip_cache_file" <<EOF
UPDATED_AT=$(printf '%q' "$now")
WAN4=$(printf '%q' "$WAN4")
WAN6=$(printf '%q' "$WAN6")
COUNTRY4=$(printf '%q' "$COUNTRY4")
AS_NUM4=$(printf '%q' "$AS_NUM4")
ISP_CLEAN4=$(printf '%q' "$ISP_CLEAN4")
EMOJI4=$(printf '%q' "$EMOJI4")
COUNTRY6=$(printf '%q' "$COUNTRY6")
AS_NUM6=$(printf '%q' "$AS_NUM6")
ISP_CLEAN6=$(printf '%q' "$ISP_CLEAN6")
EMOJI6=$(printf '%q' "$EMOJI6")
BASE_REGION_NAME=$(printf '%q' "$BASE_REGION_NAME")
BASE_FULL_NAME=$(printf '%q' "$BASE_FULL_NAME")
EOF
}
load_ip_cache() {
    [ -f "$ip_cache_file" ] || return 1
    # shellcheck disable=SC1090
    . "$ip_cache_file" 2>/dev/null || return 1
    if [ -z "$BASE_REGION_NAME" ] || [ -z "$BASE_FULL_NAME" ]; then
        apply_base_name_from_ip
    fi
    if [ -n "$WAN4" ] || [ -n "$WAN6" ] || [ -n "$BASE_REGION_NAME" ]; then
        IP_CHECKED=1
        return 0
    fi
    return 1
}
refresh_ip_cache_if_changed() {
    [ -f "$ip_cache_file" ] || return 1
    local mt
    mt=$(stat -c %Y "$ip_cache_file" 2>/dev/null || echo 0)
    [ "$mt" -gt "$IP_CACHE_MTIME" ] || return 1
    IP_CACHE_MTIME="$mt"
    load_ip_cache >/dev/null 2>&1 || true
    return 0
}

# IPinfo API 检测
fetch_ipinfo_by_family() {
    local family="$1" bind_arg="$2" out="$3"
    local url="https://ipinfo.io/json"
    if [ "$family" = "4" ]; then
        wget $bind_arg -4 -qO- --no-check-certificate --tries=2 --timeout=4 "$url" > "$out" 2>/dev/null
    else
        wget $bind_arg -6 -qO- --no-check-certificate --tries=2 --timeout=4 "$url" > "$out" 2>/dev/null
    fi
}

check_system_ip() {
    [ "$IP_CHECKED" = "1" ] && return
    local IF4 IF6 BA4="" BA6=""
    IF4=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    IF6=$(ip -6 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')

    if [ -n "${IF4}${IF6}" ]; then
        local L4 L6
        L4=$(ip -4 addr show "$IF4" 2>/dev/null | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp' | head -n1)
        L6=$(ip -6 addr show "$IF6" 2>/dev/null | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp' | head -n1)
        [ -n "$L4" ] && BA4="--bind-address=$L4"
        [ -n "$L6" ] && BA6="--bind-address=$L6"
    fi

    local t4 t6
    t4=$(mktemp)
    t6=$(mktemp)

    fetch_ipinfo_by_family 4 "$BA4" "$t4" &
    local p4=$!
    fetch_ipinfo_by_family 6 "$BA6" "$t6" &
    local p6=$!

    wait "$p4" 2>/dev/null || true
    wait "$p6" 2>/dev/null || true

    local J4 J6
    J4=$(cat "$t4" 2>/dev/null)
    J6=$(cat "$t6" 2>/dev/null)
    rm -f "$t4" "$t6"

    if [ -n "$J4" ] && echo "$J4" | jq -e '.ip' >/dev/null 2>&1; then
        WAN4=$(echo "$J4" | jq -r '.ip // empty')
        local CC4 ORG4
        CC4=$(echo "$J4" | jq -r '.country // empty')
        ORG4=$(echo "$J4" | jq -r '.org // empty')
        COUNTRY4=$(country_code_to_zh "$CC4")
        EMOJI4=$(country_code_to_flag "$CC4")
        AS_NUM4=$(extract_asn_from_org "$ORG4")
        ISP_CLEAN4=$(extract_isp_from_org "$ORG4")
    fi

    if [ -n "$J6" ] && echo "$J6" | jq -e '.ip' >/dev/null 2>&1; then
        WAN6=$(echo "$J6" | jq -r '.ip // empty')
        local CC6 ORG6
        CC6=$(echo "$J6" | jq -r '.country // empty')
        ORG6=$(echo "$J6" | jq -r '.org // empty')
        COUNTRY6=$(country_code_to_zh "$CC6")
        EMOJI6=$(country_code_to_flag "$CC6")
        AS_NUM6=$(extract_asn_from_org "$ORG6")
        ISP_CLEAN6=$(extract_isp_from_org "$ORG6")
    fi

    apply_base_name_from_ip
    IP_CHECKED=1
    save_ip_cache
}
start_ip_check_bg() {
    [ "$IP_CHECK_BG_STARTED" = "1" ] && return
    IP_CHECK_BG_STARTED=1
    (check_system_ip >/dev/null 2>&1) &
}

get_used_mem_display() {
    awk '
      /MemTotal/ {t=$2}
      /MemAvailable/ {a=$2}
      END{
        u=t-a
        if(t>1024*1024) printf "%.1fG/%.1fG", u/1024/1024, t/1024/1024
        else printf "%.0fM/%.0fM", u/1024, t/1024
      }' /proc/meminfo 2>/dev/null
}

init_xray_config_if_missing() {
    mkdir -p "$work_dir"
    if [ ! -f "$xray_conf" ]; then
        cat > "$xray_conf" <<'EOF'
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
    fi
}

ensure_dns_routing() {
    init_xray_config_if_missing
    local has_dnsout
    has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "$xray_conf" 2>/dev/null)
    [ "$has_dnsout" = "true" ] || update_config '.outbounds += [{"protocol":"dns","tag":"dns-out"}]'
    jq -e '.routing' "$xray_conf" >/dev/null 2>&1 || update_config '.routing={"rules":[]}'
    local has53 hasdns
    has53=$(jq '[.routing.rules[]? | select(.port=="53")] | length' "$xray_conf" 2>/dev/null)
    hasdns=$(jq '[.routing.rules[]? | select(.protocol=="dns")] | length' "$xray_conf" 2>/dev/null)
    if [ "${has53:-0}" -eq 0 ] || [ "${hasdns:-0}" -eq 0 ]; then
        update_config 'del(.routing.rules[]? | select(.port=="53" or .protocol=="dns"))'
        update_config '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]'
    fi
}

build_v6_domain_array_json() {
    local domains=""
    if [ "$YOUTUBE_V6" = "1" ]; then
        domains="youtube.com,youtu.be,googlevideo.com,ytimg.com"
    fi
    if [ -n "$V6_SITE_LIST" ]; then
        if [ -n "$domains" ]; then domains="${domains},${V6_SITE_LIST}"; else domains="${V6_SITE_LIST}"; fi
    fi
    jq -nc --arg s "$domains" '($s|split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))|unique)'
}

apply_outbound_policy_xray() {
    [ -f "$xray_conf" ] || return 0
    ensure_dns_routing || return 1
    update_config '
      .outbounds |=
      (
        map(select(.tag!="direct" and .tag!="direct-v4" and .tag!="direct-v6"))
        + [{"protocol":"freedom","tag":"direct-v4","settings":{"domainStrategy":"UseIPv4"}}]
        + [{"protocol":"freedom","tag":"direct-v6","settings":{"domainStrategy":"UseIPv6"}}]
      )' || return 1
    update_config 'del(.routing.rules[]? | select(.tag=="v6-route-rule"))' || return 1

    local arr_json
    arr_json=$(build_v6_domain_array_json)
    if [ "$(echo "$arr_json" | jq 'length')" -gt 0 ]; then
        update_config --argjson d "$arr_json" '.routing.rules += [{"type":"field","domain":($d|map("domain:"+.)),"outboundTag":"direct-v6","tag":"v6-route-rule"}]' || return 1
    fi
}
apply_outbound_policy_singbox() {
    [ -f "$sb_conf" ] || return 0
    local arr_json
    arr_json=$(build_v6_domain_array_json)

    if ! jq '.outbounds' "$sb_conf" >/dev/null 2>&1; then red "Sbox配置异常"; return 1; fi

    jq '
      .outbounds |=
      (
        map(select(.tag!="direct_ipv4" and .tag!="direct_ipv6"))
        + [{"type":"direct","tag":"direct_ipv4","domain_resolver":{"server":"dns4","strategy":"ipv4_only"}}]
        + [{"type":"direct","tag":"direct_ipv6","domain_resolver":{"server":"dns4","strategy":"ipv6_only"}}]
      )' "$sb_conf" > "${sb_conf}.tmp" || { rm -f "${sb_conf}.tmp"; return 1; }
    mv "${sb_conf}.tmp" "$sb_conf"

    if [ "$(echo "$arr_json" | jq 'length')" -gt 0 ]; then
        jq --argjson d "$arr_json" '
          .route = (.route // {})
          | .route.rules = ((.route.rules // []) | map(select(.tag!="v6-route-rule")))
          | .route.rules += [{"domain":$d,"outbound":"direct_ipv6","tag":"v6-route-rule"}]
          | .route.final = "direct_ipv4"
        ' "$sb_conf" > "${sb_conf}.tmp" || { rm -f "${sb_conf}.tmp"; return 1; }
    else
        jq '
          .route = (.route // {})
          | .route.rules = ((.route.rules // []) | map(select(.tag!="v6-route-rule")))
          | .route.final = "direct_ipv4"
        ' "$sb_conf" > "${sb_conf}.tmp" || { rm -f "${sb_conf}.tmp"; return 1; }
    fi
    mv "${sb_conf}.tmp" "$sb_conf"
}
apply_outbound_policy_all() {
    apply_outbound_policy_xray || return 1
    apply_outbound_policy_singbox || true
    service_exists xray && manage_service restart xray
    service_exists tuic-box && manage_service restart tuic-box
    green "出站策略已应用（Xray + Sbox）"
}

install_xray_core() {
    manage_packages jq wget unzip tar coreutils iproute2
    mkdir -p "$work_dir"
    init_xray_config_if_missing
    ensure_dns_routing

    if [ ! -x "$xray_bin" ]; then
        local arch url
        arch=$(detect_xray_arch)
        [ -z "$arch" ] && { red "当前架构不支持Xray"; return 1; }
        url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        smart_download "${work_dir}/xray.zip" "$url" 5000000 || return 1
        unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" >/dev/null 2>&1 || return 1
        chmod +x "$xray_bin"
        rm -f "${work_dir}/xray.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi

    if ! service_exists xray; then
        if [ -f /etc/alpine-release ]; then
            cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="${xray_bin}"
command_args="run -c ${xray_conf}"
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
ExecStart=${xray_bin} run -c ${xray_conf}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        fi
        manage_service enable xray
    fi

    apply_outbound_policy_xray || true
    manage_service restart xray
    green "Xray 安装完成"
}

get_current_uuid_xray_or_fallback() {
    if [ -f "$xray_conf" ]; then
        local id
        id=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "$xray_conf" 2>/dev/null)
        [ -n "$id" ] && [ "$id" != "null" ] && { echo "$id"; return; }
    fi
    echo "$UUID_FALLBACK"
}
set_xray_uuid_no_validate() {
    local u="$1"
    [ -f "$xray_conf" ] || { red "xray未安装"; return 1; }
    update_config --arg uuid "$u" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'
    manage_service restart xray
    green "UUID已更新: $u"
}

load_freeflow_state() {
    FREEFLOW_MODE="none"; FF_PATH="/"
    if [ -f "$freeflow_conf" ]; then
        local a b
        { read -r a; read -r b; } < "$freeflow_conf"
        case "$a" in ws|httpupgrade) FREEFLOW_MODE="$a" ;; *) FREEFLOW_MODE="none" ;; esac
        [ -n "$b" ] && FF_PATH="$b"
    fi
}

ask_freeflow_mode() {
    echo ""
    green "请选择免流方式"
    echo "-----------------------------------------------"
    echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_FREEFLOW}免流${C_RST} + WS"
    echo -e "${C_INSTALL} 2.${C_RST} ${C_INSTALL}安装${C_RST}${C_FREEFLOW}免流${C_RST} + HTTPUpgrade"
    echo -e "${C_BAD} 3.${C_RST} ${C_BAD}卸载${C_RST}${C_FREEFLOW}免流${C_RST}"
    echo "-----------------------------------------------"
    prompt "请选择: " c
    case "$c" in
        1) FREEFLOW_MODE="ws" ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none" ;;
    esac
    if [ "$FREEFLOW_MODE" != "none" ]; then
        prompt "path(回车默认/): " p
        FF_PATH=$(normalize_path "$p")
    else
        FF_PATH="/"
    fi
    printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
}
apply_freeflow_config() {
    [ -f "$xray_conf" ] || { red "xray未安装"; return 1; }
    ensure_dns_routing || return 1
    local uuid
    uuid=$(get_current_uuid_xray_or_fallback)
    update_config 'del(.inbounds[]? | select(.tag=="ff-in"))' || return 1
    if [ "$FREEFLOW_MODE" != "none" ]; then
        local ff
        ff='{"tag":"ff-in","port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"'"${FREEFLOW_MODE}"'","security":"none","'"${FREEFLOW_MODE}"'Settings":{"path":"'"${FF_PATH}"'"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}'
        update_config --argjson ib "$ff" '.inbounds += [$ib]' || return 1
    fi
    manage_service restart xray
}

manage_freeflow() {
    [ -f "$xray_conf" ] || { red "请先安装xray"; pause; return; }
    load_freeflow_state
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
            1) ask_freeflow_mode; apply_freeflow_config; green "已更新"; pause ;;
            2)
                [ "$FREEFLOW_MODE" = "none" ] && { red "请先启用"; pause; continue; }
                prompt "新path(回车保持): " p
                [ -n "$p" ] && FF_PATH=$(normalize_path "$p")
                printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
                apply_freeflow_config
                green "路径已更新"
                pause
                ;;
            3)
                FREEFLOW_MODE="none"; FF_PATH="/"
                printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
                apply_freeflow_config
                green "已卸载"
                pause
                ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

manage_socks5() {
    [ -f "$xray_conf" ] || { red "请先安装xray"; pause; return; }
    ensure_dns_routing || { red "初始化失败"; pause; return; }

    while true; do
        cls
        local list
        list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$xray_conf" 2>/dev/null)

        echo -e "${C_SOCKS5}=============== Socks5管理 ===============${C_RST}"
        if [ -z "$list" ]; then
            echo -e "当前: ${C_BAD}未配置${C_RST}"
        else
            echo "-----------------------------------------------"
            echo "  端口    | 用户名    | 密码"
            echo "-----------------------------------------------"
            while read -r line; do
                local p u pw
                p=$(echo "$line" | jq -r '.port')
                u=$(echo "$line" | jq -r '.settings.accounts[0].user')
                pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                printf "  %-8s| %-10s| %s\n" "$p" "$u" "$pw"
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
                prompt "端口: " p
                prompt "用户名: " u
                prompt "密码: " pw
                if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
                    local ex
                    ex=$(jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$xray_conf")
                    if [ "$ex" -gt 0 ]; then red "端口已存在"
                    else
                        update_config --argjson p "$p" --arg u "$u" --arg pw "$pw" \
                          '.inbounds += [{"tag":("socks-"+($p|tostring)),"port":$p,"listen":"0.0.0.0","protocol":"socks","settings":{"auth":"password","accounts":[{"user":$u,"pass":$pw}],"udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false}}]'
                        manage_service restart xray
                        green "添加成功"
                    fi
                else
                    red "输入无效"
                fi
                pause
                ;;
            2)
                prompt "端口: " p
                prompt "新用户名: " u
                prompt "新密码: " pw
                if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
                    update_config --argjson p "$p" --arg u "$u" --arg pw "$pw" \
                      '(.inbounds[]? | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user":$u,"pass":$pw}'
                    manage_service restart xray
                    green "修改成功"
                else
                    red "输入无效"
                fi
                pause
                ;;
            3)
                if [ -z "$list" ]; then red "无可删项"; pause; continue; fi
                local i=1 ports=()
                while read -r line; do
                    local p
                    p=$(echo "$line" | jq -r '.port')
                    echo "  ${i}. 端口 ${p}"
                    ports[$i]="$p"
                    i=$((i+1))
                done <<< "$list"
                echo "  0. 取消"
                prompt "序号: " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -gt 0 ] && [ "$idx" -lt "$i" ]; then
                    update_config --argjson p "${ports[$idx]}" 'del(.inbounds[]? | select(.protocol=="socks" and .port==$p))'
                    manage_service restart xray
                    green "已删除"
                fi
                pause
                ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

ask_apply_youtube_v6_once() {
    local ans
    prompt "是否启用 YouTube 走IPv6? (y/N): " ans
    case "$ans" in
        y|Y) YOUTUBE_V6=1 ;;
        *)   YOUTUBE_V6=0 ;;
    esac
    save_outbound_policy
    apply_outbound_policy_all || true
}

install_or_reinstall_argo() {
    install_xray_core || return 1
    ensure_dns_routing || return 1

    if [ ! -x "${work_dir}/argo" ]; then
        local arch url
        arch=$(detect_cloudflared_arch)
        [ -z "$arch" ] && { red "架构不支持cloudflared"; return 1; }
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
        smart_download "${work_dir}/argo" "$url" 15000000 || return 1
        chmod +x "${work_dir}/argo"
    fi

    prompt "Argo域名: " domain
    [ -z "$domain" ] && { red "不能为空"; return 1; }
    prompt "Argo JSON凭证: " auth
    echo "$auth" | grep -q "TunnelSecret" || { red "必须是JSON凭证"; return 1; }

    prompt "SS密码(回车随机UUID): " ss_pass
    [ -z "$ss_pass" ] && ss_pass=$(generate_uuid)
    prompt "SS加密(1/2): " mc
    local ss_method="aes-128-gcm"
    [ "$mc" = "2" ] && ss_method="aes-256-gcm"

    echo "$domain" > "$argo_domain_file"
    local tunnel_id
    tunnel_id=$(echo "$auth" | jq -r '.TunnelID' 2>/dev/null || echo "$auth" | cut -d'"' -f12)
    echo "$auth" > "$argo_json"

    cat > "$argo_yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${argo_json}
protocol: http2
ingress:
  - hostname: ${domain}
    path: /argo
    service: http://localhost:8080
    originRequest:
      noTLSVerify: true
  - hostname: ${domain}
    path: /xgo
    service: http://localhost:8081
    originRequest:
      noTLSVerify: true
  - hostname: ${domain}
    path: /ssgo
    service: http://localhost:8082
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

    local uuid
    uuid=$(get_current_uuid_xray_or_fallback)
    update_config 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))' || return 1

    local ws_json xhttp_json ss_json
    ws_json='{"port":8080,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
    xhttp_json=$(jq -nc --arg uuid "$uuid" --arg mode "$XHTTP_MODE" --argjson extra "$XHTTP_EXTRA_JSON" \
      '{"port":8081,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')
    ss_json='{"port":8082,"listen":"127.0.0.1","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
    update_config --argjson ws "$ws_json" --argjson xhttp "$xhttp_json" --argjson ss "$ss_json" '.inbounds += [$ws,$xhttp,$ss]' || return 1

    local exec_cmd svc="tunnel-argo"
    exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --config ${argo_yml} run"

    if ! service_exists "$svc"; then
        if [ -f /etc/alpine-release ]; then
            cat > "${work_dir}/argo_start.sh" <<EOF
#!/bin/sh
exec ${exec_cmd}
EOF
            chmod +x "${work_dir}/argo_start.sh"
            cat > /etc/init.d/${svc} <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="${work_dir}/argo_start.sh"
command_background=true
pidfile="/var/run/${svc}.pid"
EOF
            chmod +x /etc/init.d/${svc}
        else
            cat > /etc/systemd/system/${svc}.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=${exec_cmd}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        fi
        manage_service enable "$svc"
    fi

    manage_service restart xray
    manage_service restart "$svc"

    ask_apply_youtube_v6_once
    apply_outbound_policy_all || true

    green "Argo 配置完成"
    show_xray_nodes
}

uninstall_argo_only() {
    manage_service stop tunnel-argo 2>/dev/null
    manage_service disable tunnel-argo 2>/dev/null
    rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
    rm -f "$argo_domain_file" "$argo_yml" "$argo_json" "${work_dir}/argo_start.sh" "${work_dir}/argo"
    if [ -f "$xray_conf" ]; then
        update_config 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))'
        manage_service restart xray
    fi
    green "Argo 已卸载"
}

restart_argo_if_installed() {
    if service_exists tunnel-argo; then manage_service restart tunnel-argo; green "Argo 已重启"; else red "Argo未安装"; fi
}
restart_xray_if_installed() {
    if service_exists xray; then manage_service restart xray; green "Xray 已重启"; else red "Xray未安装"; fi
}

show_xray_nodes() {
    cls
    [ "$IP_CHECKED" = "1" ] || { load_ip_cache >/dev/null 2>&1 || true; }
    [ "$IP_CHECKED" = "1" ] || check_system_ip
    [ -f "$xray_conf" ] || { red "xray未安装"; echo "==============================================="; return; }

    local ip=""
    [ -n "$WAN4" ] && ip="$WAN4" || [ -n "$WAN6" ] && ip="$WAN6"
    local uuid count=0
    uuid=$(get_current_uuid_xray_or_fallback)

    local base_full base_region
    base_full="$BASE_FULL_NAME"; base_region="$BASE_REGION_NAME"
    [ -z "$base_full" ] && base_full="Node"
    [ -z "$base_region" ] && base_region="Node"

    green "=============== 节点链接 ================"

    if [ -f "$argo_domain_file" ]; then
        local d xextra
        d=$(cat "$argo_domain_file")
        xextra=$(url_encode "$XHTTP_EXTRA_JSON")

        local name_xhttp="${base_full} - Argo - Xhttp"
        local name_ws="${base_full} - Argo - Ws"
        local name_ss="${base_full} - Argo - Ss"

        purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&alpn=h2&fp=chrome&type=xhttp&host=${d}&path=%2Fxgo&mode=${XHTTP_MODE}&extra=${xextra}#$(url_encode "$name_xhttp")"; echo ""; count=$((count+1))
        purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2Fargo%3Fed%3D2560#$(url_encode "$name_ws")"; echo ""; count=$((count+1))

        local ss_ib
        ss_ib=$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8082)' "$xray_conf" 2>/dev/null)
        if [ -n "$ss_ib" ]; then
            local m pw b64
            m=$(echo "$ss_ib" | jq -r '.settings.method')
            pw=$(echo "$ss_ib" | jq -r '.settings.password')
            b64=$(echo -n "${m}:${pw}" | base64 | tr -d '\n')
            purple "ss://${b64}@${SS_FIXED_IP}:80?type=ws&security=none&host=${d}&path=%2Fssgo#$(url_encode "$name_ss")"; echo ""; count=$((count+1))
        fi
    fi

    load_freeflow_state
    if [ "$FREEFLOW_MODE" != "none" ] && [ -n "$ip" ]; then
        local p m ff_name
        p=$(url_encode "$FF_PATH")
        m="${FREEFLOW_MODE^^}"; [ "$m" = "HTTPUPGRADE" ] && m="HTTP+"
        ff_name="${base_full} - ${m}"
        purple "vless://${uuid}@${ip}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${ip}&path=${p}#$(url_encode "$ff_name")"
        echo ""
        count=$((count+1))
    fi

    local sl
    sl=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$xray_conf" 2>/dev/null)
    if [ -n "$sl" ] && [ -n "$ip" ]; then
        while read -r line; do
            local p u pw sname
            p=$(echo "$line" | jq -r '.port')
            u=$(echo "$line" | jq -r '.settings.accounts[0].user')
            pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
            sname="${base_full} - Socks5-${p}"
            purple "socks5://${u}:${pw}@${ip}:${p}#$(url_encode "$sname")"
            echo ""
            count=$((count+1))
        done <<< "$sl"
    fi

    [ "$count" -eq 0 ] && yellow "暂无配置节点"
    echo "=========================================="
}

show_tuic_node() {
    cls
    load_tuic_state
    [ -f "$sb_state" ] || { red "Tuic未安装"; echo "=========================================="; return; }

    local port cc domain uuid
    IFS='|' read -r port cc domain uuid < "$sb_state"
    [ -z "$port" ] || [ -z "$domain" ] || [ -z "$uuid" ] && { red "Tuic状态文件不完整"; return; }

    local base_full base_region name link
    base_full="$BASE_FULL_NAME"; base_region="$BASE_REGION_NAME"
    [ -z "$base_full" ] && base_full="Node"
    [ -z "$base_region" ] && base_region="Node"

    if [[ "$base_full" == "$base_region" ]]; then
        name="${base_region} Tuic"
    else
        name="${base_full} - Tuic"
    fi

    link="tuic://${uuid}:${uuid}@${domain}:${port}?congestion_control=${cc:-bbr}&alpn=h3&sni=${domain}&udp_relay_mode=quic&allow_insecure=0#$(url_encode "$name")"

    green "=============== Tuic 节点 ==============="
    purple "$link"
    echo "=========================================="
}

ensure_acme() {
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then return 0; fi

    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            manage_packages cron
            manage_service enable cron 2>/dev/null || true
            manage_service start cron 2>/dev/null || true
        elif command -v apk >/dev/null 2>&1; then
            manage_packages dcron
            rc-service dcron start 2>/dev/null || true
            rc-update add dcron default >/dev/null 2>&1 || true
        else
            manage_packages cronie
            manage_service enable crond 2>/dev/null || true
            manage_service start crond 2>/dev/null || true
        fi
    fi

    yellow "安装 acme.sh..."
    curl -s https://get.acme.sh | sh >/tmp/acme_install.log 2>&1
    if [ ! -x "$HOME/.acme.sh/acme.sh" ] && [ -f "$HOME/.acme.sh/acme.sh" ]; then
        "$HOME/.acme.sh/acme.sh" --install --force >/tmp/acme_force_install.log 2>&1 || true
    fi

    [ -x "$HOME/.acme.sh/acme.sh" ] || {
        red "acme.sh 安装失败"
        tail -n 60 /tmp/acme_install.log 2>/dev/null
        tail -n 60 /tmp/acme_force_install.log 2>/dev/null
        return 1
    }
}

issue_cert_cf_token() {
    local domain="$1" token="$2"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"
    mkdir -p "$tls_dir"

    if [ -s "$crt" ] && [ -s "$key" ]; then green "证书已存在: $domain"; return 0; fi

    ensure_acme || return 1
    export CF_Token="$token"

    yellow "申请证书: $domain"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1 || {
        red "签发失败"; tail -n 80 /tmp/acme_issue.log; return 1;
    }

    "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
      --fullchainpath "$crt" --keypath "$key" --ecc >/tmp/acme_installcert.log 2>&1

    [ -s "$crt" ] && [ -s "$key" ] || { red "安装证书失败"; tail -n 80 /tmp/acme_installcert.log; return 1; }
    green "证书安装成功"
}

ensure_port_open() {
    local p="$1" proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1; then ufw allow "${p}/${proto}" >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --add-port="${p}/${proto}" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

install_singbox_core_only() {
    manage_packages jq wget tar curl
    mkdir -p "$work_dir" "$SB_BASE"

    if [ ! -x "$sb_bin" ]; then
        local suffix ver url tgz
        suffix=$(detect_singbox_suffix)
        [ -z "$suffix" ] && { red "当前架构不支持sing-box"; return 1; }

        ver=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
        [ -z "$ver" ] && { red "无法获取sing-box版本"; return 1; }

        tgz="${SB_BASE}/sing-box.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}${suffix}.tar.gz"
        smart_download "$tgz" "$url" 5000000 || return 1
        tar -xzf "$tgz" -C "$SB_BASE" >/dev/null 2>&1 || return 1
        mv "${SB_BASE}/sing-box-${ver#v}${suffix}/sing-box" "$sb_bin" 2>/dev/null || return 1
        chmod +x "$sb_bin"
        rm -rf "$tgz" "${SB_BASE}/sing-box-${ver#v}${suffix}"
    fi
    green "sing-box 已安装"
}

write_tuic_config() {
    local domain="$1" port="$2" cc="$3" uuid="$4"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"
    mkdir -p "$SB_BASE"
    cat > "$sb_conf" <<EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "dns": {"servers": [{"type": "udp","tag": "dns4","server": "1.1.1.1"}]},
  "inbounds": [
    {
      "type": "tuic","listen": "::","tag": "tuic-in","listen_port": ${port},
      "users": [{"uuid": "${uuid}","password": "${uuid}"}],
      "congestion_control": "${cc}",
      "tls": {"enabled": true,"server_name": "${domain}","alpn": ["h3"],"certificate_path": "${crt}","key_path": "${key}"}
    }
  ],
  "outbounds": [{"type":"direct","tag":"direct_ipv4","domain_resolver":{"server":"dns4","strategy":"ipv4_only"}}],
  "route": {"final":"direct_ipv4"}
}
EOF
}
install_singbox_service_if_missing() {
    if service_exists tuic-box; then return; fi
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/tuic-box <<EOF
#!/sbin/openrc-run
description="Tuic by sing-box"
command="${sb_bin}"
command_args="run -c ${sb_conf}"
command_background=true
pidfile="/var/run/tuic-box.pid"
EOF
        chmod +x /etc/init.d/tuic-box
    else
        cat > /etc/systemd/system/tuic-box.service <<EOF
[Unit]
Description=Tuic by sing-box
After=network.target
[Service]
Type=simple
ExecStart=${sb_bin} run -c ${sb_conf}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    fi
    manage_service enable tuic-box
}
start_singbox_and_check() {
    manage_service restart tuic-box
    sleep 1
    if is_service_running tuic-box; then return 0; fi
    red "sing-box 启动失败"
    if [ -f /etc/alpine-release ]; then
        rc-service tuic-box status 2>/dev/null
    else
        journalctl -u tuic-box -n 80 --no-pager
    fi
    return 1
}
load_tuic_state() {
    TUIC_PORT=""; TUIC_CC=""; TUIC_DOMAIN=""; TUIC_UUID=""
    [ -f "$sb_state" ] || return
    IFS='|' read -r TUIC_PORT TUIC_CC TUIC_DOMAIN TUIC_UUID < "$sb_state"
}
install_tuic_flow() {
    install_singbox_core_only || return 1
    local domain token port cc uuid default_uuid
    prompt "Tuic域名: " domain; [ -z "$domain" ] && { red "域名不能为空"; return 1; }
    prompt "Cloudflare API Token: " token; [ -z "$token" ] && { red "Token不能为空"; return 1; }
    prompt "Tuic端口(默认18443): " port; [ -z "$port" ] && port=18443
    [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }

    echo "拥塞算法: 1.bbr 2.cubic 3.new_reno"
    prompt "选择(默认1): " csel
    case "$csel" in
        2) cc="cubic" ;;
        3) cc="new_reno" ;;
        *) cc="bbr" ;;
    esac

    default_uuid="$(get_current_uuid_xray_or_fallback)"
    prompt "Tuic UUID(回车默认 ${default_uuid}): " uuid
    [ -z "$uuid" ] && uuid="$default_uuid"

    issue_cert_cf_token "$domain" "$token" || return 1
    ensure_port_open "$port" udp
    write_tuic_config "$domain" "$port" "$cc" "$uuid"
    install_singbox_service_if_missing

    ask_apply_youtube_v6_once
    apply_outbound_policy_singbox || true

    start_singbox_and_check || return 1
    printf '%s|%s|%s|%s\n' "$port" "$cc" "$domain" "$uuid" > "$sb_state"
    green "Tuic 安装成功"
    show_tuic_node
}

restart_singbox_menu() {
    if ! service_exists tuic-box; then red "Tuic未安装"; return; fi
    start_singbox_and_check && green "Tuic已重启"
}
uninstall_singbox_menu() {
    manage_service stop tuic-box 2>/dev/null
    manage_service disable tuic-box 2>/dev/null
    rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service
    rm -rf "$SB_BASE"
    green "Sbox 已卸载"
}

load_restart_hours() {
    RESTART_HOURS=0
    if [ -f "$restart_conf" ]; then
        RESTART_HOURS=$(cat "$restart_conf" 2>/dev/null)
        [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
    fi
}
setup_cron_env_if_missing() {
    if command -v crontab >/dev/null 2>&1; then return; fi
    if command -v apt-get >/dev/null 2>&1; then
        manage_packages cron; manage_service enable cron 2>/dev/null || true; manage_service start cron 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        manage_packages dcron; rc-service dcron start 2>/dev/null || true; rc-update add dcron default >/dev/null 2>&1 || true
    else
        manage_packages cronie; manage_service enable crond 2>/dev/null || true; manage_service start crond 2>/dev/null || true
    fi
}
manage_restart_hours() {
    load_restart_hours
    cls
    green "当前间隔: ${RESTART_HOURS}小时 (0=关闭)"
    prompt "输入间隔小时: " h
    [[ "$h" =~ ^[0-9]+$ ]] || { red "输入无效"; return; }

    RESTART_HOURS="$h"
    echo "$RESTART_HOURS" > "$restart_conf"

    if [ "$RESTART_HOURS" -eq 0 ]; then
        command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab -
        green "已关闭"
        return
    fi

    setup_cron_env_if_missing
    command -v crontab >/dev/null 2>&1 || { red "crontab不可用"; return; }

    local cmd exp
    if [ -f /etc/alpine-release ]; then
        cmd='[ -f /etc/init.d/xray ] && rc-service xray restart; [ -f /etc/init.d/tuic-box ] && rc-service tuic-box restart; [ -f /etc/init.d/tunnel-argo ] && rc-service tunnel-argo restart'
    else
        cmd='systemctl list-unit-files | grep -q "^xray.service" && systemctl restart xray; systemctl list-unit-files | grep -q "^tuic-box.service" && systemctl restart tuic-box; systemctl list-unit-files | grep -q "^tunnel-argo.service" && systemctl restart tunnel-argo'
    fi
    exp="0 */${RESTART_HOURS} * * *"
    (crontab -l 2>/dev/null | sed '/#svc-restart-all/d'; echo "${exp} ${cmd} >/dev/null 2>&1 #svc-restart-all") | crontab -
    green "已设置每${RESTART_HOURS}小时重启（xray/tuic-box/argo）"
}

swap_cleanup_entries() { [ -f /etc/fstab ] && sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab; }
swap_disable_all() {
    awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | while read -r d; do [ -n "$d" ] && swapoff "$d" >/dev/null 2>&1 || true; done
    [ -f /swapfile ] && rm -f /swapfile
    swap_cleanup_entries
    if [ -d /sys/class/zram-control ] || [ -e /dev/zram0 ]; then
        for z in /sys/block/zram*; do [ -d "$z" ] || continue; echo 1 > "$z/reset" 2>/dev/null || true; done
    fi
}
zram_supported() {
    [ -e /dev/zram0 ] && return 0
    if [ -d /sys/module/zram ] || command -v modprobe >/dev/null 2>&1; then modprobe zram >/dev/null 2>&1 || true; fi
    [ -e /dev/zram0 ] && return 0
    [ -w /sys/class/zram-control/hot_add ] && return 0
    return 1
}
create_zram_swap() {
    local mb="$1" zdev="" zname=""
    if [ -e /dev/zram0 ]; then zdev="/dev/zram0"
    elif [ -w /sys/class/zram-control/hot_add ]; then
        local id; id=$(cat /sys/class/zram-control/hot_add 2>/dev/null); [ -n "$id" ] && zdev="/dev/zram${id}"
    fi
    [ -z "$zdev" ] && return 1
    zname="${zdev#/dev/}"
    echo 1 > "/sys/block/${zname}/reset" 2>/dev/null || true
    [ -w "/sys/block/${zname}/comp_algorithm" ] && echo lz4 > "/sys/block/${zname}/comp_algorithm" 2>/dev/null || true
    echo "$((mb * 1024 * 1024))" > "/sys/block/${zname}/disksize" 2>/dev/null || return 1
    mkswap "$zdev" >/dev/null 2>&1 || return 1
    swapon "$zdev" >/dev/null 2>&1 || return 1
}
create_swapfile_dd() {
    local mb="$1"
    dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>"$swap_log_file" || return 1
    chmod 600 /swapfile || return 1
    mkswap /swapfile >/dev/null 2>&1 || return 1
    swapon /swapfile >/dev/null 2>&1 || return 1
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swapfile_fallocate() {
    local mb="$1"
    command -v fallocate >/dev/null 2>&1 || return 1
    fallocate -l "${mb}M" /swapfile 2>"$swap_log_file" || return 1
    chmod 600 /swapfile || return 1
    mkswap -f /swapfile >/dev/null 2>&1 || return 1
    swapon /swapfile >/dev/null 2>&1 || return 1
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swap_best_effort() {
    local mb="${1:-256}"
    swap_disable_all
    if zram_supported && create_zram_swap "$mb"; then green "SWAP成功(ZRAM ${mb}MB)"; return 0; fi
    if create_swapfile_dd "$mb"; then green "SWAP成功(dd ${mb}MB)"; return 0; fi
    rm -f /swapfile
    if create_swapfile_fallocate "$mb"; then green "SWAP成功(fallocate ${mb}MB)"; return 0; fi
    red "SWAP失败"
    return 1
}
manage_swap() {
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
            1) prompt "大小MB(默认256): " mb; mb=${mb:-256}; [[ "$mb" =~ ^[0-9]+$ ]] && [ "$mb" -gt 0 ] && create_swap_best_effort "$mb" || red "输入无效"; pause ;;
            2) swap_disable_all; green "已清理"; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

manage_outbound_policy_menu() {
    load_outbound_policy
    while true; do
        cls
        local ystat
        [ "$YOUTUBE_V6" = "1" ] && ystat="\033[1;32m已开启\033[0m" || ystat="\033[1;91m未开启\033[0m"
        echo -e "${C_OUTBOUND}========== 出站管理（Xray + Sbox）==========${C_RST}"
        echo -e "默认出站: \033[1;36mIPv4\033[0m"
        echo -e "YouTube IPv6: ${ystat}"
        echo -e "IPv6规则: \033[1;36m${V6_SITE_LIST:-（空）}\033[0m"
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m \033[1;32m开启\033[0m${C_OUTBOUND}YouTube IPv6出站${C_RST}"
        echo -e "\033[1;36m 2.\033[0m \033[1;36m添加\033[0m${C_OUTBOUND}IPv6出站规则${C_RST}"
        echo -e "\033[1;91m 3.\033[0m \033[1;91m删除\033[0m${C_OUTBOUND}IPv6出站规则${C_RST}"
        echo -e "\033[1;33m 4.\033[0m \033[1;33m重启\033[0m服务应用规则"
        echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
        echo "==============================================="
        prompt "请选择: " c
        case "$c" in
            1) YOUTUBE_V6=1; save_outbound_policy; green "已开启YouTube IPv6出站"; pause ;;
            2)
                prompt "输入域名(逗号分隔): " s
                [ -z "$s" ] && { red "不能为空"; pause; continue; }
                [ -z "$V6_SITE_LIST" ] && V6_SITE_LIST="$s" || V6_SITE_LIST="${V6_SITE_LIST},${s}"
                V6_SITE_LIST=$(echo "$V6_SITE_LIST" | sed 's/,,*/,/g; s/^,//; s/,$//')
                save_outbound_policy
                green "已添加规则"
                pause
                ;;
            3)
                if [ -z "$V6_SITE_LIST" ]; then red "规则为空"; pause; continue; fi
                local arr i=1
                IFS=',' read -r -a arr <<< "$V6_SITE_LIST"
                echo "当前规则："
                for d in "${arr[@]}"; do
                    d=$(echo "$d" | sed 's/^ *//; s/ *$//')
                    [ -z "$d" ] && continue
                    echo "  $i. $d"
                    i=$((i+1))
                done
                echo "  a. 全部删除"
                echo "  0. 取消"
                prompt "请输入序号或a: " idx
                if [ "$idx" = "a" ] || [ "$idx" = "A" ]; then
                    V6_SITE_LIST=""
                    save_outbound_policy
                    green "已全删"
                    pause
                    continue
                fi
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -le 0 ] || [ "$idx" -ge "$i" ]; then
                    [ "$idx" = "0" ] && continue
                    red "序号无效"; pause; continue
                fi
                local new="" j=1
                for d in "${arr[@]}"; do
                    d=$(echo "$d" | sed 's/^ *//; s/ *$//')
                    [ -z "$d" ] && continue
                    [ "$j" -ne "$idx" ] && { [ -z "$new" ] && new="$d" || new="${new},${d}"; }
                    j=$((j+1))
                done
                V6_SITE_LIST="$new"
                save_outbound_policy
                green "已删除"
                pause
                ;;
            4) apply_outbound_policy_all; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

xray_menu() {
    while true; do
        cls
        local x_stat a_stat
        if [ -x "$xray_bin" ]; then
            x_stat=$(is_service_running xray && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
        else
            x_stat="${C_BAD}未安装${C_RST}"
        fi
        if service_exists tunnel-argo; then
            a_stat=$(is_service_running tunnel-argo && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
        else
            a_stat="${C_BAD}未配置${C_RST}"
        fi

        echo -e "${C_XRAY}=============== Xray管理 ===============${C_RST}"
        echo -e "${C_XRAY}Xray${C_RST}: ${x_stat}     ${C_ARGO}Argo${C_RST}: ${a_stat}"
        echo "-----------------------------------------------"
        echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_ARGO}Argo${C_RST}              ${C_VIEW} 6.${C_RST} ${C_VIEW}查看${C_RST}${C_NODE}节点${C_RST}"
        echo -e "${C_RESTART} 8.${C_RST} ${C_RESTART}重启${C_RST}${C_XRAY}Xray${C_RST}              ${C_MODIFY} 5.${C_RST} ${C_MODIFY}修改${C_RST}${C_UUID}UUID${C_RST}"
        echo -e "${C_RESTART} 7.${C_RST} ${C_RESTART}重启${C_RST}${C_ARGO}Argo${C_RST}              ${C_MANAGE} 3.${C_RST} ${C_MANAGE}管理${C_RST}${C_SOCKS5}Socks5${C_RST}"
        echo -e "${C_BAD} 9.${C_RST} ${C_BAD}卸载${C_RST}${C_XRAY}Xray${C_RST}              ${C_MANAGE} 4.${C_RST} ${C_MANAGE}管理${C_RST}${C_FREEFLOW}免流${C_RST}"
        echo -e "${C_BAD} 2.${C_RST} ${C_BAD}卸载${C_RST}${C_ARGO}Argo${C_RST}              ${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
        echo "==============================================="
        prompt "请选择: " c
        case "$c" in
            1) install_or_reinstall_argo; pause ;;
            2) uninstall_argo_only; pause ;;
            3) manage_socks5 ;;
            4) manage_freeflow ;;
            5)
                [ -f "$xray_conf" ] || { red "xray未安装"; pause; continue; }
                prompt "新UUID(回车自动): " u
                [ -z "$u" ] && u="$(generate_uuid)"
                set_xray_uuid_no_validate "$u"
                pause
                ;;
            6) show_xray_nodes; pause ;;
            7) restart_argo_if_installed; pause ;;
            8) restart_xray_if_installed; pause ;;
            9)
                manage_service stop tunnel-argo 2>/dev/null
                manage_service disable tunnel-argo 2>/dev/null
                rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
                manage_service stop xray 2>/dev/null
                manage_service disable xray 2>/dev/null
                rm -f /etc/init.d/xray /etc/systemd/system/xray.service
                rm -f "$xray_bin" "$xray_conf" "${work_dir}/argo" "$argo_domain_file" "$argo_yml" "$argo_json" "${work_dir}/argo_start.sh" "$freeflow_conf"
                green "Xray已卸载"
                pause
                ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

singbox_menu() {
    while true; do
        cls
        local st
        if [ -x "$sb_bin" ]; then
            st=$(is_service_running tuic-box && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
        else
            st="${C_BAD}未安装${C_RST}"
        fi

        echo -e "${C_SBOX}=============== Sbox管理 ===============${C_RST}"
        echo -e "Sbox: ${st}"
        echo "-----------------------------------------------"
        echo -e "${C_INSTALL} 1.${C_RST} ${C_INSTALL}安装${C_RST}${C_TUIC}Tuic${C_RST}"
        echo -e "${C_VIEW} 2.${C_RST} ${C_VIEW}查看${C_RST}${C_NODE}节点${C_RST}"
        echo -e "${C_RESTART} 3.${C_RST} ${C_RESTART}重启${C_RST}${C_TUIC}Tuic${C_RST}"
        echo -e "${C_BAD} 4.${C_RST} ${C_BAD}卸载${C_RST}${C_TUIC}Tuic${C_RST}"
        echo -e "${C_BAD} 0.${C_RST} ${C_BAD}返回${C_RST}"
        echo "==============================================="
        prompt "请选择: " c
        case "$c" in
            1) install_tuic_flow; pause ;;
            2) show_tuic_node; pause ;;
            3) restart_singbox_menu; pause ;;
            4) uninstall_singbox_menu; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

full_uninstall() {
    manage_service stop tunnel-argo 2>/dev/null
    manage_service disable tunnel-argo 2>/dev/null
    rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service

    manage_service stop xray 2>/dev/null
    manage_service disable xray 2>/dev/null
    rm -f /etc/init.d/xray /etc/systemd/system/xray.service

    manage_service stop tuic-box 2>/dev/null
    manage_service disable tuic-box 2>/dev/null
    rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service

    command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab - 2>/dev/null
    swap_disable_all >/dev/null 2>&1 || true

    rm -rf "$work_dir" "$SB_BASE" "$tls_dir"
    green "已彻底卸载"
}

install_shortcut_once() {
    mkdir -p "$work_dir"
    local mark="${work_dir}/.shortcut_done"
    [ -f "$mark" ] && { green "快捷方式已存在：ssgo"; return; }

    local src dst="/usr/local/bin/ssgo"
    src=$(readlink -f "$0" 2>/dev/null)
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
    fi

    if [ -n "$src" ] && [ -f "$src" ]; then
        cp -f "$src" "${work_dir}/manager.sh" 2>/dev/null || true
        cat > "$dst" <<'EOF'
#!/usr/bin/env bash
bash /etc/xray/manager.sh "$@"
EOF
        chmod +x "$dst"
        ln -sf "$dst" /usr/bin/ssgo 2>/dev/null || true
        touch "$mark"
        green "快捷方式已创建：ssgo"
    else
        yellow "未能识别脚本源路径，稍后可手动重建快捷方式"
    fi
}

wait_ip_first_time() {
    if [ -f "$ip_cache_file" ] && load_ip_cache; then
        IP_CACHE_MTIME=$(stat -c %Y "$ip_cache_file" 2>/dev/null || echo 0)
        return 0
    fi

    cls
    echo -e "\033[1;33mIP信息加载中，请稍候...\033[0m"
    check_system_ip
    IP_CACHE_MTIME=$(stat -c %Y "$ip_cache_file" 2>/dev/null || echo 0)
}

bootstrap_fast() {
    manage_packages jq wget curl iproute2 coreutils tar unzip openssl >/dev/null 2>&1
    install_shortcut_once
    get_sys_info
    load_restart_hours
    load_outbound_policy
    wait_ip_first_time
}

main_menu() {
    bootstrap_fast
    while true; do
        cls
        refresh_ip_cache_if_changed || true

        local len4 len6 pad p4 p6 ip4_disp ip6_disp mem_used
        len4=${#WAN4}; len6=${#WAN6}; pad=$(( len4 > len6 ? len4 : len6 ))
        [ -z "$pad" ] && pad=0

        if [ "$IP_CHECKED" = "1" ] && [ -n "$WAN4" ]; then
            p4=$(printf "%-${pad}s" "$WAN4")
            ip4_disp="\033[1;36m${p4}  (${COUNTRY4} ${AS_NUM4} ${ISP_CLEAN4})\033[0m"
        elif [ "$IP_CHECKED" = "1" ]; then
            ip4_disp="${C_BAD}未配置${C_RST}"
        else
            ip4_disp="${C_BAD}未启动${C_RST}"
        fi

        if [ "$IP_CHECKED" = "1" ] && [ -n "$WAN6" ]; then
            p6=$(printf "%-${pad}s" "$WAN6")
            ip6_disp="\033[1;36m${p6}  (${COUNTRY6} ${AS_NUM6} ${ISP_CLEAN6})\033[0m"
        elif [ "$IP_CHECKED" = "1" ]; then
            ip6_disp="${C_BAD}未配置${C_RST}"
        else
            ip6_disp="${C_BAD}未启动${C_RST}"
        fi

        mem_used=$(get_used_mem_display)

        echo -e "OS : \033[1;36m${SYS_INFO_CACHE}\033[0m"
        echo -e "v4 : ${ip4_disp}"
        echo -e "v6 : ${ip6_disp}"
        echo -e "Mem: \033[1;36m${mem_used}\033[0m"
        echo "-----------------------------------------------"
        echo -e "${C_MANAGE} 1.${C_RST} ${C_MANAGE}管理 Xray${C_RST}           ${C_MANAGE} 5.${C_RST} ${C_MANAGE}管理${C_RST}${C_SWAP} SWAP${C_RST}"
        echo -e "${C_MANAGE} 2.${C_RST} ${C_MANAGE}管理${C_RST}${C_SBOX} Sbox${C_RST}           ${C_INSTALL} 6.${C_RST} ${C_INSTALL}创建${C_RST}${C_SHORTCUT} 快捷${C_RST}"
        echo -e "${C_MANAGE} 3.${C_RST} ${C_MANAGE}管理${C_RST}${C_OUTBOUND} 出站${C_RST}${C_POLICY} 策略${C_RST}     ${C_BAD} 9.${C_RST} ${C_BAD}彻底 卸载${C_RST}"
        echo -e "${C_RESTART} 4.${C_RST} ${C_RESTART}定时 重启${C_RST}           ${C_BAD} 0.${C_RST} ${C_BAD}退出${C_RST}"
        echo "==============================================="

        prompt "请选择: " c
        case "$c" in
            1) xray_menu ;;
            2) singbox_menu ;;
            3) manage_outbound_policy_menu ;;
            4) manage_restart_hours; pause ;;
            5) manage_swap ;;
            6) install_shortcut_once; pause ;;
            9) full_uninstall; pause ;;
            0) cls; exit 0 ;;
            *) red "无效"; pause ;;
        esac
    done
}

trap 'echo ""; cls; red "已中断"; exit 130' INT TERM
main_menu
