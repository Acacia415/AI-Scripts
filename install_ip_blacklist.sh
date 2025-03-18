#!/bin/bash

# 检查是否以root运行
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以root权限运行！\033[0m"
    echo "请使用 'sudo bash $0'"
    exit 1
fi

#---------- 依赖安装部分 ----------#
echo -e "\n\033[36m[1/4] 正在更新软件包列表...\033[0m"
apt-get update
if [ $? -ne 0 ]; then
    echo -e "\033[31m更新失败，请检查网络连接！\033[0m"
    exit 1
fi

echo -e "\n\033[36m[2/4] 正在安装核心依赖\033[0m"
for pkg in iproute2 iptables ipset; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo -e "正在安装 \033[34m$pkg\033[0m..."
        apt-get install -y $pkg
        if [ $? -ne 0 ]; then
            echo -e "\033[31m$pkg 安装失败！\033[0m"
            exit 1
        fi
    else
        echo -e "\033[32m$pkg 已安装，跳过\033[0m"
    fi
done

#---------- 生成主脚本 ----------#
echo -e "\n\033[36m[3/4] 生成主脚本到 /root/ip_blacklist.sh\033[0m"
cat > /root/ip_blacklist.sh <<'EOF'
#!/bin/bash

# 彩色输出定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
    echo "请使用 'sudo bash $0'"
    exit 1
fi

# 依赖检查与安装
install_dependencies() {
    echo -e "\n${CYAN}[1/3] 检查系统依赖...${NC}"
    local REQUIRED_PKGS=("iproute2" "iptables" "ipset")
    
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            echo -e "${RED}未找到 $pkg，正在安装...${NC}"
            apt-get update
            apt-get install -y $pkg || {
                echo -e "${RED}$pkg 安装失败！${NC}"
                exit 1
            }
        fi
    done
}

# 内核模块检查
check_kernel_modules() {
    echo -e "\n${CYAN}[2/3] 检查内核模块...${NC}"
    local MODULES=("ip_tables" "ip_set")
    
    for mod in "${MODULES[@]}"; do
        if ! lsmod | grep -q "$mod"; then
            echo -e "加载模块 ${YELLOW}$mod${NC}"
            modprobe $mod || {
                echo -e "${RED}无法加载模块 $mod${NC}"
                exit 1
            }
        fi
    done
}

# 初始化日志系统
init_logfile() {
    echo -e "\n${CYAN}[3/3] 初始化日志系统...${NC}"
    local LOG_FILE="/var/log/iptables_ban.log"
    
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "创建日志文件 ${BLUE}$LOG_FILE${NC}"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi

    # 配置 logrotate
    if [ ! -f "/etc/logrotate.d/iptables_ban" ]; then
        cat > /etc/logrotate.d/iptables_ban <<LOGR
$LOG_FILE {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
}
LOGR
        echo -e "已配置 ${BLUE}logrotate 策略${NC}"
    fi
}

#---------- 主流程 ----------#
echo -e "\n${GREEN}=== 初始化流量监控系统 ===${NC}"
install_dependencies
check_kernel_modules
init_logfile

# 获取活动网卡
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | xargs -I {} sh -c 'if ip link show {} | grep -q "state UP"; then echo {}; fi' | head -n 1)
if [ -z "$INTERFACE" ]; then
    echo -e "${RED}未找到有效的网卡接口！${NC}"
    exit 1
fi
echo -e "监控网卡: ${GREEN}$INTERFACE${NC}"

#---------- 配置防火墙规则 ----------#
LIMIT=40  # 流量阈值(MB/s)
UNBAN_TIME=86400  # 封禁时长(秒)

if ! ipset list banlist &>/dev/null; then
    echo -e "创建 ipset 黑名单..."
    ipset create banlist hash:ip timeout $UNBAN_TIME
fi

echo -e "配置 iptables 规则..."
iptables -N TRAFFIC_BLOCK 2>/dev/null
iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP

#---------- 流量监控循环 ----------#
echo -e "\n${GREEN}=== 启动流量监控（阈值 ${LIMIT}MB/s）===${NC}"
declare -A ip_first_seen

while true; do
    # 流量计算
    RX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    TX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
    sleep 1
    RX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    TX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)

    RX_RATE=$(( ($RX_BYTES_2 - $RX_BYTES_1) / 1024 / 1024 ))
    TX_RATE=$(( ($TX_BYTES_2 - $TX_BYTES_1) / 1024 / 1024 ))

    # 实时流量显示
    echo -e "[$(date +%H:%M:%S)] 接收: ${BLUE}${RX_RATE}MB/s${NC} 发送: ${CYAN}${TX_RATE}MB/s${NC}"
    
    # 流量超限处理
    if [[ $RX_RATE -gt $LIMIT || $TX_RATE -gt $LIMIT ]]; then
        echo -e "\n${YELLOW}⚠️  检测到流量超限！正在分析连接...${NC}"
        
        # 获取可疑IP（排除SSH连接）
        IP_LIST=$(ss -ntu state established | awk -v port=22 '
            NR > 1 {
                split($5, arr, ":");
                ip = arr[1];
                gsub(/[\[\]]/, "", ip);
                if (arr[2] != port && ip != "0.0.0.0") {
                    print ip;
                }
            }' | sort | uniq -c | sort -nr)
        
        BAN_IP=$(echo "$IP_LIST" | awk 'NR==1 && $2 != "" {print $2}')
        
        if [[ $BAN_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            current_time=$(date +%s)
            
            # 首次检测记录时间
            if [[ -z "${ip_first_seen[$BAN_IP]}" ]]; then
                ip_first_seen[$BAN_IP]=$current_time
                echo -e "首次发现 ${RED}$BAN_IP${NC} 超速于 $(date -d @$current_time '+%H:%M:%S')"
            else
                duration=$(( current_time - ip_first_seen[$BAN_IP] ))
                
                # 持续超速60秒触发封禁
                if (( duration >= 60 )); then
                    echo -e "${RED}🚫 封禁 $BAN_IP（持续超速 ${duration}秒）${NC}"
                    ipset add banlist "$BAN_IP" timeout $UNBAN_TIME
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 封禁 $BAN_IP RX:${RX_RATE}MB/s TX:${TX_RATE}MB/s 持续:${duration}秒" >> /var/log/iptables_ban.log
                    unset ip_first_seen[$BAN_IP]
                else
                    echo -e "IP ${YELLOW}$BAN_IP${NC} 已超速 ${duration}秒（需满60秒触发封禁）"
                fi
            fi
        else
            echo -e "${YELLOW}⚠️  未找到有效封禁目标${NC}"
        fi
    else
        ip_first_seen=()
    fi
done
EOF

#---------- 配置系统服务 ----------#
echo -e "\n\033[36m[4/4] 配置系统服务\033[0m"
chmod +x /root/ip_blacklist.sh

cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP Traffic Blacklist Service
After=network.target

[Service]
ExecStart=/bin/bash /root/ip_blacklist.sh
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ip_blacklist.service

# 安装完成提示
echo -e "\n\033[42m\033[30m 安装完成！\033[0m\033[32m 服务已启动\033[0m"
echo -e "查看状态:   systemctl status ip_blacklist.service"
echo -e "查看日志:   journalctl -u ip_blacklist.service -f"
echo -e "卸载方法:   systemctl disable --now ip_blacklist.service; rm /etc/systemd/system/ip_blacklist.service"
