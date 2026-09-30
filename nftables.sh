#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="1.1.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

STATE_DIR="/etc/ai-scripts/nftables-forward"
RULES_FILE="${STATE_DIR}/rules.tsv"
SETTINGS_FILE="${STATE_DIR}/settings.conf"
MANAGED_CONFIG="${STATE_DIR}/ai-port-forward.nft"
SYSCTL_FILE="/etc/sysctl.d/99-ai-scripts-nft-forward.conf"
UNIT_NAME="ai-nftables-forward.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
BACKUP_ROOT="/var/backups/ai-scripts/nftables-forward"
TABLE_FAMILY="ip"
TABLE_NAME="ai_port_forward"

NFT_BIN=""
LAST_BACKUP_DIR=""
SELECTED_PROTOCOL=""
FORWARD_MODE="generic"
PO0_SNAT_IP=""
PO0_TCP_MSS=""
PO0_BLOCKED_PORTS=(80 443 8080 8443 8000 1080)

info() { echo -e "${GREEN}[信息]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*" >&2; }

pause_menu() {
    read -r -n 1 -s -p "按任意键返回菜单..." _ || true
    echo
}

clear_screen() {
    clear 2>/dev/null || true
}

require_supported_system() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "请使用 root 权限运行此脚本。"
        exit 1
    fi
    if [[ ! -f /etc/debian_version ]]; then
        error "当前脚本仅支持 Debian/Ubuntu。"
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        error "未检测到 systemd，无法配置规则持久化。"
        exit 1
    fi
}

ensure_state_files() {
    install -d -m 700 "${STATE_DIR}" || return 1
    install -d -m 700 "${BACKUP_ROOT}" || return 1
    if [[ ! -e ${RULES_FILE} ]]; then
        install -m 600 /dev/null "${RULES_FILE}" || return 1
    else
        chmod 600 "${RULES_FILE}" || return 1
    fi
    if [[ ! -e ${SETTINGS_FILE} ]]; then
        write_settings_file "${SETTINGS_FILE}" generic "" "" || return 1
    fi
    chmod 600 "${SETTINGS_FILE}" || return 1
}

validate_port() {
    local value=${1:-}
    [[ ${value} =~ ^[0-9]{1,5}$ ]] && (( 10#${value} >= 1 && 10#${value} <= 65535 ))
}

validate_ipv4() {
    local value=${1:-} octet
    local -a octets=()

    [[ ${value} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "${value}"
    for octet in "${octets[@]}"; do
        [[ ${#octet} -eq 1 || ${octet} != 0* ]] || return 1
        (( 10#${octet} <= 255 )) || return 1
    done
}

validate_target_ipv4() {
    local value=$1
    validate_ipv4 "${value}" || return 1
    case ${value} in
        0.0.0.0|255.255.255.255|127.*) return 1 ;;
    esac
}

validate_mss() {
    local value=${1:-}
    [[ ${value} =~ ^[0-9]{3,5}$ ]] && (( 10#${value} >= 536 && 10#${value} <= 65535 ))
}

write_settings_file() {
    local output=$1 mode=$2 snat_ip=$3 tcp_mss=$4

    printf 'MODE=%s\nSNAT_IP=%s\nTCP_MSS=%s\n' \
        "${mode}" "${snat_ip}" "${tcp_mss}" > "${output}"
}

validate_settings_file() {
    local file=$1 line key value mode="" snat_ip="" tcp_mss=""
    local have_mode=no have_snat_ip=no have_tcp_mss=no

    [[ -f ${file} ]] || { error "设置文件不存在：${file}"; return 1; }
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} == *=* ]] || { error "设置文件包含无效行。"; return 1; }
        key=${line%%=*}
        value=${line#*=}
        case ${key} in
            MODE)
                [[ ${have_mode} == no ]] || { error "设置文件包含重复的 MODE。"; return 1; }
                mode=${value}
                have_mode=yes
                ;;
            SNAT_IP)
                [[ ${have_snat_ip} == no ]] || { error "设置文件包含重复的 SNAT_IP。"; return 1; }
                snat_ip=${value}
                have_snat_ip=yes
                ;;
            TCP_MSS)
                [[ ${have_tcp_mss} == no ]] || { error "设置文件包含重复的 TCP_MSS。"; return 1; }
                tcp_mss=${value}
                have_tcp_mss=yes
                ;;
            *)
                error "设置文件包含未知字段：${key}"
                return 1
                ;;
        esac
    done < "${file}"

    if [[ ${have_mode} != yes || ${have_snat_ip} != yes || ${have_tcp_mss} != yes ]]; then
        error "设置文件缺少必要字段。"
        return 1
    fi
    case ${mode} in
        generic)
            if [[ -n ${snat_ip}${tcp_mss} ]]; then
                error "通用模式不应设置 SNAT_IP 或 TCP_MSS。"
                return 1
            fi
            ;;
        po0)
            validate_target_ipv4 "${snat_ip}" || { error "Po0 SNAT 内网 IPv4 无效。"; return 1; }
            validate_mss "${tcp_mss}" || { error "Po0 TCP MSS 无效。"; return 1; }
            ;;
        *)
            error "不支持的转发模式：${mode}"
            return 1
            ;;
    esac
}

load_settings() {
    local line key value

    FORWARD_MODE="generic"
    PO0_SNAT_IP=""
    PO0_TCP_MSS=""
    [[ -e ${SETTINGS_FILE} ]] || return 0
    validate_settings_file "${SETTINGS_FILE}" || return 1
    while IFS= read -r line || [[ -n ${line} ]]; do
        key=${line%%=*}
        value=${line#*=}
        case ${key} in
            MODE) FORWARD_MODE=${value} ;;
            SNAT_IP) PO0_SNAT_IP=${value} ;;
            TCP_MSS) PO0_TCP_MSS=${value} ;;
        esac
    done < "${SETTINGS_FILE}"
}

