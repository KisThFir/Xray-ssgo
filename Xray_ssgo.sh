#!/bin/bash

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

update_config() {
    jq "$@" "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
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

server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
freeflow_conf="${work_dir}/freeflow.conf"
restart_conf="${work_dir}/restart.conf"

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

UUID=$(generate_uuid)
CFIP=${CFIP:-'172.67.146.150'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

if [ -f "${freeflow_conf}" ]; then
    { read -r _l1; read -r _l2; } < "${freeflow_conf}"
    case "${_l1}" in
        ws|httpupgrade) FREEFLOW_MODE="${_l1}" ;;
        *)              FREEFLOW_MODE="none"   ;;
    esac
    [ -n "${_l2}" ] && FF_PATH="${_l2}"
else
    FREEFLOW_MODE="none"
    FF_PATH="/"
fi

RESTART_INTERVAL=0
[ -f "${restart_conf}" ] && RESTART_INTERVAL=$(cat "${restart_conf}" 2>/dev/null)

get_sys_info() {
    [ -n "$SYS_INFO_CACHE" ] && return
    local os_ver kernel_ver virt mem disk
    
    if [ -f /etc/alpine-release ]; then
        read -r os_ver < /etc/alpine-release 2>/dev/null
        os_ver="Alpine ${os_ver}"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$ID" ] && [ -n "$VERSION_ID" ]; then
            local os_name=$(echo "$ID" | sed -e 's/^[a-z]/\U&/')
            os_ver="${os_name} ${VERSION_ID}"
        elif [ -n "$PRETTY_NAME" ]; then
            os_ver="${PRETTY_NAME}"
        else
            os_ver="Linux"
        fi
        os_ver=$(echo "$os_ver" | sed -E 's/ \([a-zA-Z0-9_-]+\)//g')
    else
        os_ver="Linux"
    fi

    read -r kernel_ver < /proc/sys/kernel/osrelease 2>/dev/null
    kernel_ver=${kernel_ver%%[-+]*}

    if grep -qa container=lxc /proc/1/environ 2>/dev/null; then virt="LXC"
    elif [ -f /proc/user_beancounters ]; then virt="OpenVZ"
    elif [ -f /sys/class/dmi/id/product_name ]; then
        read -r virt < /sys/class/dmi/id/product_name 2>/dev/null
        virt=$(echo "$virt" | grep -ioE 'KVM|QEMU|VMware|Xen|Hyper-V' | head -n 1)
    fi
    [ -z "$virt" ] && virt="KVM"

    mem=$(awk '/MemTotal/{m=$2/1024; if(m>1024) printf"%.1fG",m/1024; else printf"%.0fM",m}' /proc/meminfo 2>/dev/null)
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')

    SYS_INFO_CACHE="${os_ver} | ${kernel_ver} | ${virt^^} | ${mem} | ${disk}"
}

