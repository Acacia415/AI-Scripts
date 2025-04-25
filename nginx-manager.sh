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

# 安装Certbot
install_certbot() {
    echo -e "${YELLOW}正在安装Certbot...${NC}"
    
    # 自动选择安装方式
    if command -v apt-get &> /dev/null; then
        apt-get install -y certbot python3-certbot-nginx
    elif command -v yum &> /dev/null; then
        yum install -y certbot python3-certbot-nginx
    else
        echo -e "${YELLOW}使用pip进行安装...${NC}"
        python3 -m ensurepip --default-pip
        pip install certbot-nginx
    fi

    # 验证安装
    if ! command -v certbot &> /dev/null; then
        echo -e "${RED}Certbot安装失败，请手动安装：https://certbot.eff.org/${NC}"
        return 1
    fi
}

# 安装/更新Nginx
install_nginx() {
    clear
    check_root
    echo -e "${YELLOW}正在安装依赖...${NC}"
    
    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi

    case $OS in
        debian|ubuntu)
            apt update
            apt install -y curl wget gnupg2 ca-certificates lsb-release
            echo "deb http://nginx.org/packages/$OS `lsb_release -cs` nginx" | tee /etc/apt/sources.list.d/nginx.list
            curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
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
    
    # 增强版错误处理
    if ! systemctl is-active --quiet nginx; then
        echo -e "${RED}启动失败，执行深度修复...${NC}"
        
        # 日志分析
        local error_log=$(journalctl -u nginx -n 50 | grep -iE 'error|failed')
        echo -e "${YELLOW}关键错误摘要：\n$error_log${NC}"
        
        # 端口冲突解决
        sudo fuser -k 80/tcp 443/tcp
        
        # 配置重置
        sudo rm -f /etc/nginx/conf.d/*
        sudo mkdir -p /var/log/nginx
        sudo chown -R nginx:nginx /var/log/nginx
        cat <<EOF | sudo tee /etc/nginx/nginx.conf
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

# 配置反向代理
setup_reverse_proxy() {
    clear
    check_root
    read -p "请输入域名 (例如 example.com): " DOMAIN
    
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
    server_name $DOMAIN;

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

    # 申请证书
    if ! certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN --redirect; then
        echo -e "${RED}证书申请失败，请检查："
        echo -e "1. 域名解析是否正确"
        echo -e "2. 80端口是否开放"
        echo -e "3. 防火墙配置${NC}"
        return 1
    fi

    # 添加自动续期
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
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
    
    if [ ${#config_files[@]} -eq 0 ]; then
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
        
        # 卸载软件包
        if [ -f /etc/debian_version ]; then
            apt purge nginx* -y
        elif [ -f /etc/redhat-release ]; then
            yum remove nginx -y
        fi
        
        # 清理文件
        rm -rf /etc/nginx /var/log/nginx /var/www/html/* /usr/lib/nginx
        rm -rf /root/.cache/letsencrypt /etc/letsencrypt
        
        # 删除定时任务
        crontab -l | grep -v 'certbot renew' | crontab -
        
        echo -e "${GREEN}Nginx已完全卸载，相关目录已清理${NC}"
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
        echo -e "                    Nginx 管理工具 v2.2"
        echo -e "▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁${NC}"
        echo -e "1. 安装/更新Nginx"
        echo -e "2. 配置反向代理+SSL"
        echo -e "3. 删除网站配置"
        echo -e "4. 完全卸载Nginx"
        echo -e "5. 查看配置列表"
        echo -e "0. 退出"
        echo -e "${BLUE}▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁${NC}"
        
        read -p "请输入选项数字: " CHOICE
        case $CHOICE in
            1) install_nginx ;;
            2) setup_reverse_proxy ;;
            3) delete_site_config ;;
            4) uninstall_nginx ;;
            5) list_configs | less -R ;;
            0) 
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选项，请重新输入${NC}"
                ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# 启动脚本
check_root
main_menu
