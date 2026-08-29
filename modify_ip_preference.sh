#!/bin/bash

# AI-Scripts IP 协议优先级与 IPv6 管理
# 只维护带所有权标记的配置，不覆盖用户或云厂商已有设置。

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

CONF_FILE="${IP_PREFERENCE_CONF_FILE:-/etc/gai.conf}"
STATE_DIR="${IP_PREFERENCE_STATE_DIR:-/var/lib/ai-scripts/ip-preference}"
GAI_ORIGINAL_BACKUP="$STATE_DIR/gai.conf.original"
GAI_ORIGINAL_ABSENT="$STATE_DIR/gai.conf.original.absent"
DISABLE_STATE_FILE="$STATE_DIR/ipv6-disable.state"
AUTOCONF_STATE_FILE="$STATE_DIR/ipv6-autoconf.state"
SYSCTL_DISABLE_FILE="${IP_PREFERENCE_SYSCTL_DISABLE_FILE:-/etc/sysctl.d/99-ai-scripts-disable-ipv6.conf}"
SYSCTL_AUTOCONF_FILE="${IP_PREFERENCE_SYSCTL_AUTOCONF_FILE:-/etc/sysctl.d/98-ai-scripts-ipv6-autoconf.conf}"
LEGACY_DISABLE_FILE="${IP_PREFERENCE_LEGACY_DISABLE_FILE:-/etc/sysctl.d/99-disable-ipv6.conf}"
LEGACY_AUTOCONF_FILE="${IP_PREFERENCE_LEGACY_AUTOCONF_FILE:-/etc/sysctl.d/98-ipv6-autoconfig.conf}"
GAI_BEGIN='# BEGIN AI-Scripts IP preference'
GAI_END='# END AI-Scripts IP preference'
OWNED_SYSCTL_MARKER='# Managed by AI-Scripts modify_ip_preference.sh'

ensure_state_dir() {
    mkdir -p -- "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" || return 1
}

ensure_gai_original_backup() {
    ensure_state_dir || return 1
    if [[ -e "$GAI_ORIGINAL_BACKUP" || -e "$GAI_ORIGINAL_ABSENT" ]]; then
        return 0
    fi
    if [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]]; then
        cp -a -- "$CONF_FILE" "$GAI_ORIGINAL_BACKUP" || return 1
    else
        : > "$GAI_ORIGINAL_ABSENT" || return 1
        chmod 600 "$GAI_ORIGINAL_ABSENT" || return 1
    fi
}

strip_gai_managed_block() {
    local input_file="$1" output_file="$2"
    if [[ ! -f "$input_file" ]]; then
        : > "$output_file"
        return
    fi
    awk -v begin="$GAI_BEGIN" -v end="$GAI_END" '
        $0 == begin {
            if (managed) exit 42
            managed=1
            next
        }
        $0 == end {
            if (!managed) exit 42
            managed=0
            next
        }
        !managed { print }
        END { if (managed) exit 42 }
    ' "$input_file" > "$output_file"
}

apply_gai_metadata() {
    local temporary="$1"
    if [[ -e "$CONF_FILE" ]]; then
        chmod --reference="$CONF_FILE" "$temporary" 2>/dev/null || chmod 644 "$temporary" || return 1
        chown --reference="$CONF_FILE" "$temporary" 2>/dev/null || true
    else
        chmod 644 "$temporary" || return 1
    fi
}

refresh_name_service_cache() {
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches >/dev/null 2>&1 || true
    elif command -v systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches >/dev/null 2>&1 || true
    fi
    if command -v nscd >/dev/null 2>&1; then
        nscd -i hosts >/dev/null 2>&1 || true
    fi
}

write_gai_preference() {
    local mode="$1" precedence="$2" temporary stripped
    ensure_gai_original_backup || {
        echo -e "${RED}错误：无法建立首次 gai.conf 备份。${NC}"
        return 1
    }
    mkdir -p -- "$(dirname "$CONF_FILE")" || return 1
    temporary=$(mktemp "$(dirname "$CONF_FILE")/.gai.conf.ai-scripts.XXXXXXXX") || return 1
    stripped=$(mktemp "$STATE_DIR/gai-stripped.XXXXXXXX") || {
        rm -f -- "$temporary"
        return 1
    }
    if ! strip_gai_managed_block "$CONF_FILE" "$stripped"; then
        echo -e "${RED}错误：检测到不完整或重复的 AI-Scripts 受管块，未修改 $CONF_FILE。${NC}"
        rm -f -- "$temporary" "$stripped"
        return 1
    fi

    {
        printf '%s\n' "$GAI_BEGIN"
        printf '# Mode: %s\n' "$mode"
        printf 'precedence ::ffff:0:0/96 %s\n' "$precedence"
        printf '%s\n' "$GAI_END"
        [[ ! -s "$stripped" ]] || {
            printf '\n'
            cat "$stripped"
        }
    } > "$temporary" || {
        rm -f -- "$temporary" "$stripped"
        return 1
    }
    rm -f -- "$stripped"
    apply_gai_metadata "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$CONF_FILE" || {
        rm -f -- "$temporary"
        return 1
    }
    refresh_name_service_cache
    echo -e "${GREEN}成功：已写入 $mode 受管块；其他 gai.conf 内容保持不变。${NC}"
    echo -e "${BLUE}首次原始备份：$GAI_ORIGINAL_BACKUP${NC}"
}

