#!/bin/bash

# Fail2Ban 交互式管理脚本
# 仅管理 AI-Scripts 自己的 SSH jail，不覆盖用户的 jail.local 或其他 jail。

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAIL2BAN_CONFIG_DIR="${FAIL2BAN_CONFIG_DIR:-/etc/fail2ban}"
FAIL2BAN_MANAGED_FILE="${FAIL2BAN_MANAGED_FILE:-${FAIL2BAN_CONFIG_DIR}/jail.d/ai-scripts-sshd.local}"
FAIL2BAN_BACKUP_ROOT="${FAIL2BAN_BACKUP_ROOT:-/var/backups/ai-scripts/fail2ban}"
FAIL2BAN_BACKUP_KEEP="${FAIL2BAN_BACKUP_KEEP:-5}"
FAIL2BAN_SERVICE="${FAIL2BAN_SERVICE:-fail2ban.service}"
FAIL2BAN_STABLE_ATTEMPTS="${FAIL2BAN_STABLE_ATTEMPTS:-10}"
FAIL2BAN_STABLE_INTERVAL="${FAIL2BAN_STABLE_INTERVAL:-1}"
FAIL2BAN_PYTHON_BIN="${FAIL2BAN_PYTHON_BIN:-python3}"
MANAGED_MARKER='# Managed by AI-Scripts install_fail2ban.sh'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行。"
        return 1
    fi
}

check_system() {
    [[ -f /etc/debian_version ]] || {
        print_error "此脚本仅支持 Debian/Ubuntu。"
        return 1
    }
}

