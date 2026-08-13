#!/bin/bash

set -uo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
CADDYFILE=/etc/caddy/Caddyfile
SITE_DIR=/etc/caddy/ai-sites
STATE_DIR=/var/lib/ai-scripts/caddy
BACKUP_ROOT=/var/backups/ai-scripts/caddy

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行。${NC}"; exit 1; }; }
valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_upstream() { [[ $1 =~ ^[A-Za-z0-9_.:-]+$ ]] && [[ $1 != *..* ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

backup_caddy() {
    local timestamp dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    dir="$BACKUP_ROOT/$timestamp"
    install -d -m 700 "$dir"
    [[ -d /etc/caddy ]] && cp -a /etc/caddy "$dir/caddy"
    systemctl is-enabled --quiet caddy 2>/dev/null && touch "$dir/service-enabled"
    systemctl is-active --quiet caddy 2>/dev/null && touch "$dir/service-active"
    printf '%s' "$dir"
}

restore_caddy_backup() {
    local backup=$1
    [[ -d $backup/caddy ]] || return 1
    rm -rf -- /etc/caddy
    cp -a "$backup/caddy" /etc/caddy
    systemctl daemon-reload
}

install_caddy() {
    command -v caddy >/dev/null 2>&1 && return 0
    local repo_backup key_tmp list_tmp
    install -d -m 700 "$STATE_DIR"
    repo_backup="$STATE_DIR/repository-before"
    install -d -m 700 "$repo_backup"
    [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]] || cp -a /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$repo_backup/key.gpg"
    [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]] || cp -a /etc/apt/sources.list.d/caddy-stable.list "$repo_backup/caddy-stable.list"
    if ! apt-get update || ! apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg; then return 1; fi
    key_tmp=$(mktemp /usr/share/keyrings/.caddy-key.XXXXXX)
    list_tmp=$(mktemp /etc/apt/sources.list.d/.caddy-list.XXXXXX)
    if ! curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o "$key_tmp" \
        || ! curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$list_tmp"; then
        rm -f "$key_tmp" "$list_tmp"
        return 1
    fi
    install -m 0644 "$key_tmp" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    install -m 0644 "$list_tmp" /etc/apt/sources.list.d/caddy-stable.list
    rm -f "$key_tmp" "$list_tmp"
    if ! apt-get update || ! apt-get install -y caddy; then
        [[ ! -f "$repo_backup/key.gpg" ]] || cp -a "$repo_backup/key.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        [[ -f "$repo_backup/key.gpg" ]] || rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        [[ ! -f "$repo_backup/caddy-stable.list" ]] || cp -a "$repo_backup/caddy-stable.list" /etc/apt/sources.list.d/caddy-stable.list
        [[ -f "$repo_backup/caddy-stable.list" ]] || rm -f /etc/apt/sources.list.d/caddy-stable.list
        return 1
    fi
    touch "$STATE_DIR/installed-by-script"
}

ensure_import() {
    install -d -m 755 /etc/caddy "$SITE_DIR"
    [[ -f $CADDYFILE ]] || printf '# Managed by Caddy package / administrator\n' > "$CADDYFILE"
    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        echo -e "${RED}现有 Caddyfile 无效；为避免覆盖用户配置，操作已停止。${NC}"
        return 1
    fi
    if ! grep -Fqx 'import /etc/caddy/ai-sites/*.caddy' "$CADDYFILE"; then
        printf '\n# AI-Scripts managed sites\nimport /etc/caddy/ai-sites/*.caddy\n' >> "$CADDYFILE"
    fi
}

configure_proxy() {
    install_caddy || return 1
    local backup domain upstream port site temp old_site=''
    read -r -p '域名（不含协议）: ' domain
    valid_domain "$domain" || { echo -e "${RED}域名格式无效。${NC}"; return 1; }
    read -r -p '上游地址 [localhost]: ' upstream
    upstream=${upstream:-localhost}
    valid_upstream "$upstream" || { echo -e "${RED}上游地址包含不安全字符。${NC}"; return 1; }
    read -r -p '上游端口: ' port
    valid_port "$port" || { echo -e "${RED}端口无效。${NC}"; return 1; }

    backup=$(backup_caddy) || return 1
    ensure_import || { restore_caddy_backup "$backup"; return 1; }

    site="$SITE_DIR/$domain.caddy"
    if [[ -f $site ]]; then
        read -r -p '该域名配置已存在，覆盖？(y/N): ' answer
        [[ $answer =~ ^[Yy]$ ]] || return 0
        old_site=$(mktemp "$STATE_DIR/.site-backup.XXXXXX")
        cp -a "$site" "$old_site"
    fi
    temp=$(mktemp "$SITE_DIR/.site.XXXXXX")
    cat > "$temp" <<EOF
$domain {
    reverse_proxy $upstream:$port
    encode gzip
}
EOF
    chmod 644 "$temp"
    mv -f "$temp" "$site"
    caddy fmt "$site" --overwrite

    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        echo -e "${RED}配置验证失败，正在自动回滚。${NC}"
        if [[ -n $old_site ]]; then mv -f "$old_site" "$site"; else rm -f "$site"; fi
        restore_caddy_backup "$backup"
        return 1
    fi
    rm -f -- "$old_site"

    if systemctl is-active --quiet caddy; then
        systemctl reload caddy || { restore_caddy_backup "$backup"; systemctl restart caddy || true; return 1; }
    else
        systemctl enable --now caddy || { restore_caddy_backup "$backup"; return 1; }
    fi
    echo -e "${GREEN}反向代理已生效：https://${domain}${NC}"
    echo -e "${CYAN}操作前备份：${backup}${NC}"
}

restart_caddy() {
    command -v caddy >/dev/null 2>&1 || { echo -e "${RED}Caddy 未安装。${NC}"; return 1; }
    caddy validate --config "$CADDYFILE" --adapter caddyfile || return 1
    systemctl restart caddy && systemctl is-active --quiet caddy
}

uninstall_caddy() {
    local confirm backup
    read -r -p '确认移除 AI-Scripts Caddy 配置？(y/N): ' confirm
    [[ $confirm =~ ^[Yy]$ ]] || return 0
    backup=$(backup_caddy) || return 1
    rm -rf -- "$SITE_DIR"
    if [[ -f $CADDYFILE ]]; then
        sed -i '\|^# AI-Scripts managed sites$|d;\|^import /etc/caddy/ai-sites/\*\.caddy$|d' "$CADDYFILE"
    fi

    if [[ -e $STATE_DIR/installed-by-script ]]; then
        systemctl disable --now caddy 2>/dev/null || true
        apt-get purge -y caddy
        if [[ -f "$STATE_DIR/repository-before/key.gpg" ]]; then cp -a "$STATE_DIR/repository-before/key.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg; else rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg; fi
        if [[ -f "$STATE_DIR/repository-before/caddy-stable.list" ]]; then cp -a "$STATE_DIR/repository-before/caddy-stable.list" /etc/apt/sources.list.d/caddy-stable.list; else rm -f /etc/apt/sources.list.d/caddy-stable.list; fi
    else
        caddy validate --config "$CADDYFILE" --adapter caddyfile && systemctl reload caddy || true
        echo -e "${YELLOW}Caddy 原本已存在，仅移除本脚本管理的站点。${NC}"
    fi
    echo -e "${YELLOW}为避免影响其他站点，/var/log/caddy 中的日志已保留。${NC}"
    echo -e "${GREEN}操作完成。卸载前备份：${backup}${NC}"
}

main() {
    require_root
    local choice
    while true; do
        clear
        echo '1. 安装/配置反向代理'
        echo '2. 卸载本脚本管理的 Caddy 内容'
        echo '3. 验证并重启 Caddy'
        echo '0. 返回'
        read -r -p '请选择: ' choice
        case $choice in
            1) configure_proxy; read -r -p '按回车继续……' _ ;;
            2) uninstall_caddy; read -r -p '按回车继续……' _ ;;
            3) restart_caddy; read -r -p '按回车继续……' _ ;;
            0) return ;;
            *) sleep 1 ;;
        esac
    done
}

main "$@"
