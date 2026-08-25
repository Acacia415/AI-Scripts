#!/bin/bash
# --- 专属配置 ---
DNS_GOST_CONFIG_PATH="${DNS_UNLOCK_GOST_CONFIG_PATH:-/etc/gost/dns-unlock-config.yml}"
DNS_GOST_SERVICE_NAME="${DNS_UNLOCK_GOST_SERVICE_NAME:-gost-dns.service}"
DNS_GOST_SERVICE_PATH="${DNS_UNLOCK_GOST_SERVICE_PATH:-/etc/systemd/system/${DNS_GOST_SERVICE_NAME}}"
GOST_INSTALL_PATH="${DNS_UNLOCK_GOST_INSTALL_PATH:-/usr/local/bin/gost}"
DNSMASQ_CONFIG_FILE="${DNS_UNLOCK_DNSMASQ_CONFIG_FILE:-/etc/dnsmasq.d/custom_unlock.conf}"
DNSMASQ_MAIN_CONFIG="${DNS_UNLOCK_DNSMASQ_MAIN_CONFIG:-/etc/dnsmasq.conf}"
RESOLV_CONF_PATH="${DNS_UNLOCK_RESOLV_CONF_PATH:-/etc/resolv.conf}"
GAI_CONF_PATH="${DNS_UNLOCK_GAI_CONF_PATH:-/etc/gai.conf}"
STATE_DIR="${DNS_UNLOCK_STATE_DIR:-/var/lib/ai-scripts/dns-unlock}"
BACKUP_ROOT="${DNS_UNLOCK_BACKUP_ROOT:-/var/backups/ai-scripts/dns-unlock}"
SERVER_ORIGINAL_SNAPSHOT="$STATE_DIR/server-original"
CLIENT_ORIGINAL_SNAPSHOT="$STATE_DIR/client-original"
SERVER_MANAGED_MARKER="$STATE_DIR/server.managed"
CLIENT_MANAGED_MARKER="$STATE_DIR/client.managed"
SERVER_GOST_MANAGED_MARKER="$STATE_DIR/server-gost.managed"
SERVER_RESOLVED_MANAGED_MARKER="$STATE_DIR/server-resolved.managed"
SERVER_SNIPROXY_MANAGED_MARKER="$STATE_DIR/server-sniproxy.managed"
IPV6_BLOCK_MARKER="$STATE_DIR/ipv6-block.managed"
DNS_ENFORCE_MARKER="$STATE_DIR/dns-enforce.managed"
GOST_RELEASE_API="${DNS_UNLOCK_GOST_RELEASE_API:-https://api.github.com/repos/go-gost/gost/releases/latest}"
FIREWALL_COMMENT="AI-Scripts:dns-unlock"
DNS_V4_CHAIN="AI_DNS_UNLOCK_OUT"
DNS_V6_CHAIN="AI_DNS_UNLOCK6_OUT"
IPV6_BLOCK_CHAIN="AI_DNS_UNLOCK6_BLK"
transaction_backup=""
selected_gost_binary=""
install_new_gost=false
SERVER_RESOLVED_CHANGED=false
STOP_SNIPROXY=false

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# --- 安全检查: 确保以 root 权限运行 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误：本脚本需要以 root 权限运行。${NC}"
       echo -e "${GREEN}请尝试使用: sudo bash $0${NC}"
       return 1
    fi
}


# ======================= 帮助函数 =======================

is_valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

snapshot_item() {
    local snapshot="$1" label="$2" source_path="$3"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
        cp -a -- "$source_path" "$snapshot/$label" || return 1
        : > "$snapshot/$label.present"
    else
        : > "$snapshot/$label.absent"
    fi
}

snapshot_service_state() {
    local snapshot="$1" label="$2" service="$3"
    systemctl is-enabled --quiet "$service" 2>/dev/null && : > "$snapshot/$label.enabled"
    systemctl is-active --quiet "$service" 2>/dev/null && : > "$snapshot/$label.active"
}

create_system_snapshot() {
    umask 077
    mkdir -p "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT"
    transaction_backup=$(mktemp -d "$BACKUP_ROOT/transaction.XXXXXXXX") || return 1
    snapshot_item "$transaction_backup" gost-binary "$GOST_INSTALL_PATH" || return 1
    snapshot_item "$transaction_backup" gost-config "$DNS_GOST_CONFIG_PATH" || return 1
    snapshot_item "$transaction_backup" gost-service "$DNS_GOST_SERVICE_PATH" || return 1
    snapshot_item "$transaction_backup" dnsmasq-custom "$DNSMASQ_CONFIG_FILE" || return 1
    snapshot_item "$transaction_backup" dnsmasq-main "$DNSMASQ_MAIN_CONFIG" || return 1
    snapshot_item "$transaction_backup" resolv-conf "$RESOLV_CONF_PATH" || return 1
    if [[ -e "$RESOLV_CONF_PATH" && ! -L "$RESOLV_CONF_PATH" ]] && lsattr -d "$RESOLV_CONF_PATH" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        : > "$transaction_backup/resolv-conf.immutable"
    fi
    snapshot_service_state "$transaction_backup" gost-dns "$DNS_GOST_SERVICE_NAME"
    snapshot_service_state "$transaction_backup" dnsmasq dnsmasq
    snapshot_service_state "$transaction_backup" sniproxy sniproxy
    snapshot_service_state "$transaction_backup" systemd-resolved systemd-resolved
    package_installed dnsmasq && : > "$transaction_backup/dnsmasq.package-present"
    package_installed sniproxy && : > "$transaction_backup/sniproxy.package-present"
    return 0
}

restore_snapshot_item() {
    local snapshot="$1" label="$2" target_path="$3"
    if [[ -f "$snapshot/$label.present" ]]; then
        [[ "$target_path" != "$RESOLV_CONF_PATH" ]] || chattr -i "$target_path" 2>/dev/null || true
        rm -rf -- "$target_path"
        mkdir -p "$(dirname "$target_path")"
        cp -a -- "$snapshot/$label" "$target_path"
    elif [[ -f "$snapshot/$label.absent" ]]; then
        [[ "$target_path" != "$RESOLV_CONF_PATH" ]] || chattr -i "$target_path" 2>/dev/null || true
        rm -rf -- "$target_path"
    fi
}

restore_service_state() {
    local snapshot="$1" label="$2" service="$3" result=0
    if [[ -f "$snapshot/$label.enabled" ]]; then
        systemctl enable "$service" >/dev/null 2>&1 || result=1
    else
        systemctl disable "$service" >/dev/null 2>&1 || true
    fi
    if [[ -f "$snapshot/$label.active" ]]; then
        systemctl start "$service" >/dev/null 2>&1 || result=1
    else
        systemctl stop "$service" >/dev/null 2>&1 || true
    fi
    return "$result"
}