# [修复] 双请求并行，加快检测速度
check_system_ip() {
    [ "$IP_CHECKED" = "1" ] && return
    local DEFAULT_LOCAL_INTERFACE4=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    local DEFAULT_LOCAL_INTERFACE6=$(ip -6 route show default 2>/dev/null | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    local BIND_ADDRESS4=""
    local BIND_ADDRESS6=""

    if [ -n "${DEFAULT_LOCAL_INTERFACE4}${DEFAULT_LOCAL_INTERFACE6}" ]; then
        local DEFAULT_LOCAL_IP4=$(ip -4 addr show $DEFAULT_LOCAL_INTERFACE4 2>/dev/null | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
        local DEFAULT_LOCAL_IP6=$(ip -6 addr show $DEFAULT_LOCAL_INTERFACE6 2>/dev/null | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
        [ -n "$DEFAULT_LOCAL_IP4" ] && BIND_ADDRESS4="--bind-address=$DEFAULT_LOCAL_IP4"
        [ -n "$DEFAULT_LOCAL_IP6" ] && BIND_ADDRESS6="--bind-address=$DEFAULT_LOCAL_IP6"
    fi

    local tmp4=$(mktemp)
    local tmp6=$(mktemp)

    wget $BIND_ADDRESS4 -4 -qO- --no-check-certificate --tries=2 --timeout=2 \
        "https://ip.cloudflare.now.cc?lang=zh-CN" > "$tmp4" 2>/dev/null &
    local pid4=$!

    wget $BIND_ADDRESS6 -6 -qO- --no-check-certificate --tries=2 --timeout=2 \
        "https://ip.cloudflare.now.cc?lang=zh-CN" > "$tmp6" 2>/dev/null &
    local pid6=$!

    wait "$pid4" "$pid6"

    local IP4_JSON=$(cat "$tmp4")
    local IP6_JSON=$(cat "$tmp6")
    rm -f "$tmp4" "$tmp6"

    if [ -n "$IP4_JSON" ]; then
        WAN4=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP4_JSON")
        COUNTRY4=$(awk -F '"' '/"country"/{print $4}' <<< "$IP4_JSON")
        EMOJI4=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP4_JSON")
        local RAW_ASN4=$(awk -F '"' '/"asn"/{print $4}' <<< "$IP4_JSON" | grep -oE '[0-9]+')
        local RAW_ISP4=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP4_JSON")
        [ -n "$RAW_ASN4" ] && AS_NUM4="AS${RAW_ASN4}" || AS_NUM4=$(echo "$RAW_ISP4" | grep -oE 'AS[0-9]+' | head -n 1)
        ISP_CLEAN4=$(echo "$RAW_ISP4" | sed -E 's/AS[0-9]+[ -]*//g' | sed -E 's/[, ]*(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|SAS|GmbH|Hosting|Host).*$//i' | sed -E 's/ *$//')
    fi

    if [ -n "$IP6_JSON" ]; then
        WAN6=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP6_JSON")
        COUNTRY6=$(awk -F '"' '/"country"/{print $4}' <<< "$IP6_JSON")
        EMOJI6=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP6_JSON")
        local RAW_ASN6=$(awk -F '"' '/"asn"/{print $4}' <<< "$IP6_JSON" | grep -oE '[0-9]+')
        local RAW_ISP6=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP6_JSON")
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

get_current_uuid() {
    if [ -f "${config_dir}" ]; then
        local id=$(jq -r '(first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "${config_dir}" 2>/dev/null)
        [ -n "$id" ] && [ "$id" != "null" ] && echo "$id" && return
    fi
    echo "${UUID}"
}

get_mem_by_svc() {
    local svc_cmd="$1"
    local pid=$(pgrep -f "$svc_cmd" | head -n 1)
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        local mem=$(grep -i VmRSS "/proc/$pid/status" | awk '{print $2}')
        if [ -n "$mem" ] && [ "$mem" -gt 0 ]; then
            awk "BEGIN {printf \"%.1fM\", $mem/1024}"
        fi
    fi
}

check_status() {
    local svc_name="$1"
    local bin_path="$2"
    local cmd_match="$3"
    [ ! -f "$bin_path" ] && printf '\033[1;91m未安装\033[0m' && return 2
    if is_service_running "$svc_name"; then
        local mem=$(get_mem_by_svc "$cmd_match")
        [ -n "$mem" ] && printf '\033[1;36m运行(%s)\033[0m' "$mem" || printf '\033[1;36m运行\033[0m'
        return 0
    fi
    printf '\033[1;91m未启动\033[0m'
    return 1
}

# [修复] 补充 coreutils 检测映射，避免每次都触发无效 apt-get update
manage_packages() {
    local need_update=1
    for package in "$@"; do
        local cmd_check
        case "$package" in
            iproute2)  cmd_check="ip"     ;;
            coreutils) cmd_check="base64" ;;
            *)         cmd_check="$package" ;;
        esac
        command -v "$cmd_check" > /dev/null 2>&1 && continue
        
        if [ "$need_update" -eq 1 ]; then
            if command -v apt-get > /dev/null 2>&1; then apt-get update -y >/dev/null 2>&1
            elif command -v apk > /dev/null 2>&1; then apk update >/dev/null 2>&1
            fi
            need_update=0
        fi

        yellow "正在安装 ${package}..."
        if   command -v apt-get > /dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1
        elif command -v dnf > /dev/null 2>&1; then dnf install -y "$package" >/dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then yum install -y "$package" >/dev/null 2>&1
        elif command -v apk > /dev/null 2>&1; then apk add "$package" >/dev/null 2>&1
        fi
    done
}

install_shortcut() {
    yellow "正在创建快捷方式..."
    local dest="/usr/local/bin/ssgo"
    cat > "$dest" << 'EOF'
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/KisThFir/Xray-ssgo/refs/heads/main/Xray_ssgo.sh) "$@"
EOF
    chmod +x "$dest"
    ln -sf "$dest" /usr/bin/ssgo 2>/dev/null
    hash -r 2>/dev/null || true
    green "快捷方式已成功创建！随时输入 ssgo 即可云端秒加载最新版脚本！"
}

init_xray_config() {
    mkdir -p "${work_dir}"
    if [ ! -f "${config_dir}" ]; then
        cat > "${config_dir}" << 'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "queryStrategy": "UseIPv4"
      }
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" },
    { "protocol": "dns", "tag": "dns-out" }
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

    local has_dns
    has_dns=$(jq 'has("dns")' "${config_dir}" 2>/dev/null)
    if [ "$has_dns" != "true" ]; then
        update_config '.dns = {"servers":[{"address":"https://1.1.1.1/dns-query","queryStrategy":"UseIPv4"}],"queryStrategy":"UseIPv4"}'
    fi

    local has_dnsout
    has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "${config_dir}" 2>/dev/null)
    if [ "$has_dnsout" != "true" ]; then
        update_config '.outbounds += [{"protocol":"dns","tag":"dns-out"}]'
    fi

    if ! jq -e '.routing' "${config_dir}" >/dev/null 2>&1; then
        update_config '.routing = {"domainStrategy":"AsIs","rules":[]}'
    fi

    local has_port53
    has_port53=$(jq '[.routing.rules[]? | select(.port=="53")] | length' "${config_dir}" 2>/dev/null)
    if [ "${has_port53:-0}" -eq 0 ]; then
        update_config '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]'
    fi
}

