#!/bin/bash

# ============================================
# 流量监控管理系统 v2.0
# ============================================

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; NC='\033[0m'

CONFIG_DIR="/etc/traffic_monitor"
SERVICE_FILE="/etc/systemd/system/ip_blacklist.service"
LOG_FILE="/var/log/iptables_ban.log"
PORTS_CONFIG="$CONFIG_DIR/monitored_ports.conf"
DURATION_CONFIG="$CONFIG_DIR/duration.conf"
THRESHOLD_CONFIG="$CONFIG_DIR/threshold.conf"
SCRIPT_PATH="$(readlink -f "$0")"

check_root() {
    [ "$EUID" -ne 0 ] && echo -e "${RED}错误：需要root权限${NC}" && exit 1
}

check_dependencies() {
    local deps=("ipset" "iptables" "ip" "bc" "ss" "gawk")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v $dep &>/dev/null || missing+=("$dep")
    done
    
    [ ${#missing[@]} -eq 0 ] && return 0
    
    echo -e "${YELLOW}检测到缺失依赖: ${missing[*]}${NC}"
    echo -e "${CYAN}开始安装依赖包...${NC}\n"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) 
                echo -e "${BLUE}更新软件包列表...${NC}"
                apt-get update
                echo -e "\n${BLUE}安装依赖包...${NC}"
                apt-get install -y ipset iptables iproute2 bc gawk
                ;;
            centos|rhel|rocky|alma*|fedora) 
                echo -e "${BLUE}安装依赖包...${NC}"
                command -v dnf &>/dev/null && dnf install -y ipset iptables iproute bc gawk || yum install -y ipset iptables iproute bc gawk
                ;;
            alpine) 
                echo -e "${BLUE}安装依赖包...${NC}"
                apk add --no-cache ipset iptables iproute2 bc gawk
                ;;
            arch|manjaro) 
                echo -e "${BLUE}安装依赖包...${NC}"
                pacman -S --noconfirm ipset iptables iproute2 bc gawk
                ;;
            *) 
                echo -e "${RED}不支持的系统: $ID${NC}"
                echo -e "${YELLOW}请手动安装: ipset iptables iproute2 bc gawk${NC}"
                return 1
                ;;
        esac
    fi
    
    echo -e "\n${GREEN}✓ 依赖安装完成${NC}"
}

validate_ip() { [[ $1 =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/([12][0-9]|3[0-2]|[0-9]))?$ ]]; }
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && [ $1 -ge 1 ] && [ $1 -le 65535 ]; }
pause() { echo ""; read -n 1 -s -r -p "按任意键继续..."; echo ""; }

# ============================================
# 监控核心功能（作为daemon运行）
# ============================================

