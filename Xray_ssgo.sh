#!/usr/bin/env bash
set -o pipefail

# =========================
# Color / UI
# =========================
red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }

clear_buffer() {
    while read -r -t 0.1 -n 10000 _dummy </dev/tty 2>/dev/null; do :; done
}

prompt() {
    clear_buffer
    printf '\033[1;91m%s\033[0m' "$1" >&2
    read -r "$2" </dev/tty
}

pause() {
    printf '\n\033[1;91m按回车键继续...\033[0m\n' >&2
    clear_buffer
    read -r _dummy </dev/tty
}

cls() {
    clear
    printf '\033[3J\033[2J\033[H'
}

url_encode() { jq -rn --arg x "$1" '$x|@uri'; }

# =========================
# Global
# =========================
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"

freeflow_conf="${work_dir}/freeflow.conf"
restart_conf="${work_dir}/restart.conf"
swap_log_file="/tmp/ssgo_swap.log"

# extra modules
tuic_conf="${work_dir}/tuic.conf"           # port|congestion
reality_conf="${work_dir}/reality.conf"     # port|sni|dest|priv|pub|sid

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}

FREEFLOW_MODE="none"
FF_PATH="/"

# 重启改小时
RESTART_HOURS=0

XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1
[ -t 0 ] || { red "请在交互式终端中运行脚本"; exit 1; }

# =========================
# Helpers
# =========================
update_config() {
    if ! jq "$@" "${config_dir}" > "${config_dir}.tmp"; then
        red "配置更新失败：JSON/jq 表达式异常"
        rm -f "${config_dir}.tmp"
        return 1
    fi
    mv "${config_dir}.tmp" "${config_dir}"
}

manage_service() {
    local action="$1"
    local svc_name="$2"
    if [ -f /etc/alpine-release ]; then
        case "$action" in
            start|stop|restart) rc-service "$svc_name" "$action" >/dev/null 2>&1 ;;
            enable) rc-update add "$svc_name" default >/dev/null 2>&1 ;;
            disable) rc-update del "$svc_name" default >/dev/null 2>&1 ;;
        esac
    else
        case "$action" in
            enable) systemctl enable "$svc_name" >/dev/null 2>&1; systemctl daemon-reload >/dev/null 2>&1 ;;
            disable) systemctl disable "$svc_name" >/dev/null 2>&1; systemctl daemon-reload >/dev/null 2>&1 ;;
            *) systemctl "$action" "$svc_name" >/dev/null 2>&1 ;;
        esac
    fi
}

is_service_running() {
    if [ -f /etc/alpine-release ]; then
        rc-service "$1" status 2>/dev/null | grep -q "started"
    else
        [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]
    fi
}

manage_packages() {
    local need_update=1
    local package
    for package in "$@"; do
        local cmd_check
        case "$package" in
            iproute2)  cmd_check="ip" ;;
            coreutils) cmd_check="base64" ;;
            *)         cmd_check="$package" ;;
        esac
        command -v "$cmd_check" >/dev/null 2>&1 && continue

        if [ "$need_update" -eq 1 ]; then
            if command -v apt-get >/dev/null 2>&1; then apt-get update -y >/dev/null 2>&1
            elif command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1
            fi
            need_update=0
        fi

        yellow "正在安装 ${package}..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$package" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$package" >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add "$package" >/dev/null 2>&1
        fi
    done
}

generate_uuid() { cat /proc/sys/kernel/random/uuid; }

