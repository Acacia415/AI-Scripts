#!/bin/bash

# ==========================================
# IRIS自用工具箱 - GitHub一键版
# 项目地址：https://github.com/Acacia415/AI-Scripts
# ==========================================

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ===================== IRIS 工具箱快捷键自动安装 =====================

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 权限运行本脚本 (例如: sudo bash $0)${NC}"
    exit 1
fi

# 1. 清理旧的 alias 快捷方式
sed -i '/^alias p=/d' ~/.bashrc > /dev/null 2>&1
sed -i '/^alias p=/d' ~/.profile > /dev/null 2>&1
sed -i '/^alias p=/d' ~/.bash_profile > /dev/null 2>&1

# 2. 定义本地脚本存放路径
LOCAL_SCRIPT="$HOME/tool.sh"

# 3. 判断执行方式
if [[ "$0" == "/dev/fd/"* || "$0" == "/proc/self/fd/"* ]]; then
    # 通过 bash <(curl …) 执行
    curl -fsSL https://link.irisu.de/toolbox -o "$LOCAL_SCRIPT"
else
    # 本地文件执行
    cp -f "$(realpath "$0")" "$LOCAL_SCRIPT"
fi

# 4. 将脚本复制到 /usr/local/bin/p 并赋予可执行权限
cp -f "$LOCAL_SCRIPT" /usr/local/bin/p
chmod +x /usr/local/bin/p

# 5. 提示信息（首次运行或直接执行脚本时显示）
if [[ $(realpath "$0") != "/usr/local/bin/p" ]]; then
    echo -e "${GREEN}[+] 已创建快捷命令：p ✅${NC}"
    echo -e "${GREEN}    现在您可以在终端中直接输入 'p' 来运行此工具箱。${NC}"
fi





