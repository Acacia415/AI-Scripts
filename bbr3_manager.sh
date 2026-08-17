#!/usr/bin/env bash

# AI-Scripts - XanMod BBRv3 管理器
# x86_64 使用 XanMod 仓库；ARM64 保留原始 jhb.ovh BBRv3 管理脚本。

set -uo pipefail
umask 022

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.0"

BACKUP_ROOT="${BBR3_BACKUP_ROOT:-/var/backups/ai-scripts/bbr3}"
STATE_DIR="${BBR3_STATE_DIR:-/var/lib/ai-scripts-bbr3}"
SYSCTL_FILE="${BBR3_SYSCTL_FILE:-/etc/sysctl.d/99-zz-ai-scripts-bbr3.conf}"
REPO_FILE="${BBR3_REPO_FILE:-/etc/apt/sources.list.d/ai-scripts-xanmod.list}"
KEYRING_FILE="${BBR3_KEYRING_FILE:-/etc/apt/keyrings/ai-scripts-xanmod-archive-keyring.gpg}"
OS_RELEASE_FILE="${BBR3_OS_RELEASE_FILE:-/etc/os-release}"
CPUINFO_FILE="${BBR3_CPUINFO_FILE:-/proc/cpuinfo}"
BOOT_DIR="${BBR3_BOOT_DIR:-/boot}"
MODULES_DIR="${BBR3_MODULES_DIR:-/lib/modules}"
ARM_SYSCTL_FILE="${BBR3_ARM_SYSCTL_FILE:-/etc/sysctl.d/99-custom.conf}"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_KEY_FALLBACK_URL="https://raw.githubusercontent.com/kejilion/sh/main/archive.key"

MANAGED_SYSCTL_MARKER="$STATE_DIR/managed-sysctl"
MANAGED_REPO_MARKER="$STATE_DIR/managed-repo"
MANAGED_KEY_MARKER="$STATE_DIR/managed-key"
ORIGINAL_DIR="$STATE_DIR/original"
ORIGINAL_RUNTIME_FILE="$ORIGINAL_DIR/runtime"

ASSUME_YES=false
JSON_OUTPUT=false
CURRENT_BACKUP_ID=""
LOCK_HELD=false
OS_ID=""
OS_ID_LIKE=""
OS_CODENAME=""
SUPPORT_REASON=""
HOST_MODE=""

if [[ -t 1 ]]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

info() { printf '%b[信息]%b %s\n' "$CYAN" "$NC" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%b[错误]%b %s\n' "$RED" "$NC" "$*" >&2; }

secure_mkdir() {
    local directory="$1"
    local kernel_name
    mkdir -p -- "$directory" || return 1
    if chmod 700 -- "$directory" 2>/dev/null; then
        return 0
    fi
    kernel_name=$(uname -s 2>/dev/null || true)
    case "$kernel_name" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
用法：
  $SCRIPT_NAME status [--json]
  sudo $SCRIPT_NAME install [--yes]
  sudo $SCRIPT_NAME update [--yes]
  sudo $SCRIPT_NAME uninstall [--yes]
  sudo $SCRIPT_NAME restore [latest|备份编号] [--yes]
  $SCRIPT_NAME menu

命令：
  status      查看 XanMod、BBR、fq、已安装内核及重启状态
  install     x86_64 安装 XanMod；ARM64 进入原始 BBRv3 菜单
  update      x86_64 更新 XanMod；ARM64 进入原始 BBRv3 菜单
  uninstall   x86_64 安全卸载；ARM64 进入原始 BBRv3 菜单
  restore     恢复脚本管理的 sysctl、软件源和密钥文件
  menu        打开交互菜单（默认）

选项：
  --yes       跳过普通确认；不会绕过备用内核等安全检查
  --json      status 使用 JSON 输出
  -h, --help  显示帮助

说明：
  - 始终安装仓库提供的最新版本，不锁定内核版本。
  - 不自动重启，也不自动运行 apt autoremove。
  - restore 不会自动恢复已被 APT 删除的内核包。
EOF
}

require_root() {
    if (( EUID != 0 )); then
        error "此操作需要 root 权限，请使用 sudo 重新运行。"
        return 1
    fi
}

confirm() {
    local prompt="$1"
    local answer=""

    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error "当前没有交互终端；确认无误后请添加 --yes。"
        return 1
    fi
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

load_os_release() {
    OS_ID=""
    OS_ID_LIKE=""
    OS_CODENAME=""

    if [[ -r "$OS_RELEASE_FILE" ]]; then
        OS_ID=$(bash -c '. "$1"; printf "%s" "${ID:-}"' _ "$OS_RELEASE_FILE" 2>/dev/null || true)
        OS_ID_LIKE=$(bash -c '. "$1"; printf "%s" "${ID_LIKE:-}"' _ "$OS_RELEASE_FILE" 2>/dev/null || true)
        OS_CODENAME=$(bash -c '. "$1"; printf "%s" "${VERSION_CODENAME:-}"' _ "$OS_RELEASE_FILE" 2>/dev/null || true)
    fi
    if [[ -z "$OS_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
        OS_CODENAME=$(lsb_release -sc 2>/dev/null || true)
    fi

    OS_ID=${OS_ID,,}
    OS_ID_LIKE=${OS_ID_LIKE,,}
    OS_CODENAME=${OS_CODENAME,,}
}

host_supported() {
    local architecture
    SUPPORT_REASON=""
    HOST_MODE=""
    architecture=$(uname -m 2>/dev/null || true)
    load_os_release

    case "$architecture" in
        x86_64|amd64)
            HOST_MODE="xanmod"
            ;;
        aarch64|arm64)
            HOST_MODE="arm64-external"
            if ! command -v curl >/dev/null 2>&1; then
                SUPPORT_REASON="ARM64 外部管理脚本需要 curl"
                return 1
            fi
            return 0
            ;;
        *)
            SUPPORT_REASON="不支持的 CPU 架构：${architecture:-unknown}"
            return 1
            ;;
    esac

    if ! command -v apt-get >/dev/null 2>&1 ||
       ! command -v apt-cache >/dev/null 2>&1 ||
       ! command -v dpkg-query >/dev/null 2>&1; then
        SUPPORT_REASON="缺少 apt-get、apt-cache 或 dpkg-query"
        return 1
    fi

    if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" &&
          " $OS_ID_LIKE " != *" debian "* && " $OS_ID_LIKE " != *" ubuntu "* ]]; then
        SUPPORT_REASON="仅支持 Debian/Ubuntu 及其 Debian 系衍生发行版"
        return 1
    fi

    if [[ -z "$OS_CODENAME" || ! "$OS_CODENAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
        SUPPORT_REASON="无法识别有效的发行版代号"
        return 1
    fi
    return 0
}

acquire_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        warn "系统缺少 flock，无法阻止多个实例同时修改配置。"
        return 0
    fi
    mkdir -p /run/lock || return 1
    exec 9>/run/lock/ai-scripts-bbr3.lock
    if ! flock -n 9; then
        error "另一个 BBR3 管理任务正在运行。"
        return 1
    fi
    LOCK_HELD=true
}

