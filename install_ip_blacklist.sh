#!/bin/bash

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以root权限运行！\033[0m"
    exit 1
fi

#---------- 交互式配置 ----------#
echo -e "\n\033[36m[1/4] 配置白名单IP（输入空行结束）\033[0m"
WHITELIST=()
while true; do
    read -p "请输入白名单IP/CIDR (例: 192.168.1.0/24): " ip
    [[ -z $ip ]] && break
    
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        WHITELIST+=("$ip")
        echo -e "\033[32m已添加：$ip\033[0m"
    else
        echo -e "\033[31m错误格式，请重新输入\033[0m"
    fi
done

#---------- 固定配置 ----------#
SPEED_LIMIT=20    # 限速阈值(MB/s)
CHECK_INTERVAL=10 # 检查间隔(秒)
BAN_HOURS=24      # 封禁时长(小时)

#---------- 单位转换 ----------#
LIMIT_BYTES=$(( SPEED_LIMIT * 1048576 * CHECK_INTERVAL ))

#---------- 依赖安装 ----------#
echo -e "\n\033[36m[2/4] 安装系统依赖...\033[0m"
apt-get update >/dev/null
apt-get install -y ipset >/dev/null

#---------- 初始化防火墙 ----------#
echo -e "\n\033[36m[3/4] 配置流量监控规则...\033[0m"

# 创建ipset集合
ipset create speed_ban hash:ip timeout $(( BAN_HOURS * 3600 )) 2>/dev/null || true

# 重建iptables链
iptables -t mangle -F 2>/dev/null
iptables -t mangle -X SPEED_MONITOR 2>/dev/null || true
iptables -t mangle -N SPEED_MONITOR

# 设置白名单规则
for ip in "${WHITELIST[@]}"; do
    iptables -t mangle -A SPEED_MONITOR -s $ip -j RETURN
    iptables -t mangle -A SPEED_MONITOR -d $ip -j RETURN
done

# 设置监控规则
iptables -t mangle -A SPEED_MONITOR -m set --match-set speed_ban src -j RETURN
iptables -t mangle -A SPEED_MONITOR -m set --match-set speed_ban dst -j RETURN
iptables -t mangle -A SPEED_MONITOR -j MARK --set-mark 0x1
iptables -t mangle -I FORWARD -j SPEED_MONITOR

#---------- 部署监控服务 ----------#
echo -e "\n\033[36m[4/4] 部署监控服务...\033[0m"

# 创建监控脚本
cat > /usr/local/sbin/speed_monitor <<EOF
#!/bin/bash
# 初始化计数
declare -A prev_count

while true; do
    # 获取当前所有连接IP（排除内网）
    current_ips=\$(ss -ntu | awk '\$6!~/^(10|127|192.168|172.(1[6-9]|2[0-9]|3[0-1])|169.254)/{split(\$6,ip,":");print ip[1]}' | sort -u)

    # 获取每个IP的流量计数
    declare -A curr_count
    for ip in \$current_ips; do
        curr_count[\$ip]=\$(iptables -t mangle -L SPEED_MONITOR -v -x 2>/dev/null | awk -v ip=\$ip '\$8 == ip {sum += \$2} END {print sum}')
    done

    # 计算速率并封禁
    for ip in "\${!curr_count[@]}"; do
        delta=\$(( \${curr_count[\$ip]} - \${prev_count[\$ip]:-0} ))
        
        if [[ \$delta -gt $LIMIT_BYTES ]]; then
            echo "\$(date "+%F %T") 封禁 \$ip 流量: \$(( delta/1048576 ))MB/10s" >> /var/log/speed_monitor.log
            ipset add speed_ban \$ip 2>/dev/null
        fi
        prev_count[\$ip]=\${curr_count[\$ip]}
    done

    sleep $CHECK_INTERVAL
done
EOF

# 设置权限
chmod 755 /usr/local/sbin/speed_monitor

# 创建系统服务
cat > /etc/systemd/system/speed-monitor.service <<EOF
[Unit]
Description=Real-time Speed Monitor
After=network.target

[Service]
ExecStart=/usr/local/sbin/speed_monitor
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable --now speed-monitor >/dev/null

echo -e "\n\033[32m部署完成！\n封禁记录：tail -f /var/log/speed_monitor.log\n当前黑名单：ipset list speed_ban\033[0m"
