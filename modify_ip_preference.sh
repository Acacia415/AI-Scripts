#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= IP优先级设置 =======================
modify_ip_preference() {
    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi
    
    # 配置文件路径
    CONF_FILE="/etc/gai.conf"
    BACKUP_DIR="/var/backups/ai-scripts/gai-conf"
    BACKUP_FILE="$BACKUP_DIR/original.gai.conf"
    NETWORK_BACKUP_DIR="/var/backups/ai-scripts/ip-preference"
    NETWORK_STATE_DIR="/var/lib/ai-scripts/ip-preference"
    install -d -m 700 "$NETWORK_BACKUP_DIR" "$NETWORK_STATE_DIR"

    backup_gai_conf() {
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        install -d -m 700 "$BACKUP_DIR"
        if [ -f "$CONF_FILE" ]; then
            [ -f "$BACKUP_FILE" ] || cp -a "$CONF_FILE" "$BACKUP_FILE"
            cp -a "$CONF_FILE" "$BACKUP_DIR/gai.conf.$timestamp"
        else
            [ -e "$BACKUP_DIR/original-was-absent" ] || : > "$BACKUP_DIR/original-was-absent"
        fi
    }
    
    # 显示当前状态
    show_current_status() {
        echo -e "\n${YELLOW}当前优先级配置：${NC}"
        
        if [ ! -f "$CONF_FILE" ]; then
            echo -e "  ▸ ${YELLOW}配置文件不存在，使用系统默认（通常IPv6优先）${NC}"
        elif grep -qE "^precedence ::ffff:0:0/96[[:space:]]+100" "$CONF_FILE" 2>/dev/null; then
            echo -e "  ▸ ${GREEN}IPv4优先模式${NC}"
        elif grep -qE "^precedence ::ffff:0:0/96[[:space:]]+10" "$CONF_FILE" 2>/dev/null; then
            echo -e "  ▸ ${GREEN}IPv6优先模式（显式配置）${NC}"
        else
            echo -e "  ▸ ${YELLOW}自定义或默认配置${NC}"
        fi
        
        # 显示IPv6启用状态
        echo -e "\n${YELLOW}IPv6状态：${NC}"
        local ipv6_disabled
        ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
        if [ "$ipv6_disabled" = "1" ]; then
            echo -e "  ▸ ${RED}IPv6已禁用${NC}"
        elif [ "$ipv6_disabled" = "0" ]; then
            echo -e "  ▸ ${GREEN}IPv6已启用${NC}"
        else
            echo -e "  ▸ ${YELLOW}无法检测${NC}"
        fi
        
        # 显示实际测试结果
        echo -e "\n${YELLOW}实际连接测试：${NC}"
        test_connectivity
    }
    
    # 测试实际连接优先级
    test_connectivity() {
        # 测试一个同时支持IPv4和IPv6的域名
        local test_host="www.google.com"
        
        # 尝试获取解析结果
        if command -v getent >/dev/null 2>&1; then
            local result
            result=$(getent ahosts "$test_host" 2>/dev/null | head -1)
            if echo "$result" | grep -q ":"; then
                echo -e "  ▸ 当前系统倾向使用 ${GREEN}IPv6${NC}"
            elif echo "$result" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
                echo -e "  ▸ 当前系统倾向使用 ${GREEN}IPv4${NC}"
            else
                echo -e "  ▸ ${YELLOW}无法确定当前优先级${NC}"
            fi
        else
            echo -e "  ▸ ${YELLOW}无法测试（getent命令不可用）${NC}"
        fi
    }
    
    # 交互式菜单
    interactive_menu() {
        clear
        echo -e "${GREEN}=== IP协议优先级设置 ===${NC}"
        echo -e "\n${CYAN}[优先级配置]${NC}"
        echo -e "1. 设置IPv4优先 (推荐)"
        echo -e "2. 设置IPv6优先"
        echo -e "3. 恢复系统默认"
        echo -e "\n${CYAN}[IPv6管理]${NC}"
        echo -e "4. 禁用IPv6"
        echo -e "5. 恢复IPv6"
        echo -e "6. 自动配置IPv6"
        echo -e "\n${CYAN}[其他]${NC}"
        echo -e "7. 查看详细配置"
        echo -e "0. 返回主菜单"
        
        show_current_status
        
        echo ""
        read -p "请输入选项 [0-7]: " choice
    }
    
    # 应用IPv4优先配置
    apply_ipv4_preference() {
        local gai_tmp
        echo -e "${YELLOW}\n[1/3] 备份原配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            backup_gai_conf
            echo -e "  ▸ 已备份到 $BACKUP_FILE"
        else
            echo -e "  ▸ 原配置文件不存在，跳过备份"
        fi
        
        echo -e "${YELLOW}[2/3] 生成新配置...${NC}"
        gai_tmp=$(mktemp /etc/.gai.conf.XXXXXX) || return 1
        cat > "$gai_tmp" << EOF
# Configuration for getaddrinfo(3).
#
# This file is managed by the network toolbox script
# Last modified: $(date)
#
# IPv4 preferred configuration

# Label definitions
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
label fec0::/10     5
label fc00::/7      6
label 2001:0::/32   7

# Precedence definitions
# Higher value = higher priority
# Default IPv6 would be 40, we set IPv4-mapped to 100
precedence ::1/128       50
precedence ::/0          40
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 100

# Scope definitions  
scopev4 ::ffff:169.254.0.0/112  2
scopev4 ::ffff:127.0.0.0/104    2
scopev4 ::ffff:0.0.0.0/96       14
EOF
        chmod 644 "$gai_tmp"
        mv -f -- "$gai_tmp" "$CONF_FILE"
        
        echo -e "${YELLOW}[3/3] 验证配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            echo -e "  ▸ ${GREEN}配置文件创建成功${NC}"
            
            # 清除DNS缓存（如果systemd-resolved在运行）
            if systemctl is-active --quiet systemd-resolved; then
                echo -e "  ▸ 清除DNS缓存..."
                systemd-resolve --flush-caches 2>/dev/null || true
            fi
            
            # 如果nscd在运行，重启它
            if systemctl is-active --quiet nscd; then
                echo -e "  ▸ 重启nscd服务..."
                systemctl restart nscd 2>/dev/null || true
            fi
        else
            echo -e "  ▸ ${RED}配置文件创建失败${NC}"
            return 1
        fi
    }
    
    # 应用IPv6优先配置
    apply_ipv6_preference() {
        local gai_tmp
        echo -e "${YELLOW}\n[1/3] 备份原配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            backup_gai_conf
            echo -e "  ▸ 已备份到 $BACKUP_FILE"
        else
            echo -e "  ▸ 原配置文件不存在，跳过备份"
        fi
        
        echo -e "${YELLOW}[2/3] 生成新配置...${NC}"
        gai_tmp=$(mktemp /etc/.gai.conf.XXXXXX) || return 1
        cat > "$gai_tmp" << EOF
# Configuration for getaddrinfo(3).
#
# This file is managed by the network toolbox script
# Last modified: $(date)
#
# IPv6 preferred configuration (explicit)

# Label definitions
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
label fec0::/10     5
label fc00::/7      6
label 2001:0::/32   7

# Precedence definitions
# Higher value = higher priority
# IPv6 set to 40, IPv4-mapped to 10 (lower priority)
precedence ::1/128       50
precedence ::/0          40
precedence 2002::/16     30
precedence ::/96         20
precedence ::ffff:0:0/96 10

# Scope definitions
scopev4 ::ffff:169.254.0.0/112  2
scopev4 ::ffff:127.0.0.0/104    2
scopev4 ::ffff:0.0.0.0/96       14
EOF
        chmod 644 "$gai_tmp"
        mv -f -- "$gai_tmp" "$CONF_FILE"
        
        echo -e "${YELLOW}[3/3] 验证配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            echo -e "  ▸ ${GREEN}配置文件创建成功${NC}"
            
            # 清除DNS缓存
            if systemctl is-active --quiet systemd-resolved; then
                echo -e "  ▸ 清除DNS缓存..."
                systemd-resolve --flush-caches 2>/dev/null || true
            fi
            
            # 重启nscd
            if systemctl is-active --quiet nscd; then
                echo -e "  ▸ 重启nscd服务..."
                systemctl restart nscd 2>/dev/null || true
            fi
        else
            echo -e "  ▸ ${RED}配置文件创建失败${NC}"
            return 1
        fi
    }
    
    # 恢复默认配置
    restore_default() {
        echo -e "${YELLOW}\n恢复默认配置...${NC}"
        
        if [ -f "$BACKUP_FILE" ]; then
            echo -e "  ▸ 发现备份文件，是否从备份恢复？[y/N]: "
            read -r restore_backup
            if [[ "$restore_backup" =~ ^[Yy]$ ]]; then
                cp -f "$BACKUP_FILE" "$CONF_FILE"
                echo -e "  ▸ ${GREEN}已从备份恢复${NC}"
            else
                echo -e "  ${YELLOW}已取消恢复，当前配置保持不变。${NC}"
                return 0
                rm -f "$CONF_FILE"
                echo -e "  ▸ ${GREEN}已删除配置文件，将使用系统默认${NC}"
            fi
        else
            if [ ! -e "$BACKUP_DIR/original-was-absent" ]; then
                echo -e "  ${RED}没有可验证的原始备份，拒绝删除当前配置。${NC}"
                return 1
            fi
            if [ -f "$CONF_FILE" ]; then
                echo -e "  ▸ 删除配置文件..."
                rm -f "$CONF_FILE"
                echo -e "  ▸ ${GREEN}已恢复为系统默认配置${NC}"
            else
                echo -e "  ▸ ${YELLOW}配置文件不存在，已是默认状态${NC}"
            fi
        fi
        
        # 清除缓存
        if systemctl is-active --quiet systemd-resolved; then
            systemd-resolve --flush-caches 2>/dev/null || true
        fi
        if systemctl is-active --quiet nscd; then
            systemctl restart nscd 2>/dev/null || true
        fi
    }
    
    # 禁用IPv6
    disable_ipv6() {
        local operation_backup sysctl_conf sysctl_tmp old_all old_default old_lo status
        echo -e "${YELLOW}\n正在禁用IPv6...${NC}"

        operation_backup="$NETWORK_BACKUP_DIR/disable-$(date +%Y%m%d-%H%M%S)"
        install -d -m 700 "$operation_backup"
        sysctl_conf="/etc/sysctl.d/99-disable-ipv6.conf"
        [[ ! -f "$sysctl_conf" ]] || cp -a "$sysctl_conf" "$operation_backup/99-disable-ipv6.conf"
        old_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
        old_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)
        old_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo 0)

        echo -e "  ▸ [1/3] 写入持久化配置..."
        sysctl_tmp=$(mktemp /etc/sysctl.d/.99-disable-ipv6.XXXXXX) || return 1
        cat > "$sysctl_tmp" << 'EOF'
