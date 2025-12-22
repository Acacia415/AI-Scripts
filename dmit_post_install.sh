#!/bin/bash
# DMIT VPS 网络自动恢复脚本
# 用于 reinstall.sh 重装后恢复网络
# 使用方法: curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/dmit_post_install.sh | bash

set -e
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'

echo "=========================================="
echo -e "${CYAN}  DMIT VPS 网络自动恢复${NC}"
echo "=========================================="
echo

# 检测网卡
echo -e "${CYAN}[步骤 1/6] 检测网卡...${NC}"
ETH=$(ip link show | grep -E '^[0-9]+: (eth|ens|enp)' | head -1 | cut -d: -f2 | tr -d ' ')
[ -z "$ETH" ] && { echo -e "${RED}错误: 未检测到网卡${NC}"; exit 1; }
echo -e "${GREEN}✓ 网卡: $ETH${NC}"
echo

# 配置 DNS  
echo -e "${CYAN}[步骤 2/6] 配置 DNS...${NC}"
cat > /etc/resolv.conf <<EOF
nameserver 2001:4860:4860::8888
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
echo -e "${GREEN}✓ DNS 配置完成${NC}"
echo

# 测试 IPv6
echo -e "${CYAN}[步骤 3/6] 测试 IPv6 连接...${NC}"
if ! ping6 -c 3 -W 2 google.com >/dev/null 2>&1; then
    echo -e "${RED}✗ IPv6 连接失败，无法自动安装 cloud-init${NC}"
    echo
    echo -e "${YELLOW}请手动配置 IPv4 网络：${NC}"
    echo "1. 从 DMIT 控制面板获取网络信息"
    echo "2. 运行以下命令："
    echo "   ip addr add <IP>/<掩码> dev $ETH"
    echo "   ip link set $ETH up"
    echo "   ip route add default via <网关>"
    exit 1
fi
echo -e "${GREEN}✓ IPv6 正常${NC}"
echo

# 更新软件源
echo -e "${CYAN}[步骤 4/6] 更新软件源...${NC}"
apt update || { echo -e "${RED}✗ 更新失败${NC}"; exit 1; }
echo -e "${GREEN}✓ 更新完成${NC}"
echo

# 安装 cloud-init
echo -e "${CYAN}[步骤 5/6] 安装 cloud-init...${NC}"
echo -e "${YELLOW}安装中，请耐心等待 2-5 分钟...${NC}"
apt install -y cloud-init cloud-initramfs-growroot || { echo -e "${RED}✗ 安装失败${NC}"; exit 1; }
echo -e "${GREEN}✓ 安装完成${NC}"
echo

# 配置 cloud-init
echo -e "${CYAN}[步骤 6/6] 配置 cloud-init...${NC}"
mkdir -p /etc/cloud/cloud.cfg.d/
cat > /etc/cloud/cloud.cfg.d/90_dmit.cfg <<'EOF'
datasource_list: [ ConfigDrive, NoCloud, None ]
datasource:
  ConfigDrive:
    dsmode: local
EOF

cloud-init clean --logs
cloud-init init --local && cloud-init init
cloud-init modules --mode=config  
cloud-init modules --mode=final

echo -e "${GREEN}✓ 配置完成${NC}"
echo

# 重启网络
systemctl restart networking 2>/dev/null || systemctl restart systemd-networkd 2>/dev/null || true
sleep 3

# 显示结果
echo "=========================================="
echo -e "${CYAN}网络配置：${NC}"
ip addr show $ETH | grep -E 'inet|link/ether'
echo
ip route show
echo "=========================================="
echo

# 测试连接
if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓✓✓  网络恢复成功！  ✓✓✓${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${YELLOW}建议重启系统使配置永久生效:${NC}"
    echo -e "${CYAN}reboot${NC}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠  IPv4 未完全恢复${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo "IPv6 可用但 IPv4 可能还有问题"
    echo -e "请尝试重启系统: ${CYAN}reboot${NC}"
fi

echo
echo "恢复脚本执行完成！"
