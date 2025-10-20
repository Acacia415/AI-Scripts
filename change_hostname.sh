#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用root权限运行此脚本${NC}"
        exit 1
    fi
}

# 显示当前主机名
show_current_hostname() {
    local current_hostname=$(hostname)
    echo -e "${BLUE}========================${NC}"
    echo -e "${GREEN}当前主机名: ${YELLOW}${current_hostname}${NC}"
    echo -e "${BLUE}========================${NC}"
}

# 验证主机名格式
validate_hostname() {
    local hostname=$1
    
    # 主机名长度检查 (1-63字符)
    if [ ${#hostname} -lt 1 ] || [ ${#hostname} -gt 63 ]; then
        echo -e "${RED}错误: 主机名长度必须在1-63个字符之间${NC}"
        return 1
    fi
    
    # 主机名格式检查 (只能包含字母、数字、连字符，不能以连字符开头或结尾)
    if ! [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}错误: 主机名只能包含字母、数字和连字符，且不能以连字符开头或结尾${NC}"
        return 1
    fi
    
    return 0
}

# 更改主机名
change_hostname() {
    local new_hostname=$1
    
    # 临时更改主机名
    hostnamectl set-hostname "$new_hostname" 2>/dev/null || hostname "$new_hostname"
    
    # 永久更改主机名 - 适配不同系统
    # 方法1: 使用 hostnamectl (systemd系统)
    if command -v hostnamectl &> /dev/null; then
        hostnamectl set-hostname "$new_hostname"
    fi
    
    # 方法2: 修改 /etc/hostname
    if [ -f /etc/hostname ]; then
        echo "$new_hostname" > /etc/hostname
    fi
    
    # 方法3: 修改 /etc/sysconfig/network (RHEL/CentOS 6及更早版本)
    if [ -f /etc/sysconfig/network ]; then
        if grep -q "HOSTNAME=" /etc/sysconfig/network; then
            sed -i "s/HOSTNAME=.*/HOSTNAME=$new_hostname/" /etc/sysconfig/network
        else
            echo "HOSTNAME=$new_hostname" >> /etc/sysconfig/network
        fi
    fi
    
    # 更新 /etc/hosts
    update_hosts_file "$new_hostname"
    
    echo -e "${GREEN}主机名已更改为: ${YELLOW}${new_hostname}${NC}"
}

# 更新hosts文件
update_hosts_file() {
    local new_hostname=$1
    local old_hostname=$(grep "127.0.1.1" /etc/hosts | awk '{print $2}')
    
    # 确保127.0.1.1有对应的主机名条目
    if grep -q "127.0.1.1" /etc/hosts; then
        # 更新现有条目
        sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/" /etc/hosts
    else
        # 添加新条目
        echo -e "127.0.1.1\t$new_hostname" >> /etc/hosts
    fi
    
    # 确保127.0.0.1有localhost条目
    if ! grep -q "127.0.0.1.*localhost" /etc/hosts; then
        sed -i "1i127.0.0.1\tlocalhost" /etc/hosts
    fi
}

# 主函数
main() {
    check_root
    
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}      主机名修改工具${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    
    show_current_hostname
    echo ""
    
    while true; do
        echo -e "${YELLOW}请输入新的主机名（输入0退出）: ${NC}"
        read -r new_hostname
        
        # 检查是否退出
        if [ "$new_hostname" = "0" ]; then
            echo -e "${BLUE}操作已取消${NC}"
            exit 0
        fi
        
        # 检查是否为空
        if [ -z "$new_hostname" ]; then
            echo -e "${RED}错误: 主机名不能为空${NC}"
            echo ""
            continue
        fi
        
        # 验证主机名格式
        if validate_hostname "$new_hostname"; then
            # 更改主机名
            change_hostname "$new_hostname"
            echo ""
            show_current_hostname
            echo ""
            echo -e "${GREEN}提示: 某些应用可能需要重启系统才能识别新主机名${NC}"
            break
        else
            echo ""
        fi
    done
}

# 执行主函数
main
