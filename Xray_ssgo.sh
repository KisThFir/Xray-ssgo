#!/usr/bin/env bash
set -o pipefail

# =========================================================
# 色彩
# =========================================================
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

# =========================================================
# 路径和全局变量
# =========================================================
work_dir="/etc/xray"
xray_bin="${work_dir}/xray"
xray_conf="${work_dir}/config.json"

# xray相关
freeflow_conf="${work_dir}/freeflow.conf"
argo_domain_file="${work_dir}/domain_argo.txt"
argo_yml="${work_dir}/tunnel_argo.yml"
argo_json="${work_dir}/tunnel_argo.json"

# sing-box/tuic相关
sb_bin="${work_dir}/sing-box"
sb_tuic_dir="${work_dir}/singbox-tuic"
sb_tuic_conf="${sb_tuic_dir}/config.json"
sb_tuic_state="${work_dir}/tuic_state.conf" # port|cc|domain|uuid
tls_dir="/etc/v2ray-agent/tls"

# 通用
restart_conf="${work_dir}/restart.conf"
swap_log_file="/tmp/ssgo_swap.log"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}

FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_HOURS=0
XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

# IP信息缓存
IP_CHECKED=0
WAN4="" WAN6=""
COUNTRY4="" AS_NUM4="" ISP_CLEAN4="" EMOJI4=""
COUNTRY6="" AS_NUM6="" ISP_CLEAN6="" EMOJI6=""
NODE_PREFIX="Node"

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1
[ -t 0 ] || { red "请在交互式终端中运行脚本"; exit 1; }

# =========================================================
# 基础
# =========================================================
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
    local need_update=1 package cmd_check
    for package in "$@"; do
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

        yellow "安装依赖: ${package}"
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

