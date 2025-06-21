#!/bin/bash

# PagerMaid Watchdog Installer (Universal Version)
#
# This script installs a systemd timer to periodically check a user-defined
# service. It restarts the service if it's found to be inactive or
# unresponsive (hung), and can send notifications via Telegram.

# --- Configuration ---
HEALTH_CHECK_SCRIPT_PATH="/usr/local/bin/check_pagermaid_health.sh"
HEALTH_CHECK_SERVICE_NAME="pagermaid-healthcheck.service"
HEALTH_CHECK_TIMER_NAME="pagermaid-healthcheck.timer"
WATCHDOG_CONFIG_PATH="/etc/pagermaid_watchdog.conf"
PAGERMAID_SERVICE_NAME=""
# --- End Configuration ---

# Function to print colored messages
print_msg() {
    COLOR=$1
    MSG=$2
    case "$COLOR" in
        "green") echo -e "\e[32m${MSG}\e[0m" ;;
        "red") echo -e "\e[31m${MSG}\e[0m" ;;
        "yellow") echo -e "\e[33m${MSG}\e[0m" ;;
        *) echo "${MSG}" ;;
    esac
}

# Function to send a test notification via Telegram
send_test_notification() {
    local bot_token=$1
    local chat_id=$2
    local hostname=$(hostname)
    
    # Modified notification text
    local message="✅ *PagerMaid 监控通知* %0A在服务器: \`$hostname\`%0A您已成功为服务 \`${PAGERMAID_SERVICE_NAME}\` 配置 Telegram 通知功能！"
    
    print_msg "yellow" "正在发送测试通知到您的 Telegram Bot..."
    
    API_URL="https://api.telegram.org/bot${bot_token}/sendMessage"
    RESPONSE=$(curl -s -X POST "$API_URL" -d "chat_id=${chat_id}" -d "text=${message}" -d "parse_mode=Markdown")
    
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        print_msg "green" "✔ 测试通知发送成功！请检查您的 Telegram。"
    else
        print_msg "red" "❌ 测试通知发送失败！"
    fi
}

# Prerequisite Check
check_prerequisites() {
    print_msg "green" "正在检查环境和依赖..."

    systemctl status "${PAGERMAID_SERVICE_NAME}" &> /dev/null
    local status_code=$?
    
    if [ $status_code -eq 4 ]; then
        print_msg "red" "错误：在系统中未找到名为 '${PAGERMAID_SERVICE_NAME}' 的服务。"
        print_msg "yellow" "请确认您输入的服务名完全正确（包括 .service 后缀）。"
        exit 1
    fi
    print_msg "green" "✔ 成功找到服务 '${PAGERMAID_SERVICE_NAME}'。"

    if ! command -v jq &>/dev/null; then
        print_msg "yellow" "依赖工具 'jq' 未安装，正在尝试自动安装..."
        if command -v apt-get &>/dev/null; then apt-get update >/dev/null && apt-get install -y jq; elif command -v yum &>/dev/null; then yum install -y jq; else
            print_msg "red" "无法确定包管理器。请手动安装 'jq' 后再运行此脚本。"; exit 1; fi
        if ! command -v jq &>/dev/null; then print_msg "red" "自动安装 'jq' 失败，请手动安装后重试。"; exit 1; fi
    fi
    print_msg "green" "✔ 依赖 'jq' 已满足。"
}

