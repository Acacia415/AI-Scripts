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
        echo -e "1. 设置IPv4优先 (推荐)"
        echo -e "2. 设置IPv6优先"
        echo -e "3. 恢复系统默认"
        echo -e "4. 查看详细配置"
        echo -e "0. 返回主菜单"
        
        show_current_status
        
        echo ""
        read -p "请输入选项 [0-4]: " choice
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
        cat > "$CONF_FILE" << 'EOF'
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
        cat > "$CONF_FILE" << 'EOF'
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
