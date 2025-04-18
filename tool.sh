#!/bin/bash

# ==========================================
# IRIS自用工具箱 - GitHub一键版
# 项目地址：https://github.com/Acacia415/GPT-Scripts
# ==========================================

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ===================== IRIS 工具箱快捷键自动安装 =====================

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 执行本脚本"
    exit 1
fi

# 获取脚本的绝对路径
SCRIPT_PATH=$(realpath "$0")

# 创建 /usr/local/bin/p 命令
cp -f "$(realpath "$0")" /usr/local/bin/p
chmod +x /usr/local/bin/p
echo "[+] 已创建命令：p ✅"

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

# ======================= 安装snell协议 =======================
install_snell() {
    clear
    # 添加来源提示（使用工具箱内置颜色变量）
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/xOS/Snell${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O snell.sh https://raw.githubusercontent.com/xOS/Snell/master/Snell.sh; then
        chmod +x snell.sh
        ./snell.sh
        rm -f snell.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Snell 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装Hysteria2协议 =======================
install_hysteria2() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Misaka-blog/hysteria-install${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -N --no-check-certificate https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/hysteria.sh; then
        chmod +x hysteria.sh
        bash hysteria.sh
        rm -f hysteria.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Hysteria2 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装SS协议 =======================
install_ss_rust() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/shadowsocks/shadowsocks-rust${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -O ss-rust.sh --no-check-certificate https://git.io/Shadowsocks-Rust.sh; then
        chmod +x ss-rust.sh
        ./ss-rust.sh
        rm -f ss-rust.sh  # 清理安装脚本
    else
        echo -e "${RED}下载 SS-Rust 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装3X-UI面板 =======================
install_3x_ui() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/mhsanaei/3x-ui${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/3x-ui_install.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 3X-UI 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 流媒体检测 =======================
install_media_check() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：ip.check.place${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/media_check.sh"
    if curl -L -s -o "$install_script" ip.check.place; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载流媒体检测脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}


# ======================= Speedtest测速 =======================
install_speedtest() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}Speedtest测速组件安装${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 下载packagecloud安装脚本
    local install_script="/tmp/speedtest_install.sh"
    echo -e "${CYAN}下载Speedtest安装脚本...${NC}"
    if ! curl -s --ssl https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh -o "$install_script"; then
        echo -e "${RED}下载Speedtest安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 执行安装脚本
    echo -e "${CYAN}添加Speedtest仓库...${NC}"
    if ! sudo bash "$install_script"; then
        echo -e "${RED}添加仓库失败！${NC}"
        rm -f "$install_script"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    rm -f "$install_script"
    
    # 更新软件源并安装
    echo -e "${CYAN}安装Speedtest...${NC}"
    if ! sudo apt-get update || ! sudo apt-get install -y speedtest; then
        echo -e "${RED}安装Speedtest失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 自动执行测速
    echo -e "${CYAN}开始网络测速...${NC}"
    speedtest --accept-license --accept-gdpr
}

# ======================= 开放所有端口 =======================
open_all_ports() {
    clear
    echo -e "${RED}════════════ 安全警告 ════════════${NC}"
    echo -e "${YELLOW}此操作将：${NC}"
    echo -e "1. 清空所有防火墙规则"
    echo -e "2. 设置默认策略为全部允许"
    echo -e "3. 完全开放所有网络端口"
    echo -e "${RED}═════════════════════════════════${NC}"
    read -p "确认继续操作？[y/N] " confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}正在重置防火墙规则...${NC}"
        
        # 设置默认策略
        sudo iptables -P INPUT ACCEPT    # 修正缺少的ACCEPT
        sudo iptables -P FORWARD ACCEPT
        sudo iptables -P OUTPUT ACCEPT
        
        # 清空所有规则
        sudo iptables -F
        sudo iptables -X
        sudo iptables -Z
        
        echo -e "${GREEN}所有端口已开放！${NC}"
        echo -e "${YELLOW}当前防火墙规则：${NC}"
        sudo iptables -L -n --line-numbers
    else
        echo -e "${BLUE}已取消操作${NC}"
    fi
}

# ======================= 安装Caddy反代 =======================
configure_caddy_reverse_proxy() {
    # 环境常量定义
    local CADDY_SERVICE="/lib/systemd/system/caddy.service"
    local CADDYFILE="/etc/caddy/Caddyfile"
    local TEMP_CONF=$(mktemp)
    local domain port

    # 首次安装检测
    if ! command -v caddy &>/dev/null; then
        echo -e "${CYAN}开始安装Caddy服务器...${NC}"
        
        # 安装依赖组件
        if ! sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https &>/dev/null; then
            echo -e "${RED}依赖组件安装失败！请检查apt源配置${NC}"
            return 1
        fi

        # 添加官方软件源
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

        # 执行安装
        sudo apt-get update &>/dev/null
        if ! sudo apt-get install -y caddy &>/dev/null; then
            echo -e "${RED}Caddy官方安装失败！错误码：$?${NC}"
            return 1
        fi

        # 初始化配置文件
        sudo mkdir -p /etc/caddy
        [ ! -f "$CADDYFILE" ] && sudo touch "$CADDYFILE"
        echo -e "# Caddyfile自动生成配置\n# 手动修改后请执行 systemctl reload caddy" | sudo tee "$CADDYFILE" >/dev/null
        sudo chown caddy:caddy "$CADDYFILE"
        echo -e "${GREEN}✅ Caddy安装完成，版本：$(caddy version)${NC}"
    else
        echo -e "${CYAN}检测到Caddy已安装，版本：$(caddy version)${NC}"
    fi

    # 配置输入循环
    while : ; do
        # 域名输入验证
        until [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; do
            read -p "请输入域名（无需https://）：" domain
            domain=$(echo "$domain" | sed 's/https\?:\/\///g')
            [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || echo -e "${RED}域名格式无效！示例：example.com${NC}"
        done

        # 端口输入验证
        until [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 -a "$port" -le 65535 ]; do
            read -p "请输入本地端口号（1-65535）：" port
            [[ $port =~ ^[0-9]+$ ]] || { echo -e "${RED}端口必须为数字！"; continue; }
            [ "$port" -ge 1 -a "$port" -le 65535 ] || echo -e "${RED}端口范围1-65535！"
        done

        # 配置冲突检测
        if sudo caddy validate --config "$CADDYFILE" --adapter caddyfile 2>/dev/null; then
            if grep -q "^$domain {" "$CADDYFILE"; then
                echo -e "${YELLOW}⚠ 检测到现有配置："
                grep -A3 "^$domain {" "$CADDYFILE"
                read -p "要覆盖此配置吗？[y/N] " overwrite
                [[ $overwrite =~ ^[Yy]$ ]] || continue
                sudo caddy adapt --config "$CADDYFILE" --adapter caddyfile | \
                awk -v domain="$domain" '/^'$domain' {/{flag=1} !flag; /^}/{flag=0}' | \
                sudo tee "$TEMP_CONF" >/dev/null
                sudo mv "$TEMP_CONF" "$CADDYFILE"
            fi
        else
            echo -e "${YELLOW}⚠ 当前配置文件存在错误，将创建新配置${NC}"
            sudo truncate -s 0 "$CADDYFILE"
        fi

        # 生成配置块
        echo -e "\n# 自动生成配置 - $(date +%F)" | sudo tee -a "$CADDYFILE" >/dev/null
        cat <<EOF | sudo tee -a "$CADDYFILE" >/dev/null
$domain {
    reverse_proxy localhost:$port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    }
}
EOF

        # 格式化配置文件
        sudo caddy fmt "$CADDYFILE" --overwrite

        # 配置验证与生效
        if ! sudo caddy validate --config "$CADDYFILE"; then
            echo -e "${RED}配置验证失败！错误详情："
            sudo caddy validate --config "$CADDYFILE" 2>&1 | grep -v "valid"
            sudo sed -i "/# 自动生成配置 - $(date +%F)/,+6d" "$CADDYFILE"
            return 1
        fi

        # 服务热重载
        if systemctl is-active caddy &>/dev/null; then
            sudo systemctl reload caddy || sudo systemctl restart caddy
        else
            sudo systemctl enable --now caddy &>/dev/null
        fi

        echo -e "${GREEN}✅ 配置生效成功！访问地址：https://$domain${NC}"
        read -p "是否继续添加配置？[y/N] " more
        [[ $more =~ ^[Yy]$ ]] || break
    done

    # 清理临时文件
    rm -f "$TEMP_CONF"
}

# ======================= IP优先级设置 =======================
modify_ip_preference() {
    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi

    # 配置文件路径
    CONF_FILE="/etc/gai.conf"
    BACKUP_FILE="/etc/gai.conf.bak"

    show_current_status() {
        echo -e "\n${YELLOW}当前优先级配置："
        if grep -qE "^precedence ::ffff:0:0/96 100" $CONF_FILE; then
            echo -e "  ▸ ${GREEN}IPv4优先模式 (precedence ::ffff:0:0/96 100)${NC}"
        elif grep -qE "^precedence ::/0 40" $CONF_FILE; then
            echo -e "  ▸ ${GREEN}IPv6优先模式 (precedence ::/0 40)${NC}"
        else
            echo -e "  ▸ ${YELLOW}系统默认配置${NC}"
        fi
    }

    interactive_menu() {
        clear
        echo -e "${GREEN}=== IP协议优先级设置 ==="
        echo -e "1. IPv4优先 (推荐)"
        echo -e "2. IPv6优先"
        echo -e "3. 恢复默认配置"
        echo -e "0. 返回主菜单"
        show_current_status
        read -p "请输入选项 [0-3]: " choice
    }

    apply_ipv4_preference() {
        echo -e "${YELLOW}\n[1/3] 备份原配置..."
        cp -f $CONF_FILE $BACKUP_FILE 2>/dev/null || true

        echo -e "${YELLOW}[2/3] 生成新配置..."
        cat > $CONF_FILE << EOF
# 由网络工具箱设置 IPv4 优先
precedence ::ffff:0:0/96 100
#precedence ::/0 40
EOF

        echo -e "${YELLOW}[3/3] 应用配置..."
        sysctl -p $CONF_FILE >/dev/null 2>&1 || true
    }

    apply_ipv6_preference() {
        echo -e "${YELLOW}\n[1/3] 备份原配置..."
        cp -f $CONF_FILE $BACKUP_FILE 2>/dev/null || true

        echo -e "${YELLOW}[2/3] 生成新配置..."
        cat > $CONF_FILE << EOF
# 由网络工具箱设置 IPv6 优先
precedence ::/0 40
#precedence ::ffff:0:0/96 100
EOF

        echo -e "${YELLOW}[3/3] 应用配置..."
    }

    restore_default() {
        if [ -f $BACKUP_FILE ]; then
            echo -e "${YELLOW}\n[1/2] 恢复备份文件..."
            cp -f $BACKUP_FILE $CONF_FILE
            echo -e "${YELLOW}[2/2] 删除备份..."
            rm -f $BACKUP_FILE
        else
            echo -e "${YELLOW}\n[1/1] 重置为默认配置..."
            sed -i '/^precedence/d' $CONF_FILE
        fi
    }

    while true; do
        interactive_menu
        case $choice in
            1)
                apply_ipv4_preference
                echo -e "${GREEN}\n✅ 已设置为IPv4优先模式！"
                echo -e "  更改将在下次网络连接时生效${NC}"
                sleep 2
                ;;
            2)
                apply_ipv6_preference
                echo -e "${GREEN}\n✅ 已设置为IPv6优先模式！"
                echo -e "  更改将在下次网络连接时生效${NC}"
                sleep 2
                ;;
            3)
                restore_default
                echo -e "${GREEN}\n✅ 已恢复默认系统配置！${NC}"
                sleep 2
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# ======================= TCP性能优化 =======================
install_magic_tcp() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/qiuxiuya/magicTCP${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 用户确认环节
    read -p "是否要执行TCP性能优化？[y/N] " confirm
    if [[ ! "$confirm" =~ [yY] ]]; then
        echo -e "${BLUE}操作已取消${NC}"
        return 1
    fi  # 必须显式闭合if语句
    
    # 网络检测环节
    if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${RED}❌ 网络连接异常，无法访问GitHub${NC}"
        return 1
    fi
    
    # 执行优化脚本
    echo -e "${CYAN}正在应用TCP优化参数..."
    if bash <(curl -sSL https://raw.githubusercontent.com/qiuxiuya/magicTCP/main/main.sh); then
        echo -e "${GREEN}✅ 优化成功完成，重启后生效${NC}"
    else
        echo -e "${RED}❌ 优化过程中出现错误，请检查："
        echo -e "1. 系统是否为Debian/Ubuntu"
        echo -e "2. 是否具有root权限"
        echo -e "3. 查看日志：/var/log/magic_tcp.log${NC}"
        return 1
    fi  # 闭合核心if语句
}  # 函数结束（对应原错误行号807）

install_shell_beautify() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}正在安装命令行美化组件...${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"

    echo -e "${CYAN}[1/6] 更新软件源...${NC}"
    apt-get update

    echo -e "${CYAN}[2/6] 安装依赖组件...${NC}"
    if ! command -v git &> /dev/null; then
        apt-get install -y git > /dev/null
    else
        echo -e "${GREEN} ✓ Git 已安装${NC}"
    fi
    if ! command -v wget &> /dev/null; then
        apt-get install -y wget > /dev/null
    fi
    if ! command -v unzip &> /dev/null; then
        apt-get install -y unzip > /dev/null
    fi

    echo -e "${CYAN}[3/6] 检查zsh...${NC}"
    if ! command -v zsh &> /dev/null; then
        echo -e "${YELLOW}未检测到zsh，正在安装...${NC}"
        apt-get install -y zsh > /dev/null
    else
        echo -e "${GREEN} ✓ Zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[4/6] 配置oh-my-zsh...${NC}"
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        echo -e "${CYAN}正在下载 oh-my-zsh 压缩包...${NC}"
        wget -qO /tmp/ohmyzsh.zip https://gitee.com/mirrors/oh-my-zsh/repository/archive/master.zip
        unzip -q /tmp/ohmyzsh.zip -d /tmp
        mv /tmp/oh-my-zsh-master ~/.oh-my-zsh
        cp ~/.oh-my-zsh/templates/zshrc.zsh-template ~/.zshrc
        echo -e "${GREEN} ✓ oh-my-zsh 安装完成${NC}"
    else
        echo -e "${GREEN} ✓ oh-my-zsh 已安装${NC}"
    fi

    echo -e "${CYAN}[5/6] 设置ultima主题...${NC}"
    ULTIMA_REPO="https://github.com/egorlem/ultima.zsh-theme"
    TEMP_DIR="$HOME/ultima-shell"
    THEME_DEST="$HOME/.oh-my-zsh/themes"

    rm -rf "$TEMP_DIR"
    git clone -q "$ULTIMA_REPO" "$TEMP_DIR"
    if [ -f "$TEMP_DIR/ultima.zsh-theme" ]; then
        mv -f "$TEMP_DIR/ultima.zsh-theme" "$THEME_DEST/ultima.zsh-theme"
        echo -e "${GREEN} ✓ 主题安装完成${NC}"
    else
        echo -e "${RED}❌ 克隆失败或找不到主题文件${NC}"
        return 1
    fi

    sed -i 's/ZSH_THEME=.*/ZSH_THEME="ultima"/' ~/.zshrc

    echo -e "${CYAN}[6/6] 设置默认shell...${NC}"
    if [ "$SHELL" != "$(which zsh)" ]; then
        chsh -s $(which zsh) >/dev/null
    fi

    echo -e "\n${GREEN}✅ 美化完成！重启终端后生效${NC}"
    read -p "$(echo -e "${YELLOW}是否立即生效主题？[${GREEN}Y${YELLOW}/n] ${NC}")" confirm
    confirm=${confirm:-Y}
    if [[ "${confirm^^}" == "Y" ]]; then
        echo -e "${GREEN}正在应用新配置...${NC}"
        exec zsh
    else
        echo -e "\n${YELLOW}可稍后手动执行：${CYAN}exec zsh ${YELLOW}生效配置${NC}"
    fi
}

# ======================= 脚本更新 =======================
update_script() {
  echo -e "${YELLOW}开始更新脚本...${NC}"
  
  # 删除旧脚本
  rm -f /root/tool.sh
  
  # 下载并执行新脚本
  if curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/tool.sh -o /root/tool.sh && 
     chmod +x /root/tool.sh
  then
    echo -e "${GREEN}更新成功，即将启动新脚本...${NC}"
    sleep 2
    exec /root/tool.sh  # 用新脚本替换当前进程
  else
    echo -e "${RED}更新失败！请手动执行："
    echo -e "curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/tool.sh -o tool.sh"
    echo -e "chmod +x tool.sh && ./tool.sh${NC}"
    exit 1
  fi
}

# ======================= 主菜单 =======================
main_menu() {
  while true; do
    clear
    echo -e "${CYAN}"
    echo "  _____ _____  _____  _____   _______ ____   ____  _      ____   ______   __"
    echo " |_   _|  __ \|_   _|/ ____| |__   __/ __ \ / __ \| |    |  _ \ / __ \ \ / /"
    echo "   | | | |__) | | | | (___      | | | |  | | |  | | |    | |_) | |  | \ V / "
    echo "   | | |  _  /  | |  \___ \     | | | |  | | |  | | |    |  _ <| |  | |> <  "
    echo "  _| |_| | \ \ _| |_ ____) |    | | | |__| | |__| | |____| |_) | |__| / . \ "
    echo " |_____|_|  \_\_____|_____/     |_|  \____/ \____/|______|____/ \____/_/ \_\\"
    echo -e "                                                              ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "1. 开启root用户登录"
    echo -e "2. 安装流量监控服务"
    echo -e "3. 完全卸载流量监控"
    echo -e "4. 安装 Snell 协议服务"
    echo -e "5. 安装 Hysteria2 协议服务"
    echo -e "6. 安装 SS-Rust 协议服务"
    echo -e "7. 安装 3X-UI 管理面板"
    echo -e "8. 流媒体解锁检测"
    echo -e "9. Speedtest网络测速"
    echo -e "10. 开放所有端口"
    echo -e "11. 安装Caddy反代"
    echo -e "12. IP优先级设置"
    echo -e "13. TCP性能优化"
    echo -e "14. 命令行美化"
    echo -e "0. 退出脚本"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "99. 脚本更新"
    echo -e "${YELLOW}==================================================${NC}"

    read -p "请输入选项 : " choice
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
        uninstall_service 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      4) 
        install_snell 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      5)  
        install_hysteria2 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      6)  
        install_ss_rust 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      7)  
        install_3x_ui 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      8)  
        install_media_check 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      9)  
        install_speedtest 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      10)  
        open_all_ports 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      11)
        configure_caddy_reverse_proxy
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      12)
        modify_ip_preference
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      13)
        install_magic_tcp 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      14)  
        install_shell_beautify 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      99)  
        update_script 
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
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo -i 切换root用户后再运行本脚本！${NC}"
  exit 1
fi

# Bash版本检查
if (( BASH_VERSINFO < 4 )); then
  echo -e "${RED}需要Bash 4.0及以上版本${NC}"
  exit 1
fi

main_menu
