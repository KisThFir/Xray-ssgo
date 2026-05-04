#!/usr/bin/env bash
set -o pipefail

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }

clear_buffer() { while read -r -t 0.1 -n 10000 _dummy </dev/tty 2>/dev/null; do :; done; }
prompt() { clear_buffer; printf '\033[1;91m%s\033[0m' "$1" >&2; read -r "$2" </dev/tty; }
pause() { printf '\n\033[1;91m按回车键继续...\033[0m\n' >&2; clear_buffer; read -r _dummy </dev/tty; }
cls() { clear; printf '\033[3J\033[2J\033[H'; }
url_encode() { jq -rn --arg x "$1" '$x|@uri'; }

manage_service() {
    local action="$1" svc_name="$2"
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

server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
freeflow_conf="${work_dir}/freeflow.conf"
restart_conf="${work_dir}/restart.conf"
swap_log_file="/tmp/ssgo_swap.log"

# Tuic / cert (新增)
tuic_conf="${work_dir}/tuic.conf"                   # port|cc|domain
tuic_sb_conf_dir="${work_dir}/tuic-sb"
tuic_sb_conf="${tuic_sb_conf_dir}/config.json"
tuic_sb_bin="${work_dir}/sing-box"
tuic_domain_file="${work_dir}/tuic_domain.txt"
tls_dir="/etc/v2ray-agent/tls"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}
FREEFLOW_MODE="none"
FF_PATH="/"
RESTART_HOURS=0

XHTTP_MODE="auto"
XHTTP_EXTRA_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"y2k","xPaddingKey":"_y2k"}'

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1
[ -t 0 ] || { red "请在交互式终端中运行脚本"; exit 1; }

update_config() {
    if ! jq "$@" "${config_dir}" > "${config_dir}.tmp"; then
        red "配置更新失败：JSON/jq 表达式异常"
        rm -f "${config_dir}.tmp"
        return 1
    fi
    mv "${config_dir}.tmp" "${config_dir}"
}

to_ghfast_url() {
    local src="$1"
    case "$src" in
        https://github.com/*|https://raw.githubusercontent.com/*) echo "https://ghfast.top/${src}" ;;
        *) echo "$src" ;;
    esac
}

