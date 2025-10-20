#!/bin/bash

# iptables 交互式流量转发脚本
# 适用于 Debian/Ubuntu 系统
# 功能：将本地端口流量转发到远程服务器

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 函数：打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 函数：检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 函数：检查系统
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        print_error "此脚本仅支持Debian/Ubuntu系统"
        exit 1
    fi
}

# 函数：初始化环境
init_environment() {
    # 检查并安装依赖
    if ! command -v iptables &> /dev/null; then
        print_info "正在安装 iptables..."
        apt-get update -qq
        apt-get install -y iptables > /dev/null 2>&1
    fi
    
    # 检查并安装iptables-persistent
    if ! dpkg -l | grep -q iptables-persistent; then
        print_info "正在安装 iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent > /dev/null 2>&1
    fi
    
    # 检查并安装dnsutils（用于域名解析）
    if ! command -v nslookup &> /dev/null; then
        print_info "正在安装 dnsutils..."
        apt-get install -y dnsutils > /dev/null 2>&1
    fi
    
    # 启用IP转发
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) -ne 1 ]]; then
        print_info "启用IP转发..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # 永久启用
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        else
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf > /dev/null 2>&1
    fi
}

# 函数：获取本地IP
get_local_ip() {
    local ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    echo "$ip"
}

# 函数：解析域名
resolve_domain() {
    local domain=$1
    local ip=""
    
    # 检查是否是IP地址
    if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$domain"
        return 0
    fi
    
    # 解析域名
    print_info "正在解析域名: $domain"
    ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | tail -1 | awk '{print $2}')
    
    if [[ -z "$ip" ]]; then
        # 尝试使用host命令
        ip=$(host "$domain" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}')
    fi
    
    if [[ -z "$ip" ]]; then
        print_error "无法解析域名: $domain"
        return 1
    fi
    
    print_info "域名解析成功: $domain -> $ip"
    echo "$ip"
    return 0
}

# 函数：验证端口
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 函数：添加转发规则
add_forward_rule() {
    local protocol=$1
    local local_port=$2
    local remote_ip=$3
    local remote_port=$4
    local local_ip=$(get_local_ip)
    
    print_info "正在添加转发规则..."
    
    # 添加TCP规则
    if [[ "$protocol" == "tcp" ]] || [[ "$protocol" == "both" ]]; then
        # 检查规则是否已存在
        if iptables -t nat -C PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
            print_warning "TCP转发规则已存在"
        else
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port
            iptables -t nat -A POSTROUTING -p tcp -d $remote_ip --dport $remote_port -j SNAT --to-source $local_ip
            iptables -A FORWARD -p tcp -d $remote_ip --dport $remote_port -j ACCEPT
            iptables -A FORWARD -p tcp -s $remote_ip --sport $remote_port -j ACCEPT
            print_info "TCP转发规则已添加: $local_ip:$local_port -> $remote_ip:$remote_port"
        fi
    fi
    
    # 添加UDP规则
    if [[ "$protocol" == "udp" ]] || [[ "$protocol" == "both" ]]; then
        # 检查规则是否已存在
        if iptables -t nat -C PREROUTING -p udp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
            print_warning "UDP转发规则已存在"
        else
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port
            iptables -t nat -A POSTROUTING -p udp -d $remote_ip --dport $remote_port -j SNAT --to-source $local_ip
            iptables -A FORWARD -p udp -d $remote_ip --dport $remote_port -j ACCEPT
            iptables -A FORWARD -p udp -s $remote_ip --sport $remote_port -j ACCEPT
            print_info "UDP转发规则已添加: $local_ip:$local_port -> $remote_ip:$remote_port"
        fi
    fi
    
    # 保存规则
    netfilter-persistent save > /dev/null 2>&1
    print_info "规则已保存并持久化"
}