install_core() {
    manage_packages jq unzip curl iproute2 coreutils
    if ! command -v jq >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        red "依赖组件 (jq/unzip) 安装失败，请检查 VPS 网络或软件源！"
        exit 1
    fi
    
    mkdir -p "${work_dir}"
    
    if [ ! -f "${work_dir}/${server_name}" ]; then
        purple "下载 Xray 内核..."
        local ARCH_RAW=$(uname -m); local ARCH_ARG
        case "${ARCH_RAW}" in
            'x86_64') ARCH_ARG='64' ;;
            'aarch64'|'arm64') ARCH_ARG='arm64-v8a' ;;
            *) ARCH_ARG='32' ;;
        esac
        curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip"
        unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" > /dev/null 2>&1
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/xray.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi

    if [ ! -f "${work_dir}/argo" ]; then
        purple "下载 Cloudflared..."
        local ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
        chmod +x "${work_dir}/argo"
    fi

    if [ ! -f /etc/systemd/system/xray.service ] && ! [ -f /etc/init.d/xray ]; then
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
}

ask_freeflow_mode() {
    echo ""; green  "请选择 FreeFlow 方式："
    printf '%s\n' "-----------------------------------------------"
    green  "1. VLESS + WS （明文 WebSocket，port 80）"
    green  "2. VLESS + HTTP+ （明文 HTTPUpgrade，port 80）"
    green  "3. 不启用 FreeFlow（默认）"
    printf '%s\n' "-----------------------------------------------"
    prompt "请输入选择(1-3，回车默认3): " ff_choice

    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws"          ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none"        ;;
    esac

    if [ "${FREEFLOW_MODE}" != "none" ]; then
        prompt "请输入 FreeFlow path（回车默认 /）: " ff_path_input
        if [ -z "${ff_path_input}" ]; then
            FF_PATH="/"
        else
            case "${ff_path_input}" in /*) FF_PATH="${ff_path_input}" ;; *) FF_PATH="/${ff_path_input}" ;; esac
        fi
    else
        FF_PATH="/"
    fi

    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
    
    case "${FREEFLOW_MODE}" in
        ws) green "已选择：VLESS+WS (path=${FF_PATH})" ;;
        httpupgrade) green "已选择：VLESS+HTTP+ (path=${FF_PATH})" ;;
        none) yellow "不启用 FreeFlow" ;;
    esac
    echo ""
}

apply_freeflow_config() {
    ensure_dns_routing
    local cur_uuid=$(get_current_uuid)
    update_config 'del(.inbounds[] | select(.port == 80))'
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        # [修复] destOverride 移除非法的 "dns"
        local ff_json='{"port": 80, "listen": "::", "protocol": "vless", "settings": { "clients": [{ "id": "'${cur_uuid}'" }], "decryption": "none" }, "streamSettings": { "network": "'${FREEFLOW_MODE}'", "security": "none", "'${FREEFLOW_MODE}'Settings": { "path": "'${FF_PATH}'" } }, "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }}'
        update_config --argjson ib "${ff_json}" '.inbounds += [$ib]'
    fi
}

manage_freeflow() {
    while true; do
        cls
        local ff_display="\033[1;91m未配置\033[0m"
        if [ "${FREEFLOW_MODE}" != "none" ]; then
            local display_mode="${FREEFLOW_MODE^^}"
            [ "$display_mode" = "HTTPUPGRADE" ] && display_mode="HTTP+"
            ff_display="\033[1;32m方式: ${display_mode} (path=${FF_PATH})\033[0m"
        fi

        printf "\033[1;32m管理 FreeFlow 模块：\033[0m\n  当前配置: %b\n" "$ff_display"
        printf '%s\n' "-----------------------------------------------"
        printf "\033[1;32m 1.\033[0m \033[1;32m变更\033[0m方式    \033[1;32m 2.\033[0m \033[1;32m修改\033[0m路径\n"
        printf "\033[1;91m 3.\033[0m \033[1;91m卸载\033[0m模块    \033[1;35m 0.\033[0m \033[1;35m返回\033[0m主菜单\n"
        printf '%s\n' "==============================================="
        
        clear_buffer
        prompt "请输入选择: " choice

        case "${choice}" in
            1) cls; ask_freeflow_mode; apply_freeflow_config; manage_service restart xray; green "FreeFlow 方式已变更"; get_info; pause ;;
            2) 
                if [ "${FREEFLOW_MODE}" = "none" ]; then red "请先启用 FreeFlow！"; pause; continue; fi
                cls; prompt "请输入新 path（回车保持当前 ${FF_PATH}）: " new_path
                if [ -n "${new_path}" ]; then
                    case "${new_path}" in /*) FF_PATH="${new_path}" ;; *) FF_PATH="/${new_path}" ;; esac
                    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
                    apply_freeflow_config; manage_service restart xray; green "FreeFlow path 已修改为：${FF_PATH}"
                fi
                get_info; pause
                ;;
            3) FREEFLOW_MODE="none"; printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"; apply_freeflow_config; manage_service restart xray; green "FreeFlow 已关闭并卸载"; pause ;;
            0) return ;;
            *) red "无效的选项！"; pause ;;
        esac
    done
}

manage_socks5() {
    while true; do
        cls; printf '\033[1;33m正在读取 Socks5 配置...\033[0m\n'
        ensure_dns_routing
        local socks_list=$(jq -c '.inbounds[]? | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
        
        cls; printf '\033[1;35m                 管理 Socks5 代理              \033[0m\n'
        if [ -z "$socks_list" ]; then
            printf '  当前配置: \033[1;91m未配置\033[0m\n'
        else
            printf '%s\n' "-----------------------------------------------"
            echo "  端口    | 用户名    | 密码"
            echo "-----------------------------------------------"
            while read -r line; do
                local p=$(echo "$line" | jq -r '.port')
                local u=$(echo "$line" | jq -r '.settings.accounts[0].user')
                local pass=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                printf "  %-8s| %-10s| %s\n" "$p" "$u" "$pass"
            done <<< "$socks_list"
        fi

        printf '%s\n' "-----------------------------------------------"
        printf "\033[1;32m 1.\033[0m \033[1;32m添加\033[0m新端口  \033[1;32m 2.\033[0m \033[1;32m修改\033[0m配置\n"
        printf "\033[1;91m 3.\033[0m \033[1;91m删除\033[0m端口    \033[1;35m 0.\033[0m \033[1;35m返回\033[0m主菜单\n"
        printf '%s\n' "==============================================="
        
        clear_buffer
        prompt "请输入选择: " s_choice

        case "${s_choice}" in
            1)
                cls; install_core
                prompt "输入监听端口 (如 1080): " ns_port; prompt "输入用户名: " ns_user; prompt "输入密码: " ns_pass
                if [[ -n "$ns_port" && "$ns_port" =~ ^[0-9]+$ && -n "$ns_user" && -n "$ns_pass" ]]; then
                    # [修复] destOverride 移除非法的 "dns"
                    update_config --argjson p "$ns_port" --arg u "$ns_user" --arg pw "$ns_pass" \
                        '.inbounds += [{"tag": ("socks-" + ($p|tostring)),"port": $p,"listen": "0.0.0.0","protocol": "socks","settings": { "auth": "password", "accounts": [{ "user": $u, "pass": $pw }], "udp": true }, "sniffing": {"enabled": true, "destOverride": ["http","tls"], "metadataOnly": false}}]'
                    green "添加成功！请确保服务器防火墙已放行 $ns_port 端口。"; manage_service restart xray
                else
                    red "输入无效！端口必须为数字，且用户名和密码不能为空。"
                fi
                pause ;;
            2)
                cls; prompt "请输入要修改的端口号: " edit_port; prompt "输入新用户名: " nu; prompt "输入新密码: " np
                if [[ -n "$edit_port" && "$edit_port" =~ ^[0-9]+$ && -n "$nu" && -n "$np" ]]; then
                    update_config --argjson p "$edit_port" --arg u "$nu" --arg pw "$np" '(.inbounds[] | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user": $u, "pass": $pw}'
                    green "修改完成！"; manage_service restart xray
                else
                    red "输入无效！"
                fi
                pause ;;
            3)
                cls
                local s_list=$(jq -c '.inbounds[]? | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
                if [ -z "$s_list" ]; then
                    red "当前没有可删除的 Socks5 端口"
                    pause; continue
                fi
                echo "请选择要删除的 Socks5 端口："
                echo "-----------------------------------------------"
                local i=1
                local port_arr=()
                while read -r line; do
                    local p=$(echo "$line" | jq -r '.port')
                    echo "  ${i}. 端口 ${p}"
                    port_arr[$i]=$p
                    i=$((i+1))
                done <<< "$s_list"
                echo "  0. 取消"
                echo "-----------------------------------------------"
                clear_buffer
                prompt "请输入序号(0-$((i-1))): " del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -gt 0 ] && [ "$del_idx" -lt "$i" ]; then
                    local del_port=${port_arr[$del_idx]}
                    update_config --argjson p "$del_port" 'del(.inbounds[] | select(.protocol=="socks" and .port==$p))'
                    green "端口 $del_port 删除完成！"; manage_service restart xray
                elif [ "$del_idx" = "0" ]; then
                    yellow "已取消删除。"
                else
                    red "输入无效！"
                fi
                pause ;;
            0) break ;;
            *) red "无效选择"; pause ;;
        esac
    done
}

install_argo_multiplex() {
    cls
    install_core
    ensure_dns_routing
    
    echo ""; yellow "正在配置 Argo 路径分流 (WS + XHTTP + SS)"
    skyblue "  => VLESS+WS 本地端口: 8080 (Cloudflare 云端路径: /argo)"
    skyblue "  => VLESS+XHTTP 本地端口: 8081 (Cloudflare 云端路径: /xgo)"
    skyblue "  => SS+WS 本地端口: 8082 (Cloudflare 云端路径: /ssgo)"
    echo ""
    
    prompt "请输入你的 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && red "Argo 域名不能为空" && return 1

    prompt "请输入 Argo 密钥 (提取到的 JSON 格式凭证): " argo_auth
    [ -z "$argo_auth" ] && red "密钥不能为空" && return 1
    
    if ! echo "$argo_auth" | grep -q "TunnelSecret"; then
        red "错误：必须使用 JSON 格式的凭证！"
        return 1
    fi

    echo ""; green "------------- SS+WS 节点参数设置 --------------"
    prompt "请输入 SS 密码 (回车默认随机): " ss_pass
    [ -z "$ss_pass" ] && ss_pass=$(generate_uuid | cut -c 1-8)

    echo "选择 SS 加密方式:"
    echo "  1. aes-128-gcm (默认)"
    echo "  2. aes-256-gcm"
    prompt "请输入(1-2，回车默认1): " m_choice
    local ss_method="aes-128-gcm"
    [ "$m_choice" = "2" ] && ss_method="aes-256-gcm"

    echo "$argo_domain" > "${work_dir}/domain_argo.txt"
    local tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID' 2>/dev/null || echo "$argo_auth" | cut -d'"' -f12)
    echo "$argo_auth" > "${work_dir}/tunnel_argo.json"

    # 【强制 HTTP/2】
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

    local cur_uuid=$(get_current_uuid)
    
    update_config 'del(.inbounds[] | select(.port == 8080 or .port == 8081 or .port == 8082))'
    
    # [修复] destOverride 移除非法的 "dns"，保持其余原样
    local ws_json='{"port": 8080, "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [{"id": "'${cur_uuid}'"}], "decryption": "none"}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/argo"}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}}'
    local xhttp_json='{"port": 8081, "listen": "127.0.0.1", "protocol": "vless", "settings": {"clients": [{"id": "'${cur_uuid}'"}], "decryption": "none"}, "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"host": "", "path": "/xgo", "mode": "auto"}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}}'
    local ss_json='{"port": 8082, "listen": "127.0.0.1", "protocol": "shadowsocks", "settings": {"method": "'${ss_method}'", "password": "'${ss_pass}'", "network": "tcp,udp"}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/ssgo"}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}}'
    
    update_config --argjson ws "$ws_json" --argjson xhttp "$xhttp_json" --argjson ss "$ss_json" '.inbounds += [$ws, $xhttp, $ss]'

    local exec_cmd="${work_dir}/argo tunnel --edge-ip-version auto --no-autoupdate --config ${work_dir}/tunnel_argo.yml run"
    local svc_name="tunnel-argo"

    if [ -f /etc/alpine-release ]; then
        # 用 wrapper 脚本规避 OpenRC command_args 引号嵌套风险
        cat > "${work_dir}/argo_start.sh" << EOF
#!/bin/sh
exec ${exec_cmd}
EOF
        chmod +x "${work_dir}/argo_start.sh"
        cat > /etc/init.d/${svc_name} << EOF
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
        cat > /etc/systemd/system/${svc_name}.service << EOF
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
    manage_service enable ${svc_name}
    manage_service restart ${svc_name}
    manage_service restart xray
    
    green "Argo(WS+XHTTP+SS) 隧道分流服务部署完毕！"
    get_info
}

get_info() {
    cls
    check_system_ip
    local IP=""
    [ -n "$WAN4" ] && IP="$WAN4" || { [ -n "$WAN6" ] && IP="[$WAN6]"; }
    local cur_uuid=$(get_current_uuid)
    local node_count=0
    
    echo ""; green "=============== 当前可用节点链接 =============="

    if [ -f "${work_dir}/domain_argo.txt" ]; then
        local domain_argo=$(cat "${work_dir}/domain_argo.txt")
        
        local name_xhttp="${NODE_PREFIX} - XHTTP"
        local link_xhttp="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&alpn=h2&fp=chrome&type=xhttp&host=${domain_argo}&path=%2Fxgo#$(url_encode "$name_xhttp")"
        purple "${link_xhttp}"; echo ""; ((node_count++))
        
        local name_ws="${NODE_PREFIX} - WS"
        local link_ws="vless://${cur_uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain_argo}&fp=chrome&type=ws&host=${domain_argo}&path=%2Fargo%3Fed%3D2560#$(url_encode "$name_ws")"
        purple "${link_ws}"; echo ""; ((node_count++))

        local ss_ib=$(jq -c '.inbounds[]? | select(.protocol == "shadowsocks" and .port == 8082)' "$config_dir" 2>/dev/null)
        if [ -n "$ss_ib" ]; then
            local m=$(echo "$ss_ib" | jq -r '.settings.method')
            local pw=$(echo "$ss_ib" | jq -r '.settings.password')
            local name_ss="${NODE_PREFIX} - SS"
            
            local b64=$(echo -n "${m}:${pw}" | base64 | tr -d '\n')
            local link_ss="ss://${b64}@${CFIP}:80?type=ws&security=none&host=${domain_argo}&path=%2Fssgo#$(url_encode "$name_ss")"
            
            purple "${link_ss}"; echo ""; ((node_count++))
        fi
    fi

    if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ]; then
        local path_enc=$(printf '%s' "${FF_PATH}" | sed 's|%|%25|g; s| |%20|g')
        local ff_node_name="${FREEFLOW_MODE^^}"
        [ "$ff_node_name" = "HTTPUPGRADE" ] && ff_node_name="HTTP+"
        
        local name_ff="${NODE_PREFIX} - FF-${ff_node_name}"
        local link="vless://${cur_uuid}@${IP}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${IP}&path=${path_enc}#$(url_encode "$name_ff")"
        purple "${link}"; echo ""; ((node_count++))
    fi
    
    if [ -f "${config_dir}" ] && [ -n "$IP" ]; then
        local socks_list=$(jq -c '.inbounds[]? | select(.protocol == "socks")' "$config_dir" 2>/dev/null)
        if [ -n "$socks_list" ]; then
            while read -r line; do
                local p=$(echo "$line" | jq -r '.port'); local u=$(echo "$line" | jq -r '.settings.accounts[0].user'); local pw=$(echo "$line" | jq -r '.settings.accounts[0].pass')
                local name_socks="${NODE_PREFIX} - Socks5-${p}"
                local link="socks5://${u}:${pw}@${IP}:${p}#$(url_encode "$name_socks")"
                purple "${link}"; echo ""; ((node_count++))
            done <<< "$socks_list"
        fi
    fi
    
    [ $node_count -eq 0 ] && yellow "当前没有任何节点配置。"
    printf '%s\n' "==============================================="
}

manage_restart() {
    cls
    green "服务自动重启间隔：当前 ${RESTART_INTERVAL} 分钟 (0=关闭)"
    clear_buffer
    prompt "请输入间隔分钟（0关闭，推荐 60 的整倍数）: " new_int
    if echo "${new_int}" | grep -qE '^[0-9]+$'; then
        RESTART_INTERVAL="${new_int}"
        echo "${RESTART_INTERVAL}" > "${restart_conf}"
        if [ "${RESTART_INTERVAL}" -eq 0 ]; then
            if command -v crontab >/dev/null 2>&1; then
                (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab - 2>/dev/null
            fi
            green "服务定时重启已关闭"
        else
            if ! command -v crontab >/dev/null 2>&1 || [ -f /etc/alpine-release ]; then
                if command -v apt-get >/dev/null 2>&1; then 
                    manage_packages cron
                    manage_service enable cron 2>/dev/null; manage_service start cron 2>/dev/null
                elif command -v apk >/dev/null 2>&1; then 
                    manage_packages dcron
                    rc-service dcron start 2>/dev/null || true
                    rc-update add dcron default >/dev/null 2>&1 || true
                else 
                    manage_packages cronie
                    manage_service enable crond 2>/dev/null; manage_service start crond 2>/dev/null
                fi
            fi
            
            local restart_cmd="systemctl restart xray tunnel-argo"
            [ -f /etc/alpine-release ] && restart_cmd="rc-service xray restart; rc-service tunnel-argo restart"
            
            local cron_exp="*/${RESTART_INTERVAL} * * * *"
            if [ "${RESTART_INTERVAL}" -ge 60 ]; then
                local hours=$(( RESTART_INTERVAL / 60 ))
                cron_exp="0 */${hours} * * *"
            fi
            (crontab -l 2>/dev/null | sed '/#svc-restart/d'; echo "${cron_exp} ${restart_cmd} >/dev/null 2>&1 #svc-restart") | crontab -
            green "服务重启策略已更新"
        fi
    else
        red "输入无效，请输入纯数字！"
    fi
}

