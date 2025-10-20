#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
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
    BACKUP_FILE="/etc/gai.conf.bak"
    
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
        local ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
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
            local result=$(getent ahosts "$test_host" 2>/dev/null | head -1)
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
        echo -e "5. 禁用IPv6"
        echo -e "6. 恢复IPv6"
        echo -e "7. 自动配置IPv6"
        echo -e "\n${CYAN}[其他]${NC}"
        echo -e "4. 查看详细配置"
        echo -e "0. 返回主菜单"
        
        show_current_status
        
        echo ""
        read -p "请输入选项 [0-7]: " choice
    }
    
    # 应用IPv4优先配置
    apply_ipv4_preference() {
        echo -e "${YELLOW}\n[1/3] 备份原配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            cp -f "$CONF_FILE" "$BACKUP_FILE" 2>/dev/null || true
            echo -e "  ▸ 已备份到 $BACKUP_FILE"
        else
            echo -e "  ▸ 原配置文件不存在，跳过备份"
        fi
        
        echo -e "${YELLOW}[2/3] 生成新配置...${NC}"
        cat > "$CONF_FILE" << EOF
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
        echo -e "${YELLOW}\n[1/3] 备份原配置...${NC}"
        if [ -f "$CONF_FILE" ]; then
            cp -f "$CONF_FILE" "$BACKUP_FILE" 2>/dev/null || true
            echo -e "  ▸ 已备份到 $BACKUP_FILE"
        else
            echo -e "  ▸ 原配置文件不存在，跳过备份"
        fi
        
        echo -e "${YELLOW}[2/3] 生成新配置...${NC}"
        cat > "$CONF_FILE" << EOF
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
                rm -f "$CONF_FILE"
                echo -e "  ▸ ${GREEN}已删除配置文件，将使用系统默认${NC}"
            fi
        else
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
        echo -e "${YELLOW}\n正在禁用IPv6...${NC}"
        
        echo -e "  ▸ [1/3] 配置sysctl参数..."
        # 临时禁用
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
        
        echo -e "  ▸ [2/3] 写入持久化配置..."
        # 持久化配置
        local sysctl_conf="/etc/sysctl.d/99-disable-ipv6.conf"
        cat > "$sysctl_conf" << 'EOF'
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        
        echo -e "  ▸ [3/3] 应用配置..."
        sysctl -p "$sysctl_conf" >/dev/null 2>&1
        
        # 验证
        local status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$status" = "1" ]; then
            echo -e "\n${GREEN}✅ IPv6已成功禁用！${NC}"
            echo -e "${YELLOW}提示：${NC}"
            echo -e "  • 配置立即生效且重启后保持"
            echo -e "  • 已禁用所有网卡的IPv6功能"
            echo -e "  • 可以使用 'ip -6 addr' 验证（应该没有IPv6地址）"
        else
            echo -e "\n${RED}❌ IPv6禁用失败${NC}"
        fi
    }
    
    # 恢复IPv6
    enable_ipv6() {
        echo -e "${YELLOW}\n正在恢复IPv6...${NC}"
        
        echo -e "  ▸ [1/3] 配置sysctl参数..."
        # 临时启用
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
        
        echo -e "  ▸ [2/3] 删除持久化配置..."
        # 删除禁用配置文件
        rm -f /etc/sysctl.d/99-disable-ipv6.conf
        
        echo -e "  ▸ [3/3] 重新加载网络配置..."
        # 尝试重启网络服务
        if systemctl is-active --quiet NetworkManager; then
            systemctl restart NetworkManager 2>/dev/null || true
        elif systemctl is-active --quiet networking; then
            systemctl restart networking 2>/dev/null || true
        fi
        
        # 验证
        local status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
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
        echo -e "${YELLOW}\n自动配置IPv6...${NC}"
        
        # 检查IPv6是否已禁用
        local ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$ipv6_disabled" = "1" ]; then
            echo -e "${RED}错误：IPv6当前已禁用，请先恢复IPv6${NC}"
            return 1
        fi
        
        echo -e "  ▸ [1/4] 检测网络接口..."
        # 获取主要网络接口
        local main_iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
        if [ -z "$main_iface" ]; then
            echo -e "${RED}无法检测到主网络接口${NC}"
            return 1
        fi
        echo -e "     检测到主接口: ${GREEN}$main_iface${NC}"
        
        echo -e "  ▸ [2/4] 配置IPv6自动配置参数..."
        # 启用IPv6自动配置
        sysctl -w net.ipv6.conf.$main_iface.autoconf=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.$main_iface.accept_ra=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1
        
        echo -e "  ▸ [3/4] 写入持久化配置..."
        local sysctl_conf="/etc/sysctl.d/98-ipv6-autoconfig.conf"
        cat > "$sysctl_conf" << EOF
# IPv6 Auto Configuration
net.ipv6.conf.$main_iface.autoconf = 1
net.ipv6.conf.$main_iface.accept_ra = 1
net.ipv6.conf.all.forwarding = 0
EOF
        sysctl -p "$sysctl_conf" >/dev/null 2>&1
        
        echo -e "  ▸ [4/4] 触发IPv6地址获取..."
        # 尝试重启网络接口以触发IPv6配置
        if command -v dhclient >/dev/null 2>&1; then
            dhclient -6 $main_iface 2>/dev/null || true
        fi
        
        # 等待一下让IPv6地址生成
        sleep 2
        
        # 显示IPv6地址
        echo -e "\n${GREEN}✅ IPv6自动配置已完成！${NC}"
        echo -e "\n${YELLOW}当前IPv6地址：${NC}"
        ip -6 addr show $main_iface | grep -E 'inet6' | awk '{print "  ▸ " $2}' || echo -e "  ▸ ${YELLOW}尚未获取到IPv6地址${NC}"
        
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
                show_detailed_config
                ;;
            5)
                disable_ipv6
                echo -e "\n按回车键继续..."
                read -r
                ;;
            6)
                enable_ipv6
                echo -e "\n按回车键继续..."
                read -r
                ;;
            7)
                auto_config_ipv6
                echo -e "\n按回车键继续..."
                read -r
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
