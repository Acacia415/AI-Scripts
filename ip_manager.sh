#!/bin/bash

# ==========================================
# 综合流量管理脚本 - GitHub一键版
# 功能：1.安装流量监控 2.完全卸载
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

# ======================= 安装部分 =======================
install_traffic_monitor() {
  # 依赖检查
  if ! check_dependencies; then
    echo -e "${RED}依赖安装失败，请手动执行：apt-get update && apt-get install ipset iptables iproute2${NC}"
    return 1
  fi

  # ---------- 生成主监控脚本 ----------
  echo -e "\n${CYAN}[1/4] 生成监控脚本到 /root/ip_blacklist.sh${NC}"
  cat > /root/ip_blacklist.sh <<'EOF'
#!/bin/bash
# ... 此处保留原始安装脚本中的主监控脚本内容，不需要修改 ...
EOF

  # ---------- 白名单配置 ----------
  echo -e "\n${CYAN}[2/4] 白名单交互配置${NC}"
  function validate_ip() {
    local ip=$1
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
    [[ $ip =~ $pattern ]] && return 0 || return 1
  }

  ipset create whitelist hash:ip 2>/dev/null || true

  read -p $'\033[33m是否要配置白名单IP？(y/N) \033[0m' REPLY
  if [[ "${REPLY,,}" == "y" ]]; then
    echo -e "\n${CYAN}输入示例：\n  单个IP: 192.168.1.1\n  IP段: 10.0.0.0/24\n  多个IP用空格分隔${NC}"
    
    while :; do
      read -p $'\033[33m请输入IP（回车结束）: \033[0m' input
      [[ -z "$input" ]] && break
      
      IFS=' ' read -ra ips <<< "$input"
      for ip in "${ips[@]}"; do
        if validate_ip "$ip"; then
          ipset add whitelist "$ip" 2>/dev/null && \
            echo -e "${GREEN} ✓ 成功添加：$ip${NC}" || \
            echo -e "${YELLOW} ⚠️  已存在：$ip${NC}"
        else
          echo -e "${RED} ✗ 无效格式：$ip${NC}"
        fi
      done
    done
  fi

  # ---------- 持久化配置 ----------
  echo -e "\n${CYAN}[3/4] 保存防火墙规则${NC}"
  mkdir -p /etc/ipset
  ipset save > /etc/ipset.conf
  iptables-save > /etc/iptables/rules.v4

  # ---------- 服务配置 ----------
  echo -e "\n${CYAN}[4/4] 配置系统服务${NC}"
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
echo -e "\n${GREEN}✅ 安装完成！${NC}"
echo -e "已添加白名单IP："
ipset list whitelist -output save | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sed 's/^/  ➤ /'
echo -e "\n管理命令："
echo -e "  实时日志: ${CYAN}journalctl -u ip_blacklist.service -f${NC}"
echo -e "  临时解封: ${CYAN}ipset del banlist <IP地址>${NC}"
echo -e "  添加白名单: ${CYAN}ipset add whitelist <IP地址>${NC}"
}

# ======================= 卸载部分 =======================
uninstall_traffic_monitor() {
  # 高危操作确认
  echo -e "\n${RED}════════════ 警告 ════════════${NC}"
  read -p "⚠️  确定要完全卸载吗？(必须输入y并回车确认) [y/N]: " confirm

  case "$confirm" in
    [yY])
      echo -e "\n${YELLOW}[1/5] 停止服务...${NC}"
      systemctl disable --now ip_blacklist.service 2>/dev/null || true

      echo -e "\n${YELLOW}[2/5] 删除文件...${NC}"
      rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

      echo -e "\n${YELLOW}[3/5] 清理网络规则...${NC}"
      iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true
      iptables -F TRAFFIC_BLOCK 2>/dev/null || true
      iptables -X TRAFFIC_BLOCK 2>/dev/null || true
      ipset flush whitelist 2>/dev/null || true
      ipset destroy whitelist 2>/dev/null || true
      ipset destroy banlist 2>/dev/null || true

      echo -e "\n${YELLOW}[4/5] 删除配置...${NC}"
      rm -vf /etc/ipset.conf /etc/iptables/rules.v4

      echo -e "\n${YELLOW}[5/5] 重载系统...${NC}"
      systemctl daemon-reload
      echo -e "\n${GREEN}✅ 卸载完成！${NC}"
      ;;
    *)
      echo -e "${YELLOW}已取消卸载操作${NC}"
      return
      ;;
  esac
}

# ======================= 主菜单 =======================
main_menu() {
  while true; do
    clear
    echo -e "\n${CYAN}流量监控管理脚本${NC}"
    echo -e "--------------------------------"
    echo -e "1. 安装流量监控服务"
    echo -e "2. 完全卸载服务"
    echo -e "0. 退出脚本"
    echo -e "--------------------------------"

    read -p "请输入选项 [0-2]: " choice
    case $choice in
      1) 
        install_traffic_monitor
        ;;
      2) 
        uninstall_traffic_monitor 
        ;;
      0) 
        echo -e "${GREEN}已退出${NC}"
        exit 0
        ;;
      *) 
        echo -e "${RED}无效选项，请重新输入${NC}"
        ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
  done
}

# ======================= 执行入口 =======================
# 检查root权限
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用sudo运行此脚本！${NC}"
  exit 1
fi

# 主程序
main_menu