resolve_target() {
    local target=$1 resolved

    if validate_target_ipv4 "${target}"; then
        printf '%s' "${target}"
        return 0
    fi
    [[ ${target} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    resolved=$(getent ahostsv4 "${target}" 2>/dev/null | awk 'NR == 1 { print $1 }')
    validate_target_ipv4 "${resolved}" || return 1
    printf '%s' "${resolved}"
}

validate_rules_file() {
    local file=$1 protocol local_port remote_ip remote_port extra key
    local line_number=0
    declare -A seen=()

    [[ -f ${file} ]] || { error "规则文件不存在：${file}"; return 1; }
    while IFS=$'\t' read -r protocol local_port remote_ip remote_port extra ||
          [[ -n ${protocol:-}${local_port:-}${remote_ip:-}${remote_port:-}${extra:-} ]]; do
        ((line_number += 1))
        if [[ -z ${protocol:-}${local_port:-}${remote_ip:-}${remote_port:-}${extra:-} ]]; then
            error "规则文件第 ${line_number} 行为空行。"
            return 1
        fi
        if [[ ${protocol} != tcp && ${protocol} != udp ]]; then
            error "规则文件第 ${line_number} 行协议无效。"
            return 1
        fi
        if ! validate_port "${local_port}" || ! validate_port "${remote_port}" ||
           ! validate_target_ipv4 "${remote_ip}" || [[ -n ${extra:-} ]]; then
            error "规则文件第 ${line_number} 行格式无效。"
            return 1
        fi
        key="${protocol}/${local_port}"
        if [[ -n ${seen[${key}]+present} ]]; then
            error "规则文件中存在重复监听项：${key}。"
            return 1
        fi
        seen[${key}]=1
    done < "${file}"
}

install_dependency() {
    if ! command -v nft >/dev/null 2>&1; then
        info "正在安装 nftables..."
        if ! apt-get update || ! DEBIAN_FRONTEND=noninteractive apt-get install -y nftables; then
            error "nftables 软件包安装失败。"
            return 1
        fi
    fi
    NFT_BIN=$(command -v nft || true)
    if [[ -z ${NFT_BIN} ]]; then
        error "nftables 安装失败或 nft 命令不可用。"
        return 1
    fi
}

write_sysctl_config() {
    install -d -m 755 /etc/sysctl.d || return 1
    if ! cat > "${SYSCTL_FILE}" <<'EOF'
# Managed by AI-Scripts nftables forwarding manager.
net.ipv4.ip_forward = 1
EOF
    then
        error "无法写入 ${SYSCTL_FILE}。"
        return 1
    fi
    chmod 644 "${SYSCTL_FILE}" || return 1
    if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null; then
        error "无法启用 net.ipv4.ip_forward。"
        return 1
    fi
}

write_service_file() {
    if ! cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=AI-Scripts nftables IPv4 port forwarding
Wants=network-online.target
After=network-online.target nftables.service ufw.service firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${NFT_BIN} delete table ${TABLE_FAMILY} ${TABLE_NAME}
ExecStart=${NFT_BIN} -f ${MANAGED_CONFIG}
ExecReload=-${NFT_BIN} delete table ${TABLE_FAMILY} ${TABLE_NAME}
ExecReload=${NFT_BIN} -f ${MANAGED_CONFIG}
ExecStop=-${NFT_BIN} delete table ${TABLE_FAMILY} ${TABLE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    then
        error "无法写入 ${UNIT_FILE}。"
        return 1
    fi
    chmod 644 "${UNIT_FILE}" || return 1
    systemctl daemon-reload || return 1
    if ! systemctl enable "${UNIT_NAME}" >/dev/null; then
        error "无法启用 ${UNIT_NAME}。"
        return 1
    fi
}

warn_firewall_interactions() {
    local firewall
    for firewall in ufw firewalld; do
        if systemctl is-active --quiet "${firewall}" 2>/dev/null; then
            warn "检测到 ${firewall} 正在运行；其转发策略或后续重载可能影响本脚本规则。"
        fi
    done
}

prepare_runtime() {
    ensure_state_files || return 1
    validate_rules_file "${RULES_FILE}" || return 1
    load_settings || return 1
    install_dependency || return 1
    write_sysctl_config || return 1
    write_service_file || return 1
}

generate_managed_config() {
    local output=$1 protocol local_port remote_ip remote_port

    {
        echo '# Managed by AI-Scripts. Manual edits will be overwritten.'
        echo "table ${TABLE_FAMILY} ${TABLE_NAME} {"
        echo '    chain prerouting {'
        echo '        type nat hook prerouting priority dstnat; policy accept;'
        while IFS=$'\t' read -r protocol local_port remote_ip remote_port; do
            [[ -n ${protocol:-} ]] || continue
            printf '        %s dport %s counter dnat to %s:%s\n' \
                "${protocol}" "${local_port}" "${remote_ip}" "${remote_port}"
        done < "${RULES_FILE}"
        echo '    }'
        echo
        echo '    chain postrouting {'
        echo '        type nat hook postrouting priority srcnat; policy accept;'
        while IFS=$'\t' read -r protocol local_port remote_ip remote_port; do
            [[ -n ${protocol:-} ]] || continue
            if [[ ${FORWARD_MODE} == po0 ]]; then
                printf '        ct status dnat ip daddr %s %s dport %s counter snat to %s\n' \
                    "${remote_ip}" "${protocol}" "${remote_port}" "${PO0_SNAT_IP}"
            else
                printf '        ct status dnat ip daddr %s %s dport %s counter masquerade\n' \
                    "${remote_ip}" "${protocol}" "${remote_port}"
            fi
        done < "${RULES_FILE}"
        echo '    }'
        echo
        echo '    chain forward {'
        echo '        type filter hook forward priority filter; policy accept;'
        if [[ ${FORWARD_MODE} == po0 ]]; then
            printf '        ct status dnat tcp flags & (syn | rst) == syn tcp option maxseg size set %s\n' \
                "${PO0_TCP_MSS}"
        fi
        echo '        ct state established,related counter accept'
        while IFS=$'\t' read -r protocol local_port remote_ip remote_port; do
            [[ -n ${protocol:-} ]] || continue
            printf '        ct status dnat ct state new ip daddr %s %s dport %s counter accept\n' \
                "${remote_ip}" "${protocol}" "${remote_port}"
        done < "${RULES_FILE}"
        echo '    }'
        echo '}'
    } > "${output}"
}

restore_live_table() {
    local previous_file=$1 had_previous=$2

    "${NFT_BIN}" delete table "${TABLE_FAMILY}" "${TABLE_NAME}" >/dev/null 2>&1 || true
    if [[ ${had_previous} == yes ]]; then
        if ! "${NFT_BIN}" -f "${previous_file}"; then
            error "无法恢复操作前的 nftables 表，请立即检查防火墙状态。"
            return 1
        fi
    fi
}

apply_managed_rules() {
    local generated runtime_batch previous_table old_config
    local had_previous=no had_old_config=no

    prepare_runtime || return 1
    generated=$(mktemp "${STATE_DIR}/.managed.XXXXXX") || return 1
    runtime_batch=$(mktemp "${STATE_DIR}/.runtime.XXXXXX") || { rm -f "${generated}"; return 1; }
    previous_table=$(mktemp "${STATE_DIR}/.previous-table.XXXXXX") || {
        rm -f "${generated}" "${runtime_batch}"
        return 1
    }
    old_config=$(mktemp "${STATE_DIR}/.old-config.XXXXXX") || {
        rm -f "${generated}" "${runtime_batch}" "${previous_table}"
        return 1
    }

    if ! generate_managed_config "${generated}"; then
        error "无法生成 nftables 配置。"
        rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
        return 1
    fi
    if "${NFT_BIN}" list table "${TABLE_FAMILY}" "${TABLE_NAME}" > "${previous_table}" 2>/dev/null; then
        had_previous=yes
    else
        : > "${previous_table}"
        if ! "${NFT_BIN}" add table "${TABLE_FAMILY}" "${TABLE_NAME}"; then
            error "无法创建 nftables 管理表。"
            rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
            return 1
        fi
    fi
    if [[ -f ${MANAGED_CONFIG} ]]; then
        if ! cp -a "${MANAGED_CONFIG}" "${old_config}"; then
            error "无法暂存当前持久化配置。"
            restore_live_table "${previous_table}" "${had_previous}" || true
            rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
            return 1
        fi
        had_old_config=yes
    fi

    if ! {
        echo "delete table ${TABLE_FAMILY} ${TABLE_NAME}"
        cat "${generated}"
    } > "${runtime_batch}"
    then
        error "无法生成 nftables 运行时事务。"
        restore_live_table "${previous_table}" "${had_previous}" || true
        rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
        return 1
    fi

    if ! "${NFT_BIN}" --check --file "${runtime_batch}"; then
        error "新规则未通过 nftables 语法检查。"
        restore_live_table "${previous_table}" "${had_previous}" || true
        rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
        return 1
    fi
    if ! "${NFT_BIN}" --file "${runtime_batch}"; then
        error "应用新规则失败，正在恢复操作前状态。"
        restore_live_table "${previous_table}" "${had_previous}" || true
        rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
        return 1
    fi
    if ! install -m 600 "${generated}" "${MANAGED_CONFIG}"; then
        error "保存持久化配置失败，正在恢复操作前状态。"
        restore_live_table "${previous_table}" "${had_previous}" || true
        if [[ ${had_old_config} == yes ]]; then
            install -m 600 "${old_config}" "${MANAGED_CONFIG}" || true
        else
            rm -f "${MANAGED_CONFIG}"
        fi
        rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
        return 1
    fi

    if ! systemctl is-active --quiet "${UNIT_NAME}"; then
        if ! systemctl start "${UNIT_NAME}"; then
            error "持久化服务启动失败，正在恢复操作前状态。"
            restore_live_table "${previous_table}" "${had_previous}" || true
            if [[ ${had_old_config} == yes ]]; then
                install -m 600 "${old_config}" "${MANAGED_CONFIG}" || true
            else
                rm -f "${MANAGED_CONFIG}"
            fi
            rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
            return 1
        fi
    fi

    rm -f "${generated}" "${runtime_batch}" "${previous_table}" "${old_config}"
    return 0
}

initialize_manager() {
    info "正在初始化 nftables IPv4 转发环境..."
    if apply_managed_rules; then
        info "初始化完成，规则已启用并设置为开机加载。"
        warn_firewall_interactions
    else
        error "初始化失败。"
        return 1
    fi
}

backup_configuration() {
    local reason=${1:-manual} timestamp

    ensure_state_files || return 1
    timestamp=$(date +%Y%m%d-%H%M%S)
    LAST_BACKUP_DIR=$(mktemp -d "${BACKUP_ROOT}/backup-${timestamp}-XXXXXX") || return 1
    if ! cp -a "${RULES_FILE}" "${LAST_BACKUP_DIR}/rules.tsv"; then
        error "无法复制规则文件到备份目录。"
        return 1
    fi
    if [[ -f ${SETTINGS_FILE} ]]; then
        cp -a "${SETTINGS_FILE}" "${LAST_BACKUP_DIR}/settings.conf" || return 1
    fi
    if [[ -f ${MANAGED_CONFIG} ]]; then
        cp -a "${MANAGED_CONFIG}" "${LAST_BACKUP_DIR}/ai-port-forward.nft" || return 1
    fi
    if command -v nft >/dev/null 2>&1; then
        nft list table "${TABLE_FAMILY}" "${TABLE_NAME}" \
            > "${LAST_BACKUP_DIR}/live-table.nft" 2>/dev/null || true
    fi
    printf 'created=%s\nreason=%s\nversion=%s\n' \
        "$(date --iso-8601=seconds)" "${reason}" "${VERSION}" \
        > "${LAST_BACKUP_DIR}/metadata"
    chmod -R go-rwx "${LAST_BACKUP_DIR}" || return 1
}

manual_backup() {
    if backup_configuration manual; then
        info "配置备份完成：${LAST_BACKUP_DIR}"
    else
        error "配置备份失败。"
    fi
}

replace_settings_file() {
    local candidate=$1 success_message=$2 old_settings
    local had_old_settings=no

    ensure_state_files || return 1
    validate_settings_file "${candidate}" || return 1
    old_settings=$(mktemp "${STATE_DIR}/.old-settings.XXXXXX") || return 1
    if [[ -f ${SETTINGS_FILE} ]]; then
        if ! cp -a "${SETTINGS_FILE}" "${old_settings}"; then
            rm -f "${old_settings}"
            return 1
        fi
        had_old_settings=yes
    fi
    if ! backup_configuration auto-before-mode-change; then
        error "自动备份失败，已取消本次修改。"
        rm -f "${old_settings}"
        return 1
    fi
    if ! install -m 600 "${candidate}" "${SETTINGS_FILE}"; then
        error "无法写入转发模式设置。"
        rm -f "${old_settings}"
        return 1
    fi
    if apply_managed_rules; then
        info "${success_message}"
        info "操作前备份：${LAST_BACKUP_DIR}"
        rm -f "${old_settings}"
        return 0
    fi

    error "模式修改失败，正在恢复操作前配置。"
    if [[ ${had_old_settings} == yes ]]; then
        install -m 600 "${old_settings}" "${SETTINGS_FILE}" || {
            error "无法恢复操作前的模式设置，请从 ${LAST_BACKUP_DIR} 手动恢复。"
            rm -f "${old_settings}"
            return 1
        }
    else
        rm -f "${SETTINGS_FILE}"
    fi
    load_settings || true
    if ! apply_managed_rules; then
        error "自动回滚未能完整应用，请从 ${LAST_BACKUP_DIR} 手动恢复。"
    fi
    rm -f "${old_settings}"
    return 1
}

show_forward_mode() {
    load_settings || return 1
    if [[ ${FORWARD_MODE} == po0 ]]; then
        echo "转发模式：Po0 优化"
        echo "SNAT 内网地址：${PO0_SNAT_IP}"
        echo "TCP MSS：${PO0_TCP_MSS}"
    else
        echo "转发模式：通用（MASQUERADE）"
    fi
}

show_local_ipv4_candidates() {
    local addresses

    command -v ip >/dev/null 2>&1 || return 0
    addresses=$(ip -o -4 addr show scope global 2>/dev/null |
        awk '{sub(/\/.*/, "", $4); printf "%s%s", separator, $4; separator=", "}')
    [[ -n ${addresses} ]] && echo "检测到的本机 IPv4：${addresses}"
}

configure_forwarding_mode() {
    local choice snat_ip tcp_mss candidate

    ensure_state_files || return 1
    load_settings || return 1
    echo "当前配置："
    show_forward_mode || return 1
    echo "-----------------------------------"
    echo "[1] 通用模式（动态 MASQUERADE）"
    echo "[2] Po0 优化模式（固定内网 IP SNAT + TCP MSS）"
    echo "[00] 返回主菜单"
    echo "-----------------------------------"
    read -r -p "请选择：" choice
    case ${choice} in
        1)
            candidate=$(mktemp "${STATE_DIR}/.settings-candidate.XXXXXX") || return 1
            write_settings_file "${candidate}" generic "" "" || {
                rm -f "${candidate}"
                return 1
            }
            replace_settings_file "${candidate}" "已切换到通用转发模式。" || true
            rm -f "${candidate}"
            ;;
        2)
            warn "Po0 模式必须填写本机的内网 IPv4，不是公网 IPv4，也不是落地机地址。"
            show_local_ipv4_candidates
            read -r -p "请输入本机 Po0 内网 IPv4：" snat_ip
            validate_target_ipv4 "${snat_ip}" || { error "内网 IPv4 无效。"; return 1; }
            read -r -p "请输入 TCP MSS（直接回车使用 1452）：" tcp_mss
            tcp_mss=${tcp_mss:-1452}
            validate_mss "${tcp_mss}" || { error "TCP MSS 必须为 536-65535 的整数。"; return 1; }
            candidate=$(mktemp "${STATE_DIR}/.settings-candidate.XXXXXX") || return 1
            write_settings_file "${candidate}" po0 "${snat_ip}" "${tcp_mss}" || {
                rm -f "${candidate}"
                return 1
            }
            replace_settings_file "${candidate}" "已启用 Po0 优化模式。" || true
            rm -f "${candidate}"
            ;;
        00) return 0 ;;
        *) warn "输入错误。"; return 1 ;;
    esac
}

