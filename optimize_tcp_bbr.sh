#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
NC='\033[0m'

version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

restore_on_error() {
    local backup_file=$1 managed_file=$2 old_managed=$3
    cp -a "$backup_file" /etc/sysctl.conf
    if [[ -f $old_managed ]]; then
        cp -a "$old_managed" "$managed_file"
    else
        rm -f -- "$managed_file"
    fi
    sysctl --system >/dev/null 2>&1 || true
}

optimize_tcp_performance() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 权限运行。${NC}"
        return 1
    fi

    local kernel_version
    kernel_version=$(uname -r | cut -d- -f1)
    if ! version_ge "$kernel_version" 4.9; then
        echo -e "${RED}BBR 需要 Linux 4.9 或更高版本，当前为 ${kernel_version}。${NC}"
        return 1
    fi

    modprobe tcp_bbr 2>/dev/null || true
    if [[ ! -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] ||
       ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        echo -e "${RED}当前内核没有提供 BBR，未修改配置。${NC}"
        return 1
    fi

    local timestamp backup_conf backup_dir managed_file old_managed temp_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_conf="/etc/sysctl.conf.bk_${timestamp}"
    backup_dir="/etc/sysctl.d.bk_${timestamp}"
    managed_file=/etc/sysctl.d/99-ai-scripts-bbr.conf
    old_managed="/var/backups/ai-scripts/bbr/${timestamp}/99-ai-scripts-bbr.conf"

    install -d -m 700 "$(dirname "$old_managed")"
    cp -a /etc/sysctl.conf "$backup_conf"
    cp -a /etc/sysctl.d "$backup_dir"
    [[ -f $managed_file ]] && cp -a "$managed_file" "$old_managed"
    echo -e "${CYAN}备份完成：${backup_conf}、${backup_dir}${NC}"

    temp_file=$(mktemp /etc/sysctl.d/.99-ai-scripts-bbr.XXXXXX)
    trap 'rm -f -- "$temp_file"' RETURN
    cat > "$temp_file" <<'EOF'
# Managed by AI-Scripts optimize_tcp_bbr.sh
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 644 "$temp_file"
    mv -f "$temp_file" "$managed_file"

    if ! sysctl --system; then
        echo -e "${RED}应用失败，正在恢复修改前配置……${NC}"
        restore_on_error "$backup_conf" "$managed_file" "$old_managed"
        return 1
    fi

    local bbr_status fq_status
    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    fq_status=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    if [[ $bbr_status != bbr || $fq_status != fq ]]; then
        echo -e "${RED}验证失败，正在恢复修改前配置……${NC}"
        restore_on_error "$backup_conf" "$managed_file" "$old_managed"
        return 1
    fi

    echo -e "${GREEN}BBR + fq 已启用。配置集中保存在 ${managed_file}，重复运行不会堆积配置块。${NC}"
}

optimize_tcp_performance