# Create the health check script
create_health_check_script() {
    local check_interval=$1
    local service_name=$2
    print_msg "green" "正在创建健康检查脚本..."
    
    cat << EOF > "${HEALTH_CHECK_SCRIPT_PATH}"
#!/bin/bash
# This script checks the health of the PagerMaid service.

PAGERMAID_SERVICE="$service_name"
WATCHDOG_CONFIG="/etc/pagermaid_watchdog.conf"
CHECK_INTERVAL="$check_interval"

# Function to send Telegram notification
send_telegram_notification() {
    local message_text=\$1
    local url_encoded_text=\$(printf %s "\$message_text" | jq -s -R -r @uri)
    API_URL="https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage"
    curl -s -o /dev/null -X POST "\$API_URL" -d "chat_id=\${CHAT_ID}" -d "text=\${url_encoded_text}" -d "parse_mode=Markdown"
}

# Load bot credentials if config file exists
if [ -f "\$WATCHDOG_CONFIG" ]; then
    source "\$WATCHDOG_CONFIG"
fi

# Step 1: Check if the service is active. If not, restart it.
if ! systemctl is-active --quiet \$PAGERMAID_SERVICE; then
    echo "\$(date): Health check FAILED! Service '\$PAGERMAID_SERVICE' is not active. Restarting..."
    if [[ -n "\$BOT_TOKEN" && -n "\$CHAT_ID" ]]; then
        HOSTNAME=\$(hostname)
        # Modified notification text
        MESSAGE="🚨 *PagerMaid 监控通知* %0A在服务器: \`\$HOSTNAME\`%0A检测到服务 \`\$PAGERMAID_SERVICE\` 处于**停止状态**，已自动触发重启。"
        send_telegram_notification "\$MESSAGE"
    fi
    /usr/bin/systemctl restart \$PAGERMAID_SERVICE
    exit 0
fi

# Step 2: If active, check for recent log activity (hung state).
if [[ "\$CHECK_INTERVAL" == *s ]]; then
    seconds=\$(echo \$CHECK_INTERVAL | sed 's/s//')
    since_time="\$((\$seconds + 5)) seconds ago"
elif [[ "\$CHECK_INTERVAL" == *m ]]; then
    minutes=\$(echo \$CHECK_INTERVAL | sed 's/m//')
    since_time="\$((\$minutes * 60 + 5)) seconds ago"
else
    since_time="2 minutes ago" # Fallback
fi

if [[ \$(journalctl -u \$PAGERMAID_SERVICE --since "\$since_time" --output=cat -n 1 | wc -l) -eq 0 ]]; then
    # NO LOGS FOUND! Perform Step 3.
    PID=\$(systemctl show -p MainPID --value \$PAGERMAID_SERVICE)
    if [[ \$PID -gt 0 ]]; then
        PROC_STATE=\$(ps -o state= -p \$PID)
        if [[ "\$PROC_STATE" == "S" ]]; then
            echo "\$(date): Health check PASSED. No new logs, but process for '\$PAGERMAID_SERVICE' is in a healthy idle state (Sleeping)."
            exit 0
        fi
        
        echo "\$(date): Health check FAILED! No log activity for '\$PAGERMAID_SERVICE' and process state is '\$PROC_STATE'. Restarting..."
        if [[ -n "\$BOT_TOKEN" && -n "\$CHAT_ID" ]]; then
            HOSTNAME=\$(hostname)
            # Modified notification text
            MESSAGE="🚨 *PagerMaid 监控通知* %0A在服务器: \`\$HOSTNAME\`%0A检测到服务 \`\$PAGERMAID_SERVICE\` **无响应（状态: \$PROC_STATE）**，已自动触发重启。"
            send_telegram_notification "\$MESSAGE"
        fi
        /usr/bin/systemctl restart \$PAGERMAID_SERVICE
        
    else
        echo "\$(date): Health check FAILED! Service '\$PAGERMAID_SERVICE' active but PID not found. Restarting..."
        /usr/bin/systemctl restart \$PAGERMAID_SERVICE
    fi
else
    echo "\$(date): Health check PASSED for '\$PAGERMAID_SERVICE'."
fi

exit 0
EOF

    chmod +x "${HEALTH_CHECK_SCRIPT_PATH}"
    print_msg "green" "✔ 健康检查脚本创建成功并已赋予执行权限。"
}

# Create the systemd service unit
create_health_check_service() {
    print_msg "green" "正在创建 systemd 服务单元..."
    cat << EOF > "/etc/systemd/system/${HEALTH_CHECK_SERVICE_NAME}"
[Unit]
Description=Periodic health check for PagerMaid Service
After=network-online.target
[Service]
Type=oneshot
ExecStart=${HEALTH_CHECK_SCRIPT_PATH}
EOF
    print_msg "green" "✔ systemd 服务单元创建成功。"
}