replace_rules_file() {
    local candidate=$1 success_message=$2 old_rules

    validate_rules_file "${candidate}" || return 1
    old_rules=$(mktemp "${STATE_DIR}/.old-rules.XXXXXX") || return 1
    if ! cp -a "${RULES_FILE}" "${old_rules}"; then
        rm -f "${old_rules}"
        return 1
    fi
    if ! backup_configuration auto-before-change; then
        error "自动备份失败，已取消本次修改。"
        rm -f "${old_rules}"
        return 1
    fi
    if ! install -m 600 "${candidate}" "${RULES_FILE}"; then
        error "无法写入规则文件。"
        rm -f "${old_rules}"
        return 1
    fi
    if apply_managed_rules; then
        info "${success_message}"
        info "操作前备份：${LAST_BACKUP_DIR}"
        rm -f "${old_rules}"
        return 0
    fi

    error "规则修改失败，正在恢复操作前配置。"
    if ! install -m 600 "${old_rules}" "${RULES_FILE}"; then
        error "无法恢复操作前的规则文件，请从 ${LAST_BACKUP_DIR} 手动恢复。"
        rm -f "${old_rules}"
        return 1
    fi
    if ! apply_managed_rules; then
        error "自动回滚未能完整应用，请从 ${LAST_BACKUP_DIR} 手动恢复。"
    fi
    rm -f "${old_rules}"
    return 1
}