# ======================= 系统信息查询 =======================
display_system_info() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/display_system_info.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/display_system_info.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 开启root用户登录 =======================
enable_root_login() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/enable_root_login.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/enable_root_login.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装流量监控服务 =======================
install_traffic_monitor() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/install_traffic_monitor.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/install_traffic_monitor.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 完全卸载流量监控 =======================
uninstall_traffic_monitor() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/uninstall_traffic_monitor.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/uninstall_traffic_monitor.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装snell协议 =======================
install_snell() {
    clear
    # 添加来源提示（使用工具箱内置颜色变量）
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/xOS/Snell${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O snell.sh https://raw.githubusercontent.com/xOS/Snell/master/Snell.sh; then
        chmod +x snell.sh
        ./snell.sh
        rm -f snell.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Snell 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装Hysteria2协议 =======================
install_hysteria2() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Misaka-blog/hysteria-install${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -N --no-check-certificate https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/hysteria.sh; then
        chmod +x hysteria.sh
        bash hysteria.sh
        rm -f hysteria.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Hysteria2 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装SS协议 =======================
install_ss_rust() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/xOS/Shadowsocks-Rust${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -O ss-rust.sh --no-check-certificate https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh; then
        chmod +x ss-rust.sh
        ./ss-rust.sh
        rm -f ss-rust.sh  # 清理安装脚本
    else
        echo -e "${RED}下载 SS-Rust 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ====================== 安装 ShadowTLS ======================
install_shadowtls() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Kismet0123/ShadowTLS-Manager${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if wget -O ShadowTLS_Manager.sh --no-check-certificate https://raw.githubusercontent.com/Kismet0123/ShadowTLS-Manager/refs/heads/main/ShadowTLS_Manager.sh; then
        chmod +x ShadowTLS_Manager.sh
        ./ShadowTLS_Manager.sh
        rm -f ShadowTLS_Manager.sh  # 清理安装脚本
    else
        echo -e "${RED}下载 ShadowTLS 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 一键IPTables转发 =======================
install_iptables_forward() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}一键IPTables转发管理工具${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/iptables_forward.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/iptables.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 IPTables转发 脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 一键GOST转发 =======================
install_gost_forward() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}一键GOST转发管理工具${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/Multi-EasyGost${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/gost_forward.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/Multi-EasyGost/refs/heads/test/gost.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 GOST转发 脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装3X-UI面板 =======================
install_3x_ui() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/mhsanaei/3x-ui${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/3x-ui_install.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 3X-UI 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 流媒体检测 =======================
install_media_check() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：ip.check.place${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/media_check.sh"
    if curl -L -s -o "$install_script" ip.check.place; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载流媒体检测脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}


# ======================= Speedtest测速 =======================
install_speedtest() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}Speedtest测速组件安装${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 下载packagecloud安装脚本
    local install_script="/tmp/speedtest_install.sh"
    echo -e "${CYAN}下载Speedtest安装脚本...${NC}"
    if ! curl -s --ssl https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh -o "$install_script"; then
        echo -e "${RED}下载Speedtest安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 执行安装脚本
    echo -e "${CYAN}添加Speedtest仓库...${NC}"
    if ! sudo bash "$install_script"; then
        echo -e "${RED}添加仓库失败！${NC}"
        rm -f "$install_script"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    rm -f "$install_script"
    
    # 更新软件源并安装
    echo -e "${CYAN}安装Speedtest...${NC}"
    if ! sudo apt-get update || ! sudo apt-get install -y speedtest; then
        echo -e "${RED}安装Speedtest失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
    # 自动执行测速
    echo -e "${CYAN}开始网络测速...${NC}"
    speedtest --accept-license --accept-gdpr
}


# ======================= BestTrace回程测试 =======================
install_besttrace() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}BestTrace三网回程延迟路由测试${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 检查是否已安装wget
    if ! command -v wget &> /dev/null; then
        echo -e "${CYAN}安装wget...${NC}"
        if ! sudo apt-get update || ! sudo apt-get install -y wget; then
            echo -e "${RED}安装wget失败！${NC}"
            return 1
        fi
    fi
    
    # 下载并执行besttrace脚本
    echo -e "${CYAN}开始BestTrace测试...${NC}"
    wget -qO- git.io/besttrace | bash
    
    echo -e "${GREEN}BestTrace测试完成！${NC}"
}


# ====================== 修改后的Nginx管理函数 =======================
nginx_main() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local nginx_script="/tmp/nginx-manager.sh"
    
    if wget -O "$nginx_script" --no-check-certificate \
        https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/nginx-manager.sh; then
        chmod +x "$nginx_script"
        "$nginx_script"
        rm -f "$nginx_script"
    else
        echo -e "${RED}错误：Nginx 管理脚本下载失败！${NC}"
    fi
    
}


# ======================= TCP性能优化 =======================
install_magic_tcp() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/qiuxiuya/magicTCP${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 用户确认环节
    read -p "是否要执行TCP性能优化？[y/N] " confirm
    if [[ ! "$confirm" =~ [yY] ]]; then
        echo -e "${BLUE}操作已取消${NC}"
        return 1
    fi
    
    # 网络检测环节
    if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
        echo -e "${RED}❌ 网络连接异常，无法访问GitHub${NC}"
        return 1
    fi
    
    # 执行优化脚本
    echo -e "${CYAN}正在应用TCP优化参数...${NC}"
    if bash <(curl -sSL https://raw.githubusercontent.com/qiuxiuya/magicTCP/main/main.sh); then
        echo -e "${GREEN}✅ 优化成功完成，重启后生效${NC}"
    else
        echo -e "${RED}❌ 优化过程中出现错误，请检查：${NC}"
        echo -e "${RED}1. 系统是否为Debian/Ubuntu${NC}"
        echo -e "${RED}2. 是否具有root权限${NC}"
        echo -e "${RED}3. 查看日志：/var/log/magic_tcp.log${NC}"
        return 1
    fi
}


# ======================= DNS解锁服务 =======================
install_dns_unlock() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}DNS解锁服务管理工具${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/dns_unlock.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/dns_unlock.sh; then
        # 转换行尾符，避免CRLF导致的执行问题
        sed -i 's/\r$//' "$install_script" 2>/dev/null || dos2unix "$install_script" 2>/dev/null
        chmod +x "$install_script"
        # DNS解锁脚本需要root权限来安装服务和修改配置（主脚本已确保root权限）
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载 DNS解锁 脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 搭建TG图床 =======================
install_tg_image_host() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo # Add an empty line for spacing

    local install_script_url="https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/install_imghub.sh"
    local temp_install_script="/tmp/tg_imghub_install.sh"

    echo -e "${CYAN}正在下载 TG图床 安装脚本...${NC}"
    if curl -sSL -o "$temp_install_script" "$install_script_url"; then
        chmod +x "$temp_install_script"
        echo -e "${GREEN}下载完成，开始执行安装脚本...${NC}"
        # Execute the script
        "$temp_install_script"
        # Optionally, remove the script after execution
        rm -f "$temp_install_script"
        echo -e "${GREEN}TG图床 安装脚本执行完毕。${NC}"
        # 成功时，不再有模块内部的 read 暂停
    else
        echo -e "${RED}下载 TG图床 安装脚本失败！${NC}"
        # 失败时，移除了这里的 read 暂停
        # read -n 1 -s -r -p "按任意键返回主菜单..." # 已移除
        return 1 # 仍然返回错误码，主菜单可以根据需要处理或忽略
    fi
    # 确保函数末尾没有其他 read 暂停
    # # Add a pause before returning to the main menu, if desired, after successful installation
    # # read -n 1 -s -r -p "安装完成，按任意键返回主菜单..." # 此行保持注释或删除
}

# ======================= 安装Fail2Ban =======================
install_fail2ban() {
    clear
    # 添加来源提示（使用工具箱内置颜色变量）
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O install_fail2ban.sh https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/install_fail2ban.sh; then
        chmod +x install_fail2ban.sh
        ./install_fail2ban.sh
        rm -f install_fail2ban.sh  # 新增清理步骤
    else
        echo -e "${RED}下载 Fail2Ban 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装 acme.sh =======================
install_acme() {
    clear
    # 添加来源提示
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/acme-script${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O acme.sh https://raw.githubusercontent.com/Acacia415/acme-script/refs/heads/main/acme.sh; then
        chmod +x acme.sh
        ./acme.sh
        rm -f acme.sh  # 执行后清理脚本
    else
        echo -e "${RED}下载 acme.sh 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装 Gost v3 =======================
install_gost_v3() {
    clear
    # 添加来源提示
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O gost_v3.sh https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/gost_v3.sh; then
        chmod +x gost_v3.sh
        ./gost_v3.sh
        rm -f gost_v3.sh  # 执行后清理脚本
    else
        echo -e "${RED}下载 Gost v3 安装脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 修改主机名 =======================
change_hostname() {
    clear
    # 添加来源提示
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    # 执行安装流程（增加错误处理和自动清理）
    if wget -O change_hostname.sh https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/change_hostname.sh; then
        chmod +x change_hostname.sh
        ./change_hostname.sh
        rm -f change_hostname.sh  # 执行后清理脚本
    else
        echo -e "${RED}下载主机名修改脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 开放所有端口 =======================
open_all_ports() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/open_all_ports.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/open_all_ports.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= Caddy反代管理 =======================
caddy_manager() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/caddy_manager.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/caddy_manager.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= IP优先级设置 =======================
modify_ip_preference() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/modify_ip_preference.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/modify_ip_preference.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 命令行美化 =======================
install_shell_beautify() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/install_shell_beautify.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/install_shell_beautify.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装Sub-Store =======================
install_substore() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/install_substore.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/install_substore.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= TCP性能优化(BBR+fq) =======================
optimize_tcp_bbr() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/optimize_tcp_bbr.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/optimize_tcp_bbr.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 恢复TCP原始配置 =======================
restore_tcp_config() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/restore_tcp_config.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/restore_tcp_config.sh; then
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 系统重装 =======================
reinstall_system() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/bin456789/reinstall${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/reinstall_system.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/reinstall_system.sh; then
        # 转换行尾符，避免CRLF导致的执行问题
        sed -i 's/\r$//' "$install_script" 2>/dev/null || dos2unix "$install_script" 2>/dev/null
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 时间同步 =======================
sync_time() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}时间同步脚本${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    local install_script="/tmp/sync-time.sh"
    if curl -Ls -o "$install_script" https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/sync-time.sh; then
        # 转换行尾符，避免CRLF导致的执行问题
        sed -i 's/\r$//' "$install_script" 2>/dev/null || dos2unix "$install_script" 2>/dev/null
        chmod +x "$install_script"
        "$install_script"
        rm -f "$install_script"
    else
        echo -e "${RED}下载时间同步脚本失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 脚本更新 =======================
update_script() {
  echo -e "${YELLOW}开始更新脚本...${NC}"
  
  # 删除旧脚本
  rm -f /root/tool.sh
  
  # 下载并执行新脚本
  if curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/tool.sh -o /root/tool.sh && 
     chmod +x /root/tool.sh
  then
    echo -e "${GREEN}更新成功，即将启动新脚本...${NC}"
    sleep 2
    exec /root/tool.sh  # 用新脚本替换当前进程
  else
    echo -e "${RED}更新失败！请手动执行："
    echo -e "curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/tool.sh -o tool.sh"
    echo -e "chmod +x tool.sh && ./tool.sh${NC}"
    exit 1
  fi
}

# ======================= 卸载工具箱 =======================
uninstall_toolbox() {
  clear
  echo -e "${RED}════════════════════════════════════${NC}"
  echo -e "${RED}         卸载 IRIS 工具箱          ${NC}"
  echo -e "${RED}════════════════════════════════════${NC}"
  echo
  echo -e "${YELLOW}警告：此操作将完全卸载工具箱，包括：${NC}"
  echo -e "  - 删除快捷命令 'p'"
  echo -e "  - 删除 /usr/local/bin/p"
  echo -e "  - 删除 $HOME/tool.sh"
  echo -e "  - 清理所有相关配置"
  echo
  read -p "确认要卸载吗？(输入 YES 确认): " confirm
  
  if [[ "$confirm" != "YES" ]]; then
    echo -e "${BLUE}已取消卸载操作${NC}"
    sleep 2
    return
  fi
  
  echo -e "${YELLOW}正在卸载工具箱...${NC}"
  
  # 删除快捷命令文件
  if [ -f /usr/local/bin/p ]; then
    rm -f /usr/local/bin/p
    echo -e "${GREEN}✓ 已删除 /usr/local/bin/p${NC}"
  fi
  
  # 删除本地备份
  if [ -f "$HOME/tool.sh" ]; then
    rm -f "$HOME/tool.sh"
    echo -e "${GREEN}✓ 已删除 $HOME/tool.sh${NC}"
  fi
  
  # 清理可能存在的 alias（虽然当前版本没用到，但为了兼容性）
  sed -i '/^alias p=/d' ~/.bashrc 2>/dev/null
  sed -i '/^alias p=/d' ~/.profile 2>/dev/null
  sed -i '/^alias p=/d' ~/.bash_profile 2>/dev/null
  echo -e "${GREEN}✓ 已清理配置文件${NC}"
  
  echo
  echo -e "${GREEN}════════════════════════════════════${NC}"
  echo -e "${GREEN}   工具箱已完全卸载！感谢使用！   ${NC}"
  echo -e "${GREEN}════════════════════════════════════${NC}"
  echo
  echo -e "${CYAN}如需重新安装，请执行：${NC}"
  echo -e "${YELLOW}bash <(curl -fsSL https://link.irisu.de/toolbox)${NC}"
  echo
  read -n 1 -s -r -p "按任意键退出..."
  exit 0
}

# ======================= 主菜单 =======================
main_menu() {
  while true; do
    clear
    echo -e "${CYAN}"
    
    # 检测 figlet 是否安装
    if ! command -v figlet >/dev/null 2>&1; then
        echo "检测到 figlet 未安装，正在自动安装..."
        # Debian/Ubuntu 系统安装
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y figlet
        # CentOS/RHEL 系统安装
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y figlet
        else
            echo "请手动安装 figlet 后再运行脚本"
        fi
    fi

    # 使用 figlet 输出 IRIS TOOLBOX，删除空行
    if command -v figlet >/dev/null 2>&1; then
        figlet -f small "IRIS TOOLBOX" | awk 'NF'
    else
        echo "IRIS TOOLBOX"  # 如果安装失败，用简单文字替代
    fi

    echo -e "${NC}"  # 恢复默认颜色

    # 菜单部分（双列显示）
    echo -e "${YELLOW}==========================================================================${NC}"
    printf "%-36s %-36s\n" "1. 系统信息查询" "17. Nginx管理"
    printf "%-36s %-36s\n" "2. 开启root用户登录" "18. IP优先级设置"
    printf "%-36s %-36s\n" "3. 安装流量监控服务" "19. TCP性能优化"
    printf "%-36s %-36s\n" "4. 完全卸载流量监控" "20. 命令行美化"
    printf "%-36s %-36s\n" "5. 安装 Snell 协议服务" "21. DNS解锁服务"
    printf "%-36s %-36s\n" "6. 安装 Hysteria2 协议服务" "22. 安装Sub-Store"
    printf "%-36s %-36s\n" "7. 安装 SS-Rust 协议服务" "23. 搭建TG图床"
    printf "%-36s %-36s\n" "8. 安装 ShadowTLS" "24. TCP性能优化 (BBR+fq)"
    printf "%-36s %-36s\n" "9. 一键IPTables转发" "25. 恢复TCP原始配置"
    printf "%-36s %-36s\n" "10. 一键GOST转发" "26. 安装Fail2Ban"
    printf "%-36s %-36s\n" "11. 安装 3X-UI 管理面板" "27. 安装 acme.sh"
    printf "%-36s %-36s\n" "12. 流媒体解锁检测" "28. 安装 Gost v3"
    printf "%-36s %-36s\n" "13. Speedtest网络测速" "29. 修改主机名"
    printf "%-36s %-36s\n" "14. BestTrace回程测试" "30. 重装系统"
    printf "%-36s %-36s\n" "15. 开放所有端口" "31. 时间同步"
    printf "%-36s\n" "16. Caddy反代管理"
    echo -e "${YELLOW}==========================================================================${NC}"
    printf "%-36s %-36s\n" "0. 退出脚本" ""
    echo -e "${YELLOW}-------------------------------------------------------------------------${NC}"
    printf "%-36s %-36s\n" "99. 脚本更新" "98. 卸载工具箱"
    echo -e "${YELLOW}==========================================================================${NC}"
    
    read -p "请输入选项 : " choice
    case $choice in
      1)
        display_system_info
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      2)
        enable_root_login
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      3)
        install_traffic_monitor
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      4)
        uninstall_traffic_monitor
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      5) 
        install_snell 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      6)  
        install_hysteria2 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      7)  
        install_ss_rust 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      8)  
        install_shadowtls 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      9)  
        install_iptables_forward 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      10)  
        install_gost_forward 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      11)  
        install_3x_ui 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      12)  
        install_media_check 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      13)  
        install_speedtest 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      14)  
        install_besttrace 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      15)
        open_all_ports
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      16)
        caddy_manager
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      17)
        nginx_main
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      18)
        modify_ip_preference
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      19)
        install_magic_tcp 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      20)
        install_shell_beautify
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      21)  
        install_dns_unlock
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      22)
        install_substore
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      23)  
        install_tg_image_host 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      24)
        optimize_tcp_bbr
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      25)
        restore_tcp_config
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      26)
        install_fail2ban 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      27)
        install_acme 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      28)
        install_gost_v3 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      29)
        change_hostname 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      30)
        reinstall_system
        # 重装系统后会自动重启，不需要返回主菜单
        ;;
      31)
        sync_time
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      99)  
        update_script 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      98)
        uninstall_toolbox
        # 卸载函数会自动退出，不需要返回主菜单
        ;;
      0) 
        echo -e "${GREEN}已退出${NC}"
        exit 0
        ;;
      *) 
        echo -e "${RED}无效选项，请重新输入${NC}"
        sleep 1
        ;;
    esac
  done
}


# ======================= 执行入口 =======================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo -i 切换root用户后再运行本脚本！${NC}"
  exit 1
fi

# Bash版本检查
if (( BASH_VERSINFO < 4 )); then
  echo -e "${RED}需要Bash 4.0及以上版本${NC}"
  exit 1
fi

main_menu

