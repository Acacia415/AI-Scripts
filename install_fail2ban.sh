#!/bin/bash
# Fail2Ban 交互式管理脚本（启用 SSH 防护 + 自定义参数 + 白名单 + 启动检测）
# 适用系统：Debian / Ubuntu

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${GREEN}     Fail2Ban 管理脚本${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""
    echo "  1. 安装 Fail2Ban"
    echo "  2. 卸载 Fail2Ban"
    echo "  3. 管理封禁列表"
    echo "  0. 退出"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
}

# 安装 Fail2Ban
install_fail2ban() {
    clear
    echo -e "${GREEN}==== Fail2Ban SSH 防护安装 ====${NC}"
    echo ""
    
    # 检查是否已安装
    if command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}检测到 Fail2Ban 已安装${NC}"
        read -p "是否重新配置？(y/n): " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            echo "取消安装"
            read -p "按回车键返回主菜单..."
            return
        fi
    fi
    
    # 输入参数
    echo -e "${BLUE}请配置 Fail2Ban 参数：${NC}"
    read -p "请输入封禁时间 (秒, 默认600=10分钟): " BANTIME
    read -p "请输入检测时间窗口 (秒, 默认600=10分钟): " FINDTIME
    read -p "请输入最大失败次数 (默认5): " MAXRETRY
    read -p "请输入白名单IP (多个用空格分隔，直接回车跳过): " IGNOREIPS
    
    # 设置默认值
    BANTIME=${BANTIME:-600}
    FINDTIME=${FINDTIME:-600}
    MAXRETRY=${MAXRETRY:-5}
    IGNOREIPS=${IGNOREIPS:-127.0.0.1/8}
    
    echo ""
    echo -e "${GREEN}使用配置: 封禁时间=${BANTIME}s, 检测窗口=${FINDTIME}s, 最大失败次数=${MAXRETRY}, 白名单IP=${IGNOREIPS}${NC}"
    echo ""
    read -p "确认安装？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消安装"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    echo -e "${GREEN}==== 更新系统并安装 Fail2Ban ====${NC}"
    sudo apt update -y
    sudo apt install fail2ban python3-systemd -y
    
    echo ""
    echo -e "${GREEN}==== 生成 jail.local 配置文件 ====${NC}"
    cat << EOF | sudo tee /etc/fail2ban/jail.local > /dev/null
[DEFAULT]
# 封禁时间
bantime = ${BANTIME}
# 检测时间窗口
findtime = ${FINDTIME}
# 最大失败次数
maxretry = ${MAXRETRY}
# 白名单 IP（不会被封禁）
ignoreip = ${IGNOREIPS}

[sshd]
enabled = true
mode = extra
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
EOF
    
    echo "配置已生成（使用 systemd backend）"
    
    echo -e "${GREEN}配置文件已生成${NC}"
    echo ""
    echo "生成的配置内容："
    cat /etc/fail2ban/jail.local
    echo ""
    echo -e "${GREEN}==== 启动并设置开机自启 Fail2Ban ====${NC}"
    
    # 停止旧服务
    sudo systemctl stop fail2ban 2>/dev/null || true
    sleep 1
    
    # 重新启动
    sudo systemctl enable --now fail2ban
    
    # 等待 Fail2Ban 启动完成
    echo "等待 Fail2Ban 启动..."
    sleep 5
    
    # 检测服务是否运行
    if sudo systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}Fail2Ban 服务已启动成功！${NC}"
        echo ""
        echo "SSH jail 状态如下："
        sudo fail2ban-client status sshd
    else
        echo -e "${RED}Fail2Ban 启动失败，请查看日志排查：${NC}"
        sudo journalctl -u fail2ban -n 50 --no-pager
    fi
    
    echo ""
    echo -e "${GREEN}==== 安装完成 ====${NC}"
    read -p "按回车键返回主菜单..."
}

