#!/bin/bash
# --- 专属配置 ---
DNS_GOST_CONFIG_PATH="/etc/gost/dns-unlock-config.yml"
DNS_GOST_SERVICE_NAME="gost-dns.service"
DNS_GOST_SERVICE_PATH="/etc/systemd/system/${DNS_GOST_SERVICE_NAME}"
DNS_STATE_DIR="/var/lib/ai-scripts/dns-unlock"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# --- 安全检查: 确保以 root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：本脚本需要以 root 权限运行。${NC}"
   echo -e "${GREEN}请尝试使用: sudo bash $0${NC}"
   exit 1
fi


# ======================= 帮助函数 =======================

# 检测并自动安装iptables
check_and_install_iptables() {
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}警告: iptables 未安装，正在自动安装...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
        if command -v iptables &>/dev/null; then
            echo -e "${GREEN}成功: iptables 已成功安装。${NC}"
        else
            echo -e "${RED}错误: iptables 安装失败，某些功能可能无法使用。${NC}"
            return 1
        fi
    fi
    return 0
}

check_port_53() {
    if ! command -v lsof &> /dev/null; then apt-get update >/dev/null 2>&1 && apt-get install -y lsof >/dev/null; fi
    local port_pids process_name
    port_pids=$( { lsof -nP -iTCP:53 -sTCP:LISTEN -t 2>/dev/null; lsof -nP -iUDP:53 -t 2>/dev/null; } | sort -u)
    if [[ -n $port_pids ]]; then
        process_name=$(ps -p "$(head -n1 <<< "$port_pids")" -o comm=)

        if [[ "$process_name" == "systemd-resolve" ]]; then
            echo -e "${YELLOW}警告: 端口 53 (DNS) 已被系统服务 'systemd-resolved' 占用。${NC}"
            read -p "是否允许脚本自动禁用该服务并修复DNS配置? (Y/n): " choice
            if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
                echo -e "${BLUE}信息: 正在停止并禁用 systemd-resolved...${NC}"
                systemctl disable --now systemd-resolved
                sleep 2 # 等待端口释放

                # 修复由 systemd-resolved 管理的 /etc/resolv.conf
                if [ -L /etc/resolv.conf ]; then
                    echo -e "${BLUE}信息: /etc/resolv.conf 是一个符号链接，正在重新创建它以确保服务器网络正常...${NC}"
                    rm /etc/resolv.conf
                    echo "nameserver 8.8.8.8" > /etc/resolv.conf
                    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
                    echo -e "${GREEN}成功: /etc/resolv.conf 已修复。${NC}"
                fi

                # 再次检查端口是否已释放
                if lsof -nP -iTCP:53 -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iUDP:53 >/dev/null 2>&1; then
                    echo -e "${RED}错误: 端口 53 仍然被占用，请手动检查。${NC}"
                    return 1
                fi
                echo -e "${GREEN}成功: 端口 53 冲突已解决。${NC}"
                return 0
            else
                echo -e "${RED}错误: 操作已取消。请手动禁用 systemd-resolved (sudo systemctl disable --now systemd-resolved) 后重试。${NC}"
                return 1
            fi
        fi

        echo -e "${YELLOW}警告: 端口 53 (DNS) 已被进程 '${process_name}' 占用。${NC}"
        if [[ "$process_name" != "dnsmasq" ]]; then
            echo -e "${RED}错误: 请先停止 '${process_name}' 服务后再试。${NC}"
            return 1
        fi
    fi
    return 0
}

check_ports_80_443() {
    if ! command -v lsof &> /dev/null; then apt-get update >/dev/null 2>&1 && apt-get install -y lsof >/dev/null; fi
    for port in 80 443; do
        if lsof -i :${port} -sTCP:LISTEN -P -n >/dev/null; then
            local process_name
            process_name=$(ps -p "$(lsof -i :${port} -sTCP:LISTEN -P -n -t)" -o comm=)
            if [[ "$process_name" != "gost" ]]; then
                echo -e "${YELLOW}警告: 端口 ${port} 已被进程 '${process_name}' 占用。${NC}"
                echo -e "${RED}这可能与 Nginx, Apache 或 Caddy 等常用Web服务冲突。请确保您已了解此情况。${NC}"
                echo -e "${RED}继续安装也无法绑定端口；请先调整该服务后重试。${NC}"
                return 1
            fi
        fi
    done
    return 0
}


# ======================= 客户端辅助函数 =======================

disable_systemd_resolved_if_running() {
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${YELLOW}警告: 检测到 systemd-resolved 正在运行，可能拦截 127.0.0.53:53。${NC}"
        read -p "是否禁用并停止 systemd-resolved，并解除 /etc/resolv.conf 软链接? (Y/n): " choice
        if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
            systemctl disable --now systemd-resolved
            # 若 resolv.conf 为软链接，则移除并创建普通文件
            if [ -L /etc/resolv.conf ]; then
                rm -f /etc/resolv.conf
                touch /etc/resolv.conf
            fi
            echo -e "${GREEN}成功: 已禁用 systemd-resolved。${NC}"
        else
            echo -e "${YELLOW}提示: 已跳过禁用 systemd-resolved，可能导致 DNS 配置被覆盖或劫持。${NC}"
        fi
    fi
}

backup_dns_client_state() {
    install -d -m 700 "$DNS_STATE_DIR/client"
    if [[ ! -e "$DNS_STATE_DIR/client/state-recorded" ]]; then
        if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
            cp -a /etc/resolv.conf "$DNS_STATE_DIR/client/resolv.conf"
        else
            touch "$DNS_STATE_DIR/client/resolv-was-absent"
        fi
        systemctl is-enabled --quiet systemd-resolved 2>/dev/null && touch "$DNS_STATE_DIR/client/resolved-enabled"
        systemctl is-active --quiet systemd-resolved 2>/dev/null && touch "$DNS_STATE_DIR/client/resolved-active"
        if [[ -e /etc/gai.conf ]]; then
            cp -a /etc/gai.conf "$DNS_STATE_DIR/client/gai.conf"
        else
            touch "$DNS_STATE_DIR/client/gai-was-absent"
        fi
        touch "$DNS_STATE_DIR/client/state-recorded"
    fi
}

set_resolv_conf() {
    local server_ip="$1"
    echo -e "${BLUE}信息: 正在备份当前的 DNS 配置...${NC}"
    backup_dns_client_state
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
    fi
    echo -e "${BLUE}信息: 正在写入新的 DNS 配置 (nameserver ${server_ip})...${NC}"
    printf "nameserver %s\n" "$server_ip" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    printf '%s\n' "$server_ip" > "$DNS_STATE_DIR/client/server-ip"
    echo -e "${GREEN}成功: /etc/resolv.conf 已更新；未设置不可变属性，方便 DHCP/VPN 管理和回滚。${NC}"
}