uninstall_component() {
    local target="$1"
    
    if [ "$target" = "argo" ]; then
        manage_service stop tunnel-argo
        manage_service disable tunnel-argo
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
        rm -f "${work_dir}/domain_argo.txt" "${work_dir}/tunnel_argo.yml" "${work_dir}/tunnel_argo.json"
        rm -f "${work_dir}/argo_start.sh" "${work_dir}/argo_dual.log"
        [ -f "${config_dir}" ] && update_config 'del(.inbounds[] | select(.port == 8080 or .port == 8081 or .port == 8082))'
        green "Argo (WS+XHTTP+SS) 已卸载关闭！"
        manage_service restart xray
    fi

    if [ "$target" = "all" ]; then
        manage_service stop tunnel-argo
        manage_service disable tunnel-argo
        rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
        
        manage_service stop xray
        manage_service disable xray
        rm -f /etc/init.d/xray /etc/systemd/system/xray.service
        
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null | sed '/#svc-restart/d') | crontab -
        fi
        
        rm -rf "${work_dir}" /usr/bin/ssgo /usr/local/bin/ssgo
        green "所有组件及定时任务已彻底卸载完成！"
        exit 0
    fi
}

modify_uuid() {
    prompt "输入新 UUID (回车自动生成): " new_uuid
    [ -z "$new_uuid" ] && new_uuid=$(generate_uuid)
    if [ -f "${config_dir}" ]; then
        update_config --arg uuid "$new_uuid" '(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) |= $uuid'
        manage_service restart xray; green "UUID 已修改为: $new_uuid"
        echo ""
        get_info
    else
        yellow "配置文件不存在，请先安装节点"
    fi
}