# 卸载 Fail2Ban
uninstall_fail2ban() {
    clear
    echo -e "${YELLOW}==== 卸载 Fail2Ban ====${NC}"
    echo ""
    
    # 检查是否已安装
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${YELLOW}Fail2Ban 未安装${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo -e "${RED}警告：此操作将完全移除 Fail2Ban 及其配置文件${NC}"
    read -p "确认卸载？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    echo -e "${GREEN}正在停止 Fail2Ban 服务...${NC}"
    sudo systemctl stop fail2ban 2>/dev/null || true
    sudo systemctl disable fail2ban 2>/dev/null || true
    
    echo -e "${GREEN}正在卸载 Fail2Ban...${NC}"
    sudo apt remove --purge fail2ban -y
    sudo apt autoremove -y
    
    # 删除配置文件
    if [ -d "/etc/fail2ban" ]; then
        echo -e "${GREEN}正在删除配置文件...${NC}"
        sudo rm -rf /etc/fail2ban
    fi
    
    echo ""
    echo -e "${GREEN}==== 卸载完成 ====${NC}"
    read -p "按回车键返回主菜单..."
}

# 管理封禁列表
manage_bans() {
    while true; do
        clear
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo -e "${GREEN}     管理封禁列表${NC}"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo ""
        
        # 检查 Fail2Ban 是否运行
        if ! sudo systemctl is-active --quiet fail2ban 2>/dev/null; then
            echo -e "${RED}Fail2Ban 服务未运行${NC}"
            read -p "按回车键返回主菜单..."
            return
        fi
        
        echo "  1. 查看所有 jail 状态"
        echo "  2. 查看 SSH 封禁列表"
        echo "  3. 解封指定 IP"
        echo "  4. 手动封禁 IP"
        echo "  5. 查看白名单"
        echo "  6. 添加白名单 IP"
        echo "  7. 查看 Fail2Ban 日志"
        echo "  0. 返回主菜单"
        echo ""
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        read -p "请选择操作 [0-7]: " ban_choice
        
        case $ban_choice in
            1)
                clear
                echo -e "${GREEN}==== 所有 Jail 状态 ====${NC}"
                echo ""
                sudo fail2ban-client status
                echo ""
                read -p "按回车键继续..."
                ;;
            2)
                clear
                echo -e "${GREEN}==== SSH 封禁列表 ====${NC}"
                echo ""
                sudo fail2ban-client status sshd
                echo ""
                read -p "按回车键继续..."
                ;;
            3)
                clear
                echo -e "${GREEN}==== 解封 IP ====${NC}"
                echo ""
                sudo fail2ban-client status sshd
                echo ""
                read -p "请输入要解封的 IP 地址: " unban_ip
                if [ -n "$unban_ip" ]; then
                    sudo fail2ban-client set sshd unbanip $unban_ip
                    echo -e "${GREEN}IP $unban_ip 已解封${NC}"
                else
                    echo -e "${RED}IP 地址不能为空${NC}"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                clear
                echo -e "${GREEN}==== 手动封禁 IP ====${NC}"
                echo ""
                read -p "请输入要封禁的 IP 地址: " ban_ip
                if [ -n "$ban_ip" ]; then
                    sudo fail2ban-client set sshd banip $ban_ip
                    echo -e "${GREEN}IP $ban_ip 已被封禁${NC}"
                else
                    echo -e "${RED}IP 地址不能为空${NC}"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            5)
                clear
                echo -e "${GREEN}==== 查看白名单 ====${NC}"
                echo ""
                if [ -f "/etc/fail2ban/jail.local" ]; then
                    echo "当前白名单配置："
                    grep "ignoreip" /etc/fail2ban/jail.local
                else
                    echo -e "${RED}配置文件不存在${NC}"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            6)
                clear
                echo -e "${GREEN}==== 添加白名单 IP ====${NC}"
                echo ""
                echo "当前白名单配置："
                grep "ignoreip" /etc/fail2ban/jail.local 2>/dev/null || echo "无"
                echo ""
                read -p "请输入要添加的白名单 IP (多个用空格分隔): " whitelist_ip
                if [ -n "$whitelist_ip" ]; then
                    # 读取当前白名单
                    current_ips=$(grep "ignoreip" /etc/fail2ban/jail.local | cut -d'=' -f2 | xargs)
                    new_ips="$current_ips $whitelist_ip"
                    # 更新配置文件
                    sudo sed -i "s/ignoreip = .*/ignoreip = $new_ips/" /etc/fail2ban/jail.local
                    echo -e "${GREEN}白名单已更新，正在重启 Fail2Ban...${NC}"
                    sudo systemctl restart fail2ban
                    sleep 2
                    echo -e "${GREEN}白名单更新完成${NC}"
                else
                    echo -e "${RED}IP 地址不能为空${NC}"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            7)
                clear
                echo -e "${GREEN}==== Fail2Ban 日志 (最近50条) ====${NC}"
                echo ""
                sudo journalctl -u fail2ban -n 50 --no-pager
                echo ""
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主循环
main() {
    while true; do
        show_menu
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1)
                install_fail2ban
                ;;
            2)
                uninstall_fail2ban
                ;;
            3)
                manage_bans
                ;;
            0)
                clear
                echo -e "${GREEN}感谢使用 Fail2Ban 管理脚本！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