normalize_path() {
    local x="$1"
    [ -z "$x" ] && { echo "/"; return; }
    case "$x" in
        /*) echo "$x" ;;
        *)  echo "/$x" ;;
    esac
}

get_current_uuid() {
    if [ -f "${config_dir}" ]; then
        local id
        id=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "${config_dir}" 2>/dev/null)
        [ -n "$id" ] && [ "$id" != "null" ] && { echo "$id"; return; }
    fi
    echo "${UUID_FALLBACK}"
}

# =========================
# load state
# =========================
load_state() {
    if [ -f "${freeflow_conf}" ]; then
        local l1 l2
        { read -r l1; read -r l2; } < "${freeflow_conf}"
        case "$l1" in
            ws|httpupgrade) FREEFLOW_MODE="$l1" ;;
            *) FREEFLOW_MODE="none" ;;
        esac
        [ -n "$l2" ] && FF_PATH="$l2"
    fi

    if [ -f "${restart_conf}" ]; then
        RESTART_HOURS="$(cat "${restart_conf}" 2>/dev/null)"
        [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
    fi
}
load_state

# =========================
# system info
# =========================
detect_virtualization() {
    local virt="UNKNOWN"
    local v="" product_name=""

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

    if [ "$virt" = "UNKNOWN" ]; then
        if grep -qaE 'container=(lxc|docker|podman)' /proc/1/environ 2>/dev/null; then
            if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
                virt="LXC"
            elif grep -qa 'container=docker' /proc/1/environ 2>/dev/null; then
                virt="DOCKER"
            elif grep -qa 'container=podman' /proc/1/environ 2>/dev/null; then
                virt="PODMAN"
            else
                virt="CONTAINER"
            fi
        elif [ -f /proc/user_beancounters ]; then
            virt="OPENVZ"
        elif [ -r /sys/class/dmi/id/product_name ]; then
            read -r product_name < /sys/class/dmi/id/product_name
            case "$product_name" in
                *KVM*|*kvm*) virt="KVM" ;;
                *QEMU*|*qemu*) virt="QEMU" ;;
                *VMware*|*vmware*) virt="VMWARE" ;;
                *Xen*|*xen*) virt="XEN" ;;
                *VirtualBox*|*virtualbox*) virt="VIRTUALBOX" ;;
                *Hyper-V*|*hyperv*|*Microsoft*) virt="HYPER-V" ;;
            esac
        fi
    fi
    echo "$virt"
}

get_sys_info() {
    [ -n "${SYS_INFO_CACHE}" ] && return
    local os_ver kernel_ver virt mem disk os_name

    if [ -f /etc/alpine-release ]; then
        read -r os_ver < /etc/alpine-release
        os_ver="Alpine ${os_ver}"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$ID" ] && [ -n "$VERSION_ID" ]; then
            os_name=$(echo "$ID" | sed -e 's/^[a-z]/\U&/')
            os_ver="${os_name} ${VERSION_ID}"
        elif [ -n "$PRETTY_NAME" ]; then
            os_ver="${PRETTY_NAME}"
        else
            os_ver="Linux"
        fi
        os_ver=$(echo "$os_ver" | sed -E 's/ \([a-zA-Z0-9._-]+\)//g')
    else
        os_ver="Linux"
    fi

    read -r kernel_ver < /proc/sys/kernel/osrelease
    kernel_ver=${kernel_ver%%[-+]*}
    virt=$(detect_virtualization)
    mem=$(awk '/MemTotal/{m=$2/1024; if(m>1024) printf"%.1fG",m/1024; else printf"%.0fM",m}' /proc/meminfo 2>/dev/null)
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')
    SYS_INFO_CACHE="${os_ver} | ${kernel_ver} | ${virt} | ${mem} | ${disk}"
}

check_system_ip() {
    [ "$IP_CHECKED" = "1" ] && return
    local IF4 IF6 BA4="" BA6=""
    IF4=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
    IF6=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')

    if [ -n "${IF4}${IF6}" ]; then
        local IP4L IP6L
        IP4L=$(ip -4 addr show "$IF4" 2>/dev/null | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp' | head -n1)
        IP6L=$(ip -6 addr show "$IF6" 2>/dev/null | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp' | head -n1)
        [ -n "$IP4L" ] && BA4="--bind-address=$IP4L"
        [ -n "$IP6L" ] && BA6="--bind-address=$IP6L"
    fi

    local t4 t6
    t4=$(mktemp)
    t6=$(mktemp)

    wget $BA4 -4 -qO- --no-check-certificate --tries=2 --timeout=3 "https://ip.cloudflare.now.cc?lang=zh-CN" >"$t4" 2>/dev/null &
    local p4=$!
    wget $BA6 -6 -qO- --no-check-certificate --tries=2 --timeout=3 "https://ip.cloudflare.now.cc?lang=zh-CN" >"$t6" 2>/dev/null &
    local p6=$!

    wait "$p4" 2>/dev/null || true
    wait "$p6" 2>/dev/null || true

    local J4 J6
    J4=$(cat "$t4" 2>/dev/null)
    J6=$(cat "$t6" 2>/dev/null)
    rm -f "$t4" "$t6"

    if [ -n "$J4" ]; then
        WAN4=$(jq -r '.ip // empty' <<<"$J4" 2>/dev/null)
        COUNTRY4=$(jq -r '.country // empty' <<<"$J4" 2>/dev/null)
        EMOJI4=$(jq -r '.emoji // empty' <<<"$J4" 2>/dev/null)
        local ASN4 ISP4
        ASN4=$(jq -r '.asn // empty' <<<"$J4" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        ISP4=$(jq -r '.isp // empty' <<<"$J4" 2>/dev/null)
        [ -n "$ASN4" ] && AS_NUM4="AS${ASN4}" || AS_NUM4=$(echo "$ISP4" | grep -oE 'AS[0-9]+' | head -n1)
        ISP_CLEAN4=$(echo "$ISP4" | sed -E 's/AS[0-9]+[ -]*//g' | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    fi

    if [ -n "$J6" ]; then
        WAN6=$(jq -r '.ip // empty' <<<"$J6" 2>/dev/null)
        COUNTRY6=$(jq -r '.country // empty' <<<"$J6" 2>/dev/null)
        EMOJI6=$(jq -r '.emoji // empty' <<<"$J6" 2>/dev/null)
        local ASN6 ISP6
        ASN6=$(jq -r '.asn // empty' <<<"$J6" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        ISP6=$(jq -r '.isp // empty' <<<"$J6" 2>/dev/null)
        [ -n "$ASN6" ] && AS_NUM6="AS${ASN6}" || AS_NUM6=$(echo "$ISP6" | grep -oE 'AS[0-9]+' | head -n1)
        ISP_CLEAN6=$(echo "$ISP6" | sed -E 's/AS[0-9]+[ -]*//g' | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    fi

    NODE_PREFIX="Argo"
    if [ -n "$EMOJI4" ] && [ -n "$ISP_CLEAN4" ]; then
        NODE_PREFIX="${EMOJI4}[${COUNTRY4}] ${ISP_CLEAN4}"
    elif [ -n "$EMOJI6" ] && [ -n "$ISP_CLEAN6" ]; then
        NODE_PREFIX="${EMOJI6}[${COUNTRY6}] ${ISP_CLEAN6}"
    fi

    IP_CHECKED=1
}

# =========================
# xray base config
# =========================
init_xray_config() {
    mkdir -p "${work_dir}"
    if [ ! -f "${config_dir}" ]; then
        cat >"${config_dir}" <<'EOF'
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
    { "protocol": "freedom",   "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "tag": "block"   },
    { "protocol": "dns",       "tag": "dns-out" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
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
    init_xray_config

    local has_dnsout
    has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "${config_dir}" 2>/dev/null)
    if [ "$has_dnsout" != "true" ]; then
        update_config '.outbounds += [{"protocol":"dns","tag":"dns-out"}]' || return 1
    fi

    if ! jq -e '.routing' "${config_dir}" >/dev/null 2>&1; then
        update_config '.routing={"domainStrategy":"AsIs","rules":[]}' || return 1
    fi

    local has53 hasdns
    has53=$(jq '[.routing.rules[]? | select(.port=="53")] | length' "${config_dir}" 2>/dev/null)
    hasdns=$(jq '[.routing.rules[]? | select(.protocol=="dns")] | length' "${config_dir}" 2>/dev/null)
    if [ "${has53:-0}" -eq 0 ] || [ "${hasdns:-0}" -eq 0 ]; then
        update_config 'del(.routing.rules[]? | select(.port=="53" or .protocol=="dns"))' || return 1
        update_config '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]' || return 1
    fi
}

# =========================
# download
# =========================
to_ghfast_url() {
    local src="$1"
    case "$src" in
        https://github.com/*|https://raw.githubusercontent.com/*) echo "https://ghfast.top/${src}" ;;
        *) echo "$src" ;;
    esac
}

smart_download() {
    local target_file="$1"
    local url="$2"
    local min_size_bytes="$3"

    local max_retries=3
    local retry_count=0
    local dl_success=0
    local current_url="$url"
    local using_mirror=0

    local total_ram use_slow_mode
    total_ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    use_slow_mode=0
    [ -n "$total_ram" ] && [ "$total_ram" -le 75 ] && use_slow_mode=1

    while [ "$retry_count" -lt "$max_retries" ]; do
        rm -f "${target_file}"

        local t_start t_end elapsed
        t_start=$(date +%s)
        if [ "$use_slow_mode" -eq 1 ]; then
            yellow "正在安全下载 (尝试 $((retry_count + 1))/${max_retries})，2M/s..."
            wget -q --show-progress --limit-rate=2M --timeout=30 --tries=1 -O "${target_file}" "${current_url}"
        else
            purple "正在全速下载 (尝试 $((retry_count + 1))/${max_retries})..."
            wget -q --show-progress --timeout=30 --tries=1 -O "${target_file}" "${current_url}"
        fi
        t_end=$(date +%s)
        elapsed=$((t_end - t_start))
        [ "$elapsed" -le 0 ] && elapsed=1

        if [ -f "${target_file}" ]; then
            local file_size
            file_size=$(wc -c < "${target_file}" 2>/dev/null || stat -c%s "${target_file}" 2>/dev/null)
            if [ -n "$file_size" ] && [ "$file_size" -ge "$min_size_bytes" ]; then
                if [ "$retry_count" -eq 0 ] && [ "$using_mirror" -eq 0 ]; then
                    local speed_kbs
                    speed_kbs=$((file_size / elapsed / 1024))
                    [ "$speed_kbs" -lt 80 ] && yellow "GitHub 速度较慢(${speed_kbs}KB/s)，失败将切 ghfast。"
                fi
                green "下载成功 (${file_size} bytes)"
                dl_success=1
                break
            else
                red "下载文件体积异常(${file_size} bytes)"
            fi
        else
            red "下载失败：未生成目标文件"
        fi

        [ "$use_slow_mode" -eq 0 ] && { yellow "降级限速重试"; use_slow_mode=1; }

        if [ "$using_mirror" -eq 0 ]; then
            local mirror
            mirror=$(to_ghfast_url "$url")
            if [ "$mirror" != "$url" ]; then
                yellow "切换 ghfast.top 加速"
                current_url="$mirror"
                using_mirror=1
            fi
        fi

        retry_count=$((retry_count + 1))
        [ "$retry_count" -lt "$max_retries" ] && sleep 3
    done

    if [ "$dl_success" -eq 0 ]; then
        red "下载失败，已终止"
        exit 1
    fi
}

detect_xray_arch() {
    local a
    a=$(uname -m)
    case "$a" in
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
    local a
    a=$(uname -m)
    case "$a" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i486|i586|i686) echo "386" ;;
        armv7l|armv7|armhf) echo "arm" ;;
        *) echo "" ;;
    esac
}

