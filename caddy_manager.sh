#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= Caddy反代管理 =======================
configure_caddy_reverse_proxy() {
    # 环境常量定义
    local CADDY_SERVICE="/lib/systemd/system/caddy.service"
    local CADDYFILE="/etc/caddy/Caddyfile"
    local TEMP_CONF=$(mktemp)
    local domain ip port

    # 首次安装检测
    if ! command -v caddy &>/dev/null; then
        echo -e "${CYAN}开始安装Caddy服务器...${NC}"
        
        # 安装依赖组件（显示进度）
        echo -e "${YELLOW}[1/5] 安装依赖组件...${NC}"
        sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https 2>&1 | \
            while read line; do 
                echo "  ▸ $line"
            done
        
        # 添加官方软件源（显示进度）
        echo -e "\n${YELLOW}[2/5] 添加Caddy官方源...${NC}"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
            sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
            sudo tee /etc/apt/sources.list.d/caddy-stable.list | \
            sed 's/^/  ▸ /'
        # 更新软件源（显示进度）
        echo -e "\n${YELLOW}[3/5] 更新软件源...${NC}"
        sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/caddy-stable.list" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" 2>&1 | \
            grep -v '^$' | \
            sed 's/^/  ▸ /'
        # 安装Caddy（显示进度）
        echo -e "\n${YELLOW}[4/5] 安装Caddy...${NC}"
        sudo apt-get install -y caddy 2>&1 | \
            grep --line-buffered -E 'Unpacking|Setting up' | \
            sed 's/^/  ▸ /'
        # 初始化配置（显示进度）
        echo -e "\n${YELLOW}[5/5] 初始化配置...${NC}"
        sudo mkdir -vp /etc/caddy | sed 's/^/  ▸ /'
        [ ! -f "$CADDYFILE" ] && sudo touch "$CADDYFILE"
        echo -e "# Caddyfile自动生成配置\n# 手动修改后请执行 systemctl reload caddy" | \
            sudo tee "$CADDYFILE" | sed 's/^/  ▸ /'
        sudo chown caddy:caddy "$CADDYFILE"
        
        echo -e "${GREEN}✅ Caddy安装完成，版本：$(caddy version)${NC}"
    else
        echo -e "${CYAN}检测到Caddy已安装，版本：$(caddy version)${NC}"
    fi

    # 配置输入循环
    while : ; do
        # 域名输入验证
        until [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; do
            read -p "请输入域名（无需https://）：" domain
            domain=$(echo "$domain" | sed 's/https\?:\/\///g')
            [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || echo -e "${RED}域名格式无效！示例：example.com${NC}"
        done

        # 目标IP输入（支持域名/IPv4/IPv6）
        read -p "请输入目标服务器地址（默认为localhost）:" ip
        ip=${ip:-localhost}

        # 端口输入验证
        until [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 -a "$port" -le 65535 ]; do
            read -p "请输入目标端口号（1-65535）:" port
            [[ $port =~ ^[0-9]+$ ]] || { echo -e "${RED}端口必须为数字！"; continue; }
            [ "$port" -ge 1 -a "$port" -le 65535 ] || echo -e "${RED}端口范围1-65535！"
        done

        # 配置冲突检测
        if sudo caddy validate --config "$CADDYFILE" --adapter caddyfile 2>/dev/null; then
            if grep -q "^$domain {" "$CADDYFILE"; then
                echo -e "${YELLOW}⚠ 检测到现有配置："
                grep -A3 "^$domain {" "$CADDYFILE"
                read -p "要覆盖此配置吗？[y/N] " overwrite
                [[ $overwrite =~ ^[Yy]$ ]] || continue
                sudo caddy adapt --config "$CADDYFILE" --adapter caddyfile | \
                awk -v domain="$domain" '/^'$domain' {/{flag=1} !flag; /^}/{flag=0}' | \
                sudo tee "$TEMP_CONF" >/dev/null
                sudo mv "$TEMP_CONF" "$CADDYFILE"
            fi
        else
            echo -e "${YELLOW}⚠ 当前配置文件存在错误，将创建新配置${NC}"
            sudo truncate -s 0 "$CADDYFILE"
        fi

        # 生成配置块
        echo -e "\n# 自动生成配置 - $(date +%F)" | sudo tee -a "$CADDYFILE" >/dev/null
        cat <<EOF | sudo tee -a "$CADDYFILE" >/dev/null
$domain {
    reverse_proxy $ip:$port {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    }
}
EOF

        # 格式化配置文件
        sudo caddy fmt "$CADDYFILE" --overwrite

        # 配置验证与生效
        if ! sudo caddy validate --config "$CADDYFILE"; then
            echo -e "${RED}配置验证失败！错误详情："
            sudo caddy validate --config "$CADDYFILE" 2>&1 | grep -v "valid"
            sudo sed -i "/# 自动生成配置 - $(date +%F)/,+6d" "$CADDYFILE"
            return 1
        fi

        # 服务热重载
        if systemctl is-active caddy &>/dev/null; then
            sudo systemctl reload caddy || sudo systemctl restart caddy
        else
            sudo systemctl enable --now caddy &>/dev/null
        fi

        echo -e "${GREEN}✅ 配置生效成功！访问地址：https://$domain${NC}"
        read -p "是否继续添加配置？[y/N] " more
        [[ $more =~ ^[Yy]$ ]] || break

        # 重置变量进行下一轮循环
        domain=""
        ip=""
        port=""
    done

    # 清理临时文件
    rm -f "$TEMP_CONF"
}

# ======================= 卸载Caddy =======================
uninstall_caddy() {
    echo -e "${RED}警告：此操作将完全移除Caddy及所有相关配置！${NC}"
    read -p "确定要卸载Caddy吗？(y/N) " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return

    # 停止服务
    echo -e "${CYAN}停止Caddy服务...${NC}"
    sudo systemctl stop caddy.service 2>/dev/null

    # 卸载软件包
    if command -v caddy &>/dev/null; then
        echo -e "${CYAN}卸载Caddy程序...${NC}"
        sudo apt-get purge -y caddy 2>/dev/null
    fi

    # 删除配置文件
    declare -a caddy_files=(
        "/etc/caddy"
        "/lib/systemd/system/caddy.service"
        "/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        "/etc/apt/sources.list.d/caddy-stable.list"
        "/var/lib/caddy"
        "/etc/ssl/caddy"
    )

    # 删除文件及目录
    echo -e "${CYAN}清理残留文件...${NC}"
    for target in "${caddy_files[@]}"; do
        if [[ -e $target ]]; then
            echo "删除：$target"
            sudo rm -rf "$target"
        fi
    done

    # 删除APT源更新
    sudo apt-get update 2>/dev/null

    # 清除无人值守安装标记（如有）
    sudo rm -f /var/lib/cloud/instances/*/sem/config_apt_source

    # 删除日志（可选）
    read -p "是否删除所有Caddy日志文件？(y/N) " del_log
    if [[ $del_log =~ ^[Yy]$ ]]; then
        sudo journalctl --vacuum-time=1s --quiet
        sudo rm -f /var/log/caddy/*.log 2>/dev/null
    fi

    echo -e "${GREEN}✅ Caddy已完全卸载，再见！${NC}"
}

# ======================= 重启Caddy =======================
restart_caddy() {
    if ! command -v caddy &>/dev/null; then
        echo -e "${RED}错误：Caddy未安装！${NC}"
        return 1
    fi

    # 验证配置文件
    echo -e "${CYAN}验证配置文件...${NC}"
    if ! sudo caddy validate --config /etc/caddy/Caddyfile; then
        echo -e "${RED}配置文件验证失败！请检查配置后再重启。${NC}"
        return 1
    fi

    echo -e "${CYAN}正在重启Caddy服务...${NC}"
    if sudo systemctl restart caddy; then
        sleep 1
        if systemctl is-active caddy &>/dev/null; then
            echo -e "${GREEN}✅ Caddy重启成功！${NC}"
            systemctl status caddy --no-pager -l
        else
            echo -e "${RED}重启后服务未正常运行，请检查日志${NC}"
            sudo journalctl -u caddy -n 20 --no-pager
            return 1
        fi
    else
        echo -e "${RED}Caddy重启失败！${NC}"
        return 1
    fi
}

# ======================= Caddy子菜单 =======================
show_caddy_menu() {
    clear
    echo -e "${CYAN}=== Caddy 管理脚本 v1.2 ===${NC}"
    echo "1. 安装/配置反向代理"
    echo "2. 完全卸载Caddy"
    echo "3. 重启Caddy"
    echo "0. 返回主菜单"
    echo -e "${YELLOW}===============================${NC}"
}

# ======================= Cady主逻辑 =======================
caddy_main() {
    while true; do
        show_caddy_menu
        read -p "请输入Caddy管理选项：" caddy_choice
        case $caddy_choice in
            1) 
                configure_caddy_reverse_proxy
                read -p "按回车键返回菜单..." 
                ;;
            2) 
                uninstall_caddy
                read -p "按回车键返回菜单..." 
                ;;
            3) 
                restart_caddy
                read -p "按回车键返回菜单..." 
                ;;
            0) 
                break
                ;;
            *) 
                echo -e "${RED}无效选项！${NC}"
                sleep 1
                ;;
        esac
    done
}

# 执行函数
caddy_main