apply_ipv4_preference() {
    write_gai_preference "IPv4 preferred" 100
}

apply_ipv6_preference() {
    write_gai_preference "IPv6 preferred" 10
}

restore_default_preference() {
    local temporary
    if [[ ! -f "$CONF_FILE" ]] || ! grep -Fxq "$GAI_BEGIN" "$CONF_FILE"; then
        echo -e "${YELLOW}未找到本脚本的 gai.conf 受管块，无需修改。${NC}"
        return 0
    fi
    temporary=$(mktemp "$(dirname "$CONF_FILE")/.gai.conf.ai-scripts.XXXXXXXX") || return 1
    if ! strip_gai_managed_block "$CONF_FILE" "$temporary"; then
        echo -e "${RED}错误：受管块结构异常，未修改 $CONF_FILE。${NC}"
        rm -f -- "$temporary"
        return 1
    fi
    apply_gai_metadata "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }

    if [[ -f "$GAI_ORIGINAL_ABSENT" ]] && ! grep -q '[^[:space:]]' "$temporary"; then
        rm -f -- "$temporary" "$CONF_FILE" || return 1
    else
        mv -f -- "$temporary" "$CONF_FILE" || {
            rm -f -- "$temporary"
            return 1
        }
    fi
    refresh_name_service_cache
    echo -e "${GREEN}成功：只移除了 AI-Scripts 受管块，其他配置未改变。${NC}"
}

