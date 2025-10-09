#!/bin/bash

# =================================================================
# DNS & Gost Unlock Service Manager (Conflict-Aware & Full-Featured Version)
# Description: A standalone script to install, manage, and uninstall
#              a DNS-based unlock service using Dnsmasq and Gost.
#              Includes smart checks to co-exist with other Gost installations.
# Version: 4.2 (Auto-fix for systemd-resolved conflict)
# =================================================================

# --- 专属配置 ---
DNS_GOST_CONFIG_PATH="/etc/gost/dns-unlock-config.json"
DNS_GOST_SERVICE_NAME="gost-dns.service"
DNS_GOST_SERVICE_PATH="/etc/systemd/system/${DNS_GOST_SERVICE_NAME}"

# --- 安全检查: 确保以 root 权限运行 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m错误：本脚本需要以 root 权限运行。\033[0m"
    echo -e "\033[0;32m请尝试使用: sudo bash $0\033[0m"
    exit 1
fi


# ======================= 帮助函数 =======================

check_port_53() {
    if ! command -v lsof &> /dev/null; then apt-get update >/dev/null 2>&1 && apt-get install -y lsof >/dev/null; fi
    if lsof -i :53 -sTCP:LISTEN -P -n >/dev/null; then
        local process_name=$(ps -p $(lsof -i :53 -sTCP:LISTEN -P -n -t) -o comm=)
        
        if [[ "$process_name" == "systemd-resolve" ]]; then
            echo -e "\033[0;33mWARNING: 端口 53 (DNS) 已被系统服务 'systemd-resolved' 占用。\033[0m"
            read -p "是否允许脚本自动禁用该服务并修复DNS配置? (Y/n): " choice
            if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
                echo -e "\033[0;36mINFO: 正在停止并禁用 systemd-resolved...\033[0m"
                systemctl disable --now systemd-resolved
                
                # 等待端口释放
                sleep 2

                # 修复由 systemd-resolved 管理的 /etc/resolv.conf
                if [ -L /etc/resolv.conf ]; then
                    echo -e "\033[0;36mINFO: /etc/resolv.conf 是一个符号链接，正在重新创建它以确保服务器网络正常...\033[0m"
                    rm /etc/resolv.conf
                    echo "nameserver 8.8.8.8" | tee /etc/resolv.conf > /dev/null
                    echo "nameserver 1.1.1.1" | tee -a /etc/resolv.conf > /dev/null
                    echo -e "\033[0;32mSUCCESS: /etc/resolv.conf 已修复。\033[0m"
                fi
                # 再次检查端口是否已释放
                if lsof -i :53 -sTCP:LISTEN -P -n >/dev/null; then
                     echo -e "\033[0;31mERROR: 端口 53 仍然被占用，请手动检查。\033[0m"
                     return 1
                fi
                echo -e "\033[0;32mSUCCESS: 端口 53 冲突已解决。\033[0m"
                return 0
            else
                echo -e "\033[0;31mERROR: 操作已取消。请手动禁用 systemd-resolved (sudo systemctl disable --now systemd-resolved) 后重试。\033[0m"
                return 1
            fi
        fi

        echo -e "\033[0;33mWARNING: 端口 53 (DNS) 已被进程 '${process_name}' 占用。\033[0m"
        if [[ "$process_name" != "dnsmasq" ]]; then
             echo -e "\033[0;31mERROR: 请先停止 '${process_name}' 服务后再试。\033[0m"
             return 1
        fi
    fi
    return 0
}

check_ports_80_443() {
    if ! command -v lsof &> /dev/null; then apt-get update >/dev/null 2>&1 && apt-get install -y lsof >/dev/null; fi
    for port in 80 443; do
        if lsof -i :${port} -sTCP:LISTEN -P -n >/dev/null; then
            local process_name=$(ps -p $(lsof -i :${port} -sTCP:LISTEN -P -n -t) -o comm=)
            if [[ "$process_name" != "gost" ]]; then
                echo -e "\033[0;33mWARNING: 端口 ${port} 已被进程 '${process_name}' 占用。\033[0m"
                echo -e "\033[0;31m这可能与 Nginx, Apache 或 Caddy 等常用Web服务冲突。请确保您已了解此情况。\033[0m"
                read -p "是否仍然继续安装? (y/N): " choice
                if [[ ! "$choice" =~ ^[yY]$ ]]; then echo "安装已取消。"; return 1; fi
                return 0
            fi
        fi
    done
    return 0
}