# =========================
# install core
# =========================
install_core() {
    manage_packages jq unzip wget iproute2 coreutils tar openssl
    if ! command -v jq >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1; then
        red "依赖安装失败，请检查网络"
        exit 1
    fi

    mkdir -p "${work_dir}"
    init_xray_config

    if [ ! -f "${work_dir}/${server_name}" ]; then
        echo ""
        purple "=== 部署 Xray 内核 ==="
        local arch
        arch=$(detect_xray_arch)
        [ -z "$arch" ] && { red "不支持架构: $(uname -m)"; exit 1; }

        local xray_url
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        smart_download "${work_dir}/xray.zip" "${xray_url}" 5000000
        unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" >/dev/null 2>&1
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/xray.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi

    if [ ! -f /etc/systemd/system/xray.service ] && [ ! -f /etc/init.d/xray ]; then
        if [ -f /etc/alpine-release ]; then
            cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="${work_dir}/xray"
command_args="run -c ${config_dir}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
            chmod +x /etc/init.d/xray
        else
            cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=always
Environment="GOGC=20"
Environment="GOMEMLIMIT=40MiB"
[Install]
WantedBy=multi-user.target
EOF
        fi
        manage_service enable xray
    fi
}

# =========================
# status helpers
# =========================
get_mem_by_svc() {
    local svc_name="$1"
    local cmd_match="$2"
    local pid=""

    if [ -f /etc/alpine-release ]; then
        pid=$(pgrep -f "$cmd_match" | head -n 1)
    else
        pid=$(systemctl show -p MainPID --value "$svc_name" 2>/dev/null)
        [ -z "$pid" ] || [ "$pid" = "0" ] && pid=$(pgrep -f "$cmd_match" | head -n 1)
    fi

    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        local mem
        mem=$(grep -i VmRSS "/proc/$pid/status" | awk '{print $2}')
        if [ -n "$mem" ] && [ "$mem" -gt 0 ]; then
            awk "BEGIN {printf \"%.1fM\", $mem/1024}"
        fi
    fi
}

check_status() {
    local svc_name="$1"
    local bin_path="$2"
    local cmd_match="$3"

    [ ! -f "$bin_path" ] && { printf '\033[1;91m未安装\033[0m'; return 2; }

    if is_service_running "$svc_name"; then
        local mem
        mem=$(get_mem_by_svc "$svc_name" "$cmd_match")
        [ -n "$mem" ] && printf '\033[1;36m运行(%s)\033[0m' "$mem" || printf '\033[1;36m运行\033[0m'
        return 0
    fi
    printf '\033[1;91m未启动\033[0m'
    return 1
}

# =========================
# freeflow
# =========================
ask_freeflow_mode() {
    echo ""
    green "请选择 FreeFlow 方式："
    printf '%s\n' "-----------------------------------------------"
    green "1. VLESS + WS（port 80）"
    green "2. VLESS + HTTPUpgrade（port 80）"
    green "3. 不启用（默认）"
    printf '%s\n' "-----------------------------------------------"

    prompt "请输入选择(1-3，回车默认3): " ff_choice
    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws" ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none" ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        prompt "请输入 FreeFlow path（回车默认 /）: " ff_path_input
        FF_PATH=$(normalize_path "${ff_path_input}")
    else
        FF_PATH="/"
    fi

    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"

    case "${FREEFLOW_MODE}" in
        ws) green "已选择 VLESS+WS (path=${FF_PATH})" ;;
        httpupgrade) green "已选择 VLESS+HTTPUpgrade (path=${FF_PATH})" ;;
        none) yellow "已关闭 FreeFlow" ;;
    esac
    echo ""
}

apply_freeflow_config() {
    ensure_dns_routing || return 1
    local cur_uuid
    cur_uuid=$(get_current_uuid)

    update_config 'del(.inbounds[]? | select(.tag=="ff-in"))' || return 1
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        local ff_json
        ff_json='{"tag":"ff-in","port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"'"${cur_uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"'"${FREEFLOW_MODE}"'","security":"none","'"${FREEFLOW_MODE}"'Settings":{"path":"'"${FF_PATH}"'"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}'
        update_config --argjson ib "${ff_json}" '.inbounds += [$ib]' || return 1
    fi
}

manage_freeflow() {
    while true; do
        cls
        local ff_display="\033[1;91m未配置\033[0m"
        if [ "${FREEFLOW_MODE}" != "none" ]; then
            local mode_show="${FREEFLOW_MODE^^}"
            [ "$mode_show" = "HTTPUPGRADE" ] && mode_show="HTTP+"
            ff_display="\033[1;32m方式: ${mode_show} (path=${FF_PATH})\033[0m"
        fi

        printf "\033[1;32m管理 FreeFlow：\033[0m\n  当前: %b\n" "$ff_display"
        printf '%s\n' "-----------------------------------------------"
        printf "\033[1;32m 1.\033[0m 切换方式   \033[1;32m 2.\033[0m 修改路径\n"
        printf "\033[1;91m 3.\033[0m 卸载模块   \033[1;35m 0.\033[0m 返回\n"
        printf '%s\n' "==============================================="

        prompt "请输入选择: " c
        case "$c" in
            1)
                cls
                ask_freeflow_mode
                apply_freeflow_config
                manage_service restart xray
                green "已更新 FreeFlow"
                pause
                ;;
            2)
                [ "${FREEFLOW_MODE}" = "none" ] && { red "请先启用 FreeFlow"; pause; continue; }
                prompt "新 path（回车保持 ${FF_PATH}）: " np
                if [ -n "$np" ]; then
                    FF_PATH=$(normalize_path "$np")
                    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
                    apply_freeflow_config
                    manage_service restart xray
                    green "路径已更新: ${FF_PATH}"
                fi
                pause
                ;;
            3)
                FREEFLOW_MODE="none"
                printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
                apply_freeflow_config
                manage_service restart xray
                green "已卸载 FreeFlow"
                pause
                ;;
            0) return ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

