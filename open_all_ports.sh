#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

open_family() {
    local command_name=$1
    command -v "$command_name" >/dev/null 2>&1 || return 0
    "$command_name" -P INPUT ACCEPT
    "$command_name" -P FORWARD ACCEPT
    "$command_name" -P OUTPUT ACCEPT
    "$command_name" -F
    "$command_name" -X
    "$command_name" -Z
}

open_all_ports() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 权限运行。${NC}"
        return 1
    fi
    if ! command -v iptables >/dev/null 2>&1 && ! command -v ip6tables >/dev/null 2>&1; then
        echo -e "${RED}未找到 iptables/ip6tables 兼容命令；纯 nftables 环境请手动处理。${NC}"
        return 1
    fi

    echo -e "${RED}安全警告：此操作会开放 IPv4 和 IPv6 的全部端口。${NC}"
    echo -e "${YELLOW}NAT/mangle/raw 表不会被清空；UFW/firewalld 的持久配置也不会被删除。${NC}"
    local confirm
    read -r -p '请输入 OPEN 确认继续: ' confirm
    [[ $confirm == OPEN ]] || { echo -e "${BLUE}已取消。${NC}"; return 0; }

    local timestamp backup_dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="/var/backups/ai-scripts/firewall-open/${timestamp}"
    install -d -m 700 "$backup_dir"
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$backup_dir/iptables.rules"
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$backup_dir/ip6tables.rules"
    command -v nft >/dev/null 2>&1 && nft list ruleset > "$backup_dir/nft.rules" 2>/dev/null || true

    rollback_firewall_open() {
        trap - ERR
        echo -e "${RED}应用防火墙变更失败，正在恢复备份。${NC}"
        [[ ! -s "$backup_dir/iptables.rules" ]] || iptables-restore < "$backup_dir/iptables.rules" || true
        [[ ! -s "$backup_dir/ip6tables.rules" ]] || ip6tables-restore < "$backup_dir/ip6tables.rules" || true
    }
    trap rollback_firewall_open ERR

    open_family iptables
    open_family ip6tables
    trap - ERR

    echo -e "${GREEN}IPv4/IPv6 filter 规则已开放。备份：${backup_dir}${NC}"
    echo -e "${YELLOW}该修改不保证重启后继续生效；持久防火墙服务可能重新加载原策略。${NC}"
    command -v iptables >/dev/null 2>&1 && iptables -L -n --line-numbers
}

open_all_ports
