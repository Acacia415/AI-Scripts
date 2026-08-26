#!/bin/bash

# iptables 交互式流量转发脚本
# 适用于 Debian/Ubuntu 系统
# 功能：将本地端口流量转发到远程服务器

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

RULE_COMMENT_PREFIX="${IPTABLES_FORWARD_COMMENT_PREFIX:-AI-Scripts:iptables-forward}"
BACKUP_ROOT="${IPTABLES_FORWARD_BACKUP_ROOT:-/var/backups/ai-scripts/iptables-forward}"
BACKUP_KEEP="${IPTABLES_FORWARD_BACKUP_KEEP:-5}"

# 函数：打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

is_valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ && ( "$octet" == 0 || "$octet" != 0* ) ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

forward_rule_id() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4"
    printf '%s' "${protocol}|${local_port}|${remote_ip}|${remote_port}" | sha256sum | awk '{print substr($1, 1, 16)}'
}

forward_rule_comment() {
    local rule_id="$1" protocol="$2" local_port="$3" remote_ip="$4" remote_port="$5" role="$6"
    printf '%s:%s:%s:%s:%s:%s:%s\n' "$RULE_COMMENT_PREFIX" "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" "$role"
}

prune_transaction_backups() {
    local backups=() index
    [[ "$BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || BACKUP_KEEP=5
    mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type f -name 'transaction.*.rules' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=BACKUP_KEEP; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$BACKUP_ROOT"/transaction.*.rules ]] && rm -f -- "${backups[$index]}"
    done
}

create_runtime_backup() {
    local reason="$1" backup_path
    umask 077
    mkdir -p -- "$BACKUP_ROOT" || return 1
    chmod 700 -- "$BACKUP_ROOT" || return 1
    backup_path=$(mktemp "$BACKUP_ROOT/transaction.${reason}.XXXXXXXX.rules") || return 1
    if ! iptables-save > "$backup_path" || ! iptables-restore --test < "$backup_path"; then
        rm -f -- "$backup_path"
        return 1
    fi
    if ! chmod 600 -- "$backup_path"; then
        rm -f -- "$backup_path"
        return 1
    fi
    prune_transaction_backups
    printf '%s\n' "$backup_path"
}

persist_rules() {
    netfilter-persistent save >/dev/null 2>&1
}

restore_runtime_backup() {
    local backup_path="$1"
    iptables-restore --test < "$backup_path" || return 1
    iptables-restore --wait 5 < "$backup_path" || return 1
    persist_rules
}

# 函数：检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 函数：检查系统
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        print_error "此脚本仅支持Debian/Ubuntu系统"
        exit 1
    fi
}

# 函数：初始化环境
init_environment() {
    # 检查并安装依赖
    if ! command -v iptables &> /dev/null; then
        print_info "正在安装 iptables..."
        apt-get update -qq
        apt-get install -y iptables > /dev/null 2>&1
    fi
    
    # 检查并安装iptables-persistent
    if ! dpkg -l | grep -q iptables-persistent; then
        print_info "正在安装 iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent > /dev/null 2>&1
    fi
    
    # 检查并安装dnsutils（用于域名解析）
    if ! command -v nslookup &> /dev/null; then
        print_info "正在安装 dnsutils..."
        apt-get install -y dnsutils > /dev/null 2>&1
    fi
    
    # 启用IP转发
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) -ne 1 ]]; then
        print_info "启用IP转发..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # 永久启用
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        else
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf > /dev/null 2>&1
    fi
}

# 函数：获取本地IP
get_local_ip() {
    local ip_address
    ip_address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    if ! is_valid_ipv4 "$ip_address"; then
        ip_address=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    fi
    printf '%s\n' "$ip_address"
}