# =========================
# socks5
# =========================
manage_socks5() {
    while true; do
        cls
        ensure_dns_routing || { red "配置初始化失败"; pause; return; }

        local socks_list
        socks_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$config_dir" 2>/dev/null)

        cls
        printf '\033[1;35m                 管理 Socks5 代理              \033[0m\n'
        if [ -z "$socks_list" ]; then
            printf '  当前: \033[1;91m未配置\033[0m\n'
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
            done <<<"$socks_list"
        fi

        echo "-----------------------------------------------"
        printf "\033[1;32m 1.\033[0m 添加  \033[1;32m 2.\033[0m 修改\n"
        printf "\033[1;91m 3.\033[0m 删除  \033[1;35m 0.\033[0m 返回\n"
        echo "==============================================="

        prompt "请输入选择: " s
        case "$s" in
            1)
                cls; install_core
                prompt "端口(如1080): " ns_port
                prompt "用户名: " ns_user
                prompt "密码: " ns_pass
                if [[ -n "$ns_port" && "$ns_port" =~ ^[0-9]+$ && -n "$ns_user" && -n "$ns_pass" ]]; then
                    local exist
                    exist=$(jq --argjson p "$ns_port" '[.inbounds[]? | select(.port==$p)] | length' "$config_dir")
                    if [ "$exist" -gt 0 ]; then
                        red "端口已存在，请换一个"
                    else
                        update_config --argjson p "$ns_port" --arg u "$ns_user" --arg pw "$ns_pass" \
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
                prompt "要修改的端口: " ep
                prompt "新用户名: " nu
                prompt "新密码: " np
                if [[ -n "$ep" && "$ep" =~ ^[0-9]+$ && -n "$nu" && -n "$np" ]]; then
                    update_config --argjson p "$ep" --arg u "$nu" --arg pw "$np" \
                        '(.inbounds[]? | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user":$u,"pass":$pw}'
                    manage_service restart xray
                    green "修改完成"
                else
                    red "输入无效"
                fi
                pause
                ;;
            3)
                local s_list i
                s_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$config_dir" 2>/dev/null)
                [ -z "$s_list" ] && { red "无可删项"; pause; continue; }
                i=1
                local ports=()
                echo "请选择删除端口："
                echo "-----------------------------------------------"
                while read -r line; do
                    local p
                    p=$(echo "$line" | jq -r '.port')
                    echo "  ${i}. 端口 ${p}"
                    ports[$i]="$p"
                    i=$((i+1))
                done <<<"$s_list"
                echo "  0. 取消"
                echo "-----------------------------------------------"
                prompt "序号(0-$((i-1))): " di
                if [[ "$di" =~ ^[0-9]+$ ]] && [ "$di" -gt 0 ] && [ "$di" -lt "$i" ]; then
                    local delp="${ports[$di]}"
                    update_config --argjson p "$delp" 'del(.inbounds[]? | select(.protocol=="socks" and .port==$p))'
                    manage_service restart xray
                    green "已删除端口 ${delp}"
                fi
                pause
                ;;
            0) break ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

# =========================
# Reality (xray native)
# =========================
load_reality_conf() {
    if [ -f "$reality_conf" ]; then
        IFS='|' read -r REALITY_PORT REALITY_SNI REALITY_DEST REALITY_PRIV REALITY_PUB REALITY_SID < "$reality_conf"
    fi
}
save_reality_conf() {
    printf '%s|%s|%s|%s|%s|%s\n' \
        "${REALITY_PORT}" "${REALITY_SNI}" "${REALITY_DEST}" "${REALITY_PRIV}" "${REALITY_PUB}" "${REALITY_SID}" > "$reality_conf"
}
detect_reality_servername() {
    local arr=(
        "addons.mozilla.org"
        "download-installer.cdn.mozilla.net"
        "www.python.org"
        "dl.google.com"
        "www.google-analytics.com"
        "www.java.com"
        "github.io"
    )
    local n=${#arr[@]}
    echo "${arr[$((RANDOM % n))]}"
}
gen_x25519() {
    local out priv pub
    out=$("${work_dir}/xray" x25519 2>/dev/null)
    priv=$(echo "$out" | awk '/Private key/ {print $3}')
    pub=$(echo "$out" | awk '/Public key/ {print $3}')
    [ -n "$priv" ] && [ -n "$pub" ] && { echo "$priv|$pub"; return 0; }
    return 1
}

apply_reality_config() {
    ensure_dns_routing || return 1
    install_core

    local cur_uuid
    cur_uuid=$(get_current_uuid)

    update_config 'del(.inbounds[]? | select(.tag=="reality-vless"))' || return 1

    local reality_json
    reality_json=$(jq -nc \
        --arg uuid "$cur_uuid" \
        --arg sni "$REALITY_SNI" \
        --arg priv "$REALITY_PRIV" \
        --arg pub "$REALITY_PUB" \
        --arg sid "$REALITY_SID" \
        --arg dest "$REALITY_DEST" \
        --argjson p "$REALITY_PORT" \
'{
  "tag":"reality-vless",
  "listen":"::",
  "port":$p,
  "protocol":"vless",
  "settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{
    "network":"tcp",
    "security":"reality",
    "realitySettings":{
      "show":false,
      "target":$dest,
      "xver":0,
      "serverNames":[$sni],
      "privateKey":$priv,
      "publicKey":$pub,
      "maxTimeDiff":70000,
      "shortIds":["",$sid]
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
}')
    update_config --argjson ib "$reality_json" '.inbounds += [$ib]' || return 1

    save_reality_conf
    manage_service restart xray
}

manage_reality() {
    load_reality_conf

    while true; do
        cls
        echo -e "\033[1;36m=============== VLESS Reality 管理 ===============\033[0m"
        if [ -n "$REALITY_PORT" ]; then
            echo -e "状态: \033[1;32m已配置\033[0m 端口=${REALITY_PORT} SNI=${REALITY_SNI} target=${REALITY_DEST}"
        else
            echo -e "状态: \033[1;91m未配置\033[0m"
        fi
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 安装/重装 Reality"
        echo -e "\033[1;32m 2.\033[0m 修改端口/SNI"
        echo -e "\033[1;91m 3.\033[0m 卸载 Reality"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="

        prompt "请输入选择 [0-3]: " r
        case "$r" in
            1)
                install_core
                prompt "Reality 端口(回车随机10000-30000): " rp
                [ -z "$rp" ] && rp=$((RANDOM % 20001 + 10000))
                [[ "$rp" =~ ^[0-9]+$ ]] || { red "端口无效"; pause; continue; }

                prompt "SNI(回车随机): " rsni
                [ -z "$rsni" ] && rsni=$(detect_reality_servername)

                prompt "target(回车默认 SNI:443): " rdest
                [ -z "$rdest" ] && rdest="${rsni}:443"

                local kp
                kp=$(gen_x25519) || { red "生成 x25519 失败"; pause; continue; }
                REALITY_PRIV="${kp%%|*}"
                REALITY_PUB="${kp##*|}"
                REALITY_SID="6ba85179e30d4fc2"
                REALITY_PORT="$rp"
                REALITY_SNI="$rsni"
                REALITY_DEST="$rdest"

                apply_reality_config && green "Reality 配置完成"
                pause
                ;;
            2)
                [ -z "$REALITY_PORT" ] && { red "请先安装 Reality"; pause; continue; }
                prompt "新端口(回车保持 ${REALITY_PORT}): " nrp
                prompt "新SNI(回车保持 ${REALITY_SNI}): " nrsni
                prompt "新target(回车保持 ${REALITY_DEST}): " nrdest
                [ -n "$nrp" ] && REALITY_PORT="$nrp"
                [ -n "$nrsni" ] && REALITY_SNI="$nrsni"
                [ -n "$nrdest" ] && REALITY_DEST="$nrdest"
                apply_reality_config && green "Reality 已更新"
                pause
                ;;
            3)
                update_config 'del(.inbounds[]? | select(.tag=="reality-vless"))'
                rm -f "$reality_conf"
                REALITY_PORT=""
                REALITY_SNI=""
                REALITY_DEST=""
                REALITY_PRIV=""
                REALITY_PUB=""
                REALITY_SID=""
                manage_service restart xray
                green "Reality 已卸载"
                pause
                ;;
            0) return ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

# =========================
# Tuic via sing-box (DNS ipv4-only optimized)
# =========================
load_tuic_conf() {
    if [ -f "$tuic_conf" ]; then
        IFS='|' read -r TUIC_PORT TUIC_CONGESTION < "$tuic_conf"
    fi
}
save_tuic_conf() {
    printf '%s|%s\n' "${TUIC_PORT}" "${TUIC_CONGESTION}" > "$tuic_conf"
}