restore_system_snapshot() {
    local snapshot="$1" restore_packages="${2:-true}" restore_binary="${3:-true}"
    local restore_resolved="${4:-true}" restore_sniproxy="${5:-true}"
    local restore_result=0
    [[ -d "$snapshot" ]] || return 1
    echo -e "${YELLOW}注意: 正在恢复修改前的 DNS 解锁文件和服务状态...${NC}"
    systemctl stop "$DNS_GOST_SERVICE_NAME" dnsmasq >/dev/null 2>&1 || true
    if [[ "$restore_packages" == true && ! -f "$snapshot/dnsmasq.package-present" ]] && package_installed dnsmasq; then
        apt-get purge -y dnsmasq >/dev/null 2>&1 || { echo -e "${RED}错误: 无法移除本脚本安装的 dnsmasq 软件包。${NC}"; restore_result=1; }
    fi
    [[ "$restore_binary" != true ]] || restore_snapshot_item "$snapshot" gost-binary "$GOST_INSTALL_PATH" || return 1
    restore_snapshot_item "$snapshot" gost-config "$DNS_GOST_CONFIG_PATH" || return 1
    restore_snapshot_item "$snapshot" gost-service "$DNS_GOST_SERVICE_PATH" || return 1
    restore_snapshot_item "$snapshot" dnsmasq-custom "$DNSMASQ_CONFIG_FILE" || return 1
    restore_snapshot_item "$snapshot" dnsmasq-main "$DNSMASQ_MAIN_CONFIG" || return 1
    if [[ "$restore_resolved" == true ]]; then
        restore_snapshot_item "$snapshot" resolv-conf "$RESOLV_CONF_PATH" || return 1
        [[ ! -f "$snapshot/resolv-conf.immutable" ]] || chattr +i "$RESOLV_CONF_PATH" 2>/dev/null || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ "$restore_resolved" != true ]] || restore_service_state "$snapshot" systemd-resolved systemd-resolved || restore_result=1
    [[ "$restore_sniproxy" != true ]] || restore_service_state "$snapshot" sniproxy sniproxy || restore_result=1
    restore_service_state "$snapshot" dnsmasq dnsmasq || restore_result=1
    restore_service_state "$snapshot" gost-dns "$DNS_GOST_SERVICE_NAME" || restore_result=1
    return "$restore_result"
}

create_client_snapshot() {
    umask 077
    mkdir -p "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT"
    transaction_backup=$(mktemp -d "$BACKUP_ROOT/transaction.XXXXXXXX") || return 1
    snapshot_item "$transaction_backup" resolv-conf "$RESOLV_CONF_PATH" || return 1
    if [[ -e "$RESOLV_CONF_PATH" && ! -L "$RESOLV_CONF_PATH" ]] && lsattr -d "$RESOLV_CONF_PATH" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        : > "$transaction_backup/resolv-conf.immutable"
    fi
    snapshot_item "$transaction_backup" gai-conf "$GAI_CONF_PATH" || return 1
    snapshot_service_state "$transaction_backup" systemd-resolved systemd-resolved
    [[ ! -f "$IPV6_BLOCK_MARKER" ]] || : > "$transaction_backup/ipv6-block.preexisting"
    return 0
}

restore_client_snapshot() {
    local snapshot="$1" restore_result=0
    [[ -d "$snapshot" ]] || return 1
    restore_snapshot_item "$snapshot" resolv-conf "$RESOLV_CONF_PATH" || return 1
    [[ ! -f "$snapshot/resolv-conf.immutable" ]] || chattr +i "$RESOLV_CONF_PATH" 2>/dev/null || true
    restore_snapshot_item "$snapshot" gai-conf "$GAI_CONF_PATH" || return 1
    restore_service_state "$snapshot" systemd-resolved systemd-resolved || restore_result=1
    return "$restore_result"
}

prune_transaction_backups() {
    local backups=() index
    mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for ((index=5; index<${#backups[@]}; index++)); do
        [[ "${backups[$index]}" == "$BACKUP_ROOT"/transaction.* ]] && rm -rf -- "${backups[$index]}"
    done
}

commit_original_snapshot() {
    local original_snapshot="$1" marker="$2"
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if [[ ! -f "$marker" ]]; then
        if [[ -e "$original_snapshot" ]]; then
            echo -e "${RED}错误: 存在未标记的旧状态目录，拒绝覆盖: $original_snapshot${NC}"
            return 1
        fi
        cp -a -- "$transaction_backup" "$original_snapshot" || return 1
        : > "$marker"
        chmod 600 "$marker"
    fi
    prune_transaction_backups
}

check_supported_system() {
    [[ -r /etc/os-release ]] || { echo -e "${RED}错误: 无法识别系统。${NC}"; return 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) return 0 ;;
        *) echo -e "${RED}错误: 当前脚本仅支持 Debian/Ubuntu 系。${NC}"; return 1 ;;
    esac
}

install_dependencies() {
    echo -e "${BLUE}信息: 正在安装/检查核心依赖...${NC}"
    apt-get update >/dev/null 2>&1 &&
        apt-get install -y ca-certificates coreutils curl dnsmasq dnsutils file iptables jq lsof tar >/dev/null 2>&1
}

wait_for_service_active() {
    local service="$1" attempts="${DNS_UNLOCK_SERVICE_CHECK_ATTEMPTS:-5}" delay="${DNS_UNLOCK_SERVICE_CHECK_DELAY:-1}" count
    for ((count=1; count<=attempts; count++)); do
        systemctl is-active --quiet "$service" && return 0
        sleep "$delay"
    done
    return 1
}

map_gost_arch() {
    local machine="$1"
    case "$machine" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7*) printf 'armv7\n' ;;
        armv6*) printf 'armv6\n' ;;
        armv5*) printf 'armv5\n' ;;
        i386|i686) printf '386\n' ;;
        loongarch64) printf 'loong64\n' ;;
        riscv64|s390x) printf '%s\n' "$machine" ;;
        *) return 1 ;;
    esac
}

