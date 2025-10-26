#!/bin/bash

# Time Synchronization Script
# 一键校准系统时间脚本
# 用于修复 ss-rust + shadowtls 时间戳不匹配问题

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 显示当前时间
show_current_time() {
    print_info "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    print_info "当前时区: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'Unknown')"
}

# 设置时区（如果需要）
set_timezone() {
    local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "")
    
    if [[ "$current_tz" != "Asia/Shanghai" ]] && [[ "$current_tz" != "Asia/Hong_Kong" ]]; then
        print_warning "检测到时区不是 Asia/Shanghai 或 Asia/Hong_Kong"
        read -p "是否要设置时区为 Asia/Shanghai? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            print_success "时区已设置为 Asia/Shanghai"
        fi
    fi
}

# 使用 chronyd 同步时间
sync_with_chrony() {
    if command -v chronyc &> /dev/null; then
        print_info "使用 chrony 同步时间..."
        
        # 启动 chronyd 服务
        systemctl start chronyd 2>/dev/null || service chronyd start 2>/dev/null || true
        
        # 强制同步
        chronyc -a makestep &>/dev/null || true
        sleep 2
        
        # 检查同步状态
        if chronyc tracking &>/dev/null; then
            print_success "Chrony 时间同步完成"
            chronyc tracking | grep -E "Reference ID|Stratum|System time"
            return 0
        fi
    fi
    return 1
}

# 使用 systemd-timesyncd 同步时间
sync_with_timesyncd() {
    if command -v timedatectl &> /dev/null; then
        print_info "使用 systemd-timesyncd 同步时间..."
        
        # 启用 NTP
        timedatectl set-ntp true 2>/dev/null || true
        
        # 重启 timesyncd 服务
        systemctl restart systemd-timesyncd 2>/dev/null || true
        sleep 3
        
        # 检查同步状态
        if timedatectl status | grep -q "System clock synchronized: yes"; then
            print_success "systemd-timesyncd 时间同步完成"
            timedatectl status | grep -E "synchronized|NTP service"
            return 0
        elif timedatectl timesync-status &>/dev/null; then
            print_success "systemd-timesyncd 时间同步完成"
            timedatectl timesync-status
            return 0
        fi
    fi
    return 1
}

# 使用 ntpdate 同步时间
sync_with_ntpdate() {
    if command -v ntpdate &> /dev/null; then
        print_info "使用 ntpdate 同步时间..."
        
        # 停止可能冲突的服务
        systemctl stop systemd-timesyncd 2>/dev/null || true
        systemctl stop chronyd 2>/dev/null || true
        systemctl stop ntpd 2>/dev/null || true
        
        # NTP 服务器列表（优先使用国内和亚洲服务器）
        local ntp_servers=(
            "ntp.aliyun.com"
            "ntp.tencent.com"
            "time.asia.apple.com"
            "cn.pool.ntp.org"
            "asia.pool.ntp.org"
            "pool.ntp.org"
        )
        
        for server in "${ntp_servers[@]}"; do
            print_info "尝试连接 NTP 服务器: $server"
            if timeout 10 ntpdate -u "$server" 2>/dev/null; then
                print_success "使用 $server 同步时间成功"
                # 将时间写入硬件时钟
                hwclock --systohc 2>/dev/null || true
                return 0
            fi
        done
        
        print_warning "ntpdate 同步失败，尝试其他方法..."
    fi
    return 1
}

# 使用 ntpd 同步时间
sync_with_ntpd() {
    if command -v ntpd &> /dev/null; then
        print_info "使用 ntpd 同步时间..."
        
        systemctl restart ntpd 2>/dev/null || service ntpd restart 2>/dev/null || true
        sleep 3
        
        if ntpq -p &>/dev/null; then
            print_success "ntpd 时间同步服务已启动"
            ntpq -p
            return 0
        fi
    fi
    return 1
}