update_config() {
    if ! jq "$@" "${xray_conf}" > "${xray_conf}.tmp"; then
        red "配置更新失败：jq表达式错误"
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
    local target="$1" url="$2" min_size="$3"
    local tries=0 max=3 ok=0 cur="$url" mirror_used=0

    while [ "$tries" -lt "$max" ]; do
        rm -f "$target"
        wget -q --show-progress --timeout=30 --tries=1 -O "$target" "$cur"

        if [ -f "$target" ]; then
            local sz
            sz=$(wc -c < "$target" 2>/dev/null || stat -c%s "$target" 2>/dev/null)
            if [ -n "$sz" ] && [ "$sz" -ge "$min_size" ]; then
                green "下载成功 (${sz} bytes)"
                ok=1
                break
            fi
        fi

        if [ "$mirror_used" -eq 0 ]; then
            local m
            m=$(to_ghfast_url "$url")
            if [ "$m" != "$url" ]; then
                yellow "切换 ghfast 镜像重试..."
                cur="$m"
                mirror_used=1
            fi
        fi
        tries=$((tries+1))
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
normalize_path() {
    local x="$1"
    [ -z "$x" ] && { echo "/"; return; }
    case "$x" in
        /*) echo "$x" ;;
        *)  echo "/$x" ;;
    esac
}

# =========================================================
# 系统信息 / IP信息（恢复你原来的国家AS运营商逻辑）
# =========================================================
detect_virtualization() {
    local virt="UNKNOWN" v="" product_name=""
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
    echo "$virt"
}
get_sys_info() {
    [ -n "$SYS_INFO_CACHE" ] && return
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
    IF4=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    IF6=$(ip -6 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')

    if [ -n "${IF4}${IF6}" ]; then
        local L4 L6
        L4=$(ip -4 addr show "$IF4" 2>/dev/null | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
        L6=$(ip -6 addr show "$IF6" 2>/dev/null | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
        [ -n "$L4" ] && BA4="--bind-address=$L4"
        [ -n "$L6" ] && BA6="--bind-address=$L6"
    fi

    local t4 t6
    t4=$(mktemp)
    t6=$(mktemp)

    wget $BA4 -4 -qO- --no-check-certificate --tries=2 --timeout=2 "https://ip.cloudflare.now.cc?lang=zh-CN" > "$t4" 2>/dev/null &
    local p4=$!
    wget $BA6 -6 -qO- --no-check-certificate --tries=2 --timeout=2 "https://ip.cloudflare.now.cc?lang=zh-CN" > "$t6" 2>/dev/null &
    local p6=$!

    wait "$p4" 2>/dev/null || true
    wait "$p6" 2>/dev/null || true

    local J4 J6
    J4=$(cat "$t4" 2>/dev/null)
    J6=$(cat "$t6" 2>/dev/null)
    rm -f "$t4" "$t6"

    if [ -n "$J4" ]; then
        WAN4=$(awk -F '"' '/"ip"/{print $4}' <<< "$J4")
        COUNTRY4=$(awk -F '"' '/"country"/{print $4}' <<< "$J4")
        EMOJI4=$(awk -F '"' '/"emoji"/{print $4}' <<< "$J4")
        local RAW_ASN4 RAW_ISP4
        RAW_ASN4=$(awk -F '"' '/"asn"/{print $4}' <<< "$J4" | grep -oE '[0-9]+')
        RAW_ISP4=$(awk -F '"' '/"isp"/{print $4}' <<< "$J4")
        [ -n "$RAW_ASN4" ] && AS_NUM4="AS${RAW_ASN4}" || AS_NUM4=$(echo "$RAW_ISP4" | grep -oE 'AS[0-9]+' | head -n 1)
        ISP_CLEAN4=$(echo "$RAW_ISP4" | sed -E 's/AS[0-9]+[ -]*//g' | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    fi

    if [ -n "$J6" ]; then
        WAN6=$(awk -F '"' '/"ip"/{print $4}' <<< "$J6")
        COUNTRY6=$(awk -F '"' '/"country"/{print $4}' <<< "$J6")
        EMOJI6=$(awk -F '"' '/"emoji"/{print $4}' <<< "$J6")
        local RAW_ASN6 RAW_ISP6
        RAW_ASN6=$(awk -F '"' '/"asn"/{print $4}' <<< "$J6" | grep -oE '[0-9]+')
        RAW_ISP6=$(awk -F '"' '/"isp"/{print $4}' <<< "$J6")
        [ -n "$RAW_ASN6" ] && AS_NUM6="AS${RAW_ASN6}" || AS_NUM6=$(echo "$RAW_ISP6" | grep -oE 'AS[0-9]+' | head -n 1)
        ISP_CLEAN6=$(echo "$RAW_ISP6" | sed -E 's/AS[0-9]+[ -]*//g' | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    fi

    NODE_PREFIX="Argo"
    if [ -n "$EMOJI4" ] && [ -n "$ISP_CLEAN4" ]; then
        NODE_PREFIX="${EMOJI4}[${COUNTRY4}] ${ISP_CLEAN4}"
    elif [ -n "$EMOJI6" ] && [ -n "$ISP_CLEAN6" ]; then
        NODE_PREFIX="${EMOJI6}[${COUNTRY6}] ${ISP_CLEAN6}"
    fi
    IP_CHECKED=1
}

get_used_mem_display() {
    local used total
    read -r total used < <(awk '
      /MemTotal/ {t=$2}
      /MemAvailable/ {a=$2}
      END{
        u=t-a
        if(t>1024*1024) printf "%.1fG %.1fG", u/1024/1024, t/1024/1024
        else printf "%.0fM %.0fM", u/1024, t/1024
      }' /proc/meminfo 2>/dev/null)
    echo "${used}/${total}"
}

# =========================================================
# Xray模块
# =========================================================
init_xray_config_if_missing() {
    mkdir -p "$work_dir"
    if [ ! -f "$xray_conf" ]; then
        cat > "$xray_conf" <<'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "dns": {
    "servers": [
      { "address": "1.1.1.1", "queryStrategy": "UseIPv4" },
      { "address": "8.8.8.8", "queryStrategy": "UseIPv4" }
    ],
    "queryStrategy": "UseIPv4",
    "disableFallback": false
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

install_xray_core() {
    manage_packages jq wget unzip tar coreutils iproute2
    mkdir -p "$work_dir"
    init_xray_config_if_missing
    ensure_dns_routing

    if [ ! -x "$xray_bin" ]; then
        local arch url
        arch=$(detect_xray_arch)
        [ -z "$arch" ] && { red "不支持当前架构安装Xray"; return 1; }
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

    manage_service restart xray
    green "Xray 已安装并启动"
}

uninstall_xray_only() {
    manage_service stop tunnel-argo 2>/dev/null
    manage_service disable tunnel-argo 2>/dev/null
    rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service

    manage_service stop xray 2>/dev/null
    manage_service disable xray 2>/dev/null
    rm -f /etc/init.d/xray /etc/systemd/system/xray.service

    # 移除xray与argo文件，但保留sing-box模块
    rm -f "${work_dir}/xray" "${xray_conf}" "${work_dir}/argo" "${argo_domain_file}" "${argo_yml}" "${argo_json}" "${work_dir}/argo_start.sh"
    rm -f "${freeflow_conf}"

    green "Xray与Argo已卸载（sing-box保留）"
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
    local new_uuid="$1"
    [ -f "$xray_conf" ] || { red "xray配置不存在"; return 1; }
    update_config --arg uuid "$new_uuid" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'
    manage_service restart xray
    green "Xray UUID 已更新: $new_uuid"
}

# ---------- FreeFlow ----------
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
    echo ""; green "请选择免流(FreeFlow)方式："
    echo "-----------------------------------------------"
    green "1. VLESS + WS (port 80)"
    green "2. VLESS + HTTPUpgrade (port 80)"
    green "3. 不启用（默认）"
    echo "-----------------------------------------------"
    prompt "请输入选择(1-3): " ff_choice
    case "$ff_choice" in
        1) FREEFLOW_MODE="ws" ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none" ;;
    esac
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        prompt "请输入path(回车默认/): " ffp
        FF_PATH=$(normalize_path "$ffp")
    else
        FF_PATH="/"
    fi
    printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
}
apply_freeflow_config() {
    [ -f "$xray_conf" ] || { red "xray未安装"; return 1; }
    ensure_dns_routing || return 1
    local cur_uuid
    cur_uuid=$(get_current_uuid_xray_or_fallback)
    update_config 'del(.inbounds[]? | select(.tag=="ff-in"))' || return 1
    if [ "$FREEFLOW_MODE" != "none" ]; then
        local ff_json
        ff_json='{"tag":"ff-in","port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"'"${cur_uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"'"${FREEFLOW_MODE}"'","security":"none","'"${FREEFLOW_MODE}"'Settings":{"path":"'"${FF_PATH}"'"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}'
        update_config --argjson ib "$ff_json" '.inbounds += [$ib]' || return 1
    fi
    manage_service restart xray
}
manage_freeflow() {
    [ -f "$xray_conf" ] || { red "请先安装xray"; pause; return; }
    load_freeflow_state
    while true; do
        cls
        local ff_show="\033[1;91m未配置\033[0m"
        if [ "$FREEFLOW_MODE" != "none" ]; then
            local m="${FREEFLOW_MODE^^}"
            [ "$m" = "HTTPUPGRADE" ] && m="HTTP+"
            ff_show="\033[1;32m${m} (path=${FF_PATH})\033[0m"
        fi
        echo -e "\033[1;33m=============== 免流(FreeFlow)管理 ===============\033[0m"
        printf "当前: %b\n" "$ff_show"
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 切换方式"
        echo -e "\033[1;32m 2.\033[0m 修改路径"
        echo -e "\033[1;91m 3.\033[0m 卸载免流"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请选择: " c
        case "$c" in
            1) ask_freeflow_mode; apply_freeflow_config; green "已更新"; pause ;;
            2)
                [ "$FREEFLOW_MODE" = "none" ] && { red "请先启用"; pause; continue; }
                prompt "新path(回车保持${FF_PATH}): " np
                [ -n "$np" ] && FF_PATH=$(normalize_path "$np")
                printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
                apply_freeflow_config
                green "路径已更新"
                pause
                ;;
            3)
                FREEFLOW_MODE="none"; FF_PATH="/"
                printf '%s\n%s\n' "$FREEFLOW_MODE" "$FF_PATH" > "$freeflow_conf"
                apply_freeflow_config
                green "已卸载免流"
                pause
                ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