fetch_latest_gost_release() {
    local release_json="$1" arch="$2" tag
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 \
        -H 'Accept: application/vnd.github+json' "$GOST_RELEASE_API" -o "$release_json" || return 1
    tag=$(jq -er '.tag_name | select(type == "string" and test("^v[0-9]+([.][0-9]+){2}([-.][0-9A-Za-z.]+)?$"))' "$release_json") || return 1
    latest_gost_version="${tag#v}"
    latest_gost_asset="gost_${latest_gost_version}_linux_${arch}.tar.gz"
    latest_gost_url=$(jq -er --arg name "$latest_gost_asset" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json" | head -n 1)
    latest_gost_checksums_url=$(jq -er '.assets[] | select(.name == "checksums.txt") | .browser_download_url' "$release_json" | head -n 1)
    [[ "$latest_gost_url" == https://github.com/go-gost/gost/releases/download/* ]] || return 1
    [[ "$latest_gost_checksums_url" == https://github.com/go-gost/gost/releases/download/* ]] || return 1
}

download_latest_gost() {
    local stage_dir="$1" archive expected actual
    archive="$stage_dir/$latest_gost_asset"
    curl --fail --show-error --location --retry 3 --connect-timeout 10 "$latest_gost_url" -o "$archive" || return 1
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 "$latest_gost_checksums_url" -o "$stage_dir/checksums.txt" || return 1
    expected=$(awk -v asset="$latest_gost_asset" '$2 == asset {print $1; exit}' "$stage_dir/checksums.txt")
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || return 1
    tar -tzf "$archive" >/dev/null && tar -xzf "$archive" -C "$stage_dir" || return 1
    [[ -s "$stage_dir/gost" ]] || return 1
    chmod 755 "$stage_dir/gost"
    "$stage_dir/gost" -V >/dev/null 2>&1
}

gost_supports_v3_yaml() {
    local binary="$1" test_config version_output
    [[ -x "$binary" ]] || return 1
    version_output=$("$binary" -V 2>&1 | head -n 1)
    [[ "$version_output" =~ [Gg][Oo][Ss][Tt][[:space:]]+v?3[.] ]] || return 1
    test_config=$(mktemp "${TMPDIR:-/tmp}/gost-v3-check.XXXXXXXX.yml") || return 1
    printf 'services: []\n' > "$test_config"
    if ! "$binary" -C "$test_config" -O yaml >/dev/null 2>&1; then
        rm -f "$test_config"
        return 1
    fi
    rm -f "$test_config"
}

select_or_stage_gost() {
    local stage_dir="$1" existing_gost arch choice
    existing_gost=$(command -v gost 2>/dev/null || true)
    if [[ -n "$existing_gost" ]] && gost_supports_v3_yaml "$existing_gost"; then
        selected_gost_binary="$existing_gost"
        install_new_gost=false
        echo -e "${GREEN}检测到兼容 GOST v3/YAML: $existing_gost ($("$existing_gost" -V))${NC}"
        return 0
    fi
    if [[ -n "$existing_gost" ]]; then
        echo -e "${YELLOW}警告: 现有 GOST 不支持 v3 YAML 配置: $existing_gost${NC}"
        read -r -p "是否安全安装官方最新版供 DNS 解锁服务独立使用? (y/N): " choice
        [[ "$choice" =~ ^[yY]$ ]] || return 1
    fi
    arch=$(map_gost_arch "$(uname -m)") || { echo -e "${RED}错误: 不支持的架构 $(uname -m)。${NC}"; return 1; }
    if ! fetch_latest_gost_release "$stage_dir/release.json" "$arch"; then
        echo -e "${RED}错误: 无法从 GOST release API 精确匹配 linux/${arch} 最新资产；未使用固定版本回退。${NC}"
        return 1
    fi
    echo -e "${BLUE}信息: 正在下载并校验 GOST v${latest_gost_version} (${arch})...${NC}"
    download_latest_gost "$stage_dir" || return 1
    gost_supports_v3_yaml "$stage_dir/gost" || return 1
    selected_gost_binary="$stage_dir/gost"
    install_new_gost=true
}

# 检测并自动安装iptables
check_and_install_iptables() {
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}警告: iptables 未安装，正在自动安装...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
        if command -v iptables &>/dev/null; then
            echo -e "${GREEN}成功: iptables 已成功安装。${NC}"
        else
            echo -e "${RED}错误: iptables 安装失败，某些功能可能无法使用。${NC}"
            return 1
        fi
    fi
    return 0
}

check_port_53() {
    local proto pids process_names choice resolved_seen=false
    for proto in tcp udp; do
        if [[ "$proto" == "tcp" ]]; then
            pids=$(lsof -nP -t -iTCP:53 -sTCP:LISTEN 2>/dev/null | sort -u || true)
        else
            pids=$(lsof -nP -t -iUDP:53 2>/dev/null | sort -u || true)
        fi
        [[ -n "$pids" ]] || continue
        process_names=$(ps -p "$(paste -sd, <<< "$pids")" -o comm= 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)
        grep -Eq '^systemd-resolve(d)?$' <<< "$process_names" && resolved_seen=true
        if grep -Evq '^(dnsmasq|systemd-resolve|systemd-resolved)$' <<< "$process_names"; then
            echo -e "${RED}错误: 端口 53/${proto} 已被非 dnsmasq 进程占用: ${process_names//$'\n'/, }${NC}"
            return 1
        fi
    done

    if [[ "$resolved_seen" == true ]]; then
        echo -e "${YELLOW}警告: systemd-resolved 正在占用 TCP 或 UDP 53。${NC}"
        read -r -p "是否临时禁用该服务并继续? (Y/n): " choice
        if [[ "$choice" =~ ^[Nn]$ ]]; then
            return 1
        fi
        systemctl disable --now systemd-resolved || return 1
        SERVER_RESOLVED_CHANGED=true
        if [[ -L "$RESOLV_CONF_PATH" ]]; then
            rm -f "$RESOLV_CONF_PATH"
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$RESOLV_CONF_PATH"
        fi
        sleep "${DNS_UNLOCK_PORT_RELEASE_DELAY:-2}"
        for proto in tcp udp; do
            if [[ "$proto" == "tcp" ]]; then
                pids=$(lsof -nP -t -iTCP:53 -sTCP:LISTEN 2>/dev/null | sort -u || true)
            else
                pids=$(lsof -nP -t -iUDP:53 2>/dev/null | sort -u || true)
            fi
            [[ -n "$pids" ]] || continue
            process_names=$(ps -p "$(paste -sd, <<< "$pids")" -o comm= 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)
            if grep -Evq '^dnsmasq$' <<< "$process_names"; then
                echo -e "${RED}错误: ${proto^^}/53 仍被占用: ${process_names//$'\n'/, }${NC}"
                return 1
            fi
        done
    fi
}

check_ports_80_443() {
    local port pids process_names choice own_pid
    STOP_SNIPROXY=false
    own_pid=$(systemctl show -p MainPID --value "$DNS_GOST_SERVICE_NAME" 2>/dev/null || true)
    for port in 80 443; do
        pids=$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)
        [[ -n "$own_pid" && "$own_pid" != "0" ]] && pids=$(grep -vx "$own_pid" <<< "$pids" || true)
        [[ -n "$pids" ]] || continue
        process_names=$(ps -p "$(paste -sd, <<< "$pids")" -o comm= 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)
        echo -e "${YELLOW}警告: TCP/${port} 已被进程占用: ${process_names//$'\n'/, }${NC}"
        read -r -p "是否仍然继续检查其余端口并尝试安装? (y/N): " choice
        [[ "$choice" =~ ^[yY]$ ]] || return 1
        grep -q '^sniproxy$' <<< "$process_names" && STOP_SNIPROXY=true
    done
    return 0
}


# ======================= 客户端辅助函数 =======================

disable_systemd_resolved_if_running() {
    if systemctl is-active --quiet systemd-resolved; then
        echo -e "${YELLOW}警告: 检测到 systemd-resolved 正在运行，可能拦截 127.0.0.53:53。${NC}"
        read -r -p "是否禁用并停止 systemd-resolved，并解除 $RESOLV_CONF_PATH 软链接? (Y/n): " choice
        if [[ "$choice" =~ ^[yY]$ ]] || [[ -z "$choice" ]]; then
            systemctl disable --now systemd-resolved
            # 若 resolv.conf 为软链接，则移除并创建普通文件
            if [[ -L "$RESOLV_CONF_PATH" ]]; then
                rm -f "$RESOLV_CONF_PATH"
                touch "$RESOLV_CONF_PATH"
            fi
            echo -e "${GREEN}成功: 已禁用 systemd-resolved。${NC}"
        else
            echo -e "${YELLOW}提示: 已跳过禁用 systemd-resolved，可能导致 DNS 配置被覆盖或劫持。${NC}"
            return 1
        fi
    fi
}

set_resolv_conf() {
    local server_ip="$1"
    local resolv_temp
    is_valid_ipv4 "$server_ip" || return 1
    chattr -i "$RESOLV_CONF_PATH" 2>/dev/null || true
    [[ ! -L "$RESOLV_CONF_PATH" ]] || rm -f "$RESOLV_CONF_PATH"
    mkdir -p "$(dirname "$RESOLV_CONF_PATH")"
    resolv_temp=$(mktemp "$(dirname "$RESOLV_CONF_PATH")/.resolv.conf.XXXXXXXX") || return 1
    echo -e "${BLUE}信息: 正在写入新的 DNS 配置 (nameserver ${server_ip})...${NC}"
    printf "nameserver %s\n" "$server_ip" > "$resolv_temp"
    chmod 644 "$resolv_temp"
    mv -f "$resolv_temp" "$RESOLV_CONF_PATH"
    if chattr +i "$RESOLV_CONF_PATH"; then
        echo -e "${GREEN}成功: /etc/resolv.conf 已锁定，防止被覆盖。${NC}"
    else
        echo -e "${YELLOW}警告: 无法锁定 /etc/resolv.conf（缺少 chattr 或不支持），继续。${NC}"
    fi
}

ensure_ipv4_preference() {
    echo -e "${BLUE}信息: 正在设置系统优先使用 IPv4（$GAI_CONF_PATH）...${NC}"
    if [[ -f "$GAI_CONF_PATH" ]]; then
        if grep -qE '^[[:space:]]*#[[:space:]]*precedence ::ffff:0:0/96 100' "$GAI_CONF_PATH"; then
            sed -i 's/^[[:space:]]*#[[:space:]]*precedence ::ffff:0:0\/96 100/precedence ::ffff:0:0\/96 100/' "$GAI_CONF_PATH"
        elif ! grep -qE '^[[:space:]]*precedence ::ffff:0:0/96 100' "$GAI_CONF_PATH"; then
            echo 'precedence ::ffff:0:0/96 100' >> "$GAI_CONF_PATH"
        fi
    else
        mkdir -p "$(dirname "$GAI_CONF_PATH")"
        echo 'precedence ::ffff:0:0/96 100' > "$GAI_CONF_PATH"
    fi
    echo -e "${GREEN}成功: 已设置 IPv4 优先。${NC}"
}

firewall_chain_exists() {
    "$1" -nL "$2" >/dev/null 2>&1
}

ensure_owned_chain() {
    local tool="$1" chain="$2" marker="$3"
    if firewall_chain_exists "$tool" "$chain"; then
        if [[ ! -f "$marker" ]]; then
            echo -e "${RED}错误: 防火墙链 $chain 已存在但没有本脚本所有权标记，拒绝修改。${NC}"
            return 1
        fi
        "$tool" -F "$chain" || return 1
    else
        "$tool" -N "$chain" || return 1
    fi
}

remove_chain_jump() {
    local tool="$1" base_chain="$2" proto="$3" port="$4" chain="$5"
    while "$tool" -C "$base_chain" -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j "$chain" >/dev/null 2>&1; do
        "$tool" -D "$base_chain" -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j "$chain" || break
    done
}

remove_owned_chain() {
    local tool="$1" chain="$2"
    firewall_chain_exists "$tool" "$chain" || return 0
    "$tool" -F "$chain" >/dev/null 2>&1 || true
    "$tool" -X "$chain" >/dev/null 2>&1 || true
}

persist_firewall_rules() {
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

# 使用专属 ip6tables 链阻断 IPv6 DNS、HTTP、HTTPS 与 QUIC。
block_ipv6_ports() {
    local proto port
    echo -e "${BLUE}信息: 正在使用专属 ip6tables 链阻断 IPv6 绕过...${NC}"
    if ! command -v ip6tables >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 && apt-get install -y iptables >/dev/null 2>&1 || return 1
    fi
    command -v ip6tables >/dev/null 2>&1 || return 1
    if firewall_chain_exists ip6tables "$IPV6_BLOCK_CHAIN" && [[ ! -f "$IPV6_BLOCK_MARKER" ]]; then
        echo -e "${RED}错误: 防火墙链 $IPV6_BLOCK_CHAIN 已存在但不属于本脚本。${NC}"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    : > "$IPV6_BLOCK_MARKER"
    chmod 600 "$IPV6_BLOCK_MARKER"
    ensure_owned_chain ip6tables "$IPV6_BLOCK_CHAIN" "$IPV6_BLOCK_MARKER" || return 1
    ip6tables -A "$IPV6_BLOCK_CHAIN" -m comment --comment "$FIREWALL_COMMENT" -j REJECT || return 1
    for proto in tcp udp; do
        for port in 53 80 443; do
            [[ "$proto/$port" != "udp/80" ]] || continue
            if ! ip6tables -C OUTPUT -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j "$IPV6_BLOCK_CHAIN" >/dev/null 2>&1; then
                ip6tables -I OUTPUT -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j "$IPV6_BLOCK_CHAIN" || return 1
            fi
        done
    done
    persist_firewall_rules
    echo -e "${GREEN}成功: 已阻断 IPv6 TCP/53、80、443 及 UDP/53、443（含 QUIC）。${NC}"
}

unblock_ipv6_ports() {
    local proto port line_num
    command -v ip6tables >/dev/null 2>&1 || return 0
    if [[ -f "$IPV6_BLOCK_MARKER" ]]; then
        for proto in tcp udp; do
            for port in 53 80 443; do
                [[ "$proto/$port" != "udp/80" ]] || continue
                remove_chain_jump ip6tables OUTPUT "$proto" "$port" "$IPV6_BLOCK_CHAIN"
            done
        done
        remove_owned_chain ip6tables "$IPV6_BLOCK_CHAIN"
    fi
    # 清理旧版脚本按 comment 直接插入的规则，不依赖当前 DNS 地址。
    while line_num=$(ip6tables -L OUTPUT -n --line-numbers 2>/dev/null | awk '/dns-unlock-block-ipv6/{print $1; exit}') && [[ -n "$line_num" ]]; do
        ip6tables -D OUTPUT "$line_num" || break
    done
    rm -f "$IPV6_BLOCK_MARKER"
    persist_firewall_rules
}

enforce_dns_only_to_server() {
    local server_ip="$1" proto
    is_valid_ipv4 "$server_ip" || { echo -e "${RED}错误: DNS 服务器 IPv4 地址无效。${NC}"; return 1; }
    check_and_install_iptables || return 1
    command -v ip6tables >/dev/null 2>&1 || return 1
    if { firewall_chain_exists iptables "$DNS_V4_CHAIN" || firewall_chain_exists ip6tables "$DNS_V6_CHAIN"; } && [[ ! -f "$DNS_ENFORCE_MARKER" ]]; then
        echo -e "${RED}错误: DNS 专属防火墙链已存在但不属于本脚本。${NC}"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    : > "$DNS_ENFORCE_MARKER"
    chmod 600 "$DNS_ENFORCE_MARKER"
    ensure_owned_chain iptables "$DNS_V4_CHAIN" "$DNS_ENFORCE_MARKER" || return 1
    ensure_owned_chain ip6tables "$DNS_V6_CHAIN" "$DNS_ENFORCE_MARKER" || return 1
    iptables -A "$DNS_V4_CHAIN" -d "$server_ip" -m comment --comment "$FIREWALL_COMMENT" -j RETURN || return 1
    iptables -A "$DNS_V4_CHAIN" -m comment --comment "$FIREWALL_COMMENT" -j REJECT || return 1
    ip6tables -A "$DNS_V6_CHAIN" -m comment --comment "$FIREWALL_COMMENT" -j REJECT || return 1
    for proto in udp tcp; do
        if ! iptables -C OUTPUT -p "$proto" --dport 53 -m comment --comment "$FIREWALL_COMMENT" -j "$DNS_V4_CHAIN" >/dev/null 2>&1; then
            iptables -I OUTPUT -p "$proto" --dport 53 -m comment --comment "$FIREWALL_COMMENT" -j "$DNS_V4_CHAIN" || return 1
        fi
        if ! ip6tables -C OUTPUT -p "$proto" --dport 53 -m comment --comment "$FIREWALL_COMMENT" -j "$DNS_V6_CHAIN" >/dev/null 2>&1; then
            ip6tables -I OUTPUT -p "$proto" --dport 53 -m comment --comment "$FIREWALL_COMMENT" -j "$DNS_V6_CHAIN" || return 1
        fi
    done
    printf '%s\n' "$server_ip" > "$STATE_DIR/client-server-ip"
    chmod 600 "$STATE_DIR/client-server-ip"
    persist_firewall_rules
    echo -e "${GREEN}成功: TCP/UDP DNS 仅允许发往 ${server_ip}，IPv6 DNS 已阻断。${NC}"
}

revert_dns_enforcement_rules() {
    local proto line_num
    if command -v iptables >/dev/null 2>&1; then
        if [[ -f "$DNS_ENFORCE_MARKER" ]]; then
            for proto in udp tcp; do remove_chain_jump iptables OUTPUT "$proto" 53 "$DNS_V4_CHAIN"; done
            remove_owned_chain iptables "$DNS_V4_CHAIN"
        fi
        while line_num=$(iptables -L OUTPUT -n --line-numbers 2>/dev/null | awk '/dns-unlock-enforce-dns/{print $1; exit}') && [[ -n "$line_num" ]]; do
            iptables -D OUTPUT "$line_num" || break
        done
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if [[ -f "$DNS_ENFORCE_MARKER" ]]; then
            for proto in udp tcp; do remove_chain_jump ip6tables OUTPUT "$proto" 53 "$DNS_V6_CHAIN"; done
            remove_owned_chain ip6tables "$DNS_V6_CHAIN"
        fi
    fi
    rm -f "$STATE_DIR/client-server-ip" "$DNS_ENFORCE_MARKER"
    persist_firewall_rules
}


# ======================= 核心功能函数 =======================

dns_unlock_menu() {
    while true; do
        clear
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${YELLOW}           DNS 解锁服务管理           ${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo " --- 服务端管理 ---"
        echo "  1. 安装/更新 DNS 解锁服务"
        echo "  2. 卸载 DNS 解锁服务"
        echo "  3. 管理 IP 白名单 (防火墙)"
        echo
        echo " --- 客户端管理 ---"
        echo "  4. 设置本机为 DNS 客户端"
        echo "  5. 还原客户端 DNS 设置"
        echo "  6. 管理IPv6端口阻断（防绕过）"
        echo " --------------------------------------------"
        echo "  0. 退出脚本"
        echo -e "${BLUE}=============================================${NC}"
        read -p "请输入选项 [0-6]: " choice

        case $choice in
            1) install_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            2) uninstall_dns_unlock_server; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            3) manage_iptables_rules ;;
            4) setup_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            5) uninstall_dns_client; echo; read -n 1 -s -r -p "按任意键返回..." ;;
            6) manage_ipv6_blocking ;;  
            0) break ;;
            *) echo -e "${RED}无效选项，请重新输入!${NC}"; sleep 2 ;;
        esac
    done
}