install_singbox_for_tuic() {
    if [ -f "${work_dir}/sing-box" ]; then return 0; fi

    local arch url ver tarf
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="-linux-amd64" ;;
        aarch64|arm64) arch="-linux-arm64" ;;
        *) red "当前架构不支持自动安装 sing-box: $arch"; return 1 ;;
    esac

    ver=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')
    [ -z "$ver" ] && { red "获取 sing-box 版本失败"; return 1; }

    tarf="${work_dir}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}${arch}.tar.gz"
    smart_download "$tarf" "$url" 5000000
    tar -xzf "$tarf" -C "$work_dir" >/dev/null 2>&1 || return 1
    mv "${work_dir}/sing-box-${ver#v}${arch}/sing-box" "${work_dir}/sing-box" 2>/dev/null || true
    rm -rf "$tarf" "${work_dir}/sing-box-${ver#v}${arch}"
    chmod +x "${work_dir}/sing-box"
}

apply_tuic_config() {
    install_core
    install_singbox_for_tuic || return 1
    mkdir -p "${work_dir}/singbox-conf"

    local cur_uuid domain cert key tlsok
    cur_uuid=$(get_current_uuid)

    if [ -f "${work_dir}/domain_argo.txt" ]; then
        domain=$(cat "${work_dir}/domain_argo.txt" 2>/dev/null)
    fi
    [ -z "$domain" ] && domain="localhost"

    cert="/etc/v2ray-agent/tls/${domain}.crt"
    key="/etc/v2ray-agent/tls/${domain}.key"

    tlsok=1
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        mkdir -p /etc/v2ray-agent/tls
        cert="/etc/v2ray-agent/tls/selfsigned.crt"
        key="/etc/v2ray-agent/tls/selfsigned.key"
        if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$cert" -days 3650 -subj "/CN=${domain}" >/dev/null 2>&1 || tlsok=0
        fi
    fi
    [ "$tlsok" -eq 0 ] && { red "证书准备失败"; return 1; }

    [ -z "$TUIC_CONGESTION" ] && TUIC_CONGESTION="bbr"
    [ -z "$TUIC_PORT" ] && TUIC_PORT=18443

    # sing-box DNS 只v4出口优化版
    # - strategy: ipv4_only
    # - 两个IPv4 DNS服务器
    # - 缓存容量 / optimistic / timeout
    # - direct outbound 强制 ipv4_only
    cat >"${work_dir}/singbox-conf/tuic.json" <<EOF
{
  "log": { "disabled": true },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "dns-1", "server": "1.1.1.1", "server_port": 53 },
      { "type": "udp", "tag": "dns-2", "server": "8.8.8.8", "server_port": 53 }
    ],
    "final": "dns-1",
    "strategy": "ipv4_only",
    "cache_capacity": 4096,
    "optimistic": {
      "enabled": true,
      "timeout": "3d"
    },
    "timeout": "3s",
    "reverse_mapping": false
  },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "tag": "tuic-in",
      "users": [
        {
          "uuid": "${cur_uuid}",
          "password": "${cur_uuid}",
          "name": "tuic-user"
        }
      ],
      "congestion_control": "${TUIC_CONGESTION}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": ["h3"],
        "certificate_path": "${cert}",
        "key_path": "${key}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "ipv4_only" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

    if [ -f /etc/alpine-release ]; then
        cat >/etc/init.d/tuic-box <<EOF
#!/sbin/openrc-run
description="Tuic by sing-box"
command="${work_dir}/sing-box"
command_args="run -c ${work_dir}/singbox-conf/tuic.json"
command_background=true
pidfile="/var/run/tuic-box.pid"
EOF
        chmod +x /etc/init.d/tuic-box
    else
        cat >/etc/systemd/system/tuic-box.service <<EOF
[Unit]
Description=Tuic by sing-box
After=network.target
[Service]
ExecStart=${work_dir}/sing-box run -c ${work_dir}/singbox-conf/tuic.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    fi

    manage_service enable tuic-box
    manage_service restart tuic-box
    save_tuic_conf
}

manage_tuic() {
    load_tuic_conf

    while true; do
        cls
        echo -e "\033[1;36m================= Tuic 管理 =================\033[0m"
        if [ -n "$TUIC_PORT" ]; then
            echo -e "状态: \033[1;32m已配置\033[0m 端口=${TUIC_PORT} 拥塞=${TUIC_CONGESTION:-bbr}"
            echo -e "DNS: \033[1;36mIPv4 Only + Cache + Optimistic\033[0m"
        else
            echo -e "状态: \033[1;91m未配置\033[0m"
        fi
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 安装/重装 Tuic"
        echo -e "\033[1;32m 2.\033[0m 修改端口/拥塞算法"
        echo -e "\033[1;91m 3.\033[0m 卸载 Tuic"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="

        prompt "请输入选择 [0-3]: " t
        case "$t" in
            1)
                prompt "Tuic 端口(回车默认 18443): " tp
                [ -z "$tp" ] && tp=18443
                [[ "$tp" =~ ^[0-9]+$ ]] || { red "端口无效"; pause; continue; }

                echo "拥塞算法：1)bbr 2)cubic 3)new_reno"
                prompt "请输入(1-3，默认1): " tc
                case "$tc" in
                    2) TUIC_CONGESTION="cubic" ;;
                    3) TUIC_CONGESTION="new_reno" ;;
                    *) TUIC_CONGESTION="bbr" ;;
                esac
                TUIC_PORT="$tp"

                apply_tuic_config && green "Tuic 配置完成"
                pause
                ;;
            2)
                [ -z "$TUIC_PORT" ] && { red "请先安装 Tuic"; pause; continue; }
                prompt "新端口(回车保持 ${TUIC_PORT}): " ntp
                echo "拥塞算法：1)bbr 2)cubic 3)new_reno"
                prompt "输入(回车保持 ${TUIC_CONGESTION:-bbr}): " ntc

                [ -n "$ntp" ] && TUIC_PORT="$ntp"
                case "$ntc" in
                    1) TUIC_CONGESTION="bbr" ;;
                    2) TUIC_CONGESTION="cubic" ;;
                    3) TUIC_CONGESTION="new_reno" ;;
                    *) ;;
                esac
                apply_tuic_config && green "Tuic 已更新"
                pause
                ;;
            3)
                manage_service stop tuic-box 2>/dev/null
                manage_service disable tuic-box 2>/dev/null
                rm -f /etc/systemd/system/tuic-box.service /etc/init.d/tuic-box
                rm -f "${work_dir}/singbox-conf/tuic.json"
                rm -f "${tuic_conf}"
                TUIC_PORT=""
                TUIC_CONGESTION=""
                green "Tuic 已卸载"
                pause
                ;;
            0) return ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

