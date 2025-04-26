#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本需要root权限执行${NC}"
        exit 1
    fi
}

# 安装Certbot（增强兼容性）
install_certbot() {
    echo -e "${YELLOW}正在安装Certbot...${NC}"
    
    # 自动选择安装方式
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y python3-pip python3-venv certbot python3-certbot-nginx
    elif command -v yum &> /dev/null; then
        yum install -y python3-pip certbot python3-certbot-nginx
    else
        echo -e "${YELLOW}使用pip进行安装...${NC}"
        # 确保安装了pip
        if ! command -v pip3 &> /dev/null; then
            echo -e "${YELLOW}正在安装pip...${NC}"
            python3 -m ensurepip --default-pip || {
                echo -e "${RED}pip安装失败，尝试使用系统包管理器安装${NC}"
                if command -v apt-get &> /dev/null; then
                    apt-get update && apt-get install -y python3-pip
                elif command -v yum &> /dev/null; then
                    yum install -y python3-pip
                else
                    echo -e "${RED}无法安装pip，请手动安装后重试${NC}"
                    return 1
                fi
            }
        fi
        pip3 install certbot certbot-nginx
    fi

    # 验证安装
    if ! command -v certbot &> /dev/null; then
        echo -e "${RED}Certbot安装失败，请手动安装：https://certbot.eff.org/${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Certbot安装成功！${NC}"
    return 0
}

# 安装/更新Nginx
install_nginx() {
    clear
    check_root
    echo -e "${YELLOW}正在安装依赖...${NC}"
    
    # 安装必要工具（提前到最前面）
    if ! command -v fuser &>/dev/null; then
        if command -v apt-get &> /dev/null; then
            apt-get install -y psmisc
        elif command -v yum &> /dev/null; then
            yum install -y psmisc
        fi
    fi

    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi

    # 检测端口占用
    echo -e "${YELLOW}检查端口占用情况...${NC}"
    if ss -tulpn | grep -E ':80\s|:443\s'; then
        echo -e "${YELLOW}警告：检测到80或443端口已被占用${NC}"
        read -p "是否尝试释放端口？(y/n): " FREE_PORT
        if [[ "$FREE_PORT" == "y" ]]; then
            echo -e "${YELLOW}尝试释放端口...${NC}"
            fuser -k 80/tcp 443/tcp 2>/dev/null
        else
            echo -e "${YELLOW}继续安装，但可能导致Nginx无法启动${NC}"
        fi
    fi

    case $OS in
        debian|ubuntu)
            apt update
            apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https
            
            # 使用新的GPG密钥方式
            echo -e "${YELLOW}使用现代GPG方式添加Nginx存储库...${NC}"
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/$OS `lsb_release -cs` nginx" | tee /etc/apt/sources.list.d/nginx.list
            
            apt update
            apt install -y nginx
            ;;
        centos|rhel)
            rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
            yum install -y nginx
            ;;
        *)
            echo -e "${RED}不支持的Linux发行版${NC}"
            exit 1
            ;;
    esac

    # 安装后修复：创建必要目录和配置文件
    echo -e "${YELLOW}正在创建必要目录结构...${NC}"
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
    chown -R nginx:nginx /var/log/nginx

    if [ ! -f /etc/nginx/nginx.conf ]; then
        echo -e "${YELLOW}生成默认nginx.conf...${NC}"
        cat <<EOF | tee /etc/nginx/nginx.conf >/dev/null
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    # 防火墙配置
    if command -v ufw &> /dev/null; then
        ufw allow 'Nginx Full'
        ufw reload
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
    fi

    systemctl enable --now nginx
    
    # 错误处理（此处需要修改深度修复部分）
    if ! systemctl is-active --quiet nginx; then
        echo -e "${RED}启动失败，执行深度修复...${NC}"
        
        # 日志分析
        local error_log=$(journalctl -u nginx -n 50 | grep -iE 'error|failed')
        echo -e "${YELLOW}关键错误摘要：\n$error_log${NC}"
        
        # 端口冲突解决
        fuser -k 80/tcp 443/tcp 2>/dev/null
        
        # 配置重置（修改此处）
        echo -e "${YELLOW}重建核心目录结构...${NC}"
        mkdir -p /etc/nginx/conf.d
        mkdir -p /var/log/nginx
        chown -R nginx:nginx /var/log/nginx

        echo -e "${YELLOW}生成最小化配置...${NC}"
        cat <<EOF | tee /etc/nginx/nginx.conf >/dev/null
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
EOF
        
        # 重试启动
        sudo systemctl restart nginx || {
            echo -e "${RED}终极修复失败，建议："
            echo -e "1. 检查/var/log/nginx/error.log"
            echo -e "2. 使用调试模式运行: sudo nginx -g 'daemon off; master_process on;'${NC}"
            exit 1
        }
    fi

    # 最终状态验证
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}Nginx 安装完成，版本信息：$(nginx -v 2>&1)${NC}"
    else
        echo -e "${RED}严重错误：Nginx无法启动，请手动排查："
        echo -e "1. 检查端口冲突：ss -tulpn | grep ':80'"
        echo -e "2. 查看完整日志：journalctl -u nginx --since '5 minutes ago'${NC}"
        exit 1
    fi
}

