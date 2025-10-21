#!/bin/bash

# ==========================================
# 修复主机名解析错误
# Fix: sudo: unable to resolve host
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 权限运行: sudo bash $0${NC}"
    exit 1
fi

# 获取当前主机名
HOSTNAME=$(hostname)

echo -e "${YELLOW}当前主机名: ${HOSTNAME}${NC}"

# 检查 /etc/hosts 中是否已存在主机名映射
if grep -q "127.0.1.1.*${HOSTNAME}" /etc/hosts; then
    echo -e "${GREEN}主机名已正确配置在 /etc/hosts 中${NC}"
    exit 0
fi

echo -e "${YELLOW}正在修复 /etc/hosts 配置...${NC}"

# 备份 /etc/hosts
cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)
echo -e "${GREEN}已备份 /etc/hosts${NC}"

# 添加主机名映射
if grep -q "^127.0.1.1" /etc/hosts; then
    # 如果存在 127.0.1.1 行，则更新它
    sed -i "s/^127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
else
    # 如果不存在，则在 127.0.0.1 后添加
    sed -i "/^127.0.0.1/a 127.0.1.1\t${HOSTNAME}" /etc/hosts
fi

echo -e "${GREEN}✅ 主机名解析问题已修复！${NC}"
echo -e "${YELLOW}修复内容：${NC}"
echo -e "  127.0.1.1\t${HOSTNAME}"
echo ""
echo -e "${GREEN}现在可以正常运行 DNS 解锁服务了${NC}"