release_lock() {
    if [[ "$LOCK_HELD" == true ]]; then
        flock -u 9 >/dev/null 2>&1 || true
        exec 9>&-
        LOCK_HELD=false
    fi
}

safe_token() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9+._:,-'
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

current_congestion_control() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
}

current_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || true
}

available_congestion_controls() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

list_installed_xanmod_packages() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 'linux-*xanmod*' 2>/dev/null |
        awk '$1 == "ii" {print $2}' |
        sort -u || true
}

list_installed_xanmod_images() {
    list_installed_xanmod_packages | grep -E '^linux-image-.*xanmod' || true
}

xanmod_installed() {
    [[ -n "$(list_installed_xanmod_images)" ]]
}

installed_xanmod_kernel_versions() {
    local directory
    shopt -s nullglob
    for directory in "$MODULES_DIR"/*xanmod*; do
        [[ -d "$directory" ]] && basename "$directory"
    done
    shopt -u nullglob
}

newest_installed_xanmod_kernel() {
    installed_xanmod_kernel_versions | sort -V | tail -n 1
}

installed_manager_package() {
    list_installed_xanmod_packages |
        grep -E '^linux-xanmod(-lts)?-x64v[123]$' |
        head -n 1 || true
}

package_snapshot() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 'linux-*xanmod*' 2>/dev/null |
        awk '$1 == "ii" {print $2 "=" $3}' |
        sort -u || true
}

candidate_version() {
    local package="$1"
    LC_ALL=C apt-cache policy "$package" 2>/dev/null |
        awk '/^[[:space:]]*Candidate:/ {print $2; exit}'
}

xanmod_package_available() {
    local candidate
    candidate=$(candidate_version "$1")
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

detect_psabi_level() {
    local flags level=0
    flags=" $(LC_ALL=C awk -F: '/^[[:space:]]*flags[[:space:]]*:/{print $2; exit}' "$CPUINFO_FILE" 2>/dev/null) "
    [[ "$flags" == "  " ]] && return 1

    has_cpu_flag() { [[ "$flags" == *" $1 "* ]]; }

    if has_cpu_flag lm && has_cpu_flag cmov && has_cpu_flag cx8 &&
       has_cpu_flag fpu && has_cpu_flag fxsr && has_cpu_flag mmx &&
       has_cpu_flag syscall && has_cpu_flag sse2; then
        level=1
    fi
    if (( level == 1 )) && has_cpu_flag cx16 && has_cpu_flag lahf_lm &&
       has_cpu_flag popcnt && has_cpu_flag pni && has_cpu_flag sse4_1 && has_cpu_flag sse4_2 &&
       has_cpu_flag ssse3; then
        level=2
    fi
    if (( level == 2 )) && has_cpu_flag avx && has_cpu_flag avx2 &&
       has_cpu_flag bmi1 && has_cpu_flag bmi2 && has_cpu_flag f16c &&
       has_cpu_flag fma && { has_cpu_flag abm || has_cpu_flag lzcnt; } &&
       has_cpu_flag movbe && has_cpu_flag xsave; then
        level=3
    fi
    (( level > 0 )) || return 1
    printf '%s\n' "$level"
}

select_xanmod_package() {
    local installed_package level prefix package

    installed_package=$(installed_manager_package)
    if [[ -n "$installed_package" ]] && xanmod_package_available "$installed_package"; then
        printf '%s\n' "$installed_package"
        return 0
    fi

    level=$(detect_psabi_level) || {
        error "无法识别当前 CPU 的 x86-64 psABI 等级。"
        return 1
    }
    (( level > 3 )) && level=3

    for prefix in linux-xanmod linux-xanmod-lts; do
        while (( level >= 1 )); do
            package="${prefix}-x64v${level}"
            if xanmod_package_available "$package"; then
                printf '%s\n' "$package"
                return 0
            fi
            ((level--))
        done
        level=$(detect_psabi_level) || return 1
        (( level > 3 )) && level=3
    done

    error "XanMod 仓库中没有适配当前 CPU 和发行版的软件包。"
    return 1
}

valid_backup_id() {
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+(-[0-9]+)?$ ]]
}

backup_file() {
    local source="$1"
    local label="$2"
    local directory="$BACKUP_ROOT/$CURRENT_BACKUP_ID"

    if [[ -e "$source" || -L "$source" ]]; then
        printf '1\n' > "$directory/$label.exists"
        cp -a -- "$source" "$directory/$label.data" || return 1
    else
        printf '0\n' > "$directory/$label.exists"
    fi
}

create_backup() {
    local action="${1:-manual}"
    local runtime_cc runtime_qdisc
    local backup_base backup_counter=0

    backup_base="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    CURRENT_BACKUP_ID="$backup_base"
    while [[ -e "$BACKUP_ROOT/$CURRENT_BACKUP_ID" ]]; do
        ((backup_counter++))
        CURRENT_BACKUP_ID="${backup_base}-${backup_counter}"
    done
    if ! secure_mkdir "$BACKUP_ROOT/$CURRENT_BACKUP_ID"; then
        error "无法创建备份目录：$BACKUP_ROOT/$CURRENT_BACKUP_ID"
        return 1
    fi

    backup_file "$SYSCTL_FILE" sysctl || return 1
    backup_file "$REPO_FILE" repo || return 1
    backup_file "$KEYRING_FILE" keyring || return 1
    backup_file "$MANAGED_SYSCTL_MARKER" marker-sysctl || return 1
    backup_file "$MANAGED_REPO_MARKER" marker-repo || return 1
    backup_file "$MANAGED_KEY_MARKER" marker-key || return 1
    backup_file "$ARM_SYSCTL_FILE" arm-sysctl || return 1

    runtime_cc=$(safe_token "$(current_congestion_control)")
    runtime_qdisc=$(safe_token "$(current_qdisc)")
    {
        printf 'action=%s\n' "$(safe_token "$action")"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'running_kernel=%s\n' "$(safe_token "$(uname -r 2>/dev/null || true)")"
        printf 'congestion_control=%s\n' "$runtime_cc"
        printf 'default_qdisc=%s\n' "$runtime_qdisc"
    } > "$BACKUP_ROOT/$CURRENT_BACKUP_ID/metadata"
    package_snapshot > "$BACKUP_ROOT/$CURRENT_BACKUP_ID/packages.before"

    ok "配置备份已保存：$BACKUP_ROOT/$CURRENT_BACKUP_ID"
}

restore_file_from_backup() {
    local directory="$1"
    local label="$2"
    local target="$3"
    local existed
    local target_directory
    local temporary

    [[ -f "$directory/$label.exists" ]] || return 1
    existed=$(<"$directory/$label.exists")
    if [[ "$existed" == "1" ]]; then
        [[ -e "$directory/$label.data" || -L "$directory/$label.data" ]] || return 1
        target_directory=$(dirname "$target")
        mkdir -p "$target_directory" || return 1
        temporary=$(mktemp "$target_directory/.bbr3-restore.XXXXXX") || return 1
        rm -f -- "$temporary"
        if ! cp -a -- "$directory/$label.data" "$temporary"; then
            rm -f -- "$temporary"
            return 1
        fi
        if ! mv -f -- "$temporary" "$target"; then
            rm -f -- "$temporary"
            return 1
        fi
    elif [[ "$existed" == "0" ]]; then
        rm -f -- "$target" || return 1
    else
        return 1
    fi
}

metadata_value() {
    local metadata_file="$1"
    local key="$2"
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$metadata_file" 2>/dev/null
}

apply_runtime_values() {
    local cc="$1"
    local qdisc="$2"
    local available

    available=" $(available_congestion_controls) "
    if [[ -n "$qdisc" ]]; then
        sysctl -w "net.core.default_qdisc=$qdisc" >/dev/null 2>&1 ||
            warn "无法恢复运行时队列算法为 $qdisc。"
    fi
    if [[ -n "$cc" && "$available" == *" $cc "* ]]; then
        sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 ||
            warn "无法恢复运行时拥塞控制算法为 $cc。"
    fi
}

restore_backup_files() {
    local backup_id="$1"
    local directory="$BACKUP_ROOT/$backup_id"
    local cc qdisc

    [[ -d "$directory" ]] || {
        error "备份不存在：$directory"
        return 1
    }

    restore_file_from_backup "$directory" sysctl "$SYSCTL_FILE" || return 1
    restore_file_from_backup "$directory" repo "$REPO_FILE" || return 1
    restore_file_from_backup "$directory" keyring "$KEYRING_FILE" || return 1
    restore_file_from_backup "$directory" marker-sysctl "$MANAGED_SYSCTL_MARKER" || return 1
    restore_file_from_backup "$directory" marker-repo "$MANAGED_REPO_MARKER" || return 1
    restore_file_from_backup "$directory" marker-key "$MANAGED_KEY_MARKER" || return 1
    restore_file_from_backup "$directory" arm-sysctl "$ARM_SYSCTL_FILE" || return 1

    cc=$(metadata_value "$directory/metadata" congestion_control)
    qdisc=$(metadata_value "$directory/metadata" default_qdisc)
    apply_runtime_values "$cc" "$qdisc"
}

latest_backup_id() {
    local directory
    [[ -d "$BACKUP_ROOT" ]] || return 1
    directory=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
        sort | tail -n 1)
    [[ -n "$directory" ]] || return 1
    printf '%s\n' "$directory"
}

capture_original_file() {
    local source="$1"
    local label="$2"

    secure_mkdir "$ORIGINAL_DIR" || return 1
    [[ ! -f "$ORIGINAL_DIR/$label.captured" ]] || return 0
    if [[ -e "$source" || -L "$source" ]]; then
        printf '1\n' > "$ORIGINAL_DIR/$label.exists"
        cp -a -- "$source" "$ORIGINAL_DIR/$label.data" || return 1
    else
        printf '0\n' > "$ORIGINAL_DIR/$label.exists"
    fi
    printf '1\n' > "$ORIGINAL_DIR/$label.captured"
}

restore_original_file() {
    local label="$1"
    local target="$2"
    [[ -f "$ORIGINAL_DIR/$label.captured" ]] || return 0
    restore_file_from_backup "$ORIGINAL_DIR" "$label" "$target"
}

capture_original_runtime() {
    local cc qdisc temporary
    secure_mkdir "$ORIGINAL_DIR" || return 1
    [[ ! -f "$ORIGINAL_RUNTIME_FILE" ]] || return 0
    cc=$(safe_token "$(current_congestion_control)")
    qdisc=$(safe_token "$(current_qdisc)")
    temporary=$(mktemp "$ORIGINAL_DIR/.runtime.XXXXXX") || return 1
    {
        printf 'congestion_control=%s\n' "$cc"
        printf 'default_qdisc=%s\n' "$qdisc"
    } > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$ORIGINAL_RUNTIME_FILE"
}

restore_original_runtime() {
    local cc qdisc
    [[ -f "$ORIGINAL_RUNTIME_FILE" ]] || return 0
    cc=$(metadata_value "$ORIGINAL_RUNTIME_FILE" congestion_control)
    qdisc=$(metadata_value "$ORIGINAL_RUNTIME_FILE" default_qdisc)
    apply_runtime_values "$cc" "$qdisc"
}

find_existing_xanmod_repo() {
    local file
    local -a files=()
    [[ -f /etc/apt/sources.list ]] && files+=(/etc/apt/sources.list)
    shopt -s nullglob
    files+=(/etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
    shopt -u nullglob

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        if grep -Eq '^[[:space:]]*deb([[:space:]]|\[).*deb\.xanmod\.org|^[[:space:]]*URIs:[[:space:]].*deb\.xanmod\.org' "$file" 2>/dev/null; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

ensure_dependencies() {
    info "更新系统软件包索引并检查必要工具..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        error "系统软件源更新失败，尚未修改 XanMod 仓库。"
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget gnupg; then
        error "安装 ca-certificates、curl、wget 或 gnupg 失败。"
        return 1
    fi
}

download_xanmod_key() {
    local output_file="$1"
    local raw_key_tmp

    raw_key_tmp=$(mktemp "${TMPDIR:-/tmp}/.ai-scripts-xanmod-key.XXXXXX") || return 1
    if wget -qO "$raw_key_tmp" "$XANMOD_KEY_URL" &&
       gpg --dearmor --batch --yes -o "$output_file" "$raw_key_tmp" 2>/dev/null; then
        rm -f -- "$raw_key_tmp"
        [[ -s "$output_file" ]]
        return
    fi

    warn "XanMod 官方密钥地址不可用，改用原脚本的 GitHub 备用地址。"
    rm -f -- "$output_file"
    if ! wget -qO "$raw_key_tmp" "$XANMOD_KEY_FALLBACK_URL" ||
       ! gpg --dearmor --batch --yes -o "$output_file" "$raw_key_tmp" 2>/dev/null; then
        rm -f -- "$output_file" "$raw_key_tmp"
        return 1
    fi
    rm -f -- "$raw_key_tmp"
    [[ -s "$output_file" ]]
}

ensure_xanmod_repo() {
    local existing_repo key_tmp repo_tmp

    existing_repo=$(find_existing_xanmod_repo || true)
    if [[ -n "$existing_repo" ]]; then
        info "使用现有 XanMod 软件源：$existing_repo"
        return 0
    fi

    capture_original_file "$REPO_FILE" repo || return 1
    capture_original_file "$KEYRING_FILE" keyring || return 1
    mkdir -p "$STATE_DIR" /etc/apt/keyrings /etc/apt/sources.list.d || return 1

    key_tmp=$(mktemp "/etc/apt/keyrings/.ai-scripts-xanmod-key.XXXXXX") || return 1
    info "下载并转换 XanMod 官方仓库密钥..."
    if ! download_xanmod_key "$key_tmp"; then
        rm -f -- "$key_tmp"
        error "官方及备用地址的 XanMod 仓库密钥均下载或转换失败。"
        return 1
    fi
    chmod 644 "$key_tmp"
    mv -f -- "$key_tmp" "$KEYRING_FILE" || return 1
    printf 'managed\n' > "$MANAGED_KEY_MARKER"

    repo_tmp=$(mktemp "/etc/apt/sources.list.d/.ai-scripts-xanmod.XXXXXX") || return 1
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' \
        "$KEYRING_FILE" "$OS_CODENAME" > "$repo_tmp"
    chmod 644 "$repo_tmp"
    mv -f -- "$repo_tmp" "$REPO_FILE" || return 1
    printf 'managed\n' > "$MANAGED_REPO_MARKER"
    ok "已配置 XanMod 软件源：$REPO_FILE"
}

update_xanmod_index() {
    info "更新包含 XanMod 的软件包索引..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        error "XanMod 软件源不可用或当前发行版代号不受支持。"
        return 1
    fi
}

check_disk_space() {
    local root_free boot_free
    root_free=$(df -Pm / 2>/dev/null | awk 'NR == 2 {print $4}')
    if [[ ! "$root_free" =~ ^[0-9]+$ || "$root_free" -lt 1536 ]]; then
        error "根分区至少需要约 1.5 GiB 可用空间。"
        return 1
    fi

    if [[ -d "$BOOT_DIR" ]]; then
        boot_free=$(df -Pm "$BOOT_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
        if [[ "$boot_free" =~ ^[0-9]+$ && "$boot_free" -lt 256 ]]; then
            error "$BOOT_DIR 至少需要约 256 MiB 可用空间。"
            return 1
        fi
    fi
}

show_dkms_warning() {
    local dkms_output
    command -v dkms >/dev/null 2>&1 || return 0
    dkms_output=$(dkms status 2>/dev/null || true)
    [[ -n "$dkms_output" ]] || return 0
    warn "检测到 DKMS 模块。新内核可能与专有驱动、OpenZFS、VirtualBox 或 VMware 模块不兼容："
    printf '%s\n' "$dkms_output" >&2
}

show_sysctl_conflicts() {
    local output
    output=$(
        grep -RnsE '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' \
            /etc/sysctl.conf /etc/sysctl.d 2>/dev/null |
            grep -Fv "$SYSCTL_FILE" || true
    )
    if [[ -n "$output" ]]; then
        warn "检测到其他 BBR/qdisc 配置；本脚本不会删除它们，请在重启后复核最终值："
        printf '%s\n' "$output" >&2
    fi
}

write_bbr_config() {
    local directory temporary available cc qdisc
    directory=$(dirname "$SYSCTL_FILE")
    mkdir -p "$STATE_DIR" "$directory" || return 1

    if [[ -e "$SYSCTL_FILE" && ! -f "$MANAGED_SYSCTL_MARKER" ]] &&
       ! grep -q '^# Managed by AI-Scripts bbr3_manager.sh$' "$SYSCTL_FILE" 2>/dev/null; then
        error "$SYSCTL_FILE 已存在且不属于本脚本，拒绝覆盖。"
        return 1
    fi

    capture_original_file "$SYSCTL_FILE" sysctl || return 1
    capture_original_runtime || return 1

    temporary=$(mktemp "$directory/.ai-scripts-bbr3.XXXXXX") || return 1
    cat > "$temporary" <<'EOF'
# Managed by AI-Scripts bbr3_manager.sh
# XanMod exposes BBRv3 through the congestion-control name "bbr".
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    chmod 644 "$temporary"
    if ! mv -f -- "$temporary" "$SYSCTL_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
    printf 'managed\n' > "$MANAGED_SYSCTL_MARKER"

    modprobe tcp_bbr >/dev/null 2>&1 || true
    available=" $(available_congestion_controls) "
    if [[ "$available" != *" bbr "* ]]; then
        warn "当前运行内核尚未提供 BBR；配置会在启动 XanMod 内核后应用。"
        show_sysctl_conflicts
        return 0
    fi

    if ! sysctl -p "$SYSCTL_FILE" >/dev/null; then
        error "应用 BBR 配置失败。"
        return 1
    fi
    cc=$(current_congestion_control)
    qdisc=$(current_qdisc)
    if [[ "$cc" != "bbr" || "$qdisc" != "fq" ]]; then
        error "配置应用后验证失败：拥塞控制=${cc:-unknown}，qdisc=${qdisc:-unknown}。"
        return 1
    fi
    show_sysctl_conflicts
    ok "当前运行内核已启用 bbr + fq。"
}

rollback_sysctl_from_current_backup() {
    local directory cc qdisc
    [[ -n "$CURRENT_BACKUP_ID" ]] || return 0
    directory="$BACKUP_ROOT/$CURRENT_BACKUP_ID"
    restore_file_from_backup "$directory" sysctl "$SYSCTL_FILE" || true
    restore_file_from_backup "$directory" marker-sysctl "$MANAGED_SYSCTL_MARKER" || true
    cc=$(metadata_value "$directory/metadata" congestion_control)
    qdisc=$(metadata_value "$directory/metadata" default_qdisc)
    apply_runtime_values "$cc" "$qdisc"
}

refresh_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        if ! update-grub; then
            warn "update-grub 执行失败，请在重启前检查引导配置。"
            return 1
        fi
    else
        warn "未找到 update-grub；请确认系统会自动更新引导项。"
    fi
}

reboot_required() {
    local running newest
    running=$(uname -r 2>/dev/null || true)
    if [[ "$(uname -m 2>/dev/null || true)" == "aarch64" ||
          "$(uname -m 2>/dev/null || true)" == "arm64" ]]; then
        [[ -f /var/run/reboot-required ]]
        return
    fi
    newest=$(newest_installed_xanmod_kernel)

    if xanmod_installed && [[ -n "$newest" && "$running" != "$newest" ]]; then
        return 0
    fi
    if ! xanmod_installed && [[ "$running" == *xanmod* ]]; then
        return 0
    fi
    return 1
}

status_json() {
    local supported=false installed=false active=false reboot=false
    local architecture running installed_kernels cc qdisc available reason evidence mode bbr_version

    architecture=$(safe_token "$(uname -m 2>/dev/null || true)")
    running=$(safe_token "$(uname -r 2>/dev/null || true)")
    load_os_release
    reason=""
    if host_supported; then supported=true; else reason="$SUPPORT_REASON"; fi
    mode="$HOST_MODE"
    bbr_version=$(modinfo -F version tcp_bbr 2>/dev/null | head -n 1 || true)
    if [[ "$mode" == "arm64-external" ]]; then
        [[ "$bbr_version" == *3* ]] && installed=true
        installed_kernels=""
    else
        xanmod_installed && installed=true
        installed_kernels=$(installed_xanmod_kernel_versions | sort -V | paste -sd, -)
    fi
    cc=$(safe_token "$(current_congestion_control)")
    qdisc=$(safe_token "$(current_qdisc)")
    available=$(safe_token "$(available_congestion_controls | tr ' ' ',')")
    evidence=""
    if [[ "$mode" == "arm64-external" ]]; then
        if [[ "$bbr_version" == *3* && "$cc" == "bbr" ]]; then
            active=true
            evidence="tcp_bbr-version-${bbr_version}+bbr+${qdisc}"
        fi
    elif [[ "$running" == *xanmod* && "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        active=true
        evidence="xanmod-kernel+bbr+fq"
    fi
    reboot_required && reboot=true

    printf '{"supported":%s,"installed":%s,"active":%s,"rebootRequired":%s,' \
        "$supported" "$installed" "$active" "$reboot"
    printf '"architecture":"%s","os":"%s","codename":"%s","mode":"%s",' \
        "$(json_escape "$architecture")" "$(json_escape "$OS_ID")" "$(json_escape "$OS_CODENAME")" \
        "$(json_escape "$mode")"
    printf '"runningKernel":"%s","installedKernels":"%s",' \
        "$(json_escape "$running")" "$(json_escape "$installed_kernels")"
    printf '"congestionControl":"%s","defaultQDisc":"%s","availableCongestionControls":"%s",' \
        "$(json_escape "$cc")" "$(json_escape "$qdisc")" "$(json_escape "$available")"
    printf '"bbrModuleVersion":"%s","evidence":"%s","reason":"%s"}\n' \
        "$(json_escape "$bbr_version")" "$(json_escape "$evidence")" "$(json_escape "$reason")"
}

status_human() {
    local architecture running installed_kernels packages cc qdisc available
    local supported_text installed_text active_text reboot_text mode bbr_version

    architecture=$(uname -m 2>/dev/null || true)
    running=$(uname -r 2>/dev/null || true)
    load_os_release
    if host_supported; then
        supported_text="是"
    else
        supported_text="否（$SUPPORT_REASON）"
    fi
    mode="$HOST_MODE"
    bbr_version=$(modinfo -F version tcp_bbr 2>/dev/null | head -n 1 || true)
    if [[ "$mode" == "arm64-external" ]]; then
        installed_kernels="不适用"
        packages="由 ARM64 原始脚本管理"
    else
        installed_kernels=$(installed_xanmod_kernel_versions | sort -V | paste -sd, -)
        packages=$(list_installed_xanmod_images | paste -sd, -)
    fi
    cc=$(current_congestion_control)
    qdisc=$(current_qdisc)
    available=$(available_congestion_controls)

    if [[ "$mode" == "arm64-external" ]]; then
        [[ "$bbr_version" == *3* ]] && installed_text="是" || installed_text="未检测到"
    else
        xanmod_installed && installed_text="是" || installed_text="否"
    fi
    if [[ "$mode" == "arm64-external" && "$bbr_version" == *3* && "$cc" == "bbr" ]]; then
        active_text="是（依据：tcp_bbr version=$bbr_version + bbr + $qdisc）"
    elif [[ "$running" == *xanmod* && "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        active_text="是（依据：XanMod 内核 + bbr + fq）"
    else
        active_text="否"
    fi
    reboot_required && reboot_text="是" || reboot_text="否"

    printf '%bBBRv3 管理状态%b\n' "$CYAN" "$NC"
    printf '  脚本版本：        %s\n' "$SCRIPT_VERSION"
    printf '  系统/代号：       %s / %s\n' "${OS_ID:-unknown}" "${OS_CODENAME:-unknown}"
    printf '  CPU 架构：        %s\n' "${architecture:-unknown}"
    printf '  管理模式：        %s\n' "${mode:-unsupported}"
    printf '  支持当前架构：    %s\n' "$supported_text"
    printf '  当前内核：        %s\n' "${running:-unknown}"
    if [[ "$mode" == "arm64-external" ]]; then
        printf '  ARM BBRv3 检测：  %s\n' "$installed_text"
        printf '  tcp_bbr 版本：    %s\n' "${bbr_version:-unknown}"
    else
        printf '  XanMod 已安装：   %s\n' "$installed_text"
    fi
    printf '  已安装内核目录：  %s\n' "${installed_kernels:-无}"
    printf '  已安装内核包：    %s\n' "${packages:-无}"
    printf '  当前拥塞控制：    %s\n' "${cc:-unknown}"
    printf '  当前 qdisc：      %s\n' "${qdisc:-unknown}"
    printf '  可用拥塞控制：    %s\n' "${available:-unknown}"
    printf '  BBRv3 条件生效：  %s\n' "$active_text"
    printf '  建议重启：        %s\n' "$reboot_text"
    if [[ "$mode" == "arm64-external" ]]; then
        printf '\n说明：ARM64 保留原始脚本的 modinfo version 检测方式和交互管理菜单。\n'
    else
        printf '\n说明：x86_64 状态依据官方 XanMod 内核和 bbr/fq 组合推断，不能从 sysctl 名称直接读取 BBR 版本。\n'
    fi
}

run_arm64_manager() {
    create_backup arm64-external || return 1
    info "ARM64 将进入原始 BBRv3 管理菜单。"
    warn "该菜单会自行处理内核安装、配置和卸载；--yes 不会跳过它内部的确认。"
    if ! bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); then
        error "ARM64 原始 BBRv3 管理脚本执行失败。"
        return 1
    fi
    ok "ARM64 原始 BBRv3 管理脚本执行结束。"
    show_status
}

show_status() {
    if [[ "$JSON_OUTPUT" == true ]]; then
        status_json
    else
        status_human
    fi
}

prepare_mutation() {
    require_root || return 1
    host_supported || {
        error "$SUPPORT_REASON"
        return 1
    }
    acquire_lock || return 1
}

prepare_uninstall() {
    require_root || return 1
    load_os_release
    if ! command -v apt-get >/dev/null 2>&1 ||
       ! command -v dpkg-query >/dev/null 2>&1; then
        error "缺少 apt-get 或 dpkg-query，无法安全卸载 XanMod 软件包。"
        return 1
    fi
    acquire_lock || return 1
}

install_bbr3() {
    local package

    prepare_mutation || return 1
    if [[ "$HOST_MODE" == "arm64-external" ]]; then
        run_arm64_manager
        return
    fi
    check_disk_space || return 1
    if xanmod_installed; then
        info "检测到已安装的 XanMod 内核，将修复并验证 BBR 配置。"
        create_backup repair || return 1
        if ! write_bbr_config; then
            rollback_sysctl_from_current_backup
            return 1
        fi
        show_status
        return 0
    fi

    show_dkms_warning
    warn "安装第三方内核后必须重启。请确保控制台或云平台救援功能可用。"
    confirm "继续安装最新适配的 XanMod BBRv3 内核吗？" || {
        info "操作已取消。"
        return 1
    }

    create_backup install || return 1
    ensure_dependencies || return 1
    if ! ensure_xanmod_repo || ! update_xanmod_index; then
        warn "仓库配置失败，正在恢复本次操作前的仓库文件。"
        restore_backup_files "$CURRENT_BACKUP_ID" || true
        return 1
    fi

    package=$(select_xanmod_package) || return 1
    info "将安装最新候选包：$package ($(candidate_version "$package"))"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        error "XanMod 内核安装失败。APT 可能已完成部分操作，请检查上方输出和备份。"
        return 1
    fi
    if ! xanmod_installed; then
        error "APT 返回成功，但没有检测到处于 ii 状态的 XanMod 内核镜像包。"
        return 1
    fi

    refresh_grub || true
    if ! write_bbr_config; then
        rollback_sysctl_from_current_backup
        error "内核已安装，但 BBR 配置失败；sysctl 配置已回滚。"
        return 1
    fi

    ok "XanMod BBRv3 内核安装完成。请确认状态后自行重启。"
    show_status
}

update_bbr3() {
    local package before after

    prepare_mutation || return 1
    if [[ "$HOST_MODE" == "arm64-external" ]]; then
        run_arm64_manager
        return
    fi
    check_disk_space || return 1
    if ! xanmod_installed; then
        error "没有检测到已安装的 XanMod 内核，请先执行 install。"
        return 1
    fi

    show_dkms_warning
    confirm "继续更新当前 XanMod 内核系列并修复 BBR 配置吗？" || {
        info "操作已取消。"
        return 1
    }

    create_backup update || return 1
    before=$(package_snapshot)
    ensure_dependencies || return 1
    if ! ensure_xanmod_repo || ! update_xanmod_index; then
        warn "仓库配置失败，正在恢复本次操作前的仓库文件。"
        restore_backup_files "$CURRENT_BACKUP_ID" || true
        return 1
    fi
    package=$(select_xanmod_package) || return 1
    info "更新目标：$package ($(candidate_version "$package"))"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        error "XanMod 更新失败，请检查 APT 输出。"
        return 1
    fi
    after=$(package_snapshot)
    if [[ "$before" == "$after" ]]; then
        info "XanMod 软件包已经是当前仓库提供的最新版本。"
    else
        ok "XanMod 软件包已更新。"
    fi

    refresh_grub || true
    if ! write_bbr_config; then
        rollback_sysctl_from_current_backup
        error "内核更新完成，但 BBR 配置失败；sysctl 配置已回滚。"
        return 1
    fi
    show_status
}

find_non_xanmod_boot_kernels() {
    local image version
    shopt -s nullglob
    for image in "$BOOT_DIR"/vmlinuz-*; do
        [[ -f "$image" ]] || continue
        version=${image##*/vmlinuz-}
        [[ "$version" == *xanmod* ]] && continue
        if [[ -d "$MODULES_DIR/$version" ]]; then
            printf '%s\n' "$version"
        fi
    done
    shopt -u nullglob
}