show_all_rules() {
    echo -e "${CYAN}当前 nftables IPv4 转发规则：${NC}"
    echo "--------------------------------------------------------------------------"
    if [[ ! -s ${RULES_FILE} ]]; then
        echo "当前没有配置规则。"
    else
        printf '%-5s %-6s %-10s %s\n' "编号" "协议" "本地端口" "目标"
        awk -F '\t' '{printf "%-5d %-6s %-10s %s:%s\n", NR, toupper($1), $2, $3, $4}' \
            "${RULES_FILE}"
    fi
    echo "--------------------------------------------------------------------------"
}

source_port_conflict() {
    local wanted_protocol=$1 wanted_port=$2 protocol local_port remote_ip remote_port
    while IFS=$'\t' read -r protocol local_port remote_ip remote_port; do
        [[ -n ${protocol:-} ]] || continue
        if [[ ${protocol} == "${wanted_protocol}" && ${local_port} == "${wanted_port}" ]]; then
            printf '%s %s -> %s:%s' "${protocol}" "${local_port}" "${remote_ip}" "${remote_port}"
            return 0
        fi
    done < "${RULES_FILE}"
    return 1
}

is_po0_blocked_port() {
    local wanted_port=$1 blocked_port

    for blocked_port in "${PO0_BLOCKED_PORTS[@]}"; do
        [[ ${wanted_port} == "${blocked_port}" ]] && return 0
    done
    return 1
}

