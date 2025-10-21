#!/bin/bash
# --- 专属配置 ---
DNS_GOST_CONFIG_PATH="/etc/gost/dns-unlock-config.yml"
DNS_GOST_SERVICE_NAME="gost-dns.service"
DNS_GOST_SERVICE_PATH="/etc/systemd/system/${DNS_GOST_SERVICE_NAME}"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# --- 安全检�? 确保�?root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：本脚本需要以 root 权限运行�?{NC}"
   echo -e "${GREEN}请尝试使�? sudo bash $0${NC}"
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
            echo -e "${GREEN}成功: iptables 已成功安装�?{NC}"
        else
            echo -e "${RED}错误: iptables 安装失败，某些功能可能无法使用�?{NC}"
            return 1
        fi
    fi
    return 0
}

check_port_53() {
    if ! command -v lsof &> /dev/null; then apt-get update >/dev/null 2>&1 && apt-get install -y lsof >/dev/null; fi
    if lsof -i :53 -sTCP:LISTEN -P -n >/dev/null; then
        local process_name
        process_name=$(ps -p "$(lsof -i :53 -sTCP:LISTEN -P -n -t)" -o comm=)

        if [[ "$process_name" == "systemd-resolve" ]]; then
            echo -e "${YELLOW}警告: 端口 53 (DNS) 已被系统服务 'systemd-resolved' 占用�?{NC}"
            read -p "是否允许脚本自动禁用该服务并修复DNS配置? (Y/n): " choice
            if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
                echo -e "${BLUE}信息: 正在停止并禁�?systemd-resolved...${NC}"
                systemctl disable --now systemd-resolved
                sleep 2 # 等待端口释放

                # 修复�?systemd-resolved 管理�?/etc/resolv.conf
                if [ -L /etc/resolv.conf ]; then
                    echo -e "${BLUE}信息: /etc/resolv.conf 是一个符号链接，正在重新创建它以确保服务器网络正�?..${NC}"
                    rm /etc/resolv.conf
                    echo "nameserver 8.8.8.8" > /etc/resolv.conf
                    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
                    echo -e "${GREEN}成功: /etc/resolv.conf 已修复�?{NC}"
                fi

                # 再次检查端口是否已释放
                if lsof -i :53 -sTCP:LISTEN -P -n >/dev/null; then
                    echo -e "${RED}错误: 端口 53 仍然被占用，请手动检查�?{NC}"
                    return 1
                fi
                echo -e "${GREEN}成功: 端口 53 冲突已解决�?{NC}"
                return 0
            else
                echo -e "${RED}错误: 操作已取消。请手动禁用 systemd-resolved (sudo systemctl disable --now systemd-resolved) 后重试�?{NC}"
                return 1
            fi
        fi

        echo -e "${YELLOW}警告: 端口 53 (DNS) 已被进程 '${process_name}' 占用�?{NC}"
        if [[ "$process_name" != "dnsmasq" ]]; then
            echo -e "${RED}错误: 请先停止 '${process_name}' 服务后再试�?{NC}"
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
                echo -e "${YELLOW}警告: 端口 ${port} 已被进程 '${process_name}' 占用�?{NC}"
                echo -e "${RED}这可能与 Nginx, Apache �?Caddy 等常用Web服务冲突。请确保您已了解此情况�?{NC}"
                read -p "是否仍然继续安装? (y/N): " choice
                if [[ ! "$choice" =~ ^[yY]$ ]]; then echo "安装已取消�?; return 1; fi
                return 0
            fi
        fi
    done
    return 0
}


# ======================= 客户端辅助函�?=======================

disable_systemd_resolved_if_running() {
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${YELLOW}警告: 检测到 systemd-resolved 正在运行，可能拦�?127.0.0.53:53�?{NC}"
        read -p "是否禁用并停�?systemd-resolved，并解除 /etc/resolv.conf 软链�? (Y/n): " choice
        if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
            systemctl disable --now systemd-resolved
            # �?resolv.conf 为软链接，则移除并创建普通文�?
            if [ -L /etc/resolv.conf ]; then
                rm -f /etc/resolv.conf
                touch /etc/resolv.conf
            fi
            echo -e "${GREEN}成功: 已禁�?systemd-resolved�?{NC}"
        else
            echo -e "${YELLOW}提示: 已跳过禁�?systemd-resolved，可能导�?DNS 配置被覆盖或劫持�?{NC}"
        fi
    fi
}