# ---------- socks5 ----------
manage_socks5() {
    [ -f "$xray_conf" ] || { red "请先安装xray"; pause; return; }
    ensure_dns_routing || { red "配置初始化失败"; pause; return; }

    while true; do
        cls
        local socks_list
        socks_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$xray_conf" 2>/dev/null)

        echo -e "\033[1;35m                 Socks5 管理                 \033[0m"
        if [ -z "$socks_list" ]; then
            echo -e "当前配置: \033[1;91m未配置\033[0m"
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
            done <<< "$socks_list"
        fi

        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 添加"
        echo -e "\033[1;32m 2.\033[0m 修改"
        echo -e "\033[1;91m 3.\033[0m 删除"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请选择: " c

        case "$c" in
            1)
                prompt "端口(如1080): " p
                prompt "用户名: " u
                prompt "密码: " pw
                if [[ "$p" =~ ^[0-9]+$ && -n "$u" && -n "$pw" ]]; then
                    local exists
                    exists=$(jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$xray_conf")
                    if [ "$exists" -gt 0 ]; then
                        red "端口已存在"
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
                prompt "修改哪个端口: " p
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
                local i=1 ports=()
                if [ -z "$socks_list" ]; then red "无可删项"; pause; continue; fi
                echo "请选择删除项："
                while read -r line; do
                    local p
                    p=$(echo "$line" | jq -r '.port')
                    echo "  ${i}. 端口 ${p}"
                    ports[$i]="$p"
                    i=$((i+1))
                done <<< "$socks_list"
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

# ---------- argo ----------
install_or_reinstall_argo() {
    install_xray_core || return 1
    ensure_dns_routing || return 1

    if [ ! -x "${work_dir}/argo" ]; then
        local arch url
        arch=$(detect_cloudflared_arch)
        [ -z "$arch" ] && { red "当前架构不支持 cloudflared"; return 1; }
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
        smart_download "${work_dir}/argo" "$url" 15000000 || return 1
        chmod +x "${work_dir}/argo"
    fi

    prompt "请输入Argo域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 1; }
    prompt "请输入Argo JSON凭证: " argo_auth
    echo "$argo_auth" | grep -q "TunnelSecret" || { red "凭证必须为JSON"; return 1; }

    prompt "SS密码(回车随机): " ss_pass
    [ -z "$ss_pass" ] && ss_pass="$(generate_uuid | cut -c1-8)"
    prompt "SS加密(1:aes-128-gcm 2:aes-256-gcm，默认1): " m
    local ss_method="aes-128-gcm"
    [ "$m" = "2" ] && ss_method="aes-256-gcm"

    echo "$argo_domain" > "$argo_domain_file"
    local tunnel_id
    tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID' 2>/dev/null || echo "$argo_auth" | cut -d'"' -f12)
    echo "$argo_auth" > "$argo_json"

    cat > "$argo_yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${argo_json}
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
    green "Argo 安装/重装完成"
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
    if service_exists tunnel-argo; then
        manage_service restart tunnel-argo
        green "Argo 已重启"
    else
        yellow "Argo 未安装"
    fi
}
restart_xray_if_installed() {
    if service_exists xray; then
        manage_service restart xray
        green "Xray 已重启"
    else
        yellow "Xray 未安装"
    fi
}

# ---------- xray节点 ----------
show_xray_nodes() {
    cls
    check_system_ip
    [ -f "$xray_conf" ] || { yellow "xray未安装"; echo "==============================================="; return; }

    local ip=""
    [ -n "$WAN4" ] && ip="$WAN4" || [ -n "$WAN6" ] && ip="$WAN6"

    local uuid
    uuid=$(get_current_uuid_xray_or_fallback)
    local count=0

    green "=============== Xray相关节点链接 =============="

    if [ -f "$argo_domain_file" ]; then
        local d
        d=$(cat "$argo_domain_file")
        local xextra name_xhttp link_xhttp name_ws link_ws
        name_xhttp="${NODE_PREFIX} - XHTTP"
        xextra=$(url_encode "$XHTTP_EXTRA_JSON")
        link_xhttp="vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&alpn=h2&fp=chrome&type=xhttp&host=${d}&path=%2Fxgo&mode=${XHTTP_MODE}&extra=${xextra}#$(url_encode "$name_xhttp")"
        purple "$link_xhttp"; echo ""; count=$((count+1))

        name_ws="${NODE_PREFIX} - WS"
        link_ws="vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2Fargo%3Fed%3D2560#$(url_encode "$name_ws")"
        purple "$link_ws"; echo ""; count=$((count+1))

        local ss_ib
        ss_ib=$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8082)' "$xray_conf" 2>/dev/null)
        if [ -n "$ss_ib" ]; then
            local m pw b64 link_ss
            m=$(echo "$ss_ib" | jq -r '.settings.method')
            pw=$(echo "$ss_ib" | jq -r '.settings.password')
            b64=$(echo -n "${m}:${pw}" | base64 | tr -d '\n')
            link_ss="ss://${b64}@${CFIP}:80?type=ws&security=none&host=${d}&path=%2Fssgo#$(url_encode "${NODE_PREFIX} - SS")"
            purple "$link_ss"; echo ""; count=$((count+1))
        fi
    fi

    load_freeflow_state
    if [ "$FREEFLOW_MODE" != "none" ] && [ -n "$ip" ]; then
        local penc ff_name link_ff
        ff_name="${FREEFLOW_MODE^^}"; [ "$ff_name" = "HTTPUPGRADE" ] && ff_name="HTTP+"
        penc=$(url_encode "$FF_PATH")
        link_ff="vless://${uuid}@${ip}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${ip}&path=${penc}#$(url_encode "${NODE_PREFIX} - FF-${ff_name}")"
        purple "$link_ff"; echo ""; count=$((count+1))
    fi

    local socks
    socks=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$xray_conf" 2>/dev/null)
    if [ -n "$socks" ] && [ -n "$ip" ]; then
        while read -r line; do
            local p u pw
            p=$(echo "$line" | jq -r '.port')
            u=$(echo "$line" | jq -r '.settings.accounts[0].user')
            pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
            purple "socks5://${u}:${pw}@${ip}:${p}#$(url_encode "${NODE_PREFIX} - Socks5-${p}")"
            echo ""
            count=$((count+1))
        done <<< "$socks"
    fi

    [ "$count" -eq 0 ] && yellow "当前没有Xray节点配置"
    echo "==============================================="
}