smart_download() {
    local target_file="$1" url="$2" min_size_bytes="$3"
    local max_retries=3 retry_count=0 dl_success=0 current_url="$url" using_mirror=0

    while [ "$retry_count" -lt "$max_retries" ]; do
        rm -f "${target_file}"
        wget -q --show-progress --timeout=30 --tries=1 -O "${target_file}" "${current_url}"

        if [ -f "${target_file}" ]; then
            local file_size
            file_size=$(wc -c < "${target_file}" 2>/dev/null || stat -c%s "${target_file}" 2>/dev/null)
            if [ -n "$file_size" ] && [ "$file_size" -ge "$min_size_bytes" ]; then
                green "下载成功 (${file_size} bytes)"
                dl_success=1
                break
            else
                red "下载体积异常(${file_size} bytes)"
            fi
        else
            red "下载失败: 未生成文件"
        fi

        if [ "$using_mirror" -eq 0 ]; then
            local mirror_url
            mirror_url=$(to_ghfast_url "$url")
            if [ "$mirror_url" != "$url" ]; then
                yellow "切换 ghfast 加速重试..."
                current_url="$mirror_url"
                using_mirror=1
            fi
        fi

        retry_count=$((retry_count + 1))
        [ "$retry_count" -lt "$max_retries" ] && sleep 2
    done

    [ "$dl_success" -eq 1 ] || { red "下载失败: ${url}"; return 1; }
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

normalize_path() {
    local x="$1"
    [ -z "$x" ] && { echo "/"; return; }
    case "$x" in
        /*) echo "$x" ;;
        *)  echo "/$x" ;;
    esac
}

load_state() {
    if [ -f "${freeflow_conf}" ]; then
        local l1 l2
        { read -r l1; read -r l2; } < "${freeflow_conf}"
        case "$l1" in ws|httpupgrade) FREEFLOW_MODE="$l1" ;; *) FREEFLOW_MODE="none" ;; esac
        [ -n "$l2" ] && FF_PATH="$l2"
    fi

    if [ -f "${restart_conf}" ]; then
        RESTART_HOURS="$(cat "${restart_conf}" 2>/dev/null)"
        [[ "$RESTART_HOURS" =~ ^[0-9]+$ ]] || RESTART_HOURS=0
    fi
}
load_state

detect_virtualization() {
    local virt="UNKNOWN" v="" product_name=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt 2>/dev/null)
        case "$v" in
            kvm) virt="KVM" ;; qemu) virt="QEMU" ;; vmware) virt="VMWARE" ;;
            xen) virt="XEN" ;; microsoft|hyperv) virt="HYPER-V" ;;
            openvz) virt="OPENVZ" ;; lxc|lxc-libvirt) virt="LXC" ;;
            docker) virt="DOCKER" ;; podman) virt="PODMAN" ;;
            wsl) virt="WSL" ;; none|"") virt="UNKNOWN" ;;
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
            *Hyper-V*|*hyperv*|*Microsoft*) virt="HYPER-V" ;;
        esac
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
    WAN4=$(curl -4 -s --max-time 4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    WAN6=$(curl -6 -s --max-time 4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
    [ -z "$WAN4" ] && WAN4=""
    [ -z "$WAN6" ] && WAN6=""
    COUNTRY4="--"; AS_NUM4="--"; ISP_CLEAN4="--"
    COUNTRY6="--"; AS_NUM6="--"; ISP_CLEAN6="--"
    NODE_PREFIX="Argo"
    IP_CHECKED=1
}

init_xray_config() {
    mkdir -p "${work_dir}"
    if [ ! -f "${config_dir}" ]; then
        cat > "${config_dir}" << 'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "warning" },
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
    init_xray_config
    local has_dnsout
    has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "${config_dir}" 2>/dev/null)
    [ "$has_dnsout" = "true" ] || update_config '.outbounds += [{"protocol":"dns","tag":"dns-out"}]'

    jq -e '.routing' "${config_dir}" >/dev/null 2>&1 || update_config '.routing={"rules":[]}'
    local has53 hasdns
    has53=$(jq '[.routing.rules[]? | select(.port=="53")] | length' "${config_dir}" 2>/dev/null)
    hasdns=$(jq '[.routing.rules[]? | select(.protocol=="dns")] | length' "${config_dir}" 2>/dev/null)
    if [ "${has53:-0}" -eq 0 ] || [ "${hasdns:-0}" -eq 0 ]; then
        update_config 'del(.routing.rules[]? | select(.port=="53" or .protocol=="dns"))'
        update_config '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]'
    fi
}

install_core() {
    manage_packages jq unzip wget iproute2 coreutils tar curl openssl
    mkdir -p "${work_dir}"
    init_xray_config

    if [ ! -x "${work_dir}/${server_name}" ]; then
        local arch xray_url
        arch=$(detect_xray_arch)
        [ -z "$arch" ] && { red "当前架构不支持自动安装 Xray"; return 1; }
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        smart_download "${work_dir}/xray.zip" "${xray_url}" 5000000 || return 1
        unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" >/dev/null 2>&1 || return 1
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/xray.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi

    if [ ! -f /etc/systemd/system/xray.service ] && [ ! -f /etc/init.d/xray ]; then
        if [ -f /etc/alpine-release ]; then
            cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run
description="Xray Service"
command="${work_dir}/xray"
command_args="run -c ${config_dir}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
            chmod +x /etc/init.d/xray
        else
            cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        fi
        manage_service enable xray
    fi
    manage_service restart xray
}

get_current_uuid() {
    if [ -f "${config_dir}" ]; then
        local id
        id=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "${config_dir}" 2>/dev/null)
        [ -n "$id" ] && [ "$id" != "null" ] && { echo "$id"; return; }
    fi
    echo "${UUID_FALLBACK}"
}

get_mem_by_svc() {
    local svc_name="$1" cmd_match="$2" pid=""
    if [ -f /etc/alpine-release ]; then
        pid=$(pgrep -f "$cmd_match" | head -n1)
    else
        pid=$(systemctl show -p MainPID --value "$svc_name" 2>/dev/null)
        [ -z "$pid" ] || [ "$pid" = "0" ] && pid=$(pgrep -f "$cmd_match" | head -n1)
    fi
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        local mem
        mem=$(grep -i VmRSS "/proc/$pid/status" | awk '{print $2}')
        [ -n "$mem" ] && [ "$mem" -gt 0 ] && awk "BEGIN {printf \"%.1fM\", $mem/1024}"
    fi
}
check_status() {
    local svc_name="$1" bin_path="$2" cmd_match="$3"
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
    green "FreeFlow 已更新"
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
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 切换方式   \033[1;32m 2.\033[0m 修改路径"
        echo -e "\033[1;91m 3.\033[0m 卸载模块   \033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请输入选择: " c
        case "$c" in
            1) ask_freeflow_mode; apply_freeflow_config; manage_service restart xray; pause ;;
            2)
                [ "${FREEFLOW_MODE}" = "none" ] && { red "请先启用 FreeFlow"; pause; continue; }
                prompt "新 path（回车保持 ${FF_PATH}）: " np
                [ -n "$np" ] && FF_PATH=$(normalize_path "$np")
                printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
                apply_freeflow_config
                manage_service restart xray
                green "路径已更新"
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
            *) red "无效选择"; pause ;;
        esac
    done
}

manage_socks5() {
    while true; do
        cls
        ensure_dns_routing || { red "配置初始化失败"; pause; return; }

        local socks_list
        socks_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$config_dir" 2>/dev/null)

        cls
        printf '\033[1;35m                 管理 Socks5 代理              \033[0m\n'
        if [ -z "$socks_list" ]; then
            echo '  当前: 未配置'
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
        echo -e "\033[1;32m 1.\033[0m 添加  \033[1;32m 2.\033[0m 修改"
        echo -e "\033[1;91m 3.\033[0m 删除  \033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请输入选择: " s

        case "$s" in
            1)
                install_core
                prompt "端口: " ns_port
                prompt "用户名: " ns_user
                prompt "密码: " ns_pass
                if [[ -n "$ns_port" && "$ns_port" =~ ^[0-9]+$ && -n "$ns_user" && -n "$ns_pass" ]]; then
                    local exist
                    exist=$(jq --argjson p "$ns_port" '[.inbounds[]? | select(.port==$p)] | length' "$config_dir")
                    if [ "$exist" -gt 0 ]; then
                        red "端口已存在"
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
                i=1; local ports=()
                while read -r line; do
                    local p
                    p=$(echo "$line" | jq -r '.port')
                    echo "  ${i}. 端口 ${p}"
                    ports[$i]="$p"
                    i=$((i+1))
                done <<<"$s_list"
                echo "  0. 取消"
                prompt "序号: " di
                if [[ "$di" =~ ^[0-9]+$ ]] && [ "$di" -gt 0 ] && [ "$di" -lt "$i" ]; then
                    update_config --argjson p "${ports[$di]}" 'del(.inbounds[]? | select(.protocol=="socks" and .port==$p))'
                    manage_service restart xray
                    green "已删除"
                fi
                pause
                ;;
            0) return ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

install_argo_multiplex() {
    cls
    install_core

    if [ ! -x "${work_dir}/argo" ]; then
        local arch argo_url
        arch=$(detect_cloudflared_arch)
        [ -z "$arch" ] && { red "架构不支持 cloudflared"; return 1; }
        argo_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
        smart_download "${work_dir}/argo" "${argo_url}" 15000000 || return 1
        chmod +x "${work_dir}/argo"
    fi

    ensure_dns_routing || return 1

    prompt "请输入 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 1; }

    prompt "请输入 Argo JSON 凭证: " argo_auth
    echo "$argo_auth" | grep -q "TunnelSecret" || { red "凭证必须是JSON"; return 1; }

    prompt "SS密码(回车随机): " ss_pass
    [ -z "$ss_pass" ] && ss_pass="$(cat /proc/sys/kernel/random/uuid | cut -c1-8)"
    local ss_method="aes-128-gcm"
    prompt "SS加密(1:aes-128-gcm 2:aes-256-gcm): " m
    [ "$m" = "2" ] && ss_method="aes-256-gcm"

    echo "$argo_domain" > "${work_dir}/domain_argo.txt"
    local tunnel_id
    tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID' 2>/dev/null || echo "$argo_auth" | cut -d'"' -f12)
    echo "$argo_auth" > "${work_dir}/tunnel_argo.json"

    cat > "${work_dir}/tunnel_argo.yml" << EOF
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

    local ws_json xhttp_json ss_json
    ws_json='{"port":8080,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"'"${cur_uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
    xhttp_json=$(jq -nc --arg uuid "$cur_uuid" --arg mode "$XHTTP_MODE" --argjson extra "$XHTTP_EXTRA_JSON" \
        '{"port":8081,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')
    ss_json='{"port":8082,"listen":"127.0.0.1","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
    update_config --argjson ws "$ws_json" --argjson xhttp "$xhttp_json" --argjson ss "$ss_json" '.inbounds += [$ws,$xhttp,$ss]' || return 1

    local exec_cmd svc="tunnel-argo"
    exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --config ${work_dir}/tunnel_argo.yml run"

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

    manage_service enable "${svc}"
    manage_service restart "${svc}"
    manage_service restart xray
    green "Argo 部署完成"
}

# ---------- Cloudflare Token only cert ----------
ensure_acme() {
    if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
        yellow "安装 acme.sh..."
        curl -s https://get.acme.sh | sh >/tmp/acme_install.log 2>&1
        [ -x "$HOME/.acme.sh/acme.sh" ] || { red "acme.sh 安装失败"; tail -n 20 /tmp/acme_install.log; return 1; }
    fi
    return 0
}
ensure_port_open() {
    local p="$1" proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1; then ufw allow "${p}/${proto}" >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --add-port="${p}/${proto}" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}
issue_cert_cf_token() {
    local domain="$1" token="$2"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"

    mkdir -p "${tls_dir}"
    if [ -s "$crt" ] && [ -s "$key" ]; then
        green "检测到现有证书: ${domain}"
        return 0
    fi

    ensure_acme || return 1
    export CF_Token="$token"

    yellow "开始 Cloudflare Token 申请证书: ${domain}"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1
    if [ $? -ne 0 ]; then
        red "签发失败"
        tail -n 50 /tmp/acme_issue.log
        return 1
    fi

    "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
        --fullchainpath "$crt" \
        --keypath "$key" \
        --ecc >/tmp/acme_installcert.log 2>&1

    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        red "安装证书失败"
        tail -n 50 /tmp/acme_installcert.log
        return 1
    fi
    green "证书已安装: ${crt}"
    return 0
}

# ---------- Tuic via sing-box (按 install.sh 思路 + 仅v4出站) ----------
install_singbox_for_tuic() {
    if [ -x "${tuic_sb_bin}" ]; then return 0; fi
    local suffix ver url tgz
    suffix=$(detect_singbox_suffix)
    [ -z "$suffix" ] && { red "当前架构不支持 sing-box"; return 1; }

    ver=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
    [ -z "$ver" ] && { red "无法获取 sing-box 版本"; return 1; }

    tgz="${work_dir}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}${suffix}.tar.gz"

    smart_download "$tgz" "$url" 5000000 || return 1
    tar -xzf "$tgz" -C "$work_dir" >/dev/null 2>&1 || return 1
    mv "${work_dir}/sing-box-${ver#v}${suffix}/sing-box" "${tuic_sb_bin}" 2>/dev/null || return 1
    chmod +x "${tuic_sb_bin}"
    rm -rf "$tgz" "${work_dir}/sing-box-${ver#v}${suffix}"
    green "sing-box 安装完成"
    return 0
}
write_tuic_config() {
    local domain="$1" port="$2" cc="$3" uuid="$4"
    local crt="${tls_dir}/${domain}.crt" key="${tls_dir}/${domain}.key"
    mkdir -p "${tuic_sb_conf_dir}"

    cat > "${tuic_sb_conf}" <<EOF
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
      "tag": "singbox-tuic-in",
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
install_tuic_service() {
    local svc="tuic-box"
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/${svc} <<EOF
#!/sbin/openrc-run
description="Tuic by sing-box"
command="${tuic_sb_bin}"
command_args="run -c ${tuic_sb_conf}"
command_background=true
pidfile="/var/run/${svc}.pid"
EOF
        chmod +x /etc/init.d/${svc}
        rc-update add ${svc} default >/dev/null 2>&1 || true
    else
        cat > /etc/systemd/system/${svc}.service <<EOF
[Unit]
Description=Tuic by sing-box
After=network.target
[Service]
Type=simple
ExecStart=${tuic_sb_bin} run -c ${tuic_sb_conf}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${svc} >/dev/null 2>&1 || true
    fi
}
start_tuic_and_check() {
    if [ -f /etc/alpine-release ]; then
        rc-service tuic-box restart >/dev/null 2>&1 || true
        rc-service tuic-box status >/dev/null 2>&1 || { red "tuic-box 启动失败"; return 1; }
    else
        systemctl restart tuic-box >/dev/null 2>&1 || true
        if ! systemctl is-active --quiet tuic-box; then
            red "tuic-box 启动失败，日志："
            journalctl -u tuic-box -n 80 --no-pager
            return 1
        fi
    fi
    return 0
}
load_tuic_state() {
    [ -f "$tuic_conf" ] || return
    IFS='|' read -r TUIC_PORT TUIC_CC TUIC_DOMAIN < "$tuic_conf"
}
manage_tuic() {
    load_tuic_state
    while true; do
        cls
        local tstat="\033[1;91m未运行\033[0m"
        is_service_running tuic-box && tstat="\033[1;32m运行中\033[0m"
        echo -e "\033[1;36m=============== Tuic 管理 ===============\033[0m"
        echo -e "状态: ${tstat}"
        [ -n "$TUIC_DOMAIN" ] && echo -e "域名: \033[1;36m${TUIC_DOMAIN}\033[0m"
        [ -n "$TUIC_PORT" ] && echo -e "端口: \033[1;36m${TUIC_PORT}\033[0m"
        [ -n "$TUIC_CC" ] && echo -e "拥塞: \033[1;36m${TUIC_CC}\033[0m"
        echo "-----------------------------------------------"
        echo -e "\033[1;32m 1.\033[0m 安装/重装 Tuic"
        echo -e "\033[1;32m 2.\033[0m 重启 Tuic"
        echo -e "\033[1;91m 3.\033[0m 卸载 Tuic"
        echo -e "\033[1;35m 0.\033[0m 返回"
        echo "==============================================="
        prompt "请选择: " tc

        case "$tc" in
            1)
                install_core || { pause; continue; }
                install_singbox_for_tuic || { pause; continue; }

                local domain token port cc uuid
                prompt "请输入 Tuic 域名: " domain
                [ -z "$domain" ] && { red "域名不能为空"; pause; continue; }

                prompt "请输入 Cloudflare API Token: " token
                [ -z "$token" ] && { red "Token 不能为空"; pause; continue; }

                prompt "请输入 Tuic 端口(默认18443): " port
                [ -z "$port" ] && port=18443
                [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; pause; continue; }

                echo "拥塞算法：1)bbr(默认) 2)cubic 3)new_reno"
                prompt "请选择(1-3): " csel
                case "$csel" in
                    2) cc="cubic" ;;
                    3) cc="new_reno" ;;
                    *) cc="bbr" ;;
                esac

                issue_cert_cf_token "$domain" "$token" || { pause; continue; }
                ensure_port_open "$port" udp

                uuid=$(get_current_uuid)
                write_tuic_config "$domain" "$port" "$cc" "$uuid"
                install_tuic_service

                if start_tuic_and_check; then
                    printf '%s|%s|%s\n' "$port" "$cc" "$domain" > "$tuic_conf"
                    echo "$domain" > "$tuic_domain_file"
                    TUIC_PORT="$port"; TUIC_CC="$cc"; TUIC_DOMAIN="$domain"
                    green "Tuic 安装成功（v6入站 + v4出站）"
                else
                    red "Tuic 启动失败"
                fi
                pause
                ;;
            2)
                if start_tuic_and_check; then green "Tuic 已重启"; else red "Tuic 重启失败"; fi
                pause
                ;;
            3)
                manage_service stop tuic-box 2>/dev/null
                manage_service disable tuic-box 2>/dev/null
                rm -f /etc/systemd/system/tuic-box.service /etc/init.d/tuic-box
                rm -rf "${tuic_sb_conf_dir}"
                rm -f "${tuic_conf}" "${tuic_domain_file}"
                TUIC_PORT=""; TUIC_CC=""; TUIC_DOMAIN=""
                green "Tuic 已卸载"
                pause
                ;;
            0) return ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

get_info() {
    cls
    check_system_ip
    load_tuic_state

    local IP=""
    [ -n "$WAN4" ] && IP="$WAN4" || [ -n "$WAN6" ] && IP="$WAN6"

    local cur_uuid
    cur_uuid=$(get_current_uuid)
    local node_count=0

    green "=============== 当前可用节点链接 =============="

    if [ -f "${work_dir}/domain_argo.txt" ]; then
        local domain_argo
        domain_argo=$(cat "${work_dir}/domain_argo.txt")

        local xhttp_extra_uri name_xhttp link_xhttp
        name_xhttp="Argo-XHTTP"
        xhttp_extra_uri=$(url_encode "$XHTTP_EXTRA_JSON")
        link_xhttp="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&alpn=h2&fp=chrome&type=xhttp&host=${domain_argo}&path=%2Fxgo&mode=${XHTTP_MODE}&extra=${xhttp_extra_uri}#$(url_encode "$name_xhttp")"
        purple "$link_xhttp"; echo ""; node_count=$((node_count+1))

        local name_ws link_ws
        name_ws="Argo-WS"
        link_ws="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&fp=chrome&type=ws&host=${domain_argo}&path=%2Fargo%3Fed%3D2560#$(url_encode "$name_ws")"
        purple "$link_ws"; echo ""; node_count=$((node_count+1))

        local ss_ib
        ss_ib=$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8082)' "$config_dir" 2>/dev/null)
        if [ -n "$ss_ib" ]; then
            local m pw b64 name_ss link_ss
            m=$(echo "$ss_ib" | jq -r '.settings.method')
            pw=$(echo "$ss_ib" | jq -r '.settings.password')
            name_ss="Argo-SS"
            b64=$(echo -n "${m}:${pw}" | base64 | tr -d '\n')
            link_ss="ss://${b64}@${CFIP}:80?type=ws&security=none&host=${domain_argo}&path=%2Fssgo#$(url_encode "$name_ss")"
            purple "$link_ss"; echo ""; node_count=$((node_count+1))
        fi
    fi

    if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ]; then
        local ff_name path_enc ff_link
        ff_name="${FREEFLOW_MODE^^}"; [ "$ff_name" = "HTTPUPGRADE" ] && ff_name="HTTP+"
        path_enc=$(url_encode "$FF_PATH")
        ff_link="vless://${cur_uuid}@${IP}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${IP}&path=${path_enc}#$(url_encode "FF-${ff_name}")"
        purple "$ff_link"; echo ""; node_count=$((node_count+1))
    fi

    local socks_list
    socks_list=$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$config_dir" 2>/dev/null)
    if [ -n "$socks_list" ] && [ -n "$IP" ]; then
        while read -r line; do
            local p u pw link
            p=$(echo "$line" | jq -r '.port')
            u=$(echo "$line" | jq -r '.settings.accounts[0].user')
            pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
            link="socks5://${u}:${pw}@${IP}:${p}#$(url_encode "Socks5-${p}")"
            purple "$link"; echo ""; node_count=$((node_count+1))
        done <<< "$socks_list"
    fi

    if [ -n "$TUIC_PORT" ] && [ -n "$TUIC_DOMAIN" ]; then
        local tuic_name tuic_link
        tuic_name="Tuic"
        tuic_link="tuic://${cur_uuid}:${cur_uuid}@${TUIC_DOMAIN}:${TUIC_PORT}?congestion_control=${TUIC_CC:-bbr}&alpn=h3&sni=${TUIC_DOMAIN}&udp_relay_mode=quic&allow_insecure=0#$(url_encode "$tuic_name")"
        purple "$tuic_link"; echo ""; node_count=$((node_count+1))
    fi

    [ "$node_count" -eq 0 ] && yellow "当前没有任何节点配置"
    echo "==============================================="
}

manage_restart() {
    cls
    green "服务自动重启间隔：当前 ${RESTART_HOURS} 小时 (0=关闭)"
    prompt "请输入间隔小时（0关闭，1/2/3...）: " nh
    [[ "$nh" =~ ^[0-9]+$ ]] || { red "输入无效"; return; }

    RESTART_HOURS="$nh"
    echo "$RESTART_HOURS" > "$restart_conf"

    if [ "$RESTART_HOURS" -eq 0 ]; then
        command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab - 2>/dev/null
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

    local restart_cmd cron_exp
    restart_cmd="systemctl restart xray tunnel-argo tuic-box"
    [ -f /etc/alpine-release ] && restart_cmd="rc-service xray restart; rc-service tunnel-argo restart; rc-service tuic-box restart"
    cron_exp="0 */${RESTART_HOURS} * * *"
    (crontab -l 2>/dev/null | sed '/#svc-restart/d'; echo "${cron_exp} ${restart_cmd} >/dev/null 2>&1 #svc-restart") | crontab -
    green "已设置每 ${RESTART_HOURS} 小时重启"
}

swap_log() { echo "[$(date '+%F %T')] $*" >> "${swap_log_file}"; }
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
    if zram_supported && create_zram_swap "$size_mb"; then green "SWAP成功(ZRAM)"; return 0; fi
    if create_swapfile_dd "$size_mb"; then green "SWAP成功(dd)"; return 0; fi
    if swap_dd_should_short_circuit; then red "dd失败且不可继续"; return 1; fi
    rm -f /swapfile /tmp/swapon_err.log
    create_swapfile_fallocate "$size_mb" && green "SWAP成功(fallocate)" && return 0
    red "SWAP配置失败"; return 1
}
manage_swap() {
    while true; do
        cls
        local ram swap
        ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$ram" ] && ram=0
        swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null); [ -z "$swap" ] && swap=0

        echo -e "\033[1;36m=============== SWAP 管理 ===============\033[0m"
        echo "RAM: ${ram}MB, SWAP: ${swap}MB"
        echo "1. 添加/修改SWAP"
        echo "2. 关闭清理SWAP"
        echo "0. 返回"
        prompt "选择: " op
        case "$op" in
            1) prompt "大小MB(默认256): " sz; sz=${sz:-256}; create_swap_best_effort "$sz"; pause ;;
            2) swap_disable_all; green "已清理"; pause ;;
            0) return ;;
            *) red "无效"; pause ;;
        esac
    done
}