install_dns_unlock_server() {
    local stage_dir result=0 interrupted=false
    install_new_gost=false
    selected_gost_binary=""
    SERVER_RESOLVED_CHANGED=false
    STOP_SNIPROXY=false
    clear
    echo -e "${YELLOW}--- DNS解锁服务 安装/更新 ---${NC}"
    check_supported_system || return 1
    create_system_snapshot || { echo -e "${RED}错误: 无法创建安装前快照，已停止。${NC}"; return 1; }
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/dns-unlock-install.XXXXXXXX") || return 1

    trap 'interrupted=true' INT TERM
    perform_dns_unlock_server_install "$stage_dir" || result=$?
    [[ "$interrupted" != true ]] || result=130
    if ((result == 0)) && ! commit_original_snapshot "$SERVER_ORIGINAL_SNAPSHOT" "$SERVER_MANAGED_MARKER"; then
        result=1
    fi
    if ((result == 0)) && [[ "$install_new_gost" == true ]]; then
        : > "$SERVER_GOST_MANAGED_MARKER"
        chmod 600 "$SERVER_GOST_MANAGED_MARKER"
    fi
    if ((result == 0)) && [[ "$SERVER_RESOLVED_CHANGED" == true ]]; then
        : > "$SERVER_RESOLVED_MANAGED_MARKER"
        chmod 600 "$SERVER_RESOLVED_MANAGED_MARKER"
    fi
    if ((result == 0)) && [[ "$STOP_SNIPROXY" == true ]]; then
        : > "$SERVER_SNIPROXY_MANAGED_MARKER"
        chmod 600 "$SERVER_SNIPROXY_MANAGED_MARKER"
    fi
    if ((result != 0)); then
        restore_system_snapshot "$transaction_backup" true "$install_new_gost" "$SERVER_RESOLVED_CHANGED" "$STOP_SNIPROXY"
        echo -e "${YELLOW}已回滚到安装前状态，快照保留在: $transaction_backup${NC}"
    fi
    rm -rf -- "$stage_dir"
    trap - INT TERM
    return "$result"
}

