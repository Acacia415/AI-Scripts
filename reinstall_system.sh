#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= DMIT Cloud-Init 检测 =======================
# 检测并备份 DMIT VPS 的 Cloud-Init customdata
# 防止重装后网络失联问题
detect_and_backup_cloudinit() {
    echo -e "${CYAN}[DMIT 检测] 正在检查 Cloud-Init customdata...${NC}"
    
    local backup_dir="/tmp/dmit_cloudinit_backup"
    local found_cloudinit=false
    
    mkdir -p "$backup_dir"
    
    # 查找 ISO9660 格式的 CD-ROM 设备
    local cd_devices
    cd_devices=$(blkid -t TYPE=iso9660 -o device 2>/dev/null || true)
    
    if [ -z "$cd_devices" ]; then
        echo -e "${YELLOW}[DMIT 检测] 未发现 Cloud-Init CD-ROM（非 DMIT VPS 或使用不同配置方式）${NC}"
        return 0
    fi
    
    # 遍历所有 CD 设备查找 Cloud-Init 配置
    for cd_dev in $cd_devices; do
        echo -e "${CYAN}[DMIT 检测] 检查设备: $cd_dev${NC}"
        
        local mount_point="/mnt/cloudinit_detect_$$"
        mkdir -p "$mount_point"
        
        if mount "$cd_dev" "$mount_point" 2>/dev/null; then
            # 查找 Cloud-Init 配置文件（meta-data, user-data 等）
            if find "$mount_point" -type f \( -name "meta-data*" -o -name "user-data*" -o -name "meta_data*" -o -name "user_data*" \) 2>/dev/null | grep -q .; then
                echo -e "${GREEN}[DMIT 检测] ✓ 发现 DMIT Cloud-Init 配置！${NC}"
                
                # 备份所有配置文件
                cp -r "$mount_point"/* "$backup_dir/" 2>/dev/null || true
                
                echo -e "${GREEN}[DMIT 检测] ✓ Cloud-Init 配置已备份到: $backup_dir${NC}"
                echo -e "${CYAN}[DMIT 检测] 备份文件列表:${NC}"
                ls -lh "$backup_dir" 2>/dev/null | grep -v "^total" | awk '{print "  - " $9}'
                
                found_cloudinit=true
                umount "$mount_point" 2>/dev/null || true
                rmdir "$mount_point" 2>/dev/null || true
                break
            fi
            
            umount "$mount_point" 2>/dev/null || true
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done
    
    if [ "$found_cloudinit" = true ]; then
        echo -e "${GREEN}[DMIT 检测] ✓ 这是 DMIT VPS，Cloud-Init 配置已保护${NC}"
        echo -e "${YELLOW}[DMIT 检测] 重装后系统将自动从 customdata 获取网络配置${NC}"
    else
        echo -e "${YELLOW}[DMIT 检测] 未找到 Cloud-Init 配置文件（可能不是 DMIT VPS）${NC}"
    fi
    
    echo
    return 0
}

# ======================= 系统重装 =======================
reinstall_system() {
    clear
    echo -e "${RED}════════════════════════════════════${NC}"
    echo -e "${RED}         系统重装工具          ${NC}"
    echo -e "${CYAN}脚本来源：https://github.com/bin456789/reinstall${NC}"
    echo -e "${RED}════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}⚠️  警告：重装系统将清空所有数据，请务必备份重要文件！${NC}"
    echo
    
    # 定义系统列表（系统名称|版本|显示名称）
    local systems=(
        "debian|11|Debian 11"
        "debian|12|Debian 12"
        "debian|13|Debian 13"
        "ubuntu|20.04|Ubuntu 20.04 LTS"
        "ubuntu|22.04|Ubuntu 22.04 LTS"
        "ubuntu|24.04|Ubuntu 24.04 LTS"
        "centos|9|CentOS Stream 9"
        "alma|8|AlmaLinux 8"
        "alma|9|AlmaLinux 9"
        "rocky|8|Rocky Linux 8"
        "rocky|9|Rocky Linux 9"
        "fedora|40|Fedora 40"
        "fedora|41|Fedora 41"
        "arch||Arch Linux"
        "alpine||Alpine Linux"
        "opensuse||openSUSE"
        "kali||Kali Linux"
    )
    
    echo -e "${CYAN}请选择要重装的系统：${NC}"
    echo -e "${YELLOW}────────────────────────────────────${NC}"
    
    local index=1
    for system in "${systems[@]}"; do
        local display_name=$(echo "$system" | cut -d'|' -f3)
        printf "  ${GREEN}%-3s${NC} %s\n" "$index." "$display_name"
        ((index++))
    done
    
    echo -e "${YELLOW}────────────────────────────────────${NC}"
    echo -e "  ${GREEN}0.${NC}   返回主菜单"
    echo
    
    read -p "请输入选项 [0-${#systems[@]}]: " choice
    
    # 验证输入
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#systems[@]}" ]; then
        echo -e "${RED}无效的选项！${NC}"
        sleep 2
        return
    fi
    
    # 获取选中的系统信息
    local selected_system="${systems[$((choice-1))]}"
    local os_name=$(echo "$selected_system" | cut -d'|' -f1)
    local os_version=$(echo "$selected_system" | cut -d'|' -f2)
    local display_name=$(echo "$selected_system" | cut -d'|' -f3)
    
    # 构建命令
    local reinstall_cmd="bash reinstall.sh $os_name"
    if [[ -n "$os_version" ]]; then
        reinstall_cmd="$reinstall_cmd $os_version"
    fi
    
    echo
    echo -e "${YELLOW}您选择了：${NC}${GREEN}$display_name${NC}"
    echo -e "${YELLOW}将执行命令：${NC}${CYAN}$reinstall_cmd${NC}"
    echo
    echo -e "${RED}⚠️  最后警告：此操作不可逆，将清空所有数据！${NC}"
    echo -e "${YELLOW}请确认您已经备份了所有重要文件。${NC}"
    echo
    read -p "确认要继续吗？(输入 YES 确认): " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        echo -e "${BLUE}已取消重装操作${NC}"
        sleep 2
        return
    fi
    
    echo
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}步骤 1/3: DMIT VPS 兼容性检测${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo
    
    # DMIT Cloud-Init 检测（防止网络失联）
    detect_and_backup_cloudinit
    
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}步骤 2/3: 下载重装脚本${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo
    if ! curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh; then
        echo -e "${RED}下载脚本失败！请检查网络连接。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    
    echo -e "${GREEN}✓ 脚本下载成功！${NC}"
    echo
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}步骤 3/3: 执行系统重装${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}重装命令: ${NC}${CYAN}$reinstall_cmd${NC}"
    echo
    sleep 2
    
    # 执行重装命令
    echo -e "${YELLOW}正在执行重装脚本...${NC}"
    $reinstall_cmd
    
    # 检查命令执行结果
    if [ $? -eq 0 ]; then
        echo
        echo -e "${GREEN}重装脚本执行完成！${NC}"
        echo -e "${YELLOW}系统将在 5 秒后自动重启以完成重装...${NC}"
        echo -e "${RED}请注意：重启后系统将开始重装过程！${NC}"
        
        # 倒计时
        for i in {5..1}; do
            echo -e "${CYAN}$i 秒后重启...${NC}"
            sleep 1
        done
        
        echo -e "${RED}正在重启系统...${NC}"
        reboot
    else
        echo
        echo -e "${RED}重装脚本执行失败！请检查错误信息。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
}

# 执行函数
reinstall_system