set_resolv_conf() {
    local server_ip="$1"
    echo -e "${BLUE}信息: 正在备份当前�?DNS 配置...${NC}"
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        cp /etc/resolv.conf "/etc/resolv.conf.bak_$(date +%Y%m%d_%H%M%S)"
    fi
    echo -e "${BLUE}信息: 正在写入新的 DNS 配置 (nameserver ${server_ip})...${NC}"
    printf "nameserver %s\n" "$server_ip" > /etc/resolv.conf
    if chattr +i /etc/resolv.conf; then
        echo -e "${GREEN}成功: /etc/resolv.conf 已锁定，防止被覆盖�?{NC}"
    else
        echo -e "${YELLOW}警告: 无法锁定 /etc/resolv.conf（缺�?chattr 或不支持），继续�?{NC}"
    fi
}

ensure_ipv4_preference() {
    echo -e "${BLUE}信息: 正在设置系统优先使用 IPv4�?etc/gai.conf�?..${NC}"
    if [ -f /etc/gai.conf ]; then
        if grep -qE '^\s*#\s*precedence ::ffff:0:0/96 100' /etc/gai.conf; then
            sed -i 's/^\s*#\s*precedence ::ffff:0:0\/96 100/precedence ::ffff:0:0\/96 100/' /etc/gai.conf
        elif ! grep -qE '^\s*precedence ::ffff:0:0/96 100' /etc/gai.conf; then
            echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
        fi
    else
        echo 'precedence ::ffff:0:0/96 100' > /etc/gai.conf
    fi
    echo -e "${GREEN}成功: 已设�?IPv4 优先�?{NC}"
}

# 使用iptables阻断IPv6关键端口
block_ipv6_ports() {
    echo -e "${BLUE}信息: 正在使用ip6tables阻断IPv6端口以防止解锁绕�?..${NC}"
    
    # 检查ip6tables是否可用
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}警告: ip6tables未安装，正在安装...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
    fi
    
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${RED}错误: 无法安装ip6tables，跳过IPv6阻断�?{NC}"
        return 1
    fi
    
    # 阻断IPv6的DNS(53)、HTTP(80)、HTTPS(443)出站
    for port in 53 80 443; do
        for proto in tcp udp; do
            # 跳过80/443的UDP（不存在�?
            if [[ "$port" != "53" ]] && [[ "$proto" == "udp" ]]; then
                continue
            fi
            
            # 检查规则是否已存在
            if ! ip6tables -C OUTPUT -p "${proto}" --dport "${port}" -m comment --comment "dns-unlock-block-ipv6" -j REJECT &>/dev/null; then
                ip6tables -I OUTPUT -p "${proto}" --dport "${port}" -m comment --comment "dns-unlock-block-ipv6" -j REJECT
                echo -e "${GREEN}已阻断IPv6 ${proto^^}/${port}端口${NC}"
            fi
        done
    done
    
    # 持久化规�?
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}IPv6阻断规则已持久化�?{NC}"
    fi
    
    echo -e "${GREEN}成功: IPv6关键端口已阻断，防止绕过DNS解锁�?{NC}"
    return 0
}

# 移除IPv6端口阻断规则
unblock_ipv6_ports() {
    echo -e "${BLUE}信息: 正在移除IPv6端口阻断规则...${NC}"
    
    if ! command -v ip6tables &>/dev/null; then
        echo -e "${YELLOW}提示: ip6tables未安装，跳过�?{NC}"
        return 0
    fi
    
    # 移除所有带dns-unlock-block-ipv6标记的规�?
    while ip6tables -L OUTPUT -n --line-numbers | grep -q "dns-unlock-block-ipv6"; do
        local line_num=$(ip6tables -L OUTPUT -n --line-numbers | grep "dns-unlock-block-ipv6" | head -1 | awk '{print $1}')
        if [[ -n "$line_num" ]]; then
            ip6tables -D OUTPUT "$line_num"
        else
            break
        fi
    done
    
    # 持久化规�?
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}成功: IPv6端口阻断规则已移除�?{NC}"
    return 0
}