run_monitor() {
    [ -f /etc/ipset.conf ] && ipset restore -! < /etc/ipset.conf
    
    ipset create whitelist hash:ip timeout 0 2>/dev/null || true
    ipset create banlist hash:ip timeout 86400 2>/dev/null || true
    iptables -N TRAFFIC_BLOCK 2>/dev/null
    iptables -F TRAFFIC_BLOCK 2>/dev/null
    iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP
    
    INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    [ -z "$INTERFACE" ] && echo -e "${RED}未找到网卡${NC}" && exit 1
    echo -e "监控网卡: ${GREEN}$INTERFACE${NC}"
    
    [ -f "$PORTS_CONFIG" ] && FILTER_PORTS=$(cat "$PORTS_CONFIG") && echo -e "端口过滤: ${CYAN}$FILTER_PORTS${NC}" || FILTER_PORTS=""
    [ -f "$THRESHOLD_CONFIG" ] && LIMIT=$(cat "$THRESHOLD_CONFIG") || LIMIT=20
    [ -f "$DURATION_CONFIG" ] && DURATION=$(cat "$DURATION_CONFIG") || DURATION=60
    
    echo -e "流量阈值: ${YELLOW}${LIMIT}MB/s${NC}"
    echo -e "持续时间: ${YELLOW}${DURATION}秒${NC}"
    
    declare -A ip_first_seen
    
    while true; do
        RX1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
        sleep 1
        RX2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
        RX_RATE=$(echo "scale=2; ($RX2 - $RX1) / 1048576" | bc)
        TX_RATE=$(echo "scale=2; ($TX2 - $TX1) / 1048576" | bc)
        echo -e "[$(date +%H:%M:%S)] RX: ${BLUE}${RX_RATE}MB/s${NC} TX: ${CYAN}${TX_RATE}MB/s${NC}"
        
        if (( $(echo "$RX_RATE > $LIMIT || $TX_RATE > $LIMIT" | bc -l) )); then
            echo -e "${YELLOW}⚠️  流量超限${NC}"
            
            if [ -n "$FILTER_PORTS" ]; then
                IP_LIST=$(ss -ntu state established | gawk -v ports="$FILTER_PORTS" '
                    BEGIN { split(ports, pa, ","); for(i in pa) pmap[pa[i]]=1 }
                    NR > 1 {
                        match($4, /:([0-9]+)$/, lp);
                        if(lp[1] in pmap) {
                            match($5, /:([0-9]+)$/, rp);
                            ip = gensub(/\[|\]/, "", "g", substr($5, 1, RSTART-1));
                            if(ip != "0.0.0.0" && ip != "::") print ip;
                        }
                    }' | sort | uniq -c | sort -nr)
            else
                IP_LIST=$(ss -ntu state established | gawk -v port=22 '
                    NR > 1 {
                        match($5, /:([0-9]+)$/, port_arr);
                        current_port = port_arr[1];
                        ip = gensub(/\[|\]/, "", "g", substr($5, 1, RSTART-1));
                        if (current_port != port && ip != "0.0.0.0") print ip;
                    }' | sort | uniq -c | sort -nr)
            fi
            
            BAN_IP=$(echo "$IP_LIST" | awk 'NR==1 && $2 != "" {print $2}')
            
            if [[ -n "$BAN_IP" ]] && ! ipset test whitelist "$BAN_IP" &>/dev/null; then
                ct=$(date +%s)
                if [[ -z "${ip_first_seen[$BAN_IP]}" ]]; then
                    ip_first_seen[$BAN_IP]=$ct
                    echo -e "检测 ${RED}$BAN_IP${NC} 超速"
                else
                    dur=$(( ct - ip_first_seen[$BAN_IP] ))
                    if (( dur >= DURATION )); then
                        # 去除IPv6映射前缀
                        CLEAN_IP="${BAN_IP#::ffff:}"
                        echo -e "${RED}🚫 封禁 $CLEAN_IP (${dur}秒)${NC}"
                        ipset add banlist "$CLEAN_IP" timeout 86400
                        echo "[BAN]|$(date '+%Y-%m-%d %H:%M:%S')|$CLEAN_IP|RX:${RX_RATE}MB/s|TX:${TX_RATE}MB/s|持续:${dur}秒" >> "$LOG_FILE"
                        unset ip_first_seen[$BAN_IP]
                    else
                        echo -e "${YELLOW}$BAN_IP 超速 ${dur}秒 (需${DURATION}秒)${NC}"
                    fi
                fi
            fi
        else
            ip_first_seen=()
        fi
        sleep 0.5
    done
}

# ============================================
# 安装
# ============================================

install_monitor() {
    clear
    echo -e "${CYAN}════════════════════════════════${NC}"
    echo -e "${GREEN}    安装流量监控服务${NC}"
    echo -e "${CYAN}════════════════════════════════${NC}\n"
    
    systemctl is-active --quiet ip_blacklist.service && {
        echo -e "${YELLOW}服务已运行${NC}"
        read -p "重新安装? [y/N] " c
        [[ ! "$c" =~ [yY] ]] && return
        systemctl stop ip_blacklist.service
    }
    
    mkdir -p "$CONFIG_DIR"
    
    echo -e "${CYAN}[1/5] 端口过滤配置${NC}"
    read -p "启用端口过滤? [y/N] " pf
    if [[ "${pf,,}" == "y" ]]; then
        echo -e "${YELLOW}输入监控端口(空格分隔): ${NC}"
        read -p "端口: " ports
        valid_ports=()
        for p in $ports; do
            validate_port "$p" && valid_ports+=("$p") || echo -e "${RED}✗ 无效: $p${NC}"
        done
        [ ${#valid_ports[@]} -gt 0 ] && {
            echo $(IFS=,; echo "${valid_ports[*]}") > "$PORTS_CONFIG"
            echo -e "${GREEN}✓ 端口: ${valid_ports[*]}${NC}"
        }
    else
        rm -f "$PORTS_CONFIG"
    fi
    
    echo -e "\n${CYAN}[2/5] 流量阈值${NC}"
    read -p "阈值(MB/s) [默认20]: " th
    th=${th:-20}
    echo "$th" > "$THRESHOLD_CONFIG"
    echo -e "${GREEN}✓ 阈值: ${th}MB/s${NC}"
    
    echo -e "\n${CYAN}[3/5] 持续时间${NC}"
    echo -e "${YELLOW}超速持续多少秒后触发封禁${NC}"
    read -p "持续时间(秒) [默认60]: " dur
    dur=${dur:-60}
    echo "$dur" > "$DURATION_CONFIG"
    echo -e "${GREEN}✓ 持续时间: ${dur}秒${NC}"
    
    echo -e "\n${CYAN}[4/5] 白名单${NC}"
    ipset create whitelist hash:ip 2>/dev/null || true
    read -p "添加白名单? [y/N] " aw
    [[ "${aw,,}" == "y" ]] && add_whitelist_batch
    
    mkdir -p /etc/ipset
    ipset save > /etc/ipset.conf
    
    echo -e "\n${CYAN}[5/5] 创建服务${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IP流量监控服务
After=network-online.target
[Service]
ExecStart=$SCRIPT_PATH monitor
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    
    cat > /etc/logrotate.d/iptables_ban <<'LR'
/var/log/iptables_ban.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
}
LR
    
    systemctl daemon-reload
    systemctl enable --now ip_blacklist.service
    echo -e "\n${GREEN}✅ 安装完成${NC}"
    pause
}

# ============================================
# 卸载
# ============================================

uninstall_monitor() {
    clear
    echo -e "${RED}════════════════════════════════${NC}"
    echo -e "${RED}    卸载流量监控${NC}"
    echo -e "${RED}════════════════════════════════${NC}\n"
    read -p "确认卸载? [y/N] " c
    [[ ! "$c" =~ [yY] ]] && return
    
    systemctl disable --now ip_blacklist.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true
    iptables -F TRAFFIC_BLOCK 2>/dev/null || true
    iptables -X TRAFFIC_BLOCK 2>/dev/null || true
    ipset flush whitelist 2>/dev/null && ipset destroy whitelist 2>/dev/null || true
    ipset flush banlist 2>/dev/null && ipset destroy banlist 2>/dev/null || true
    rm -rf "$CONFIG_DIR"
    rm -f /etc/ipset.conf /etc/logrotate.d/iptables_ban
    systemctl daemon-reload
    echo -e "${GREEN}✅ 卸载完成${NC}"
    pause
}

# ============================================
# 端口管理
# ============================================

manage_ports() {
    while true; do
        clear
        echo -e "${CYAN}════════════════════════════════${NC}"
        echo -e "${GREEN}    端口过滤管理${NC}"
        echo -e "${CYAN}════════════════════════════════${NC}\n"
        
        [ -f "$PORTS_CONFIG" ] && echo -e "${YELLOW}当前: ${NC}${GREEN}$(cat $PORTS_CONFIG)${NC}" || echo -e "${YELLOW}当前: 监控所有端口${NC}"
        
        echo -e "\n${CYAN}1.${NC} 设置端口过滤"
        echo -e "${CYAN}2.${NC} 添加端口"
        echo -e "${CYAN}3.${NC} 删除端口"
        echo -e "${CYAN}4.${NC} 禁用过滤"
        echo -e "${CYAN}0.${NC} 返回\n"
        read -p "选择: " c
        
        case $c in
            1)
                echo -e "\n${YELLOW}输入端口(空格分隔): ${NC}"
                read -p "端口: " ports
                valid=()
                for p in $ports; do
                    validate_port "$p" && valid+=("$p") || echo -e "${RED}✗ $p${NC}"
                done
                [ ${#valid[@]} -gt 0 ] && {
                    mkdir -p "$CONFIG_DIR"
                    echo $(IFS=,; echo "${valid[*]}") > "$PORTS_CONFIG"
                    echo -e "${GREEN}✓ 已设置${NC}"
                    systemctl is-active --quiet ip_blacklist.service && systemctl restart ip_blacklist.service
                }
                pause
                ;;
            2)
                [ ! -f "$PORTS_CONFIG" ] && { echo -e "${RED}请先设置端口${NC}"; pause; continue; }
                echo -e "\n${YELLOW}添加端口: ${NC}"
                read -p "端口: " ports
                curr=$(cat "$PORTS_CONFIG" | tr ',' ' ')
                for p in $ports; do
                    validate_port "$p" && {
                        [[ ! " $curr " =~ " $p " ]] && curr="$curr $p" && echo -e "${GREEN}✓ $p${NC}"
                    }
                done
                echo $(echo $curr | tr ' ' ',') | sed 's/^,//' > "$PORTS_CONFIG"
                systemctl is-active --quiet ip_blacklist.service && systemctl restart ip_blacklist.service
                pause
                ;;
            3)
                [ ! -f "$PORTS_CONFIG" ] && { echo -e "${RED}未启用${NC}"; pause; continue; }
                echo -e "\n${YELLOW}删除端口: ${NC}"
                read -p "端口: " ports
                curr=$(cat "$PORTS_CONFIG" | tr ',' ' ')
                for p in $ports; do
                    curr=$(echo $curr | sed "s/\b$p\b//g" | tr -s ' ')
                done
                [ -n "$curr" ] && echo $(echo $curr | tr ' ' ',') | sed 's/^,//' > "$PORTS_CONFIG" || rm -f "$PORTS_CONFIG"
                systemctl is-active --quiet ip_blacklist.service && systemctl restart ip_blacklist.service
                echo -e "${GREEN}✓ 完成${NC}"
                pause
                ;;
            4)
                rm -f "$PORTS_CONFIG"
                systemctl is-active --quiet ip_blacklist.service && systemctl restart ip_blacklist.service
                echo -e "${GREEN}✓ 已禁用${NC}"
                pause
                ;;
            0) return ;;
        esac
    done
}

