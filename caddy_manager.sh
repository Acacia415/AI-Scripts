#!/bin/bash

# Caddy 反向代理管理工具
# 主 Caddyfile 仅增加一条受管 import；每个域名使用独立配置文件。

set -o pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

CADDY_CONFIG_DIR="${CADDY_CONFIG_DIR:-/etc/caddy}"
CADDYFILE="${CADDYFILE:-${CADDY_CONFIG_DIR}/Caddyfile}"
CADDY_MANAGED_DIR="${CADDY_MANAGED_DIR:-${CADDY_CONFIG_DIR}/ai-scripts.d}"
CADDY_SERVICE="${CADDY_SERVICE:-caddy.service}"
CADDY_BACKUP_ROOT="${CADDY_BACKUP_ROOT:-/var/backups/ai-scripts/caddy}"
CADDY_BACKUP_KEEP="${CADDY_BACKUP_KEEP:-5}"
CADDY_APT_KEY="${CADDY_APT_KEY:-/usr/share/keyrings/caddy-stable-archive-keyring.gpg}"
CADDY_APT_SOURCE="${CADDY_APT_SOURCE:-/etc/apt/sources.list.d/caddy-stable.list}"
CADDY_SERVICE_FILE="${CADDY_SERVICE_FILE:-/lib/systemd/system/caddy.service}"
CADDY_DATA_DIR="${CADDY_DATA_DIR:-/var/lib/caddy}"
CADDY_TLS_DIR="${CADDY_TLS_DIR:-/etc/ssl/caddy}"
CADDY_LOG_DIR="${CADDY_LOG_DIR:-/var/log/caddy}"
CADDY_IMPORT_MARKER='# Managed by AI-Scripts caddy_manager.sh'
CADDY_IMPORT_DIRECTIVE='import ai-scripts.d/*.caddy'
CADDY_SITE_MARKER='# Managed by AI-Scripts caddy_manager.sh site'

print_info() { echo -e "${CYAN}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限执行。"
        return 1
    fi
}

