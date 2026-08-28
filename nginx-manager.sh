#!/bin/bash

# Nginx 反向代理管理工具
# 只管理带 AI-Scripts 标识的站点、证书状态和续期任务。

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_MAIN_CONFIG="${NGINX_MAIN_CONFIG:-/etc/nginx/nginx.conf}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/var/log/nginx}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx.service}"
NGINX_STATE_ROOT="${NGINX_STATE_ROOT:-/var/lib/ai-scripts/nginx}"
NGINX_DOMAIN_STATE_DIR="${NGINX_DOMAIN_STATE_DIR:-${NGINX_STATE_ROOT}/domains}"
NGINX_BACKUP_ROOT="${NGINX_BACKUP_ROOT:-/var/backups/ai-scripts/nginx}"
NGINX_BACKUP_KEEP="${NGINX_BACKUP_KEEP:-5}"
NGINX_RENEWAL_CRON="${NGINX_RENEWAL_CRON:-/etc/cron.d/ai-scripts-nginx-certbot}"
NGINX_ACME_WEBROOT="${NGINX_ACME_WEBROOT:-/var/lib/ai-scripts/nginx/acme}"
LETSENCRYPT_LIVE_DIR="${LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"
SITE_MARKER='# Managed by AI-Scripts nginx-manager.sh'
STATE_MARKER='# AI-Scripts Nginx domain state v1'
CRON_MARKER='# Managed by AI-Scripts nginx-manager.sh'
declare -A MANAGED_SITES=()
SELECTED_DOMAIN=''
SELECTED_UPSTREAM_IP=''
SELECTED_UPSTREAM_PORT=''

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限执行。"
        return 1
    fi
}

