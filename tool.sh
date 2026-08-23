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

# 下载与安装配置
AI_SCRIPTS_REF="${AI_SCRIPTS_REF:-main}"
AI_SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/${AI_SCRIPTS_REF}"
TOOLBOX_LOCAL_SCRIPT="${AI_SCRIPTS_LOCAL_SCRIPT:-$HOME/tool.sh}"
TOOLBOX_COMMAND_PATH="${AI_SCRIPTS_COMMAND_PATH:-/usr/local/bin/p}"
TOOLBOX_BACKUP_ROOT="${AI_SCRIPTS_BACKUP_ROOT:-/var/backups/ai-scripts/toolbox}"

download_shell_script() {
    local url=$1
    local label=${2:-远程脚本}
    local temp_file

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}${label}下载失败：系统未安装 curl。${NC}" >&2
        return 1
    fi

    temp_file=$(mktemp /tmp/ai-scripts-download.XXXXXX.sh) || {
        echo -e "${RED}${label}下载失败：无法创建安全临时文件。${NC}" >&2
        return 1
    }

    if ! curl -fL --silent --show-error \
        --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 300 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        -o "$temp_file" "$url"; then
        echo -e "${RED}${label}下载失败：服务器返回错误或网络不可用。${NC}" >&2
        rm -f -- "$temp_file"
        return 1
    fi

    if [[ ! -s $temp_file ]]; then
        echo -e "${RED}${label}下载失败：下载内容为空。${NC}" >&2
        rm -f -- "$temp_file"
        return 1
    fi

    # 兼容错误上传为 CRLF 的脚本，再进行语法检查。
    sed -i 's/\r$//' "$temp_file" 2>/dev/null || true
    if ! /bin/bash -n "$temp_file"; then
        echo -e "${RED}${label}下载失败：脚本语法检查未通过，未执行。${NC}" >&2
        rm -f -- "$temp_file"
        return 1
    fi

    chmod 700 "$temp_file" || {
        echo -e "${RED}${label}下载失败：无法设置临时文件权限。${NC}" >&2
        rm -f -- "$temp_file"
        return 1
    }
    printf '%s\n' "$temp_file"
}

run_remote_script() {
    local url=$1
    local label=$2
    local script_path status=0
    shift 2

    script_path=$(download_shell_script "$url" "$label") || return 1
    /bin/bash "$script_path" "$@" || status=$?
    rm -f -- "$script_path"

    if (( status != 0 )); then
        echo -e "${RED}${label}执行失败（退出码：${status}）。${NC}" >&2
    fi
    return "$status"
}

run_repo_script() {
    local path=$1
    local label=$2
    shift 2
    run_remote_script "${AI_SCRIPTS_RAW_BASE}/${path}" "$label" "$@"
}