add_forward_rule() {
    local mode=$1 local_port target remote_ip remote_port protocol conflict candidate confirm
    local -a protocols=()

    load_settings || return 1
    read -r -p "请输入本机监听端口 (1-65535)：" local_port
    validate_port "${local_port}" || { error "本机监听端口无效。"; return 1; }
    if [[ ${FORWARD_MODE} == po0 ]] && is_po0_blocked_port "${local_port}"; then
        warn "Po0 默认可能限制端口 ${local_port}；请先确认该端口在服务侧可用。"
        read -r -p "仍要继续添加吗？(y/N)：" confirm
        [[ ${confirm} =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }
    fi
    read -r -p "请输入目标 IPv4 或域名：" target
    remote_ip=$(resolve_target "${target}") || {
        error "目标无效、无法解析，或属于不支持的本机/保留地址。"
        return 1
    }
    if [[ ${target} != "${remote_ip}" ]]; then
        info "域名已解析为 ${remote_ip}；规则不会自动跟随 DNS 变化。"
    fi
    read -r -p "请输入目标端口 (1-65535)：" remote_port
    validate_port "${remote_port}" || { error "目标端口无效。"; return 1; }

    if [[ ${mode} == both ]]; then
        protocols=(tcp udp)
    else
        protocols=("${mode}")
    fi
    for protocol in "${protocols[@]}"; do
        if conflict=$(source_port_conflict "${protocol}" "${local_port}"); then
            error "监听端口已被本脚本规则占用：${conflict}"
            return 1
        fi
    done

    candidate=$(mktemp "${STATE_DIR}/.rules-candidate.XXXXXX") || return 1
    if ! cp -a "${RULES_FILE}" "${candidate}"; then
        rm -f "${candidate}"
        return 1
    fi
    for protocol in "${protocols[@]}"; do
        printf '%s\t%s\t%s\t%s\n' \
            "${protocol}" "${local_port}" "${remote_ip}" "${remote_port}" >> "${candidate}"
    done
    if ! replace_rules_file "${candidate}" \
        "已添加：${local_port} -> ${remote_ip}:${remote_port} (${mode})"; then
        rm -f "${candidate}"
        return 1
    fi
    rm -f "${candidate}"
}

choose_protocol() {
    local choice
    SELECTED_PROTOCOL=""
    while true; do
        echo "请选择转发协议："
        echo "-----------------------------------"
        echo "[1] TCP + UDP"
        echo "[2] 仅 TCP"
        echo "[3] 仅 UDP"
        echo "[00] 返回主菜单"
        echo "-----------------------------------"
        read -r -p "请选择：" choice
        case ${choice} in
            1) SELECTED_PROTOCOL=both; return 0 ;;
            2) SELECTED_PROTOCOL=tcp; return 0 ;;
            3) SELECTED_PROTOCOL=udp; return 0 ;;
            00) return 1 ;;
            *) warn "输入错误，请重新选择。" ;;
        esac
    done
}