# 函数：解析域名
resolve_domain() {
    local domain=$1
    local ip=""
    
    # 检查是否是IP地址
    if is_valid_ipv4 "$domain"; then
        echo "$domain"
        return 0
    fi
    
    # 解析域名（日志输出到stderr，避免污染stdout的返回值）
    print_info "正在解析域名: $domain" >&2
    ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | tail -1 | awk '{print $2}')
    
    if ! is_valid_ipv4 "$ip"; then
        # 尝试使用host命令
        ip=$(host "$domain" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}')
    fi
    
    if ! is_valid_ipv4 "$ip"; then
        print_error "无法解析域名: $domain" >&2
        return 1
    fi
    
    print_info "域名解析成功: $domain -> $ip" >&2
    echo "$ip"
    return 0
}

# 函数：验证端口
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

forward_group_complete() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4" rule_id
    local dnat_comment masq_comment forward_comment return_comment
    rule_id=$(forward_rule_id "$protocol" "$local_port" "$remote_ip" "$remote_port") || return 1
    dnat_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" dnat)
    masq_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" masquerade)
    forward_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" forward)
    return_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" return)

    iptables -t nat -C PREROUTING -p "$protocol" --dport "$local_port" -m comment --comment "$dnat_comment" -j DNAT --to-destination "$remote_ip:$remote_port" 2>/dev/null &&
        iptables -t nat -C POSTROUTING -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m comment --comment "$masq_comment" -j MASQUERADE 2>/dev/null &&
        iptables -C FORWARD -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$forward_comment" -j ACCEPT 2>/dev/null &&
        iptables -C FORWARD -p "$protocol" -s "$remote_ip" --sport "$remote_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$return_comment" -j ACCEPT 2>/dev/null
}

remove_exact_forward_group() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4" rule_id
    local dnat_comment masq_comment forward_comment return_comment
    rule_id=$(forward_rule_id "$protocol" "$local_port" "$remote_ip" "$remote_port") || return 1
    dnat_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" dnat)
    masq_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" masquerade)
    forward_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" forward)
    return_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" return)

    while iptables -t nat -C PREROUTING -p "$protocol" --dport "$local_port" -m comment --comment "$dnat_comment" -j DNAT --to-destination "$remote_ip:$remote_port" 2>/dev/null; do
        iptables -t nat -D PREROUTING -p "$protocol" --dport "$local_port" -m comment --comment "$dnat_comment" -j DNAT --to-destination "$remote_ip:$remote_port" || return 1
    done
    while iptables -t nat -C POSTROUTING -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m comment --comment "$masq_comment" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m comment --comment "$masq_comment" -j MASQUERADE || return 1
    done
    while iptables -C FORWARD -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$forward_comment" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$forward_comment" -j ACCEPT || return 1
    done
    while iptables -C FORWARD -p "$protocol" -s "$remote_ip" --sport "$remote_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$return_comment" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -p "$protocol" -s "$remote_ip" --sport "$remote_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$return_comment" -j ACCEPT || return 1
    done
}

apply_forward_group() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4" rule_id
    local dnat_comment masq_comment forward_comment return_comment
    rule_id=$(forward_rule_id "$protocol" "$local_port" "$remote_ip" "$remote_port") || return 1
    dnat_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" dnat)
    masq_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" masquerade)
    forward_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" forward)
    return_comment=$(forward_rule_comment "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port" return)

    remove_exact_forward_group "$protocol" "$local_port" "$remote_ip" "$remote_port" || return 1
    iptables -t nat -A PREROUTING -p "$protocol" --dport "$local_port" -m comment --comment "$dnat_comment" -j DNAT --to-destination "$remote_ip:$remote_port" || return 1
    iptables -t nat -A POSTROUTING -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m comment --comment "$masq_comment" -j MASQUERADE || return 1
    iptables -A FORWARD -p "$protocol" -d "$remote_ip" --dport "$remote_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$forward_comment" -j ACCEPT || return 1
    iptables -A FORWARD -p "$protocol" -s "$remote_ip" --sport "$remote_port" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$return_comment" -j ACCEPT || return 1
}