enforce_dns_only_to_server() {
    local server_ip="$1"
    echo -e "${BLUE}信息: 正在应用防火墙规则，强制 DNS 仅发往 ${server_ip}...${NC}"
    # 自动检测并安装iptables
    if ! check_and_install_iptables; then
        echo -e "${RED}错误: iptables 不可用，无法应用 DNS 强制规则�?{NC}"
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
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}成功: 防火墙规则已持久化�?{NC}"
    fi
}

revert_dns_enforcement_rules() {
    echo -e "${BLUE}信息: 正在移除由脚本添加的 DNS 强制规则...${NC}"
    # 检查iptables是否可用
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}警告: iptables 未安装，跳过规则移除�?{NC}"
        return 0
    fi
    local server_ip=""
    if [ -f /etc/resolv.conf ]; then
        server_ip=$(awk '/^nameserver[ \t]+([0-9]{1,3}\.){3}[0-9]{1,3}/{print $2; exit}' /etc/resolv.conf)
    fi
    for proto in udp tcp; do
        if [[ -n "$server_ip" ]] && iptables -C OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT &>/dev/null; then
            iptables -D OUTPUT -p "${proto}" --dport 53 -d "${server_ip}" -m comment --comment "dns-unlock-enforce-dns" -j ACCEPT
        fi
        while iptables -C OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT &>/dev/null; do
            iptables -D OUTPUT -p "${proto}" --dport 53 -m comment --comment "dns-unlock-enforce-dns" -j REJECT || break
        done
    done
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo -e "${GREEN}成功: 防火墙规则变更已持久化�?{NC}"
    fi
}


# ======================= 核心功能函数 =======================