# 手动使用 date 命令从网络获取时间
sync_manual() {
    print_info "尝试手动获取网络时间..."
    
    # 尝试从多个来源获取时间
    local time_sources=(
        "http://worldtimeapi.org/api/timezone/Asia/Shanghai"
        "http://worldtimeapi.org/api/timezone/Asia/Hong_Kong"
    )
    
    for source in "${time_sources[@]}"; do
        if command -v curl &> /dev/null; then
            local timestamp=$(curl -s "$source" | grep -oP '"datetime":"\K[^"]+' | head -1)
            if [[ -n "$timestamp" ]]; then
                # 转换为 date 命令可用的格式
                local formatted_time=$(echo "$timestamp" | sed 's/T/ /' | cut -d'.' -f1)
                if date -s "$formatted_time" 2>/dev/null; then
                    print_success "手动时间同步成功"
                    hwclock --systohc 2>/dev/null || true
                    return 0
                fi
            fi
        fi
    done
    
    return 1
}

# 安装时间同步工具
install_sync_tools() {
    print_warning "未检测到时间同步工具"
    read -p "是否要安装 chrony? (推荐) (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "正在安装 chrony..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony
        elif command -v yum &> /dev/null; then
            yum install -y chrony
        elif command -v dnf &> /dev/null; then
            dnf install -y chrony
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm chrony
        else
            print_error "无法识别的包管理器，请手动安装 chrony"
            return 1
        fi
        
        systemctl enable chronyd 2>/dev/null || true
        systemctl start chronyd 2>/dev/null || true
        print_success "chrony 安装完成"
        return 0
    fi
    
    return 1
}

# 重启相关服务
restart_services() {
    print_info "检查并重启 ss-rust 和 shadowtls 服务..."
    
    if systemctl is-active --quiet ss-rust.service; then
        systemctl restart ss-rust.service
        print_success "ss-rust 服务已重启"
    fi
    
    if systemctl is-active --quiet shadowtls.service; then
        systemctl restart shadowtls.service
        print_success "shadowtls 服务已重启"
    fi
}

# 验证时间同步
verify_sync() {
    print_info "验证时间同步..."
    show_current_time
    
    # 检查与网络时间的差异
    if command -v ntpdate &> /dev/null; then
        local time_diff=$(ntpdate -q ntp.aliyun.com 2>/dev/null | grep -oP 'offset \K[0-9.-]+' | head -1)
        if [[ -n "$time_diff" ]]; then
            local abs_diff=$(echo "$time_diff" | tr -d '-')
            if (( $(echo "$abs_diff < 1.0" | bc -l 2>/dev/null || echo 0) )); then
                print_success "时间同步验证通过，偏差: ${time_diff}秒"
            else
                print_warning "时间偏差较大: ${time_diff}秒，可能需要再次同步"
            fi
        fi
    fi
}

# 主函数
main() {
    echo "======================================"
    echo "      时间同步脚本 / Time Sync       "
    echo "======================================"
    echo
    
    check_root
    show_current_time
    set_timezone
    
    echo
    print_info "开始同步时间..."
    echo
    
    # 尝试多种同步方法
    if sync_with_chrony; then
        :
    elif sync_with_timesyncd; then
        :
    elif sync_with_ntpdate; then
        :
    elif sync_with_ntpd; then
        :
    elif install_sync_tools && sync_with_chrony; then
        :
    elif sync_manual; then
        :
    else
        print_error "所有时间同步方法都失败了"
        print_info "请检查网络连接或手动安装 chrony/ntpdate"
        exit 1
    fi
    
    echo
    verify_sync
    
    echo
    read -p "是否要重启 ss-rust 和 shadowtls 服务? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        restart_services
    fi
    
    echo
    print_success "时间同步完成！"
    print_info "建议设置定时任务定期同步时间，运行: crontab -e"
    print_info "添加以下行以每小时同步一次:"
    echo "  0 * * * * /usr/bin/bash $(realpath $0) > /dev/null 2>&1"
}

# 运行主函数
main "$@"