atomic_install_file() {
    local source_file=$1
    local target_file=$2
    local mode=${3:-755}
    local target_dir temp_file

    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir" || return 1
    temp_file=$(mktemp "${target_dir}/.ai-scripts-$(basename "$target_file").XXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    if ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

create_toolbox_backup() {
    local backup_prefix backup_dir
    backup_prefix="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    install -d -m 700 "$TOOLBOX_BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "${TOOLBOX_BACKUP_ROOT}/${backup_prefix}.XXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1

    if [[ -e $TOOLBOX_LOCAL_SCRIPT ]]; then
        cp -a -- "$TOOLBOX_LOCAL_SCRIPT" "$backup_dir/tool.sh" || return 1
    else
        : > "$backup_dir/tool.sh.missing"
    fi
    if [[ -e $TOOLBOX_COMMAND_PATH ]]; then
        cp -a -- "$TOOLBOX_COMMAND_PATH" "$backup_dir/p" || return 1
    else
        : > "$backup_dir/p.missing"
    fi
    chmod 600 "$backup_dir"/* 2>/dev/null || true
    printf '%s\n' "$backup_dir"
}

restore_toolbox_backup() {
    local backup_dir=$1
    local status=0

    if [[ -f $backup_dir/tool.sh.missing ]]; then
        rm -f -- "$TOOLBOX_LOCAL_SCRIPT" || status=1
    elif [[ -f $backup_dir/tool.sh ]]; then
        atomic_install_file "$backup_dir/tool.sh" "$TOOLBOX_LOCAL_SCRIPT" 755 || status=1
    else
        status=1
    fi

    if [[ -f $backup_dir/p.missing ]]; then
        rm -f -- "$TOOLBOX_COMMAND_PATH" || status=1
    elif [[ -f $backup_dir/p ]]; then
        atomic_install_file "$backup_dir/p" "$TOOLBOX_COMMAND_PATH" 755 || status=1
    else
        status=1
    fi
    return "$status"
}

install_toolbox_copies() {
    local source_file=$1
    local backup_dir
    TOOLBOX_LAST_BACKUP=''

    if [[ -f $TOOLBOX_LOCAL_SCRIPT && -f $TOOLBOX_COMMAND_PATH ]] \
        && cmp -s -- "$source_file" "$TOOLBOX_LOCAL_SCRIPT" \
        && cmp -s -- "$source_file" "$TOOLBOX_COMMAND_PATH"; then
        return 0
    fi

    backup_dir=$(create_toolbox_backup) || return 1
    TOOLBOX_LAST_BACKUP=$backup_dir
    if atomic_install_file "$source_file" "$TOOLBOX_LOCAL_SCRIPT" 755 \
        && atomic_install_file "$source_file" "$TOOLBOX_COMMAND_PATH" 755; then
        return 0
    fi

    restore_toolbox_backup "$backup_dir" || \
        echo -e "${RED}快捷命令自动恢复失败，请从 ${backup_dir} 手动恢复。${NC}" >&2
    return 1
}

# ===================== IRIS 工具箱快捷键自动安装 =====================

if [[ ${AI_SCRIPTS_SOURCE_ONLY:-0} != 1 ]]; then
    # 确保以 root 权限运行
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行本脚本 (例如: sudo bash $0)${NC}"
        exit 1
    fi

    # 1. 清理旧的 alias 快捷方式
    sed -i '/^alias p=/d' ~/.bashrc > /dev/null 2>&1
    sed -i '/^alias p=/d' ~/.profile > /dev/null 2>&1
    sed -i '/^alias p=/d' ~/.bash_profile > /dev/null 2>&1

    # 2. 进程替换执行时重新获取远程 main；本地执行时使用当前已运行脚本。
    toolbox_source=''
    toolbox_download=''
    if [[ "$0" == "/dev/fd/"* || "$0" == "/proc/self/fd/"* ]]; then
        toolbox_url="${AI_SCRIPTS_RAW_BASE}/tool.sh?cachebust=$(date +%s)"
        toolbox_download=$(download_shell_script "$toolbox_url" "工具箱") || exit 1
        toolbox_source=$toolbox_download
    else
        toolbox_source=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
        if [[ ! -s $toolbox_source ]] || ! /bin/bash -n "$toolbox_source"; then
            echo -e "${RED}当前工具箱文件无效，未安装快捷命令。${NC}"
            exit 1
        fi
    fi

    # 3. 以同一事务安装本地脚本和快捷命令，任一目标失败即恢复旧版本。
    if ! install_toolbox_copies "$toolbox_source"; then
        rm -f -- "$toolbox_download"
        echo -e "${RED}工具箱快捷命令安装失败，已尝试恢复原文件。${NC}"
        exit 1
    fi
    rm -f -- "$toolbox_download"
    if [[ -n ${TOOLBOX_LAST_BACKUP:-} ]]; then
        echo -e "${BLUE}工具箱原文件备份：${TOOLBOX_LAST_BACKUP}${NC}"
    fi

    # 4. 提示信息（首次运行或直接执行脚本时显示）
    current_script=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
    if [[ $current_script != "$TOOLBOX_COMMAND_PATH" ]]; then
        echo -e "${GREEN}[+] 已创建快捷命令：p ✅${NC}"
        echo -e "${GREEN}    现在您可以在终端中直接输入 'p' 来运行此工具箱。${NC}"
    fi
fi





# ======================= 系统信息查询 =======================
display_system_info() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "display_system_info.sh" "系统信息查询脚本"; then
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
    
    if ! run_repo_script "enable_root_login.sh" "root 登录配置脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 智能流量监控 =======================
traffic_monitor() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "traffic_monitor.sh" "流量监控脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/xOS/Snell/master/Snell.sh" "Snell 安装脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/hysteria.sh" "Hysteria2 安装脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh" "SS-Rust 安装脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/Kismet0123/ShadowTLS-Manager/refs/heads/main/ShadowTLS_Manager.sh" "ShadowTLS 安装脚本"; then
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
    
    if ! run_repo_script "iptables.sh" "IPTables 转发脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/Acacia415/Multi-EasyGost/refs/heads/test/gost.sh" "GOST 转发脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" "3X-UI 安装脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" "流媒体检测脚本"; then
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
    
    echo -e "${CYAN}下载Speedtest安装脚本...${NC}"
    echo -e "${CYAN}添加Speedtest仓库...${NC}"
    if ! run_remote_script "https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh" "Speedtest 仓库安装脚本"; then
        echo -e "${RED}添加仓库失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
    
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
    
    echo -e "${CYAN}开始BestTrace测试...${NC}"
    if run_remote_script "https://git.io/besttrace" "BestTrace 脚本"; then
        echo -e "${GREEN}BestTrace测试完成！${NC}"
    else
        return 1
    fi
}


# ====================== 修改后的Nginx管理函数 =======================
nginx_main() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    run_repo_script "nginx-manager.sh" "Nginx 管理脚本"
    
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
    
    echo -e "${CYAN}正在应用TCP优化参数...${NC}"
    if run_remote_script "https://raw.githubusercontent.com/qiuxiuya/magicTCP/main/main.sh" "MagicTCP 优化脚本"; then
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
    
    if ! run_repo_script "dns_unlock.sh" "DNS 解锁脚本"; then
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

    echo -e "${CYAN}正在下载 TG图床 安装脚本...${NC}"
    if run_repo_script "install_imghub.sh" "TG 图床安装脚本"; then
        echo -e "${GREEN}TG图床 安装脚本执行完毕。${NC}"
    else
        return 1
    fi
}

# ======================= 安装Fail2Ban =======================
install_fail2ban() {
    clear
    # 添加来源提示（使用工具箱内置颜色变量）
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "install_fail2ban.sh" "Fail2Ban 安装脚本"; then
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
    
    if ! run_remote_script "https://raw.githubusercontent.com/Acacia415/acme-script/refs/heads/main/acme.sh" "acme.sh 安装脚本"; then
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
    
    if ! run_repo_script "gost_v3.sh" "GOST v3 管理脚本"; then
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
    
    if ! run_repo_script "change_hostname.sh" "主机名修改脚本"; then
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
    
    if ! run_repo_script "open_all_ports.sh" "开放端口脚本"; then
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
    
    if ! run_repo_script "caddy_manager.sh" "Caddy 管理脚本"; then
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
    
    if ! run_repo_script "modify_ip_preference.sh" "IP 优先级脚本"; then
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
    
    if ! run_repo_script "install_shell_beautify.sh" "命令行美化脚本"; then
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
    
    if ! run_repo_script "install_substore.sh" "Sub-Store 安装脚本"; then
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
    
    if ! run_repo_script "optimize_tcp_bbr.sh" "TCP 优化脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= BBRv3内核管理 =======================
manage_bbr3() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"

    run_repo_script "bbr3_manager.sh" "BBRv3 管理脚本" menu
}

# ======================= 恢复TCP原始配置 =======================
restore_tcp_config() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "restore_tcp_config.sh" "TCP 配置恢复脚本"; then
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
    
    if ! run_repo_script "reinstall_system.sh" "系统重装脚本"; then
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
    
    if ! run_repo_script "sync-time.sh" "时间同步脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 部署Hexo博客 =======================
deploy_hexo_blog() {
    clear
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    
    local target_script="/usr/local/bin/hexo_manager.sh"
    local install_script
    install_script=$(download_shell_script "${AI_SCRIPTS_RAW_BASE}/Hexo/hexo_manager.sh" "Hexo 管理脚本") || {
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    }
    if atomic_install_file "$install_script" "$target_script" 755; then
        rm -f -- "$install_script"
        "$target_script"
    else
        rm -f -- "$install_script"
        echo -e "${RED}Hexo 管理脚本安装失败！${NC}"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装Hexo_butterfly主题 =======================
install_hexo_butterfly() {
    clear
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    
    if ! run_repo_script "Hexo/butterfly_setup.sh" "Butterfly 主题安装脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 安装 AnyTLS =======================
install_anytls() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "anytls.sh" "AnyTLS 安装脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= SaveAnyBot管理 =======================
saveanybot_manager() {
    clear
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/Acacia415/AI-Scripts${NC}"
    echo -e "${YELLOW}════════════════════════════════════${NC}"
    
    if ! run_repo_script "saveanybot-manager.sh" "SaveAnyBot 管理脚本"; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return 1
    fi
}

# ======================= 脚本更新 =======================
update_script() {
    local update_url new_script backup_dir exec_status

    echo -e "${YELLOW}开始更新脚本...${NC}"
    update_url="${AI_SCRIPTS_RAW_BASE}/tool.sh?cachebust=$(date +%s)"
    new_script=$(download_shell_script "$update_url" "工具箱更新") || return 1

    # 加载一次新脚本的函数定义，确认其初始化路径不会立即报错。
    if ! AI_SCRIPTS_SOURCE_ONLY=1 /bin/bash "$new_script"; then
        echo -e "${RED}新版本预检失败，当前工具箱保持不变。${NC}"
        rm -f -- "$new_script"
        return 1
    fi

    backup_dir=$(create_toolbox_backup) || {
        echo -e "${RED}无法创建更新前备份，已取消更新。${NC}"
        rm -f -- "$new_script"
        return 1
    }

    if ! atomic_install_file "$new_script" "$TOOLBOX_LOCAL_SCRIPT" 755 \
        || ! atomic_install_file "$new_script" "$TOOLBOX_COMMAND_PATH" 755; then
        echo -e "${RED}更新安装失败，正在恢复旧版本。${NC}"
        restore_toolbox_backup "$backup_dir" || \
            echo -e "${RED}自动恢复失败，请从 ${backup_dir} 手动恢复。${NC}"
        rm -f -- "$new_script"
        return 1
    fi
    rm -f -- "$new_script"

    echo -e "${GREEN}更新成功，更新前备份：${backup_dir}${NC}"
    if [[ ${AI_SCRIPTS_NO_EXEC:-0} == 1 ]]; then
        return 0
    fi

    echo -e "${GREEN}即将启动新脚本...${NC}"
    sleep 2
    # 更新成功后必须用新脚本替换当前菜单进程。
    # shellcheck disable=SC2093
    exec "$TOOLBOX_LOCAL_SCRIPT"
    exec_status=$?

    echo -e "${RED}新脚本启动失败，正在恢复旧版本。${NC}"
    restore_toolbox_backup "$backup_dir" || \
        echo -e "${RED}自动恢复失败，请从 ${backup_dir} 手动恢复。${NC}"
    return "$exec_status"
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
    echo "1. 系统信息查询                        19. IP优先级设置"
    echo "2. 开启root用户登录                    20. TCP性能优化"
    echo "3. 智能流量监控                        21. 命令行美化"
    echo "4. 安装 Snell 协议服务                 22. DNS解锁服务"
    echo "5. 安装 Hysteria2 协议服务             23. 安装Sub-Store"
    echo "6. 安装 SS-Rust 协议服务               24. 搭建TG图床"
    echo "7. 安装 ShadowTLS                      25. TCP性能优化 (BBR+fq)"
    echo "8. 一键IPTables转发                    26. 恢复TCP原始配置"
    echo "9. 一键GOST转发                        27. 安装Fail2Ban"
    echo "10. 安装 3X-UI 管理面板                28. 安装 acme.sh"
    echo "11. 流媒体解锁检测                     29. 安装 Gost v3"
    echo "12. Speedtest网络测速                  30. 修改主机名"
    echo "13. BestTrace回程测试                  31. 重装系统"
    echo "14. 开放所有端口                       32. 部署Hexo博客"
    echo "15. 时间同步                           33. 安装Hexo_butterfly主题"
    echo "16. Caddy反代管理                      34. 安装 AnyTLS"
    echo "17. Nginx管理                          35. SaveAnyBot管理"
    echo "18. BBRv3内核管理"
    echo -e "${YELLOW}==========================================================================${NC}"
    echo "0. 退出脚本"
    echo -e "${YELLOW}-------------------------------------------------------------------------${NC}"
    echo "99. 脚本更新                           98. 卸载工具箱"
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
        traffic_monitor
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      4) 
        install_snell 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      5)  
        install_hysteria2 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      6)  
        install_ss_rust 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      7)  
        install_shadowtls 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      8)  
        install_iptables_forward 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      9)  
        install_gost_forward 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      10)  
        install_3x_ui 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      11)  
        install_media_check 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      12)  
        install_speedtest 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      13)  
        install_besttrace 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      14)
        open_all_ports
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      15)
        sync_time
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
        manage_bbr3
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      19)
        modify_ip_preference
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      20)
        install_magic_tcp
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      21)
        install_shell_beautify
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      22)
        install_dns_unlock
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      23)
        install_substore
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      24)
        install_tg_image_host 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      25)
        optimize_tcp_bbr
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      26)
        restore_tcp_config
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      27)
        install_fail2ban 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      28)
        install_acme 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      29)
        install_gost_v3 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      30)
        change_hostname 
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      31)
        reinstall_system
        # 重装系统后会自动重启，不需要返回主菜单
        ;;
      32)
        deploy_hexo_blog
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      33)
        install_hexo_butterfly
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      34)
        install_anytls
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      35)
        saveanybot_manager
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
if [[ ${AI_SCRIPTS_SOURCE_ONLY:-0} != 1 ]]; then
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
fi