ensure_ipv4_preference() {
    echo -e "${BLUE}信息: 正在设置系统优先使用 IPv4（/etc/gai.conf）...${NC}"
    if [ -f /etc/gai.conf ]; then
        if grep -qE '^\s*#\s*precedence ::ffff:0:0/96 100' /etc/gai.conf; then
            sed -i 's/^\s*#\s*precedence ::ffff:0:0\/96 100/precedence ::ffff:0:0\/96 100/' /etc/gai.conf
        elif ! grep -qE '^\s*precedence ::ffff:0:0/96 100' /etc/gai.conf; then
            echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
        fi
    else
        echo 'precedence ::ffff:0:0/96 100' > /etc/gai.conf
    fi
    echo -e "${GREEN}成功: 已设置 IPv4 优先。${NC}"
}

# 使用iptables阻断IPv6关键端口
block_ipv6_ports() {
    echo -e "${BLUE}信息: 正在使用ip6tables阻断IPv6端口以防止解锁绕过...${NC}"
    
    # 检查ip6tables是否可用
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}警告: ip6tables未安装，正在安装...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
    fi
    
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${RED}错误: 无法安装ip6tables，跳过IPv6阻断。${NC}"
        return 1
    fi
    
    # 仅阻断 IPv6 DNS，避免影响服务器的 IPv6 HTTP/HTTPS/QUIC 流量。
    local port=53
    for proto in tcp udp; do
        # 检查规则是否已存在
        if ! ip6tables -C OUTPUT -p "${proto}" --dport "${port}" -m comment --comment "dns-unlock-block-ipv6" -j REJECT &>/dev/null; then
            ip6tables -I OUTPUT -p "${proto}" --dport "${port}" -m comment --comment "dns-unlock-block-ipv6" -j REJECT
            echo -e "${GREEN}已阻断IPv6 ${proto^^}/${port}端口${NC}"
        fi
    done
    
    # 持久化规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}IPv6阻断规则已持久化。${NC}"
    fi
    
    echo -e "${GREEN}成功: IPv6关键端口已阻断，防止绕过DNS解锁。${NC}"
    return 0
}

# 移除IPv6端口阻断规则
unblock_ipv6_ports() {
    echo -e "${BLUE}信息: 正在移除IPv6端口阻断规则...${NC}"
    
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}提示: ip6tables未安装，跳过。${NC}"
        return 0
    fi
    
    # 移除所有带dns-unlock-block-ipv6标记的规则
    while ip6tables -L OUTPUT -n --line-numbers | grep -q "dns-unlock-block-ipv6"; do
        local line_num
        line_num=$(ip6tables -L OUTPUT -n --line-numbers | grep "dns-unlock-block-ipv6" | head -1 | awk '{print $1}')
        if [[ -n "$line_num" ]]; then
            ip6tables -D OUTPUT "$line_num"
        else
            break
        fi
    done
    
    # 持久化规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}成功: IPv6端口阻断规则已移除。${NC}"
    return 0
}

enforce_dns_only_to_server() {
    local server_ip="$1"
    echo -e "${BLUE}信息: 正在应用防火墙规则，优先 DNS 发往 ${server_ip}...${NC}"
    # 自动检测并安装iptables
    if ! check_and_install_iptables; then
        echo -e "${RED}错误: iptables 不可用，无法应用 DNS 优先规则。${NC}"
        return 1
    fi
    for proto in udp tcp; do
        if ! iptables -C OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT &>/dev/null; then
            iptables -I OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT
        fi
        if ! iptables -C OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT &>/dev/null; then
            iptables -A OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT
        fi
    done
    printf '%s\n' "$server_ip" > "$DNS_STATE_DIR/client/enforced-server-ip"
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}成功: 防火墙规则已持久化。${NC}"
    fi
}

revert_dns_enforcement_rules() {
    echo -e "${BLUE}信息: 正在移除由脚本添加的 DNS 优先规则...${NC}"
    # 检查iptables是否可用
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}警告: iptables 未安装，跳过规则移除。${NC}"
        return 0
    fi
    local server_ip=""
    [[ -f "$DNS_STATE_DIR/client/enforced-server-ip" ]] && server_ip=$(<"$DNS_STATE_DIR/client/enforced-server-ip")
    for proto in udp tcp; do
        if [[ -n "$server_ip" ]] && iptables -C OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT &>/dev/null; then
            iptables -D OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT
        fi
        # 清理可能残留的旧版本REJECT规则
        while iptables -C OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT &>/dev/null; do
            iptables -D OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT || break
        done
    done
    rm -f "$DNS_STATE_DIR/client/enforced-server-ip"
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}成功: 防火墙规则变更已持久化。${NC}"
    fi
}


# ======================= 核心功能函数 =======================