validate_runtime_settings() {
    [[ "$FAIL2BAN_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        print_error "备份保留数量无效: $FAIL2BAN_BACKUP_KEEP"
        return 1
    }
    [[ "$FAIL2BAN_STABLE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
        print_error "服务稳定检查次数无效。"
        return 1
    }
    [[ "$FAIL2BAN_STABLE_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        print_error "服务稳定检查间隔无效。"
        return 1
    }
}

validate_integer_range() {
    local value="$1" minimum="$2" maximum="$3"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    ((${#value} <= ${#maximum})) || return 1
    ((10#$value >= minimum && 10#$value <= maximum))
}

normalize_ip_token() {
    local token="$1"
    command -v "$FAIL2BAN_PYTHON_BIN" >/dev/null 2>&1 || return 1
    "$FAIL2BAN_PYTHON_BIN" - "$token" <<'PY'
import ipaddress
import sys

value = sys.argv[1]
try:
    parsed = ipaddress.ip_network(value, strict=False) if "/" in value else ipaddress.ip_address(value)
except ValueError:
    raise SystemExit(1)
print(parsed)
PY
}

normalize_ip_list() {
    local raw="$1" token normalized
    local -a result=() tokens=()
    local -A seen=()
    [[ -n "$raw" ]] || raw='127.0.0.1/8 ::1'
    read -r -a tokens <<< "$raw"
    for token in "${tokens[@]}"; do
        normalized=$(normalize_ip_token "$token") || return 1
        [[ -v 'seen[$normalized]' ]] && continue
        seen["$normalized"]=1
        result+=("$normalized")
    done
    ((${#result[@]} > 0)) || return 1
    printf '%s\n' "${result[*]}"
}

validate_single_ip() {
    local normalized
    normalized=$(normalize_ip_token "$1") || return 1
    [[ "$normalized" != */* ]] || return 1
    printf '%s\n' "$normalized"
}

is_owned_managed_file() {
    [[ -f "$FAIL2BAN_MANAGED_FILE" && ! -L "$FAIL2BAN_MANAGED_FILE" ]] \
        && grep -Fxq "$MANAGED_MARKER" "$FAIL2BAN_MANAGED_FILE"
}

prune_backup_kind() {
    local kind="$1" index
    local -a backups=()
    mapfile -t backups < <(find "$FAIL2BAN_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name "${kind}.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=FAIL2BAN_BACKUP_KEEP; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$FAIL2BAN_BACKUP_ROOT/${kind}."* ]] || continue
        rm -rf -- "${backups[$index]}"
    done
}

create_transaction_backup() {
    local reason="$1" backup_dir active=false enabled=false
    umask 077
    install -d -m 700 "$FAIL2BAN_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$FAIL2BAN_BACKUP_ROOT/transaction.${reason}.XXXXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1
    if [[ -e "$FAIL2BAN_MANAGED_FILE" || -L "$FAIL2BAN_MANAGED_FILE" ]]; then
        cp -a -- "$FAIL2BAN_MANAGED_FILE" "$backup_dir/managed.local" || return 1
    else
        : > "$backup_dir/managed.missing" || return 1
    fi
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && active=true
    systemctl is-enabled --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && enabled=true
    printf '%s\n' "$active" > "$backup_dir/service.active"
    printf '%s\n' "$enabled" > "$backup_dir/service.enabled"
    prune_backup_kind transaction
    printf '%s\n' "$backup_dir"
}

atomic_install_file() {
    local source_file="$1" target_file="$2" mode="$3" target_dir temp_file
    target_dir=$(dirname -- "$target_file")
    install -d -m 755 "$target_dir" || return 1
    temp_file=$(mktemp "$target_dir/.ai-scripts-fail2ban.XXXXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

restore_service_state() {
    local backup_dir="$1" was_active was_enabled status=0
    was_active=$(< "$backup_dir/service.active")
    was_enabled=$(< "$backup_dir/service.enabled")
    if [[ "$was_enabled" == true ]]; then
        systemctl enable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || status=1
    else
        systemctl disable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ "$was_active" == true ]]; then
        systemctl restart "$FAIL2BAN_SERVICE" >/dev/null 2>&1 \
            || systemctl start "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || status=1
    else
        systemctl stop "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    fi
    return "$status"
}

restore_transaction_backup() {
    local backup_dir="$1" status=0
    if [[ -f "$backup_dir/managed.missing" ]]; then
        rm -f -- "$FAIL2BAN_MANAGED_FILE" || status=1
    elif [[ -f "$backup_dir/managed.local" ]]; then
        atomic_install_file "$backup_dir/managed.local" "$FAIL2BAN_MANAGED_FILE" 600 || status=1
    else
        status=1
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null 2>&1 || status=1
    fi
    restore_service_state "$backup_dir" || status=1
    return "$status"
}

write_managed_config() {
    local output_file="$1" bantime="$2" findtime="$3" maxretry="$4" ignoreips="$5"
    cat > "$output_file" <<EOF
$MANAGED_MARKER
# This file only controls the sshd jail. Other Fail2Ban configuration is preserved.
[sshd]
enabled = true
backend = systemd
mode = extra
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = $ignoreips
EOF
    chmod 600 "$output_file"
}

validate_fail2ban_config() {
    fail2ban-client -t >/dev/null 2>&1
}

wait_for_fail2ban_stable() {
    local require_sshd="${1:-true}" attempt
    for ((attempt=1; attempt<=FAIL2BAN_STABLE_ATTEMPTS; attempt++)); do
        if systemctl is-active --quiet "$FAIL2BAN_SERVICE" 2>/dev/null \
            && fail2ban-client ping 2>/dev/null | grep -Fq pong; then
            if [[ "$require_sshd" == false ]] || fail2ban-client status sshd >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep "$FAIL2BAN_STABLE_INTERVAL"
    done
    return 1
}

activate_managed_config() {
    systemctl enable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || return 1
    systemctl restart "$FAIL2BAN_SERVICE" >/dev/null 2>&1 \
        || systemctl start "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || return 1
    wait_for_fail2ban_stable true
}

apply_managed_config() {
    local staged_file="$1" backup_dir="$2"
    if ! atomic_install_file "$staged_file" "$FAIL2BAN_MANAGED_FILE" 600; then
        print_error "无法安装专属 jail 配置。"
        return 1
    fi
    if validate_fail2ban_config && activate_managed_config; then
        print_success "专属 SSH jail 已通过配置测试并稳定运行。"
        return 0
    fi
    print_error "配置测试或服务稳定检查失败，正在恢复修改前状态。"
    if restore_transaction_backup "$backup_dir"; then
        print_warning "已恢复修改前配置和服务状态；备份保留在: $backup_dir"
    else
        print_error "自动回滚未完全成功，请使用备份手动恢复: $backup_dir"
    fi
    return 1
}

read_managed_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        value=$2; sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); print value; exit
    }' "$FAIL2BAN_MANAGED_FILE"
}

install_packages() {
    print_info "安装 Fail2Ban 及 systemd Python 后端..."
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd || return 1
    command -v fail2ban-client >/dev/null 2>&1
}

install_fail2ban() {
    local bantime findtime maxretry ignoreips_raw ignoreips confirm backup_dir stage_dir stage_file
    clear
    echo -e "${GREEN}==== Fail2Ban SSH 防护安装/配置 ====${NC}"
    echo
    command -v "$FAIL2BAN_PYTHON_BIN" >/dev/null 2>&1 || {
        print_error "严格校验 IP 需要 python3；请先安装 python3。"
        read -r -p "按回车键返回主菜单..."
        return 1
    }
    if [[ -e "$FAIL2BAN_MANAGED_FILE" || -L "$FAIL2BAN_MANAGED_FILE" ]]; then
        is_owned_managed_file || {
            print_error "专属路径已存在但不属于本脚本，拒绝覆盖: $FAIL2BAN_MANAGED_FILE"
            read -r -p "按回车键返回主菜单..."
            return 1
        }
        print_warning "检测到现有 AI-Scripts SSH jail，将进行安全重新配置。"
    fi

    read -r -p "请输入封禁时间（秒，默认 600，范围 1-315360000）: " bantime
    read -r -p "请输入检测时间窗口（秒，默认 600，范围 1-31536000）: " findtime
    read -r -p "请输入最大失败次数（默认 5，范围 1-1000）: " maxretry
    read -r -p "请输入白名单 IP/CIDR（空格分隔，默认本机回环）: " ignoreips_raw
    bantime=${bantime:-600}
    findtime=${findtime:-600}
    maxretry=${maxretry:-5}
    validate_integer_range "$bantime" 1 315360000 || { print_error "封禁时间无效。"; return 1; }
    validate_integer_range "$findtime" 1 31536000 || { print_error "检测时间窗口无效。"; return 1; }
    validate_integer_range "$maxretry" 1 1000 || { print_error "最大失败次数无效。"; return 1; }
    ignoreips=$(normalize_ip_list "$ignoreips_raw") || { print_error "白名单包含无效 IP 或 CIDR。"; return 1; }

    echo
    print_info "封禁=${bantime}s，窗口=${findtime}s，重试=${maxretry}，白名单=${ignoreips}"
    read -r -p "确认安装或重新配置？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { print_warning "已取消。"; return 0; }

    backup_dir=$(create_transaction_backup install) || {
        print_error "无法创建操作前备份，已停止。"
        return 1
    }
    install_packages || {
        print_error "Fail2Ban 软件包安装失败，未修改专属配置。"
        return 1
    }
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-fail2ban.XXXXXXXX") || return 1
    stage_file="$stage_dir/ai-scripts-sshd.local"
    write_managed_config "$stage_file" "$bantime" "$findtime" "$maxretry" "$ignoreips" || {
        rm -rf -- "$stage_dir"
        return 1
    }
    if apply_managed_config "$stage_file" "$backup_dir"; then
        rm -rf -- "$stage_dir"
        print_success "安装/配置完成，修改前备份: $backup_dir"
        fail2ban-client status sshd || true
    else
        rm -rf -- "$stage_dir"
        return 1
    fi
    echo
    read -r -p "按回车键返回主菜单..."
}

remove_managed_config() {
    local confirm backup_dir status=0 was_active=false
    clear
    echo -e "${YELLOW}==== 移除 AI-Scripts SSH 防护配置 ====${NC}"
    echo
    if [[ ! -e "$FAIL2BAN_MANAGED_FILE" && ! -L "$FAIL2BAN_MANAGED_FILE" ]]; then
        print_warning "没有找到本脚本的专属配置；其他 Fail2Ban 配置未修改。"
        read -r -p "按回车键返回主菜单..."
        return 0
    fi
    is_owned_managed_file || {
        print_error "专属路径不含本脚本标识，拒绝删除: $FAIL2BAN_MANAGED_FILE"
        return 1
    }
    print_info "只会删除 $FAIL2BAN_MANAGED_FILE，不卸载软件包，也不修改其他 jail。"
    read -r -p "确认移除本脚本的 SSH jail？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { print_warning "已取消。"; return 0; }
    backup_dir=$(create_transaction_backup remove) || { print_error "无法创建删除前备份。"; return 1; }
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && was_active=true
    rm -f -- "$FAIL2BAN_MANAGED_FILE" || status=1
    if ((status == 0)) && command -v fail2ban-client >/dev/null 2>&1; then
        validate_fail2ban_config || status=1
        if [[ "$was_active" == true ]]; then
            systemctl restart "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || status=1
            ((status != 0)) || wait_for_fail2ban_stable false || status=1
        fi
    fi
    if ((status != 0)); then
        print_error "移除后的配置或服务检查失败，正在回滚。"
        restore_transaction_backup "$backup_dir" || print_error "回滚失败，请使用备份: $backup_dir"
        return 1
    fi
    print_success "已仅移除本脚本的 SSH jail；其他 Fail2Ban 配置和软件包均已保留。"
    print_info "删除前备份: $backup_dir"
    read -r -p "按回车键返回主菜单..."
}

is_safe_full_config_dir() {
    [[ "$FAIL2BAN_CONFIG_DIR" == /etc/fail2ban || "$FAIL2BAN_CONFIG_DIR" == */etc/fail2ban ]]
}

create_full_uninstall_backup() {
    local backup_dir
    umask 077
    install -d -m 700 "$FAIL2BAN_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$FAIL2BAN_BACKUP_ROOT/full-uninstall.XXXXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1
    if [[ -d "$FAIL2BAN_CONFIG_DIR" && ! -L "$FAIL2BAN_CONFIG_DIR" ]]; then
        cp -a -- "$FAIL2BAN_CONFIG_DIR" "$backup_dir/fail2ban" || return 1
    else
        : > "$backup_dir/config.missing"
    fi
    dpkg-query -W -f='${Status} ${Version}\n' fail2ban > "$backup_dir/package-state.txt" 2>/dev/null || printf 'not-installed\n' > "$backup_dir/package-state.txt"
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && printf 'active\n' > "$backup_dir/service-state.txt" \
        || printf 'inactive\n' > "$backup_dir/service-state.txt"
    prune_backup_kind full-uninstall
    printf '%s\n' "$backup_dir"
}

full_uninstall_fail2ban() {
    local phrase backup_dir was_active=false was_enabled=false
    clear
    echo -e "${RED}==== 完整卸载 Fail2Ban（高级操作） ====${NC}"
    echo
    print_warning "此操作会卸载 Fail2Ban 并删除整个配置目录，包括用户创建的其他 jail。"
    print_warning "操作前会完整备份配置；不会执行 apt autoremove。"
    echo "如确实需要完整清理，请输入：PURGE-FAIL2BAN"
    read -r -p "> " phrase
    [[ "$phrase" == PURGE-FAIL2BAN ]] || { print_warning "确认短语不匹配，已取消。"; return 0; }
    is_safe_full_config_dir || { print_error "配置目录不安全，拒绝完整清理: $FAIL2BAN_CONFIG_DIR"; return 1; }
    [[ ! -L "$FAIL2BAN_CONFIG_DIR" ]] || { print_error "配置目录是符号链接，拒绝清理。"; return 1; }
    backup_dir=$(create_full_uninstall_backup) || { print_error "完整备份失败，已停止卸载。"; return 1; }
    print_info "完整配置备份: $backup_dir"
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && was_active=true
    systemctl is-enabled --quiet "$FAIL2BAN_SERVICE" 2>/dev/null && was_enabled=true
    systemctl stop "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "未找到 apt-get，配置目录未删除。"
        [[ "$was_enabled" == true ]] && systemctl enable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
        [[ "$was_active" == true ]] && systemctl start "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y fail2ban; then
        print_error "软件包卸载失败，配置目录未删除。"
        [[ "$was_enabled" == true ]] && systemctl enable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
        [[ "$was_active" == true ]] && systemctl start "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
        return 1
    fi
    if [[ -e "$FAIL2BAN_CONFIG_DIR" ]]; then
        rm -rf -- "$FAIL2BAN_CONFIG_DIR" || {
            print_error "软件包已卸载，但配置目录删除失败；备份位于: $backup_dir"
            return 1
        }
    fi
    print_success "Fail2Ban 已完整卸载；未运行 apt autoremove。"
    print_info "需要恢复配置时请使用: $backup_dir/fail2ban"
    read -r -p "按回车键返回主菜单..."
}

show_whitelist() {
    if is_owned_managed_file; then
        printf '当前 AI-Scripts SSH jail 白名单：%s\n' "$(read_managed_value ignoreip)"
    else
        print_warning "尚未安装本脚本的专属 SSH jail。"
    fi
}

add_whitelist_ips() {
    local input current combined normalized bantime findtime maxretry backup_dir stage_dir stage_file
    is_owned_managed_file || { print_error "请先安装本脚本的专属 SSH jail。"; return 1; }
    show_whitelist
    read -r -p "请输入要添加的 IP/CIDR（空格分隔）: " input
    [[ -n "$input" ]] || { print_error "输入不能为空。"; return 1; }
    current=$(read_managed_value ignoreip)
    combined="$current $input"
    normalized=$(normalize_ip_list "$combined") || { print_error "包含无效 IP 或 CIDR。"; return 1; }
    bantime=$(read_managed_value bantime)
    findtime=$(read_managed_value findtime)
    maxretry=$(read_managed_value maxretry)
    if ! validate_integer_range "$bantime" 1 315360000 \
        || ! validate_integer_range "$findtime" 1 31536000 \
        || ! validate_integer_range "$maxretry" 1 1000; then
        print_error "现有专属配置参数无效，拒绝自动修改。"
        return 1
    fi
    backup_dir=$(create_transaction_backup whitelist) || return 1
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-fail2ban.XXXXXXXX") || return 1
    stage_file="$stage_dir/ai-scripts-sshd.local"
    write_managed_config "$stage_file" "$bantime" "$findtime" "$maxretry" "$normalized"
    if apply_managed_config "$stage_file" "$backup_dir"; then
        print_success "白名单已安全更新。"
    else
        rm -rf -- "$stage_dir"
        return 1
    fi
    rm -rf -- "$stage_dir"
}

manage_bans() {
    local ban_choice input_ip normalized_ip
    while true; do
        clear
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo -e "${GREEN}     管理封禁列表${NC}"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        if ! wait_for_fail2ban_stable false; then
            print_error "Fail2Ban 服务未稳定运行。"
            read -r -p "按回车键返回主菜单..."
            return 1
        fi
        echo "  1. 查看所有 jail 状态"
        echo "  2. 查看 SSH 封禁列表"
        echo "  3. 解封指定 IP"
        echo "  4. 手动封禁 IP"
        echo "  5. 查看本脚本白名单"
        echo "  6. 添加本脚本白名单 IP/CIDR"
        echo "  7. 查看 Fail2Ban 日志"
        echo "  0. 返回主菜单"
        read -r -p "请选择操作 [0-7]: " ban_choice
        case "$ban_choice" in
            1) fail2ban-client status; read -r -p "按回车键继续..." ;;
            2) fail2ban-client status sshd; read -r -p "按回车键继续..." ;;
            3)
                read -r -p "请输入要解封的 IP 地址: " input_ip
                normalized_ip=$(validate_single_ip "$input_ip") || { print_error "IP 地址无效。"; continue; }
                if fail2ban-client set sshd unbanip "$normalized_ip"; then
                    print_success "IP $normalized_ip 已解封"
                else
                    print_error "解封失败。"
                fi
                ;;
            4)
                read -r -p "请输入要封禁的 IP 地址: " input_ip
                normalized_ip=$(validate_single_ip "$input_ip") || { print_error "IP 地址无效。"; continue; }
                if fail2ban-client set sshd banip "$normalized_ip"; then
                    print_success "IP $normalized_ip 已被封禁"
                else
                    print_error "封禁失败。"
                fi
                ;;
            5) show_whitelist; read -r -p "按回车键继续..." ;;
            6) add_whitelist_ips; read -r -p "按回车键继续..." ;;
            7) journalctl -u "$FAIL2BAN_SERVICE" -n 50 --no-pager; read -r -p "按回车键继续..." ;;
            0) return 0 ;;
            *) print_error "无效选择，请重新输入"; sleep 1 ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${GREEN}     Fail2Ban 管理脚本${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo "  1. 安装/配置 AI-Scripts SSH 防护"
    echo "  2. 移除 AI-Scripts SSH 防护（保留软件和其他 jail）"
    echo "  3. 完整卸载 Fail2Ban（高级操作）"
    echo "  4. 管理封禁列表"
    echo "  0. 退出"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
}

main() {
    local choice
    check_root || return 1
    check_system || return 1
    validate_runtime_settings || return 1
    while true; do
        show_menu
        read -r -p "请选择操作 [0-4]: " choice
        case "$choice" in
            1) install_fail2ban ;;
            2) remove_managed_config ;;
            3) full_uninstall_fail2ban ;;
            4) manage_bans ;;
            0) print_success "感谢使用 Fail2Ban 管理脚本！"; return 0 ;;
            *) print_error "无效选择，请重新输入"; sleep 1 ;;
        esac
    done
}

if [[ ${FAIL2BAN_SOURCE_ONLY:-0} != 1 ]]; then
    main "$@"
fi
