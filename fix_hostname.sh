#!/bin/bash

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}请使用 root 权限运行。${NC}"
    exit 1
fi

current_hostname=$(hostname)
if awk -v host="$current_hostname" '$1 == "127.0.1.1" { for (i=2; i<=NF; i++) if ($i == host) found=1 } END { exit !found }' /etc/hosts; then
    echo -e "${GREEN}主机名已正确配置在 /etc/hosts 中。${NC}"
    exit 0
fi

timestamp=$(date +%Y%m%d_%H%M%S)
backup="/etc/hosts.backup.${timestamp}"
temp=$(mktemp /etc/.hosts.ai-fix.XXXXXX)
cp -a /etc/hosts "$backup"

awk -v host="$current_hostname" '
    BEGIN { replaced=0 }
    $1 == "127.0.1.1" { if (!replaced) { print "127.0.1.1\t" host; replaced=1 }; next }
    { print }
    END { if (!replaced) print "127.0.1.1\t" host }
' /etc/hosts > "$temp"
chmod --reference=/etc/hosts "$temp" 2>/dev/null || chmod 644 "$temp"
chown --reference=/etc/hosts "$temp" 2>/dev/null || true

if mv -f "$temp" /etc/hosts && getent hosts "$current_hostname" >/dev/null 2>&1; then
    echo -e "${GREEN}主机名解析已修复。备份：${backup}${NC}"
else
    echo -e "${RED}验证失败，正在恢复 /etc/hosts。${NC}"
    cp -a "$backup" /etc/hosts
    rm -f -- "$temp"
    exit 1
fi
