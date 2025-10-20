#!/bin/bash
# Fail2Ban 一键安装脚本（启用 SSH 防护 + 自定义参数 + 白名单 + 启动检测）
# 适用系统：Debian / Ubuntu

set -e

echo "==== Fail2Ban SSH 防护一键安装 ===="

# 输入参数
read -p "请输入封禁时间 (秒, 默认600=10分钟): " BANTIME
read -p "请输入检测时间窗口 (秒, 默认600=10分钟): " FINDTIME
read -p "请输入最大失败次数 (默认5): " MAXRETRY
read -p "请输入白名单IP (多个用空格分隔，直接回车跳过): " IGNOREIPS

# 设置默认值
BANTIME=${BANTIME:-600}
FINDTIME=${FINDTIME:-600}
MAXRETRY=${MAXRETRY:-5}
IGNOREIPS=${IGNOREIPS:-127.0.0.1/8}

echo "使用配置: 封禁时间=${BANTIME}s, 检测窗口=${FINDTIME}s, 最大失败次数=${MAXRETRY}, 白名单IP=${IGNOREIPS}"

echo "==== 更新系统并安装 Fail2Ban ===="
sudo apt update -y
sudo apt install fail2ban -y

echo "==== 生成 jail.local 配置文件 ===="
cat << EOF | sudo tee /etc/fail2ban/jail.local > /dev/null
[DEFAULT]
# 封禁时间
bantime = ${BANTIME}
# 检测时间窗口
findtime = ${FINDTIME}
# 最大失败次数
maxretry = ${MAXRETRY}
# 白名单 IP（不会被封禁）
ignoreip = ${IGNOREIPS}
# 使用 systemd 作为后端
backend = systemd

[sshd]
enabled = true
port    = ssh
logpath = /var/log/auth.log
EOF

echo "==== 启动并设置开机自启 Fail2Ban ===="
sudo systemctl enable --now fail2ban

# 等待 Fail2Ban 启动完成
echo "等待 Fail2Ban 启动..."
sleep 3  # 给 Fail2Ban 启动时间

# 检测服务是否运行
if sudo systemctl is-active --quiet fail2ban; then
    echo "Fail2Ban 服务已启动。SSH jail 状态如下："
    sudo fail2ban-client status sshd
else
    echo "Fail2Ban 启动失败，请查看日志排查："
    sudo journalctl -u fail2ban -n 50 --no-pager
    exit 1
fi

echo "==== 安装完成 ===="
