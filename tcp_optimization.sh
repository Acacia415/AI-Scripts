#!/bin/bash

# ======================= TCP性能优化模块 =======================
# 从 tool.sh 拆分出来的独立模块

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= TCP性能优化 (BBR+fq) =======================
optimize_tcp_performance() {
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}        TCP 性能优化 (BBR + fq) 安装脚本        ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo # Add an empty line for spacing
    echo -e "此脚本将通过以下步骤优化系统的TCP性能："
    echo -e "1. 自动备份当前的 sysctl.conf 和 sysctl.d 目录。"
    echo -e "2. 检查并注释掉与BBR及网络性能相关的旧配置。"
    echo -e "3. 添加最新的BBR、fq及其他网络优化配置。"
    echo -e "4. 提醒您手动检查 sysctl.d 目录中的潜在冲突。"
    echo

    # 检查内核版本，BBR需要4.9及以上版本
    local kernel_version
    kernel_version=$(uname -r | cut -d- -f1)
    if ! dpkg --compare-versions "$kernel_version" "ge" "4.9"; then
        echo -e "${RED}错误: BBR 需要 Linux 内核版本 4.9 或更高。${NC}"
        echo -e "${RED}您当前的内核版本是: ${kernel_version}${NC}"
        echo -e "${RED}无法继续，请升级您的系统内核。${NC}"
        return 1
    fi
    echo -e "${GREEN}内核版本 ${kernel_version}，满足要求。${NC}"
    echo

    # --- 要添加或更新的参数列表 (已更新) ---
    local params=(
        "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_fastopen_blackhole_timeout_sec"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_collapse_max_bytes"
        "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.tcp_syn_retries"
        "net.ipv4.tcp_moderate_rcvbuf"
        "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
    )

    # --- 1. 执行备份 ---
    echo -e "${CYAN}INFO: 正在备份 /etc/sysctl.conf 和 /etc/sysctl.d/ 目录...${NC}"
    sudo cp /etc/sysctl.conf "/etc/sysctl.conf.bk_$(date +%Y%m%d_%H%M%S)" &>/dev/null
    sudo cp -r /etc/sysctl.d/ "/etc/sysctl.d.bk_$(date +%Y%m%d_%H%M%S)" &>/dev/null
    echo -e "${GREEN}INFO: 备份完成。${NC}"
    echo

    # --- 2. 自动注释掉 /etc/sysctl.conf 中的旧配置 ---
    echo -e "${CYAN}INFO: 正在检查并注释掉 /etc/sysctl.conf 中的旧配置...${NC}"
    for param in "${params[@]}"; do
        # 使用sed命令查找参数并将其注释掉。-E使用扩展正则, \.转义点.
        # s/^\s*.../ 表示从行首开始匹配，可以有空格
        sudo sed -i.bak -E "s/^\s*${param//./\\.}.*/# &/" /etc/sysctl.conf
    done
    sudo rm -f /etc/sysctl.conf.bak
    echo -e "${GREEN}INFO: 旧配置注释完成。${NC}"
    echo

    # --- 3. 追加新的配置到 /etc/sysctl.conf (已更新) ---
    echo -e "${CYAN}INFO: 正在将新的网络优化配置追加到文件末尾...${NC}"
    sudo tee -a /etc/sysctl.conf > /dev/null << EOF

# --- BBR and Network Optimization Settings Added by Toolbox on $(date +%Y-%m-%d) ---
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fastopen_blackhole_timeout_sec=0
net.ipv4.tcp_slow_start_after_idle=0
#net.ipv4.tcp_collapse_max_bytes=6291456
#net.ipv4.tcp_notsent_lowat=16384
#net.ipv4.tcp_notsent_lowat=4294967295
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_rmem=4096 26214400 104857600
net.ipv4.tcp_wmem=4096 26214400 104857600
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.core.rmem_max=104857600
net.core.wmem_max=104857600
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# --- End of BBR Settings ---
EOF
    echo -e "${GREEN}INFO: 新配置追加完成。${NC}"
    echo

    # --- 4. 提醒检查 /etc/sysctl.d/ 目录 ---
    echo -e "${YELLOW}!!! 警告: 请手动检查 /etc/sysctl.d/ 目录中的配置文件。${NC}"
    echo -e "以下是该目录中的文件列表:"
    ls -l /etc/sysctl.d/
    echo -e "${YELLOW}请确认其中没有与BBR或网络缓冲区相关的冲突配置（例如 99-bbr.conf 等）。${NC}"
    echo -e "${YELLOW}如果有，请手动检查、备份并决定是否删除它们。${NC}"
    read -n 1 -s -r -p "检查完毕后，按任意键继续应用配置..."
    echo
    echo

    # --- 5. 应用配置并验证 ---
    echo -e "${CYAN}INFO: 正在应用新的 sysctl 配置...${NC}"
    if sudo sysctl -p; then
        echo -e "${GREEN}INFO: 配置已成功应用。${NC}"
    else
        echo -e "${RED}ERROR: 应用 sysctl 配置时出错。请检查 /etc/sysctl.conf 的语法。${NC}"
        return 1
    fi
    echo
    echo -e "${CYAN}INFO: 正在验证BBR是否成功启用...${NC}"

    local bbr_status
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local fq_status
    fq_status=$(sysctl net.core.default_qdisc | awk '{print $3}')

    echo -e "当前TCP拥塞控制算法: ${GREEN}${bbr_status}${NC}"
    echo -e "当前默认队列调度算法: ${GREEN}${fq_status}${NC}"
    echo

    if [[ "$bbr_status" == "bbr" && "$fq_status" == "fq" ]]; then
        echo -e "${GREEN}SUCCESS: TCP 性能优化（BBR + fq）已成功启用！${NC}"
    else
        echo -e "${RED}WARNING: 验证失败。BBR 或 fq 未能成功启用。${NC}"
        echo -e "${RED}请检查系统日志和以上步骤的输出。${NC}"
    fi
}

