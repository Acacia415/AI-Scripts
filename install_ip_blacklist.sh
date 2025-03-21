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
#!/bin/bash -e

# 强制实时输出日志
exec > >(systemd-cat -t ip_blacklist) 2>&1
export SYSTEMD_LOG_TARGET=journal
export SYSTEMD_LOG_LEVEL=debug

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

# 加载白名单规则
if [ -f /etc/ipset.conf ]; then
    echo -e "${CYAN}[+] 加载白名单规则...${NC}"
    ipset restore -! < /etc/ipset.conf
fi

# 初始化防火墙规则
init_firewall() {
    echo -e "${CYAN}[+] 初始化防火墙规则...${NC}"
    
    # 创建黑名单集合
    if ! ipset list banlist &>/dev/null; then
        ipset create banlist hash:ip timeout 86400
        echo -e "${GREEN} ✓ 创建黑名单集合 banlist${NC}"
    fi
    
    # 创建白名单集合
    if ! ipset list whitelist &>/dev/null; then
        ipset create whitelist hash:ip
        echo -e "${GREEN} ✓ 创建白名单集合 whitelist${NC}"
    fi

    # 创建流量监控链
    if ! iptables -nL TRAFFIC_BLOCK &>/dev/null; then
        iptables -N TRAFFIC_BLOCK
        iptables -I INPUT -j TRAFFIC_BLOCK
        echo -e "${GREEN} ✓ 创建流量监控链 TRAFFIC_BLOCK${NC}"
    fi

    # 清空旧规则
    iptables -F TRAFFIC_BLOCK
    
    # 白名单优先规则
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP
    echo -e "${GREEN} ✓ 设置白名单优先规则${NC}"
}

# 流量监控逻辑
start_monitor() {
    echo -e "${CYAN}[+] 启动流量监控...${NC}"
    while true; do
        # 获取当前时间
        timestamp=$(date "+%Y-%m-%d %T")
        
        # 监控流量异常的IP（示例条件：60秒内超过100个连接）
        offenders=$(netstat -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -n | awk '$1 > 100')
        
        if [ -n "$offenders" ]; then
            echo -e "${YELLOW}[$timestamp] 检测到以下异常连接：${NC}"
            printf "%-8s %s\n" "连接数" "IP地址"
            echo "----------------------"
            while read -r line; do
                count=$(echo $line | awk '{print $1}')
                ip=$(echo $line | awk '{print $2}')
                # 检查白名单
                if ipset test whitelist "$ip" 2>/dev/null; then
                    echo -e "${GREEN} ✓ $count\t$ip (白名单)${NC}"
                else
                    echo -e "${RED} ⚠️ $count\t$ip 加入黑名单${NC}"
                    ipset add banlist "$ip" 2>/dev/null
                fi
            done <<< "$offenders"
        else
            echo -e "${CYAN}[$timestamp] 未检测到异常连接${NC}"
        fi
        
        sleep 10  # 检测间隔改为10秒
    done
}

# 主执行流程
init_firewall
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
ipset save -file /etc/ipset.conf 2>/dev/null || {
    echo -e "\033[31m无法保存ipset配置，请手动执行：ipset save > /etc/ipset.conf\033[0m"
}

#---------- 系统服务配置 ----------#
echo -e "\n\033[36m[5/5] 配置系统服务\033[0m"
chmod +x /root/ip_blacklist.sh

cat > /etc/systemd/system/ip_blacklist.service <<'EOF'
[Unit]
Description=IP流量监控与封禁服务
After=network.target

[Service]
Environment=SYSTEMD_LOG_TARGET=journal
Environment=SYSTEMD_LOG_LEVEL=debug
ExecStart=/bin/bash -e /root/ip_blacklist.sh
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=0

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
echo -e "  实时日志: journalctl -u ip_blacklist.service -f --output cat"
echo -e "  临时解封: ipset del banlist <IP地址>"
echo -e "  添加白名单: ipset add whitelist <IP地址>\033[0m"
