#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 权限运行。${NC}"
        exit 1
    fi
}

restore_current_backup() {
    local current_backup=$1 had_sysctl_dir=$2
    cp -a "$current_backup/sysctl.conf" /etc/sysctl.conf
    rm -rf -- /etc/sysctl.d
    if [[ $had_sysctl_dir == yes ]]; then
        cp -a "$current_backup/sysctl.d" /etc/sysctl.d
    else
        install -d -m 755 /etc/sysctl.d
    fi
    sysctl --system >/dev/null 2>&1 || true
}

uninstall_tcp_optimization() {
    require_root
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}             恢复原始 TCP/sysctl 配置             ${NC}"
    echo -e "${YELLOW}==================================================${NC}"

    local backups=()
    mapfile -t backups < <(find /etc -maxdepth 1 -type f -name 'sysctl.conf.bk_*' -print | sort -r)
    if (( ${#backups[@]} == 0 )); then
        echo -e "${RED}未找到 /etc/sysctl.conf.bk_* 备份，无法自动恢复。${NC}"
        return 1
    fi

    echo -e "${GREEN}请选择要恢复的版本：${NC}"
    local backup_file PS3='请输入选项: '
    select backup_file in "${backups[@]}"; do
        [[ -n $backup_file ]] && break
        echo -e "${RED}无效选择。${NC}"
    done

    local timestamp backup_dir
    timestamp=${backup_file##*bk_}
    backup_dir="/etc/sysctl.d.bk_${timestamp}"
    echo -e "${YELLOW}将恢复版本 ${timestamp}。恢复前会再次备份当前配置。${NC}"
    [[ -d $backup_dir ]] && echo "同时恢复：$backup_dir"

    local confirm
    read -r -p '确认继续？(y/N): ' confirm
    [[ $confirm =~ ^[Yy]$ ]] || return 0

    local now current_backup stage had_sysctl_dir=no
    now=$(date +%Y%m%d-%H%M%S)
    current_backup="/var/backups/ai-scripts/sysctl-restore/${now}"
    stage=$(mktemp -d /etc/.ai-sysctl-restore.XXXXXX)
    trap 'rm -rf -- "$stage"' RETURN

    install -d -m 700 "$current_backup"
    cp -a /etc/sysctl.conf "$current_backup/sysctl.conf"
    if [[ -d /etc/sysctl.d ]]; then
        cp -a /etc/sysctl.d "$current_backup/sysctl.d"
        had_sysctl_dir=yes
    fi

    cp -a "$backup_file" "$stage/sysctl.conf"
    if [[ -d $backup_dir ]]; then
        cp -a "$backup_dir" "$stage/sysctl.d"
    else
        cp -a /etc/sysctl.d "$stage/sysctl.d"
    fi

    echo -e "${CYAN}当前配置备份：${current_backup}${NC}"
    cp -a "$stage/sysctl.conf" /etc/sysctl.conf.ai-new
    mv -f /etc/sysctl.conf.ai-new /etc/sysctl.conf

    local old_dir="/etc/sysctl.d.ai-old-${now}"
    if [[ -e $old_dir ]]; then
        echo -e "${RED}安全检查失败：临时目录已存在：${old_dir}${NC}"
        restore_current_backup "$current_backup" "$had_sysctl_dir"
        return 1
    fi

    mv /etc/sysctl.d "$old_dir"
    if ! mv "$stage/sysctl.d" /etc/sysctl.d; then
        mv "$old_dir" /etc/sysctl.d
        restore_current_backup "$current_backup" "$had_sysctl_dir"
        return 1
    fi

    if ! sysctl --system; then
        echo -e "${RED}应用恢复配置失败，正在自动回滚……${NC}"
        restore_current_backup "$current_backup" "$had_sysctl_dir"
        rm -rf -- "$old_dir"
        return 1
    fi

    rm -rf -- "$old_dir"
    echo -e "${GREEN}恢复成功。若需撤销，可使用：${current_backup}${NC}"
}

uninstall_tcp_optimization