# 配置反向代理（支持多域名）
setup_reverse_proxy() {
    clear
    check_root
    
    # 主域名
    read -p "请输入主域名 (例如 example.com): " DOMAIN
    
    # 多域名支持
    local ADDITIONAL_DOMAINS=""
    read -p "是否添加额外域名？如www.$DOMAIN (y/n): " ADD_MORE
    if [[ "$ADD_MORE" == "y" ]]; then
        read -p "请输入额外域名（用空格分隔，如www.$DOMAIN blog.$DOMAIN）: " ADDITIONAL_DOMAINS
    fi
    
    # 合并所有域名为一个数组
    local ALL_DOMAINS=($DOMAIN $ADDITIONAL_DOMAINS)
    
    # 检查每个域名的DNS解析
    for domain in "${ALL_DOMAINS[@]}"; do
        if ! check_dns_resolution "$domain"; then
            echo -e "${YELLOW}跳过域名: $domain${NC}"
            # 从域名数组中移除该域名
            ALL_DOMAINS=( "${ALL_DOMAINS[@]/$domain}" )
        fi
    done
    
    # 确认剩余的域名
    if [ ${#ALL_DOMAINS[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的域名，操作取消${NC}"
        return 1
    fi
    
    echo -e "${GREEN}将为以下域名配置反向代理:${NC}"
    for domain in "${ALL_DOMAINS[@]}"; do
        [ -n "$domain" ] && echo -e "- $domain"
    done
    
    # 智能判断上游地址
    while true; do
        read -p "是否为本地服务？(y/n): " IS_LOCAL
        case $IS_LOCAL in
            [Yy]* )
                UPSTREAM_IP="127.0.0.1"
                echo -e "${YELLOW}使用本地服务，自动设置上游IP为127.0.0.1${NC}"
                break
                ;;
            [Nn]* )
                while true; do
                    read -p "请输入上游服务器IP地址: " UPSTREAM_IP
                    if [[ $UPSTREAM_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        break
                    else
                        echo -e "${RED}错误：无效的IP地址格式${NC}"
                    fi
                done
                break
                ;;
            * )
                echo -e "${RED}请回答 y 或 n${NC}"
                ;;
        esac
    done

    # 端口验证
    while true; do
        read -p "请输入上游服务器端口: " UPSTREAM_PORT
        if [[ $UPSTREAM_PORT =~ ^[0-9]+$ ]] && [ $UPSTREAM_PORT -ge 1 ] && [ $UPSTREAM_PORT -le 65535 ]; then
            break
        else
            echo -e "${RED}端口号必须为1-65535之间的数字${NC}"
        fi
    done

    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"
    
    # 生成配置
    cat > $CONF_FILE <<EOF
server {
    listen 80;
    server_name ${ALL_DOMAINS[@]};

    location / {
        proxy_pass http://$UPSTREAM_IP:$UPSTREAM_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 配置测试
    if ! nginx -t; then
        echo -e "${RED}Nginx配置测试失败，请检查输入参数${NC}"
        rm -f $CONF_FILE
        return 1
    fi
    systemctl reload nginx

    # 安装Certbot
    if ! command -v certbot &> /dev/null; then
        install_certbot || return 1
    fi

    # 构建certbot命令参数，支持多域名
    local CERTBOT_DOMAINS=""
    for domain in "${ALL_DOMAINS[@]}"; do
        [ -n "$domain" ] && CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
    done

    # 申请证书（添加备用方案）
# 首先尝试使用nginx插件
if certbot --nginx $CERTBOT_DOMAINS --non-interactive --agree-tos --email admin@$DOMAIN --redirect; then
    echo -e "${GREEN}成功使用Nginx插件申请证书${NC}"
else
    echo -e "${YELLOW}Nginx插件失败，尝试使用standalone模式...${NC}"
    # 临时停止nginx释放80端口
    systemctl stop nginx
    
    # 使用standalone模式申请证书
    if certbot certonly --standalone $CERTBOT_DOMAINS --non-interactive --agree-tos --email admin@$DOMAIN; then
        echo -e "${GREEN}成功使用standalone模式申请证书${NC}"
        
        # 更新nginx配置以使用新证书
        for domain in "${ALL_DOMAINS[@]}"; do
            if [ -n "$domain" ]; then
                cat > "/etc/nginx/conf.d/${domain}.conf" <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://$domain\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain;
    
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    
    # SSL优化配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    location / {
        proxy_pass http://$UPSTREAM_IP:$UPSTREAM_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
                break  # 只需要处理主域名
            fi
        done
    else
        echo -e "${RED}证书申请失败，请检查："
        echo -e "1. 域名解析是否正确"
        echo -e "2. 80端口是否开放"
        echo -e "3. 防火墙配置${NC}"
        systemctl start nginx
        return 1
    fi
    
    # 重启nginx
    systemctl start nginx
fi

    # 添加自动续期
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"") | sort -u | crontab -
    echo -e "${GREEN}已配置SSL证书自动续期任务${NC}"
    
    # 最终测试
    echo -e "${YELLOW}正在进行最终配置检查...${NC}"
    curl -I https://$DOMAIN --max-time 10 || echo -e "${RED}访问测试失败，请检查网络和DNS设置${NC}"
    echo -e "${GREEN}配置完成！访问地址：https://$DOMAIN${NC}"
}

# 删除网站配置
delete_site_config() {
    clear
    check_root
    
    # 获取所有配置的域名列表
    echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "当前存在的域名配置列表：${NC}"
    local config_files=(/etc/nginx/conf.d/*.conf)
    
    if [ ${#config_files[@]} -eq 0 ] || [[ "${config_files[0]}" == "/etc/nginx/conf.d/*.conf" ]]; then
        echo -e "${YELLOW}没有找到任何域名配置${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi
    
    # 显示带序号的可选域名
    local i=1
    declare -A domain_map
    for file in "${config_files[@]}"; do
        domain=$(basename "$file" .conf)
        domain_map[$i]=$domain
        echo -e "${GREEN}$i. $domain${NC}"
        ((i++))
    done
    echo -e "${BLUE}▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"
    # 用户选择要删除的配置
    while true; do
        read -p "请输入要删除的配置编号 (或直接输入域名): " INPUT
        if [[ $INPUT =~ ^[0-9]+$ ]]; then
            if [ -n "${domain_map[$INPUT]}" ]; then
                DOMAIN=${domain_map[$INPUT]}
                break
            else
                echo -e "${RED}错误：无效的编号${NC}"
            fi
        else
            # 验证直接输入的域名是否存在
            if [ -f "/etc/nginx/conf.d/${INPUT}.conf" ]; then
                DOMAIN=$INPUT
                break
            else
                echo -e "${RED}错误：域名配置不存在${NC}"
            fi
        fi
    done
    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"
    SSL_CONF="/etc/letsencrypt/live/${DOMAIN}"
    
    # 删除操作保持不变
    if [ -f $CONF_FILE ]; then
        rm -f $CONF_FILE
        echo -e "${YELLOW}已删除配置文件: $CONF_FILE${NC}"
        
        read -p "是否删除SSL证书？(y/n): " DEL_SSL
        if [ "$DEL_SSL" = "y" ]; then
            certbot delete --cert-name $DOMAIN
            rm -rf /etc/letsencrypt/live/$DOMAIN
            rm -rf /etc/letsencrypt/archive/$DOMAIN
            rm -rf /etc/letsencrypt/renewal/${DOMAIN}.conf
            echo -e "${YELLOW}已删除SSL证书相关文件${NC}"
        fi
        
        systemctl reload nginx
        echo -e "${GREEN}配置删除完成${NC}"
    else
        echo -e "${RED}未找到该域名的配置文件${NC}"
    fi
}

# 编辑反向代理配置
edit_proxy_config() {
    clear
    check_root
    
    # 获取所有配置的域名列表
    echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "当前存在的域名配置列表：${NC}"
    local config_files=(/etc/nginx/conf.d/*.conf)
    
    if [ ${#config_files[@]} -eq 0 ] || [[ "${config_files[0]}" == "/etc/nginx/conf.d/*.conf" ]]; then
        echo -e "${YELLOW}没有找到任何域名配置${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi
    
    # 显示带序号的可选域名
    local i=1
    declare -A domain_map
    for file in "${config_files[@]}"; do
        domain=$(basename "$file" .conf)
        domain_map[$i]=$domain
        echo -e "${GREEN}$i. $domain${NC}"
        ((i++))
    done
    echo -e "${BLUE}▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"
    
    # 用户选择要编辑的配置
    while true; do
        read -p "请输入要编辑的配置编号 (或直接输入域名): " INPUT
        if [[ $INPUT =~ ^[0-9]+$ ]]; then
            if [ -n "${domain_map[$INPUT]}" ]; then
                DOMAIN=${domain_map[$INPUT]}
                break
            else
                echo -e "${RED}错误：无效的编号${NC}"
            fi
        else
            # 验证直接输入的域名是否存在
            if [ -f "/etc/nginx/conf.d/${INPUT}.conf" ]; then
                DOMAIN=$INPUT
                break
            else
                echo -e "${RED}错误：域名配置不存在${NC}"
            fi
        fi
    done
    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"
    
    # 显示当前配置信息
    echo -e "${YELLOW}当前配置信息:${NC}"
    current_upstream=$(grep -oP "proxy_pass http://\K[^:]+(?=:[0-9]+)" "$CONF_FILE")
    current_port=$(grep -oP "proxy_pass http://[^:]+:\K[0-9]+" "$CONF_FILE")
    
    echo "上游IP: $current_upstream"
    echo "上游端口: $current_port"
    
    # 询问修改项
    echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "请选择要修改的项目:${NC}"
    echo "1. 上游IP地址"
    echo "2. 上游端口"
    echo "3. 两者都修改"
    echo "4. 返回主菜单"
    
    read -p "请输入选项: " EDIT_CHOICE
    
    case $EDIT_CHOICE in
        1)
            while true; do
                read -p "请输入新的上游IP地址: " NEW_IP
                if [[ $NEW_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    sed -i "s|proxy_pass http://$current_upstream:$current_port|proxy_pass http://$NEW_IP:$current_port|g" "$CONF_FILE"
                    break
                else
                    echo -e "${RED}错误：无效的IP地址格式${NC}"
                fi
            done
            ;;
        2)
            while true; do
                read -p "请输入新的上游端口: " NEW_PORT
                if [[ $NEW_PORT =~ ^[0-9]+$ ]] && [ $NEW_PORT -ge 1 ] && [ $NEW_PORT -le 65535 ]; then
                    sed -i "s|proxy_pass http://$current_upstream:$current_port|proxy_pass http://$current_upstream:$NEW_PORT|g" "$CONF_FILE"
                    break
                else
                    echo -e "${RED}端口号必须为1-65535之间的数字${NC}"
                fi
            done
            ;;
        3)
            while true; do
                read -p "请输入新的上游IP地址: " NEW_IP
                if [[ $NEW_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    break
                else
                    echo -e "${RED}错误：无效的IP地址格式${NC}"
                fi
            done
            
            while true; do
                read -p "请输入新的上游端口: " NEW_PORT
                if [[ $NEW_PORT =~ ^[0-9]+$ ]] && [ $NEW_PORT -ge 1 ] && [ $NEW_PORT -le 65535 ]; then
                    break
                else
                    echo -e "${RED}端口号必须为1-65535之间的数字${NC}"
                fi
            done
            
            sed -i "s|proxy_pass http://$current_upstream:$current_port|proxy_pass http://$NEW_IP:$NEW_PORT|g" "$CONF_FILE"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效的选项${NC}"
            return
            ;;
    esac
    
    # 配置测试
    if ! nginx -t; then
        echo -e "${RED}Nginx配置测试失败，正在回滚更改...${NC}"
        sed -i "s|proxy_pass http://.*|proxy_pass http://$current_upstream:$current_port|g" "$CONF_FILE"
        return 1
    fi
    
    systemctl reload nginx
    echo -e "${GREEN}配置已更新并重载${NC}"
}

# 查看Nginx日志
view_nginx_logs() {
    clear
    check_root
    
    echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "选择要查看的日志类型:${NC}"
    echo "1. 错误日志"
    echo "2. 访问日志"
    echo "3. 返回主菜单"
    
    read -p "请输入选项: " LOG_CHOICE
    
    case $LOG_CHOICE in
        1)
            if [ -f /var/log/nginx/error.log ]; then
                echo -e "${YELLOW}显示最近100行错误日志:${NC}"
                tail -n 100 /var/log/nginx/error.log | less
            else
                echo -e "${RED}错误日志文件不存在${NC}"
            fi
            ;;
        2)
            if [ -f /var/log/nginx/access.log ]; then
                echo -e "${YELLOW}显示最近100行访问日志:${NC}"
                tail -n 100 /var/log/nginx/access.log | less
            else
                echo -e "${RED}访问日志文件不存在${NC}"
            fi
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}无效的选项${NC}"
            ;;
    esac
}

# 完全卸载Nginx
uninstall_nginx() {
    clear
    check_root
    echo -e "${RED}警告：这将完全删除Nginx及其所有配置！${NC}"
    read -p "确认完全卸载？(y/n): " CONFIRM
    
    if [ "$CONFIRM" = "y" ]; then
        # 停止服务
        systemctl stop nginx
        systemctl disable nginx
        
        # 卸载软件包（保持原有包管理器判断）
        if command -v apt-get &> /dev/null; then
            apt purge nginx -y
        elif command -v yum &> /dev/null; then
            yum remove nginx -y
        fi
        
        # 仅删除用户生成的配置文件（保留核心目录）
        rm -rf /etc/nginx/conf.d/*.conf
        rm -rf /var/www/html/*
        
        # 删除证书文件
        rm -rf /etc/letsencrypt/live/*
        rm -rf /etc/letsencrypt/archive/*
        rm -rf /etc/letsencrypt/renewal/*
        
        # 删除定时任务
        crontab -l | grep -v 'certbot renew' | crontab -
        
        echo -e "${GREEN}Nginx已完全卸载，相关配置已清理${NC}"
    else
        echo -e "${YELLOW}取消卸载操作${NC}"
    fi
}


# 查看配置列表
list_configs() {
    clear
    check_root
    echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "当前Nginx配置文件列表：${NC}"
    find /etc/nginx/conf.d/ -name "*.conf" -exec ls -lh {} \;
    
    echo -e "\n${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "SSL证书到期信息：${NC}"
    certbot certificates 2>/dev/null | awk '/Certificate Name|Domains|Expiry Date/'
    
    echo -e "\n${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo -e "活动网络连接：${NC}"
    ss -tulpn | grep nginx
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
        echo -e "                    Nginx 管理工具 v3.0"
        echo -e "▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▔▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁${NC}"
        echo -e "${GREEN}1. 安装/更新Nginx"
        echo -e "2. 配置反向代理"
        echo -e "3. 删除网站配置"
        echo -e "4. 编辑代理配置"
        echo -e "5. 查看日志"
        echo -e "6. 配置列表"
        echo -e "${RED}7. 完全卸载"
        echo -e "${YELLOW}0. 退出${NC}"
        echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔${NC}"

        read -p "请输入选项: " choice
        case $choice in
            1) install_nginx ;;
            2) setup_reverse_proxy ;;
            3) delete_site_config ;;
            4) edit_proxy_config ;;
            5) view_nginx_logs ;;
            6) list_configs ;;
            7) uninstall_nginx ;;
            0) 
                echo -e "${YELLOW}退出脚本...${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# 脚本入口
main_menu