read_sysctl_value() {
    local key="$1" value
    value=$(sysctl -n "$key" 2>/dev/null) || return 1
    [[ "$value" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

save_sysctl_state_once() {
    local state_file="$1" key value temporary
    shift
    ensure_state_dir || return 1
    if [[ -e "$state_file" ]]; then
        for key in "$@"; do
            awk -F= -v expected="$key" '
                $1 == expected && $2 ~ /^-?[0-9]+$/ { matches++ }
                END { exit(matches == 1 ? 0 : 1) }
            ' "$state_file" || return 1
        done
        return 0
    fi
    temporary=$(mktemp "$STATE_DIR/sysctl-state.XXXXXXXX") || return 1
    for key in "$@"; do
        [[ "$key" =~ ^net[.]ipv6[.]conf[.][A-Za-z0-9_.:@-]+[.][A-Za-z0-9_]+$ ]] || {
            rm -f -- "$temporary"
            return 1
        }
        value=$(read_sysctl_value "$key") || {
            rm -f -- "$temporary"
            return 1
        }
        printf '%s=%s\n' "$key" "$value" >> "$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    done
    chmod 600 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$state_file"
}

restore_sysctl_state() {
    local state_file="$1" key value result=0
    [[ -f "$state_file" ]] || return 1
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^net[.]ipv6[.]conf[.][A-Za-z0-9_.:@-]+[.][A-Za-z0-9_]+$ ]] || return 1
        [[ "$value" =~ ^-?[0-9]+$ ]] || return 1
        sysctl -w "${key}=${value}" >/dev/null 2>&1 || result=1
    done < "$state_file"
    return "$result"
}

is_owned_sysctl_file() {
    local file="$1"
    [[ -f "$file" ]] && grep -Fxq "$OWNED_SYSCTL_MARKER" "$file"
}

prepare_owned_sysctl_file() {
    local destination="$1" temporary
    if [[ -e "$destination" ]] && ! is_owned_sysctl_file "$destination"; then
        echo -e "${RED}错误：$destination 已存在但不属于本脚本，拒绝覆盖。${NC}" >&2
        return 1
    fi
    mkdir -p -- "$(dirname "$destination")" || return 1
    temporary=$(mktemp "$(dirname "$destination")/.ai-scripts-sysctl.XXXXXXXX") || return 1
    printf '%s\n' "$OWNED_SYSCTL_MARKER" > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    printf '%s\n' "$temporary"
}

commit_sysctl_file() {
    local temporary="$1" destination="$2" state_file="$3"
    chmod 644 "$temporary" || return 1
    if ! sysctl -p "$temporary" >/dev/null 2>&1; then
        restore_sysctl_state "$state_file" >/dev/null 2>&1 || true
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -f -- "$temporary" "$destination"; then
        restore_sysctl_state "$state_file" >/dev/null 2>&1 || true
        rm -f -- "$temporary"
        return 1
    fi
}

restore_owned_sysctl_config() {
    local config_file="$1" state_file="$2" label="$3" saved_config=""
    if [[ -e "$config_file" ]] && ! is_owned_sysctl_file "$config_file"; then
        echo -e "${RED}错误：$config_file 不属于本脚本，拒绝删除。${NC}"
        return 1
    fi
    if [[ ! -e "$config_file" && ! -e "$state_file" ]]; then
        echo -e "${YELLOW}未找到本脚本管理的 $label 配置。${NC}"
        return 0
    fi
    if [[ ! -f "$state_file" ]]; then
        echo -e "${RED}错误：缺少 $label 原始状态记录，未执行不可逆恢复。${NC}"
        return 1
    fi
    if [[ -f "$config_file" ]]; then
        saved_config=$(mktemp "$STATE_DIR/sysctl-config.XXXXXXXX") || return 1
        cp -a -- "$config_file" "$saved_config" || {
            rm -f -- "$saved_config"
            return 1
        }
        rm -f -- "$config_file" || {
            rm -f -- "$saved_config"
            return 1
        }
    fi
    if ! restore_sysctl_state "$state_file"; then
        [[ -z "$saved_config" ]] || mv -f -- "$saved_config" "$config_file"
        [[ ! -f "$config_file" ]] || sysctl -p "$config_file" >/dev/null 2>&1 || true
        echo -e "${RED}错误：恢复 $label 运行时状态失败，持久化配置已回滚。${NC}"
        return 1
    fi
    rm -f -- "$state_file"
    [[ -z "$saved_config" ]] || rm -f -- "$saved_config"
    echo -e "${GREEN}成功：已恢复 $label 修改前的内核参数。${NC}"
}

disable_ipv6() {
    local temporary
    if [[ -e "$SYSCTL_DISABLE_FILE" ]] && ! is_owned_sysctl_file "$SYSCTL_DISABLE_FILE"; then
        echo -e "${RED}错误：$SYSCTL_DISABLE_FILE 已存在但不属于本脚本，拒绝覆盖。${NC}"
        return 1
    fi
    save_sysctl_state_once "$DISABLE_STATE_FILE" \
        net.ipv6.conf.all.disable_ipv6 \
        net.ipv6.conf.default.disable_ipv6 \
        net.ipv6.conf.lo.disable_ipv6 || {
        echo -e "${RED}错误：无法保存 IPv6 修改前状态，操作已停止。${NC}"
        return 1
    }
    temporary=$(prepare_owned_sysctl_file "$SYSCTL_DISABLE_FILE") || return 1
    {
        printf 'net.ipv6.conf.all.disable_ipv6 = 1\n'
        printf 'net.ipv6.conf.default.disable_ipv6 = 1\n'
        printf 'net.ipv6.conf.lo.disable_ipv6 = 1\n'
    } >> "$temporary"
    if ! commit_sysctl_file "$temporary" "$SYSCTL_DISABLE_FILE" "$DISABLE_STATE_FILE"; then
        echo -e "${RED}错误：IPv6 禁用配置应用失败，已恢复原内核参数。${NC}"
        return 1
    fi
    echo -e "${GREEN}成功：IPv6 已通过本脚本专属配置禁用。${NC}"
}

restore_ipv6_changes() {
    local result=0
    restore_owned_sysctl_config "$SYSCTL_DISABLE_FILE" "$DISABLE_STATE_FILE" "IPv6 禁用" || result=1
    restore_owned_sysctl_config "$SYSCTL_AUTOCONF_FILE" "$AUTOCONF_STATE_FILE" "IPv6 自动配置" || result=1
    if [[ -e "$LEGACY_DISABLE_FILE" ]] && ! is_owned_sysctl_file "$LEGACY_DISABLE_FILE"; then
        echo -e "${YELLOW}警告：检测到未带所有权标记的旧配置 $LEGACY_DISABLE_FILE，已保留，请人工确认。${NC}"
    fi
    if [[ -e "$LEGACY_AUTOCONF_FILE" ]] && ! is_owned_sysctl_file "$LEGACY_AUTOCONF_FILE"; then
        echo -e "${YELLOW}警告：检测到未带所有权标记的旧配置 $LEGACY_AUTOCONF_FILE，已保留，请人工确认。${NC}"
    fi
    return "$result"
}

get_main_interface() {
    local interface
    interface=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ "$interface" =~ ^[A-Za-z0-9_.:@-]+$ ]] || return 1
    printf '%s\n' "$interface"
}

