#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= 系统信息查询 =======================
display_system_info() {
    # 检查依赖
    check_deps() {
        local deps=(jq whois)
        local missing=()
        for dep in "${deps[@]}"; do
            if ! command -v $dep &>/dev/null; then
                missing+=("$dep")
            fi
        done
        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}正在安装依赖：${missing[*]}${NC}"
            apt-get update >/dev/null 2>&1
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # 获取公网IP信息
    get_ip_info() {
        local ipv4=$(curl -s4 ifconfig.me 2>/dev/null)
        
        # 尝试通过外部服务获取IPv6
        local ipv6=$(curl -s6 --connect-timeout 3 ifconfig.me 2>/dev/null)
        
        # 如果外部服务失败（可能被防火墙阻断），尝试从本地网卡获取
        if [ -z "$ipv6" ]; then
            # 获取全局IPv6地址（排除链路本地地址fe80::和临时地址）
            ipv6=$(ip -6 addr show scope global 2>/dev/null | \
                   grep -oP '(?<=inet6\s)[0-9a-f:]+' | \
                   grep -v '^fe80:' | \
                   grep -v '^fd' | \
                   head -1)
            
            # 如果有本地IPv6，添加标记
            if [ -n "$ipv6" ]; then
                ipv6="$ipv6 (本地)"
            fi
        fi
        
        echo "$ipv4" "$ipv6"
    }

    # 获取ASN信息
    get_asn() {
        local ip=$1
        whois -h whois.radb.net -- "-i origin $ip" 2>/dev/null | grep -i descr: | head -1 | awk -F': ' '{print $2}' | xargs
    }

    # 获取地理信息
    get_geo() {
        local ip=$1
        curl -s "https://ipinfo.io/$ip/json" 2>/dev/null | jq -r '[.country, .city] | join(" ")' 
    }

    # 获取CPU使用率
    get_cpu_usage() {
        echo $(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.1f%%", 100 - $1}')
    }

    # 主显示逻辑
    clear
    check_deps
    read ipv4 ipv6 <<< $(get_ip_info)
    
    echo -e "${CYAN}\n系统信息查询"
    echo "------------------------"
    echo -e "主机名\t: ${GREEN}$(hostname)${NC}"
    echo -e "运营商\t: ${GREEN}$(get_asn $ipv4)${NC}"
    echo "------------------------"
    echo -e "系统版本\t: ${GREEN}$(lsb_release -sd)${NC}"
    echo -e "内核版本\t: ${GREEN}$(uname -r)${NC}"
    echo "------------------------"
    echo -e "CPU架构\t: ${GREEN}$(uname -m)${NC}"
    echo -e "CPU型号\t: ${GREEN}$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)${NC}"
    echo -e "CPU核心\t: ${GREEN}$(nproc) 核${NC}"
    echo -e "CPU占用\t: ${GREEN}$(get_cpu_usage)${NC}"
    echo "------------------------"
    echo -e "物理内存\t: ${GREEN}$(free -m | awk '/Mem/{printf "%.2f/%.2f MB (%.2f%%)", $3, $2, $3/$2*100}')${NC}"
    echo -e "虚拟内存\t: ${GREEN}$(free -m | awk '/Swap/{printf "%.2f/%.2f MB (%.2f%%)", $3, $2, ($3/$2)*100}')${NC}"
    echo -e "硬盘使用\t: ${GREEN}$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')${NC}"
    echo "------------------------"
    echo -e "公网IPv4\t: ${GREEN}${ipv4:-未检测到}${NC}"
    echo -e "公网IPv6\t: ${GREEN}${ipv6:-未检测到}${NC}"
    echo -e "地理位置\t: ${GREEN}$(get_geo $ipv4)${NC}"
    echo -e "系统时区\t: ${GREEN}$(timedatectl | grep "Time zone" | awk '{print $3}')${NC}"
    echo -e "运行时间\t: ${GREEN}$(awk '{printf "%d天%d时%d分", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime)${NC}"
    echo "------------------------"
}

# 执行函数
display_system_info