# =========================================================
# sing-box / tuic模块（只装sing-box，不碰xray）
# =========================================================
install_singbox_core_only() {
    manage_packages jq wget tar curl
    mkdir -p "$work_dir" "$sb_tuic_dir"

    if [ ! -x "$sb_bin" ]; then
        local suffix ver tgz url
        suffix=$(detect_singbox_suffix)
        [ -z "$suffix" ] && { red "当前架构不支持 sing-box"; return 1; }
        ver=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
        [ -z "$ver" ] && { red "无法获取 sing-box 版本"; return 1; }

        tgz="${work_dir}/sing-box.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}${suffix}.tar.gz"
        smart_download "$tgz" "$url" 5000000 || return 1
        tar -xzf "$tgz" -C "$work_dir" >/dev/null 2>&1 || return 1
        mv "${work_dir}/sing-box-${ver#v}${suffix}/sing-box" "$sb_bin" 2>/dev/null || return 1
        chmod +x "$sb_bin"
        rm -rf "$tgz" "${work_dir}/sing-box-${ver#v}${suffix}"
    fi
    green "sing-box 已安装"
    return 0
}

ensure_acme() {
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then return 0; fi

    # 先保证crontab存在，解决你报的pre-check失败
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
        tail -n 40 /tmp/acme_install.log 2>/dev/null
        tail -n 40 /tmp/acme_force_install.log 2>/dev/null
        return 1
    }
    return 0
}

