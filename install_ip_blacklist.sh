#!/bin/bash

# 检查是否以root运行
if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本必须以root权限运行！"
    echo "请使用 'sudo bash $0'"
    exit 1
fi

# 安装基础依赖
echo "正在安装依赖：iproute2 iptables ipset"
apt-get update -qq > /dev/null
apt-get install -y -qq iproute2 iptables ipset > /dev/null

# 创建 /root/ip_blacklist.sh
echo "正在生成主脚本：/root/ip_blacklist.sh"
cat > /root/ip_blacklist.sh <<'EOF'
#!/bin/bash

# 检查是否以root运行
if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本必须以root权限运行！" 
    echo "请使用 'sudo bash $0'"
    exit 1
fi

# 依赖列表（Debian/Ubuntu包名）
REQUIRED_PKGS=("iproute2" "iptables" "ipset")

# 安装缺失的依赖
install_dependencies() {
    echo "正在更新软件包列表..."
    apt-get update -qq > /dev/null

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            echo "正在安装依赖：$pkg"
            apt-get install -y -qq $pkg > /dev/null
        fi
    done
}

# 检查内核模块是否加载
check_kernel_modules() {
    MODULES=("ip_tables" "ip_set")
    for mod in "${MODULES[@]}"; do
        if ! lsmod | grep -q "$mod"; then
            echo "正在加载内核模块：$mod"
            modprobe $mod
        fi
    done
}

# 创建日志文件并配置logrotate
init_logfile() {
    LOG_FILE="/var/log/iptables_ban.log"
    LOGROTATE_CONF="/etc/logrotate.d/iptables_ban"

    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        echo "已创建日志文件：$LOG_FILE"
    fi

    if [ ! -f "$LOGROTATE_CONF" ]; then
        cat > "$LOGROTATE_CONF" <<LOGR
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
        echo "已配置logrotate策略：$LOGROTATE_CONF"
    fi
}

#----- 主流程 -----
install_dependencies
check_kernel_modules
init_logfile

# 自动获取第一个状态为UP的非lo网卡
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | xargs -I {} sh -c 'if ip link show {} | grep -q "state UP"; then echo {}; fi' | head -n 1)

if [ -z "$INTERFACE" ]; then
    echo "未找到有效的网卡接口，脚本退出"
    exit 1
else
    echo "监控网卡: $INTERFACE"
fi

LIMIT=40
DURATION=1
UNBAN_TIME=86400
SSH_PORT=22
declare -A ip_first_seen

if ! ipset list banlist &>/dev/null; then
    ipset create banlist hash:ip timeout $UNBAN_TIME
fi
iptables -N TRAFFIC_BLOCK 2>/dev/null
iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP

while true; do
    RX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    TX_BYTES_1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
    sleep $DURATION
    RX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    TX_BYTES_2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)

    RX_RATE=$(( ($RX_BYTES_2 - $RX_BYTES_1) / 1024 / 1024 / $DURATION ))
    TX_RATE=$(( ($TX_BYTES_2 - $TX_BYTES_1) / 1024 / 1024 / $DURATION ))

    echo "[流量监控] 接收: ${RX_RATE}MB/s 发送: ${TX_RATE}MB/s"

    if [[ $RX_RATE -gt $LIMIT || $TX_RATE -gt $LIMIT ]]; then
        echo "== 检测到流量超限 =="
        IP_LIST=$(ss -ntu state established | awk -v port="$SSH_PORT" '
            NR > 1 {
                remote = $5;
                sub(/:[0-9]+$/, "", remote);
                gsub(/[\[\]]/, "", remote);
                sub(/^::ffff:/, "", remote);
                if ($5 !~ ":"port"$" && remote != "") {
                    print remote;
                }
            }' | sort | uniq -c | sort -nr)
        BAN_IP=$(echo "$IP_LIST" | awk '$2 != "" {print $2}' | head -n 1)
      
        if [[ -n "$BAN_IP" && "$BAN_IP" != "0.0.0.0" && "$BAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^([a-fA-F0-9]{1,4}:){1,7}(:[a-fA-F0-9]{1,4}){1,7}$ ]]; then
            current_time=$(date +%s)
            if [[ -z "${ip_first_seen[$BAN_IP]}" ]]; then
                ip_first_seen[$BAN_IP]=$current_time
                echo "首次检测到 $BAN_IP 超速，时间: $(date -d @$current_time '+%H:%M:%S')"
            else
                duration=$(( current_time - ip_first_seen[$BAN_IP] ))
                if (( duration >= 60 )); then
                    echo "== 正在封禁异常IP: $BAN_IP（持续超速 ${duration}秒）==="
                    ipset add banlist "$BAN_IP" timeout $UNBAN_TIME
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 封禁IP: $BAN_IP RX:${RX_RATE}MB/s TX:${TX_RATE}MB/s 持续:${duration}秒" >> /var/log/iptables_ban.log
                    unset ip_first_seen[$BAN_IP]
                else
                    echo "IP $BAN_IP 已超速 ${duration}秒（需满60秒触发封禁）"
                fi
            fi
        else
            echo "!! 未找到有效封禁目标（无效IP：${BAN_IP:-空}）"
        fi
    else
        ip_first_seen=()
    fi

    current_time=$(date +%s)
    for ip in "${!ip_first_seen[@]}"; do
        if (( current_time - ip_first_seen[$ip] > 60 )); then
            unset ip_first_seen[$ip]
            echo "清理过期IP记录: $ip"
        fi
    done
done
EOF

# 赋予执行权限
chmod +x /root/ip_blacklist.sh

# 创建 systemd 服务文件
echo "正在配置 systemd 服务"
cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP Blacklist Script
After=network.target

[Service]
ExecStart=/bin/bash /root/ip_blacklist.sh
Restart=always
User=root
WorkingDirectory=/root
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
EOF

# 重载并启动服务
systemctl daemon-reload
systemctl enable ip_blacklist.service --now

# 输出提示
echo "============================================="
echo "安装完成！服务已启动并设为开机自启。"
echo "查看实时日志命令："
echo "sudo journalctl -u ip_blacklist.service -f"
echo "============================================="
