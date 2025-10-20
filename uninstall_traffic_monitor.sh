#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= 流量监控卸载 =======================
uninstall_service() {
    # 权限检查
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用sudo运行此脚本${NC}"
        return 1
    fi

    clear
    echo -e "${RED}⚠️ ⚠️ ⚠️  危险操作警告 ⚠️ ⚠️ ⚠️ ${NC}"
    echo -e "${YELLOW}此操作将执行以下操作："
    echo -e "1. 永久删除所有防火墙规则"
    echo -e "2. 清除全部流量监控数据"
    echo -e "3. 移除所有相关系统服务${NC}\n"
    read -p "确定要彻底卸载所有组件吗？[y/N] " confirm
    [[ ! "$confirm" =~ [yY] ]] && echo "操作已取消" && return

    echo -e "\n${YELLOW}[1/6] 停止服务...${NC}"
    systemctl disable --now ip_blacklist.service 2>/dev/null || true

    echo -e "\n${YELLOW}[2/6] 删除文件...${NC}"
    rm -vf /etc/systemd/system/ip_blacklist.service /root/ip_blacklist.sh

    echo -e "\n${YELLOW}[3/6] 清理网络规则...${NC}"
    # 安全清理策略：仅删除本脚本创建的规则
    {
        echo -e "${YELLOW}[步骤3.1] 从INPUT链移除TRAFFIC_BLOCK跳转${NC}"
        # 只删除指向TRAFFIC_BLOCK的规则
        iptables -D INPUT -j TRAFFIC_BLOCK 2>/dev/null || true

        echo -e "${YELLOW}[步骤3.2] 清空并删除TRAFFIC_BLOCK自定义链${NC}"
        # 清空链中的所有规则
        iptables -F TRAFFIC_BLOCK 2>/dev/null || true
        # 删除自定义链
        iptables -X TRAFFIC_BLOCK 2>/dev/null || true

        echo -e "${YELLOW}[步骤3.3] 验证规则清理${NC}"
        # 检查是否还有残留的相关规则
        remaining=$(iptables -S | grep -c -E 'TRAFFIC_BLOCK|whitelist|banlist' || true)
        if [ "$remaining" -gt 0 ]; then
            echo -e "${YELLOW}发现 $remaining 条相关规则，正在清理...${NC}"
            # 逐条删除包含关键字的规则
            iptables -S | grep -E 'TRAFFIC_BLOCK|whitelist|banlist' | while read -r line; do
                # 将 -A 改为 -D 来删除规则
                delete_cmd=$(echo "$line" | sed 's/^-A/-D/')
                eval "iptables $delete_cmd" 2>/dev/null || true
            done
        else
            echo -e "${GREEN}✓ 未发现残留规则${NC}"
        fi

        echo -e "${YELLOW}[步骤3.4] 更新持久化规则${NC}"
        # 仅从持久化文件中移除相关规则，保留其他规则
        if [ -f /etc/iptables/rules.v4 ]; then
            echo -e "${CYAN}备份现有规则到 /etc/iptables/rules.v4.bak${NC}"
            cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.bak
            iptables-save | grep -vE 'TRAFFIC_BLOCK|banlist|whitelist' > /etc/iptables/rules.v4.tmp
            mv /etc/iptables/rules.v4.tmp /etc/iptables/rules.v4
            echo -e "${GREEN}✓ 已保留其他防火墙规则${NC}"
        fi
    } || true

    # 内核级清理
    {
        echo -e "${YELLOW}[步骤3.5] 清理ipset集合${NC}"
        ipset list whitelist &>/dev/null && {
            ipset flush whitelist
            ipset destroy whitelist
        }
        ipset list banlist &>/dev/null && {
            ipset flush banlist
            ipset destroy banlist
        }
        echo -e "${YELLOW}[步骤3.6] 卸载内核模块（安全模式）${NC}"
        rmmod ip_set_hash_net 2>/dev/null || true
        rmmod xt_set 2>/dev/null || true
        rmmod ip_set 2>/dev/null || true
    } || true

    echo -e "\n${YELLOW}[4/6] 删除配置...${NC}"
    # 只删除ipset配置，保留iptables规则文件（已在步骤3.4中更新）
    if [ -f /etc/ipset.conf ]; then
        echo -e "${CYAN}备份ipset配置到 /etc/ipset.conf.bak${NC}"
        cp /etc/ipset.conf /etc/ipset.conf.bak
        # 从ipset配置中移除whitelist和banlist
        grep -vE 'whitelist|banlist' /etc/ipset.conf > /etc/ipset.conf.tmp 2>/dev/null || true
        if [ -s /etc/ipset.conf.tmp ]; then
            mv /etc/ipset.conf.tmp /etc/ipset.conf
            echo -e "${GREEN}✓ 已保留其他ipset配置${NC}"
        else
            rm -f /etc/ipset.conf /etc/ipset.conf.tmp
            echo -e "${GREEN}✓ ipset配置文件已清空${NC}"
        fi
    fi
    # 删除日志轮替配置
    rm -vf /etc/logrotate.d/iptables_ban 2>/dev/null || true

    echo -e "\n${YELLOW}[5/6] 重置系统...${NC}"
    systemctl daemon-reload
    systemctl reset-failed
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    echo -e "\n${YELLOW}[6/6] 验证卸载...${NC}"
    local check_fail=0
    echo -n "服务状态: " && { systemctl status ip_blacklist.service &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPTables链: " && { iptables -L TRAFFIC_BLOCK &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet黑名单: " && { ipset list banlist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "IPSet白名单: " && { ipset list whitelist &>/dev/null && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已移除${NC}"; }
    echo -n "日志轮替配置: " && { [ -f /etc/logrotate.d/iptables_ban ] && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }
    echo -n "残留规则检查: " && { iptables -S | grep -qE 'TRAFFIC_BLOCK|banlist|whitelist' && check_fail=1 && echo -e "${RED}存在${NC}" || echo -e "${GREEN}已清除${NC}"; }

    [ $check_fail -eq 0 ] && echo -e "\n${GREEN}✅ 卸载完成，无残留${NC}" || echo -e "\n${RED}⚠️  检测到残留组件，请重启系统${NC}"
}

# 执行函数
uninstall_service
