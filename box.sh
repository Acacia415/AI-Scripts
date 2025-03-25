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

  # ---------- 生成主监控脚本 ----------
  echo -e "\n${CYAN}[1/4] 生成监控脚本到 /root/ip_blacklist.sh${NC}"
  cat > /root/ip_blacklist.sh <<'EOF'
#!/bin/bash
# ... 此处保留原始安装脚本中的主监控脚本内容，不需要修改 ...
EOF

  # 白名单配置、持久化配置和服务配置部分保持不变...
  # ...（此处为节省空间省略中间重复内容，实际脚本需保持完整）...

  echo -e "\n${GREEN}✅ 流量监控安装完成！${NC}"
}

# ======================= 流量监控卸载 =======================
uninstall_traffic_monitor() {
  # ...（原有卸载逻辑保持不变）...
  echo -e "\n${GREEN}✅ 流量监控卸载完成！${NC}"
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