trap 'echo ""; cls; red "已中断"; exit 130' INT TERM

menu() {
    cls; printf '\033[1;33m正在初始化系统信息与网络检测，请稍候...\033[0m\n'
    get_sys_info
    check_system_ip

    while true; do
        cls; printf '\033[1;33m正在刷新系统状态...\033[0m\n'

        local x_stat=$(check_status "xray" "${work_dir}/${server_name}" "${work_dir}/xray")
        local argo_stat=$(check_status "tunnel-argo" "${work_dir}/argo" "${work_dir}/argo tunnel")
        
        [ ! -f "${work_dir}/domain_argo.txt" ] && argo_stat="\033[1;91m未配置\033[0m"

        local len4=${#WAN4}
        local len6=${#WAN6}
        local pad_len=$(( len4 > len6 ? len4 : len6 ))
        [ -z "$pad_len" ] && pad_len=0
        
        local ip4_disp="\033[1;91m未检出\033[0m"
        if [ -n "$WAN4" ]; then
            local pad_v4=$(printf "%-${pad_len}s" "$WAN4")
            ip4_disp="\033[1;36m${pad_v4}  (${COUNTRY4} ${AS_NUM4} ${ISP_CLEAN4})\033[0m"
        fi
        
        local ip6_disp="\033[1;91m未检出\033[0m"
        if [ -n "$WAN6" ]; then
            local pad_v6=$(printf "%-${pad_len}s" "$WAN6")
            ip6_disp="\033[1;36m${pad_v6}  (${COUNTRY6} ${AS_NUM6} ${ISP_CLEAN6})\033[0m"
        fi

        local menu_text="OS: \033[1;36m${SYS_INFO_CACHE}\033[0m
v4: ${ip4_disp}
v6: ${ip6_disp}
-----------------------------------------------
  Xray: ${x_stat}    |    Argo: ${argo_stat}
-----------------------------------------------
\033[1;32m 1.\033[0m 安装\033[1;36mArgo\033[0m
\033[1;91m 2.\033[0m \033[1;91m卸载\033[0m\033[1;36mArgo\033[0m
\033[1;32m 3.\033[0m 管理\033[1;33mS5\033[0m        \033[1;32m 4.\033[0m 管理\033[1;33mFF\033[0m
\033[1;32m 5.\033[0m 查看\033[1;36m节点\033[0m      \033[1;32m 6.\033[0m 修改\033[1;36mUUID\033[0m
\033[1;32m 7.\033[0m 定时\033[1;33m重启\033[0m      \033[1;32m 8.\033[0m 创建\033[1;33m快捷\033[0m
\033[1;91m 9.\033[0m 彻底\033[1;91m卸载\033[0m      \033[1;35m 0.\033[0m 安全\033[1;35m退出\033[0m
==============================================="

        cls; printf '%b\n' "$menu_text"

        clear_buffer
        prompt "请输入(0-9): " choice

        case "${choice}" in
            1) cls; install_argo_multiplex; pause ;;
            2) cls; uninstall_component "argo"; pause ;;
            3) manage_socks5 ;;
            4) manage_freeflow ;;
            5) cls; get_info; pause ;;
            6) cls; modify_uuid; pause ;;
            7) manage_restart; pause ;;
            8) cls; install_shortcut; pause ;;
            9) cls; uninstall_component "all" ;;
            0) cls; exit 0 ;;
            *) red "无效选项"; pause ;;
        esac
    done
}

menu
