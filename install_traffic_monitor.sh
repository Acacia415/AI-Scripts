#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= 流量监控安装 =======================
install_traffic_monitor() {
  # 检查并安装依赖
  check_dependencies() {
    echo -e "${CYAN}正在检查系统依赖...${NC}"
    
    # 定义所需依赖
    local deps=("ipset" "iptables" "ip" "bc" "ss" "awk")
    local missing=()
    
    # 检测缺失的命令
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    # 如果没有缺失依赖，直接返回
    if [ ${#missing[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ 所有依赖已安装${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⚠️  检测到缺失依赖：${missing[*]}${NC}"
    echo -e "${CYAN}正在自动安装...${NC}"
    
    # 检测系统类型并安装
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    else
        OS=$(uname -s)
    fi
    
    case "${OS}" in
        ubuntu|debian|kali|linuxmint)
            echo -e "${BLUE}检测到 Debian/Ubuntu 系统${NC}"
            apt-get update -qq
            if apt-get install -y ipset iptables iproute2 bc; then
                echo -e "${GREEN}✓ 依赖安装成功${NC}"
            else
                echo -e "${RED}✗ 依赖安装失败${NC}"
                return 1
            fi
            ;;
        centos|rhel|rocky|almalinux|fedora)
            echo -e "${BLUE}检测到 CentOS/RHEL 系统${NC}"
            if command -v dnf &>/dev/null; then
                if dnf install -y ipset iptables iproute bc; then
                    echo -e "${GREEN}✓ 依赖安装成功${NC}"
                else
                    echo -e "${RED}✗ 依赖安装失败${NC}"
                    return 1
                fi
            else
                if yum install -y ipset iptables iproute bc; then
                    echo -e "${GREEN}✓ 依赖安装成功${NC}"
                else
                    echo -e "${RED}✗ 依赖安装失败${NC}"
                    return 1
                fi
            fi
            ;;
        alpine)
            echo -e "${BLUE}检测到 Alpine Linux${NC}"
            if apk add --no-cache ipset iptables iproute2 bc; then
                echo -e "${GREEN}✓ 依赖安装成功${NC}"
            else
                echo -e "${RED}✗ 依赖安装失败${NC}"
                return 1
            fi
            ;;
        arch|manjaro)
            echo -e "${BLUE}检测到 Arch Linux${NC}"
            if pacman -S --noconfirm ipset iptables iproute2 bc; then
                echo -e "${GREEN}✓ 依赖安装成功${NC}"
            else
                echo -e "${RED}✗ 依赖安装失败${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "${RED}✗ 不支持的系统类型: ${OS}${NC}"
            echo -e "${YELLOW}请手动安装以下依赖: ipset iptables iproute2 bc${NC}"
            return 1
            ;;
    esac
    
    return 0
  }
  
  # ▼▼▼ 执行依赖检查 ▼▼▼
  if ! check_dependencies; then
    echo -e "${RED}依赖安装失败，无法继续！${NC}"
    read -p "按任意键返回..."
    return 1
  fi
  echo ""

  #---------- 生成主监控脚本 ----------#
  echo -e "\n${CYAN}[1/4] 生成主脚本到 /root/ip_blacklist.sh${NC}"
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
    
    # 白名单优先规则
    iptables -C INPUT -j TRAFFIC_BLOCK 2>/dev/null || iptables -I INPUT -j TRAFFIC_BLOCK
    iptables -A TRAFFIC_BLOCK -m set --match-set whitelist src -j ACCEPT
    iptables -A TRAFFIC_BLOCK -m set --match-set banlist src -j DROP

    # 获取活动网卡
    INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
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

        RX_RATE=$(echo "scale=2; ($RX_BYTES_2 - $RX_BYTES_1) / 1048576" | bc)
        TX_RATE=$(echo "scale=2; ($TX_BYTES_2 - $TX_BYTES_1) / 1048576" | bc)

        echo -e "[$(date +%H:%M:%S)] 接收: ${BLUE}${RX_RATE}MB/s${NC} 发送: ${CYAN}${TX_RATE}MB/s${NC}"

        # 超速处理逻辑
        if (( $(echo "$RX_RATE > $LIMIT || $TX_RATE > $LIMIT" | bc -l) )); then
            echo -e "\n${YELLOW}⚠️  检测到流量超限！正在分析连接...${NC}"
            
            # 获取可疑IP（排除SSH和白名单）
            IP_LIST=$(ss -ntu state established | awk -v port=22 '
                NR > 1 {
                    match($5, /:([0-9]+)$/, port_arr);
                    current_port = port_arr[1];
                    ip = gensub(/\[|\]/, "", "g", substr($5, 1, RSTART-1));
                    if (current_port != port && ip != "0.0.0.0") {
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

        # +++ 新增CPU优化 +++
        sleep 0.5  # 降低CPU占用
    done
}

# 主执行流程
init_system
start_monitor
EOF

  #---------- 白名单交互配置 ----------#
  echo -e "\n${CYAN}[2/4] 白名单配置${NC}"
  function validate_ip() {
      local ip=$1
      local pattern='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/([12][0-9]|3[0-2]|[0-9]))?$'
      [[ $ip =~ $pattern ]] && return 0 || return 1
  }

  ipset create whitelist hash:ip 2>/dev/null || true

  read -p $'\033[33m是否要配置白名单IP？(y/N) \033[0m' REPLY
  if [[ "${REPLY,,}" == "y" ]]; then
      echo -e "\n${CYAN}请输入IP地址（支持格式示例）："
      echo -e "  • 单个IP: 192.168.1.1"
      echo -e "  • IP段: 10.0.0.0/24"
      echo -e "  • 多个IP用空格分隔${NC}"
      
      while :; do
          read -p $'\033[33m请输入IP（多个用空格分隔，直接回车结束）: \033[0m' input
          [[ -z "$input" ]] && break
          
          IFS=' ' read -ra ips <<< "$input"
          for ip in "${ips[@]}"; do
              if validate_ip "$ip"; then
                  if ipset add whitelist "$ip" 2>/dev/null; then
                      echo -e "${GREEN} ✓ 成功添加：$ip${NC}"
                  else
                      echo -e "${YELLOW} ⚠️  已存在：$ip${NC}"
                  fi
              else
                  echo -e "${RED} ✗ 无效格式：$ip${NC}"
              fi
          done
      done
  else
      echo -e "${CYAN}已跳过白名单配置${NC}"
  fi

  #---------- 持久化配置 ----------#
  echo -e "\n${CYAN}[3/4] 保存防火墙规则${NC}"
  mkdir -p /etc/ipset
  ipset save > /etc/ipset.conf
  iptables-save > /etc/iptables/rules.v4

  #---------- 系统服务配置 ----------#
  echo -e "\n${CYAN}[4/4] 配置系统服务${NC}"
  chmod +x /root/ip_blacklist.sh

  cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP流量监控与封禁服务
After=network-online.target
Wants=network-online.target

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

  # +++ 新增日志轮替配置 +++
  echo -e "\n${CYAN}[附加] 配置日志轮替规则${NC}"
  sudo tee /etc/logrotate.d/iptables_ban <<'EOF'
/var/log/iptables_ban.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
EOF

  # ▼▼▼ 新增：立即触发日志轮替 ▼▼▼
  sudo logrotate -f /etc/logrotate.d/iptables_ban

  # 完成提示
  echo -e "\n${GREEN}✅ 部署完成！${NC}"
  echo -e "白名单IP列表："
  ipset list whitelist -output save | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sed 's/^/  ➤ /'
  echo -e "\n管理命令："
  echo -e "  查看日志: ${CYAN}journalctl -u ip_blacklist.service -f${NC}"
  echo -e "  临时解封: ${CYAN}ipset del banlist <IP地址>${NC}"
  echo -e "  添加白名单: ${CYAN}ipset add whitelist <IP地址>${NC}"
  # +++ 新增日志管理提示 +++
  echo -e "\n日志管理："
  echo -e "  • 实时日志: ${CYAN}tail -f /var/log/iptables_ban.log${NC}"
  echo -e "  • 日志轮替: ${CYAN}每天自动压缩，保留最近7天日志${NC}"
}

# 执行函数
install_traffic_monitor