validate_runtime_settings() {
    [[ "$NGINX_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || {
        print_error "备份保留数量无效: $NGINX_BACKUP_KEEP"
        return 1
    }
}

normalize_domain() {
    tr '[:upper:]' '[:lower:]' <<< "$1"
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

is_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] && ((${#1} <= 5)) && ((10#$1 <= 65535))
}

site_file_for_domain() { printf '%s/%s.conf\n' "$NGINX_CONF_DIR" "$1"; }
state_file_for_domain() { printf '%s/%s.state\n' "$NGINX_DOMAIN_STATE_DIR" "$1"; }

is_managed_site_file() {
    [[ -f "$1" && ! -L "$1" ]] && grep -Fxq "$SITE_MARKER" "$1"
}

is_managed_state_file() {
    [[ -f "$1" && ! -L "$1" ]] && grep -Fxq "$STATE_MARKER" "$1"
}

ensure_dedicated_cron_owned_or_absent() {
    if [[ -e "$NGINX_RENEWAL_CRON" || -L "$NGINX_RENEWAL_CRON" ]]; then
        [[ -f "$NGINX_RENEWAL_CRON" && ! -L "$NGINX_RENEWAL_CRON" ]] \
            && grep -Fxq "$CRON_MARKER" "$NGINX_RENEWAL_CRON"
    fi
}

atomic_install_file() {
    local source_file="$1" target_file="$2" mode="$3" target_dir temp_file
    target_dir=$(dirname -- "$target_file")
    install -d -m 755 "$target_dir" || return 1
    temp_file=$(mktemp "$target_dir/.ai-scripts-nginx.XXXXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

prune_transaction_backups() {
    local index
    local -a backups=()
    mapfile -t backups < <(find "$NGINX_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name 'transaction.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=NGINX_BACKUP_KEEP; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$NGINX_BACKUP_ROOT/transaction."* ]] || continue
        rm -rf -- "${backups[$index]}"
    done
}

snapshot_optional_file() {
    local source_file="$1" backup_file="$2" missing_file="$3"
    if [[ -e "$source_file" || -L "$source_file" ]]; then
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

create_site_transaction() {
    local domain="$1" reason="$2" site_file state_file backup_dir active=false
    site_file=$(site_file_for_domain "$domain")
    state_file=$(state_file_for_domain "$domain")
    umask 077
    install -d -m 700 "$NGINX_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$NGINX_BACKUP_ROOT/transaction.${reason}.${domain}.XXXXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1
    snapshot_optional_file "$site_file" "$backup_dir/site.conf" "$backup_dir/site.missing" || return 1
    snapshot_optional_file "$state_file" "$backup_dir/domain.state" "$backup_dir/state.missing" || return 1
    snapshot_optional_file "$NGINX_RENEWAL_CRON" "$backup_dir/renewal.cron" "$backup_dir/cron.missing" || return 1
    systemctl is-active --quiet "$NGINX_SERVICE" 2>/dev/null && active=true
    printf '%s\n' "$active" > "$backup_dir/nginx.active"
    prune_transaction_backups
    printf '%s\n' "$backup_dir"
}

restore_site_transaction() {
    local domain="$1" backup_dir="$2" site_file state_file was_active status=0
    site_file=$(site_file_for_domain "$domain")
    state_file=$(state_file_for_domain "$domain")
    restore_optional_file "$site_file" "$backup_dir/site.conf" "$backup_dir/site.missing" 600 || status=1
    restore_optional_file "$state_file" "$backup_dir/domain.state" "$backup_dir/state.missing" 600 || status=1
    restore_optional_file "$NGINX_RENEWAL_CRON" "$backup_dir/renewal.cron" "$backup_dir/cron.missing" 644 || status=1
    was_active=$(< "$backup_dir/nginx.active")
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || status=1
        if [[ "$was_active" == true ]]; then
            systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1 || status=1
        fi
    fi
    return "$status"
}

read_state_value() {
    local state_file="$1" key="$2"
    is_managed_state_file "$state_file" || return 1
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$state_file"
}

write_domain_state() {
    local domain="$1" certificate_owned="$2" site_present="$3" state_file stage_dir stage_file status
    is_valid_domain "$domain" || return 1
    [[ "$certificate_owned" =~ ^(true|false)$ && "$site_present" =~ ^(true|false)$ ]] || return 1
    state_file=$(state_file_for_domain "$domain")
    if [[ -e "$state_file" || -L "$state_file" ]]; then
        is_managed_state_file "$state_file" || return 1
    fi
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-nginx-state.XXXXXXXX") || return 1
    stage_file="$stage_dir/domain.state"
    printf '%s\n' "$STATE_MARKER" "domain=$domain" "certificate_owned=$certificate_owned" "site_present=$site_present" > "$stage_file"
    chmod 600 "$stage_file"
    atomic_install_file "$stage_file" "$state_file" 600
    status=$?
    rm -rf -- "$stage_dir"
    return "$status"
}

refresh_renewal_cron() {
    local state_file domain certificate_owned stage_dir stage_file state_domain status count=0
    local -a lines=()
    ensure_dedicated_cron_owned_or_absent || {
        print_error "续期任务路径已被其他配置占用，拒绝覆盖: $NGINX_RENEWAL_CRON"
        return 1
    }
    shopt -s nullglob
    for state_file in "$NGINX_DOMAIN_STATE_DIR"/*.state; do
        is_managed_state_file "$state_file" || continue
        domain=$(read_state_value "$state_file" domain) || continue
        certificate_owned=$(read_state_value "$state_file" certificate_owned) || continue
        is_valid_domain "$domain" || continue
        state_domain=$(basename -- "$state_file" .state)
        [[ "$domain" == "$state_domain" ]] || continue
        [[ "$certificate_owned" == true ]] || continue
        lines+=("$((17 + count % 40)) 3 * * * root /usr/bin/certbot renew --cert-name $domain --quiet --deploy-hook '/usr/bin/systemctl reload nginx'")
        ((count++))
    done
    shopt -u nullglob
    if ((count == 0)); then
        rm -f -- "$NGINX_RENEWAL_CRON"
        return 0
    fi
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-nginx-cron.XXXXXXXX") || return 1
    stage_file="$stage_dir/renewal.cron"
    printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$CRON_MARKER" > "$stage_file"
    printf '%s\n' "${lines[@]}" >> "$stage_file"
    atomic_install_file "$stage_file" "$NGINX_RENEWAL_CRON" 644
    status=$?
    rm -rf -- "$stage_dir"
    return "$status"
}

check_dns_resolution() {
    local domain="$1" answers
    print_info "验证域名解析: $domain"
    if ! command -v dig >/dev/null 2>&1; then
        print_info "未安装 dig，正在从系统软件源安装 DNS 查询工具。"
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update \
                && DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils || return 1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bind-utils || return 1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bind-utils || return 1
        else
            print_error "无法自动安装 dig，请先安装 dnsutils/bind-utils。"
            return 1
        fi
        command -v dig >/dev/null 2>&1 || {
            print_error "DNS 查询工具安装后仍不可用。"
            return 1
        }
    fi
    answers=$( { dig +short A "$domain"; dig +short AAAA "$domain"; } 2>/dev/null )
    [[ -n "$answers" ]] || {
        print_error "域名 $domain 没有有效的 A/AAAA 解析记录。"
        return 1
    }
}

non_nginx_port_conflicts() {
    local listeners
    command -v ss >/dev/null 2>&1 || return 1
    listeners=$(ss -H -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /:443$/')
    [[ -n "$listeners" ]] || return 1
    grep -Fv nginx <<< "$listeners"
}

authorize_and_release_ports() {
    local conflicts reply
    conflicts=$(non_nginx_port_conflicts) || return 0
    print_warning "检测到非 Nginx 进程占用 80/443 端口："
    printf '%s\n' "$conflicts"
    read -r -p "是否明确同意终止这些端口上的进程？(y/N): " reply
    [[ "$reply" =~ ^[Yy]$ ]] || {
        print_error "未获得释放端口授权，已停止安装；不会终止任何进程。"
        return 1
    }
    command -v fuser >/dev/null 2>&1 || {
        print_error "缺少 fuser，无法按授权释放端口。"
        return 1
    }
    fuser -k 80/tcp 443/tcp >/dev/null 2>&1 || true
    sleep 1
    if non_nginx_port_conflicts >/dev/null; then
        print_error "端口仍被占用，已停止安装。"
        return 1
    fi
}

install_nginx() {
    clear
    check_root || return 1
    authorize_and_release_ports || return 1
    print_info "使用系统软件源安装或更新 Nginx；不会覆盖全局 nginx.conf。"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx || return 1
    else
        print_error "无法识别包管理器，请手动安装 Nginx。"
        return 1
    fi
    command -v nginx >/dev/null 2>&1 || { print_error "Nginx 安装后命令不可用。"; return 1; }
    if ! nginx -t; then
        print_error "现有 Nginx 配置测试失败；未覆盖 nginx.conf，也不会执行深度重置。"
        return 1
    fi
    systemctl enable "$NGINX_SERVICE" >/dev/null 2>&1 || return 1
    systemctl restart "$NGINX_SERVICE" >/dev/null 2>&1 \
        || systemctl start "$NGINX_SERVICE" >/dev/null 2>&1 || {
            print_error "Nginx 启动失败；不会杀死未获授权的端口进程或重写全局配置。"
            journalctl -u "$NGINX_SERVICE" -n 50 --no-pager 2>/dev/null || true
            return 1
        }
    systemctl is-active --quiet "$NGINX_SERVICE" || return 1
    print_success "Nginx 安装/更新完成：$(nginx -v 2>&1)"
}

install_certbot() {
    command -v certbot >/dev/null 2>&1 && return 0
    print_info "安装 Certbot..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y certbot || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y certbot || return 1
    else
        print_error "无法自动安装 Certbot。"
        return 1
    fi
    command -v certbot >/dev/null 2>&1
}

render_http_site() {
    local output_file="$1" domain="$2" upstream_ip="$3" upstream_port="$4"
    cat > "$output_file" <<EOF
$SITE_MARKER
server {
    listen 80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $NGINX_ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://$upstream_ip:$upstream_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    chmod 600 "$output_file"
}

render_https_site() {
    local output_file="$1" domain="$2" upstream_ip="$3" upstream_port="$4"
    cat > "$output_file" <<EOF
$SITE_MARKER
server {
    listen 80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $NGINX_ACME_WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate $LETSENCRYPT_LIVE_DIR/$domain/fullchain.pem;
    ssl_certificate_key $LETSENCRYPT_LIVE_DIR/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location / {
        proxy_pass http://$upstream_ip:$upstream_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    chmod 600 "$output_file"
}

apply_site_candidate() {
    local domain="$1" candidate="$2" backup_dir="$3" site_file
    site_file=$(site_file_for_domain "$domain")
    if ! atomic_install_file "$candidate" "$site_file" 600; then
        print_error "站点候选配置安装失败。"
        return 1
    fi
    if nginx -t >/dev/null 2>&1 && systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1; then
        return 0
    fi
    print_error "候选配置测试或 reload 失败，正在恢复原站点。"
    restore_site_transaction "$domain" "$backup_dir" \
        || print_error "自动恢复未完全成功，请使用备份: $backup_dir"
    return 1
}

certificate_files_exist() {
    [[ -s "$LETSENCRYPT_LIVE_DIR/$1/fullchain.pem" && -s "$LETSENCRYPT_LIVE_DIR/$1/privkey.pem" ]]
}

port_80_is_free() {
    local listeners
    command -v ss >/dev/null 2>&1 || {
        print_error "缺少 ss，无法确认 standalone 所需的 80 端口是否空闲。"
        return 1
    }
    listeners=$(ss -H -ltn 2>/dev/null | awk '$4 ~ /:80$/') || return 1
    [[ -z "$listeners" ]]
}

request_certificate_standalone() {
    local domain="$1" was_active=false cert_status=1 restart_status=0
    local -a valid_domains=("$domain") certbot_domains=()
    local valid_domain
    for valid_domain in "${valid_domains[@]}"; do
        certbot_domains+=(-d "$valid_domain")
    done
    systemctl is-active --quiet "$NGINX_SERVICE" 2>/dev/null && was_active=true
    if [[ "$was_active" == true ]]; then
        systemctl stop "$NGINX_SERVICE" >/dev/null 2>&1 || return 1
    fi
    if port_80_is_free; then
        certbot certonly --standalone "${certbot_domains[@]}" --cert-name "$domain" \
            --non-interactive --agree-tos --email "admin@$domain" && cert_status=0
    else
        print_error "停止 Nginx 后 80 端口仍被占用；不会绕过授权杀死进程。"
    fi
    if [[ "$was_active" == true ]]; then
        systemctl start "$NGINX_SERVICE" >/dev/null 2>&1 || restart_status=1
    fi
    ((cert_status == 0 && restart_status == 0))
}

request_certificate() {
    local domain="$1" valid_domain
    local -a valid_domains=("$domain") certbot_domains=()
    for valid_domain in "${valid_domains[@]}"; do
        certbot_domains+=(-d "$valid_domain")
    done
    if certbot certonly --webroot -w "$NGINX_ACME_WEBROOT" "${certbot_domains[@]}" --cert-name "$domain" \
        --non-interactive --agree-tos --email "admin@$domain"; then
        print_success "使用 webroot 模式申请证书成功。"
        return 0
    fi
    print_warning "webroot 模式失败，尝试 standalone；域名参数将完整保留。"
    request_certificate_standalone "$domain"
}

cleanup_new_certificate() {
    local domain="$1"
    command -v certbot >/dev/null 2>&1 || return 1
    certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1
}

prompt_upstream() {
    local is_local upstream_ip upstream_port
    while true; do
        read -r -p "是否为本地服务？(y/n): " is_local
        case "$is_local" in
            [Yy]*) upstream_ip=127.0.0.1; break ;;
            [Nn]*)
                read -r -p "请输入上游服务器 IPv4 地址: " upstream_ip
                is_valid_ipv4 "$upstream_ip" && break
                print_error "IPv4 地址无效。"
                ;;
            *) print_error "请回答 y 或 n。" ;;
        esac
    done
    while true; do
        read -r -p "请输入上游服务器端口: " upstream_port
        is_valid_port "$upstream_port" && break
        print_error "端口必须是 1-65535。"
    done
    SELECTED_UPSTREAM_IP="$upstream_ip"
    SELECTED_UPSTREAM_PORT="$upstream_port"
}

setup_reverse_proxy() {
    local domain_input domain site_file state_file upstream_ip upstream_port
    local backup_dir stage_dir http_stage https_stage certificate_preexisting=false certificate_owned=false
    local previous_owned=false new_certificate=false
    clear
    check_root || return 1
    if ! command -v nginx >/dev/null 2>&1 || ! systemctl is-active --quiet "$NGINX_SERVICE"; then
        print_error "请先安装并启动 Nginx。"
        return 1
    fi
    read -r -p "请输入域名（无需 http/https）: " domain_input
    domain=$(normalize_domain "$domain_input")
    is_valid_domain "$domain" || { print_error "域名格式无效。"; return 1; }
    check_dns_resolution "$domain" || return 1
    site_file=$(site_file_for_domain "$domain")
    state_file=$(state_file_for_domain "$domain")
    if [[ -e "$site_file" || -L "$site_file" ]]; then
        is_managed_site_file "$site_file" || {
            print_error "同名站点不属于本脚本，拒绝覆盖: $site_file"
            return 1
        }
    fi
    if [[ -e "$state_file" || -L "$state_file" ]]; then
        is_managed_state_file "$state_file" || { print_error "域名状态文件不属于本脚本，拒绝覆盖。"; return 1; }
        [[ $(read_state_value "$state_file" certificate_owned 2>/dev/null) == true ]] && previous_owned=true
    fi
    ensure_dedicated_cron_owned_or_absent || { print_error "专属续期任务路径被占用。"; return 1; }
    prompt_upstream || return 1
    upstream_ip="$SELECTED_UPSTREAM_IP"
    upstream_port="$SELECTED_UPSTREAM_PORT"
    backup_dir=$(create_site_transaction "$domain" setup) || { print_error "无法创建站点操作前备份。"; return 1; }
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-nginx-site.XXXXXXXX") || return 1
    http_stage="$stage_dir/http.conf"
    https_stage="$stage_dir/https.conf"
    install -d -m 755 "$NGINX_ACME_WEBROOT/.well-known/acme-challenge" || { rm -rf -- "$stage_dir"; return 1; }

    certificate_files_exist "$domain" && certificate_preexisting=true
    if [[ "$certificate_preexisting" == false ]]; then
        render_http_site "$http_stage" "$domain" "$upstream_ip" "$upstream_port" || { rm -rf -- "$stage_dir"; return 1; }
        if ! apply_site_candidate "$domain" "$http_stage" "$backup_dir"; then
            rm -rf -- "$stage_dir"
            return 1
        fi
        if ! install_certbot || ! request_certificate "$domain" || ! certificate_files_exist "$domain"; then
            print_error "证书申请失败，正在恢复原站点配置。"
            restore_site_transaction "$domain" "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
            certificate_files_exist "$domain" && cleanup_new_certificate "$domain" || true
            rm -rf -- "$stage_dir"
            return 1
        fi
        new_certificate=true
    fi
    [[ "$previous_owned" == true || "$new_certificate" == true ]] && certificate_owned=true
    if ! render_https_site "$https_stage" "$domain" "$upstream_ip" "$upstream_port"; then
        print_error "无法生成 HTTPS 候选配置，正在恢复原站点。"
        restore_site_transaction "$domain" "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
        [[ "$new_certificate" == true ]] && cleanup_new_certificate "$domain" || true
        rm -rf -- "$stage_dir"
        return 1
    fi
    if ! apply_site_candidate "$domain" "$https_stage" "$backup_dir"; then
        [[ "$new_certificate" == true ]] && cleanup_new_certificate "$domain" || true
        rm -rf -- "$stage_dir"
        return 1
    fi
    if ! write_domain_state "$domain" "$certificate_owned" true || ! refresh_renewal_cron; then
        print_error "站点状态或专属续期任务写入失败，正在回滚。"
        restore_site_transaction "$domain" "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
        [[ "$new_certificate" == true ]] && cleanup_new_certificate "$domain" || true
        rm -rf -- "$stage_dir"
        return 1
    fi
    rm -rf -- "$stage_dir"
    print_success "反向代理配置完成：https://$domain"
    print_info "操作前备份: $backup_dir"
}

map_managed_sites() {
    local file domain index=1
    MANAGED_SITES=()
    shopt -s nullglob
    for file in "$NGINX_CONF_DIR"/*.conf; do
        is_managed_site_file "$file" || continue
        domain=$(basename -- "$file" .conf)
        is_valid_domain "$domain" || continue
        MANAGED_SITES["$index"]="$domain"
        ((index++))
    done
    shopt -u nullglob
}

select_managed_domain() {
    local prompt="$1" input index
    map_managed_sites
    ((${#MANAGED_SITES[@]} > 0)) || { print_warning "没有本脚本管理的站点。"; return 1; }
    for index in $(printf '%s\n' "${!MANAGED_SITES[@]}" | sort -n); do
        printf '%s. %s\n' "$index" "${MANAGED_SITES[$index]}"
    done
    read -r -p "$prompt" input
    if [[ "$input" =~ ^[0-9]+$ && -n "${MANAGED_SITES[$input]:-}" ]]; then
        SELECTED_DOMAIN="${MANAGED_SITES[$input]}"
    else
        input=$(normalize_domain "$input")
        is_valid_domain "$input" || return 1
        is_managed_site_file "$(site_file_for_domain "$input")" || return 1
        SELECTED_DOMAIN="$input"
    fi
}

delete_site_config() {
    local domain site_file state_file backup_dir delete_ssl certificate_owned=false
    clear
    check_root || return 1
    select_managed_domain '请输入要删除的配置编号或域名: ' || return 1
    domain="$SELECTED_DOMAIN"
    site_file=$(site_file_for_domain "$domain")
    state_file=$(state_file_for_domain "$domain")
    if is_managed_state_file "$state_file" \
        && [[ $(read_state_value "$state_file" certificate_owned 2>/dev/null) == true ]]; then
        certificate_owned=true
    fi
    read -r -p "是否同时删除本脚本拥有的 SSL 证书？(y/N): " delete_ssl
    backup_dir=$(create_site_transaction "$domain" delete) || return 1
    rm -f -- "$site_file" || return 1
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1; then
        print_error "删除后的配置检查失败，正在恢复站点。"
        restore_site_transaction "$domain" "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
        return 1
    fi
    if [[ "$certificate_owned" == true ]]; then
        write_domain_state "$domain" true false || { restore_site_transaction "$domain" "$backup_dir"; return 1; }
    else
        rm -f -- "$state_file"
    fi
    refresh_renewal_cron || { restore_site_transaction "$domain" "$backup_dir"; return 1; }
    if [[ "$delete_ssl" =~ ^[Yy]$ ]]; then
        if [[ "$certificate_owned" == true ]]; then
            if cleanup_new_certificate "$domain"; then
                rm -f -- "$state_file"
                refresh_renewal_cron || print_warning "证书已删除，但续期任务刷新失败。"
                print_success "已删除本脚本拥有的证书。"
            else
                print_warning "Certbot 未能删除证书；已保留证书状态和续期任务。"
            fi
        else
            print_warning "该证书不是本脚本创建的，不会删除。"
        fi
    fi
    print_success "已删除受管站点配置；其他 Nginx 站点未修改。"
    print_info "删除前备份: $backup_dir"
}

edit_proxy_config() {
    local domain site_file current_upstream current_port choice new_ip new_port backup_dir stage_dir stage_file
    clear
    check_root || return 1
    select_managed_domain '请输入要编辑的配置编号或域名: ' || return 1
    domain="$SELECTED_DOMAIN"
    site_file=$(site_file_for_domain "$domain")
    current_upstream=$(sed -n 's/^[[:space:]]*proxy_pass http:\/\/\([^:;]*\):[0-9][0-9]*;.*/\1/p' "$site_file" | head -n 1)
    current_port=$(sed -n 's/^[[:space:]]*proxy_pass http:\/\/[^:;]*:\([0-9][0-9]*\);.*/\1/p' "$site_file" | head -n 1)
    if ! is_valid_ipv4 "$current_upstream" || ! is_valid_port "$current_port"; then
        print_error "无法安全解析现有受管配置。"
        return 1
    fi
    echo "当前上游: $current_upstream:$current_port"
    echo "1. 修改上游 IP"
    echo "2. 修改上游端口"
    echo "3. 同时修改 IP 和端口"
    echo "0. 返回"
    read -r -p "请输入选项: " choice
    new_ip="$current_upstream"
    new_port="$current_port"
    case "$choice" in
        1|3)
            read -r -p "新 IPv4 地址: " new_ip
            is_valid_ipv4 "$new_ip" || { print_error "IPv4 地址无效。"; return 1; }
            ;;
        0) return 0 ;;
        2) ;;
        *) print_error "无效选项。"; return 1 ;;
    esac
    if [[ "$choice" == 2 || "$choice" == 3 ]]; then
        read -r -p "新端口号: " new_port
        is_valid_port "$new_port" || { print_error "端口无效。"; return 1; }
    fi
    backup_dir=$(create_site_transaction "$domain" edit) || return 1
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-nginx-edit.XXXXXXXX") || return 1
    stage_file="$stage_dir/site.conf"
    cp -- "$site_file" "$stage_file" || { rm -rf -- "$stage_dir"; return 1; }
    sed -i "s|proxy_pass http://$current_upstream:$current_port;|proxy_pass http://$new_ip:$new_port;|g" "$stage_file"
    if apply_site_candidate "$domain" "$stage_file" "$backup_dir"; then
        print_success "代理上游已安全更新。"
    else
        rm -rf -- "$stage_dir"
        return 1
    fi
    rm -rf -- "$stage_dir"
}

view_nginx_logs() {
    local choice
    clear
    check_root || return 1
    echo "1. 实时错误日志"
    echo "2. 实时访问日志"
    echo "3. 查看历史错误日志"
    echo "4. 查看历史访问日志"
    echo "0. 返回"
    read -r -p "请输入选项: " choice
    case "$choice" in
        1) tail -f "$NGINX_LOG_DIR/error.log" ;;
        2) tail -f "$NGINX_LOG_DIR/access.log" ;;
        3) less "$NGINX_LOG_DIR/error.log" ;;
        4) less "$NGINX_LOG_DIR/access.log" ;;
        0) return 0 ;;
        *) print_error "无效选项。"; return 1 ;;
    esac
}

