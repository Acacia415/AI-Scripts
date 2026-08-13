#!/bin/bash

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
STATE_DIR=/var/lib/ai-scripts/nginx
SITES_FILE="$STATE_DIR/sites.tsv"
BACKUP_ROOT=/var/backups/ai-scripts/nginx

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行。${NC}"; exit 1; }; }
valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_upstream() { [[ $1 =~ ^[A-Za-z0-9_.:-]+$ ]] && [[ $1 != *..* ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
pause_menu() { read -r -p '按回车继续……' _; }

backup_nginx() {
    local timestamp dir
    timestamp=$(date +%Y%m%d-%H%M%S)
    dir="$BACKUP_ROOT/$timestamp"
    install -d -m 700 "$dir"
    [[ -d /etc/nginx ]] && cp -a /etc/nginx "$dir/nginx"
    [[ -f $SITES_FILE ]] && cp -a "$SITES_FILE" "$dir/sites.tsv"
    printf '%s' "$dir"
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then return 0; fi
    if ss -ltn '( sport = :80 or sport = :443 )' 2>/dev/null | tail -n +2 | grep -q .; then
        echo -e "${RED}80 或 443 已被其他程序占用；不会自动结束该程序。请先处理冲突。${NC}"
        return 1
    fi
    install -d -m 700 "$STATE_DIR"
    touch "$STATE_DIR/installed-by-script"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y nginx curl certbot python3-certbot-nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx certbot python3-certbot-nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx certbot python3-certbot-nginx
    else
        echo -e "${RED}不支持的包管理器。${NC}"; return 1
    fi
    nginx -t || return 1
    systemctl enable --now nginx
}

record_site() {
    local domain=$1 upstream=$2 port=$3 temp
    install -d -m 700 "$STATE_DIR"
    touch "$SITES_FILE"; chmod 600 "$SITES_FILE"
    temp=$(mktemp "$STATE_DIR/.sites.XXXXXX")
    awk -F '\t' -v domain="$domain" '$1 != domain' "$SITES_FILE" > "$temp"
    printf '%s\t%s\t%s\n' "$domain" "$upstream" "$port" >> "$temp"
    chmod 600 "$temp" && mv -f "$temp" "$SITES_FILE"
}

write_site() {
    local domain=$1 upstream=$2 port=$3 config temp
    config="/etc/nginx/conf.d/ai-${domain}.conf"
    temp=$(mktemp /etc/nginx/conf.d/.ai-site.XXXXXX)
    if [[ -f /etc/letsencrypt/live/$domain/fullchain.pem && -f /etc/letsencrypt/live/$domain/privkey.pem ]]; then
        cat > "$temp" <<EOF
# Managed by AI-Scripts nginx-manager.sh
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://$upstream:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    else
        cat > "$temp" <<EOF
# Managed by AI-Scripts nginx-manager.sh
server {
    listen 80;
    server_name $domain;
    location / {
        proxy_pass http://$upstream:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    fi
    chmod 644 "$temp" && mv -f "$temp" "$config"
}

configure_site() {
    install_nginx || return 1
    local domain upstream port email config backup old=''
    read -r -p '域名: ' domain
    valid_domain "$domain" || { echo -e "${RED}域名无效。${NC}"; return 1; }
    read -r -p '上游地址 [127.0.0.1]: ' upstream
    upstream=${upstream:-127.0.0.1}
    valid_upstream "$upstream" || { echo -e "${RED}上游地址无效。${NC}"; return 1; }
    read -r -p '上游端口: ' port
    valid_port "$port" || { echo -e "${RED}端口无效。${NC}"; return 1; }
    read -r -p "证书通知邮箱 [admin@$domain]: " email
    email=${email:-admin@$domain}
    [[ $email =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo -e "${RED}邮箱无效。${NC}"; return 1; }

    backup=$(backup_nginx)
    config="/etc/nginx/conf.d/ai-${domain}.conf"
    [[ -f $config ]] && { old=$(mktemp "$STATE_DIR/.site.XXXXXX"); cp -a "$config" "$old"; }
    write_site "$domain" "$upstream" "$port"
    if ! nginx -t; then
        [[ -n $old ]] && mv -f "$old" "$config" || rm -f "$config"
        echo -e "${RED}配置校验失败，已回滚。${NC}"
        return 1
    fi
    systemctl reload nginx || { [[ -n $old ]] && mv -f "$old" "$config" || rm -f "$config"; systemctl reload nginx || true; return 1; }

    if ! certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$email" --redirect; then
        echo -e "${YELLOW}证书申请失败，保留已验证的 HTTP 反向代理配置；没有停止 Nginx。${NC}"
    fi
    nginx -t && systemctl reload nginx
    record_site "$domain" "$upstream" "$port"
    rm -f -- "$old"
    echo -e "${GREEN}站点配置完成。操作前备份：${backup}${NC}"
}

list_sites() {
    if [[ ! -s $SITES_FILE ]]; then echo -e "${YELLOW}没有本脚本管理的站点。${NC}"; return 1; fi
    awk -F '\t' '{printf "%-3d %-30s -> %s:%s\n", NR, $1, $2, $3}' "$SITES_FILE"
}

select_site() {
    local number total
    list_sites >&2 || return 1
    read -r -p '选择编号: ' number
    total=$(wc -l < "$SITES_FILE")
    [[ $number =~ ^[0-9]+$ ]] && (( number >= 1 && number <= total )) || return 1
    sed -n "${number}p" "$SITES_FILE"
}

edit_site() {
    local row domain old_upstream old_port upstream port config backup
    row=$(select_site) || { echo -e "${RED}选择无效。${NC}"; return; }
    IFS=$'\t' read -r domain old_upstream old_port <<< "$row"
    read -r -p "上游地址 [$old_upstream]: " upstream; upstream=${upstream:-$old_upstream}
    read -r -p "上游端口 [$old_port]: " port; port=${port:-$old_port}
    valid_upstream "$upstream" && valid_port "$port" || { echo -e "${RED}输入无效。${NC}"; return 1; }
    backup=$(backup_nginx); config="/etc/nginx/conf.d/ai-${domain}.conf"
    cp -a "$config" "${config}.ai-rollback"
    write_site "$domain" "$upstream" "$port"
    if nginx -t && systemctl reload nginx; then
        rm -f "${config}.ai-rollback"; record_site "$domain" "$upstream" "$port"
        echo -e "${GREEN}修改成功。备份：$backup${NC}"
    else
        mv -f "${config}.ai-rollback" "$config"; systemctl reload nginx || true
        echo -e "${RED}修改失败，已回滚。${NC}"
    fi
}

delete_site() {
    local row domain upstream port config temp backup answer
    row=$(select_site) || { echo -e "${RED}选择无效。${NC}"; return; }
    IFS=$'\t' read -r domain upstream port <<< "$row"
    read -r -p "确认删除 $domain？(y/N): " answer
    [[ $answer =~ ^[Yy]$ ]] || return 0
    backup=$(backup_nginx); config="/etc/nginx/conf.d/ai-${domain}.conf"
    rm -f "$config"
    if ! nginx -t; then cp -a "$backup/nginx/conf.d/ai-${domain}.conf" "$config"; return 1; fi
    systemctl reload nginx
    temp=$(mktemp "$STATE_DIR/.sites.XXXXXX")
    awk -F '\t' -v domain="$domain" '$1 != domain' "$SITES_FILE" > "$temp" && chmod 600 "$temp" && mv -f "$temp" "$SITES_FILE"
    read -r -p '是否同时让 Certbot 删除该域名证书？(y/N): ' answer
    [[ $answer =~ ^[Yy]$ ]] && certbot delete --cert-name "$domain" --non-interactive || true
    echo -e "${GREEN}删除完成。备份：$backup${NC}"
}

uninstall_nginx() {
    local answer backup domain _
    read -r -p '确认移除本脚本管理的全部 Nginx 站点？(y/N): ' answer
    [[ $answer =~ ^[Yy]$ ]] || return 0
    backup=$(backup_nginx)
    if [[ -f $SITES_FILE ]]; then
        while IFS=$'\t' read -r domain _; do rm -f "/etc/nginx/conf.d/ai-${domain}.conf"; done < "$SITES_FILE"
    fi
    if [[ -e $STATE_DIR/installed-by-script ]]; then
        systemctl disable --now nginx 2>/dev/null || true
        if command -v apt-get >/dev/null 2>&1; then apt-get purge -y nginx; else yum remove -y nginx; fi
    else
        nginx -t && systemctl reload nginx || true
        echo -e "${YELLOW}Nginx 原本已存在，已保留软件、其他站点、网站文件和证书。${NC}"
    fi
    rm -f "$SITES_FILE"
    echo -e "${GREEN}完成。卸载前备份：$backup${NC}"
}

main() {
    require_root
    install -d -m 700 "$STATE_DIR"
    local choice
    while true; do
        clear
        echo -e "${BLUE}Nginx 反向代理管理${NC}"
        echo '1. 安装/新增站点  2. 查看站点  3. 编辑站点'
        echo '4. 删除站点       5. 验证并重启 Nginx'
        echo '6. 卸载本脚本内容 0. 退出'
        read -r -p '请选择: ' choice
        case $choice in
            1) configure_site; pause_menu ;;
            2) list_sites || true; pause_menu ;;
            3) edit_site; pause_menu ;;
            4) delete_site; pause_menu ;;
            5) nginx -t && systemctl restart nginx; pause_menu ;;
            6) uninstall_nginx; pause_menu ;;
            0) return ;;
            *) sleep 1 ;;
        esac
    done
}

main "$@"