# ============================================
# 白名单/黑名单管理（简化版）
# ============================================

add_whitelist_batch() {
    echo -e "${CYAN}输入IP(空格分隔, 0结束):${NC}"
    while read -p "IP: " ips; do
        [ "$ips" == "0" ] && break
        for ip in $ips; do
            validate_ip "$ip" && {
                ipset add whitelist "$ip" 2>/dev/null && echo -e "${GREEN}✓ $ip${NC}" || echo -e "${YELLOW}已存在: $ip${NC}"
            } || echo -e "${RED}✗ 无效: $ip${NC}"
        done
    done
    ipset save > /etc/ipset.conf
}

manage_whitelist() {
    while true; do
        clear
        echo -e "${CYAN}════════════════════════════════${NC}"
        echo -e "${GREEN}    白名单管理${NC}"
        echo -e "${CYAN}════════════════════════════════${NC}\n"
        ipset list whitelist &>/dev/null || ipset create whitelist hash:ip 2>/dev/null
        echo -e "${CYAN}1.${NC} 添加IP\n${CYAN}2.${NC} 查看列表\n${CYAN}3.${NC} 删除IP\n${CYAN}0.${NC} 返回\n"
        read -p "选择: " c
        case $c in
            1) add_whitelist_batch; pause ;;
            2) echo -e "\n${YELLOW}白名单:${NC}"; ipset list whitelist | grep -E '^[0-9]' | nl; pause ;;
            3)
                list=$(ipset list whitelist | grep -E '^[0-9]')
                [ -z "$list" ] && { echo -e "${YELLOW}空${NC}"; pause; continue; }
                echo "$list" | nl
                echo -e "\n${YELLOW}输入序号或IP(空格分隔): ${NC}"
                read -p "序号/IP: " inputs
                mapfile -t ip_array < <(echo "$list" | awk '{print $1}')
                for input in $inputs; do
                    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#ip_array[@]}" ]; then
                        # 序号
                        idx=$((input - 1))
                        ip="${ip_array[$idx]}"
                        ipset del whitelist "$ip" 2>/dev/null && echo -e "${GREEN}✓ [$input] $ip${NC}" || echo -e "${RED}✗ $ip${NC}"
                    else
                        # IP地址
                        ipset del whitelist "$input" 2>/dev/null && echo -e "${GREEN}✓ $input${NC}" || echo -e "${RED}✗ $input${NC}"
                    fi
                done
                ipset save > /etc/ipset.conf
                pause
                ;;
            0) return ;;
        esac
    done
}