write_gost_dns_unlock_config() {
    local output_path="$1" http_addr="${2:-:80}" https_addr="${3:-:443}"
    cat > "$output_path" <<EOF
# Managed by AI-Scripts dns_unlock.sh
services:
- name: "dns-unlock-http-80"
  addr: "${http_addr}"
  resolver: "dns-unlock-upstream"
  listener:
    type: "tcp"
  handler:
    type: "sni"
- name: "dns-unlock-https-443"
  addr: "${https_addr}"
  resolver: "dns-unlock-upstream"
  listener:
    type: "tcp"
  handler:
    type: "sni"
resolvers:
- name: "dns-unlock-upstream"
  nameservers:
  - addr: "https://1.1.1.1/dns-query"
    hostname: "cloudflare-dns.com"
    prefer: "ipv4"
    timeout: 5s
  - addr: "https://1.0.0.1/dns-query"
    hostname: "cloudflare-dns.com"
    prefer: "ipv4"
    timeout: 5s
EOF
}

validate_running_dns_unlock() {
    local public_ip="$1" dns_answers

    dns_answers=$(dig +time=3 +tries=1 +short @127.0.0.1 netflix.com A 2>/dev/null) || {
        echo -e "${RED}错误: 无法通过本机 dnsmasq 查询解锁域名。${NC}"
        return 1
    }
    if ! grep -Fxq "$public_ip" <<< "$dns_answers"; then
        echo -e "${RED}错误: dnsmasq 未将 netflix.com 解析到本机公网 IPv4 (${public_ip})。${NC}"
        return 1
    fi

    if ! curl --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 20 \
        -H 'Host: example.com' http://127.0.0.1/ -o /dev/null; then
        echo -e "${RED}错误: GOST HTTP Host 转发自检失败。${NC}"
        return 1
    fi
    if ! curl --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 20 \
        --resolve 'www.example.com:443:127.0.0.1' https://www.example.com/ -o /dev/null; then
        echo -e "${RED}错误: GOST HTTPS SNI 转发自检失败。${NC}"
        return 1
    fi
}

