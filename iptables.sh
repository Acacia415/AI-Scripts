#!/bin/bash

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
STATE_DIR=/etc/ai-scripts/port-forward
RULES_FILE="$STATE_DIR/rules.tsv"
SYSCTL_FILE=/etc/sysctl.d/99-ai-scripts-port-forward.conf
NAT_PRE=AI_FWD_PRE
NAT_POST=AI_FWD_POST
FILTER_FWD=AI_FWD_FILTER

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
pause_menu() { read -r -p '按回车键继续……' _; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { error '请使用 root 权限运行。'; exit 1; }
    [[ -f /etc/debian_version ]] || { error '当前安装流程仅支持 Debian/Ubuntu。'; exit 1; }
}

init_environment() {
    if ! command -v iptables >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y iptables
    fi
    command -v iptables-save >/dev/null 2>&1 && command -v iptables-restore >/dev/null 2>&1 || {
        error 'iptables 工具不完整。'; exit 1;
    }
    install -d -m 700 "$STATE_DIR"
    touch "$RULES_FILE"
    chmod 600 "$RULES_FILE"
}

validate_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

validate_ipv4() {
    local value=$1 part
    [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
}

resolve_target() {
    local target=$1 result
    if validate_ipv4 "$target"; then printf '%s' "$target"; return; fi
    [[ $target =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    result=$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1 {print $1}')
    validate_ipv4 "$result" || return 1
    printf '%s' "$result"
}

backup_current_rules() {
    local timestamp dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    dir="/var/backups/ai-scripts/iptables/${timestamp}"
    install -d -m 700 "$dir"
    iptables-save > "$dir/iptables.rules"
    cp -a "$RULES_FILE" "$dir/port-forward-rules.tsv"
    printf '%s' "$dir"
}

ensure_chain() {
    local table=$1 chain=$2 parent=$3
    iptables -t "$table" -N "$chain" 2>/dev/null || true
    iptables -t "$table" -F "$chain"
    if ! iptables -t "$table" -C "$parent" -j "$chain" 2>/dev/null; then
        iptables -t "$table" -A "$parent" -m comment --comment ai-scripts-port-forward -j "$chain"
    fi
}

persist_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || warn '持久化失败，当前运行时规则仍然有效。'
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
    else
        warn '未安装 iptables-persistent，重启后规则可能丢失。'
    fi
}

apply_managed_rules() {
    local backup_dir protocol local_port remote_ip remote_port
    backup_dir=$(backup_current_rules) || return 1
    install -d -m 755 /etc/sysctl.d
    printf '# Managed by AI-Scripts\nnet.ipv4.ip_forward = 1\n' > "$SYSCTL_FILE"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1

    if ! ensure_chain nat "$NAT_PRE" PREROUTING ||
       ! ensure_chain nat "$NAT_POST" POSTROUTING ||
       ! ensure_chain filter "$FILTER_FWD" FORWARD; then
        iptables-restore < "$backup_dir/iptables.rules"
        return 1
    fi

    iptables -A "$FILTER_FWD" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    while IFS=$'\t' read -r protocol local_port remote_ip remote_port; do
        [[ -n ${protocol:-} ]] || continue
        if ! iptables -t nat -A "$NAT_PRE" -p "$protocol" --dport "$local_port" -m comment --comment ai-scripts-port-forward -j DNAT --to-destination "${remote_ip}:${remote_port}" ||
           ! iptables -t nat -A "$NAT_POST" -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m comment --comment ai-scripts-port-forward -j MASQUERADE ||
           ! iptables -A "$FILTER_FWD" -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m conntrack --ctstate NEW -m comment --comment ai-scripts-port-forward -j ACCEPT; then
            error "应用 ${protocol} ${local_port} 转发失败，正在恢复防火墙。"
            iptables-restore < "$backup_dir/iptables.rules"
            return 1
        fi
    done < "$RULES_FILE"
    persist_rules
}

add_forward() {
    local protocol=$1 local_port target remote_ip remote_port entry
    read -r -p '本地端口 (1-65535): ' local_port
    validate_port "$local_port" || { error '端口无效。'; return; }
    read -r -p '目标 IPv4 或域名: ' target
    remote_ip=$(resolve_target "$target") || { error '目标地址无效或无法解析。'; return; }
    read -r -p '目标端口 (1-65535): ' remote_port
    validate_port "$remote_port" || { error '端口无效。'; return; }

    local protocols=()
    [[ $protocol == both ]] && protocols=(tcp udp) || protocols=("$protocol")
    local proto
    for proto in "${protocols[@]}"; do
        entry=$(printf '%s\t%s\t%s\t%s' "$proto" "$local_port" "$remote_ip" "$remote_port")
        grep -Fqx "$entry" "$RULES_FILE" || printf '%s\n' "$entry" >> "$RULES_FILE"
    done
    if apply_managed_rules; then info "已添加：${local_port} -> ${remote_ip}:${remote_port}"; else error '添加失败。'; fi
}

list_rules() {
    echo -e "${CYAN}编号  协议  本地端口  目标${NC}"
    if [[ ! -s $RULES_FILE ]]; then warn '暂无本脚本管理的规则。'; return; fi
    awk -F '\t' '{printf "%-5d %-5s %-9s %s:%s\n", NR, $1, $2, $3, $4}' "$RULES_FILE"
}

delete_rule() {
    list_rules
    [[ -s $RULES_FILE ]] || return
    local number total temp backup
    read -r -p '输入要删除的编号（0 取消）: ' number
    [[ $number == 0 ]] && return
    total=$(wc -l < "$RULES_FILE")
    [[ $number =~ ^[0-9]+$ ]] && (( number >= 1 && number <= total )) || { error '编号无效。'; return; }
    backup=$(backup_current_rules) || return
    temp=$(mktemp "$STATE_DIR/.rules.XXXXXX")
    awk -v number="$number" 'NR != number' "$RULES_FILE" > "$temp"
    chmod 600 "$temp" && mv -f "$temp" "$RULES_FILE"
    if apply_managed_rules; then info "已删除。操作前备份：$backup"; else cp -a "$backup/port-forward-rules.tsv" "$RULES_FILE"; fi
}

manual_backup() {
    local path
    path=$(backup_current_rules) && info "备份完成：$path"
}

restore_rules() {
    local path confirm current
    read -r -p 'iptables-save 备份文件路径: ' path
    [[ -f $path ]] || { error '文件不存在。'; return; }
    if iptables-restore --help 2>&1 | grep -q -- '--test'; then
        iptables-restore --test < "$path" || { error '备份语法验证失败。'; return; }
    fi
    read -r -p '该操作将替换全部 IPv4 iptables 规则，输入 RESTORE 确认: ' confirm
    [[ $confirm == RESTORE ]] || return
    current=$(backup_current_rules) || return
    if iptables-restore < "$path"; then
        persist_rules
        info "恢复成功。恢复前备份：$current"
    else
        error '恢复失败，正在恢复操作前规则。'
        iptables-restore < "$current/iptables.rules"
    fi
}

main() {
    require_root
    init_environment
    local choice
    while true; do
        clear
        echo -e "${BLUE}======== IPv4 端口转发管理 ========${NC}"
        echo '1. 添加 TCP+UDP   2. 添加 TCP   3. 添加 UDP'
        echo '4. 查看规则       5. 删除规则    6. 备份全部规则'
        echo '7. 恢复全部规则   0. 退出'
        read -r -p '请选择: ' choice
        case $choice in
            1) add_forward both; pause_menu ;;
            2) add_forward tcp; pause_menu ;;
            3) add_forward udp; pause_menu ;;
            4) list_rules; pause_menu ;;
            5) delete_rule; pause_menu ;;
            6) manual_backup; pause_menu ;;
            7) restore_rules; pause_menu ;;
            0) return ;;
            *) warn '无效选项。'; pause_menu ;;
        esac
    done
}

main "$@"
