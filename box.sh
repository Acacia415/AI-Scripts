#!/bin/bash

# ==========================================
# IRIS自用工具箱 - GitHub一键版
# 功能：1.开启root登录 2.安装流量监控 3.卸载流量监控
# 项目地址：https://github.com/yourname/yourrepo
# ==========================================

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 依赖检查函数
check_dependencies() {
  local missing=()
  for cmd in ipset iptables ip ss systemctl curl; do
    if ! command -v $cmd &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}缺失必要组件: ${missing[*]}${NC}"
    echo -e "正在尝试自动安装..."
    apt-get update && apt-get install -y ipset iptables iproute2 systemctl curl
    return $?
  fi
}

# ======================= 开启root登录 =======================
enable_root_login() {
  # 移除文件保护属性
  lsattr /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -i /etc/passwd /etc/shadow >/dev/null 2>&1
  chattr -a /etc/passwd /etc/shadow >/dev/null 2>&1

  # 交互设置密码
  read -p "请输入自定义 root 密码: " mima
  if [[ -n $mima ]]; then
    # 修改密码和SSH配置
    echo root:$mima | chpasswd root
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' /etc/ssh/sshd_config
    
    # 重启SSH服务
    systemctl restart sshd
    
    echo -e "\n${GREEN}配置完成！请手动重启服务器使部分设置生效！${NC}"
    echo -e "------------------------------------------"
    echo -e "VPS 当前用户名：root"
    echo -e "VPS 当前 root 密码：$mima"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}请使用以下方式登录："
    echo -e "1. 密码方式登录"
    echo -e "2. keyboard-interactive 验证方式${NC}\n"
  else
    echo -e "${RED}密码不能为空，设置失败！${NC}"
  fi
}

# ======================= 流量监控安装 =======================
install_traffic_monitor() {
  # 依赖检查
  if ! check_dependencies; then
    echo -e "${RED}依赖安装失败，请手动执行：apt-get update && apt-get install ipset iptables iproute2${NC}"
    return 1
  fi

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
read -p $'\033[33m是否要配置白名单IP？(y/N) \033[0m' REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    echo -e "\n\033[36m请输入IP地址（支持格式示例）："
    echo -e "  • 单个IP: 192.168.1.1\n  • IP段: 10.0.0.0/24\n  • 多个IP用空格分隔，例如：192.168.1.5 192.168.1.6 10.0.0.0/24\033[0m"
    
    while :; do
        read -p $'\033[33m请输入IP（多个用空格分隔，直接回车结束）: \033[0m' input
        if [[ -z "$input" ]]; then
            break
        fi
        
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
else
    echo -e "\033[90m已跳过白名单配置\033[0m"
fi

#---------- 持久化配置 ----------#
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
}

# ======================= 流量监控卸载 =======================
uninstall_traffic_monitor() {
  set -e

# 彩色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
  exit 1
fi

# 高危操作确认
read -p "⚠️  确定要完全卸载IP黑名单服务吗？[y/N] " confirm
if [[ ! "$confirm" =~ [yY] ]]; then
  echo "已取消卸载操作"
  exit 0
fi

echo -e "\n${YELLOW}[1/6] 停止并禁用服务...${NC}"
systemctl disable --now ip_blacklist.service 2>/dev/null || true

echo -e "\n${YELLOW}[2/6] 删除核心文件...${NC}"
rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

echo -e "\n${YELLOW}[3/6] 清理网络规则...${NC}"
# 清除iptables规则
iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true
iptables -F TRAFFIC_BLOCK 2>/dev/null || true
iptables -X TRAFFIC_BLOCK 2>/dev/null || true

# 强制刷新规则（防止残留）
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true

# 清除ipset集合
ipset flush whitelist 2>/dev/null || true
ipset destroy whitelist 2>/dev/null || true
ipset flush banlist 2>/dev/null || true
ipset destroy banlist 2>/dev/null || true

# 清理内核模块（确保内存释放）
{ 
  ipset destroy 2>/dev/null
  rmmod ip_set_hash_net 2>/dev/null
  rmmod ip_set 2>/dev/null
} || true

echo -e "\n${YELLOW}[4/6] 删除持久化配置...${NC}"
rm -vf /etc/ipset.conf /etc/iptables/rules.v4

echo -e "\n${YELLOW}[5/6] 重载系统配置...${NC}"
systemctl daemon-reload
systemctl reset-failed
echo 1 > /proc/sys/net/ipv4/ip_forward  # 恢复默认网络设置

echo -e "\n${YELLOW}[6/6] 最终检查...${NC}"
echo -n "服务状态: " && { systemctl status ip_blacklist.service &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
echo -n "IPTables链: " && { iptables -L TRAFFIC_BLOCK &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
echo -n "IPSet黑名单: " && { ipset list banlist &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
echo -n "IPSet白名单: " && { ipset list whitelist &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
echo -n "残留配置文件: " && { ls /etc/ipset.conf /etc/iptables/rules.v4 &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }

echo -e "\n${GREEN}✅ 卸载完成！所有内存规则已清除，无需重启系统${NC}"
}

# ======================= 主菜单 =======================
main_menu() {
  while true; do
    clear
    echo -e "\n${CYAN}IRIS自用工具箱${NC}"
    echo -e "--------------------------------"
    echo -e "1. 开启root用户登录"
    echo -e "2. 安装流量监控服务"
    echo -e "3. 完全卸载流量监控"
    echo -e "0. 退出脚本"
    echo -e "--------------------------------"

    read -p "请输入选项 [0-3]: " choice
    case $choice in
      1) 
        enable_root_login
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      2) 
        install_traffic_monitor
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      3) 
        uninstall_traffic_monitor 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      0) 
        echo -e "${GREEN}已退出${NC}"
        exit 0
        ;;
      *) 
        echo -e "${RED}无效选项，请重新输入${NC}"
        sleep 1
        ;;
    esac
  done
}

# ======================= 执行入口 =======================
# 检查root权限
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo -i 切换root用户后再运行本脚本！${NC}"
  exit 1
fi

# 主程序
main_menu