validate_ipv4_or_cidr() {
    local value=$1 ip prefix part
    ip=${value%/*}
    prefix=${value#*/}
    [[ $value == */* ]] || prefix=32
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ $prefix =~ ^[0-9]+$ ]] && (( 10#$prefix <= 32 )) || return 1
    IFS=. read -r -a octets <<< "$ip"
    for part in "${octets[@]}"; do (( 10#$part <= 255 )) || return 1; done
}

configure_dns_unlock_access() {
    check_and_install_iptables || return 1
    install -d -m 700 "$DNS_STATE_DIR/server"
    [[ -f "$DNS_STATE_DIR/server/iptables.before" ]] || iptables-save > "$DNS_STATE_DIR/server/iptables.before"

    local chain=AI_DNS_UNLOCK_ACCESS allowed item
    iptables -N "$chain" 2>/dev/null || true
    iptables -F "$chain"
    iptables -C INPUT -j "$chain" 2>/dev/null || iptables -I INPUT -m comment --comment dns-unlock-access -j "$chain"
    iptables -A "$chain" -s 127.0.0.0/8 -j RETURN
    iptables -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    echo -e "${YELLOW}请输入允许访问 DNS 解锁服务的客户端 IPv4/CIDR（空格分隔）。${NC}"
    echo -e "${YELLOW}留空将只允许本机，防止服务成为公网开放 DNS/转发器。${NC}"
    read -r -p '允许列表: ' allowed
    for item in $allowed; do
        if validate_ipv4_or_cidr "$item"; then
            iptables -A "$chain" -s "$item" -p tcp -m multiport --dports 53,80,443 -j RETURN
            iptables -A "$chain" -s "$item" -p udp --dport 53 -j RETURN
        else
            echo -e "${YELLOW}跳过无效地址：$item${NC}"
        fi
    done
    iptables -A "$chain" -p tcp -m multiport --dports 53,80,443 -j DROP
    iptables -A "$chain" -p udp --dport 53 -j DROP
    iptables -A "$chain" -j RETURN
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

restore_dns_server_snapshot() {
    local state="$DNS_STATE_DIR/server"
    if [[ -f "$state/gost-config.before" ]]; then cp -a "$state/gost-config.before" "$DNS_GOST_CONFIG_PATH"; else rm -f "$DNS_GOST_CONFIG_PATH"; fi
    if [[ -f "$state/gost-service.before" ]]; then cp -a "$state/gost-service.before" "$DNS_GOST_SERVICE_PATH"; else rm -f "$DNS_GOST_SERVICE_PATH"; fi
    if [[ -f "$state/dnsmasq.conf.before" ]]; then cp -a "$state/dnsmasq.conf.before" /etc/dnsmasq.conf; fi
    if [[ -f "$state/custom-unlock.before" ]]; then cp -a "$state/custom-unlock.before" /etc/dnsmasq.d/custom_unlock.conf; else rm -f /etc/dnsmasq.d/custom_unlock.conf; fi
    if [[ -e "$state/resolv.conf.before" || -L "$state/resolv.conf.before" ]]; then
        rm -f /etc/resolv.conf
        cp -a "$state/resolv.conf.before" /etc/resolv.conf
    elif [[ -e "$state/no-resolv-conf" ]]; then
        rm -f /etc/resolv.conf
    fi
    systemctl daemon-reload
    if [[ -e "$state/gost-service-enabled" ]]; then systemctl enable "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; else systemctl disable "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; fi
    if [[ -e "$state/gost-service-active" ]]; then systemctl restart "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; else systemctl stop "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; fi
    if [[ -e "$state/resolved-enabled" ]]; then systemctl enable systemd-resolved 2>/dev/null || true; else systemctl disable systemd-resolved 2>/dev/null || true; fi
    if [[ -e "$state/resolved-active" ]]; then systemctl start systemd-resolved 2>/dev/null || true; else systemctl stop systemd-resolved 2>/dev/null || true; fi
    dnsmasq --test >/dev/null 2>&1 && systemctl restart dnsmasq 2>/dev/null || true
}

dns_unlock_menu() {
    while true; do
        clear
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${YELLOW}           DNS 解锁服务管理           ${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo " --- 服务端管理 ---"
        echo "  1. 安装/更新 DNS 解锁服务"
        echo "  2. 卸载 DNS 解锁服务"
        echo "  3. 管理 IP 白名单 (防火墙)"
        echo
        echo " --- 客户端管理 ---"
        echo "  4. 设置本机为 DNS 客户端"
        echo "  5. 还原客户端 DNS 设置"
        echo "  6. 管理IPv6端口阻断（防绕过）"
        echo " --------------------------------------------"
        echo "  0. 退出脚本"
        echo -e "${BLUE}=============================================${NC}"
        read -p "请输入选项 [0-6]: " choice

        case $choice in
            1) install_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            2) uninstall_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            3) manage_iptables_rules ;;
            4) setup_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            5) uninstall_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            6) manage_ipv6_blocking ;;  
            0) break ;;
            *) echo -e "${RED}无效选项，请重新输入!${NC}"; sleep 2 ;;
        esac
    done
}

install_dns_unlock_server() {
    clear
    echo -e "${YELLOW}--- DNS解锁服务 安装/更新 ---${NC}"

    echo -e "${BLUE}信息: 正在安装/检查核心依赖...${NC}"
    apt-get update >/dev/null 2>&1
    install -d -m 700 "$DNS_STATE_DIR/server"
    # 首次安装时建立基线快照；重复更新不能覆盖真正的安装前状态。
    if [[ ! -e "$DNS_STATE_DIR/server/snapshot-complete" ]]; then
        local dnsmasq_preexisting=no
        dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed' && dnsmasq_preexisting=yes
        [[ $dnsmasq_preexisting == yes ]] && touch "$DNS_STATE_DIR/server/dnsmasq-preexisting"
        [[ -f /etc/dnsmasq.conf ]] && cp -a /etc/dnsmasq.conf "$DNS_STATE_DIR/server/dnsmasq.conf.before" 2>/dev/null || touch "$DNS_STATE_DIR/server/no-dnsmasq-conf"
        [[ -f /etc/dnsmasq.d/custom_unlock.conf ]] && cp -a /etc/dnsmasq.d/custom_unlock.conf "$DNS_STATE_DIR/server/custom-unlock.before" || touch "$DNS_STATE_DIR/server/no-custom-unlock"
        [[ -f "$DNS_GOST_CONFIG_PATH" ]] && cp -a "$DNS_GOST_CONFIG_PATH" "$DNS_STATE_DIR/server/gost-config.before" || touch "$DNS_STATE_DIR/server/no-gost-config"
        [[ -f "$DNS_GOST_SERVICE_PATH" ]] && cp -a "$DNS_GOST_SERVICE_PATH" "$DNS_STATE_DIR/server/gost-service.before" || touch "$DNS_STATE_DIR/server/no-gost-service"
        [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]] && cp -a /etc/resolv.conf "$DNS_STATE_DIR/server/resolv.conf.before" || touch "$DNS_STATE_DIR/server/no-resolv-conf"
        systemctl is-active --quiet systemd-resolved 2>/dev/null && touch "$DNS_STATE_DIR/server/resolved-active"
        systemctl is-enabled --quiet systemd-resolved 2>/dev/null && touch "$DNS_STATE_DIR/server/resolved-enabled"
        systemctl is-active --quiet "$DNS_GOST_SERVICE_NAME" 2>/dev/null && touch "$DNS_STATE_DIR/server/gost-service-active"
        systemctl is-enabled --quiet "$DNS_GOST_SERVICE_NAME" 2>/dev/null && touch "$DNS_STATE_DIR/server/gost-service-enabled"
        touch "$DNS_STATE_DIR/server/snapshot-complete"
    fi
    apt-get install -y dnsmasq curl wget lsof tar file >/dev/null 2>&1
    if ! check_port_53; then return 1; fi
    if ! check_ports_80_443; then return 1; fi

    echo -e "${BLUE}信息: 正在清理旧环境...${NC}"
    systemctl stop "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    # 不卸载 sniproxy，也不删除其他脚本的 dnsmasq 配置。
    echo

    # --- 智能检查Gost是否已安装 ---
    local GOST_EXEC_PATH
    GOST_EXEC_PATH=$(command -v gost)

    if [[ -n "$GOST_EXEC_PATH" ]]; then
        echo -e "${GREEN}检测到 Gost 已安装: ${GOST_EXEC_PATH} ($(${GOST_EXEC_PATH} -V))${NC}"
        echo -e "${BLUE}信息: 将使用现有版本，跳过安装步骤。${NC}"
    else
        echo -e "${BLUE}信息: 正在安装最新版 Gost ...${NC}"
        LATEST_GOST_VERSION=$(curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/go-gost/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' | head -1)
        local gost_version=$LATEST_GOST_VERSION
        if [[ ! "$gost_version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
            echo -e "${RED}错误: 无法解析 Gost 最新正式版，不使用固定版本回退。${NC}"
            return 1
        fi
        local bit
        bit=$(uname -m)
        case "$bit" in
            x86_64|amd64) bit="amd64" ;;
            aarch64|arm64) bit="arm64" ;;
            *) echo -e "${RED}错误: 不支持的架构 $bit（仅支持 amd64/arm64）。${NC}"; return 1 ;;
        esac
        local FILENAME="gost_${gost_version}_linux_${bit}.tar.gz"
        local GOST_URL="https://github.com/go-gost/gost/releases/download/v${gost_version}/${FILENAME}"
        local gost_tmp archive extracted_gost
        gost_tmp=$(mktemp -d /tmp/ai-dns-gost.XXXXXX) || return 1
        archive="$gost_tmp/$FILENAME"

        echo "信息: 正在从以下地址下载Gost (v${gost_version}):"
        echo "${GOST_URL}"
        if ! curl -fL --connect-timeout 10 --max-time 120 -o "$archive" "${GOST_URL}"; then
            echo -e "${RED}错误: Gost 下载失败！${NC}"
            rm -rf -- "$gost_tmp"
            return 1
        fi

        if ! file "$archive" | grep -q 'gzip compressed data' \
            || ! tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ { bad=1 } END { exit bad }'; then
            echo -e "${RED}错误: 下载文件不是安全、有效的压缩包。${NC}"
            rm -rf -- "$gost_tmp"
            return 1
        fi

        tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$gost_tmp" || { echo -e "${RED}错误: Gost解压失败！${NC}"; rm -rf -- "$gost_tmp"; return 1; }
        extracted_gost=$(find "$gost_tmp" -type f -name gost -print -quit)
        [[ -n "$extracted_gost" ]] || { echo -e "${RED}错误: 压缩包内没有 gost。${NC}"; rm -rf -- "$gost_tmp"; return 1; }
        install -m 0755 "$extracted_gost" /usr/local/bin/gost || { echo -e "${RED}错误: 安装 gost 失败。${NC}"; rm -rf -- "$gost_tmp"; return 1; }
        rm -rf -- "$gost_tmp"
        touch "$DNS_STATE_DIR/server/gost-installed-by-script"
        GOST_EXEC_PATH="/usr/local/bin/gost" # 更新路径变量
        
        if ! command -v gost &> /dev/null; then 
            echo -e "${RED}错误: Gost 安装最终失败，未知错误。${NC}"
            return 1
        else
            echo -e "${GREEN}成功: Gost (v${gost_version}) 已成功安装。版本：$(gost -V)${NC}"
        fi
    fi
    echo

    echo -e "${BLUE}信息: 正在为DNS解锁服务创建 Gost 配置文件 (YAML)...${NC}"
    mkdir -p /etc/gost

    # --- Gost 配置说明 ---
    # 本脚本中，Gost 的角色是 HTTP (80) 和 HTTPS (443) 的透明流量转发器。
    # 它不处理 DNS (53) 请求，该任务由 Dnsmasq 完成。
    # 因此，配置文件中只有 80 和 443 端口的监听服务。
    tee "${DNS_GOST_CONFIG_PATH}" > /dev/null <<'EOT'
services:
- name: "dns-unlock-http-80"
  addr: ":80"
  listener:
    type: "tcp"
  handler:
    type: "forward"
  forwarder:
    nodes:
    - name: "forwarder-80"
      addr: "{host}:80"
- name: "dns-unlock-https-443"
  addr: ":443"
  listener:
    type: "tcp"
  handler:
    type: "sni" # 使用SNI模式来解析TLS流量的目标域名
  forwarder:
    nodes:
    - name: "forwarder-443"
      addr: "{host}:{port}"
resolvers:
- name: "google-dns"
  addr: "8.8.8.8:53"
  protocol: "udp"
EOT

    echo -e "${BLUE}信息: 正在创建Systemd服务 (${DNS_GOST_SERVICE_NAME})...${NC}"
    # 使用检测到的或新安装的gost路径，确保兼容性
    tee "${DNS_GOST_SERVICE_PATH}" > /dev/null <<EOT
[Unit]
Description=GOST DNS Unlock Service
After=network.target

[Service]
Type=simple
ExecStart=${GOST_EXEC_PATH} -C ${DNS_GOST_CONFIG_PATH}
Restart=always
User=root
StandardOutput=journal
StandardError=journal
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOT

    systemctl daemon-reload && systemctl enable "${DNS_GOST_SERVICE_NAME}" && systemctl restart "${DNS_GOST_SERVICE_NAME}"
    if systemctl is-active --quiet "${DNS_GOST_SERVICE_NAME}"; then
        echo -e "${GREEN}成功: Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME}) 已成功启动。${NC}"
    else
        echo -e "${RED}错误: Gost DNS解锁服务启动失败，正在恢复安装前配置。${NC}"
        restore_dns_server_snapshot
        return 1
    fi
    echo

    echo -e "${BLUE}信息: 正在创建 Dnsmasq 子配置文件...${NC}"
    PUBLIC_IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || curl -4fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip)
    if [[ -z "$PUBLIC_IP" ]]; then echo -e "${RED}错误: 无法获取公网IP地址。${NC}"; return 1; fi
    
    DNSMASQ_CONFIG_FILE="/etc/dnsmasq.d/custom_unlock.conf"
    # 可选：启用 AAAA 过滤，防止 IPv6 泄漏（默认启用）
    read -p "是否在服务端启用 AAAA 过滤（filter-aaaa）以防 IPv6 泄漏？(Y/n): " enable_filter_aaaa
    local FILTER_AAAA_LINE=""
    if [[ "$enable_filter_aaaa" =~ ^[yY]$ ]] || [[ -z "$enable_filter_aaaa" ]]; then FILTER_AAAA_LINE="filter-aaaa"; fi
    
    tee "$DNSMASQ_CONFIG_FILE" > /dev/null <<EOF
# --- DNSMASQ CONFIG MODULE MANAGED BY SCRIPT ---
# General Settings
domain-needed
bogus-priv
no-resolv
no-poll
all-servers
$FILTER_AAAA_LINE
cache-size=2048
local-ttl=60
# Listen on all interfaces; restrict public access with the whitelist menu below.
interface=*
# Upstream DNS Servers
server=8.8.8.8
server=1.1.1.1
# --- Unlock Rules (All resolve to this server's IP: ${PUBLIC_IP}) ---
address=/akadns.net/${PUBLIC_IP}
address=/akam.net/${PUBLIC_IP}
address=/akamai.com/${PUBLIC_IP}
address=/akamai.net/${PUBLIC_IP}
address=/akamaiedge.net/${PUBLIC_IP}
address=/akamaihd.net/${PUBLIC_IP}
address=/akamaistream.net/${PUBLIC_IP}
address=/akamaitech.net/${PUBLIC_IP}
address=/akamaitechnologies.com/${PUBLIC_IP}
address=/akamaitechnologies.fr/${PUBLIC_IP}
address=/akamaized.net/${PUBLIC_IP}
address=/edgekey.net/${PUBLIC_IP}
address=/edgesuite.net/${PUBLIC_IP}
address=/srip.net/${PUBLIC_IP}
address=/footprint.net/${PUBLIC_IP}
address=/level3.net/${PUBLIC_IP}
address=/llnwd.net/${PUBLIC_IP}
address=/edgecastcdn.net/${PUBLIC_IP}
address=/cloudfront.net/${PUBLIC_IP}
address=/netflix.com/${PUBLIC_IP}
address=/netflix.net/${PUBLIC_IP}
address=/nflximg.com/${PUBLIC_IP}
address=/nflximg.net/${PUBLIC_IP}
address=/nflxvideo.net/${PUBLIC_IP}
address=/nflxso.net/${PUBLIC_IP}
address=/nflxext.com/${PUBLIC_IP}
address=/hulu.com/${PUBLIC_IP}
address=/huluim.com/${PUBLIC_IP}
address=/hbo.com/${PUBLIC_IP}
address=/hbonow.com/${PUBLIC_IP}
address=/hbomax.com/${PUBLIC_IP}
address=/hbomaxcdn.com/${PUBLIC_IP}
address=/hboasia.com/${PUBLIC_IP}
address=/hbogoasia.com/${PUBLIC_IP}
address=/max.com/${PUBLIC_IP}
address=/warnermediacdn.com/${PUBLIC_IP}
address=/wmcdp.io/${PUBLIC_IP}
address=/ngtv.io/${PUBLIC_IP}
address=/pypestream.com/${PUBLIC_IP}
address=/arkoselabs.com/${PUBLIC_IP}
address=/amazon.com/${PUBLIC_IP}
address=/amazon.co.uk/${PUBLIC_IP}
address=/amazonvideo.com/${PUBLIC_IP}
address=/crackle.com/${PUBLIC_IP}
address=/pandora.com/${PUBLIC_IP}
address=/vudu.com/${PUBLIC_IP}
address=/blinkbox.com/${PUBLIC_IP}
address=/abc.com/${PUBLIC_IP}
address=/fox.com/${PUBLIC_IP}
address=/theplatform.com/${PUBLIC_IP}
address=/nbc.com/${PUBLIC_IP}
address=/nbcuni.com/${PUBLIC_IP}
address=/ip2location.com/${PUBLIC_IP}
address=/pbs.org/${PUBLIC_IP}
address=/warnerbros.com/${PUBLIC_IP}
address=/southpark.cc.com/${PUBLIC_IP}
address=/cbs.com/${PUBLIC_IP}
address=/brightcove.com/${PUBLIC_IP}
address=/cwtv.com/${PUBLIC_IP}
address=/spike.com/${PUBLIC_IP}
address=/go.com/${PUBLIC_IP}
address=/mtv.com/${PUBLIC_IP}
address=/mtvnservices.com/${PUBLIC_IP}
address=/playstation.net/${PUBLIC_IP}
address=/uplynk.com/${PUBLIC_IP}
address=/maxmind.com/${PUBLIC_IP}
address=/disney.com/${PUBLIC_IP}
address=/disneyjunior.com/${PUBLIC_IP}
address=/adobedtm.com/${PUBLIC_IP}
address=/bam.nr-data.net/${PUBLIC_IP}
address=/bamgrid.com/${PUBLIC_IP}
address=/braze.com/${PUBLIC_IP}
address=/cdn.optimizely.com/${PUBLIC_IP}
address=/cdn.registerdisney.go.com/${PUBLIC_IP}
address=/cws.conviva.com/${PUBLIC_IP}
address=/d9.flashtalking.com/${PUBLIC_IP}
address=/disney-plus.net/${PUBLIC_IP}
address=/disney-portal.my.onetrust.com/${PUBLIC_IP}
address=/disney.demdex.net/${PUBLIC_IP}
address=/disney.my.sentry.io/${PUBLIC_IP}
address=/disneyplus.bn5x.net/${PUBLIC_IP}
address=/disneyplus.com/${PUBLIC_IP}
address=/disneyplus.com.ssl.sc.omtrdc.net/${PUBLIC_IP}
address=/disneystreaming.com/${PUBLIC_IP}
address=/dssott.com/${PUBLIC_IP}
address=/execute-api.us-east-1.amazonaws.com/${PUBLIC_IP}
address=/js-agent.newrelic.com/${PUBLIC_IP}
address=/xboxlive.com/${PUBLIC_IP}
address=/lovefilm.com/${PUBLIC_IP}
address=/turner.com/${PUBLIC_IP}
address=/amctv.com/${PUBLIC_IP}
address=/sho.com/${PUBLIC_IP}
address=/mog.com/${PUBLIC_IP}
address=/wdtvlive.com/${PUBLIC_IP}
address=/beinsportsconnect.tv/${PUBLIC_IP}
address=/beinsportsconnect.net/${PUBLIC_IP}
address=/fig.bbc.co.uk/${PUBLIC_IP}
address=/open.live.bbc.co.uk/${PUBLIC_IP}
address=/sa.bbc.co.uk/${PUBLIC_IP}
address=/www.bbc.co.uk/${PUBLIC_IP}
address=/crunchyroll.com/${PUBLIC_IP}
address=/ifconfig.co/${PUBLIC_IP}
address=/omtrdc.net/${PUBLIC_IP}
address=/sling.com/${PUBLIC_IP}
address=/movetv.com/${PUBLIC_IP}
address=/happyon.jp/${PUBLIC_IP}
address=/abema.tv/${PUBLIC_IP}
address=/hulu.jp/${PUBLIC_IP}
address=/optus.com.au/${PUBLIC_IP}
address=/optusnet.com.au/${PUBLIC_IP}
address=/gamer.com.tw/${PUBLIC_IP}
address=/bahamut.com.tw/${PUBLIC_IP}
address=/hinet.net/${PUBLIC_IP}
address=/dmm.com/${PUBLIC_IP}
address=/dmm.co.jp/${PUBLIC_IP}
address=/dmm-extension.com/${PUBLIC_IP}
address=/dmmapis.com/${PUBLIC_IP}
address=/videomarket.jp/${PUBLIC_IP}
address=/p-smith.com/${PUBLIC_IP}
address=/img.vm-movie.jp/${PUBLIC_IP}
address=/saima.zlzd.xyz/${PUBLIC_IP}
address=/challenges.cloudflare.com/${PUBLIC_IP}
address=/ai.com/${PUBLIC_IP}
address=/openai.com/${PUBLIC_IP}
address=/cdn.oaistatic.com/${PUBLIC_IP}
address=/aiv-cdn.net/${PUBLIC_IP}
address=/aiv-delivery.net/${PUBLIC_IP}
address=/amazonprimevideo.cn/${PUBLIC_IP}
address=/amazonprimevideo.com.cn/${PUBLIC_IP}
address=/amazonprimevideos.com/${PUBLIC_IP}
address=/amazonvideo.cc/${PUBLIC_IP}
address=/media-amazon.com/${PUBLIC_IP}
address=/prime-video.com/${PUBLIC_IP}
address=/primevideo.cc/${PUBLIC_IP}
address=/primevideo.com/${PUBLIC_IP}
address=/primevideo.info/${PUBLIC_IP}
address=/primevideo.org/${PUBLIC_IP}
address=/primevideo.tv/${PUBLIC_IP}
address=/pv-cdn.net/${PUBLIC_IP}
address=/chatgpt.com/${PUBLIC_IP}
address=/auth0.com/${PUBLIC_IP}
address=/sora.com/${PUBLIC_IP}
address=/gemini.google.com/${PUBLIC_IP}
address=/proactivebackend-pa.googleapis.com/${PUBLIC_IP}
address=/aistudio.google.com/${PUBLIC_IP}
address=/alkalimakersuite-pa.clients6.google.com/${PUBLIC_IP}
address=/generativelanguage.googleapis.com/${PUBLIC_IP}
address=/copilot.microsoft.com/${PUBLIC_IP}
address=/oaiusercontent.com/${PUBLIC_IP}
address=/cdn.usefathom.com/${PUBLIC_IP}
address=/anthropic.com/${PUBLIC_IP}
address=/claude.ai/${PUBLIC_IP}
address=/byteoversea.com/${PUBLIC_IP}
address=/ibytedtos.com/${PUBLIC_IP}
address=/ipstatp.com/${PUBLIC_IP}
address=/muscdn.com/${PUBLIC_IP}
address=/musical.ly/${PUBLIC_IP}
address=/tiktok.com/${PUBLIC_IP}
address=/tik-tokapi.com/${PUBLIC_IP}
address=/tiktokcdn.com/${PUBLIC_IP}
address=/tiktokv.com/${PUBLIC_IP}
address=/youtube.com/${PUBLIC_IP}
address=/youtubei.googleapis.com/${PUBLIC_IP}
EOF

    if ! grep -q "^conf-dir=/etc/dnsmasq.d" /etc/dnsmasq.conf; then
        echo -e "${BLUE}信息: 正在为 dnsmasq.conf 添加 'conf-dir' 配置...${NC}"
        echo -e "\n# Load configurations from /etc/dnsmasq.d\nconf-dir=/etc/dnsmasq.d/,*.conf" >> /etc/dnsmasq.conf
    fi
    
    echo -e "${BLUE}信息: 正在重启Dnsmasq服务以加载新配置...${NC}"
    if ! dnsmasq --test; then
        echo -e "${RED}错误: Dnsmasq 配置校验失败，正在恢复原配置。${NC}"
        restore_dns_server_snapshot
        return 1
    fi
    systemctl restart dnsmasq
    if systemctl is-active --quiet dnsmasq; then
        echo -e "${GREEN}成功: Dnsmasq配置完成并已重启。${NC}"
    else
        echo -e "${RED}错误: Dnsmasq服务重启失败，正在恢复安装前配置。${NC}"
        restore_dns_server_snapshot
        return 1
    fi
    configure_dns_unlock_access || return 1
    echo
    echo -e "${GREEN}🎉 恭喜！全新的 DNS 解锁服务已成功安装！它现在独立于您其他的Gost转发服务运行。${NC}"
}


uninstall_dns_unlock_server() {
    clear
    echo -e "${YELLOW}--- DNS解锁服务 卸载 ---${NC}"
    echo -e "${BLUE}信息: 正在停止并卸载 Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME})...${NC}"
    systemctl stop "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    systemctl disable "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    if [[ -f "$DNS_STATE_DIR/server/gost-service.before" ]]; then
        cp -a "$DNS_STATE_DIR/server/gost-service.before" "$DNS_GOST_SERVICE_PATH"
    else
        rm -f "${DNS_GOST_SERVICE_PATH}"
    fi
    if [[ -f "$DNS_STATE_DIR/server/gost-config.before" ]]; then
        cp -a "$DNS_STATE_DIR/server/gost-config.before" "$DNS_GOST_CONFIG_PATH"
    else
        rm -f "${DNS_GOST_CONFIG_PATH}"
    fi
    systemctl daemon-reload
    while iptables -C INPUT -j AI_DNS_UNLOCK_ACCESS 2>/dev/null; do iptables -D INPUT -j AI_DNS_UNLOCK_ACCESS; done
    iptables -F AI_DNS_UNLOCK_ACCESS 2>/dev/null || true
    iptables -X AI_DNS_UNLOCK_ACCESS 2>/dev/null || true
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    
    # 仅在确认没有其他 Gost systemd 服务引用二进制时删除它。
    if [[ ! -e "$DNS_STATE_DIR/server/gost-installed-by-script" ]]; then
        echo -e "${BLUE}信息: Gost 原本已存在，保留程序本体。${NC}"
    elif grep -Rqs --include='*.service' -E 'ExecStart=.*(/|[[:space:]])gost([[:space:]]|$)' /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system 2>/dev/null; then
        echo -e "${YELLOW}警告: 检测到可能存在的主Gost转发服务。${NC}"
        echo -e "${BLUE}信息: 为避免破坏主服务，将不会删除 'gost' 程序本体。${NC}"
    else
        echo -e "${BLUE}信息: 未检测到其他Gost服务，将一并删除 'gost' 程序本体。${NC}"
        rm -f /usr/local/bin/gost
    fi
    echo

    echo -e "${BLUE}信息: 正在移除本脚本的 Dnsmasq 配置...${NC}"
    if [[ -f "$DNS_STATE_DIR/server/custom-unlock.before" ]]; then
        cp -a "$DNS_STATE_DIR/server/custom-unlock.before" /etc/dnsmasq.d/custom_unlock.conf
    else
        rm -f /etc/dnsmasq.d/custom_unlock.conf
    fi
    if [[ -f "$DNS_STATE_DIR/server/dnsmasq.conf.before" ]]; then
        cp -a "$DNS_STATE_DIR/server/dnsmasq.conf.before" /etc/dnsmasq.conf
    fi
    if [[ -e "$DNS_STATE_DIR/server/resolv.conf.before" || -L "$DNS_STATE_DIR/server/resolv.conf.before" ]]; then
        rm -f /etc/resolv.conf
        cp -a "$DNS_STATE_DIR/server/resolv.conf.before" /etc/resolv.conf
    elif [[ -e "$DNS_STATE_DIR/server/no-resolv-conf" ]]; then
        rm -f /etc/resolv.conf
    fi
    if [[ -e "$DNS_STATE_DIR/server/dnsmasq-preexisting" ]]; then
        dnsmasq --test >/dev/null 2>&1 && systemctl restart dnsmasq 2>/dev/null || true
        echo -e "${GREEN}成功: 已恢复安装前的 Dnsmasq 配置，保留原软件。${NC}"
    else
        systemctl stop dnsmasq 2>/dev/null || true
        apt-get purge -y dnsmasq >/dev/null 2>&1 || true
        echo -e "${GREEN}成功: 已移除由本脚本安装的 Dnsmasq。${NC}"
    fi
    if [[ -f "$DNS_STATE_DIR/server/gost-service.before" ]]; then
        if [[ -e "$DNS_STATE_DIR/server/gost-service-enabled" ]]; then systemctl enable "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; else systemctl disable "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; fi
        if [[ -e "$DNS_STATE_DIR/server/gost-service-active" ]]; then systemctl restart "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true; fi
    fi
    if [[ -e "$DNS_STATE_DIR/server/resolved-enabled" ]]; then systemctl enable systemd-resolved 2>/dev/null || true; else systemctl disable systemd-resolved 2>/dev/null || true; fi
    if [[ -e "$DNS_STATE_DIR/server/resolved-active" ]]; then systemctl start systemd-resolved 2>/dev/null || true; else systemctl stop systemd-resolved 2>/dev/null || true; fi
    local state_archive
    state_archive="/var/backups/ai-scripts/dns-unlock/uninstall-$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$state_archive"
    cp -a "$DNS_STATE_DIR/server" "$state_archive/server-state"
    rm -rf -- "$DNS_STATE_DIR/server"
    echo -e "${BLUE}信息: 卸载前状态已归档到 $state_archive${NC}"
    echo
    echo -e "${GREEN}✅ 所有 DNS 解锁服务组件均已卸载完毕。${NC}"
}

setup_dns_client() {
    clear
    backup_dns_client_state
    echo -e "${YELLOW}--- 设置 DNS 客户端 ---${NC}"
    read -p "请输入您的 DNS 解锁服务器的 IP 地址: " server_ip
    if [[ "$server_ip" == */* ]] || ! validate_ipv4_or_cidr "$server_ip"; then echo -e "${RED}错误: 您输入的不是一个有效的 IPv4 地址。${NC}"; return 1; fi

    # 1) （推荐）禁用 systemd-resolved，避免 stub 劫持；解除 resolv.conf 软链
    disable_systemd_resolved_if_running

    # 2) 写入并锁定 resolv.conf 指向 A
    set_resolv_conf "$server_ip"

    # 3) （推荐）设置系统 IPv4 优先，避免 AAAA 泄漏
    echo -e "${YELLOW}重要: 如果您的系统支持IPv6，必须采取措施防止绕过解锁！${NC}"
    echo -e "${BLUE}可选方案：${NC}"
    echo "  1. 设置IPv4优先（推荐）"
    echo "  2. 使用防火墙阻断IPv6关键端口（更彻底）"
    echo "  3. 两者都启用（最安全）"
    echo "  4. 都不启用（不推荐）"
    read -p "请选择 [1-4，默认3]: " ipv6_choice
    
    case "${ipv6_choice:-3}" in
        1)
            ensure_ipv4_preference
            ;;
        2)
            block_ipv6_ports
            ;;
        3)
            ensure_ipv4_preference
            block_ipv6_ports
            ;;
        4)
            echo -e "${RED}警告: 未采取任何IPv6防护措施！${NC}"
            echo -e "${RED}如果系统支持IPv6，DNS解锁很可能会失效！${NC}"
            ;;
        *)
            echo -e "${YELLOW}无效选择，默认执行方案3（最安全）${NC}"
            ensure_ipv4_preference
            block_ipv6_ports
            ;;
    esac

    # 4) （可选）添加防火墙优先规则，优化 DNS 路由
    read -p "是否添加防火墙规则，优先将 DNS 发往 ${server_ip} ? (y/N): " enforce_dns
    if [[ "$enforce_dns" =~ ^[yY]$ ]]; then
        enforce_dns_only_to_server "$server_ip"
    else
        echo -e "${YELLOW}提示: 未启用 DNS 优先规则，依靠 /etc/resolv.conf 配置即可正常工作。${NC}"
    fi

    echo -e "${GREEN}成功: 客户端 DNS 已完成设置。${NC}"
    echo -e "${BLUE}建议测试:${NC} dig +short chatgpt.com ; curl --socks5 与 --socks5-hostname 对比访问。"
}