manage_blacklist() {
    while true; do
        clear
        echo -e "${CYAN}════════════════════════════════${NC}"
        echo -e "${GREEN}    黑名单管理${NC}"
        echo -e "${CYAN}════════════════════════════════${NC}\n"
        ipset list banlist &>/dev/null || ipset create banlist hash:ip timeout 86400 2>/dev/null
        echo -e "${CYAN}1.${NC} 添加IP\n${CYAN}2.${NC} 查看列表\n${CYAN}3.${NC} 删除IP\n${CYAN}0.${NC} 返回\n"
        read -p "选择: " c
        case $c in
            1)
                echo -e "\n${YELLOW}输入IP(空格分隔, 0结束):${NC}"
                while read -p "IP: " ips; do
                    [ "$ips" == "0" ] && break
                    for ip in $ips; do
                        validate_ip "$ip" && ipset add banlist "$ip" timeout 86400 2>/dev/null && echo -e "${GREEN}✓ $ip${NC}" || echo -e "${RED}✗ $ip${NC}"
                    done
                done
                ipset save > /etc/ipset.conf
                pause
                ;;
            2) echo -e "\n${YELLOW}黑名单:${NC}"; ipset list banlist | grep -E '^[0-9]' | nl; pause ;;
            3)
                list=$(ipset list banlist | grep -E '^[0-9]')
                [ -z "$list" ] && { echo -e "${YELLOW}空${NC}"; pause; continue; }
                echo "$list" | nl
                echo -e "\n${YELLOW}输入序号或IP(空格分隔): ${NC}"
                read -p "序号/IP: " inputs
                mapfile -t ip_array < <(echo "$list" | awk '{print $1}')
                for input in $inputs; do
                    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#ip_array[@]}" ]; then
                        # 序号
                        idx=$((input - 1))
                        ip="${ip_array[$idx]}"
                        ipset del banlist "$ip" 2>/dev/null && echo -e "${GREEN}✓ [$input] $ip${NC}" || echo -e "${RED}✗ $ip${NC}"
                    else
                        # IP地址
                        ipset del banlist "$input" 2>/dev/null && echo -e "${GREEN}✓ $input${NC}" || echo -e "${RED}✗ $input${NC}"
                    fi
                done
                ipset save > /etc/ipset.conf
                pause
                ;;
            0) return ;;
        esac
    done
}