fallback_kernel_hint() {
    if [[ "$OS_ID" == "ubuntu" || " $OS_ID_LIKE " == *" ubuntu "* ]]; then
        printf 'sudo apt-get install linux-generic'
    else
        printf 'sudo apt-get install linux-image-amd64'
    fi
}

remove_managed_files() {
    if [[ -f "$MANAGED_SYSCTL_MARKER" ]]; then
        if [[ -f "$ORIGINAL_DIR/sysctl.captured" ]]; then
            restore_original_file sysctl "$SYSCTL_FILE" || return 1
        elif grep -q '^# Managed by AI-Scripts bbr3_manager.sh$' "$SYSCTL_FILE" 2>/dev/null; then
            rm -f -- "$SYSCTL_FILE" || return 1
        fi
        rm -f -- "$MANAGED_SYSCTL_MARKER"
    fi
    if [[ -f "$MANAGED_REPO_MARKER" ]]; then
        if [[ -f "$ORIGINAL_DIR/repo.captured" ]]; then
            restore_original_file repo "$REPO_FILE" || return 1
        else
            rm -f -- "$REPO_FILE" || return 1
        fi
        rm -f -- "$MANAGED_REPO_MARKER"
    fi
    if [[ -f "$MANAGED_KEY_MARKER" ]]; then
        if [[ -f "$ORIGINAL_DIR/keyring.captured" ]]; then
            restore_original_file keyring "$KEYRING_FILE" || return 1
        else
            rm -f -- "$KEYRING_FILE" || return 1
        fi
        rm -f -- "$MANAGED_KEY_MARKER"
    fi
    restore_original_runtime
}