# 函数：执行转发设置
setup_forward() {
    local protocol=$1
    local protocol_name=$2
    
    echo ""
    echo -e "${CYAN}========== 设置${protocol_name}转发 ==========${NC}"
    echo ""
    
    # 输入本地端口
    local local_port=""
    while true; do
        read -p "请输入本机需要转发的端口 (1-65535): " local_port
        if validate_port "$local_port"; then
            break
        else
            print_error "无效的端口号，请输入1-65535之间的数字"
        fi
    done
    
    # 输入远程地址
    local remote_address=""
    local remote_ip=""
    while true; do
        echo ""
        read -p "请输入需要转发到的目标地址 (支持IP或域名): " remote_address
        
        # 解析地址
        remote_ip=$(resolve_domain "$remote_address")
        if [[ $? -eq 0 ]] && [[ -n "$remote_ip" ]]; then
            break
        else
            print_error "无效的地址或域名无法解析，请重新输入"
        fi
    done
    
    # 输入远程端口
    local remote_port=""
    while true; do
        echo ""
        read -p "请输入目标服务器的端口 (1-65535): " remote_port
        if validate_port "$remote_port"; then
            break
        else
            print_error "无效的端口号，请输入1-65535之间的数字"
        fi
    done
    
    # 确认信息
    echo ""
    echo -e "${YELLOW}========== 确认转发信息 ==========${NC}"
    echo -e "转发协议: ${GREEN}${protocol_name}${NC}"
    echo -e "本地端口: ${GREEN}${local_port}${NC}"
    echo -e "目标地址: ${GREEN}${remote_address}${NC}"
    if [[ "$remote_address" != "$remote_ip" ]]; then
        echo -e "解析后IP: ${GREEN}${remote_ip}${NC}"
    fi
    echo -e "目标端口: ${GREEN}${remote_port}${NC}"
    echo ""
    
    read -p "确认添加此转发规则吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        add_forward_rule "$protocol" "$local_port" "$remote_ip" "$remote_port"
        echo ""
        print_info "转发规则添加成功！"
    else
        print_warning "已取消添加规则"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 函数：显示当前规则
show_current_rules() {
    clear
    echo -e "${CYAN}========== 当前转发规则 ==========${NC}"
    echo ""
    
    # 只显示DNAT转发规则（最核心的规则）
    echo -e "${YELLOW}当前转发规则列表:${NC}"
    echo "-------------------------------------------------------------------"
    printf "%-5s %-8s %-20s %-30s\n" "编号" "协议" "本地端口" "目标地址"
    echo "-------------------------------------------------------------------"
    
    # 获取规则
    iptables -t nat -L PREROUTING -n --line-numbers | grep "dpt:" | while read line; do
        num=$(echo "$line" | awk '{print $1}')
        proto=$(echo "$line" | awk '{print $4}')
        local_port=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
        dest=$(echo "$line" | grep -oP 'to:\K[0-9.]+:[0-9]+')
        printf "%-5s %-8s %-20s %-30s\n" "$num" "$proto" "$local_port" "$dest"
    done
    
    echo "-------------------------------------------------------------------"
    echo ""
    read -p "按回车键返回主菜单..."
}

# 函数：删除规则
delete_rules() {
    clear
    echo -e "${CYAN}========== 删除转发规则 ==========${NC}"
    echo ""
    
    # 显示当前规则列表
    echo -e "${YELLOW}当前转发规则列表:${NC}"
    echo "-------------------------------------------------------------------"
    printf "%-5s %-8s %-20s %-30s\n" "编号" "协议" "本地端口" "目标地址"
    echo "-------------------------------------------------------------------"
    
    # 保存规则到数组
    declare -a rule_nums
    declare -a rule_details
    local index=0
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "dpt:"; then
            num=$(echo "$line" | awk '{print $1}')
            proto=$(echo "$line" | awk '{print $4}')
            local_port=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
            dest=$(echo "$line" | grep -oP 'to:\K[0-9.]+:[0-9]+')
            printf "%-5s %-8s %-20s %-30s\n" "$num" "$proto" "$local_port" "$dest"
            rule_nums[$index]=$num
            rule_details[$index]="$proto $local_port -> $dest"
            ((index++))
        fi
    done < <(iptables -t nat -L PREROUTING -n --line-numbers)
    
    echo "-------------------------------------------------------------------"
    
    if [[ $index -eq 0 ]]; then
        print_warning "没有找到任何转发规则"
        echo ""
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    echo "提示: 可以输入单个编号或多个编号(用英文逗号分隔，如: 1,3,5)"
    echo "      输入 0 返回主菜单"
    echo ""
    read -p "请输入要删除的规则编号: " rule_input
    
    if [[ "$rule_input" == "0" ]]; then
        return
    fi
    
    # 解析输入的规则编号
    IFS=',' read -ra selected_rules <<< "$rule_input"
    
    # 验证所有输入的编号
    declare -a valid_rules
    declare -a valid_details
    local valid_count=0
    
    for rule_num in "${selected_rules[@]}"; do
        # 去除空格
        rule_num=$(echo "$rule_num" | tr -d ' ')
        
        # 检查是否为数字
        if [[ ! "$rule_num" =~ ^[0-9]+$ ]]; then
            print_error "无效的规则编号: $rule_num"
            continue
        fi
        
        # 检查规则是否存在
        local found=0
        for i in "${!rule_nums[@]}"; do
            if [[ "${rule_nums[$i]}" == "$rule_num" ]]; then
                valid_rules[$valid_count]=$rule_num
                valid_details[$valid_count]="${rule_details[$i]}"
                ((valid_count++))
                found=1
                break
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            print_error "未找到规则编号: $rule_num"
        fi
    done
    
    if [[ $valid_count -eq 0 ]]; then
        print_warning "没有有效的规则编号"
        echo ""
        read -p "按回车键返回主菜单..."
        return
    fi
    
    # 显示将要删除的规则
    echo ""
    echo -e "${YELLOW}将要删除以下规则:${NC}"
    for i in "${!valid_rules[@]}"; do
        echo "  规则 ${valid_rules[$i]}: ${valid_details[$i]}"
    done
    
    echo ""
    read -p "确认删除这些规则吗？(y/n): " confirm
    
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        # 从大到小排序规则编号，避免删除时编号变化
        # 使用 printf 和 sort 来正确处理多位数字排序
        local sorted_rules=($(printf "%s\n" "${valid_rules[@]}" | sort -rn))
        
        local success_count=0
        local fail_count=0
        
        # 删除规则
        # 注意：这里只删除了PREROUTING规则，与之关联的POSTROUTING和FORWARD规则会保留，
        # 但因为入口规则已删除，它们不会被匹配到，通常无害。
        print_info "正在删除规则..."
        for rule_num in "${sorted_rules[@]}"; do
            if iptables -t nat -D PREROUTING $rule_num 2>/dev/null; then
                print_info "已删除规则 $rule_num"
                ((success_count++))
            else
                print_error "删除规则 $rule_num 失败"
                ((fail_count++))
            fi
        done
        
        # 保存规则
        netfilter-persistent save > /dev/null 2>&1
        
        echo ""
        if [[ $success_count -gt 0 ]]; then
            print_info "成功删除 $success_count 条规则并已持久化"
        fi
        if [[ $fail_count -gt 0 ]]; then
            print_warning "删除失败 $fail_count 条规则"
        fi
    else
        print_warning "已取消删除"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 函数：备份规则
backup_rules() {
    clear
    echo -e "${CYAN}========== 备份iptables规则 ==========${NC}"
    echo ""
    
    local default_path="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
    local backup_path=""
    
    read -p "请输入备份文件路径 [默认: ${default_path}]: " backup_path
    if [[ -z "$backup_path" ]]; then
        backup_path="$default_path"
    fi
    
    # 检查文件是否存在
    if [[ -f "$backup_path" ]]; then
        print_warning "文件已存在: $backup_path"
        read -p "是否覆盖？ (y/n): " confirm
        if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
            print_info "已取消备份"
            echo ""
            read -p "按回车键返回主菜单..."
            return
        fi
    fi
    
    print_info "正在备份规则到 $backup_path ..."
    if iptables-save > "$backup_path"; then
        print_info "规则备份成功！"
    else
        print_error "规则备份失败！"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 函数：恢复规则
restore_rules() {
    clear
    echo -e "${CYAN}========== 恢复iptables规则 ==========${NC}"
    echo ""
    
    local backup_path=""
    read -p "请输入要恢复的备份文件路径: " backup_path
    
    if [[ ! -f "$backup_path" ]]; then
        print_error "备份文件不存在: $backup_path"
        echo ""
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    print_warning "警告：恢复操作将覆盖所有现有iptables规则！"
    read -p "确认从 $backup_path 恢复规则吗？ (y/n): " confirm
    
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        print_info "正在从 $backup_path 恢复规则..."
        if iptables-restore < "$backup_path"; then
            print_info "规则恢复成功！"
            print_info "正在持久化规则..."
            netfilter-persistent save > /dev/null 2>&1
            print_info "规则已持久化！"
        else
            print_error "规则恢复失败！请检查备份文件格式是否正确。"
        fi
    else
        print_warning "已取消恢复操作"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 函数：显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${CYAN}          IPTables 流量转发管理工具${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo -e "${GREEN}请选择操作:${NC}"
    echo ""
    echo "  1. 转发 TCP+UDP"
    echo "  2. 转发 TCP"
    echo "  3. 转发 UDP"
    echo "  4. 查看当前规则"
    echo "  5. 删除转发规则"
    echo "  6. 备份转发规则"
    echo "  7. 恢复转发规则"
    echo "  0. 退出脚本"
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "本机IP: ${GREEN}$(get_local_ip)${NC}"
    echo -e "IP转发: ${GREEN}$([ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ] && echo "已启用" || echo "未启用")${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# 主函数
main() {
    # 检查权限和系统
    check_root
    check_system
    
    # 初始化环境
    print_info "正在初始化环境..."
    init_environment
    
    # 主循环
    while true; do
        show_menu
        
        read -p "请输入选项 (0-7): " choice
        
        case $choice in
            1)
                setup_forward "both" "TCP+UDP"
                ;;
            2)
                setup_forward "tcp" "TCP"
                ;;
            3)
                setup_forward "udp" "UDP"
                ;;
            4)
                show_current_rules
                ;;
            5)
                delete_rules
                ;;
            6)
                backup_rules
                ;;
            7)
                restore_rules
                ;;
            0)
                echo ""
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_error "无效的选项，请重新选择"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
main
