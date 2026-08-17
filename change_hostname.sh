#!/bin/bash

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

validate_hostname() {
    local value=$1
    (( ${#value} >= 1 && ${#value} <= 63 )) &&
        [[ $value =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

set_hostname_value() {
    local value=$1
    if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$value"; then
        return 0
    fi
    hostname "$value" || return 1
    printf '%s\n' "$value" > /etc/hostname
}

update_hosts_file() {
    local value=$1 source=/etc/hosts temp
    temp=$(mktemp /etc/.hosts.ai-scripts.XXXXXX) || return 1
    awk -v host="$value" '
        BEGIN { found_loopback=0; found_host=0 }
        $1 == "127.0.0.1" {
            for (i=2; i<=NF; i++) {
                if ($i == "localhost") found_loopback=1
            }
            print
            next
        }
        $1 == "127.0.1.1" {
            if (!found_host) { print "127.0.1.1\t" host; found_host=1 }
            next
        }
        { print }
        END {
            if (!found_loopback) print "127.0.0.1\tlocalhost"
            if (!found_host) print "127.0.1.1\t" host
        }
    ' "$source" > "$temp" || { rm -f -- "$temp"; return 1; }
    chmod --reference="$source" "$temp" 2>/dev/null || chmod 644 "$temp"
    chown --reference="$source" "$temp" 2>/dev/null || true
    mv -f "$temp" "$source" || { rm -f -- "$temp"; return 1; }
}

update_sysconfig_network() {
    local value=$1 source=/etc/sysconfig/network temp
    [[ -f $source ]] || return 0
    temp=$(mktemp /etc/sysconfig/.network.ai-scripts.XXXXXX) || return 1
    awk -v host="$value" '
        BEGIN { replaced=0 }
        /^HOSTNAME=/ {
            if (!replaced) { print "HOSTNAME=" host; replaced=1 }
            next
        }
        { print }
        END { if (!replaced) print "HOSTNAME=" host }
    ' "$source" > "$temp" || { rm -f -- "$temp"; return 1; }
    chmod --reference="$source" "$temp" 2>/dev/null || chmod 644 "$temp"
    chown --reference="$source" "$temp" 2>/dev/null || true
    mv -f "$temp" "$source" || { rm -f -- "$temp"; return 1; }
}

change_hostname_safely() {
    local new_hostname=$1 old_hostname timestamp backup_dir
    old_hostname=$(hostname)
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_dir="/var/backups/ai-scripts/hostname/${timestamp}"
    install -d -m 700 "$backup_dir"
    cp -a /etc/hosts "$backup_dir/hosts"
    [[ -f /etc/hostname ]] && cp -a /etc/hostname "$backup_dir/hostname"
    [[ -f /etc/sysconfig/network ]] && cp -a /etc/sysconfig/network "$backup_dir/sysconfig-network"

    if ! set_hostname_value "$new_hostname" \
        || ! update_hosts_file "$new_hostname" \
        || ! update_sysconfig_network "$new_hostname"; then
        echo -e "${RED}修改失败，正在恢复原配置……${NC}"
        set_hostname_value "$old_hostname" || true
        cp -a "$backup_dir/hosts" /etc/hosts
        if [[ -f $backup_dir/hostname ]]; then
            cp -a "$backup_dir/hostname" /etc/hostname
        else
            rm -f /etc/hostname
        fi
        [[ -f $backup_dir/sysconfig-network ]] && cp -a "$backup_dir/sysconfig-network" /etc/sysconfig/network
        return 1
    fi

    echo -e "${GREEN}主机名已修改为 ${YELLOW}${new_hostname}${NC}"
    echo -e "${BLUE}备份位置：${backup_dir}${NC}"
}

main() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 权限运行。${NC}"
        exit 1
    fi

    echo -e "${GREEN}当前主机名：${YELLOW}$(hostname)${NC}"
    local new_hostname
    while true; do
        read -r -p '请输入新主机名（输入 0 退出）: ' new_hostname
        [[ $new_hostname == 0 ]] && return 0
        if validate_hostname "$new_hostname"; then
            change_hostname_safely "$new_hostname"
            return
        fi
        echo -e "${RED}主机名只能包含字母、数字和连字符，长度为 1–63，且不能以连字符开头或结尾。${NC}"
    done
}

main "$@"