perform_dns_unlock_server_install() {
    local stage_dir="$1" PUBLIC_IP enable_filter_aaaa FILTER_AAAA_LINE=""
    local gost_config_temp service_temp dnsmasq_temp dnsmasq_main_temp final_gost_binary
    install_dependencies || { echo -e "${RED}错误: 依赖安装失败。${NC}"; return 1; }
    check_port_53 || return 1
    check_ports_80_443 || return 1

    systemctl stop "$DNS_GOST_SERVICE_NAME" >/dev/null 2>&1 || true
    if [[ "${STOP_SNIPROXY:-false}" == true ]]; then
        systemctl stop sniproxy >/dev/null 2>&1 || return 1
    fi

    select_or_stage_gost "$stage_dir" || { echo -e "${RED}错误: 没有可用的兼容 GOST v3。${NC}"; return 1; }
    if [[ "$install_new_gost" == true ]]; then
        final_gost_binary="$GOST_INSTALL_PATH"
    else
        final_gost_binary="$selected_gost_binary"
    fi

    PUBLIC_IP=$(curl --fail --silent --show-error --ipv4 --connect-timeout 10 https://api.ipify.org 2>/dev/null ||
        curl --fail --silent --show-error --ipv4 --connect-timeout 10 https://ifconfig.me/ip 2>/dev/null) || true
    if ! is_valid_ipv4 "$PUBLIC_IP"; then
        echo -e "${RED}错误: 无法取得有效的公网 IPv4 地址，收到: ${PUBLIC_IP:-空}${NC}"
        return 1
    fi

    gost_config_temp="$stage_dir/dns-unlock-config.yml"
    service_temp="$stage_dir/$DNS_GOST_SERVICE_NAME"
    dnsmasq_temp="$stage_dir/custom_unlock.conf"
    dnsmasq_main_temp="$stage_dir/dnsmasq.conf"

    echo -e "${BLUE}信息: 正在为DNS解锁服务创建 Gost 配置文件 (YAML)...${NC}"

    # GOST v3 的 SNI handler 同时根据 HTTP Host 和 TLS SNI 转发流量。
    # 服务显式绑定独立 DoH 解析器，避免本机也作为 DNS 客户端时解析回本机而形成循环。
    write_gost_dns_unlock_config "$gost_config_temp" || return 1

    echo -e "${BLUE}信息: 正在创建Systemd服务 (${DNS_GOST_SERVICE_NAME})...${NC}"
    # 使用检测到的或新安装的gost路径，确保兼容性
    cat > "${service_temp}" <<EOT
# Managed by AI-Scripts dns_unlock.sh
[Unit]
Description=GOST DNS Unlock Service
After=network.target

[Service]
Type=simple
ExecStart=${final_gost_binary} -C ${DNS_GOST_CONFIG_PATH}
Restart=always
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOT

    echo -e "${BLUE}信息: 正在暂存 Dnsmasq 子配置文件...${NC}"
    # 可选：启用 AAAA 过滤，防止 IPv6 泄漏（默认启用）
    read -r -p "是否在服务端启用 AAAA 过滤（filter-AAAA）以防 IPv6 泄漏？(Y/n): " enable_filter_aaaa
    if [[ "$enable_filter_aaaa" =~ ^[yY]$ ]] || [[ -z "$enable_filter_aaaa" ]]; then FILTER_AAAA_LINE="filter-AAAA"; fi
    
    cat > "$dnsmasq_temp" <<EOF
# --- DNSMASQ CONFIG MODULE MANAGED BY AI-Scripts dns_unlock.sh ---
# General Settings
domain-needed
bogus-priv
no-resolv
no-poll
all-servers
$FILTER_AAAA_LINE
cache-size=2048
local-ttl=60
# Listen on all network interfaces to accept queries from non-local IPs
interface=*
# Upstream DNS Servers
server=8.8.8.8
server=1.1.1.1
# --- Unlock Rules (All resolve to this server's IP: ${PUBLIC_IP}) ---
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
address=/reddit.com/${PUBLIC_IP}
address=/redd.it/${PUBLIC_IP}
address=/redditmedia.com/${PUBLIC_IP}
address=/redditstatic.com/${PUBLIC_IP}
address=/auth0.com/${PUBLIC_IP}
address=/sora.com/${PUBLIC_IP}
address=/gemini.google.com/${PUBLIC_IP}
address=/proactivebackend-pa.googleapis.com/${PUBLIC_IP}
address=/aistudio.google.com/${PUBLIC_IP}
address=/alkalimakersuite-pa.clients6.google.com/${PUBLIC_IP}
address=/generativelanguage.googleapis.com/${PUBLIC_IP}
address=/copilot.microsoft.com/${PUBLIC_IP}
address=/oaiusercontent.com/${PUBLIC_IP}
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
address=/googlevideo.com/${PUBLIC_IP}
address=/ggpht.com/${PUBLIC_IP}
address=/ytimg.com/${PUBLIC_IP}
EOF

    if [[ -f "$DNSMASQ_MAIN_CONFIG" ]]; then
        cp -a "$DNSMASQ_MAIN_CONFIG" "$dnsmasq_main_temp" || return 1
    else
        : > "$dnsmasq_main_temp"
    fi
    if ! grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq[.]d' "$dnsmasq_main_temp" &&
       ! grep -Fq "conf-file=$DNSMASQ_CONFIG_FILE" "$dnsmasq_main_temp"; then
        printf '\n# Managed by AI-Scripts dns_unlock.sh\nconf-file=%s\n' "$DNSMASQ_CONFIG_FILE" >> "$dnsmasq_main_temp"
    fi

    echo -e "${BLUE}信息: 正在校验暂存的 GOST 与 Dnsmasq 配置...${NC}"
    "$selected_gost_binary" -C "$gost_config_temp" -O yaml >/dev/null 2>&1 || {
        echo -e "${RED}错误: GOST 配置校验失败。${NC}"; return 1;
    }
    dnsmasq --test --conf-file="$dnsmasq_temp" >/dev/null 2>&1 || {
        echo -e "${RED}错误: Dnsmasq 子配置校验失败。${NC}"; return 1;
    }

    if [[ "$install_new_gost" == true ]]; then
        mkdir -p "$(dirname "$GOST_INSTALL_PATH")"
        install -m 755 "$selected_gost_binary" "$GOST_INSTALL_PATH" || return 1
        selected_gost_binary="$GOST_INSTALL_PATH"
    fi
    mkdir -p "$(dirname "$DNS_GOST_CONFIG_PATH")" "$(dirname "$DNS_GOST_SERVICE_PATH")" "$(dirname "$DNSMASQ_CONFIG_FILE")"
    install -m 600 "$gost_config_temp" "$DNS_GOST_CONFIG_PATH" || return 1
    install -m 644 "$service_temp" "$DNS_GOST_SERVICE_PATH" || return 1
    install -m 600 "$dnsmasq_temp" "$DNSMASQ_CONFIG_FILE" || return 1
    install -m 644 "$dnsmasq_main_temp" "$DNSMASQ_MAIN_CONFIG" || return 1

    dnsmasq --test >/dev/null 2>&1 || { echo -e "${RED}错误: Dnsmasq 完整配置校验失败。${NC}"; return 1; }
    systemctl daemon-reload || return 1
    systemctl enable "$DNS_GOST_SERVICE_NAME" dnsmasq >/dev/null 2>&1 || return 1
    systemctl restart "$DNS_GOST_SERVICE_NAME" || return 1
    wait_for_service_active "$DNS_GOST_SERVICE_NAME" || { echo -e "${RED}错误: GOST DNS 服务未能稳定运行。${NC}"; return 1; }
    systemctl restart dnsmasq || return 1
    wait_for_service_active dnsmasq || { echo -e "${RED}错误: Dnsmasq 未能稳定运行。${NC}"; return 1; }
    echo -e "${BLUE}信息: 正在执行 DNS、HTTP 与 HTTPS 端到端自检...${NC}"
    if ! validate_running_dns_unlock "$PUBLIC_IP"; then
        journalctl -u "$DNS_GOST_SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
        journalctl -u dnsmasq -n 20 --no-pager 2>/dev/null || true
        return 1
    fi

    echo -e "${GREEN}🎉 DNS 解锁服务安装成功；安装前快照: $transaction_backup${NC}"
    echo -e "${YELLOW}提示: 服务端安装不会自动修改本机 DNS。若要在本机运行流媒体检测，请返回菜单选择 [设置本机为 DNS 客户端]，服务器 IPv4 填写 127.0.0.1（推荐）或 ${PUBLIC_IP}。${NC}"
}


uninstall_dns_unlock_server() {
    clear
    echo -e "${YELLOW}--- DNS解锁服务 卸载 ---${NC}"
    if [[ -f "$SERVER_MANAGED_MARKER" && -d "$SERVER_ORIGINAL_SNAPSHOT" ]]; then
        local restore_gost_binary=false restore_resolved=false restore_sniproxy=false archive_container archived_original
        [[ ! -f "$SERVER_GOST_MANAGED_MARKER" ]] || restore_gost_binary=true
        [[ ! -f "$SERVER_RESOLVED_MANAGED_MARKER" ]] || restore_resolved=true
        [[ ! -f "$SERVER_SNIPROXY_MANAGED_MARKER" ]] || restore_sniproxy=true
        if restore_system_snapshot "$SERVER_ORIGINAL_SNAPSHOT" true "$restore_gost_binary" "$restore_resolved" "$restore_sniproxy"; then
            mkdir -p "$BACKUP_ROOT"
            archive_container=$(mktemp -d "$BACKUP_ROOT/uninstalled-server.$(date +%Y%m%d_%H%M%S).XXXXXXXX") || return 1
            archived_original="$archive_container/original"
            mv "$SERVER_ORIGINAL_SNAPSHOT" "$archived_original" || return 1
            rm -f "$SERVER_MANAGED_MARKER" "$SERVER_GOST_MANAGED_MARKER" "$SERVER_RESOLVED_MANAGED_MARKER" "$SERVER_SNIPROXY_MANAGED_MARKER"
            echo -e "${GREEN}成功: 已恢复安装前的 GOST、dnsmasq、sniproxy、systemd-resolved、配置及服务状态。${NC}"
            echo -e "${BLUE}原始状态快照保留在: $archived_original${NC}"
        else
            echo -e "${RED}错误: 恢复安装前状态失败，所有权记录已保留，请勿手动删除 $STATE_DIR。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}警告: 未找到新版所有权快照，只清理能明确识别为本脚本创建的文件；不会卸载 dnsmasq 或删除 GOST。${NC}"
        if [[ -f "$DNS_GOST_SERVICE_PATH" ]] && grep -Fq '# Managed by AI-Scripts dns_unlock.sh' "$DNS_GOST_SERVICE_PATH"; then
            systemctl disable --now "$DNS_GOST_SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "$DNS_GOST_SERVICE_PATH"
        fi
        [[ ! -f "$DNS_GOST_CONFIG_PATH" ]] || ! grep -Fq '# Managed by AI-Scripts dns_unlock.sh' "$DNS_GOST_CONFIG_PATH" || rm -f "$DNS_GOST_CONFIG_PATH"
        [[ ! -f "$DNSMASQ_CONFIG_FILE" ]] || ! grep -Fq 'DNSMASQ CONFIG MODULE MANAGED BY AI-Scripts dns_unlock.sh' "$DNSMASQ_CONFIG_FILE" || rm -f "$DNSMASQ_CONFIG_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}✅ DNS 解锁服务卸载完成。${NC}"
}

setup_dns_client() {
    local server_ip result=0 previous_dns_ip="" previous_ipv6_block=false interrupted=false
    clear
    echo -e "${YELLOW}--- 设置 DNS 客户端 ---${NC}"
    read -r -p "请输入您的 DNS 解锁服务器的 IPv4 地址: " server_ip
    if ! is_valid_ipv4 "$server_ip"; then echo -e "${RED}错误: IPv4 地址无效。${NC}"; return 1; fi
    check_supported_system || return 1
    create_client_snapshot || { echo -e "${RED}错误: 无法创建客户端设置前快照。${NC}"; return 1; }
    [[ ! -f "$STATE_DIR/client-server-ip" ]] || previous_dns_ip=$(<"$STATE_DIR/client-server-ip")
    [[ ! -f "$IPV6_BLOCK_MARKER" ]] || previous_ipv6_block=true

    trap 'interrupted=true' INT TERM
    perform_setup_dns_client "$server_ip" || result=$?
    [[ "$interrupted" != true ]] || result=130
    if ((result == 0)) && ! commit_original_snapshot "$CLIENT_ORIGINAL_SNAPSHOT" "$CLIENT_MANAGED_MARKER"; then
        result=1
    fi
    if ((result != 0)); then
        revert_dns_enforcement_rules
        unblock_ipv6_ports
        restore_client_snapshot "$transaction_backup"
        if is_valid_ipv4 "$previous_dns_ip"; then enforce_dns_only_to_server "$previous_dns_ip" || true; fi
        if [[ "$previous_ipv6_block" == true ]]; then block_ipv6_ports || true; fi
        echo -e "${YELLOW}客户端设置失败，已恢复到操作前状态；快照: $transaction_backup${NC}"
    fi
    trap - INT TERM
    return "$result"
}

perform_setup_dns_client() {
    local server_ip="$1" ipv6_choice enforce_dns

    # 1) （推荐）禁用 systemd-resolved，避免 stub 劫持；解除 resolv.conf 软链
    disable_systemd_resolved_if_running || return 1

    # 2) 写入并锁定 resolv.conf 指向 A
    set_resolv_conf "$server_ip" || return 1

    # 3) （推荐）设置系统 IPv4 优先，避免 AAAA 泄漏
    echo -e "${YELLOW}重要: 如果您的系统支持IPv6，必须采取措施防止绕过解锁！${NC}"
    echo -e "${BLUE}可选方案：${NC}"
    echo "  1. 设置IPv4优先（推荐）"
    echo "  2. 使用防火墙阻断IPv6关键端口（更彻底）"
    echo "  3. 两者都启用（最安全）"
    echo "  4. 都不启用（不推荐）"
    read -r -p "请选择 [1-4，默认3]: " ipv6_choice
    
    case "${ipv6_choice:-3}" in
        1)
            ensure_ipv4_preference || return 1
            ;;
        2)
            block_ipv6_ports || return 1
            ;;
        3)
            ensure_ipv4_preference || return 1
            block_ipv6_ports || return 1
            ;;
        4)
            echo -e "${RED}警告: 未采取任何IPv6防护措施！${NC}"
            echo -e "${RED}如果系统支持IPv6，DNS解锁很可能会失效！${NC}"
            ;;
        *)
            echo -e "${YELLOW}无效选择，默认执行方案3（最安全）${NC}"
            ensure_ipv4_preference || return 1
            block_ipv6_ports || return 1
            ;;
    esac

    # 4) （可选）添加防火墙优先规则，优化 DNS 路由
    read -r -p "是否添加防火墙规则，强制 TCP/UDP DNS 只能发往 ${server_ip} ? (y/N): " enforce_dns
    if [[ "$enforce_dns" =~ ^[yY]$ ]]; then
        enforce_dns_only_to_server "$server_ip" || return 1
    else
        revert_dns_enforcement_rules
        echo -e "${YELLOW}提示: 未启用 DNS 强制规则，仅依靠 resolv.conf。${NC}"
    fi

    echo -e "${GREEN}成功: 客户端 DNS 已完成设置。${NC}"
    echo -e "${BLUE}建议测试:${NC} dig +short chatgpt.com ; curl --socks5 与 --socks5-hostname 对比访问。"
}

