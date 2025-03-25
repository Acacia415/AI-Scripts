#!/bin/bash
# IP流量管理一体化脚本
# 一键命令：curl -sSL https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/ip_manager.sh | sudo bash
# 彩色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'
#---------- 通用函数 ----------#
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
    exit 1
  fi
}
confirm_action() {
  local prompt=$1
  read -p "${YELLOW}${prompt} [y/N] ${NC}" confirm
  [[ "$confirm" =~ [yY] ]] || return 1
}
show_header() {
  clear
  echo -e "${CYAN}========================================"
  echo "IP流量管理脚本 v2.1"
  echo "GitHub: https://github.com/Acacia415"
  echo "功能选项："
  echo "  1. 安装流量监控系统"
  echo "  2. 卸载流量监控系统"
  echo -e "----------------------------------------"
  echo "  输入 0 退出管理脚本"
  echo -e "========================================${NC}"
}

#---------- 安装模块 ----------#
install_script() {
  echo -e "\n${GREEN}>>>>>> 开始安装流量监控系统 <<<<<<${NC}"

  # 依赖安装
  echo -e "\n${CYAN}[1/5] 安装系统依赖...${NC}"
  apt-get update
  for pkg in iproute2 iptables ipset; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
      apt-get install -y $pkg
    fi
  done

  # 生成监控脚本
  echo -e "\n${CYAN}[2/5] 部署监控程序...${NC}"
  cat > /root/ip_blacklist.sh <<'EOF'
[此处粘贴完整的主监控脚本内容]
EOF
  chmod +x /root/ip_blacklist.sh

  # 白名单配置
  echo -e "\n${CYAN}[3/5] 配置白名单...${NC}"
  ipset create whitelist hash:ip 2>/dev/null || true
  if confirm_action "是否要添加初始白名单IP？"; then
    while :; do
      read -p "${YELLOW}输入IP（支持CIDR格式，多个用空格分隔，回车结束）: ${NC}" input
      [ -z "$input" ] && break
      IFS=' ' read -ra ips <<< "$input"
      for ip in "${ips[@]}"; do
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
          ipset add whitelist "$ip" 2>/dev/null && echo -e "  ${GREEN}✓ 添加成功: $ip${NC}" || echo -e "  ${YELLOW}⚠️  已存在: $ip${NC}"
        else
          echo -e "  ${RED}✗ 无效IP: $ip${NC}"
        fi
      done
    done
  fi

  # 持久化配置
  echo -e "\n${CYAN}[4/5] 保存配置...${NC}"
  mkdir -p /etc/ipset
  ipset save > /etc/ipset.conf
  iptables-save > /etc/iptables/rules.v4

  # 服务配置
  echo -e "\n${CYAN}[5/5] 启动服务...${NC}"
  cat > /etc/systemd/system/ip_blacklist.service <<EOF
[Unit]
Description=IP流量监控服务
After=network.target

[Service]
ExecStart=/root/ip_blacklist.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ip_blacklist.service

  # 完成提示
  echo -e "\n${GREEN}✅ 安装完成！管理命令："
  echo -e "  查看状态: systemctl status ip_blacklist.service"
  echo -e "  实时日志: journalctl -u ip_blacklist.service -f"
  echo -e "  添加白名单: ipset add whitelist <IP地址>${NC}"
}

#---------- 卸载模块 ----------#
uninstall_script() {
  echo -e "\n${RED}>>>>>> 开始卸载流量监控系统 <<<<<<${NC}"
  ! confirm_action "⚠️  确定要完全卸载吗？" && exit 0

  # 停止服务
  echo -e "\n${CYAN}[1/6] 清理服务...${NC}"
  systemctl disable --now ip_blacklist.service 2>/dev/null || true

  # 删除文件
  echo -e "\n${CYAN}[2/6] 移除文件...${NC}"
  rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

  # 清除规则
  echo -e "\n${CYAN}[3/6] 清除网络规则...${NC}"
  iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true
  iptables -F TRAFFIC_BLOCK 2>/dev/null || true
  iptables -X TRAFFIC_BLOCK 2>/dev/null || true
  ipset flush 2>/dev/null || true
  ipset destroy 2>/dev/null || true

  # 删除配置
  echo -e "\n${CYAN}[4/6] 擦除持久化数据...${NC}"
  rm -vf /etc/ipset.conf /etc/iptables/rules.v4

  # 系统重置
  echo -e "\n${CYAN}[5/6] 重置系统配置...${NC}"
  systemctl daemon-reload
  systemctl reset-failed

  # 完成检查
  echo -e "\n${CYAN}[6/6] 验证卸载结果...${NC}"
  echo -n "服务状态: " && { systemctl status ip_blacklist.service &>/dev/null && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }
  echo -n "IPSet集合: " && { ipset list | grep -q 'whitelist\|banlist' && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }

  echo -e "\n${GREEN}✅ 卸载完成！所有相关配置已移除${NC}"
}

#---------- 主流程 ----------#
main() {
  check_root
  show_header
  PS3=$'\n'"请选择操作 (1-2, 输入0退出): "
  options=("安装系统" "卸载系统")
  select opt in "${options[@]}"; do
    case $REPLY in
      1) install_script; break ;;
      2) uninstall_script; break ;;
      0) echo -e "${GREEN}已退出脚本${NC}"; exit 0 ;;
      *) echo -e "${RED}无效选择，请重新输入${NC}";;
    esac
  done
}

main "$@"