# =========================
# argo
# =========================
install_argo_multiplex() {
    cls
    install_core

    if [ ! -f "${work_dir}/argo" ]; then
        echo ""
        purple "=== 部署 Cloudflared ==="
        local arch
        arch=$(detect_cloudflared_arch)
        [ -z "$arch" ] && { red "不支持架构"; return 1; }
        local argo_url
        argo_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
        smart_download "${work_dir}/argo" "${argo_url}" 15000000
        chmod +x "${work_dir}/argo"
    fi

    ensure_dns_routing || return 1

    echo ""
    yellow "配置 Argo 路径分流 (WS + XHTTP + SS)"
    skyblue "  => VLESS+WS:   8080 /argo"
    skyblue "  => VLESS+XHTTP:8081 /xgo"
    skyblue "  => SS+WS:      8082 /ssgo"
    echo ""

    prompt "请输入 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 1; }

    prompt "请输入 Argo JSON 凭证: " argo_auth
    [ -z "$argo_auth" ] && { red "凭证不能为空"; return 1; }
    echo "$argo_auth" | grep -q "TunnelSecret" || { red "必须是 JSON 凭证"; return 1; }

    prompt "SS 密码(回车随机): " ss_pass
    [ -z "$ss_pass" ] && ss_pass=$(generate_uuid | cut -c1-8)

    echo "SS 加密: 1.aes-128-gcm(默认) 2.aes-256-gcm"
    prompt "请输入(1-2): " mc
    local ss_method="aes-128-gcm"
    [ "$mc" = "2" ] && ss_method="aes-256-gcm"

    echo "$argo_domain" > "${work_dir}/domain_argo.txt"
    local tunnel_id
    tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID' 2>/dev/null || echo "$argo_auth" | cut -d'"' -f12)
    echo "$argo_auth" > "${work_dir}/tunnel_argo.json"

    cat > "${work_dir}/tunnel_argo.yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel_argo.json
protocol: http2
ingress:
  - hostname: ${argo_domain}
    path: /argo
    service: http://localhost:8080
    originRequest:
      noTLSVerify: true
  - hostname: ${argo_domain}
    path: /xgo
    service: http://localhost:8081
    originRequest:
      noTLSVerify: true
  - hostname: ${argo_domain}
    path: /ssgo
    service: http://localhost:8082
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

    local cur_uuid
    cur_uuid=$(get_current_uuid)

    update_config 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))' || return 1

    local ws_json
    ws_json='{"port":8080,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"'"${cur_uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'

    local xhttp_json
    xhttp_json=$(jq -nc \
        --arg uuid "$cur_uuid" \
        --arg mode "$XHTTP_MODE" \
        --argjson extra "$XHTTP_EXTRA_JSON" \
        '{"port":8081,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')

    local ss_json
    ss_json='{"port":8082,"listen":"127.0.0.1","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'

    update_config --argjson ws "$ws_json" --argjson xhttp "$xhttp_json" --argjson ss "$ss_json" '.inbounds += [$ws,$xhttp,$ss]' || return 1

    local exec_cmd svc_name
    exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --config ${work_dir}/tunnel_argo.yml run"
    svc_name="tunnel-argo"

    if [ -f /etc/alpine-release ]; then
        cat > "${work_dir}/argo_start.sh" <<EOF
#!/bin/sh
exec ${exec_cmd}
EOF
        chmod +x "${work_dir}/argo_start.sh"
        cat > /etc/init.d/${svc_name} <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel Multiplex"
command="${work_dir}/argo_start.sh"
command_background=true
pidfile="/var/run/${svc_name}.pid"
output_log="${work_dir}/argo_dual.log"
error_log="${work_dir}/argo_dual.log"
EOF
        chmod +x /etc/init.d/${svc_name}
    else
        cat > /etc/systemd/system/${svc_name}.service <<EOF
[Unit]
Description=Cloudflare Tunnel Multiplex
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${exec_cmd}
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    fi
    manage_service enable "${svc_name}"
    manage_service restart "${svc_name}"
    manage_service restart xray

    green "Argo(WS+XHTTP+SS) 部署完成"
}

# =========================
# node links
# =========================
get_info() {
    cls
    check_system_ip
    load_reality_conf
    load_tuic_conf

    local IP=""
    [ -n "$WAN4" ] && IP="$WAN4" || { [ -n "$WAN6" ] && IP="$WAN6"; }

    local cur_uuid
    cur_uuid=$(get_current_uuid)
    local node_count=0

    echo ""
    green "=============== 当前可用节点链接 =============="

    if [ -f "${work_dir}/domain_argo.txt" ]; then
        local domain_argo
        domain_argo=$(cat "${work_dir}/domain_argo.txt")

        local name_xhttp="${NODE_PREFIX} - XHTTP"
        local xhttp_extra_uri
        xhttp_extra_uri=$(url_encode "$XHTTP_EXTRA_JSON")
        local link_xhttp
        link_xhttp="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&alpn=h2&fp=chrome&type=xhttp&host=${domain_argo}&path=%2Fxgo&mode=${XHTTP_MODE}&extra=${xhttp_extra_uri}#$(url_encode "$name_xhttp")"
        purple "${link_xhttp}"; echo ""; node_count=$((node_count+1))

        local name_ws="${NODE_PREFIX} - WS"
        local link_ws
        link_ws="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&fp=chrome&type=ws&host=${domain_argo}&path=%2Fargo%3Fed%3D2560#$(url_encode "$name_ws")"
        purple "${link_ws}"; echo ""; node_count=$((node_count+1))

        local ss_ib
        ss_ib=$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8082)' "$config_dir" 2>/dev/null)
        if [ -n "$ss_ib" ]; then
            local m pw b64 name_ss link_ss
            m=$(echo "$ss_ib" | jq -r '.settings.method')
            pw=$(echo "$ss_ib" | jq -r '.settings.password')
            name_ss="${NODE_PREFIX} - SS"
            b64=$(echo -n "${m}:${pw}" | base64 | tr -d '\n')
            link_ss="ss://${b64}@${CFIP}:80?type=ws&security=none&host=${domain_argo}&path=%2Fssgo#$(url_encode "$name_ss")"
            purple "$link_ss"; echo ""; node_count=$((node_count+1))
        fi
    fi

    if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ]; then
        local penc ff_name link_ff
        penc=$(url_encode "${FF_PATH}")
        ff_name="${FREEFLOW_MODE^^}"
        [ "$ff_name" = "HTTPUPGRADE" ] && ff_name="HTTP+"
        link_ff="vless://${cur_uuid}@${IP}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${IP}&path=${penc}#$(url_encode "${NODE_PREFIX} - FF-${ff_name}")"
        purple "$link_ff"; echo ""; node_count=$((node_count+1))
    fi

    if [ -f "${config_dir}" ] && [ -n "$IP" ]; then
        local socks_list
        socks_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$config_dir" 2>/dev/null)
        if [ -n "$socks_list" ]; then
            while read -r line; do
                local p u pw link
                p=$(echo "$line" | jq -r '.port')
                u=$(echo "$line" | jq -r '.settings.accounts[0].user')
                pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                link="socks5://${u}:${pw}@${IP}:${p}#$(url_encode "${NODE_PREFIX} - Socks5-${p}")"
                purple "$link"; echo ""; node_count=$((node_count+1))
            done <<<"$socks_list"
        fi
    fi

    if [ -n "$REALITY_PORT" ] && [ -n "$REALITY_SNI" ] && [ -n "$REALITY_PUB" ]; then
        local rip
        [ -n "$WAN4" ] && rip="$WAN4" || rip="$WAN6"
        if [ -n "$rip" ]; then
            local reality_name reality_link
            reality_name="${NODE_PREFIX} - Reality-Vision"
            reality_link="vless://${cur_uuid}@${rip}:${REALITY_PORT}?encryption=none&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID:-6ba85179e30d4fc2}&flow=xtls-rprx-vision#$(url_encode "$reality_name")"
            purple "$reality_link"; echo ""; node_count=$((node_count+1))
        fi
    fi

    if [ -n "$TUIC_PORT" ]; then
        local tip
        [ -n "$WAN4" ] && tip="$WAN4" || tip="$WAN6"
        if [ -n "$tip" ]; then
            local tuic_name tuic_link
            tuic_name="${NODE_PREFIX} - Tuic"
            tuic_link="tuic://${cur_uuid}:${cur_uuid}@${tip}:${TUIC_PORT}?congestion_control=${TUIC_CONGESTION:-bbr}&alpn=h3&sni=${tip}&udp_relay_mode=quic&allow_insecure=1#$(url_encode "$tuic_name")"
            purple "$tuic_link"; echo ""; node_count=$((node_count+1))
        fi
    fi

    [ "$node_count" -eq 0 ] && yellow "当前没有任何节点配置。"
    echo "==============================================="
}