# 函数：添加或修复完整转发规则组
add_forward_rule() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4" transaction_backup
    local current_protocol changed=false
    local -a protocols=()

    if ! validate_port "$local_port" || ! validate_port "$remote_port" || ! is_valid_ipv4 "$remote_ip"; then
        print_error "转发参数校验失败，未修改防火墙。"
        return 1
    fi
    case "$protocol" in
        tcp|udp) protocols=("$protocol") ;;
        both) protocols=(tcp udp) ;;
        *) print_error "不支持的协议: $protocol"; return 1 ;;
    esac

    for current_protocol in "${protocols[@]}"; do
        if forward_group_complete "$current_protocol" "$local_port" "$remote_ip" "$remote_port"; then
            print_warning "${current_protocol^^} 完整转发规则组已存在。"
        else
            changed=true
        fi
    done
    [[ "$changed" == true ]] || return 0

    transaction_backup=$(create_runtime_backup add) || {
        print_error "无法创建修改前规则备份，已停止。"
        return 1
    }
    print_info "修改前规则已备份到: $transaction_backup"

    for current_protocol in "${protocols[@]}"; do
        forward_group_complete "$current_protocol" "$local_port" "$remote_ip" "$remote_port" && continue
        if ! apply_forward_group "$current_protocol" "$local_port" "$remote_ip" "$remote_port"; then
            print_error "${current_protocol^^} 规则组创建失败，正在恢复修改前规则。"
            restore_runtime_backup "$transaction_backup" || print_error "严重错误：自动恢复失败，请使用备份 $transaction_backup 手动恢复。"
            return 1
        fi
        print_info "${current_protocol^^} 规则组已添加或修复: :${local_port} -> ${remote_ip}:${remote_port}"
    done

    if ! persist_rules; then
        print_error "规则持久化失败，正在恢复修改前规则。"
        restore_runtime_backup "$transaction_backup" || print_error "严重错误：自动恢复失败，请使用备份 $transaction_backup 手动恢复。"
        return 1
    fi
    print_info "完整规则组已保存并持久化。"
}

# 函数：执行转发设置
setup_forward() {
    local protocol=$1
    local protocol_name=$2
    
    echo ""
    echo -e "${CYAN}========== 设置${protocol_name}转发 ==========${NC}"
    echo ""
    
    # 输入本地端口
    local local_port=""
    while true; do
        read -r -p "请输入本机需要转发的端口 (1-65535): " local_port
        if validate_port "$local_port"; then
            break
        else
            print_error "无效的端口号，请输入1-65535之间的数字"
        fi
    done
    
    # 输入远程地址
    local remote_address=""
    local remote_ip=""
    while true; do
        echo ""
        read -r -p "请输入需要转发到的目标地址 (支持IP或域名): " remote_address
        
        # 解析地址
        if remote_ip=$(resolve_domain "$remote_address") && [[ -n "$remote_ip" ]]; then
            break
        else
            print_error "无效的地址或域名无法解析，请重新输入"
        fi
    done
    
    # 输入远程端口
    local remote_port=""
    while true; do
        echo ""
        read -r -p "请输入目标服务器的端口 (1-65535): " remote_port
        if validate_port "$remote_port"; then
            break
        else
            print_error "无效的端口号，请输入1-65535之间的数字"
        fi
    done
    
    # 确认信息
    echo ""
    echo -e "${YELLOW}========== 确认转发信息 ==========${NC}"
    echo -e "转发协议: ${GREEN}${protocol_name}${NC}"
    echo -e "本地端口: ${GREEN}${local_port}${NC}"
    echo -e "目标地址: ${GREEN}${remote_address}${NC}"
    if [[ "$remote_address" != "$remote_ip" ]]; then
        echo -e "解析后IP: ${GREEN}${remote_ip}${NC}"
    fi
    echo -e "目标端口: ${GREEN}${remote_port}${NC}"
    echo ""
    
    read -r -p "确认添加此转发规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        echo ""
        if add_forward_rule "$protocol" "$local_port" "$remote_ip" "$remote_port"; then
            print_info "转发规则添加或修复成功！"
        else
            print_error "转发规则添加失败，当前规则已尽可能恢复到操作前状态。"
        fi
    else
        print_warning "已取消添加规则"
    fi
    
    echo ""
    read -r -p "按回车键返回主菜单..."
}