create_bulk_backup() {
    local backup_dir file
    umask 077
    install -d -m 700 "$NGINX_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "$NGINX_BACKUP_ROOT/managed-uninstall.XXXXXXXX") || return 1
    install -d -m 700 "$backup_dir/sites" "$backup_dir/states" || return 1
    shopt -s nullglob
    for file in "$NGINX_CONF_DIR"/*.conf; do
        is_managed_site_file "$file" && cp -a -- "$file" "$backup_dir/sites/"
    done
    for file in "$NGINX_DOMAIN_STATE_DIR"/*.state; do
        is_managed_state_file "$file" && cp -a -- "$file" "$backup_dir/states/"
    done
    shopt -u nullglob
    snapshot_optional_file "$NGINX_RENEWAL_CRON" "$backup_dir/renewal.cron" "$backup_dir/cron.missing" || return 1
    printf '%s\n' "$backup_dir"
}

restore_bulk_sites() {
    local backup_dir="$1" file status=0
    shopt -s nullglob
    for file in "$backup_dir/sites"/*.conf; do
        atomic_install_file "$file" "$NGINX_CONF_DIR/$(basename -- "$file")" 600 || status=1
    done
    for file in "$backup_dir/states"/*.state; do
        atomic_install_file "$file" "$NGINX_DOMAIN_STATE_DIR/$(basename -- "$file")" 600 || status=1
    done
    shopt -u nullglob
    restore_optional_file "$NGINX_RENEWAL_CRON" "$backup_dir/renewal.cron" "$backup_dir/cron.missing" 644 || status=1
    nginx -t >/dev/null 2>&1 || status=1
    systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1 || status=1
    return "$status"
}

uninstall_nginx() {
    local confirm backup_dir file domain certificate_owned failures=0 managed_count=0
    clear
    check_root || return 1
    print_warning "此操作只移除 AI-Scripts 标记的站点、证书状态和专属 cron。"
    print_info "Nginx 软件包、nginx.conf、其他站点、日志、Web 文件和其他证书都会保留。"
    read -r -p "确认清理本脚本管理的 Nginx 资产？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { print_warning "已取消。"; return 0; }
    ensure_dedicated_cron_owned_or_absent || {
        print_error "专属续期任务路径不属于本脚本，拒绝继续清理。"
        return 1
    }
    backup_dir=$(create_bulk_backup) || { print_error "无法创建完整受管资产备份。"; return 1; }
    shopt -s nullglob
    for file in "$NGINX_CONF_DIR"/*.conf; do
        is_managed_site_file "$file" || continue
        rm -f -- "$file" || failures=1
        ((managed_count++))
    done
    shopt -u nullglob
    if ((failures != 0)) || ! nginx -t >/dev/null 2>&1 || ! systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1; then
        print_error "受管站点移除后的配置检查失败，正在恢复。"
        restore_bulk_sites "$backup_dir" || print_error "恢复失败，请使用备份: $backup_dir"
        return 1
    fi
    shopt -s nullglob
    for file in "$NGINX_DOMAIN_STATE_DIR"/*.state; do
        is_managed_state_file "$file" || continue
        domain=$(read_state_value "$file" domain) || { failures=1; continue; }
        certificate_owned=$(read_state_value "$file" certificate_owned) || { failures=1; continue; }
        if ! is_valid_domain "$domain" || [[ "$domain" != "$(basename -- "$file" .state)" ]]; then
            print_warning "状态文件与域名不匹配，已保留: $file"
            failures=1
            continue
        fi
        if [[ "$certificate_owned" == true ]] && certificate_files_exist "$domain"; then
            if ! cleanup_new_certificate "$domain"; then
                print_warning "证书 $domain 删除失败，已保留其状态和续期任务。"
                failures=1
                continue
            fi
        fi
        rm -f -- "$file" || failures=1
    done
    shopt -u nullglob
    refresh_renewal_cron || failures=1
    print_success "已移除 $managed_count 个受管站点；未卸载 Nginx，未删除任何未标记资产。"
    print_info "清理前备份: $backup_dir"
    ((failures == 0)) || print_warning "部分受管证书未删除，相关状态已保留。"
}

list_configs() {
    local file found=0 nginx_status
    clear
    check_root || return 1
    echo -e "${BLUE}AI-Scripts 管理的站点：${NC}"
    shopt -s nullglob
    for file in "$NGINX_CONF_DIR"/*.conf; do
        is_managed_site_file "$file" || continue
        printf '  %s\n' "$(basename -- "$file" .conf)"
        found=1
    done
    shopt -u nullglob
    ((found == 1)) || print_warning "没有受管站点。"
    echo
    print_info "未带 $SITE_MARKER 标识的其他 Nginx 配置不会被编辑或删除。"
    echo
    echo -e "${BLUE}受管 SSL 证书状态：${NC}"
    if command -v certbot >/dev/null 2>&1; then
        certbot certificates 2>/dev/null | awk '/Certificate Name:|Domains:|Expiry Date:/' || true
    else
        print_warning "Certbot 未安装。"
    fi
    echo
    nginx_status=$(systemctl is-active "$NGINX_SERVICE" 2>/dev/null || true)
    echo -e "${BLUE}Nginx 服务状态：${NC}${nginx_status:-unknown}"
}

main_menu() {
    local choice
    check_root || return 1
    validate_runtime_settings || return 1
    while true; do
        clear
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo -e "${GREEN}          Nginx 管理工具 v4.0${NC}"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo "1. 安装/更新 Nginx"
        echo "2. 配置反向代理"
        echo "3. 删除受管网站配置"
        echo "4. 编辑受管代理配置"
        echo "5. 查看日志"
        echo "6. 查看受管配置列表"
        echo "7. 移除本脚本管理的 Nginx 资产"
        echo "0. 退出"
        read -r -p "请输入选项: " choice
        case "$choice" in
            1) install_nginx ;;
            2) setup_reverse_proxy ;;
            3) delete_site_config ;;
            4) edit_proxy_config ;;
            5) view_nginx_logs ;;
            6) list_configs ;;
            7) uninstall_nginx ;;
            0) print_info "退出脚本。"; return 0 ;;
            *) print_error "无效选项。"; sleep 1 ;;
        esac
        read -r -p "按回车键继续..."
    done
}

if [[ ${NGINX_MANAGER_SOURCE_ONLY:-0} != 1 ]]; then
    main_menu "$@"
fi