uninstall_dns_client() {
    clear
    echo -e "${YELLOW}--- 卸载/还原 DNS 客户端设置 ---${NC}"
    # 移除IPv6端口阻断规则
    unblock_ipv6_ports
    # 移除由脚本添加的 DNS 强制规则
    revert_dns_enforcement_rules
    echo -e "${BLUE}信息: 正在解锁 DNS 配置文件...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null
    if [[ -e "$DNS_STATE_DIR/client/state-recorded" ]]; then
        rm -f /etc/resolv.conf
        if [[ -e "$DNS_STATE_DIR/client/resolv.conf" || -L "$DNS_STATE_DIR/client/resolv.conf" ]]; then
            cp -a "$DNS_STATE_DIR/client/resolv.conf" /etc/resolv.conf
        fi
        if [[ -e "$DNS_STATE_DIR/client/gai.conf" ]]; then
            cp -a "$DNS_STATE_DIR/client/gai.conf" /etc/gai.conf
        elif [[ -e "$DNS_STATE_DIR/client/gai-was-absent" ]]; then
            rm -f /etc/gai.conf
        fi
        if [[ -e "$DNS_STATE_DIR/client/resolved-enabled" ]]; then
            systemctl enable systemd-resolved 2>/dev/null || true
        else
            systemctl disable systemd-resolved 2>/dev/null || true
        fi
        if [[ -e "$DNS_STATE_DIR/client/resolved-active" ]]; then
            systemctl start systemd-resolved 2>/dev/null || true
        else
            systemctl stop systemd-resolved 2>/dev/null || true
        fi
        echo -e "${GREEN}已恢复首次修改前的 resolv.conf、gai.conf 和 systemd-resolved 状态。${NC}"
        rm -rf -- "$DNS_STATE_DIR/client"
    else
        echo -e "${YELLOW}没有本脚本记录的原始 DNS 状态，拒绝猜测或覆盖当前配置。${NC}"
    fi
}