validate_runtime_settings() {
    [[ "$CADDY_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        print_error "备份保留数量无效: $CADDY_BACKUP_KEEP"
        return 1
    }
    [[ "$(dirname -- "$CADDYFILE")" == "$CADDY_CONFIG_DIR" ]] || {
        print_error "Caddyfile 必须位于 CADDY_CONFIG_DIR 中。"
        return 1
    }
    [[ "$(dirname -- "$CADDY_MANAGED_DIR")" == "$CADDY_CONFIG_DIR" \
        && "$(basename -- "$CADDY_MANAGED_DIR")" == ai-scripts.d ]] || {
        print_error "受管配置目录必须是 CADDY_CONFIG_DIR/ai-scripts.d。"
        return 1
    }
}

normalize_domain() {
    local domain="$1"
    domain=${domain#http://}
    domain=${domain#https://}
    tr '[:upper:]' '[:lower:]' <<< "$domain"
}

is_valid_domain() {
    local domain="$1" label
    local -a labels=()
    ((${#domain} >= 3 && ${#domain} <= 253)) || return 1
    [[ "$domain" != *..* && "$domain" != .* && "$domain" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

is_valid_ipv4() {
    local ip="$1" octet
    local -a octets=()
    [[ "$ip" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ && ( "$octet" == 0 || "$octet" != 0* ) ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

is_valid_ipv6_literal() {
    local ip="$1" left right group
    local group_count=0 compressed=false
    local -a groups=()
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *::* ]]; then
        compressed=true
        left=${ip%%::*}
        right=${ip#*::}
        [[ "$right" != *::* ]] || return 1
        [[ -z "$left" ]] || {
            IFS=':' read -r -a groups <<< "$left"
            for group in "${groups[@]}"; do
                [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                group_count=$((group_count + 1))
            done
        }
        [[ -z "$right" ]] || {
            IFS=':' read -r -a groups <<< "$right"
            for group in "${groups[@]}"; do
                [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                group_count=$((group_count + 1))
            done
        }
    else
        IFS=':' read -r -a groups <<< "$ip"
        for group in "${groups[@]}"; do
            [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            group_count=$((group_count + 1))
        done
    fi
    if [[ "$compressed" == true ]]; then
        ((group_count < 8))
    else
        ((group_count == 8))
    fi
}

is_valid_hostname() {
    local hostname="$1" label
    local -a labels=()
    ((${#hostname} >= 1 && ${#hostname} <= 253)) || return 1
    [[ "$hostname" != *..* && "$hostname" != .* && "$hostname" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

is_valid_upstream_host() {
    if [[ "$1" =~ ^[0-9.]+$ ]]; then
        is_valid_ipv4 "$1"
    elif [[ "$1" == *:* ]]; then
        is_valid_ipv6_literal "$1"
    else
        is_valid_hostname "$1"
    fi
}

is_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] && ((${#1} <= 5)) && ((10#$1 <= 65535))
}

format_upstream() {
    local host="$1" port="$2"
    if is_valid_ipv6_literal "$host"; then
        printf '[%s]:%s\n' "$host" "$port"
    else
        printf '%s:%s\n' "$host" "$port"
    fi
}

site_file_for_domain() { printf '%s/%s.caddy\n' "$CADDY_MANAGED_DIR" "$1"; }

is_managed_site_file() {
    [[ -f "$1" && ! -L "$1" ]] && grep -Fxq "$CADDY_SITE_MARKER" "$1"
}

atomic_install_file() {
    local source_file="$1" target_file="$2" mode="$3" target_dir temp_file
    target_dir=$(dirname -- "$target_file")
    install -d -m 755 "$target_dir" || return 1
    temp_file=$(mktemp "$target_dir/.ai-scripts-caddy.XXXXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

snapshot_optional_file() {
    local source_file="$1" backup_file="$2" missing_file="$3"
    if [[ -e "$source_file" || -L "$source_file" ]]; then
        [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
        cp -a -- "$source_file" "$backup_file"
    else
        : > "$missing_file"
    fi
}

restore_optional_file() {
    local target_file="$1" backup_file="$2" missing_file="$3" fallback_mode="$4" mode
    if [[ -f "$missing_file" ]]; then
        rm -f -- "$target_file"
    elif [[ -f "$backup_file" ]]; then
        mode=$(stat -c '%a' "$backup_file" 2>/dev/null) || mode="$fallback_mode"
        atomic_install_file "$backup_file" "$target_file" "$mode"
    else
        return 1
    fi
}

prune_backups() {
    local pattern="$1" index
    local -a backups=()
    mapfile -t backups < <(find "$CADDY_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=CADDY_BACKUP_KEEP; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$CADDY_BACKUP_ROOT/"* ]] || continue
        rm -rf -- "${backups[$index]}"
    done
}

record_service_state() {
    local output_dir="$1" active=false enabled=false
    systemctl is-active --quiet "$CADDY_SERVICE" 2>/dev/null && active=true
    systemctl is-enabled --quiet "$CADDY_SERVICE" 2>/dev/null && enabled=true
    printf '%s\n' "$active" > "$output_dir/service.active"
    printf '%s\n' "$enabled" > "$output_dir/service.enabled"
}

restore_service_state() {
    local backup_dir="$1" was_active was_enabled status=0
    was_active=$(< "$backup_dir/service.active")
    was_enabled=$(< "$backup_dir/service.enabled")
    if [[ "$was_enabled" == true ]]; then
        systemctl enable "$CADDY_SERVICE" >/dev/null 2>&1 || status=1
    else
        systemctl disable "$CADDY_SERVICE" >/dev/null 2>&1 || status=1
    fi
    if [[ "$was_active" == true ]]; then
        systemctl reload "$CADDY_SERVICE" >/dev/null 2>&1 || status=1
    else
        systemctl stop "$CADDY_SERVICE" >/dev/null 2>&1 || status=1
    fi
    return "$status"
}

create_site_transaction() {
    local domain="$1" reason="$2" site_file backup_dir
    site_file=$(site_file_for_domain "$domain")
    umask 077
    install -d -m 700 "$CADDY_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$CADDY_BACKUP_ROOT/transaction.${reason}.${domain}.XXXXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1
    snapshot_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" || return 1
    snapshot_optional_file "$site_file" "$backup_dir/site.caddy" "$backup_dir/site.missing" || return 1
    record_service_state "$backup_dir"
    prune_backups 'transaction.*'
    printf '%s\n' "$backup_dir"
}

restore_site_transaction() {
    local domain="$1" backup_dir="$2" site_file status=0
    site_file=$(site_file_for_domain "$domain")
    restore_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" 644 || status=1
    restore_optional_file "$site_file" "$backup_dir/site.caddy" "$backup_dir/site.missing" 644 || status=1
    if command -v caddy >/dev/null 2>&1 && [[ -f "$CADDYFILE" ]]; then
        caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || status=1
    fi
    restore_service_state "$backup_dir" || status=1
    return "$status"
}

owned_import_is_valid() {
    [[ -f "$1" ]] || return 1
    awk -v marker="$CADDY_IMPORT_MARKER" -v directive="$CADDY_IMPORT_DIRECTIVE" '
        previous == marker && $0 == directive { found=1 }
        { previous=$0 }
        END { exit !found }
    ' "$1"
}

ensure_import_in_file() {
    local file="$1"
    if grep -Fxq "$CADDY_IMPORT_MARKER" "$file"; then
        owned_import_is_valid "$file" || {
            print_error "主 Caddyfile 中的受管 import 标记不完整，拒绝自动修改。"
            return 1
        }
        return 0
    fi
    grep -Fxq "$CADDY_IMPORT_DIRECTIVE" "$file" && return 0
    [[ ! -s "$file" ]] || printf '\n' >> "$file"
    printf '%s\n%s\n' "$CADDY_IMPORT_MARKER" "$CADDY_IMPORT_DIRECTIVE" >> "$file"
}

remove_owned_import_from_file() {
    local input_file="$1" output_file="$2"
    awk -v marker="$CADDY_IMPORT_MARKER" -v directive="$CADDY_IMPORT_DIRECTIVE" '
        pending {
            if ($0 == directive) { pending=0; next }
            print marker
            pending=0
        }
        $0 == marker { pending=1; next }
        { print }
        END { if (pending) print marker }
    ' "$input_file" > "$output_file"
}

copy_live_config_to_stage() {
    local stage_root="$1" file
    install -d -m 755 "$stage_root/ai-scripts.d" || return 1
    if [[ -e "$CADDYFILE" || -L "$CADDYFILE" ]]; then
        [[ -f "$CADDYFILE" && ! -L "$CADDYFILE" ]] || {
            print_error "主 Caddyfile 不是普通文件，拒绝替换。"
            return 1
        }
        cp -- "$CADDYFILE" "$stage_root/Caddyfile" || return 1
    else
        printf '# Caddy configuration\n' > "$stage_root/Caddyfile"
    fi
    if [[ -d "$CADDY_MANAGED_DIR" ]]; then
        shopt -s nullglob
        for file in "$CADDY_MANAGED_DIR"/*.caddy; do
            [[ -f "$file" && ! -L "$file" ]] || {
                shopt -u nullglob
                print_error "受管目录包含符号链接或非普通配置: $file"
                return 1
            }
            cp -- "$file" "$stage_root/ai-scripts.d/" || {
                shopt -u nullglob
                return 1
            }
        done
        shopt -u nullglob
    fi
}

render_site_config() {
    local output_file="$1" domain="$2" host="$3" port="$4" upstream
    upstream=$(format_upstream "$host" "$port") || return 1
    cat > "$output_file" <<EOF
$CADDY_SITE_MARKER
$domain {
    reverse_proxy $upstream {
        header_up X-Real-IP {remote_host}
    }
    encode gzip
}
EOF
    chmod 644 "$output_file"
}

validate_staged_config() {
    local stage_root="$1"
    caddy validate --config "$stage_root/Caddyfile" --adapter caddyfile
}

activate_caddy_config() {
    local backup_dir="$1" was_active
    was_active=$(< "$backup_dir/service.active")
    if [[ "$was_active" == true ]]; then
        systemctl reload "$CADDY_SERVICE" >/dev/null 2>&1 || return 1
    else
        systemctl enable "$CADDY_SERVICE" >/dev/null 2>&1 || return 1
        systemctl start "$CADDY_SERVICE" >/dev/null 2>&1 || return 1
    fi
    systemctl is-active --quiet "$CADDY_SERVICE"
}

apply_staged_site() {
    local domain="$1" stage_root="$2" backup_dir="$3" site_file staged_site main_mode=644 site_mode=644
    site_file=$(site_file_for_domain "$domain")
    staged_site="$stage_root/ai-scripts.d/$domain.caddy"
    [[ ! -f "$CADDYFILE" ]] || main_mode=$(stat -c '%a' "$CADDYFILE" 2>/dev/null) || return 1
    [[ ! -f "$site_file" ]] || site_mode=$(stat -c '%a' "$site_file" 2>/dev/null) || return 1
    if ! atomic_install_file "$staged_site" "$site_file" "$site_mode" \
        || ! atomic_install_file "$stage_root/Caddyfile" "$CADDYFILE" "$main_mode" \
        || ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
        || ! activate_caddy_config "$backup_dir"; then
        print_error "新配置验证或加载失败，正在恢复修改前状态。"
        restore_site_transaction "$domain" "$backup_dir" \
            || print_error "自动恢复未完全成功，请使用备份: $backup_dir"
        return 1
    fi
}

configure_site_transaction() {
    local domain="$1" host="$2" port="$3" allow_overwrite="${4:-false}"
    local site_file backup_dir stage_root staged_site
    is_valid_domain "$domain" || { print_error "域名格式无效。"; return 1; }
    is_valid_upstream_host "$host" || { print_error "目标服务器地址格式无效。"; return 1; }
    is_valid_port "$port" || { print_error "端口必须是 1-65535。"; return 1; }
    site_file=$(site_file_for_domain "$domain")
    if [[ -e "$site_file" || -L "$site_file" ]]; then
        is_managed_site_file "$site_file" || {
            print_error "同名配置不属于本脚本，拒绝覆盖: $site_file"
            return 1
        }
        [[ "$allow_overwrite" == true ]] || {
            print_warning "域名 $domain 已存在受管配置。"
            return 2
        }
    fi
    backup_dir=$(create_site_transaction "$domain" configure) || {
        print_error "无法创建配置变更前备份。"
        return 1
    }
    stage_root=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-caddy-stage.XXXXXXXX") || return 1
    if ! copy_live_config_to_stage "$stage_root"; then
        rm -rf -- "$stage_root"
        return 1
    fi
    staged_site="$stage_root/ai-scripts.d/$domain.caddy"
    if ! render_site_config "$staged_site" "$domain" "$host" "$port" \
        || ! caddy fmt --overwrite "$staged_site" >/dev/null 2>&1 \
        || ! ensure_import_in_file "$stage_root/Caddyfile" \
        || ! validate_staged_config "$stage_root"; then
        print_error "候选 Caddy 配置验证失败，现有配置未修改。"
        rm -rf -- "$stage_root"
        return 1
    fi
    if ! apply_staged_site "$domain" "$stage_root" "$backup_dir"; then
        rm -rf -- "$stage_root"
        return 1
    fi
    rm -rf -- "$stage_root"
    print_success "反向代理配置已生效：https://$domain"
    print_info "修改前备份: $backup_dir"
}

create_install_backup() {
    local backup_dir
    umask 077
    install -d -m 700 "$CADDY_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$CADDY_BACKUP_ROOT/install.XXXXXXXX") || return 1
    snapshot_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" || return 1
    snapshot_optional_file "$CADDY_APT_KEY" "$backup_dir/apt.key" "$backup_dir/apt.key.missing" || return 1
    snapshot_optional_file "$CADDY_APT_SOURCE" "$backup_dir/apt.source" "$backup_dir/apt.source.missing" || return 1
    prune_backups 'install.*'
    printf '%s\n' "$backup_dir"
}

restore_install_backup() {
    local backup_dir="$1" status=0
    restore_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" 644 || status=1
    restore_optional_file "$CADDY_APT_KEY" "$backup_dir/apt.key" "$backup_dir/apt.key.missing" 644 || status=1
    restore_optional_file "$CADDY_APT_SOURCE" "$backup_dir/apt.source" "$backup_dir/apt.source.missing" 644 || status=1
    return "$status"
}

install_caddy_if_needed() {
    local backup_dir stage_dir key_source key_binary apt_source_file
    command -v caddy >/dev/null 2>&1 && {
        print_info "检测到 Caddy 已安装，版本：$(caddy version)"
        return 0
    }
    command -v apt-get >/dev/null 2>&1 || {
        print_error "当前系统没有 apt-get，请手动安装 Caddy 后重试。"
        return 1
    }
    print_info "正在从 Caddy 官方软件源安装最新稳定版。"
    backup_dir=$(create_install_backup) || return 1
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-caddy-install.XXXXXXXX") || return 1
    key_source="$stage_dir/caddy.key"
    key_binary="$stage_dir/caddy.gpg"
    apt_source_file="$stage_dir/caddy.list"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg \
        || ! curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$key_source" \
        || ! gpg --batch --yes --dearmor --output "$key_binary" "$key_source" \
        || ! curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$apt_source_file" \
        || [[ ! -s "$key_binary" ]] || ! grep -Eq '^deb([[:space:]]|$)' "$apt_source_file" \
        || ! atomic_install_file "$key_binary" "$CADDY_APT_KEY" 644 \
        || ! atomic_install_file "$apt_source_file" "$CADDY_APT_SOURCE" 644 \
        || ! apt-get update \
        || ! DEBIAN_FRONTEND=noninteractive apt-get install -y caddy \
        || ! command -v caddy >/dev/null 2>&1; then
        print_error "Caddy 安装失败，正在恢复软件源文件。"
        restore_install_backup "$backup_dir" || print_error "软件源恢复失败，请使用备份: $backup_dir"
        rm -rf -- "$stage_dir"
        return 1
    fi
    rm -rf -- "$stage_dir"
    print_success "Caddy 安装完成，版本：$(caddy version)"
    print_info "安装前软件源备份: $backup_dir"
}

configure_caddy_reverse_proxy() {
    local domain_input domain host port overwrite more site_file result
    check_root || return 1
    validate_runtime_settings || return 1
    install_caddy_if_needed || return 1
    while true; do
        while true; do
            read -r -p "请输入域名（无需 https://）：" domain_input
            domain=$(normalize_domain "$domain_input")
            is_valid_domain "$domain" && break
            print_error "域名格式无效，示例：example.com"
        done
        while true; do
            read -r -p "请输入目标服务器地址（默认为 localhost）：" host
            host=${host:-localhost}
            is_valid_upstream_host "$host" && break
            print_error "目标地址必须是安全的主机名、IPv4 或 IPv6 地址。"
        done
        while true; do
            read -r -p "请输入目标端口号（1-65535）：" port
            is_valid_port "$port" && break
            print_error "端口必须是 1-65535。"
        done
        site_file=$(site_file_for_domain "$domain")
        overwrite=false
        if [[ -e "$site_file" || -L "$site_file" ]]; then
            if ! is_managed_site_file "$site_file"; then
                print_error "同名配置不属于本脚本，拒绝覆盖: $site_file"
                return 1
            fi
            print_warning "检测到现有受管配置："
            sed -n '1,20p' "$site_file"
            read -r -p "要覆盖此配置吗？[y/N] " overwrite
            [[ "$overwrite" =~ ^[Yy]$ ]] || {
                read -r -p "是否改为添加其他域名？[y/N] " more
                [[ "$more" =~ ^[Yy]$ ]] && continue
                return 0
            }
            overwrite=true
        fi
        result=0
        configure_site_transaction "$domain" "$host" "$port" "$overwrite" || result=$?
        ((result == 0)) || return "$result"
        read -r -p "是否继续添加配置？[y/N] " more
        [[ "$more" =~ ^[Yy]$ ]] || return 0
    done
}

create_managed_cleanup_backup() {
    local backup_dir
    umask 077
    install -d -m 700 "$CADDY_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$CADDY_BACKUP_ROOT/managed-cleanup.XXXXXXXX") || return 1
    snapshot_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" || return 1
    if [[ -d "$CADDY_MANAGED_DIR" ]]; then
        cp -a -- "$CADDY_MANAGED_DIR" "$backup_dir/ai-scripts.d" || return 1
    else
        : > "$backup_dir/managed-dir.missing"
    fi
    record_service_state "$backup_dir"
    prune_backups 'managed-cleanup.*'
    printf '%s\n' "$backup_dir"
}

restore_managed_cleanup() {
    local backup_dir="$1" status=0
    restore_optional_file "$CADDYFILE" "$backup_dir/Caddyfile" "$backup_dir/Caddyfile.missing" 644 || status=1
    if [[ -f "$backup_dir/managed-dir.missing" ]]; then
        rm -rf -- "$CADDY_MANAGED_DIR"
    elif [[ -d "$backup_dir/ai-scripts.d" ]]; then
        rm -rf -- "$CADDY_MANAGED_DIR"
        cp -a -- "$backup_dir/ai-scripts.d" "$CADDY_MANAGED_DIR" || status=1
    else
        status=1
    fi
    if command -v caddy >/dev/null 2>&1 && [[ -f "$CADDYFILE" ]]; then
        caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || status=1
    fi
    restore_service_state "$backup_dir" || status=1
    return "$status"
}

remove_managed_caddy_assets() {
    local confirm backup_dir stage_root file remaining_configs=0 removed=0 cleaned_main main_mode=644 removal_failed=0
    check_root || return 1
    validate_runtime_settings || return 1
    print_warning "此操作只移除 AI-Scripts 标记的 Caddy 站点和自有 import。"
    print_info "Caddy 软件包、其他配置、证书数据和日志都会保留。"
    read -r -p "确认移除本脚本管理的配置？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { print_warning "已取消。"; return 0; }
    command -v caddy >/dev/null 2>&1 || { print_error "Caddy 命令不可用，无法验证清理结果。"; return 1; }
    backup_dir=$(create_managed_cleanup_backup) || { print_error "无法创建清理前备份。"; return 1; }
    stage_root=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-caddy-cleanup.XXXXXXXX") || return 1
    copy_live_config_to_stage "$stage_root" || { rm -rf -- "$stage_root"; return 1; }
    shopt -s nullglob
    for file in "$stage_root/ai-scripts.d"/*.caddy; do
        is_managed_site_file "$file" || { remaining_configs=$((remaining_configs + 1)); continue; }
        rm -f -- "$file"
        removed=$((removed + 1))
    done
    shopt -u nullglob
    if ((remaining_configs == 0)) && owned_import_is_valid "$stage_root/Caddyfile"; then
        cleaned_main="$stage_root/Caddyfile.cleaned"
        remove_owned_import_from_file "$stage_root/Caddyfile" "$cleaned_main" || {
            rm -rf -- "$stage_root"
            return 1
        }
        mv -f -- "$cleaned_main" "$stage_root/Caddyfile"
    fi
    if ! validate_staged_config "$stage_root"; then
        print_error "清理后的候选配置验证失败，现有配置未修改。"
        rm -rf -- "$stage_root"
        return 1
    fi
    shopt -s nullglob
    for file in "$CADDY_MANAGED_DIR"/*.caddy; do
        if is_managed_site_file "$file"; then
            rm -f -- "$file" || removal_failed=1
        fi
    done
    shopt -u nullglob
    [[ ! -f "$CADDYFILE" ]] || main_mode=$(stat -c '%a' "$CADDYFILE" 2>/dev/null) || removal_failed=1
    if ((removal_failed != 0)) \
        || ! atomic_install_file "$stage_root/Caddyfile" "$CADDYFILE" "$main_mode" \
        || ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
        || ! activate_caddy_config "$backup_dir"; then
        print_error "清理结果未能安全加载，正在恢复。"
        restore_managed_cleanup "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
        rm -rf -- "$stage_root"
        return 1
    fi
    rmdir "$CADDY_MANAGED_DIR" 2>/dev/null || true
    rm -rf -- "$stage_root"
    print_success "已移除 $removed 个受管站点，未修改其他 Caddy 资产。"
    print_info "清理前备份: $backup_dir"
}

snapshot_directory_if_present() {
    local source_dir="$1" backup_dir="$2" name="$3"
    if [[ -d "$source_dir" && ! -L "$source_dir" ]]; then
        cp -a -- "$source_dir" "$backup_dir/$name"
    elif [[ -e "$source_dir" || -L "$source_dir" ]]; then
        return 1
    else
        : > "$backup_dir/$name.missing"
    fi
}

create_full_uninstall_backup() {
    local backup_dir
    umask 077
    install -d -m 700 "$CADDY_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$CADDY_BACKUP_ROOT/full-uninstall.XXXXXXXX") || return 1
    snapshot_directory_if_present "$CADDY_CONFIG_DIR" "$backup_dir" config || return 1
    snapshot_directory_if_present "$CADDY_DATA_DIR" "$backup_dir" data || return 1
    snapshot_directory_if_present "$CADDY_TLS_DIR" "$backup_dir" tls || return 1
    snapshot_directory_if_present "$CADDY_LOG_DIR" "$backup_dir" logs || return 1
    snapshot_optional_file "$CADDY_APT_KEY" "$backup_dir/apt.key" "$backup_dir/apt.key.missing" || return 1
    snapshot_optional_file "$CADDY_APT_SOURCE" "$backup_dir/apt.source" "$backup_dir/apt.source.missing" || return 1
    snapshot_optional_file "$CADDY_SERVICE_FILE" "$backup_dir/caddy.service" "$backup_dir/caddy.service.missing" || return 1
    record_service_state "$backup_dir"
    prune_backups 'full-uninstall.*'
    printf '%s\n' "$backup_dir"
}

remove_exact_caddy_path() {
    local target="$1"
    case "$target" in
        "$CADDY_CONFIG_DIR"|"$CADDY_DATA_DIR"|"$CADDY_TLS_DIR"|"$CADDY_LOG_DIR")
            [[ "$target" == /* && "$target" != / && "$target" != /etc && "$target" != /var ]] || return 1
            rm -rf -- "$target"
            ;;
        "$CADDY_APT_KEY"|"$CADDY_APT_SOURCE"|"$CADDY_SERVICE_FILE")
            [[ "$target" == /* ]] || return 1
            rm -f -- "$target"
            ;;
        *) return 1 ;;
    esac
}

validate_full_uninstall_paths() {
    [[ "$(basename -- "$CADDY_CONFIG_DIR")" == caddy \
        && "$(basename -- "$CADDY_DATA_DIR")" == caddy \
        && "$(basename -- "$CADDY_TLS_DIR")" == caddy \
        && "$(basename -- "$CADDY_LOG_DIR")" == caddy \
        && "$(basename -- "$CADDY_APT_KEY")" == caddy*.gpg \
        && "$(basename -- "$CADDY_APT_SOURCE")" == caddy*.list \
        && "$(basename -- "$CADDY_SERVICE_FILE")" == caddy.service ]]
}

full_uninstall_caddy() {
    local confirmation delete_logs backup_dir target failures=0
    check_root || return 1
    validate_runtime_settings || return 1
    validate_full_uninstall_paths || {
        print_error "完整卸载路径校验失败，拒绝执行递归删除。"
        return 1
    }
    command -v apt-get >/dev/null 2>&1 || {
        print_error "完整卸载仅支持由 apt 管理的 Caddy；未修改任何文件。"
        return 1
    }
    print_warning "完整卸载将停止并删除 Caddy 软件包及其专用配置和数据。"
    print_warning "请输入 PURGE-CADDY 进行强确认；不会清空系统 journal，也不会修改 cloud-init。"
    read -r -p "确认文本: " confirmation
    [[ "$confirmation" == PURGE-CADDY ]] || { print_warning "确认不匹配，已取消。"; return 0; }
    read -r -p "是否同时删除 /var/log/caddy 日志目录？[y/N] " delete_logs
    backup_dir=$(create_full_uninstall_backup) || { print_error "无法创建完整卸载前备份。"; return 1; }
    systemctl stop "$CADDY_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$CADDY_SERVICE" >/dev/null 2>&1 || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy; then
        print_error "Caddy 软件包卸载失败，专用目录未删除。"
        restore_service_state "$backup_dir" || print_warning "服务状态未能完全恢复。"
        return 1
    fi
    for target in "$CADDY_CONFIG_DIR" "$CADDY_DATA_DIR" "$CADDY_TLS_DIR" \
        "$CADDY_APT_KEY" "$CADDY_APT_SOURCE" "$CADDY_SERVICE_FILE"; do
        remove_exact_caddy_path "$target" || failures=1
    done
    if [[ "$delete_logs" =~ ^[Yy]$ ]]; then
        remove_exact_caddy_path "$CADDY_LOG_DIR" || failures=1
        print_info "仅删除了 Caddy 自有日志目录；systemd journal 历史未清理。"
    fi
    command -v apt-get >/dev/null 2>&1 && apt-get update >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    print_info "卸载前完整备份: $backup_dir"
    if ((failures != 0)); then
        print_warning "部分 Caddy 资产清理失败，备份已保留。"
        return 1
    fi
    print_success "Caddy 已卸载；未清理全局 journal 或 cloud-init 状态。"
}

restart_caddy() {
    check_root || return 1
    validate_runtime_settings || return 1
    command -v caddy >/dev/null 2>&1 || { print_error "Caddy 未安装。"; return 1; }
    [[ -f "$CADDYFILE" && ! -L "$CADDYFILE" ]] || { print_error "Caddyfile 不存在或不是普通文件。"; return 1; }
    print_info "正在验证 Caddyfile。"
    caddy validate --config "$CADDYFILE" --adapter caddyfile || {
        print_error "配置验证失败，未重启服务。"
        return 1
    }
    systemctl restart "$CADDY_SERVICE" >/dev/null 2>&1 || { print_error "Caddy 重启失败。"; return 1; }
    sleep 1
    systemctl is-active --quiet "$CADDY_SERVICE" || {
        print_error "重启后服务未正常运行。"
        journalctl -u "$CADDY_SERVICE" -n 20 --no-pager 2>/dev/null || true
        return 1
    }
    print_success "Caddy 重启成功。"
}

show_caddy_menu() {
    clear
    echo -e "${CYAN}=== Caddy 管理脚本 v2.0 ===${NC}"
    echo "1. 安装/配置反向代理"
    echo "2. 移除本脚本管理的配置"
    echo "3. 重启 Caddy"
    echo "4. 完整卸载 Caddy（强确认）"
    echo "0. 返回工具箱"
    echo -e "${YELLOW}================================${NC}"
}

caddy_main() {
    local caddy_choice status
    check_root || return 1
    validate_runtime_settings || return 1
    while true; do
        show_caddy_menu
        read -r -p "请输入 Caddy 管理选项：" caddy_choice
        status=0
        case "$caddy_choice" in
            1) configure_caddy_reverse_proxy || status=$? ;;
            2) remove_managed_caddy_assets || status=$? ;;
            3) restart_caddy || status=$? ;;
            4) full_uninstall_caddy || status=$? ;;
            0) return 0 ;;
            *) print_error "无效选项。"; status=1 ;;
        esac
        ((status == 0)) || print_warning "本次操作未完成（退出码：$status）。"
        read -r -p "按回车键返回菜单..."
    done
}

if [[ ${CADDY_MANAGER_SOURCE_ONLY:-0} != 1 ]]; then
    caddy_main "$@"
fi