issue_cert_cf_token() {
    local domain="$1" token="$2"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"

    mkdir -p "$tls_dir"
    if [ -s "$crt" ] && [ -s "$key" ]; then
        green "检测到证书已存在: $domain"
        return 0
    fi

    ensure_acme || return 1
    export CF_Token="$token"

    yellow "使用 Cloudflare Token 为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1
    if [ $? -ne 0 ]; then
        red "证书签发失败"
        tail -n 60 /tmp/acme_issue.log
        return 1
    fi

    "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
      --fullchainpath "$crt" \
      --keypath "$key" \
      --ecc >/tmp/acme_installcert.log 2>&1

    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        red "证书安装失败"
        tail -n 60 /tmp/acme_installcert.log
        return 1
    fi
    green "证书安装完成: $domain"
    return 0
}

ensure_port_open() {
    local p="$1" proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${p}/${proto}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --add-port="${p}/${proto}" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

write_tuic_config() {
    local domain="$1" port="$2" cc="$3" uuid="$4"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"
    mkdir -p "$sb_tuic_dir"

    cat > "$sb_tuic_conf" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "tag": "tuic-in",
      "listen_port": ${port},
      "users": [
        {
          "uuid": "${uuid}",
          "password": "${uuid}"
        }
      ],
      "congestion_control": "${cc}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": ["h3"],
        "certificate_path": "${crt}",
        "key_path": "${key}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct_ipv4",
      "domain_strategy": "ipv4_only"
    }
  ],
  "route": {
    "final": "direct_ipv4"
  }
}
EOF
}