uninstall_component() {
    local target="$1"
    if [ "$target" = "argo" ]; then
        manage_service stop tunnel-argo 2>/dev/null
        manage_service disable tunnel-argo 2>/dev/null
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
        rm -f "${work_dir}/domain_argo.txt" "${work_dir}/tunnel_argo.yml" "${work_dir}/tunnel_argo.json" "${work_dir}/argo_start.sh"
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

        command -v crontab >/dev/null 2>&1 && (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab -
        swap_disable_all >/dev/null 2>&1 || true

        rm -rf "${work_dir}"
        green "全部组件已卸载"
        exit 0
    fi
}

modify_uuid() {
    prompt "输入新 UUID (回车自动生成): " new_uuid
    [ -z "$new_uuid" ] && new_uuid="$(cat /proc/sys/kernel/random/uuid)"

    if [ -f "${config_dir}" ]; then
        update_config --arg uuid "$new_uuid" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'
        if [ -f "${tuic_sb_conf}" ]; then
            jq --arg u "$new_uuid" '.inbounds[0].users[0].uuid=$u | .inbounds[0].users[0].password=$u' "${tuic_sb_conf}" > "${tuic_sb_conf}.tmp" && mv "${tuic_sb_conf}.tmp" "${tuic_sb_conf}"
            manage_service restart tuic-box
        fi
        manage_service restart xray
        green "UUID 已修改: ${new_uuid}"
    else
        yellow "xray配置不存在"
    fi
}

trap 'echo ""; cls; red "已中断"; exit 130' INT TERM

menu() {
    cls
    manage_packages jq wget curl iproute2 coreutils tar unzip openssl >/dev/null 2>&1
    get_sys_info
    check_system_ip

    while true; do
        cls
        local x_stat argo_stat tuic_stat
        x_stat=$(check_status "xray" "${work_dir}/${server_name}" "${work_dir}/xray")
        argo_stat=$(check_status "tunnel-argo" "${work_dir}/argo" "${work_dir}/argo tunnel")
        tuic_stat=$(check_status "tuic-box" "${tuic_sb_bin}" "${tuic_sb_bin} run")

        [ ! -f "${work_dir}/domain_argo.txt" ] && argo_stat="\033[1;91m未配置\033[0m"
        [ ! -f "${tuic_sb_conf}" ] && tuic_stat="\033[1;91m未配置\033[0m"

        cat <<EOF
OS: ${SYS_INFO_CACHE}
v4: ${WAN4:-未检出}
v6: ${WAN6:-未检出}
-----------------------------------------------
Xray: ${x_stat}
Argo: ${argo_stat}
Tuic: ${tuic_stat}
-----------------------------------------------
1. 安装Argo          2. 卸载Argo
3. 管理Socks5        4. 管理FreeFlow
5. 查看节点          6. 修改UUID
7. 定时重启(小时)    8. 管理SWAP
9. 管理Tuic(CF Token证书)
10. 彻底卸载         0. 退出
===============================================
EOF

        prompt "请输入(0-10): " c
        case "$c" in
            1) install_argo_multiplex; pause ;;
            2) uninstall_component "argo"; pause ;;
            3) manage_socks5 ;;
            4) manage_freeflow ;;
            5) get_info; pause ;;
            6) modify_uuid; pause ;;
            7) manage_restart; pause ;;
            8) manage_swap ;;
            9) manage_tuic ;;
            10) uninstall_component "all" ;;
            0) cls; exit 0 ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

menu
