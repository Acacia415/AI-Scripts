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

# 日志文件配置
LOG_FILE="/var/log/ip_defense.log"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
    exit 1
fi

# 日志记录函数
log() {
    local event_type=$1
    local message=$2
    echo -e "${CYAN}[$(date +'%F %T')] [$event_type] ${message}${NC}" | tee -a $LOG_FILE
    sync
}

# 加载白名单规则
load_rules() {
    if [ -f /etc/ipset.conf ]; then
        ipset restore -! < /etc/ipset.conf
        log "规则加载" "白名单规则已加载"
    fi
}

# 初始化防火墙规则
init_firewall() {
    # 创建黑名单集合
    if ! ipset list banlist &>/dev/null; then
        ipset create banlist hash:ip timeout 86400
        log "防火墙" "创建黑名单集合"
    fi
    
    # 创建白名单集合
    if ! ipset list whitelist &>/dev/null; then
        ipset create whitelist hash:ip
        log "防火墙" "创建白名单集合"
    fi

    # 创建流量监控链
    iptables -N TRAFFIC_BLOCK 2>/dev/null
    if ! iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null; then
        iptables -I INPUT -j TRAFFIC_BLOCK
        log "防火墙" "创建TRAFFIC_BLOCK链"
    fi
    
    # 设置规则
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP
}

# 实时日志分析
analyze_traffic() {
    log "监控启动" "开始实时分析Nginx日志"
    
    stdbuf -oL tail -Fn0 $NGINX_ACCESS_LOG | while read line; do
        {
            ip=$(echo "$line" | awk '{print $1}')
            path=$(echo "$line" | awk '{print $7}')
            status=$(echo "$line" | awk '{print $9}')
            timestamp=$(date +%s)
            
            echo -e "${CYAN}[实时处理] 正在分析 $ip 的请求：$path${NC}" | tee -a $LOG_FILE

            # 异常请求检测
            if [[ "$path" =~ \.php$ ]] && [[ "$status" == "404" ]]; then
                if ! ipset test whitelist $ip 2>/dev/null; then
                    ipset add banlist $ip 2>/dev/null
                    log "异常请求" "已封禁 $ip (原因：PHP探测)"
                fi
            fi

            # 高频请求检测
            req_count=$(grep $ip $NGINX_ACCESS_LOG | wc -l)
            if (( req_count > 100 )); then
                if ! ipset test whitelist $ip 2>/dev/null; then
                    ipset add banlist $ip 2>/dev/null
                    log "高频请求" "已封禁 $ip (请求次数：$req_count)"
                fi
            fi
        }
    done
}

# 主流程
load_rules
init_firewall
analyze_traffic
EOF

#---------- 白名单交互配置 ----------#
echo -e "\n\033[36m[4/4] 白名单配置\033[0m"
function validate_ip() {
    local ip=$1
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
    [[ $ip =~ $pattern ]] && return 0 || return 1
}

ipset create whitelist hash:ip 2>/dev/null || true

read -p $'\033[33m是否要配置白名单IP？(y/[n]) \033[0m' -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "\n\033[36m支持格式示例："
    echo -e "  单个IP: 192.168.1.1"
    echo -e "  IP段: 10.0.0.0/24"
    echo -e "  多个IP用空格分隔\033[0m"
    
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

#---------- 永久保存配置 ----------#
echo -e "\n\033[36m保存防火墙规则...\033[0m"
mkdir -p /etc/ipset
ipset save -f /etc/ipset.conf

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
echo -e "白名单IP列表："
ipset list whitelist -output save | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sed 's/^/  ➤ /'
echo -e "\n管理命令："
echo -e "  实时日志: tail -f ${LOG_FILE}"
echo -e "  服务状态: systemctl status ip_blacklist"
echo -e "  解封IP: ipset del banlist <IP>"
echo -e "  添加白名单: ipset add whitelist <IP>\033[0m"