dns_unlock_menu() {
    while true; do
        clear
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${YELLOW}           DNS 解锁服务管理           ${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo " --- 服务端管�?---"
        echo "  1. 安装/更新 DNS 解锁服务"
        echo "  2. 卸载 DNS 解锁服务"
        echo "  3. 管理 IP 白名�?(防火�?"
        echo
        echo " --- 客户端管�?---"
        echo "  4. 设置本机�?DNS 客户�?
        echo "  5. 还原客户�?DNS 设置"
        echo "  6. 管理IPv6端口阻断（防绕过�?
        echo " --------------------------------------------"
        echo "  0. 退出脚�?
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

    echo -e "${BLUE}信息: 正在安装/检查核心依�?..${NC}"
    apt-get update >/dev/null 2>&1
    apt-get install -y dnsmasq curl wget lsof tar file >/dev/null 2>&1
    if ! check_port_53; then return 1; fi
    if ! check_ports_80_443; then return 1; fi

    echo -e "${BLUE}信息: 正在清理旧环�?..${NC}"
    systemctl stop sniproxy 2>/dev/null
    systemctl stop "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    apt-get purge -y sniproxy >/dev/null 2>&1
    rm -f /etc/dnsmasq.d/custom_netflix.conf
    # 清理动作不应删除gost主程序，智能检查会处理
    echo

    # --- 智能检查Gost是否已安�?---
    local GOST_EXEC_PATH
    GOST_EXEC_PATH=$(command -v gost)

    if [[ -n "$GOST_EXEC_PATH" ]]; then
        echo -e "${GREEN}检测到 Gost 已安�? ${GOST_EXEC_PATH} ($(${GOST_EXEC_PATH} -V))${NC}"
        echo -e "${BLUE}信息: 将使用现有版本，跳过安装步骤�?{NC}"
    else
        echo -e "${BLUE}信息: 正在安装最新版 Gost ...${NC}"
        LATEST_GOST_VERSION=$(curl -s "https://api.github.com/repos/go-gost/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 2-)
        local gost_version=${LATEST_GOST_VERSION:-"3.2.4"} # 如果API失败则回退到指定版�?
        local bit
        bit=$(uname -m)
        if [[ "$bit" == "x86_64" ]]; then bit="amd64"; elif [[ "$bit" == "aarch64" ]]; then bit="armv8"; fi
        local FILENAME="gost_${gost_version}_linux_${bit}.tar.gz"
        local GOST_URL="https://github.com/go-gost/gost/releases/download/v${gost_version}/${FILENAME}"

        echo "信息: 正在从以下地址下载Gost (v${gost_version}):"
        echo "${GOST_URL}"
        if ! curl -L -o "${FILENAME}" "${GOST_URL}"; then
            echo -e "${RED}错误: Gost 下载失败�?(curl 退出码: $?)${NC}"
            rm -f "${FILENAME}"
            return 1
        fi

        if ! file "${FILENAME}" | grep -q 'gzip compressed data'; then
            echo -e "${RED}错误: 下载的文件不是有效的压缩包。请手动检查上述URL�?{NC}"
            rm -f "${FILENAME}"
            return 1
        fi

        tar -xzf "${FILENAME}" || { echo -e "${RED}错误: Gost解压失败�?{NC}"; rm -f "${FILENAME}"; return 1; }
        
        chmod +x "gost"
        mv "gost" /usr/local/bin/gost || { echo -e "${RED}错误: 移动gost文件失败，请检查权限�?{NC}"; return 1; }
        
        rm -f "${FILENAME}"
        GOST_EXEC_PATH="/usr/local/bin/gost" # 更新路径变量
        
        if ! command -v gost &> /dev/null; then 
            echo -e "${RED}错误: Gost 安装最终失败，未知错误�?{NC}"
            return 1
        else
            echo -e "${GREEN}成功: Gost (v${gost_version}) 已成功安装。版本：$(gost -V)${NC}"
        fi
    fi
    echo

    echo -e "${BLUE}信息: 正在为DNS解锁服务创建 Gost 配置文件 (YAML)...${NC}"
    mkdir -p /etc/gost

    # --- Gost 配置说明 ---
    # 本脚本中，Gost 的角色是 HTTP (80) �?HTTPS (443) 的透明流量转发器�?
    # 它不处理 DNS (53) 请求，该任务�?Dnsmasq 完成�?
    # 因此，配置文件中只有 80 �?443 端口的监听服务�?
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
    type: "sni" # 使用SNI模式来解析TLS流量的目标域�?
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
    # 使用检测到的或新安装的gost路径，确保兼容�?
    tee "${DNS_GOST_SERVICE_PATH}" > /dev/null <<EOT
[Unit]
Description=GOST DNS Unlock Service
After=network.target

[Service]
Type=simple
ExecStart=${GOST_EXEC_PATH} -C ${DNS_GOST_CONFIG_PATH}
Restart=always
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOT

    systemctl daemon-reload && systemctl enable "${DNS_GOST_SERVICE_NAME}" && systemctl restart "${DNS_GOST_SERVICE_NAME}"
    if systemctl is-active --quiet "${DNS_GOST_SERVICE_NAME}"; then echo -e "${GREEN}成功: Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME}) 已成功启动�?{NC}"; else echo -e "${RED}错误: Gost DNS解锁服务启动失败，请使用 'systemctl status ${DNS_GOST_SERVICE_NAME}' 查看日志�?{NC}"; return 1; fi
    echo

    echo -e "${BLUE}信息: 正在创建 Dnsmasq 子配置文�?..${NC}"
    PUBLIC_IP=$(curl -4s ip.sb || curl -4s ifconfig.me)
    if [[ -z "$PUBLIC_IP" ]]; then echo -e "${RED}错误: 无法获取公网IP地址�?{NC}"; return 1; fi
    
    DNSMASQ_CONFIG_FILE="/etc/dnsmasq.d/custom_unlock.conf"
    # 可选：启用 AAAA 过滤，防�?IPv6 泄漏（默认启用）
    read -p "是否在服务端启用 AAAA 过滤（filter-aaaa）以�?IPv6 泄漏�?Y/n): " enable_filter_aaaa
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
interface=* # Listen on all network interfaces to accept queries from non-local IPs
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
        echo -e "${BLUE}信息: 正在�?dnsmasq.conf 添加 'conf-dir' 配置...${NC}"
        echo -e "\n# Load configurations from /etc/dnsmasq.d\nconf-dir=/etc/dnsmasq.d/,*.conf" >> /etc/dnsmasq.conf
    fi
    
    echo -e "${BLUE}信息: 正在重启Dnsmasq服务以加载新配置...${NC}"
    systemctl restart dnsmasq
    if systemctl is-active --quiet dnsmasq; then
        echo -e "${GREEN}成功: Dnsmasq配置完成并已重启�?{NC}"
    else
        echo -e "${RED}错误: Dnsmasq服务重启失败�?{NC}"; return 1;
    fi
    echo
    echo -e "${GREEN}🎉 恭喜！全新的 DNS 解锁服务已成功安装！它现在独立于您其他的Gost转发服务运行�?{NC}"
}


uninstall_dns_unlock_server() {
    clear
    echo -e "${YELLOW}--- DNS解锁服务 卸载 ---${NC}"
    echo -e "${BLUE}信息: 正在停止并卸�?Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME})...${NC}"
    systemctl stop "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    systemctl disable "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    rm -f "${DNS_GOST_SERVICE_PATH}"
    rm -f "${DNS_GOST_CONFIG_PATH}"
    systemctl daemon-reload
    
    # --- 智能卸载检�?---
    # 定义常见的主Gost服务路径
    MAIN_GOST_SERVICE_PATH="/usr/lib/systemd/system/gost.service" 
    if [[ -f "${MAIN_GOST_SERVICE_PATH}" ]] || systemctl list-units --type=service | grep -q 'gost.service'; then
        echo -e "${YELLOW}警告: 检测到可能存在的主Gost转发服务�?{NC}"
        echo -e "${BLUE}信息: 为避免破坏主服务，将不会删除 'gost' 程序本体�?{NC}"
    else
        echo -e "${BLUE}信息: 未检测到其他Gost服务，将一并删�?'gost' 程序本体�?{NC}"
        rm -f "$(command -v gost)"
    fi
    echo
    
    echo -e "${BLUE}信息: 正在卸载 Dnsmasq 服务及相关配�?..${NC}"
    systemctl stop dnsmasq 2>/dev/null
    rm -f /etc/dnsmasq.d/custom_unlock.conf
    sed -i '/^# Load configurations from \/etc\/dnsmasq.d/d' /etc/dnsmasq.conf 2>/dev/null
    sed -i '/^conf-dir=\/etc\/dnsmasq.d/d' /etc/dnsmasq.conf 2>/dev/null
    apt-get purge -y dnsmasq >/dev/null 2>&1
    echo -e "${GREEN}成功: Dnsmasq 及相关配置已卸载�?{NC}"
    echo
    echo -e "${GREEN}�?所�?DNS 解锁服务组件均已卸载完毕�?{NC}"
}

setup_dns_client() {
    clear
    echo -e "${YELLOW}--- 设置 DNS 客户�?---${NC}"
    read -p "请输入您�?DNS 解锁服务器的 IP 地址: " server_ip
    if ! [[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo -e "${RED}错误: 您输入的不是一个有效的 IP 地址�?{NC}"; return 1; fi

    # 1) （推荐）禁用 systemd-resolved，避�?stub 劫持；解�?resolv.conf 软链
    disable_systemd_resolved_if_running

    # 2) 写入并锁�?resolv.conf 指向 A
    set_resolv_conf "$server_ip"

    # 3) （推荐）设置系统 IPv4 优先，避�?AAAA 泄漏
    echo -e "${YELLOW}重要: 如果您的系统支持IPv6，必须采取措施防止绕过解锁！${NC}"
    echo -e "${BLUE}可选方案：${NC}"
    echo "  1. 设置IPv4优先（推荐）"
    echo "  2. 使用防火墙阻断IPv6关键端口（更彻底�?
    echo "  3. 两者都启用（最安全�?
    echo "  4. 都不启用（不推荐�?
    read -p "请选择 [1-4，默�?]: " ipv6_choice
    
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
            echo -e "${RED}警告: 未采取任何IPv6防护措施�?{NC}"
            echo -e "${RED}如果系统支持IPv6，DNS解锁很可能会失效�?{NC}"
            ;;
        *)
            echo -e "${YELLOW}无效选择，默认执行方�?（最安全�?{NC}"
            ensure_ipv4_preference
            block_ipv6_ports
            ;;
    esac

    # 4) （可选）强制 DNS 仅发往 A，防止程序私自换 DNS
    read -p "是否添加防火墙规则，强制所�?DNS 仅发往 ${server_ip} ? (y/N): " enforce_dns
    if [[ "$enforce_dns" =~ ^[yY]$ ]]; then
        enforce_dns_only_to_server "$server_ip"
    else
        echo -e "${YELLOW}提示: 未启�?DNS 强制规则，若有程序绕�?/etc/resolv.conf，可能仍出现异常�?{NC}"
    fi

    echo -e "${GREEN}成功: 客户�?DNS 已完成设置�?{NC}"
    echo -e "${BLUE}建议测试:${NC} dig +short chatgpt.com ; curl --socks5 �?--socks5-hostname 对比访问�?
}

uninstall_dns_client() {
    clear
    echo -e "${YELLOW}--- 卸载/还原 DNS 客户端设�?---${NC}"
    # 移除IPv6端口阻断规则
    unblock_ipv6_ports
    # 移除由脚本添加的 DNS 强制规则
    revert_dns_enforcement_rules
    echo -e "${BLUE}信息: 正在解锁 DNS 配置文件...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null
    local latest_backup
    latest_backup=$(ls -t /etc/resolv.conf.bak_* 2>/dev/null | head -n 1)
    if [[ -f "$latest_backup" ]]; then
        echo -e "${BLUE}信息: 正在从备份文�?$latest_backup 还原...${NC}"
        mv "$latest_backup" /etc/resolv.conf
        echo -e "${GREEN}成功: DNS 配置已成功从备份还原�?{NC}"
    else
        echo -e "${YELLOW}警告: 未找到备份文件。正在设置为通用 DNS (8.8.8.8)...${NC}"
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo -e "${GREEN}成功: DNS 已设置为通用公共服务器�?{NC}"
    fi
    # 可选：恢复 systemd-resolved
    if systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
        read -p "是否重新启用并启�?systemd-resolved? (y/N): " reenable_sr
        if [[ "$reenable_sr" =~ ^[yY]$ ]]; then
            if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
                rm -f /etc/resolv.conf
                ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            fi
            systemctl enable --now systemd-resolved && echo -e "${GREEN}已重新启�?systemd-resolved�?{NC}"
        fi
    fi
}

manage_ipv6_blocking() {
    while true; do
        clear
        echo -e "${YELLOW}══════ IPv6 端口阻断管理 ══════${NC}"
        echo -e "${BLUE}防止应用通过IPv6绕过DNS解锁${NC}"
        echo ""
        
        # 显示当前IPv6阻断状�?
        if command -v ip6tables &>/dev/null && ip6tables -L OUTPUT -n | grep -q "dns-unlock-block-ipv6"; then
            echo -e "${GREEN}状�? IPv6端口阻断已启�?{NC}"
            echo -e "${BLUE}当前阻断的端�?${NC}"
            ip6tables -L OUTPUT -n --line-numbers | grep "dns-unlock-block-ipv6" | while read line; do
                echo "  $line"
            done
        else
            echo -e "${YELLOW}状�? IPv6端口阻断未启�?{NC}"
        fi
        
        echo -e "${YELLOW}────────────────────────────────${NC}"
        echo "1. 启用IPv6端口阻断 (53/80/443)"
        echo "2. 禁用IPv6端口阻断"
        echo "3. 查看当前IPv6连接状�?
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}══════════════════════════════�?{NC}"
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
                echo -e "${BLUE}当前IPv6连接状�?${NC}"
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
    # 首先确保iptables已安�?
    if ! check_and_install_iptables; then
        echo -e "${RED}错误: 无法继续，iptables 是必需的�?{NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    
    if ! dpkg -l | grep -q 'iptables-persistent'; then
        echo -e "${YELLOW}警告: 'iptables-persistent' 未安装，规则可能无法自动持久化�?{NC}"
        read -p "是否现在尝试安装? (y/N): " install_confirm
        if [[ "$install_confirm" =~ ^[yY]$ ]]; then apt-get update && apt-get install -y iptables-persistent; fi
    fi
    while true; do
        clear
        echo -e "${YELLOW}══════ IP 白名单管�?(端口 53, 80, 443) ══════${NC}"
        echo "管理 DNS(53) �?Gost(80, 443) 的访问权限�?
        echo -e "${BLUE}当前生效的相关规�?${NC}"
        iptables -L INPUT -v -n --line-numbers | grep -E 'dpt:53|dpt:80|dpt:443' || echo -e "  (无相关规�?"
        echo -e "${YELLOW}────────────────────────────────────────────${NC}"
        echo "1. 添加白名单IP (允许访问)"
        echo "2. 删除白名单IP (根据行号)"
        echo "3. 应用 '默认拒绝' 规则 (推荐)"
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}════════════════════════════════════════════${NC}"
        read -p "请输入选项: " rule_choice
        case $rule_choice in
        1)
            read -p "请输入要加入白名单的IP (单个或多�? 用空格隔开): " ips
            if [[ -z "$ips" ]]; then continue; fi

            local added_count=0
            local invalid_input=false
            for ip in $ips; do
                # Simple validation for IP format
                if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$ip' 不是一个有效的 IP 地址格式�?{NC}"
                    invalid_input=true
                    continue
                fi

                for port in 53 80 443; do
                    iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
                    if [[ "$port" == "53" ]]; then iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT; fi
                done
                echo -e "${GREEN}IP $ip 已添加至端口 53, 80, 443 白名单�?{NC}"
                ((added_count++))
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过�?{NC}"
            fi

            if (( added_count > 0 )); then
                echo -e "${GREEN}共添加了 ${added_count} 个IP至白名单�?{NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存�?{NC}" || echo -e "${RED}防火墙规则保存失败�?{NC}"
            else
                echo -e "${YELLOW}未执行任何有效的添加操作�?{NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        2)
            read -p "请输入要删除的规则行�?(单个或多�? 用空格隔开): " line_nums
            if [[ -z "$line_nums" ]]; then continue; fi

            # 为了防止删除时行号变化导致错删，必须从大到小删除
            readarray -t sorted_nums < <(echo "$line_nums" | tr ' ' '\n' | sort -nr)

            local deleted_count=0
            local invalid_input=false
            for num in "${sorted_nums[@]}"; do
                # 验证每个输入是否为纯数字
                if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$num' 不是有效的行号�?{NC}"
                    invalid_input=true
                    continue
                fi
                # 执行删除
                if iptables -D INPUT "$num"; then
                    echo -e "${GREEN}规则 ${num} 已删除�?{NC}"
                    ((deleted_count++))
                else
                    echo -e "${RED}删除规则 ${num} 失败 (可能行号不存�?�?{NC}"
                fi
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过�?{NC}"
            fi

            if (( deleted_count > 0 )); then
                echo -e "${GREEN}共删除了 ${deleted_count} 条规则�?{NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存�?{NC}" || echo -e "${RED}防火墙规则保存失败�?{NC}"
            else
                echo -e "${YELLOW}未执行任何有效删除操作�?{NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        3)
            echo -e "${BLUE}信息: 这将确保所有不在白名单的IP无法访问相关端口�?{NC}"
            for port in 53 80 443; do
                if ! iptables -C INPUT -p tcp --dport "$port" -j DROP &>/dev/null; then iptables -A INPUT -p tcp --dport "$port" -j DROP; fi
                if [[ "$port" == "53" ]]; then if ! iptables -C INPUT -p udp --dport "$port" -j DROP &>/dev/null; then iptables -A INPUT -p udp --dport "$port" -j DROP; fi; fi
            done
            echo -e "${GREEN}'默认拒绝' 规则已应�?确认存在�?{NC}"
            netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存�?{NC}" || echo -e "${RED}防火墙规则保存失败�?{NC}"
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
