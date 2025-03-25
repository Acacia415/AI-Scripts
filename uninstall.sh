#!/bin/bash
# 卸载脚本优化版 - GitHub直链版
# 下载地址：https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/uninstall.sh

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