manage_ipv6_blocking() {
    while true; do
        clear
        echo -e "${YELLOW}══════ IPv6 端口阻断管理 ══════${NC}"
        echo -e "${BLUE}防止应用通过IPv6绕过DNS解锁${NC}"
        echo ""
        
        # 显示当前IPv6阻断状态
        if command -v ip6tables &>/dev/null && ip6tables -L OUTPUT -n | grep -q "dns-unlock-block-ipv6"; then
            echo -e "${GREEN}状态: IPv6端口阻断已启用${NC}"
            echo -e "${BLUE}当前阻断的端口:${NC}"
            ip6tables -L OUTPUT -n --line-numbers | grep "dns-unlock-block-ipv6" | while read line; do
                echo "  $line"
            done
        else
            echo -e "${YELLOW}状态: IPv6端口阻断未启用${NC}"
        fi
        
        echo -e "${YELLOW}────────────────────────────────${NC}"
        echo "1. 启用IPv6端口阻断 (53/80/443)"
        echo "2. 禁用IPv6端口阻断"
        echo "3. 查看当前IPv6连接状态"
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}═══════════════════════════════${NC}"
        read -p "请输入选项: " ipv6_choice
        
        case $ipv6_choice in
            1)
                block_ipv6_ports
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            2)
                unblock_ipv6_ports
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            3)
                echo -e "${BLUE}当前IPv6连接状态:${NC}"
                if command -v ss &>/dev/null; then
                    echo -e "${YELLOW}IPv6 TCP连接:${NC}"
                    ss -6tn state established 2>/dev/null | head -20
                    echo -e "${YELLOW}IPv6 监听端口:${NC}"
                    ss -6tln 2>/dev/null | head -20
                else
                    echo -e "${YELLOW}IPv6网络配置:${NC}"
                    ip -6 addr show 2>/dev/null | grep -v "^\s*valid_lft"
                fi
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选项!${NC}"
                sleep 1
                ;;
        esac
    done
}