install_singbox_service_if_missing() {
    if service_exists tuic-box; then return 0; fi
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/tuic-box <<EOF
#!/sbin/openrc-run
description="Tuic by sing-box"
command="${sb_bin}"
command_args="run -c ${sb_tuic_conf}"
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
ExecStart=${sb_bin} run -c ${sb_tuic_conf}
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
    if is_service_running tuic-box; then
        return 0
    fi

    red "sing-box 启动失败，日志如下："
    if [ -f /etc/alpine-release ]; then
        rc-service tuic-box status 2>/dev/null
    else
        journalctl -u tuic-box -n 80 --no-pager
    fi
    return 1
}

load_tuic_state() {
    TUIC_PORT=""; TUIC_CC=""; TUIC_DOMAIN=""; TUIC_UUID=""
    [ -f "$sb_tuic_state" ] || return
    IFS='|' read -r TUIC_PORT TUIC_CC TUIC_DOMAIN TUIC_UUID < "$sb_tuic_state"
}

install_tuic_flow() {
    install_singbox_core_only || return 1

    local domain token port cc uuid
    prompt "请输入Tuic域名: " domain
    [ -z "$domain" ] && { red "域名不能为空"; return 1; }

    prompt "请输入Cloudflare API Token: " token
    [ -z "$token" ] && { red "Token不能为空"; return 1; }

    prompt "请输入Tuic端口(默认18443): " port
    [ -z "$port" ] && port=18443
    [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }

    echo "拥塞算法：1.bbr(默认) 2.cubic 3.new_reno"
    prompt "请选择(1-3): " csel
    case "$csel" in
        2) cc="cubic" ;;
        3) cc="new_reno" ;;
        *) cc="bbr" ;;
    esac

    issue_cert_cf_token "$domain" "$token" || return 1
    ensure_port_open "$port" udp

    # tuic不依赖xray，独立uuid
    uuid="$(generate_uuid)"
    write_tuic_config "$domain" "$port" "$cc" "$uuid"
    install_singbox_service_if_missing
    start_singbox_and_check || return 1

    printf '%s|%s|%s|%s\n' "$port" "$cc" "$domain" "$uuid" > "$sb_tuic_state"
    green "Tuic安装完成（v6入站 + v4出站）"
    return 0
}

restart_singbox_menu() {
    if ! service_exists tuic-box; then
        yellow "sing-box服务未安装"
        return
    fi
    if start_singbox_and_check; then
        green "sing-box 已重启（tuic已随之重启）"
    fi
}

uninstall_singbox_menu() {
    manage_service stop tuic-box 2>/dev/null
    manage_service disable tuic-box 2>/dev/null
    rm -f /etc/init.d/tuic-box /etc/systemd/system/tuic-box.service
    rm -rf "$sb_tuic_dir"
    rm -f "$sb_tuic_state" "$sb_bin" "$tuic_domain_file"
    green "sing-box/Tuic 已卸载"
}