uninstall_dns_client() {
    local restore_ipv6_block=false
    clear
    echo -e "${YELLOW}--- 卸载/还原 DNS 客户端设置 ---${NC}"
    if [[ -f "$CLIENT_MANAGED_MARKER" && -f "$CLIENT_ORIGINAL_SNAPSHOT/ipv6-block.preexisting" ]]; then
        restore_ipv6_block=true
    fi
    unblock_ipv6_ports
    revert_dns_enforcement_rules
    chattr -i "$RESOLV_CONF_PATH" 2>/dev/null || true
    if [[ -f "$CLIENT_MANAGED_MARKER" && -d "$CLIENT_ORIGINAL_SNAPSHOT" ]]; then
        if restore_client_snapshot "$CLIENT_ORIGINAL_SNAPSHOT"; then
            local archive_container archived_original
            mkdir -p "$BACKUP_ROOT"
            archive_container=$(mktemp -d "$BACKUP_ROOT/uninstalled-client.$(date +%Y%m%d_%H%M%S).XXXXXXXX") || return 1
            archived_original="$archive_container/original"
            mv "$CLIENT_ORIGINAL_SNAPSHOT" "$archived_original" || return 1
            rm -f "$CLIENT_MANAGED_MARKER"
            if [[ "$restore_ipv6_block" == true ]]; then block_ipv6_ports || true; fi
            echo -e "${GREEN}成功: 已恢复设置客户端前的 resolv.conf、gai.conf 和 systemd-resolved 状态。${NC}"
            echo -e "${BLUE}原始状态快照保留在: $archived_original${NC}"
        else
            echo -e "${RED}错误: 客户端原始状态恢复失败，所有权记录已保留。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}警告: 未找到客户端所有权快照；仅移除了本脚本专属防火墙链，没有猜测或覆盖当前 DNS 配置。${NC}"
    fi
}

