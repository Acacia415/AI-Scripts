#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

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

# 执行函数
uninstall_tcp_optimization