# Create the systemd timer unit
create_health_check_timer() {
    local check_interval=$1
    print_msg "green" "正在创建 systemd 定时器单元 (间隔: ${check_interval})..."
    cat << EOF > "/etc/systemd/system/${HEALTH_CHECK_TIMER_NAME}"
[Unit]
Description=Run PagerMaid health check periodically
[Timer]
OnBootSec=${check_interval}
OnUnitActiveSec=${check_interval}
Unit=${HEALTH_CHECK_SERVICE_NAME}
[Install]
WantedBy=timers.target
EOF
    print_msg "green" "✔ systemd 定时器单元创建成功。"
}

# Install and enable the monitoring
install_watchdog() {
    read -p "请输入您要监控的 PagerMaid 服务名，默认为 [pagermaid.service]: " custom_service_name
    if [ -z "$custom_service_name" ]; then
        PAGERMAID_SERVICE_NAME="pagermaid.service"
    else
        PAGERMAID_SERVICE_NAME="$custom_service_name"
    fi
    print_msg "green" "将要监控的服务: ${PAGERMAID_SERVICE_NAME}"
    echo
    
    check_prerequisites
    
    local bot_token=""
    local chat_id=""
    local check_interval=""
    
    read -p "请输入巡检时间间隔 (例如 30s, 1m, 5m)，默认为 [1m]: " check_interval
    if [ -z "$check_interval" ]; then
        check_interval="1m"
    fi
    
    read -p "是否启用 Telegram Bot 通知功能? (y/N): " enable_bot
    if [[ "$enable_bot" =~ ^[Yy]$ ]]; then
        read -p "请输入您的 Bot Token: " bot_token
        read -p "请输入您的 Chat ID: " chat_id
        echo "BOT_TOKEN=\"$bot_token\"" > "$WATCHDOG_CONFIG_PATH"
        echo "CHAT_ID=\"$chat_id\"" >> "$WATCHDOG_CONFIG_PATH"
        chmod 600 "$WATCHDOG_CONFIG_PATH"
    fi
    
    create_health_check_script "$check_interval" "$PAGERMAID_SERVICE_NAME"
    create_health_check_service
    create_health_check_timer "$check_interval"

    print_msg "green" "正在重载 systemd 并启动监控定时器..."
    systemctl daemon-reload
    systemctl enable "${HEALTH_CHECK_TIMER_NAME}" &>/dev/null
    systemctl start "${HEALTH_CHECK_TIMER_NAME}"

    if [[ -n "$bot_token" && -n "$chat_id" ]]; then
        send_test_notification "$bot_token" "$chat_id"
    fi
    
    print_msg "green" "--------------------------------------------------"
    print_msg "green" "监控脚本安装成功！"
    print_msg "yellow" "服务 '${PAGERMAID_SERVICE_NAME}' 将以 '${check_interval}' 的间隔被监控。"
    print_msg "green" "--------------------------------------------------"
}

# Uninstall the monitoring
uninstall_watchdog() {
    print_msg "yellow" "正在卸载监控脚本..."
    systemctl stop "${HEALTH_CHECK_TIMER_NAME}" &>/dev/null
    systemctl disable "${HEALTH_CHECK_TIMER_NAME}" &>/dev/null
    rm -f "/etc/systemd/system/${HEALTH_CHECK_TIMER_NAME}" "/etc/systemd/system/${HEALTH_CHECK_SERVICE_NAME}" "${HEALTH_CHECK_SCRIPT_PATH}" "${WATCHDOG_CONFIG_PATH}"
    systemctl daemon-reload
    print_msg "green" "✔ 监控脚本已成功卸载。"
}

# --- Main Logic ---
main() {
    clear
    print_msg "green" "============================================="
    print_msg "green" "        PagerMaid 监控脚本 "
    print_msg "green" "============================================="
    echo
    
    if [ -f "${HEALTH_CHECK_SCRIPT_PATH}" ]; then
        print_msg "yellow" "检测到您已经安装了监控脚本。"
        echo "请选择您要执行的操作："
        echo "  1) 重新安装 (覆盖配置)"
        echo "  2) 卸载监控"
        echo "  3) 退出"
        read -p "请输入选项 [1-3]: " choice
        case "$choice" in
            1) uninstall_watchdog; install_watchdog ;;
            2) uninstall_watchdog ;;
            3) print_msg "green" "操作已取消。"; exit 0 ;;
            *) print_msg "red" "无效输入。"; exit 1 ;;
        esac
    else
        install_watchdog
    fi
}

# Run the script
main