# =========================================================
# 定时重启
# =========================================================
load_restart_hours() {
    RESTART_HOURS=0
    if [ -f "$restart_conf" ]; then
        RESTART_HOURS=$(cat "$restart_conf" 2>/dev/null)
        [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
    fi
}
setup_cron_env_if_missing() {
    if command -v crontab >/dev/null 2>&1; then return 0; fi
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
}
manage_restart_hours() {
    load_restart_hours
    cls
    green "当前定时重启间隔: ${RESTART_HOURS} 小时 (0=关闭)"
    prompt "请输入间隔小时(0关闭): " nh
    [[ "$nh" =~ ^[0-9]+$ ]] || { red "输入无效"; return; }

    RESTART_HOURS="$nh"
    echo "$RESTART_HOURS" > "$restart_conf"

    if [ "$RESTART_HOURS" -eq 0 ]; then
        command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart-all/d') | crontab -
        green "定时重启已关闭"
        return
    fi

    setup_cron_env_if_missing
    command -v crontab >/dev/null 2>&1 || { red "crontab不可用"; return; }

    local cmd
    if [ -f /etc/alpine-release ]; then
        cmd='[ -f /etc/init.d/xray ] && rc-service xray restart; [ -f /etc/init.d/tuic-box ] && rc-service tuic-box restart; [ -f /etc/init.d/tunnel-argo ] && rc-service tunnel-argo restart'
    else
        cmd='systemctl list-unit-files | grep -q "^xray.service" && systemctl restart xray; systemctl list-unit-files | grep -q "^tuic-box.service" && systemctl restart tuic-box; systemctl list-unit-files | grep -q "^tunnel-argo.service" && systemctl restart tunnel-argo'
    fi

    local exp="0 */${RESTART_HOURS} * * *"
    (crontab -l 2>/dev/null | sed '/#svc-restart-all/d'; echo "${exp} ${cmd} >/dev/null 2>&1 #svc-restart-all") | crontab -
    green "已设置每 ${RESTART_HOURS} 小时重启（xray/sing-box/argo按安装情况执行）"
}

# =========================================================
# SWAP
# =========================================================
swap_cleanup_entries() { [ -f /etc/fstab ] && sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab; }
swap_disable_all() {
    awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | while read -r dev; do [ -n "$dev" ] && swapoff "$dev" >/dev/null 2>&1 || true; done
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
    local size_mb="$1" zdev="" zname=""
    if [ -e /dev/zram0 ]; then zdev="/dev/zram0"
    elif [ -w /sys/class/zram-control/hot_add ]; then
        local zid; zid=$(cat /sys/class/zram-control/hot_add 2>/dev/null); [ -n "$zid" ] && zdev="/dev/zram${zid}"
    fi
    [ -z "$zdev" ] && return 1
    zname="${zdev#/dev/}"
    echo 1 > "/sys/block/${zname}/reset" 2>/dev/null || true
    [ -w "/sys/block/${zname}/comp_algorithm" ] && echo lz4 > "/sys/block/${zname}/comp_algorithm" 2>/dev/null || true
    echo "$((size_mb * 1024 * 1024))" > "/sys/block/${zname}/disksize" 2>/dev/null || return 1
    mkswap "${zdev}" >/dev/null 2>&1 || return 1
    swapon "${zdev}" >/dev/null 2>&1 || return 1
    return 0
}
create_swapfile_dd() {
    local size_mb="$1"
    dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none 2>/tmp/dd_err.log || return 1
    chmod 600 /swapfile || return 1
    mkswap /swapfile >/dev/null 2>&1 || return 1
    swapon /swapfile >/dev/null 2>&1 || return 1
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    return 0
}
create_swapfile_fallocate() {
    local size_mb="$1"
    command -v fallocate >/dev/null 2>&1 || return 1
    fallocate -l "${size_mb}M" /swapfile 2>/tmp/fallocate_err.log || return 1
    chmod 600 /swapfile || return 1
    mkswap -f /swapfile >/dev/null 2>&1 || return 1
    swapon /swapfile >/dev/null 2>&1 || return 1
    grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    return 0
}
create_swap_best_effort() {
    local size_mb="${1:-256}"
    swap_disable_all
    if zram_supported && create_zram_swap "$size_mb"; then green "SWAP成功(ZRAM ${size_mb}MB)"; return 0; fi
    if create_swapfile_dd "$size_mb"; then green "SWAP成功(dd ${size_mb}MB)"; return 0; fi
    rm -f /swapfile
    if create_swapfile_fallocate "$size_mb"; then green "SWAP成功(fallocate ${size_mb}MB)"; return 0; fi
    red "SWAP配置失败"; return 1
}
manage_swap() {
    while true; do
        cls
        local ram swap
        ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$ram" ] && ram=0
        swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$swap" ] && swap=0

        echo -e "\033[1;36m=============== SWAP 虚拟内存管理 ===============\033[0m"
        echo "物理内存: ${ram}MB"
        if [ "$swap" -gt 0 ]; then
            echo -e "SWAP: \033[1;32m${swap}MB(已开启)\033[0m"
        else
            echo -e "SWAP: \033[1;91m0MB(未开启)\033[0m"
        fi
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 添加/修改SWAP (zram优先)"
        echo -e "\033[1;91m 2.\033[0m 关闭并清理SWAP"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请选择: " c
        case "$c" in
            1) prompt "请输入SWAP大小MB(默认256): " sz; sz=${sz:-256}; [[ "$sz" =~ ^[0-9]+$ ]] && [ "$sz" -gt 0 ] && create_swap_best_effort "$sz" || red "输入无效"; pause ;;
            2) swap_disable_all; green "SWAP已关闭清理"; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