# ======================= 恢复TCP原始配置 =======================
uninstall_tcp_optimization() {
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}         恢复原始 TCP 配置 (卸载BBR优化)         ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo
    echo -e "此脚本将帮助您从之前创建的备份中恢复网络配置。"
    echo -e "它会查找由优化脚本创建的备份文件，并用它们覆盖当前配置。"
    echo

    # 查找所有 sysctl.conf 的备份文件
    # 使用 find 命令以处理没有备份文件的情况
    local backups
    mapfile -t backups < <(find /etc -maxdepth 1 -type f -name "sysctl.conf.bk_*" | sort -r)

    # 检查是否找到了备份
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}错误: 未找到任何由优化脚本创建的备份文件 (/etc/sysctl.conf.bk_*)。${NC}"
        echo -e "${RED}无法自动恢复。${NC}"
        return 1
    fi

    echo -e "${GREEN}找到了以下备份，请选择要恢复的版本 (输入数字):${NC}"
    
    # 使用 select 命令让用户选择
    local PS3="请输入选项: "
    select backup_file in "${backups[@]}"; do
        if [ -n "$backup_file" ]; then
            break
        else
            echo -e "${RED}无效的选择，请输入列表中的数字。${NC}"
        fi
    done

    # 从选择的文件名中提取时间戳
    local timestamp
    timestamp=$(echo "$backup_file" | sed 's/.*bk_//')
    local backup_dir="/etc/sysctl.d.bk_${timestamp}"

    echo
    echo -e "${YELLOW}您选择了恢复到版本: ${timestamp}${NC}"
    echo -e "即将执行以下操作:"
    echo -e "1. 使用 ${CYAN}${backup_file}${NC} 覆盖当前 ${CYAN}/etc/sysctl.conf${NC}"
    if [ -d "$backup_dir" ]; then
        echo -e "2. 使用 ${CYAN}${backup_dir}${NC} 覆盖当前 ${CYAN}/etc/sysctl.d/${NC} 目录"
    else
        echo -e "2. 未找到对应的 sysctl.d 备份目录，将仅恢复 sysctl.conf"
    fi
    echo
    
    read -p "确定要继续吗? 这将覆盖您当前的网络配置！ (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${RED}操作已取消。${NC}"
        return
    fi

    echo
    echo -e "${CYAN}INFO: 正在恢复 /etc/sysctl.conf...${NC}"
    if sudo cp "$backup_file" /etc/sysctl.conf; then
        echo -e "${GREEN}INFO: /etc/sysctl.conf 恢复成功。${NC}"
    else
        echo -e "${RED}ERROR: 恢复 /etc/sysctl.conf 失败！${NC}"
        return 1
    fi

    if [ -d "$backup_dir" ]; then
        echo -e "${CYAN}INFO: 正在恢复 /etc/sysctl.d/ 目录...${NC}"
        # 先删除现有目录再复制备份，确保干净恢复
        if sudo rm -rf /etc/sysctl.d && sudo cp -r "$backup_dir" /etc/sysctl.d; then
            echo -e "${GREEN}INFO: /etc/sysctl.d/ 目录恢复成功。${NC}"
        else
            echo -e "${RED}ERROR: 恢复 /etc/sysctl.d/ 目录失败！${NC}"
            return 1
        fi
    fi

    echo
    echo -e "${CYAN}INFO: 正在应用已恢复的配置...${NC}"
    if sudo sysctl -p; then
        echo -e "${GREEN}INFO: 配置已成功应用。${NC}"
    else
        echo -e "${RED}ERROR: 应用恢复的 sysctl 配置时出错。${NC}"
        return 1
    fi

    echo
    echo -e "${GREEN}SUCCESS: 网络配置已成功恢复到 ${timestamp} 的状态！${NC}"
}

# 如果直接执行此脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "用法："
    echo "  优化TCP: source $0 && optimize_tcp_performance"
    echo "  恢复配置: source $0 && uninstall_tcp_optimization"
fi