auto_config_ipv6() {
    local interface forwarding accept_ra temporary
    [[ "$(read_sysctl_value net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)" == 0 ]] || {
        echo -e "${RED}错误：IPv6 当前已禁用，请先恢复 IPv6。${NC}"
        return 1
    }
    interface=$(get_main_interface) || {
        echo -e "${RED}错误：无法安全识别主网络接口。${NC}"
        return 1
    }
    if [[ -e "$SYSCTL_AUTOCONF_FILE" ]] && ! is_owned_sysctl_file "$SYSCTL_AUTOCONF_FILE"; then
        echo -e "${RED}错误：$SYSCTL_AUTOCONF_FILE 已存在但不属于本脚本，拒绝覆盖。${NC}"
        return 1
    fi
    if [[ -f "$AUTOCONF_STATE_FILE" ]] && ! grep -Fq "net.ipv6.conf.${interface}.autoconf=" "$AUTOCONF_STATE_FILE"; then
        echo -e "${RED}错误：已有其他接口的自动配置状态，请先使用 [恢复 IPv6/撤销修改]。${NC}"
        return 1
    fi
    forwarding=$(read_sysctl_value net.ipv6.conf.all.forwarding) || return 1
    if [[ "$forwarding" == 1 ]]; then
        accept_ra=2
    else
        accept_ra=1
    fi
    save_sysctl_state_once "$AUTOCONF_STATE_FILE" \
        "net.ipv6.conf.${interface}.autoconf" \
        "net.ipv6.conf.${interface}.accept_ra" \
        net.ipv6.conf.all.forwarding || {
        echo -e "${RED}错误：无法保存 IPv6 自动配置前状态。${NC}"
        return 1
    }
    temporary=$(prepare_owned_sysctl_file "$SYSCTL_AUTOCONF_FILE") || return 1
    {
        printf '# Interface: %s\n' "$interface"
        printf 'net.ipv6.conf.%s.autoconf = 1\n' "$interface"
        printf 'net.ipv6.conf.%s.accept_ra = %s\n' "$interface" "$accept_ra"
    } >> "$temporary"
    if ! commit_sysctl_file "$temporary" "$SYSCTL_AUTOCONF_FILE" "$AUTOCONF_STATE_FILE"; then
        echo -e "${RED}错误：IPv6 自动配置应用失败，已恢复原内核参数。${NC}"
        return 1
    fi
    echo -e "${GREEN}成功：已为 $interface 启用 SLAAC；forwarding=$forwarding 保持不变。${NC}"
    echo -e "${YELLOW}未重启 NetworkManager、networking 或网卡；地址将在收到路由通告后生成。${NC}"
    ip -6 addr show dev "$interface" scope global 2>/dev/null | awk '/inet6/ {print "  ▸ " $2}' || true
}