add_rule_menu() {
    local mode choice

    while true; do
        clear_screen
        choose_protocol || return 0
        mode=${SELECTED_PROTOCOL}
        add_forward_rule "${mode}" || true
        echo
        show_all_rules
        echo "[1] 继续添加新的转发规则"
        echo "[00] 返回主菜单"
        read -r -p "请选择：" choice
        case ${choice} in
            1) ;;
            00) return 0 ;;
            *) warn "输入无效，返回主菜单。"; return 0 ;;
        esac
    done
}

delete_rule_menu() {
    local number number_value total candidate

    while true; do
        clear_screen
        show_all_rules
        if [[ ! -s ${RULES_FILE} ]]; then
            pause_menu
            return 0
        fi
        read -r -p "请输入要删除的规则编号 (输入 00 返回主菜单)：" number
        [[ ${number} == 00 ]] && return 0
        if [[ ! ${number} =~ ^[0-9]{1,9}$ ]]; then
            error "请输入正确的数字。"
            pause_menu
            continue
        fi
        number_value=$((10#${number}))
        total=$(wc -l < "${RULES_FILE}")
        if (( number_value < 1 || number_value > total )); then
            error "输入的编号不在有效范围内。"
            pause_menu
            continue
        fi

        candidate=$(mktemp "${STATE_DIR}/.rules-candidate.XXXXXX") || return 1
        if ! awk -v target="${number_value}" 'NR != target' "${RULES_FILE}" > "${candidate}"; then
            error "无法生成删除后的规则文件。"
            rm -f "${candidate}"
            return 1
        fi
        replace_rules_file "${candidate}" "已删除第 ${number_value} 条规则。" || true
        rm -f "${candidate}"
        pause_menu
    done
}

restore_backup_configuration() {
    local backup_dir=$1 old_rules old_settings
    local backup_rules="${backup_dir}/rules.tsv"
    local backup_settings="${backup_dir}/settings.conf"
    local had_old_settings=no

    validate_rules_file "${backup_rules}" || return 1
    if [[ -f ${backup_settings} ]]; then
        validate_settings_file "${backup_settings}" || return 1
    fi
    old_rules=$(mktemp "${STATE_DIR}/.old-rules.XXXXXX") || return 1
    old_settings=$(mktemp "${STATE_DIR}/.old-settings.XXXXXX") || {
        rm -f "${old_rules}"
        return 1
    }
    if ! cp -a "${RULES_FILE}" "${old_rules}"; then
        rm -f "${old_rules}" "${old_settings}"
        return 1
    fi
    if [[ -f ${SETTINGS_FILE} ]]; then
        if ! cp -a "${SETTINGS_FILE}" "${old_settings}"; then
            rm -f "${old_rules}" "${old_settings}"
            return 1
        fi
        had_old_settings=yes
    fi
    if ! backup_configuration auto-before-restore; then
        error "自动备份失败，已取消恢复。"
        rm -f "${old_rules}" "${old_settings}"
        return 1
    fi
    if ! install -m 600 "${backup_rules}" "${RULES_FILE}"; then
        error "无法恢复规则文件。"
        rm -f "${old_rules}" "${old_settings}"
        return 1
    fi
    if [[ -f ${backup_settings} ]]; then
        install -m 600 "${backup_settings}" "${SETTINGS_FILE}" || {
            error "无法恢复模式设置，正在回滚。"
            install -m 600 "${old_rules}" "${RULES_FILE}" || true
            if [[ ${had_old_settings} == yes ]]; then
                install -m 600 "${old_settings}" "${SETTINGS_FILE}" || true
            else
                rm -f "${SETTINGS_FILE}"
            fi
            rm -f "${old_rules}" "${old_settings}"
            return 1
        }
    elif ! write_settings_file "${SETTINGS_FILE}" generic "" "" ||
        ! chmod 600 "${SETTINGS_FILE}"; then
        error "无法恢复模式设置，正在回滚。"
        install -m 600 "${old_rules}" "${RULES_FILE}" || true
        if [[ ${had_old_settings} == yes ]]; then
            install -m 600 "${old_settings}" "${SETTINGS_FILE}" || true
        else
            rm -f "${SETTINGS_FILE}"
        fi
        rm -f "${old_rules}" "${old_settings}"
        return 1
    fi
    if apply_managed_rules; then
        info "已恢复备份：$(basename "${backup_dir}")"
        info "恢复前备份：${LAST_BACKUP_DIR}"
        rm -f "${old_rules}" "${old_settings}"
        return 0
    fi

    error "恢复备份失败，正在恢复操作前配置。"
    install -m 600 "${old_rules}" "${RULES_FILE}" || {
        error "无法恢复操作前的规则文件，请从 ${LAST_BACKUP_DIR} 手动恢复。"
        rm -f "${old_rules}" "${old_settings}"
        return 1
    }
    if [[ ${had_old_settings} == yes ]]; then
        install -m 600 "${old_settings}" "${SETTINGS_FILE}" || true
    else
        rm -f "${SETTINGS_FILE}"
    fi
    load_settings || true
    if ! apply_managed_rules; then
        error "自动回滚未能完整应用，请从 ${LAST_BACKUP_DIR} 手动恢复。"
    fi
    rm -f "${old_rules}" "${old_settings}"
    return 1
}

restore_backup_menu() {
    local choice choice_value selected_backup
    local -a backups=()
    local index

    mapfile -t backups < <(
        find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d \
            -name 'backup-*' -print | sort -r
    )
    if (( ${#backups[@]} == 0 )); then
        warn "未找到可用备份。"
        return 0
    fi

    echo "可用备份："
    for index in "${!backups[@]}"; do
        printf '[%d] %s\n' "$((index + 1))" "$(basename "${backups[${index}]}")"
    done
    echo "[00] 返回主菜单"
    read -r -p "请选择要恢复的备份：" choice
    [[ ${choice} == 00 ]] && return 0
    if [[ ! ${choice} =~ ^[0-9]{1,9}$ ]]; then
        error "请输入正确的数字。"
        return 1
    fi
    choice_value=$((10#${choice}))
    if (( choice_value < 1 || choice_value > ${#backups[@]} )); then
        error "备份编号无效。"
        return 1
    fi
    selected_backup=${backups[$((choice_value - 1))]}
    restore_backup_configuration "${selected_backup}"
}

clear_all_rules() {
    local confirm candidate

    show_all_rules
    [[ -s ${RULES_FILE} ]] || return 0
    read -r -p "该操作将清空本脚本管理的全部转发规则，输入 CLEAR 确认：" confirm
    [[ ${confirm} == CLEAR ]] || { info "已取消。"; return 0; }
    candidate=$(mktemp "${STATE_DIR}/.rules-candidate.XXXXXX") || return 1
    : > "${candidate}"
    replace_rules_file "${candidate}" "已清空本脚本管理的全部规则。" || true
    rm -f "${candidate}"
}

reload_rules() {
    if apply_managed_rules; then
        info "规则已重新生成并加载。"
        warn_firewall_interactions
    else
        error "规则重新加载失败。"
        return 1
    fi
}

show_status() {
    echo -e "${CYAN}nftables 转发状态：${NC}"
    if ! show_forward_mode; then
        error "无法读取转发模式设置。"
    fi
    if command -v nft >/dev/null 2>&1; then
        nft --version
    else
        warn "nftables 尚未安装。"
    fi
    printf 'IPv4 转发：%s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    if [[ -f ${UNIT_FILE} ]]; then
        printf '开机加载：%s\n' "$(systemctl is-enabled "${UNIT_NAME}" 2>/dev/null || true)"
        printf '服务状态：%s\n' "$(systemctl is-active "${UNIT_NAME}" 2>/dev/null || true)"
    else
        echo "持久化服务：未初始化"
    fi
    if command -v nft >/dev/null 2>&1 &&
       nft list table "${TABLE_FAMILY}" "${TABLE_NAME}" >/dev/null 2>&1; then
        echo "管理表状态：已加载"
    else
        echo "管理表状态：未加载"
    fi
    echo
    show_all_rules
}

main_menu() {
    local choice

    while true; do
        clear_screen
        echo -e "${BLUE}====================================================${NC}"
        echo -e "${CYAN}       nftables IPv4 端口转发管理 v${VERSION}${NC}"
        echo -e "${BLUE}====================================================${NC}"
        echo "1. 安装/初始化 nftables"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo "5. 重新加载规则"
        echo "6. 查看运行状态"
        echo "7. 备份转发配置"
        echo "8. 恢复转发配置"
        echo "9. 清空全部转发规则"
        echo "10. 转发模式设置（通用/Po0）"
        echo "00. 退出脚本"
        echo -e "${BLUE}====================================================${NC}"
        read -r -p "请输入选项：" choice
        case ${choice} in
            1) initialize_manager || true; pause_menu ;;
            2) add_rule_menu ;;
            3) clear_screen; show_all_rules; pause_menu ;;
            4) delete_rule_menu ;;
            5) reload_rules || true; pause_menu ;;
            6) clear_screen; show_status; pause_menu ;;
            7) manual_backup; pause_menu ;;
            8) restore_backup_menu || true; pause_menu ;;
            9) clear_all_rules; pause_menu ;;
            10) clear_screen; configure_forwarding_mode || true; pause_menu ;;
            00) return 0 ;;
            *) warn "请输入正确的选项。"; pause_menu ;;
        esac
    done
}

main() {
    require_supported_system
    ensure_state_files
    validate_rules_file "${RULES_FILE}" || exit 1
    load_settings || exit 1
    main_menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
