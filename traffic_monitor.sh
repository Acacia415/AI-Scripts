#!/bin/bash

# ======================= 流量监控安装/卸载模块 =======================
# 从 tool.sh 拆分出来的独立模块

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= 流量监控安装 =======================
install_traffic_monitor() {
  # 检查依赖并安装
check_dependencies() {
    local deps=("ipset" "iptables" "ip")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装缺失依赖：${missing[*]}${NC}"
        apt-get update
        if ! apt-get install -y ipset iptables iproute2; then
            return 1
        fi
    fi
    return 0
}

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

# ======================= 流量监控卸载 =======================
uninstall_service() {
    # 彩色定义
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    NC='\033[0m'

    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi

    clear
    echo -e "${RED}⚠️ ⚠️ ⚠️  危险操作警告 ⚠️ ⚠️ ⚠️ ${NC}"
    echo -e "${YELLOW}此操作将执行以下操作："
    echo -e "1. 永久删除所有防火墙规则"
    echo -e "2. 清除全部流量监控数据"
    echo -e "3. 移除所有相关系统服务${NC}\n"
    read -p "确定要彻底卸载所有组件吗？[y/N] " confirm
    [[ ! "$confirm" =~ [yY] ]] && echo "操作已取消" && return

    echo -e "\n${YELLOW}[1/6] 停止服务...${NC}"
    systemctl disable --now ip_blacklist.service 2>/dev/null || true

    echo -e "\n${YELLOW}[2/6] 删除文件...${NC}"
    rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

    echo -e "\n${YELLOW}[3/6] 清理网络规则...${NC}"
    # 分步清理策略
    {
        echo -e "${YELLOW}[步骤3.1] 清除动态规则${NC}"
        iptables -S | grep -E 'TRAFFIC_BLOCK|whitelist|banlist' | sed 's/^-A//' | xargs -rL1 iptables -D 2>/dev/null || true

        echo -e "${YELLOW}[步骤3.2] 清理自定义链${NC}"
        iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null
        iptables -F TRAFFIC_BLOCK 2>/dev/null
        iptables -X TRAFFIC_BLOCK 2>/dev/null

        echo -e "${YELLOW}[步骤3.3] 刷新全局规则${NC}"
        iptables -F 2>/dev/null && iptables -X 2>/dev/null

        echo -e "${YELLOW}[步骤3.4] 持久化清理${NC}"
        iptables-save | grep -vE 'TRAFFIC_BLOCK|banlist|whitelist' | iptables-restore
    } || true

    # 内核级清理
    {
        echo -e "${YELLOW}[步骤3.5] 清理ipset集合${NC}"
        ipset list whitelist &>/dev/null && {
            ipset flush whitelist
            ipset destroy whitelist
        }
        ipset list banlist &>/dev/null && {
            ipset flush banlist
            ipset destroy banlist
        }
        echo -e "${YELLOW}[步骤3.6] 卸载内核模块（安全模式）${NC}"
        rmmod ip_set_hash_net 2>/dev/null || true
        rmmod xt_set 2>/dev/null || true
        rmmod ip_set 2>/dev/null || true
    } || true

    echo -e "\n${YELLOW}[4/6] 删除配置...${NC}"
    rm -vf /etc/ipset.conf /etc/iptables/rules.v4

    echo -e "\n${YELLOW}[5/6] 重置系统...${NC}"
    systemctl daemon-reload
    systemctl reset-failed
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    echo -e "\n${YELLOW}[6/6] 验证卸载...${NC}"
    local check_fail=0
    echo -n "服务状态: " && { systemctl status ip_blacklist.service &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPTables链: " && { iptables -L TRAFFIC_BLOCK &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet黑名单: " && { ipset list banlist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet白名单: " && { ipset list whitelist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "残留配置文件: " && { ls /etc/ipset.conf /etc/iptables/rules.v4 &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }

    [ $check_fail -eq 0 ] && echo -e "\n${GREEN}✅ 卸载完成，无残留${NC}" || echo -e "\n${RED}⚠️  检测到残留组件，请重启系统${NC}"
}

# 如果直接执行此脚本，显示帮助
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "用法："
    echo "  安装: source $0 && install_traffic_monitor"
    echo "  卸载: source $0 && uninstall_service"
fi
