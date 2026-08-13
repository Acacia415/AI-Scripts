#!/bin/bash

set -u

GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

fetch() {
    curl -fsS --connect-timeout 3 --max-time 8 "$@" 2>/dev/null || true
}

get_public_ipv4() { fetch -4 https://ifconfig.me/ip; }
get_public_ipv6() {
    local value
    value=$(fetch -6 https://ifconfig.me/ip)
    if [[ -z $value ]] && command -v ip >/dev/null 2>&1; then
        value=$(ip -6 -o addr show scope global 2>/dev/null | awk '$4 !~ /^(fe80|fd)/ {sub(/\/.*/, "", $4); print $4; exit}')
        [[ -n $value ]] && value="$value (本地)"
    fi
    printf '%s' "$value"
}

get_asn() {
    local address=$1
    [[ -n $address ]] && command -v whois >/dev/null 2>&1 || return 0
    timeout 8 whois -h whois.radb.net -- "-i origin $address" 2>/dev/null |
        awk -F': *' 'tolower($1)=="descr" {print $2; exit}'
}

get_geo() {
    local address=$1 response
    [[ -n $address ]] || return 0
    response=$(fetch "https://ipinfo.io/${address}/json")
    if command -v jq >/dev/null 2>&1; then
        jq -r '[.country, .city] | map(select(. != null)) | join(" ")' <<< "$response" 2>/dev/null || true
    fi
}

get_os() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-${NAME:-Unknown}}"
    else
        uname -s
    fi
}

get_swap() {
    free -m | awk '/Swap/ { if ($2 == 0) printf "0/0 MB (未启用)"; else printf "%.0f/%.0f MB (%.2f%%)", $3, $2, $3/$2*100 }'
}

display_system_info() {
    local ipv4 ipv6
    ipv4=$(get_public_ipv4)
    ipv6=$(get_public_ipv6)
    clear
    echo -e "${CYAN}系统信息查询${NC}"
    echo '------------------------'
    echo -e "主机名       : ${GREEN}$(hostname)${NC}"
    echo -e "运营商       : ${GREEN}$(get_asn "$ipv4")${NC}"
    echo -e "系统版本     : ${GREEN}$(get_os)${NC}"
    echo -e "内核版本     : ${GREEN}$(uname -r)${NC}"
    echo -e "CPU 架构     : ${GREEN}$(uname -m)${NC}"
    echo -e "CPU 核心     : ${GREEN}$(nproc 2>/dev/null || echo '?')${NC}"
    echo -e "物理内存     : ${GREEN}$(free -m | awk '/Mem/ {printf "%.0f/%.0f MB (%.2f%%)", $3, $2, $3/$2*100}')${NC}"
    echo -e "虚拟内存     : ${GREEN}$(get_swap)${NC}"
    echo -e "硬盘使用     : ${GREEN}$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')${NC}"
    echo -e "公网 IPv4    : ${GREEN}${ipv4:-未检测到}${NC}"
    echo -e "公网 IPv6    : ${GREEN}${ipv6:-未检测到}${NC}"
    echo -e "地理位置     : ${GREEN}$(get_geo "$ipv4")${NC}"
    echo -e "系统时区     : ${GREEN}$(date +%Z)${NC}"
    echo -e "运行时间     : ${GREEN}$(uptime -p 2>/dev/null || awk '{printf "%d天%d小时%d分钟", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime)${NC}"
    if ! command -v jq >/dev/null 2>&1 || ! command -v whois >/dev/null 2>&1; then
        echo -e "${YELLOW}提示：安装 jq 和 whois 可显示完整地理位置与 ASN；查询脚本不会自动安装软件。${NC}"
    fi
}

display_system_info