manage_iptables_rules() {
    # 首先确保iptables已安装
    if ! check_and_install_iptables; then
        echo -e "${RED}错误: 无法继续，iptables 是必需的。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    
    if ! dpkg -l | grep -q 'iptables-persistent'; then
        echo -e "${YELLOW}警告: 'iptables-persistent' 未安装，规则可能无法自动持久化。${NC}"
        read -p "是否现在尝试安装? (y/N): " install_confirm
        if [[ "$install_confirm" =~ ^[yY]$ ]]; then apt-get update && apt-get install -y iptables-persistent; fi
    fi
    while true; do
        clear
        echo -e "${YELLOW}══════ IP 白名单管理 (端口 53, 80, 443) ══════${NC}"
        echo "管理 DNS(53) 和 Gost(80, 443) 的访问权限。"
        echo -e "${BLUE}当前生效的相关规则:${NC}"
        iptables -L INPUT -v -n --line-numbers | grep -E 'dpt:53|dpt:80|dpt:443' || echo -e "  (无相关规则)"
        echo -e "${YELLOW}────────────────────────────────────────────${NC}"
        echo "1. 添加白名单IP (允许访问)"
        echo "2. 删除白名单IP (根据行号)"
        echo "3. 应用 '默认拒绝' 规则 (推荐)"
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}════════════════════════════════════════════${NC}"
        read -p "请输入选项: " rule_choice
        case $rule_choice in
        1)
            read -p "请输入要加入白名单的IP (单个或多个, 用空格隔开): " ips
            if [[ -z "$ips" ]]; then continue; fi

            local added_count=0
            local invalid_input=false
            for ip in $ips; do
                # Simple validation for IP format
                if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$ip' 不是一个有效的 IP 地址格式。${NC}"
                    invalid_input=true
                    continue
                fi

                for port in 53 80 443; do
                    iptables -I INPUT -s "$ip" -p tcp --dport "$port" -m comment --comment dns-unlock-whitelist -j ACCEPT
                    if [[ "$port" == "53" ]]; then iptables -I INPUT -s "$ip" -p udp --dport "$port" -m comment --comment dns-unlock-whitelist -j ACCEPT; fi
                done
                echo -e "${GREEN}IP $ip 已添加至端口 53, 80, 443 白名单。${NC}"
                ((added_count++))
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过。${NC}"
            fi

            if (( added_count > 0 )); then
                echo -e "${GREEN}共添加了 ${added_count} 个IP至白名单。${NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            else
                echo -e "${YELLOW}未执行任何有效的添加操作。${NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        2)
            read -p "请输入要删除的规则行号 (单个或多个, 用空格隔开): " line_nums
            if [[ -z "$line_nums" ]]; then continue; fi

            # 为了防止删除时行号变化导致错删，必须从大到小删除
            readarray -t sorted_nums < <(echo "$line_nums" | tr ' ' '\n' | sort -nr)

            local deleted_count=0
            local invalid_input=false
            for num in "${sorted_nums[@]}"; do
                # 验证每个输入是否为纯数字
                if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$num' 不是有效的行号。${NC}"
                    invalid_input=true
                    continue
                fi
                if ! iptables -L INPUT -n --line-numbers | awk -v number="$num" '$1 == number' | grep -q 'dns-unlock'; then
                    echo -e "${RED}规则 ${num} 不是由本脚本管理，拒绝删除。${NC}"
                    invalid_input=true
                    continue
                fi
                # 执行删除
                if iptables -D INPUT "$num"; then
                    echo -e "${GREEN}规则 ${num} 已删除。${NC}"
                    ((deleted_count++))
                else
                    echo -e "${RED}删除规则 ${num} 失败 (可能行号不存在)。${NC}"
                fi
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过。${NC}"
            fi

            if (( deleted_count > 0 )); then
                echo -e "${GREEN}共删除了 ${deleted_count} 条规则。${NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            else
                echo -e "${YELLOW}未执行任何有效删除操作。${NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        3)
            echo -e "${BLUE}信息: 这将确保所有不在白名单的IP无法访问相关端口。${NC}"
            for port in 53 80 443; do
                if ! iptables -C INPUT -p tcp --dport "$port" -m comment --comment dns-unlock-default-deny -j DROP &>/dev/null; then iptables -A INPUT -p tcp --dport "$port" -m comment --comment dns-unlock-default-deny -j DROP; fi
                if [[ "$port" == "53" ]]; then if ! iptables -C INPUT -p udp --dport "$port" -m comment --comment dns-unlock-default-deny -j DROP &>/dev/null; then iptables -A INPUT -p udp --dport "$port" -m comment --comment dns-unlock-default-deny -j DROP; fi; fi
            done
            echo -e "${GREEN}'默认拒绝' 规则已应用/确认存在。${NC}"
            netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        0) break ;;
        *) echo -e "${RED}无效选项!${NC}"; sleep 1;;
        esac
    done
}


# ======================= 主逻辑入口 =======================

# --- 运行主逻辑 ---
dns_unlock_menu