# ======================= 核心功能函数 =======================

dns_unlock_menu() {
    while true; do
        clear
        echo -e "\033[0;36m=============================================\033[0m"
        echo -e "\033[0;33m         DNS 解锁服务管理 (Gost v3 版)         \033[0m"
        echo -e "\033[0;36m=============================================\033[0m"
        echo " --- 服务端管理 ---"
        echo "  1. 安装/更新 DNS 解锁服务"
        echo "  2. 卸载 DNS 解锁服务"
        echo "  3. 管理 IP 白名单 (防火墙)"
        echo
        echo " --- 客户端管理 ---"
        echo "  4. 设置本机为 DNS 客户端"
        echo "  5. 还原客户端 DNS 设置"
        echo " --------------------------------------------"
        echo "  0. 退出脚本"
        echo -e "\033[0;36m=============================================\033[0m"
        read -p "请输入选项 [0-5]: " choice

        case $choice in
            1) install_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            2) uninstall_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            3) manage_iptables_rules ;;
            4) setup_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            5) uninstall_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            0) break ;;
            *) echo -e "\033[0;31m无效选项，请重新输入!\033[0m"; sleep 2 ;;
        esac
    done
}

install_dns_unlock_server() {
    clear
    echo -e "\033[0;33m--- DNS解锁服务 安装/更新 (已升级为Gost V3) ---\033[0m"

    echo -e "\033[0;36mINFO: 正在安装/检查核心依赖...\033[0m"
    apt-get update >/dev/null 2>&1
    apt-get install -y dnsmasq curl wget lsof tar file >/dev/null 2>&1
    if ! check_port_53; then return 1; fi
    if ! check_ports_80_443; then return 1; fi
    
    echo -e "\033[0;36mINFO: 正在清理旧环境 (包括旧版Gost)...\033[0m"
    systemctl stop sniproxy 2>/dev/null
    systemctl stop gost-dns.service 2>/dev/null
    apt-get purge -y sniproxy >/dev/null 2>&1
    apt-get --fix-broken install -y >/dev/null 2>&1
    rm -f /etc/dnsmasq.d/custom_netflix.conf
    # 清理动作不应删除gost主程序，智能检查会处理
    echo

    # --- 智能检查Gost是否已安装 ---
    local GOST_EXEC_PATH
    GOST_EXEC_PATH=$(command -v gost)

    if [[ -n "$GOST_EXEC_PATH" ]]; then
        echo -e "\033[0;32m检测到 Gost 已安装: ${GOST_EXEC_PATH} ($(gost -V))\033[0m"
        echo -e "\033[0;36mINFO: 将使用现有版本，跳过安装步骤。\033[0m"
    else
        echo -e "\033[0;36mINFO: 正在安装 Gost v3 ...\033[0m"
        FILENAME="gost_3.2.4_linux_amd64.tar.gz"
        GOST_URL="https://github.com/go-gost/gost/releases/download/v3.2.4/${FILENAME}"

        echo "INFO: 正在从以下地址下载Gost v3:"
        echo "$GOST_URL"
        if ! curl -L -o "${FILENAME}" "${GOST_URL}"; then
            echo -e "\033[0;31mERROR: Gost v3 下载失败！ (curl 退出码: $?)\033[0m"
            rm -f "${FILENAME}"
            return 1
        fi

        if ! file "${FILENAME}" | grep -q 'gzip compressed data'; then
            echo -e "\033[0;31mERROR: 下载的文件不是有效的压缩包。请手动检查上述URL。\033[0m"
            rm -f "${FILENAME}"
            return 1
        fi

        tar -xzf "${FILENAME}" || { echo -e "\033[0;31mERROR: Gost解压失败！\033[0m"; rm -f "${FILENAME}"; return 1; }
        
        chmod +x "gost"
        mv "gost" /usr/local/bin/gost || { echo -e "\033[0;31mERROR: 移动gost文件失败，请检查权限。\033[0m"; return 1; }
        
        rm -f "${FILENAME}"
        GOST_EXEC_PATH="/usr/local/bin/gost" # 更新路径变量
        
        if ! command -v gost &> /dev/null; then 
            echo -e "\033[0;31mERROR: Gost 安装最终失败，未知错误。\033[0m"
            return 1
        else
            echo -e "\033[0;32mSUCCESS: Gost v3 已成功安装。版本：$(gost -V)\033[0m"
        fi
    fi
    echo
    
    echo -e "\033[0;36mINFO: 正在为DNS解锁服务创建 Gost v3 配置文件...\033[0m"
    mkdir -p /etc/gost
    
    tee "${DNS_GOST_CONFIG_PATH}" > /dev/null <<'EOT'
{
  "services": [
    {
      "name": "dns-unlock-sni-80",
      "addr": ":80",
      "handler": { "type": "tcp" },
      "listener": { "type": "tcp" },
      "forwarder": { "nodes": [ { "name": "forwarder-80", "addr": "{host}:80" } ] }
    },
    {
      "name": "dns-unlock-sni-443",
      "addr": ":443",
      "handler": { "type": "sni" },
      "listener": { "type": "tcp" },
      "forwarder": { "nodes": [ { "name": "forwarder-443", "addr": "{host}:{port}" } ] }
    }
  ],
  "resolvers": [
    { "name": "google-dns", "addr": "8.8.8.8:53", "protocol": "udp" }
  ]
}
EOT

    echo -e "\033[0;36mINFO: 正在创建Systemd服务 (${DNS_GOST_SERVICE_NAME})...\033[0m"
    # 使用检测到的或新安装的gost路径，确保兼容性
    tee "${DNS_GOST_SERVICE_PATH}" > /dev/null <<EOT
[Unit]
Description=GOST DNS Unlock Service
After=network.target

[Service]
Type=simple
ExecStart=${GOST_EXEC_PATH} -C ${DNS_GOST_CONFIG_PATH}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOT

    systemctl daemon-reload; systemctl enable "${DNS_GOST_SERVICE_NAME}"; systemctl restart "${DNS_GOST_SERVICE_NAME}"
    if systemctl is-active --quiet "${DNS_GOST_SERVICE_NAME}"; then echo -e "\033[0;32mSUCCESS: Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME}) 已成功启动。\033[0m"; else echo -e "\033[0;31mERROR: Gost DNS解锁服务启动失败，请使用 'systemctl status gost-dns.service' 查看日志。\033[0m"; return 1; fi
    echo

    echo -e "\033[0;36mINFO: 正在创建 Dnsmasq 子配置文件...\033[0m"
    PUBLIC_IP=$(curl -4s ip.sb || curl -4s ifconfig.me)
    if [[ -z "$PUBLIC_IP" ]]; then echo -e "\033[0;31mERROR: 无法获取公网IP地址。\033[0m"; return 1; fi
    
    DNSMASQ_CONFIG_FILE="/etc/dnsmasq.d/custom_unlock.conf"
    
    tee "$DNSMASQ_CONFIG_FILE" > /dev/null <<EOF
# --- DNSMASQ CONFIG MODULE MANAGED BY SCRIPT ---
# General Settings
domain-needed
bogus-priv
no-resolv
no-poll
all-servers
cache-size=2048
local-ttl=60
interface=*
# Upstream DNS Servers
server=8.8.8.8
server=1.1.1.1
server=208.67.222.222
server=4.2.2.1
# --- Unlock Rules ---
address=/akadns.net/${PUBLIC_IP}
address=/akam.net/${PUBLIC_IP}
address=/akamai.com/${PUBLIC_IP}
address=/akamai.net/${PUBLIC_IP}
address=/akamaiedge.net/${PUBLIC_IP}
address=/akamaihd.net/${PUBLIC_IP}
address=/akamaistream.net/${PUBLIC_IP}
address=/akamaitech.net/${PUBLIC_IP}
address=/akamaitechnologies.com/${PUBLIC_IP}
address=/akamaitechnologies.fr/${PUBLIC_IP}
address=/akamaized.net/${PUBLIC_IP}
address=/edgekey.net/${PUBLIC_IP}
address=/edgesuite.net/${PUBLIC_IP}
address=/srip.net/${PUBLIC_IP}
address=/footprint.net/${PUBLIC_IP}
address=/level3.net/${PUBLIC_IP}
address=/llnwd.net/${PUBLIC_IP}
address=/edgecastcdn.net/${PUBLIC_IP}
address=/cloudfront.net/${PUBLIC_IP}
address=/netflix.com/${PUBLIC_IP}
address=/netflix.net/${PUBLIC_IP}
address=/nflximg.com/${PUBLIC_IP}
address=/nflximg.net/${PUBLIC_IP}
address=/nflxvideo.net/${PUBLIC_IP}
address=/nflxso.net/${PUBLIC_IP}
address=/nflxext.com/${PUBLIC_IP}
address=/hulu.com/${PUBLIC_IP}
address=/huluim.com/${PUBLIC_IP}
address=/hbo.com/${PUBLIC_IP}
address=/hbonow.com/${PUBLIC_IP}
address=/hbomax.com/${PUBLIC_IP}
address=/hbomaxcdn.com/${PUBLIC_IP}
address=/hboasia.com/${PUBLIC_IP}
address=/hbogoasia.com/${PUBLIC_IP}
address=/max.com/${PUBLIC_IP}
address=/warnermediacdn.com/${PUBLIC_IP}
address=/wmcdp.io/${PUBLIC_IP}
address=/ngtv.io/${PUBLIC_IP}
address=/pypestream.com/${PUBLIC_IP}
address=/arkoselabs.com/${PUBLIC_IP}
address=/amazon.com/${PUBLIC_IP}
address=/amazon.co.uk/${PUBLIC_IP}
address=/amazonvideo.com/${PUBLIC_IP}
address=/crackle.com/${PUBLIC_IP}
address=/pandora.com/${PUBLIC_IP}
address=/vudu.com/${PUBLIC_IP}
address=/blinkbox.com/${PUBLIC_IP}
address=/abc.com/${PUBLIC_IP}
address=/fox.com/${PUBLIC_IP}
address=/theplatform.com/${PUBLIC_IP}
address=/nbc.com/${PUBLIC_IP}
address=/nbcuni.com/${PUBLIC_IP}
address=/ip2location.com/${PUBLIC_IP}
address=/pbs.org/${PUBLIC_IP}
address=/warnerbros.com/${PUBLIC_IP}
address=/southpark.cc.com/${PUBLIC_IP}
address=/cbs.com/${PUBLIC_IP}
address=/brightcove.com/${PUBLIC_IP}
address=/cwtv.com/${PUBLIC_IP}
address=/spike.com/${PUBLIC_IP}
address=/go.com/${PUBLIC_IP}
address=/mtv.com/${PUBLIC_IP}
address=/mtvnservices.com/${PUBLIC_IP}
address=/playstation.net/${PUBLIC_IP}
address=/uplynk.com/${PUBLIC_IP}
address=/maxmind.com/${PUBLIC_IP}
address=/disney.com/${PUBLIC_IP}
address=/disneyjunior.com/${PUBLIC_IP}
address=/adobedtm.com/${PUBLIC_IP}
address=/bam.nr-data.net/${PUBLIC_IP}
address=/bamgrid.com/${PUBLIC_IP}
address=/braze.com/${PUBLIC_IP}
address=/cdn.optimizely.com/${PUBLIC_IP}
address=/cdn.registerdisney.go.com/${PUBLIC_IP}
address=/cws.conviva.com/${PUBLIC_IP}
address=/d9.flashtalking.com/${PUBLIC_IP}
address=/disney-plus.net/${PUBLIC_IP}
address=/disney-portal.my.onetrust.com/${PUBLIC_IP}
address=/disney.demdex.net/${PUBLIC_IP}
address=/disney.my.sentry.io/${PUBLIC_IP}
address=/disneyplus.bn5x.net/${PUBLIC_IP}
address=/disneyplus.com/${PUBLIC_IP}
address=/disneyplus.com.ssl.sc.omtrdc.net/${PUBLIC_IP}
address=/disneystreaming.com/${PUBLIC_IP}
address=/dssott.com/${PUBLIC_IP}
address=/execute-api.us-east-1.amazonaws.com/${PUBLIC_IP}
address=/js-agent.newrelic.com/${PUBLIC_IP}
address=/xboxlive.com/${PUBLIC_IP}
address=/lovefilm.com/${PUBLIC_IP}
address=/turner.com/${PUBLIC_IP}
address=/amctv.com/${PUBLIC_IP}
address=/sho.com/${PUBLIC_IP}
address=/mog.com/${PUBLIC_IP}
address=/wdtvlive.com/${PUBLIC_IP}
address=/beinsportsconnect.tv/${PUBLIC_IP}
address=/beinsportsconnect.net/${PUBLIC_IP}
address=/fig.bbc.co.uk/${PUBLIC_IP}
address=/open.live.bbc.co.uk/${PUBLIC_IP}
address=/sa.bbc.co.uk/${PUBLIC_IP}
address=/www.bbc.co.uk/${PUBLIC_IP}
address=/crunchyroll.com/${PUBLIC_IP}
address=/ifconfig.co/${PUBLIC_IP}
address=/omtrdc.net/${PUBLIC_IP}
address=/sling.com/${PUBLIC_IP}
address=/movetv.com/${PUBLIC_IP}
address=/happyon.jp/${PUBLIC_IP}
address=/abema.tv/${PUBLIC_IP}
address=/hulu.jp/${PUBLIC_IP}
address=/optus.com.au/${PUBLIC_IP}
address=/optusnet.com.au/${PUBLIC_IP}
address=/gamer.com.tw/${PUBLIC_IP}
address=/bahamut.com.tw/${PUBLIC_IP}
address=/hinet.net/${PUBLIC_IP}
address=/dmm.com/${PUBLIC_IP}
address=/dmm.co.jp/${PUBLIC_IP}
address=/dmm-extension.com/${PUBLIC_IP}
address=/dmmapis.com/${PUBLIC_IP}
address=/videomarket.jp/${PUBLIC_IP}
address=/p-smith.com/${PUBLIC_IP}
address=/img.vm-movie.jp/${PUBLIC_IP}
address=/saima.zlzd.xyz/${PUBLIC_IP}
address=/challenges.cloudflare.com/${PUBLIC_IP}
address=/ai.com/${PUBLIC_IP}
address=/auth0.com/${PUBLIC_IP}
address=/identrust.com/${PUBLIC_IP}
address=/openai.com/${PUBLIC_IP}
address=/cdn.oaistatic.com/${PUBLIC_IP}
address=/aiv-cdn.net/${PUBLIC_IP}
address=/aiv-delivery.net/${PUBLIC_IP}
address=/amazonprimevideo.cn/${PUBLIC_IP}
address=/amazonprimevideo.com.cn/${PUBLIC_IP}
address=/amazonprimevideos.com/${PUBLIC_IP}
address=/amazonvideo.cc/${PUBLIC_IP}
address=/media-amazon.com/${PUBLIC_IP}
address=/prime-video.com/${PUBLIC_IP}
address=/primevideo.cc/${PUBLIC_IP}
address=/primevideo.com/${PUBLIC_IP}
address=/primevideo.info/${PUBLIC_IP}
address=/primevideo.org/${PUBLIC_IP}
address=/primevideo.tv/${PUBLIC_IP}
address=/pv-cdn.net/${PUBLIC_IP}
address=/chatgpt.com/${PUBLIC_IP}
address=/cdn.usefathom.com/${PUBLIC_IP}
address=/anthropic.com/${PUBLIC_IP}
address=/claude.ai/${PUBLIC_IP}
address=/byteoversea.com/${PUBLIC_IP}
address=/ibytedtos.com/${PUBLIC_IP}
address=/ipstatp.com/${PUBLIC_IP}
address=/muscdn.com/${PUBLIC_IP}
address=/musical.ly/${PUBLIC_IP}
address=/tiktok.com/${PUBLIC_IP}
address=/tik-tokapi.com/${PUBLIC_IP}
address=/tiktokcdn.com/${PUBLIC_IP}
address=/tiktokv.com/${PUBLIC_IP}
address=/youtube.com/${PUBLIC_IP}
address=/youtubei.googleapis.com/${PUBLIC_IP}
EOF

    if ! grep -q "^conf-dir=/etc/dnsmasq.d" /etc/dnsmasq.conf; then
        echo -e "\033[0;36mINFO: 正在为 dnsmasq.conf 添加 'conf-dir' 配置...\033[0m"
        echo -e "\n# Load configurations from /etc/dnsmasq.d\nconf-dir=/etc/dnsmasq.d/,*.conf" | tee -a /etc/dnsmasq.conf
    fi
    
    echo -e "\033[0;36mINFO: 正在重启Dnsmasq服务以加载新配置...\033[0m"
    systemctl restart dnsmasq
    if systemctl is-active --quiet dnsmasq; then
        echo -e "\033[0;32mSUCCESS: Dnsmasq配置完成并已重启。\033[0m"
    else
        echo -e "\033[0;31mERROR: Dnsmasq服务重启失败。\033[0m"; return 1;
    fi
    echo
    echo -e "\033[0;32m🎉 恭喜！全新的 DNS 解锁服务 (Gost v3) 已成功安装！它现在独立于您其他的Gost转发服务运行。\033[0m"
}


