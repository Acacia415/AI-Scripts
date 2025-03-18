#!/bin/bash
# 卸载脚本 - GitHub直链版
# 下载地址：https://raw.githubusercontent.com/Acacia415/GPT-Scripts/main/uninstall.sh

set -e

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31m错误：请使用sudo运行此脚本\033[0m"
  exit 1
fi

# 高危操作确认
read -p "⚠️  确定要完全卸载IP黑名单服务吗？[y/N] " confirm
if [[ ! "$confirm" =~ [yY] ]]; then
  echo "已取消卸载操作"
  exit 0
fi

echo -e "\n\033[34m[1/6] 停止并禁用服务...\033[0m"
systemctl disable --now ip_blacklist.service 2>/dev/null || true

echo -e "\n\033[34m[2/6] 删除核心文件...\033[0m"
rm -f /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

echo -e "\n\033[34m[3/6] 清理网络规则...\033[0m"
iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true
iptables -F TRAFFIC_BLOCK 2>/dev/null || true
iptables -X TRAFFIC_BLOCK 2>/dev/null || true
ipset flush banlist 2>/dev/null || true
ipset destroy banlist 2>/dev/null || true

echo -e "\n\033[34m[4/6] 删除日志文件...\033[0m"
rm -f /var/log/iptables_ban.log /etc/logrotate.d/iptables_ban

echo -e "\n\033[34m[5/6] 重载系统配置...\033[0m"
systemctl daemon-reload
systemctl reset-failed

echo -e "\n\033[34m[6/6] 最终检查...\033[0m"
echo -n "服务状态: " && systemctl status ip_blacklist.service 2>&1 | grep -q "not found" && echo "已移除" || echo "存在"
echo -n "IPTables链: " && (iptables -L TRAFFIC_BLOCK &>/dev/null && echo "存在" || echo "已移除")
echo -n "IPSet黑名单: " && (ipset list banlist &>/dev/null && echo "存在" || echo "已移除")

echo -e "\n\033[32m✅ 卸载完成！建议重启服务器确保内存规则清除\033[0m"