uninstall_bbr3() {
    local simulation fallback_kernels running
    local -a packages=()

    if host_supported && [[ "$HOST_MODE" == "arm64-external" ]]; then
        require_root || return 1
        acquire_lock || return 1
        run_arm64_manager
        return
    fi
    prepare_uninstall || return 1
    mapfile -t packages < <(list_installed_xanmod_packages)
    fallback_kernels=$(find_non_xanmod_boot_kernels | paste -sd, -)
    running=$(uname -r 2>/dev/null || true)

    if (( ${#packages[@]} == 0 )); then
        info "没有检测到已安装的 XanMod 软件包。"
        if [[ ! -f "$MANAGED_SYSCTL_MARKER" && ! -f "$MANAGED_REPO_MARKER" &&
              ! -f "$MANAGED_KEY_MARKER" ]]; then
            return 0
        fi
        confirm "仍要清理本脚本管理的 BBR 配置和仓库文件吗？" || return 1
        create_backup cleanup || return 1
        remove_managed_files || return 1
        ok "脚本管理的配置已恢复或移除。"
        return 0
    fi

    if [[ -z "$fallback_kernels" ]]; then
        error "未找到可启动的非 XanMod 内核，拒绝卸载。"
        printf '请先安装并确认备用内核，例如：%s\n' "$(fallback_kernel_hint)" >&2
        return 1
    fi

    info "检测到备用内核：$fallback_kernels"
    if [[ "$running" == *xanmod* ]]; then
        warn "当前正在运行 XanMod 内核；卸载成功后必须重启到备用内核。"
    fi
    info "APT 将模拟清除以下已安装的 XanMod 包："
    printf '  %s\n' "${packages[@]}"
    if ! simulation=$(DEBIAN_FRONTEND=noninteractive apt-get -s purge "${packages[@]}" 2>&1); then
        error "APT 卸载模拟失败："
        printf '%s\n' "$simulation" >&2
        return 1
    fi
    printf '%s\n' "$simulation"
    warn "本脚本不会自动执行 apt autoremove。"
    confirm "确认清除上述 XanMod 包吗？" || {
        info "操作已取消。"
        return 1
    }

    create_backup uninstall || return 1
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"; then
        error "XanMod 卸载失败；软件源和 sysctl 配置保持不变。"
        return 1
    fi
    if xanmod_installed; then
        error "卸载命令结束后仍检测到 XanMod 内核镜像，配置保持不变。"
        return 1
    fi

    refresh_grub || true
    if ! remove_managed_files; then
        error "内核已卸载，但恢复配置文件失败；请使用 restore $CURRENT_BACKUP_ID。"
        return 1
    fi
    ok "XanMod 已卸载，脚本管理的配置已恢复。"
    if [[ "$running" == *xanmod* ]]; then
        warn "当前进程仍运行在已卸载的 XanMod 内核上，请尽快重启。"
    fi
    show_status
}

restore_action() {
    local requested="${1:-latest}"
    local target_id recovery_id

    require_root || return 1
    acquire_lock || return 1
    if [[ "$requested" == "latest" ]]; then
        target_id=$(latest_backup_id) || {
            error "没有可用备份。"
            return 1
        }
    else
        valid_backup_id "$requested" || {
            error "备份编号格式无效。"
            return 1
        }
        target_id="$requested"
    fi
    [[ -d "$BACKUP_ROOT/$target_id" ]] || {
        error "备份不存在：$target_id"
        return 1
    }

    warn "restore 只恢复脚本管理的配置文件和运行时网络参数，不自动安装或删除内核包。"
    confirm "确认恢复备份 $target_id 吗？" || return 1
    create_backup pre-restore || return 1
    recovery_id="$CURRENT_BACKUP_ID"
    if ! restore_backup_files "$target_id"; then
        error "恢复失败，正在尝试回到恢复操作前的配置。"
        restore_backup_files "$recovery_id" || true
        return 1
    fi
    ok "已恢复备份：$target_id"
    info "如需撤销本次恢复，可执行：sudo $SCRIPT_NAME restore $recovery_id"
}

pause_menu() {
    release_lock
    [[ -t 0 ]] || return 0
    printf '\n按回车键继续...'
    read -r _
}

interactive_menu() {
    local choice
    while true; do
        printf '\033c'
        printf '%bXanMod BBRv3 管理器%b  v%s\n' "$CYAN" "$NC" "$SCRIPT_VERSION"
        printf '%s\n' '----------------------------------------'
        printf '%s\n' '1. 查看状态' '2. 安装/修复 BBRv3' '3. 更新 XanMod' \
            '4. 安全卸载 XanMod' '5. 恢复最近一次配置备份' '0. 退出'
        printf '%s\n' '----------------------------------------'
        read -r -p '请选择: ' choice
        case "$choice" in
            1) show_status; pause_menu ;;
            2) install_bbr3; pause_menu ;;
            3) update_bbr3; pause_menu ;;
            4) uninstall_bbr3; pause_menu ;;
            5) restore_action latest; pause_menu ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

main() {
    local action="${1:-menu}"
    local restore_id="latest"
    local restore_id_seen=false
    shift || true

    while (( $# > 0 )); do
        case "$1" in
            --yes) ASSUME_YES=true ;;
            --json) JSON_OUTPUT=true ;;
            -h|--help) usage; return 0 ;;
            *)
                if [[ "$action" == "restore" && "$restore_id_seen" == false ]]; then
                    restore_id="$1"
                    restore_id_seen=true
                else
                    error "未知参数：$1"
                    usage
                    return 2
                fi
                ;;
        esac
        shift
    done

    case "$action" in
        status) show_status ;;
        install) install_bbr3 ;;
        update) update_bbr3 ;;
        uninstall) uninstall_bbr3 ;;
        restore) restore_action "$restore_id" ;;
        menu) interactive_menu ;;
        -h|--help|help) usage ;;
        *)
            error "未知命令：$action"
            usage
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