parse_managed_rule_record() {
    local line="${1//\"/}" comment="" payload rule_id protocol local_port remote_ip remote_port role extra expected_id
    local index
    local -a fields
    read -r -a fields <<< "$line"
    for ((index=0; index<${#fields[@]}; index++)); do
        [[ "${fields[$index]}" == --comment ]] && comment="${fields[$((index+1))]:-}"
    done
    [[ "$comment" == "$RULE_COMMENT_PREFIX":* ]] || return 1
    payload="${comment#"$RULE_COMMENT_PREFIX":}"
    IFS=':' read -r rule_id protocol local_port remote_ip remote_port role extra <<< "$payload"
    [[ -z "$extra" && "$rule_id" =~ ^[0-9a-f]{16}$ && "$protocol" =~ ^(tcp|udp)$ ]] || return 1
    [[ "$role" =~ ^(dnat|masquerade|forward|return)$ ]] || return 1
    validate_port "$local_port" && validate_port "$remote_port" && is_valid_ipv4 "$remote_ip" || return 1
    expected_id=$(forward_rule_id "$protocol" "$local_port" "$remote_ip" "$remote_port") || return 1
    [[ "$rule_id" == "$expected_id" ]] || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$rule_id" "$protocol" "$local_port" "$remote_ip" "$remote_port"
}

list_managed_forward_records() {
    local line record rule_id
    local -A seen=()
    while IFS= read -r line; do
        [[ "$line" == *"$RULE_COMMENT_PREFIX"* ]] || continue
        record=$(parse_managed_rule_record "$line") || continue
        rule_id="${record%%$'\t'*}"
        [[ -v 'seen[$rule_id]' ]] && continue
        seen["$rule_id"]=1
        printf '%s\n' "$record"
    done < <({
        iptables -t nat -S PREROUTING
        iptables -t nat -S POSTROUTING
        iptables -S FORWARD
    } 2>/dev/null)
}

print_forward_record_table() {
    local index=1 record rule_id protocol local_port remote_ip remote_port status
    local -a records=("$@")
    printf "%-5s %-8s %-12s %-24s %-10s\n" "编号" "协议" "本地端口" "目标地址" "状态"
    echo "-----------------------------------------------------------------------"
    for record in "${records[@]}"; do
        IFS=$'\t' read -r rule_id protocol local_port remote_ip remote_port <<< "$record"
        if forward_group_complete "$protocol" "$local_port" "$remote_ip" "$remote_port"; then
            status="完整"
        else
            status="需修复"
        fi
        printf "%-5s %-8s %-12s %-24s %-10s\n" "$index" "$protocol" "$local_port" "$remote_ip:$remote_port" "$status"
        ((index++))
    done
}

# 函数：显示当前由本脚本管理的完整规则组
show_current_rules() {
    local -a rule_records=()
    mapfile -t rule_records < <(list_managed_forward_records)
    clear
    echo -e "${CYAN}========== 当前转发规则组 ==========${NC}"
    echo ""
    if ((${#rule_records[@]} == 0)); then
        print_warning "没有找到带本脚本所有权标识的转发规则。"
    else
        print_forward_record_table "${rule_records[@]}"
    fi
    echo ""
    print_info "未带 $RULE_COMMENT_PREFIX 标识的其他 iptables 规则不会显示或修改。"
    echo ""
    read -r -p "按回车键返回主菜单..."
}

delete_forward_rule() {
    local protocol="$1" local_port="$2" remote_ip="$3" remote_port="$4" transaction_backup
    transaction_backup=$(create_runtime_backup delete) || {
        print_error "无法创建删除前规则备份，已停止。"
        return 1
    }
    if ! remove_exact_forward_group "$protocol" "$local_port" "$remote_ip" "$remote_port" || ! persist_rules; then
        print_error "规则组删除或持久化失败，正在恢复删除前规则。"
        restore_runtime_backup "$transaction_backup" || print_error "严重错误：自动恢复失败，请使用备份 $transaction_backup 手动恢复。"
        return 1
    fi
    print_info "已完整删除 ${protocol^^} :${local_port} -> ${remote_ip}:${remote_port} 的 DNAT、MASQUERADE 和双向 FORWARD 规则。"
}

# 函数：按逻辑规则组成组删除
delete_rules() {
    local rule_input confirm selected_number record rule_id protocol local_port remote_ip remote_port
    local success_count=0 fail_count=0
    local -a rule_records=() selected_rules=()
    local -A selected_seen=()
    mapfile -t rule_records < <(list_managed_forward_records)

    clear
    echo -e "${CYAN}========== 删除转发规则组 ==========${NC}"
    echo ""
    if ((${#rule_records[@]} == 0)); then
        print_warning "没有找到可由本脚本安全删除的转发规则组。"
        echo ""
        read -r -p "按回车键返回主菜单..."
        return 0
    fi
    print_forward_record_table "${rule_records[@]}"
    echo ""
    echo "提示: 可输入单个编号或多个编号（英文逗号分隔，如 1,3），输入 0 返回。"
    read -r -p "请输入要删除的规则组编号: " rule_input
    [[ "$rule_input" != 0 ]] || return 0

    IFS=',' read -r -a selected_rules <<< "$rule_input"
    for selected_number in "${selected_rules[@]}"; do
        selected_number="${selected_number//[[:space:]]/}"
        if [[ ! "$selected_number" =~ ^[0-9]+$ ]] || ((selected_number < 1 || selected_number > ${#rule_records[@]})); then
            print_error "无效的规则组编号: $selected_number"
            continue
        fi
        selected_seen["$selected_number"]=1
    done
    ((${#selected_seen[@]} > 0)) || return 1

    echo ""
    echo -e "${YELLOW}将完整删除以下规则组:${NC}"
    for selected_number in "${!selected_seen[@]}"; do
        record="${rule_records[$((selected_number-1))]}"
        IFS=$'\t' read -r rule_id protocol local_port remote_ip remote_port <<< "$record"
        printf '  %s. %s :%s -> %s:%s\n' "$selected_number" "$protocol" "$local_port" "$remote_ip" "$remote_port"
    done
    read -r -p "确认删除吗？(y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { print_warning "已取消删除"; return 0; }

    for selected_number in "${!selected_seen[@]}"; do
        record="${rule_records[$((selected_number-1))]}"
        IFS=$'\t' read -r rule_id protocol local_port remote_ip remote_port <<< "$record"
        if delete_forward_rule "$protocol" "$local_port" "$remote_ip" "$remote_port"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    print_info "成功删除 $success_count 个完整规则组。"
    ((fail_count == 0)) || print_warning "删除失败 $fail_count 个规则组；失败项已自动恢复。"
    echo ""
    read -r -p "按回车键返回主菜单..."
}

backup_rules_to_file() {
    local backup_path="$1" backup_dir temp_path
    backup_dir=$(dirname -- "$backup_path")
    [[ -d "$backup_dir" && -w "$backup_dir" ]] || {
        print_error "备份目录不存在或不可写: $backup_dir"
        return 1
    }
    umask 077
    temp_path=$(mktemp "$backup_dir/.iptables-backup.XXXXXXXX.rules") || return 1
    if ! iptables-save > "$temp_path" || ! iptables-restore --test < "$temp_path"; then
        rm -f -- "$temp_path"
        print_error "当前规则导出或格式自检失败，未覆盖目标文件。"
        return 1
    fi
    chmod 600 -- "$temp_path" || { rm -f -- "$temp_path"; return 1; }
    mv -f -- "$temp_path" "$backup_path" || { rm -f -- "$temp_path"; return 1; }
    print_info "规则备份成功: $backup_path"
}

# 函数：备份规则
backup_rules() {
    local default_path backup_path="" confirm
    default_path="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
    clear
    echo -e "${CYAN}========== 备份iptables规则 ==========${NC}"
    echo ""
    read -r -p "请输入备份文件路径 [默认: ${default_path}]: " backup_path
    [[ -n "$backup_path" ]] || backup_path="$default_path"
    if [[ -e "$backup_path" || -L "$backup_path" ]]; then
        print_warning "文件已存在: $backup_path"
        read -r -p "是否原子替换该文件？(y/N): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { print_info "已取消备份"; return 0; }
    fi
    backup_rules_to_file "$backup_path" || true
    echo ""
    read -r -p "按回车键返回主菜单..."
}

restore_rules_from_file() {
    local backup_path="$1" pre_restore_backup
    [[ -f "$backup_path" && -r "$backup_path" ]] || {
        print_error "备份文件不存在或不可读: $backup_path"
        return 1
    }
    if ! iptables-restore --test < "$backup_path"; then
        print_error "待恢复文件未通过 iptables-restore --test，当前规则未修改。"
        return 1
    fi
    pre_restore_backup=$(create_runtime_backup pre-restore) || {
        print_error "无法创建恢复前规则备份，已停止恢复。"
        return 1
    }
    print_info "恢复前现场已备份到: $pre_restore_backup"

    if iptables-restore --wait 5 < "$backup_path" && persist_rules; then
        print_info "规则已通过预检、完整恢复并持久化。"
        return 0
    fi

    print_error "规则应用或持久化失败，正在恢复操作前现场。"
    if restore_runtime_backup "$pre_restore_backup"; then
        print_warning "已恢复操作前规则；现场备份保留在: $pre_restore_backup"
    else
        print_error "严重错误：现场自动恢复失败，请立即使用 $pre_restore_backup 手动恢复。"
    fi
    return 1
}

# 函数：安全恢复全量规则
restore_rules() {
    local backup_path="" confirm
    clear
    echo -e "${CYAN}========== 恢复iptables规则 ==========${NC}"
    echo ""
    read -r -p "请输入要恢复的备份文件路径: " backup_path
    if [[ ! -f "$backup_path" ]]; then
        print_error "备份文件不存在: $backup_path"
        echo ""
        read -r -p "按回车键返回主菜单..."
        return 1
    fi
    if ! iptables-restore --test < "$backup_path"; then
        print_error "备份文件格式预检失败，未修改当前规则。"
        echo ""
        read -r -p "按回车键返回主菜单..."
        return 1
    fi
    echo ""
    print_warning "警告：恢复操作将替换全部现有 IPv4 iptables 规则；应用前会自动备份当前现场。"
    read -r -p "确认从 $backup_path 恢复规则吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        restore_rules_from_file "$backup_path" || true
    else
        print_warning "已取消恢复操作"
    fi
    echo ""
    read -r -p "按回车键返回主菜单..."
}

# 函数：显示主菜单
show_menu() {
    local forwarding_status="未启用"
    [[ $(< /proc/sys/net/ipv4/ip_forward) == 1 ]] && forwarding_status="已启用"
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${CYAN}          IPTables 流量转发管理工具${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo -e "${GREEN}请选择操作:${NC}"
    echo ""
    echo "  1. 转发 TCP+UDP"
    echo "  2. 转发 TCP"
    echo "  3. 转发 UDP"
    echo "  4. 查看当前规则"
    echo "  5. 删除转发规则"
    echo "  6. 备份转发规则"
    echo "  7. 恢复转发规则"
    echo "  0. 退出脚本"
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "本机IP: ${GREEN}$(get_local_ip)${NC}"
    echo -e "IP转发: ${GREEN}${forwarding_status}${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# 主函数
main() {
    # 检查权限和系统
    check_root
    check_system
    
    # 初始化环境
    print_info "正在初始化环境..."
    init_environment
    
    # 主循环
    while true; do
        show_menu
        
        read -r -p "请输入选项 (0-7): " choice
        
        case $choice in
            1)
                setup_forward "both" "TCP+UDP"
                ;;
            2)
                setup_forward "tcp" "TCP"
                ;;
            3)
                setup_forward "udp" "UDP"
                ;;
            4)
                show_current_rules
                ;;
            5)
                delete_rules
                ;;
            6)
                backup_rules
                ;;
            7)
                restore_rules
                ;;
            0)
                echo ""
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_error "无效的选项，请重新选择"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
if [[ ${IPTABLES_FORWARD_SOURCE_ONLY:-0} != 1 ]]; then
    main
fi