# ============================================
# 日志管理
# ============================================

manage_logs() {
    while true; do
        clear
        echo -e "${CYAN}════════════════════════════════${NC}"
        echo -e "${GREEN}    封禁日志管理${NC}"
        echo -e "${CYAN}════════════════════════════════${NC}\n"
        [ -f "$LOG_FILE" ] && {
            total=$(grep -c '^\[BAN\]' "$LOG_FILE" 2>/dev/null || echo 0)
            echo -e "${YELLOW}共 ${total} 条封禁记录${NC}\n"
        } || echo -e "${YELLOW}暂无日志${NC}\n"
        echo -e "${CYAN}1.${NC} 查看全部\n${CYAN}2.${NC} 查看最近\n${CYAN}3.${NC} 清空日志\n${CYAN}0.${NC} 返回\n"
        read -p "选择: " c
        case $c in
            1) [ -f "$LOG_FILE" ] && { echo -e "\n${YELLOW}封禁记录:${NC}"; grep '^\[BAN\]' "$LOG_FILE" | nl | tail -50; } || echo -e "${YELLOW}无日志${NC}"; pause ;;
            2) [ -f "$LOG_FILE" ] && { echo -e "\n${YELLOW}最近10条:${NC}"; grep '^\[BAN\]' "$LOG_FILE" | tail -10 | nl; } || echo -e "${YELLOW}无日志${NC}"; pause ;;
            3) read -p "确认清空? [y/N] " cf; [[ "$cf" =~ [yY] ]] && > "$LOG_FILE" && echo -e "${GREEN}✓ 已清空${NC}"; pause ;;
            0) return ;;
        esac
    done
}

# ============================================
# 主菜单
# ============================================

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}    ${CYAN}流量监控管理系统 v2.0${NC}     ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════╝${NC}\n"
        
        systemctl is-active --quiet ip_blacklist.service && echo -e "${GREEN}● 服务状态: 运行中${NC}\n" || echo -e "${YELLOW}○ 服务状态: 未运行${NC}\n"
        
        echo -e "${CYAN}1.${NC} 安装流量监控"
        echo -e "${CYAN}2.${NC} 卸载流量监控"
        echo -e "${CYAN}3.${NC} 端口过滤管理"
        echo -e "${CYAN}4.${NC} 白名单管理"
        echo -e "${CYAN}5.${NC} 黑名单管理"
        echo -e "${CYAN}6.${NC} 封禁日志管理"
        echo -e "${CYAN}7.${NC} 查看服务状态"
        echo -e "${CYAN}0.${NC} 退出\n"
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_monitor ;;
            2) uninstall_monitor ;;
            3) manage_ports ;;
            4) manage_whitelist ;;
            5) manage_blacklist ;;
            6) manage_logs ;;
            7)
                clear
                systemctl status ip_blacklist.service
                echo -e "\n${CYAN}实时日志:${NC}"
                journalctl -u ip_blacklist.service -n 20 --no-pager
                pause
                ;;
            0) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ============================================
# 启动入口
# ============================================

check_root

# 如果以monitor参数运行，启动监控模式
if [ "$1" == "monitor" ]; then
    run_monitor
    exit 0
fi

# 否则进入管理菜单
check_dependencies
main_menu