# =========================
# restart (hour based)
# =========================
manage_restart() {
    cls
    green "服务自动重启间隔：当前 ${RESTART_HOURS} 小时 (0=关闭)"
    prompt "请输入间隔小时（0关闭，1/2/3...）: " nh

    if ! [[ "$nh" =~ ^[0-9]+$ ]]; then
        red "输入无效，请输入纯数字"
        return
    fi

    RESTART_HOURS="$nh"
    echo "${RESTART_HOURS}" > "${restart_conf}"

    if [ "${RESTART_HOURS}" -eq 0 ]; then
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab - 2>/dev/null
        fi
        green "定时重启已关闭"
        return
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            manage_packages cron
            manage_service enable cron
            manage_service start cron
        elif command -v apk >/dev/null 2>&1; then
            manage_packages dcron
            rc-service dcron start 2>/dev/null || true
            rc-update add dcron default >/dev/null 2>&1 || true
        else
            manage_packages cronie
            manage_service enable crond
            manage_service start crond
        fi
    fi

    local restart_cmd
    restart_cmd="systemctl restart xray tunnel-argo tuic-box"
    [ -f /etc/alpine-release ] && restart_cmd="rc-service xray restart; rc-service tunnel-argo restart; rc-service tuic-box restart"

    local cron_exp
    cron_exp="0 */${RESTART_HOURS} * * *"
    (crontab -l 2>/dev/null | sed '/#svc-restart/d'; echo "${cron_exp} ${restart_cmd} >/dev/null 2>&1 #svc-restart") | crontab -

    green "重启策略已更新：每 ${RESTART_HOURS} 小时"
}

# =========================
# swap
# =========================
swap_log() { echo "[$(date '+%F %T')] $*" >> "${swap_log_file}"; }

swap_cleanup_entries() { [ -f /etc/fstab ] && sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab; }

swap_disable_all() {
    awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | while read -r dev; do
        [ -n "$dev" ] && swapoff "$dev" >/dev/null 2>&1 || true
    done
    [ -f /swapfile ] && rm -f /swapfile
    swap_cleanup_entries
    if [ -d /sys/class/zram-control ] || [ -e /dev/zram0 ]; then
        for z in /sys/block/zram*; do
            [ -d "$z" ] || continue
            echo 1 > "$z/reset" 2>/dev/null || true
        done
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
    local size_mb="$1" zdev="" zname=""
    if [ -e /dev/zram0 ]; then
        zdev="/dev/zram0"
    elif [ -w /sys/class/zram-control/hot_add ]; then
        local zid
        zid=$(cat /sys/class/zram-control/hot_add 2>/dev/null)
        [ -n "$zid" ] && zdev="/dev/zram${zid}"
    fi
    [ -z "$zdev" ] && return 1
    zname="${zdev#/dev/}"
    echo 1 > "/sys/block/${zname}/reset" 2>/dev/null || true
    [ -w "/sys/block/${zname}/comp_algorithm" ] && echo lz4 > "/sys/block/${zname}/comp_algorithm" 2>/dev/null || true
    echo "$((size_mb * 1024 * 1024))" > "/sys/block/${zname}/disksize" 2>/dev/null || return 1
    mkswap "${zdev}" >/dev/null 2>&1 || return 1
    swapon "${zdev}" >/tmp/swapon_err.log 2>&1 || return 1
    return 0
}

create_swapfile_dd() {
    local size_mb="$1"
    dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none 2>/tmp/dd_err.log || return 10
    chmod 600 /swapfile || return 11
    mkswap /swapfile >/dev/null 2>&1 || return 12
    swapon /swapfile >/tmp/swapon_err.log 2>&1 || return 13
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    return 0
}

create_swapfile_fallocate() {
    local size_mb="$1"
    command -v fallocate >/dev/null 2>&1 || return 20
    fallocate -l "${size_mb}M" /swapfile 2>/tmp/fallocate_err.log || return 21
    chmod 600 /swapfile || return 22
    mkswap -f /swapfile >/dev/null 2>&1 || return 23
    swapon /swapfile >/tmp/swapon_err.log 2>&1 || return 24
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    return 0
}

swap_dd_should_short_circuit() {
    local combined=""
    [ -f /tmp/dd_err.log ] && combined="${combined} $(cat /tmp/dd_err.log)"
    [ -f /tmp/swapon_err.log ] && combined="${combined} $(cat /tmp/swapon_err.log)"
    echo "$combined" | grep -qiE 'Operation not permitted|No space left on device|Read-only file system|Permission denied'
}

create_swap_best_effort() {
    local size_mb="${1:-256}"

    : > "${swap_log_file}"
    rm -f /tmp/dd_err.log /tmp/fallocate_err.log /tmp/swapon_err.log

    swap_disable_all
    swap_log "start swap setup size=${size_mb}MB"

    if zram_supported; then
        yellow "优先尝试 zram..."
        if create_zram_swap "$size_mb"; then
            green "SWAP 启用成功（ZRAM ${size_mb}MB）"
            return 0
        fi
        yellow "zram 失败，回退 swapfile"
    fi

    yellow "尝试 dd swapfile..."
    if create_swapfile_dd "$size_mb"; then
        green "SWAP 启用成功（dd ${size_mb}MB）"
        return 0
    fi

    if swap_dd_should_short_circuit; then
        red "dd 失败且属于权限/空间/只读问题，停止进一步尝试。"
        return 1
    fi

    yellow "尝试 fallocate swapfile..."
    rm -f /swapfile /tmp/swapon_err.log
    if create_swapfile_fallocate "$size_mb"; then
        green "SWAP 启用成功（fallocate ${size_mb}MB）"
        return 0
    fi

    local err
    err="$(cat /tmp/fallocate_err.log 2>/dev/null) $(cat /tmp/swapon_err.log 2>/dev/null)"
    red "SWAP 启用失败：${err:-未知错误}"
    return 1
}

manage_swap() {
    while true; do
        cls
        local ram swap
        ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
        swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
        [ -z "$ram" ] && ram=0
        [ -z "$swap" ] && swap=0

        echo -e "\033[1;36m=============== SWAP 管理 ===============\033[0m"
        echo "RAM: ${ram} MB"
        if [ "$swap" -gt 0 ]; then
            echo -e "SWAP: \033[1;32m${swap} MB (已开启)\033[0m"
        else
            echo -e "SWAP: \033[1;91m0 MB (未开启)\033[0m"
        fi
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 添加/修改 SWAP"
        echo -e "\033[1;91m 2.\033[0m 关闭并清理 SWAP"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="

        prompt "请输入选择 [0-2]: " op
        case "$op" in
            1)
                prompt "SWAP大小MB（默认256）: " sz
                sz=${sz:-256}
                if [[ "$sz" =~ ^[0-9]+$ ]] && [ "$sz" -gt 0 ]; then
                    yellow "正在配置 ${sz}MB SWAP..."
                    create_swap_best_effort "$sz" && green "配置完成" || red "配置失败，日志：${swap_log_file}"
                else
                    red "输入无效"
                fi
                pause
                ;;
            2)
                yellow "正在关闭 SWAP..."
                swap_disable_all
                green "已清理"
                pause
                ;;
            0) return ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