manage_ipv6_blocking() {
    while true; do
        clear
        echo -e "${YELLOW}══════ IPv6 端口阻断管理 ══════${NC}"
        echo -e "${BLUE}防止应用通过IPv6绕过DNS解锁${NC}"
        echo ""
        
        # 显示当前IPv6阻断状态
        if command -v ip6tables &>/dev/null && firewall_chain_exists ip6tables "$IPV6_BLOCK_CHAIN"; then
            echo -e "${GREEN}状态: IPv6端口阻断已启用${NC}"
            echo -e "${BLUE}当前阻断的端口:${NC}"
            ip6tables -L OUTPUT -n --line-numbers | grep "$IPV6_BLOCK_CHAIN" | while read -r line; do
                echo "  $line"
            done
        else
            echo -e "${YELLOW}状态: IPv6端口阻断未启用${NC}"
        fi
        
        echo -e "${YELLOW}────────────────────────────────${NC}"
        echo "1. 启用IPv6端口阻断 (53/80/443)"
        echo "2. 禁用IPv6端口阻断"
        echo "3. 查看当前IPv6连接状态"
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}═══════════════════════════════${NC}"
        read -p "请输入选项: " ipv6_choice
        
        case $ipv6_choice in
            1)
                block_ipv6_ports || unblock_ipv6_ports
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            2)
                unblock_ipv6_ports
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            3)
                echo -e "${BLUE}当前IPv6连接状态:${NC}"
                if command -v ss &>/dev/null; then
                    echo -e "${YELLOW}IPv6 TCP连接:${NC}"
                    ss -6tn state established 2>/dev/null | head -20
                    echo -e "${YELLOW}IPv6 监听端口:${NC}"
                    ss -6tln 2>/dev/null | head -20
                else
                    echo -e "${YELLOW}IPv6网络配置:${NC}"
                    ip -6 addr show 2>/dev/null | grep -v "^\s*valid_lft"
                fi
                echo
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选项!${NC}"
                sleep 1
                ;;
        esac
    done
}

manage_iptables_rules() {
    # 首先确保iptables已安装
    if ! check_and_install_iptables; then
        echo -e "${RED}错误: 无法继续，iptables 是必需的。${NC}"
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    
    if ! dpkg -l | grep -q 'iptables-persistent'; then
        echo -e "${YELLOW}警告: 'iptables-persistent' 未安装，规则可能无法自动持久化。${NC}"
        read -p "是否现在尝试安装? (y/N): " install_confirm
        if [[ "$install_confirm" =~ ^[yY]$ ]]; then apt-get update && apt-get install -y iptables-persistent; fi
    fi
    while true; do
        clear
        echo -e "${YELLOW}══════ IP 白名单管理 (端口 53, 80, 443) ══════${NC}"
        echo "管理 DNS(53) 和 Gost(80, 443) 的访问权限。"
        echo -e "${BLUE}当前生效的相关规则:${NC}"
        iptables -L INPUT -v -n --line-numbers | grep -E 'dpt:53|dpt:80|dpt:443' || echo -e "  (无相关规则)"
        echo -e "${YELLOW}────────────────────────────────────────────${NC}"
        echo "1. 添加白名单IP (允许访问)"
        echo "2. 删除白名单IP (根据行号)"
        echo "3. 应用 '默认拒绝' 规则 (推荐)"
        echo "0. 返回上级菜单"
        echo -e "${YELLOW}════════════════════════════════════════════${NC}"
        read -p "请输入选项: " rule_choice
        case $rule_choice in
        1)
            read -p "请输入要加入白名单的IP (单个或多个, 用空格隔开): " ips
            if [[ -z "$ips" ]]; then continue; fi

            local added_count=0
            local invalid_input=false
            for ip in $ips; do
                # Simple validation for IP format
                if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$ip' 不是一个有效的 IP 地址格式。${NC}"
                    invalid_input=true
                    continue
                fi

                for port in 53 80 443; do
                    iptables -I INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
                    if [[ "$port" == "53" ]]; then iptables -I INPUT -s "$ip" -p udp --dport "$port" -j ACCEPT; fi
                done
                echo -e "${GREEN}IP $ip 已添加至端口 53, 80, 443 白名单。${NC}"
                ((added_count++))
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过。${NC}"
            fi

            if (( added_count > 0 )); then
                echo -e "${GREEN}共添加了 ${added_count} 个IP至白名单。${NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            else
                echo -e "${YELLOW}未执行任何有效的添加操作。${NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        2)
            read -p "请输入要删除的规则行号 (单个或多个, 用空格隔开): " line_nums
            if [[ -z "$line_nums" ]]; then continue; fi

            # 为了防止删除时行号变化导致错删，必须从大到小删除
            readarray -t sorted_nums < <(echo "$line_nums" | tr ' ' '\n' | sort -nr)

            local deleted_count=0
            local invalid_input=false
            for num in "${sorted_nums[@]}"; do
                # 验证每个输入是否为纯数字
                if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}输入错误: '$num' 不是有效的行号。${NC}"
                    invalid_input=true
                    continue
                fi
                # 执行删除
                if iptables -D INPUT "$num"; then
                    echo -e "${GREEN}规则 ${num} 已删除。${NC}"
                    ((deleted_count++))
                else
                    echo -e "${RED}删除规则 ${num} 失败 (可能行号不存在)。${NC}"
                fi
            done

            if [[ "$invalid_input" == true ]]; then
                 echo -e "${YELLOW}部分输入无效，操作已跳过。${NC}"
            fi

            if (( deleted_count > 0 )); then
                echo -e "${GREEN}共删除了 ${deleted_count} 条规则。${NC}"
                netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            else
                echo -e "${YELLOW}未执行任何有效删除操作。${NC}"
            fi
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        3)
            echo -e "${BLUE}信息: 这将确保所有不在白名单的IP无法访问相关端口。${NC}"
            for port in 53 80 443; do
                if ! iptables -C INPUT -p tcp --dport "$port" -j DROP &>/dev/null; then iptables -A INPUT -p tcp --dport "$port" -j DROP; fi
                if [[ "$port" == "53" ]]; then if ! iptables -C INPUT -p udp --dport "$port" -j DROP &>/dev/null; then iptables -A INPUT -p udp --dport "$port" -j DROP; fi; fi
            done
            echo -e "${GREEN}'默认拒绝' 规则已应用/确认存在。${NC}"
            netfilter-persistent save && echo -e "${GREEN}防火墙规则已保存。${NC}" || echo -e "${RED}防火墙规则保存失败。${NC}"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
        0) break ;;
        *) echo -e "${RED}无效选项!${NC}"; sleep 1;;
        esac
    done
}


# ======================= 主逻辑入口 =======================

# --- 运行主逻辑 ---
if [[ "${DNS_UNLOCK_SOURCE_ONLY:-0}" != "1" ]]; then
    check_root || exit 1
    dns_unlock_menu
fi