detect_ip_family() {
    local address="$1"
    if [[ "$address" == *:* ]]; then
        printf 'IPv6\n'
    elif [[ "$address" =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
        printf 'IPv4\n'
    else
        printf '未知\n'
    fi
}

test_connectivity() {
    local test_host="www.cloudflare.com" first_address="" remote_ip=""
    echo -e "\n${YELLOW}地址选择检查：${NC}"
    if command -v getent >/dev/null 2>&1; then
        first_address=$(getent ahosts "$test_host" 2>/dev/null | awk '!seen[$1]++ {print $1; exit}')
        if [[ -n "$first_address" ]]; then
            echo -e "  ▸ getent 首选地址：$first_address ($(detect_ip_family "$first_address"))"
        else
            echo -e "  ▸ ${YELLOW}getent 未返回地址${NC}"
        fi
    else
        echo -e "  ▸ ${YELLOW}getent 不可用${NC}"
    fi
    if command -v curl >/dev/null 2>&1; then
        remote_ip=$(curl --silent --show-error --location --noproxy '*' --connect-timeout 5 --max-time 10 \
            -o /dev/null -w '%{remote_ip}' "https://${test_host}/cdn-cgi/trace" 2>/dev/null || true)
        if [[ -n "$remote_ip" ]]; then
            echo -e "  ▸ 实际 HTTPS 连接：$remote_ip ($(detect_ip_family "$remote_ip"))"
        else
            echo -e "  ▸ ${YELLOW}实际 HTTPS 连接失败，无法验证使用的地址族${NC}"
        fi
    else
        echo -e "  ▸ ${YELLOW}curl 不可用，无法执行实际连接验证${NC}"
    fi
}

show_current_status() {
    local ipv6_disabled
    echo -e "\n${YELLOW}当前优先级配置：${NC}"
    if [[ -f "$CONF_FILE" ]] && grep -A2 -Fx "$GAI_BEGIN" "$CONF_FILE" | grep -q 'IPv4 preferred'; then
        echo -e "  ▸ ${GREEN}IPv4 优先（AI-Scripts 受管块）${NC}"
    elif [[ -f "$CONF_FILE" ]] && grep -A2 -Fx "$GAI_BEGIN" "$CONF_FILE" | grep -q 'IPv6 preferred'; then
        echo -e "  ▸ ${GREEN}IPv6 优先（AI-Scripts 受管块）${NC}"
    else
        echo -e "  ▸ ${YELLOW}系统默认或用户自定义配置${NC}"
    fi
    ipv6_disabled=$(read_sysctl_value net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)
    case "$ipv6_disabled" in
        1) echo -e "  ▸ ${RED}IPv6 已禁用${NC}" ;;
        0) echo -e "  ▸ ${GREEN}IPv6 已启用${NC}" ;;
        *) echo -e "  ▸ ${YELLOW}IPv6 状态未知${NC}" ;;
    esac
    test_connectivity
}

show_detailed_config() {
    echo -e "\n${YELLOW}=== 详细配置信息 ===${NC}"
    if [[ -f "$CONF_FILE" ]]; then
        echo -e "\n${GREEN}$CONF_FILE：${NC}"
        echo "----------------------------------------"
        cat "$CONF_FILE"
        echo "----------------------------------------"
    else
        echo -e "${YELLOW}配置文件不存在，使用系统默认设置。${NC}"
    fi
    echo -e "\n${GREEN}本脚本状态目录：${NC}$STATE_DIR"
    [[ ! -e "$SYSCTL_DISABLE_FILE" ]] || echo "  ▸ $SYSCTL_DISABLE_FILE"
    [[ ! -e "$SYSCTL_AUTOCONF_FILE" ]] || echo "  ▸ $SYSCTL_AUTOCONF_FILE"
    test_connectivity
}

pause_ip_preference_menu() {
    echo -e "\n按回车键继续..."
    read -r
}

modify_ip_preference() {
    local choice
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}错误：请使用 sudo 或 root 运行此脚本。${NC}"
        return 1
    fi
    while true; do
        clear
        echo -e "${GREEN}=== IP 协议优先级设置 ===${NC}"
        echo -e "\n${CYAN}[优先级配置]${NC}"
        echo "1. 设置 IPv4 优先（推荐）"
        echo "2. 设置 IPv6 优先"
        echo "3. 恢复系统默认（移除本脚本受管块）"
        echo -e "\n${CYAN}[IPv6 管理]${NC}"
        echo "4. 禁用 IPv6"
        echo "5. 恢复 IPv6 / 撤销本脚本 IPv6 修改"
        echo "6. 自动配置 IPv6（保留路由转发状态）"
        echo -e "\n${CYAN}[其他]${NC}"
        echo "7. 查看详细配置"
        echo "0. 返回主菜单"
        show_current_status
        echo
        read -r -p "请输入选项 [0-7]: " choice
        case "$choice" in
            1) apply_ipv4_preference && echo -e "${GREEN}✅ 已设置为 IPv4 优先模式。${NC}"; pause_ip_preference_menu ;;
            2) apply_ipv6_preference && echo -e "${GREEN}✅ 已设置为 IPv6 优先模式。${NC}"; pause_ip_preference_menu ;;
            3) restore_default_preference; pause_ip_preference_menu ;;
            4) disable_ipv6; pause_ip_preference_menu ;;
            5) restore_ipv6_changes; pause_ip_preference_menu ;;
            6) auto_config_ipv6; pause_ip_preference_menu ;;
            7) show_detailed_config; pause_ip_preference_menu ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 1 ;;
        esac
    done
}

if [[ "${IP_PREFERENCE_SOURCE_ONLY:-0}" != 1 ]]; then
    modify_ip_preference
fi