# =========================================================
# 菜单：Xray管理
# =========================================================
xray_menu() {
    while true; do
        cls
        local x_stat a_stat
        if [ -x "$xray_bin" ]; then
            x_stat=$(is_service_running xray && echo "\033[1;36m运行中\033[0m" || echo "\033[1;91m未启动\033[0m")
        else
            x_stat="\033[1;91m未安装\033[0m"
        fi
        if service_exists tunnel-argo; then
            a_stat=$(is_service_running tunnel-argo && echo "\033[1;36m运行中\033[0m" || echo "\033[1;91m未启动\033[0m")
        else
            a_stat="\033[1;91m未配置\033[0m"
        fi

        local menu_text
        menu_text="\033[1;33m=============== Xray 管理 ===============\033[0m
Xray: ${x_stat}
Argo: ${a_stat}
-----------------------------------------------
\033[1;32m 1.\033[0m 安装/重装 Argo
\033[1;91m 2.\033[0m 卸载 Argo
\033[1;32m 3.\033[0m Socks5 管理
\033[1;32m 4.\033[0m 免流管理 (FreeFlow)
\033[1;32m 5.\033[0m 修改 UUID
\033[1;32m 6.\033[0m 查看节点
\033[1;32m 7.\033[0m 重启 Argo
\033[1;32m 8.\033[0m 重启 Xray
\033[1;91m 9.\033[0m 卸载 Xray
\033[1;35m 0.\033[0m 返回
==============================================="
        printf '%b\n' "$menu_text"

        prompt "请选择: " c
        case "$c" in
            1) install_or_reinstall_argo; pause ;;
            2) uninstall_argo_only; pause ;;
            3) manage_socks5 ;;
            4) manage_freeflow ;;
            5)
                if [ ! -f "$xray_conf" ]; then red "xray未安装"; pause; continue; fi
                prompt "新UUID(回车自动生成): " nu
                [ -z "$nu" ] && nu="$(generate_uuid)"
                set_xray_uuid_no_validate "$nu"
                pause
                ;;
            6) show_xray_nodes; pause ;;
            7) restart_argo_if_installed; pause ;;
            8) restart_xray_if_installed; pause ;;
            9) uninstall_xray_only; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

# =========================================================
# 菜单：sing-box管理
# =========================================================
singbox_menu() {
    while true; do
        cls
        local sb_stat
        if [ -x "$sb_bin" ]; then
            sb_stat=$(is_service_running tuic-box && echo "\033[1;36m运行中\033[0m" || echo "\033[1;91m未启动\033[0m")
        else
            sb_stat="\033[1;91m未安装\033[0m"
        fi

        local menu_text
        menu_text="\033[1;36m=============== sing-box 管理 ===============\033[0m
sing-box(Tuic): ${sb_stat}
-----------------------------------------------
\033[1;32m 1.\033[0m 安装 Tuic（自动安装sing-box+域名证书）
\033[1;32m 2.\033[0m 重启 sing-box（tuic会一起重启）
\033[1;91m 3.\033[0m 卸载 sing-box
\033[1;35m 0.\033[0m 返回
==============================================="
        printf '%b\n' "$menu_text"

        prompt "请选择: " c
        case "$c" in
            1) install_tuic_flow; pause ;;
            2) restart_singbox_menu; pause ;;
            3) uninstall_singbox_menu; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

# =========================================================
# 彻底卸载
# =========================================================
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

    rm -rf "$work_dir" "$tls_dir"
    green "已彻底卸载并尽量恢复初始状态"
}

# =========================================================
# 主菜单
# =========================================================
main_menu() {
    manage_packages jq wget curl iproute2 coreutils tar unzip openssl >/dev/null 2>&1
    get_sys_info
    check_system_ip
    load_restart_hours

    while true; do
        cls
        local len4 len6 pad_len ip4_disp ip6_disp mem_used
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

        mem_used=$(get_used_mem_display)

        local menu_text
        menu_text="OS: \033[1;36m${SYS_INFO_CACHE}\033[0m
v4: ${ip4_disp}
v6: ${ip6_disp}
Mem: \033[1;36m${mem_used}\033[0m
-----------------------------------------------
\033[1;32m 1.\033[0m Xray 管理
\033[1;32m 2.\033[0m sing-box 管理
\033[1;32m 3.\033[0m 定时重启（xray/sing-box/argo）
\033[1;32m 4.\033[0m 管理 SWAP
\033[1;91m 9.\033[0m 彻底卸载
\033[1;35m 0.\033[0m 退出
==============================================="
        printf '%b\n' "$menu_text"

        prompt "请输入: " c
        case "$c" in
            1) xray_menu ;;
            2) singbox_menu ;;
            3) manage_restart_hours; pause ;;
            4) manage_swap ;;
            9) full_uninstall; pause ;;
            0) cls; exit 0 ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

trap 'echo ""; cls; red "已中断"; exit 130' INT TERM
main_menu
