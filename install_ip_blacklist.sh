#!/bin/bash

#---------- 初始化检查 ----------#
# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以root权限运行！\033[0m"
    echo "请使用 'sudo bash $0'"
    exit 1
fi

#---------- 依赖安装部分 ----------#
echo -e "\n\033[36m[1/4] 正在更新软件包列表...\033[0m"
apt-get update || {
    echo -e "\033[31m更新失败，请检查网络连接！\033[0m"
    exit 1
}

echo -e "\n\033[36m[2/4] 安装核心依赖\033[0m"
for pkg in iproute2 iptables ipset; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo -e "正在安装 \033[34m$pkg\033[0m..."
        if apt-get install -y $pkg; then
            echo -e "\033[32m$pkg 安装成功\033[0m"
        else
            echo -e "\033[31m$pkg 安装失败！\033[0m"
            exit 1
        fi
    else
        echo -e "\033[32m$pkg 已安装，跳过\033[0m"
    fi
done

#---------- 生成主监控脚本 ----------#
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
    exit 1
fi

# 加载ipset规则
if [ -f /etc/ipset.conf ]; then
    ipset restore -! < /etc/ipset.conf
fi

#---------- 核心初始化 ----------#
init_system() {
    # 创建ipset集合
    ipset create whitelist hash:ip timeout 0 2>/dev/null || true
    ipset create banlist hash:ip timeout 86400 2>/dev/null || true

    # 配置iptables规则
    iptables -N TRAFFIC_BLOCK 2>/dev/null
    iptables -F TRAFFIC_BLOCK 2>/dev/null
    
    # 白名单优先规则（必须放在链的最前面）
    iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP

    # 获取活动网卡
    INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | xargs -I {} sh -c 'if ip link show {} | grep -q "state UP"; then echo {}; fi' | head -n 1)
    [ -z "$INTERFACE" ] && {
        echo -e "${RED}未找到有效的网卡接口！${NC}"
        exit 1
    }
    echo -e "监控网卡: ${GREEN}$INTERFACE${NC}"
}

#---------- 流量监控逻辑 ----------#
start_monitor() {
    declare -A ip_first_seen
    LIMIT=40  # 流量阈值(MB/s)
    LOG_FILE="/var/log/iptables_ban.log"

    while true; do
        # 实时流量计算
        RX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
        sleep 1
        RX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
        TX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)

        RX_RATE=$(( ($RX_BYTES_2 - $RX_BYTES_1) / 1024 / 1024 ))
        TX_RATE=$(( ($TX_BYTES_2 - $TX_BYTES_1) / 1024 / 1024 ))

        echo -e "[$(date +%H:%M:%S)] 接收: ${BLUE}${RX_RATE}MB/s${NC} 发送: ${CYAN}${TX_RATE}MB/s${NC}"

        # 超速处理逻辑
        if [[ $RX_RATE -gt $LIMIT || $TX_RATE -gt $LIMIT ]]; then
            echo -e "\n${YELLOW}⚠️  检测到流量超限！正在分析连接...${NC}"
            
            # 获取可疑IP（排除SSH和白名单）
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
            
            # 跳过白名单IP
            if [[ -n "$BAN_IP" ]] && ! ipset test whitelist "$BAN_IP" &>/dev/null; then
                current_time=$(date +%s)
                
                if [[ -z "${ip_first_seen[$BAN_IP]}" ]]; then
                    ip_first_seen[$BAN_IP]=$current_time
                    echo -e "首次发现 ${RED}$BAN_IP${NC} 超速于 $(date -d @$current_time '+%H:%M:%S')"
                else
                    duration=$(( current_time - ip_first_seen[$BAN_IP] ))
                    
                    if (( duration >= 60 )); then
                        echo -e "${RED}🚫 封禁 $BAN_IP（持续超速 ${duration}秒）${NC}"
                        ipset add banlist "$BAN_IP" timeout 86400
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 封禁 $BAN_IP RX:${RX_RATE}MB/s TX:${TX_RATE}MB/s 持续:${duration}秒" >> $LOG_FILE
                        unset ip_first_seen[$BAN_IP]
                    else
                        echo -e "IP ${YELLOW}$BAN_IP${NC} 已超速 ${duration}秒（需满60秒触发封禁）"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠️  未找到有效封禁目标或目标在白名单中${NC}"
            fi
        else
            ip_first_seen=()
        fi
    done
}

# 主执行流程
init_system
start_monitor
EOF

#---------- 白名单交互配置 ----------#
echo -e "\n\033[36m[4/4] 白名单配置\033[0m"
function validate_ip() {
    local ip=$1
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
    [[ $ip =~ $pattern ]] && return 0 || return 1
}

# 创建白名单集合
ipset create whitelist hash:ip 2>/dev/null || true

# 交互式配置
read -p $'\033[33m是否要配置白名单IP？(y/[n]) \033[0m' -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\n\033[36m请输入IP地址（支持格式示例）："
    echo -e "  • 单个IP: 192.168.1.1\n  • IP段: 10.0.0.0/24\n  • 多个IP用空格分隔\033[0m"
    
    while :; do
        read -p $'\033[33m请输入IP（输入 done 结束）: \033[0m' input
        [[ "$input" == "done" ]] && break
        
        IFS=' ' read -ra ips <<< "$input"
        for ip in "${ips[@]}"; do
            if validate_ip "$ip"; then
                if ipset add whitelist "$ip" 2>/dev/null; then
                    echo -e "\033[32m ✓ 成功添加：$ip\033[0m"
                else
                    echo -e "\033[33m ⚠️  已存在：$ip\033[0m"
                fi
            else
                echo -e "\033[31m ✗ 无效格式：$ip\033[0m"
            fi
        done
    done
fi

# 永久保存配置
echo -e "\n\033[36m保存防火墙规则...\033[0m"
mkdir -p /etc/ipset
ipset save whitelist > /etc/ipset.conf
ipset save banlist >> /etc/ipset.conf
echo -e "iptables规则保存到 /etc/iptables/rules.v4"
iptables-save > /etc/iptables/rules.v4

#---------- 系统服务配置 ----------#
echo -e "\n\033[36m[5/5] 配置系统服务\033[0m"
chmod +x /root/ip_blacklist.sh

cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP流量监控与封禁服务
After=network.target

[Service]
ExecStart=/bin/bash /root/ip_blacklist.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ip_blacklist.service

# 完成提示
echo -e "\n\033[42m\033[30m 部署完成！\033[0m\033[32m"
echo -e "已添加白名单IP："
ipset list whitelist -output save | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sed 's/^/  ➤ /'
echo -e "\n管理命令："
echo -e "  实时日志: journalctl -u ip_blacklist.service -f"
echo -e "  临时解封: ipset del banlist <IP地址>"
echo -e "  添加白名单: ipset add whitelist <IP地址>\033[0m"