uninstall_dns_unlock_server() {
    clear
    echo -e "\033[0;33m--- DNS解锁服务 卸载 ---\033[0m"
    echo -e "\033[0;36mINFO: 正在停止并卸载 Gost DNS解锁服务 (${DNS_GOST_SERVICE_NAME})...\033[0m"
    systemctl stop "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    systemctl disable "${DNS_GOST_SERVICE_NAME}" 2>/dev/null
    rm -f "${DNS_GOST_SERVICE_PATH}"
    rm -f "${DNS_GOST_CONFIG_PATH}"
    systemctl daemon-reload
    
    # --- 智能卸载检查 ---
    # 定义主脚本的服务路径 (根据gost.sh脚本通常的路径)
    MAIN_GOST_SERVICE_PATH="/usr/lib/systemd/system/gost.service" 
    if [[ -f "${MAIN_GOST_SERVICE_PATH}" ]]; then
        echo -e "\033[0;33mWARNING: 检测到主Gost转发服务(${MAIN_GOST_SERVICE_PATH})存在。\033[0m"
        echo -e "\033[0;36mINFO: 为避免破坏主服务，将不会删除 'gost' 程序本体。\033[0m"
    else
        echo -e "\033[0;36mINFO: 未检测到其他Gost服务，将一并删除 'gost' 程序本体。\033[0m"
        # 卸载时同样删除gost二进制，因为安装时是脚本管理的
        rm -f "$(command -v gost)"
    fi
    echo
    
    echo -e "\033[0;36mINFO: 正在卸载 Dnsmasq 服务及相关配置...\033[0m"
    systemctl stop dnsmasq 2>/dev/null
    rm -f /etc/dnsmasq.d/custom_unlock.conf
    sed -i '/^# Load configurations from \/etc\/dnsmasq.d/d' /etc/dnsmasq.conf 2>/dev/null
    sed -i '/^conf-dir=\/etc\/dnsmasq.d/d' /etc/dnsmasq.conf 2>/dev/null
    apt-get purge -y dnsmasq >/dev/null 2>&1
    echo -e "\033[0;32mSUCCESS: Dnsmasq 及相关配置已卸载。\033[0m"
    echo
    echo -e "\033[0;32m✅ 所有 DNS 解锁服务组件均已卸载完毕。\033[0m"
}