# =========================
# uninstall
# =========================
uninstall_component() {
    local target="$1"

    if [ "$target" = "argo" ]; then
        manage_service stop tunnel-argo 2>/dev/null
        manage_service disable tunnel-argo 2>/dev/null
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
        rm -f "${work_dir}/domain_argo.txt" "${work_dir}/tunnel_argo.yml" "${work_dir}/tunnel_argo.json" "${work_dir}/argo_start.sh" "${work_dir}/argo_dual.log"
        [ -f "${config_dir}" ] && update_config 'del(.inbounds[]? | select(.port==8080 or .port==8081 or .port==8082))'
        manage_service restart xray
        green "Argo 已卸载"
    fi

    if [ "$target" = "all" ]; then
        manage_service stop tunnel-argo 2>/dev/null
        manage_service disable tunnel-argo 2>/dev/null
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service

        manage_service stop tuic-box 2>/dev/null
        manage_service disable tuic-box 2>/dev/null
        rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service

        manage_service stop xray 2>/dev/null
        manage_service disable xray 2>/dev/null
        rm -f /etc/init.d/xray /etc/systemd/system/xray.service

        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab -
        fi

        swap_disable_all >/dev/null 2>&1 || true
        rm -rf "${work_dir}"
        green "全部组件已卸载"
        exit 0
    fi
}

# =========================
# modify uuid (不校验)
# =========================
modify_uuid() {
    prompt "输入新 UUID (回车自动生成): " new_uuid
    [ -z "$new_uuid" ] && new_uuid=$(generate_uuid)

    if [ -f "${config_dir}" ]; then
        update_config --arg uuid "$new_uuid" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'

        if [ -f "${work_dir}/singbox-conf/tuic.json" ]; then
            jq --arg u "$new_uuid" '.inbounds[0].users[0].uuid=$u | .inbounds[0].users[0].password=$u' \
                "${work_dir}/singbox-conf/tuic.json" > "${work_dir}/singbox-conf/tuic.json.tmp" \
                && mv "${work_dir}/singbox-conf/tuic.json.tmp" "${work_dir}/singbox-conf/tuic.json"
            manage_service restart tuic-box
        fi

        manage_service restart xray
        green "UUID 已修改: ${new_uuid}"
        get_info
    else
        yellow "配置不存在，请先安装节点"
    fi
}

# =========================
# shortcut
# =========================
install_shortcut() {
    yellow "正在创建快捷方式..."
    local dest="/usr/local/bin/ssgo"
    cat > "$dest" <<'EOF'
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/KisThFir/Xray-ssgo/refs/heads/main/Xray_ssgo.sh) "$@"
EOF
    chmod +x "$dest"
    ln -sf "$dest" /usr/bin/ssgo 2>/dev/null || true
    hash -r 2>/dev/null || true
    green "快捷方式已创建：ssgo"
}

maybe_offer_shortcut() {
    [ -x /usr/local/bin/ssgo ] || [ -x /usr/bin/ssgo ] && return
    prompt "是否创建 ssgo 快捷命令？[Y/n]: " mk
    case "$mk" in
        n|N) yellow "已跳过" ;;
        *) install_shortcut ;;
    esac
}

# =========================
# main menu
# =========================
trap 'echo ""; cls; red "已中断"; exit 130' INT TERM

menu() {
    cls
    printf '\033[1;33m初始化系统信息与网络检测...\033[0m\n'
    manage_packages jq wget iproute2 coreutils tar unzip openssl >/dev/null 2>&1
    get_sys_info
    check_system_ip

    while true; do
        cls
        local x_stat argo_stat tuic_stat
        x_stat=$(check_status "xray" "${work_dir}/${server_name}" "${work_dir}/xray")
        argo_stat=$(check_status "tunnel-argo" "${work_dir}/argo" "${work_dir}/argo tunnel")
        tuic_stat=$(check_status "tuic-box" "${work_dir}/sing-box" "${work_dir}/sing-box run")

        [ ! -f "${work_dir}/domain_argo.txt" ] && argo_stat="\033[1;91m未配置\033[0m"
        [ ! -f "${work_dir}/singbox-conf/tuic.json" ] && tuic_stat="\033[1;91m未配置\033[0m"

        local len4 len6 pad_len ip4_disp ip6_disp
        len4=${#WAN4}; len6=${#WAN6}; pad_len=$(( len4 > len6 ? len4 : len6 ))
        [ -z "$pad_len" ] && pad_len=0

        ip4_disp="\033[1;91m未检出\033[0m"
        if [ -n "$WAN4" ]; then
            local p4
            p4=$(printf "%-${pad_len}s" "$WAN4")
            ip4_disp="\033[1;36m${p4}  (${COUNTRY4} ${AS_NUM4} ${ISP_CLEAN4})\033[0m"
        fi

        ip6_disp="\033[1;91m未检出\033[0m"
        if [ -n "$WAN6" ]; then
            local p6
            p6=$(printf "%-${pad_len}s" "$WAN6")
            ip6_disp="\033[1;36m${p6}  (${COUNTRY6} ${AS_NUM6} ${ISP_CLEAN6})\033[0m"
        fi

        local menu_text
        menu_text="OS: \033[1;36m${SYS_INFO_CACHE}\033[0m
v4: ${ip4_disp}
v6: ${ip6_disp}
-----------------------------------------------
  Xray: ${x_stat}
  Argo: ${argo_stat}
  Tuic: ${tuic_stat}
-----------------------------------------------
\033[1;32m 1.\033[0m 安装\033[1;36mArgo\033[0m      \033[1;91m 2.\033[0m 卸载\033[1;36mArgo\033[0m
\033[1;32m 3.\033[0m 管理\033[1;33mSocks5\033[0m    \033[1;32m 4.\033[0m 管理\033[1;33mFreeFlow\033[0m
\033[1;32m 5.\033[0m 查看\033[1;36m节点\033[0m      \033[1;32m 6.\033[0m 修改\033[1;36mUUID\033[0m
\033[1;32m 7.\033[0m 定时\033[1;33m重启(小时)\033[0m \033[1;32m 8.\033[0m 管理\033[1;36mSWAP\033[0m
\033[1;32m 9.\033[0m 管理\033[1;36mReality\033[0m   \033[1;32m10.\033[0m 管理\033[1;36mTuic\033[0m
\033[1;91m11.\033[0m 彻底\033[1;91m卸载\033[0m      \033[1;35m 0.\033[0m 安全\033[1;35m退出\033[0m
==============================================="

        printf '%b\n' "$menu_text"

        prompt "请输入(0-11): " c
        case "$c" in
            1) cls; install_argo_multiplex; maybe_offer_shortcut; pause ;;
            2) cls; uninstall_component "argo"; pause ;;
            3) manage_socks5 ;;
            4) manage_freeflow ;;
            5) cls; get_info; pause ;;
            6) cls; modify_uuid; pause ;;
            7) manage_restart; pause ;;
            8) manage_swap ;;
            9) manage_reality ;;
            10) manage_tuic ;;
            11) cls; uninstall_component "all" ;;
            0) cls; exit 0 ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

menu