# Managed by AI-Scripts: disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        chmod 644 "$sysctl_tmp"
        mv -f -- "$sysctl_tmp" "$sysctl_conf"
        touch "$NETWORK_STATE_DIR/owns-disable-ipv6"

        echo -e "  ▸ [2/3] 应用配置..."
        if ! sysctl -p "$sysctl_conf" >/dev/null 2>&1; then
            [[ ! -f "$operation_backup/99-disable-ipv6.conf" ]] || cp -a "$operation_backup/99-disable-ipv6.conf" "$sysctl_conf"
            [[ -f "$operation_backup/99-disable-ipv6.conf" ]] || rm -f "$sysctl_conf"
            sysctl -w "net.ipv6.conf.all.disable_ipv6=$old_all" >/dev/null 2>&1 || true
            sysctl -w "net.ipv6.conf.default.disable_ipv6=$old_default" >/dev/null 2>&1 || true
            sysctl -w "net.ipv6.conf.lo.disable_ipv6=$old_lo" >/dev/null 2>&1 || true
            rm -f "$NETWORK_STATE_DIR/owns-disable-ipv6"
            echo -e "${RED}应用失败，已恢复修改前状态。${NC}"
            return 1
        fi

        echo -e "  ▸ [3/3] 验证配置..."
        status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$status" = "1" ]; then
            echo -e "\n${GREEN}✅ IPv6已成功禁用！${NC}"
            echo -e "${YELLOW}提示：${NC}"
            echo -e "  • 配置立即生效且重启后保持"
            echo -e "  • 已禁用所有网卡的IPv6功能"
            echo -e "  • 可以使用 'ip -6 addr' 验证（应该没有IPv6地址）"
            echo -e "  • 修改前备份：$operation_backup"
        else
            echo -e "\n${RED}❌ IPv6禁用失败${NC}"
        fi
    }
    
    # 恢复IPv6
    enable_ipv6() {
        local status
        echo -e "${YELLOW}\n正在恢复IPv6...${NC}"
        
        echo -e "  ▸ [1/3] 配置sysctl参数..."
        # 临时启用
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
        
        echo -e "  ▸ [2/3] 删除持久化配置..."
        # 仅删除本脚本确认拥有的持久化配置文件。
        if [[ -e "$NETWORK_STATE_DIR/owns-disable-ipv6" ]] && grep -Fqx '# Managed by AI-Scripts: disable IPv6' /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null; then
            cp -a /etc/sysctl.d/99-disable-ipv6.conf "$NETWORK_BACKUP_DIR/enable-$(date +%Y%m%d-%H%M%S).conf" 2>/dev/null || true
            rm -f /etc/sysctl.d/99-disable-ipv6.conf "$NETWORK_STATE_DIR/owns-disable-ipv6"
        elif [[ -f /etc/sysctl.d/99-disable-ipv6.conf ]]; then
            echo -e "  ▸ ${YELLOW}该持久化文件并非本脚本确认创建，已保留。${NC}"
        fi
        
        echo -e "  ▸ [3/3] 重新加载网络配置..."
        # 尝试重启网络服务
        echo -e "  ${YELLOW}为避免 SSH 连接中断，不自动重启网络服务。${NC}"
        
        # 验证
        status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$status" = "0" ]; then
            echo -e "\n${GREEN}✅ IPv6已成功恢复！${NC}"
            echo -e "${YELLOW}提示：${NC}"
            echo -e "  • IPv6功能已重新启用"
            echo -e "  • 网络接口应该会自动获取IPv6地址"
            echo -e "  • 可以使用 'ip -6 addr' 查看IPv6地址"
        else
            echo -e "\n${RED}❌ IPv6恢复失败${NC}"
        fi
    }
    
    # 自动配置IPv6
    auto_config_ipv6() {
        local operation_backup old_autoconf old_accept_ra sysctl_tmp sysctl_conf
        echo -e "${YELLOW}\n自动配置IPv6...${NC}"
        
        # 检查IPv6是否已禁用
        local ipv6_disabled
        ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$ipv6_disabled" = "1" ]; then
            echo -e "${RED}错误：IPv6当前已禁用，请先恢复IPv6${NC}"
            return 1
        fi
        
        echo -e "  ▸ [1/4] 检测网络接口..."
        # 获取主要网络接口
        local main_iface
        main_iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
        if [ -z "$main_iface" ]; then
            echo -e "${RED}无法检测到主网络接口${NC}"
            return 1
        fi
        echo -e "     检测到主接口: ${GREEN}$main_iface${NC}"
        
        echo -e "  ▸ [2/4] 配置IPv6自动配置参数..."
        # 启用IPv6自动配置
        if ! [[ $main_iface =~ ^[a-zA-Z0-9_.:-]+$ ]] || [ ! -d "/sys/class/net/$main_iface" ]; then
            echo -e "${RED}检测到不安全或不存在的网络接口名称，操作已取消。${NC}"
            return 1
        fi
        echo -e "  ▸ [3/4] 写入持久化配置..."
        sysctl_conf="/etc/sysctl.d/98-ipv6-autoconfig.conf"
        operation_backup="$NETWORK_BACKUP_DIR/autoconfig-$(date +%Y%m%d-%H%M%S)"
        install -d -m 700 "$operation_backup"
        [[ ! -f "$sysctl_conf" ]] || cp -a "$sysctl_conf" "$operation_backup/98-ipv6-autoconfig.conf"
        old_autoconf=$(sysctl -n "net.ipv6.conf.${main_iface}.autoconf" 2>/dev/null || echo 0)
        old_accept_ra=$(sysctl -n "net.ipv6.conf.${main_iface}.accept_ra" 2>/dev/null || echo 0)
        sysctl_tmp=$(mktemp /etc/sysctl.d/.98-ipv6-autoconfig.XXXXXX) || return 1
        cat > "$sysctl_tmp" << EOF
# Managed by AI-Scripts: IPv6 auto configuration
net.ipv6.conf.$main_iface.autoconf = 1
net.ipv6.conf.$main_iface.accept_ra = 1
EOF
        chmod 644 "$sysctl_tmp"
        mv -f -- "$sysctl_tmp" "$sysctl_conf"
        if ! sysctl -p "$sysctl_conf" >/dev/null 2>&1; then
            [[ ! -f "$operation_backup/98-ipv6-autoconfig.conf" ]] || cp -a "$operation_backup/98-ipv6-autoconfig.conf" "$sysctl_conf"
            [[ -f "$operation_backup/98-ipv6-autoconfig.conf" ]] || rm -f "$sysctl_conf"
            sysctl -w "net.ipv6.conf.${main_iface}.autoconf=$old_autoconf" >/dev/null 2>&1 || true
            sysctl -w "net.ipv6.conf.${main_iface}.accept_ra=$old_accept_ra" >/dev/null 2>&1 || true
            echo -e "${RED}应用失败，已恢复修改前状态。${NC}"
            return 1
        fi
        
        echo -e "  ▸ [4/4] 触发IPv6地址获取..."
        # 尝试重启网络接口以触发IPv6配置
        if command -v dhclient >/dev/null 2>&1; then
            dhclient -6 "$main_iface" 2>/dev/null || true
        fi
        
        # 等待一下让IPv6地址生成
        sleep 2
        
        # 显示IPv6地址
        echo -e "\n${GREEN}✅ IPv6自动配置已完成！${NC}"
        echo -e "\n${YELLOW}当前IPv6地址：${NC}"
        ip -6 addr show "$main_iface" | grep -E 'inet6' | awk '{print "  ▸ " $2}' || echo -e "  ▸ ${YELLOW}尚未获取到IPv6地址${NC}"
        
        echo -e "\n${YELLOW}提示：${NC}"
        echo -e "  • 已启用SLAAC（无状态地址自动配置）"
        echo -e "  • 如果路由器支持IPv6，将自动获取地址"
        echo -e "  • 链路本地地址(fe80::)会立即生成"
        echo -e "  • 全局地址可能需要几秒钟时间"
    }
    
    # 查看详细配置
    show_detailed_config() {
        echo -e "\n${YELLOW}=== 详细配置信息 ===${NC}"
        
        if [ -f "$CONF_FILE" ]; then
            echo -e "\n${GREEN}当前 /etc/gai.conf 内容：${NC}"
            echo "----------------------------------------"
            cat "$CONF_FILE"
            echo "----------------------------------------"
        else
            echo -e "${YELLOW}配置文件不存在，使用系统默认设置${NC}"
        fi
        
        echo -e "\n${GREEN}测试解析结果：${NC}"
        for host in "www.google.com" "www.cloudflare.com" "www.github.com"; do
            echo -e "\n  测试 $host:"
            if command -v getent >/dev/null 2>&1; then
                getent ahosts "$host" 2>/dev/null | head -3 | while read -r line; do
                    echo "    $line"
                done
            else
                echo "    ${YELLOW}getent 命令不可用${NC}"
            fi
        done
        
        echo -e "\n${YELLOW}按回车键继续...${NC}"
        read -r
    }
    
    # 主循环
    while true; do
        interactive_menu
        
        case $choice in
            1)
                apply_ipv4_preference
                echo -e "${GREEN}\n✅ 已设置为IPv4优先模式！${NC}"
                echo -e "${YELLOW}提示：${NC}"
                echo -e "  • 更改立即生效"
                echo -e "  • 部分应用可能需要重启才能应用新设置"
                echo -e "  • 可以使用 'curl -4 ifconfig.me' 测试IPv4连接"
                echo -e "\n按回车键继续..."
                read -r
                ;;
            2)
                apply_ipv6_preference
                echo -e "${GREEN}\n✅ 已设置为IPv6优先模式！${NC}"
                echo -e "${YELLOW}提示：${NC}"
                echo -e "  • 更改立即生效"
                echo -e "  • 部分应用可能需要重启才能应用新设置"
                echo -e "  • 可以使用 'curl -6 ifconfig.me' 测试IPv6连接"
                echo -e "\n按回车键继续..."
                read -r
                ;;
            3)
                restore_default
                echo -e "${GREEN}\n✅ 操作完成！${NC}"
                echo -e "\n按回车键继续..."
                read -r
                ;;
            4)
                disable_ipv6
                echo -e "\n按回车键继续..."
                read -r
                ;;
            5)
                enable_ipv6
                echo -e "\n按回车键继续..."
                read -r
                ;;
            6)
                auto_config_ipv6
                echo -e "\n按回车键继续..."
                read -r
                ;;
            7)
                show_detailed_config
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 执行函数
modify_ip_preference