setup_dns_client() {
    clear
    echo -e "\033[0;33m--- 设置 DNS 客户端 ---\033[0m"
    read -p "请输入您的 DNS 解锁服务器的 IP 地址: " server_ip
    if ! [[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo -e "\033[0;31m错误: 您输入的不是一个有效的 IP 地址。\033[0m"; return 1; fi
    echo -e "\033[0;36mINFO: 正在备份当前的 DNS 配置...\033[0m"
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        mv /etc/resolv.conf "/etc/resolv.conf.bak_$(date +%Y%m%d_%H%M%S)"
        echo -e "\033[0;32mINFO: 原有配置已备份至 /etc/resolv.conf.bak_...\033[0m"
    fi
    echo -e "\033[0;36mINFO: 正在写入新的 DNS 配置...\033[0m"
    echo "nameserver $server_ip" | tee /etc/resolv.conf > /dev/null
    echo -e "\033[0;36mINFO: 正在锁定 DNS 配置文件以防被覆盖...\033[0m"
    if chattr +i /etc/resolv.conf; then echo -e "\033[0;32mSUCCESS: 客户端 DNS 已成功设置为 ${server_ip} 并已锁定！\033[0m"; else echo -e "\033[0;31mERROR: 锁定 /etc/resolv.conf 文件失败。\033[0m"; fi
}

uninstall_dns_client() {
    clear
    echo -e "\033[0;33m--- 卸载/还原 DNS 客户端设置 ---\033[0m"
    echo -e "\033[0;36mINFO: 正在解锁 DNS 配置文件...\033[0m"
    chattr -i /etc/resolv.conf 2>/dev/null
    local latest_backup
    latest_backup=$(ls -t /etc/resolv.conf.bak_* 2>/dev/null | head -n 1)
    if [[ -f "$latest_backup" ]]; then
        echo -e "\033[0;36mINFO: 正在从备份文件 $latest_backup 还原...\033[0m"
        mv "$latest_backup" /etc/resolv.conf
        echo -e "\033[0;32mSUCCESS: DNS 配置已成功从备份还原。\033[0m"
    else
        echo -e "\033[0;33mWARNING: 未找到备份文件。正在设置为通用 DNS (8.8.8.8)...\033[0m"
        echo "nameserver 8.8.8.8" | tee /etc/resolv.conf > /dev/null
        echo -e "\033[0;32mSUCCESS: DNS 已设置为通用公共服务器。\033[0m"
    fi
}

manage_iptables_rules() {
    if ! dpkg -l | grep -q 'iptables-persistent'; then
        echo -e "\033[0;33mWARNING: 'iptables-persistent' 未安装，规则可能无法自动持久化。\033[0m"
        read -p "是否现在尝试安装? (y/N): " install_confirm
        if [[ "$install_confirm" =~ ^[yY]$ ]]; then apt-get update && apt-get install -y iptables-persistent; fi
    fi
    while true; do
        clear
        echo -e "\033[0;33m══════ IP 白名单管理 (端口 53, 80, 443) ══════\033[0m"
        echo -e "管理 DNS(53) 和 Gost(80, 443) 的访问权限。"
        echo -e "\033[0;36m当前生效的相关规则:\033[0m"
        iptables -L INPUT -v -n --line-numbers | grep -E 'dpt:53|dpt:80|dpt:443' || echo -e "  (无相关规则)"
        echo -e "\033[0;33m────────────────────────────────────────────\033[0m"
        echo "1. 添加白名单IP (允许访问)"
        echo "2. 删除白名单IP (根据行号)"
        echo "3. 应用 '默认拒绝' 规则 (推荐)"
        echo "0. 返回上级菜单"
        echo -e "\033[0;33m════════════════════════════════════════════\033[0m"
        read -p "请输入选项: " rule_choice
        case $rule_choice in
        1)
            read -p "请输入要加入白名单的IP (单个IP): " ip
            if [[ -z "$ip" ]]; then continue; fi
            for port in 53 80 443; do
                iptables -I INPUT -s "$ip" -p tcp --dport $port -j ACCEPT
                if [[ "$port" == "53" ]]; then iptables -I INPUT -s "$ip" -p udp --dport $port -j ACCEPT; fi
            done
            echo -e "\033[0;32mIP $ip 已添加至端口 53, 80, 443 白名单。\033[0m"
            netfilter-persistent save && echo -e "\033[0;32m防火墙规则已保存。\033[0m" || echo -e "\033[0;31m防火墙规则保存失败。\033[0m"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        2)
            read -p "请输入要删除的规则的行号: " line_num
            if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then continue; fi
            iptables -D INPUT "$line_num"
            echo -e "\033[0;32m规则 ${line_num} 已删除。\033[0m"
            netfilter-persistent save && echo -e "\033[0;32m防火墙规则已保存。\033[0m" || echo -e "\033[0;31m防火墙规则保存失败。\033[0m"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        3)
            echo -e "\033[0;36mINFO: 这将确保所有不在白名单的IP无法访问相关端口。\033[0m"
            for port in 53 80 443; do
                if ! iptables -C INPUT -p tcp --dport $port -j DROP &>/dev/null; then iptables -A INPUT -p tcp --dport $port -j DROP; fi
                if [[ "$port" == "53" ]]; then if ! iptables -C INPUT -p udp --dport $port -j DROP &>/dev/null; then iptables -A INPUT -p udp --dport $port -j DROP; fi; fi
            done
            echo -e "\032m'默认拒绝' 规则已应用/确认存在。\033[0m"
            netfilter-persistent save && echo -e "\033[0;32m防火墙规则已保存。\033[0m" || echo -e "\033[0;31m防火墙规则保存失败。\033[0m"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        0) break ;;
        *) echo -e "\033[0;31m无效选项!\033[0m"; sleep 1;;
        esac
    done
}


# ======================= 主逻辑入口 =======================

# --- 运行主逻辑 ---
dns_unlock_menu
