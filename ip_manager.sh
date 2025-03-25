#!/bin/bash
# IP流量管理一体化脚本 v2.3
# GitHub: https://github.com/Acacia415
# 一键命令：curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/ip_manager.sh | sudo bash

# 彩色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

#---------- 输入重定向修复 ----------#
exec </dev/tty  # 强制从真实终端读取输入

#---------- 通用函数 ----------#
check_root() {
  [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用sudo运行此脚本${NC}"; exit 1; }
}

show_header() {
  clear
  echo -e "${CYAN}========================================"
  echo "IP流量管理脚本 v2.3"
  echo "GitHub: https://github.com/Acacia415"
  echo "功能选项："
  echo "  1) 安装流量监控系统"
  echo "  2) 卸载流量监控系统"
  echo -e "----------------------------------------"
  echo "  输入 0 退出管理脚本"
  echo -e "========================================${NC}\n"
}

#---------- 安装模块 ----------#
install_script() {
  echo -e "\n${GREEN}>>>>>> 开始安装流量监控系统 <<<<<<${NC}"
  
  # 禁用firewalld
  systemctl stop firewalld 2>/dev/null
  systemctl disable firewalld 2>/dev/null
  echo -e "${YELLOW}[1/6] 已禁用firewalld${NC}"

  # 安装依赖
  yum install -y iptables-services nftables >/dev/null 2>&1
  systemctl enable --now iptables >/dev/null 2>&1
  echo -e "${YELLOW}[2/6] 已安装iptables服务${NC}"

  # 创建监控目录
  mkdir -p /etc/ip_traffic
  cat > /etc/ip_traffic/traffic_counter.sh <<'EOF'
#!/bin/bash
# IP流量统计脚本
log_file="/etc/ip_traffic/traffic.log"
EOF

  # 设置定时任务
  crontab -l | grep -v "/etc/ip_traffic" | crontab -
  echo "* * * * * /etc/ip_traffic/traffic_counter.sh" | crontab -
  echo -e "${YELLOW}[3/6] 已配置crontab监控${NC}"

  # 创建管理脚本
  cat > /usr/local/bin/ip_manager <<'EOF'
#!/bin/bash
# 管理入口脚本
EOF
  chmod +x /usr/local/bin/ip_manager

  echo -e "${YELLOW}[4/6] 已创建管理入口${NC}"
  
  # 配置systemd服务
  cat > /etc/systemd/system/ip_traffic.service <<'EOF'
[Unit]
Description=IP Traffic Monitor
EOF
  systemctl daemon-reload
  systemctl enable --now ip_traffic.service >/dev/null 2>&1
  echo -e "${YELLOW}[5/6] 已启动监控服务${NC}"

  # 完成提示
  echo -e "${YELLOW}[6/6] ${GREEN}✅ 安装完成！${NC}"
  echo -e "监控日志路径：/etc/ip_traffic/traffic.log"
}

#---------- 卸载模块 ----------#
uninstall_script() {
  echo -e "\n${RED}>>>>>> 开始卸载流量监控系统 <<<<<<${NC}"
  read -p "⚠️  确定要完全卸载吗？ [y/N] " confirm
  case $confirm in
    [yY])
      # 停止服务
      systemctl stop ip_traffic.service 2>/dev/null
      systemctl disable ip_traffic.service 2>/dev/null
      echo -e "${YELLOW}[1/4] 已停止监控服务${NC}"

      # 删除定时任务
      crontab -l | grep -v "/etc/ip_traffic" | crontab -
      echo -e "${YELLOW}[2/4] 已清除crontab配置${NC}"

      # 删除文件
      rm -rf /etc/ip_traffic /usr/local/bin/ip_manager
      echo -e "${YELLOW}[3/4] 已删除程序文件${NC}"

      # 恢复防火墙
      systemctl enable --now firewalld >/dev/null 2>&1
      echo -e "${YELLOW}[4/4] 已恢复firewalld${NC}"
      
      echo -e "\n${GREEN}✅ 卸载完成！${NC}"
      ;;
    *)
      echo -e "${GREEN}已取消卸载操作${NC}"
      exit 0
      ;;
  esac
}

#---------- 主流程 ----------#
main() {
  check_root
  while true; do
    show_header
    read -p "请选择操作 (输入数字 1/2/0): " choice
    
    case "$choice" in
      1)
        install_script
        break
        ;;
      2)
        uninstall_script
        break
        ;;
      0)
        echo -e "${GREEN}已退出脚本${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}无效输入，请输入 1（安装）/2（卸载）/0（退出）${NC}"
        sleep 2
        ;;
    esac
  done
}

main "$@"
