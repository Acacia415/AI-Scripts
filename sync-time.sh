#!/bin/bash

# 一键校准系统时间脚本
# 用于修复 ss-rust + shadowtls 时间戳不匹配问题

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MAX_CLOCK_OFFSET_SECONDS="${SYNC_TIME_MAX_OFFSET_SECONDS:-5}"
HTTPS_CONSENSUS_SECONDS="${SYNC_TIME_HTTPS_CONSENSUS_SECONDS:-10}"
CHRONY_WAIT_ATTEMPTS="${SYNC_TIME_CHRONY_WAIT_ATTEMPTS:-10}"
SYNC_WAIT_ATTEMPTS="${SYNC_TIME_WAIT_ATTEMPTS:-10}"
SYNC_WAIT_INTERVAL="${SYNC_TIME_WAIT_INTERVAL:-2}"
SYNC_TIME_INSTALL_PATH="${SYNC_TIME_INSTALL_PATH:-/usr/local/lib/ai-scripts/sync-time.sh}"
SYNC_TIME_CRON_FILE="${SYNC_TIME_CRON_FILE:-/etc/cron.d/ai-scripts-sync-time}"
SYNC_TIME_LOG_DIR="${SYNC_TIME_LOG_DIR:-/var/log/ai-scripts}"
SYNC_TIME_LOG_FILE="${SYNC_TIME_LOG_FILE:-${SYNC_TIME_LOG_DIR}/sync-time.log}"
SYNC_TIME_LOGROTATE_FILE="${SYNC_TIME_LOGROTATE_FILE:-/etc/logrotate.d/ai-scripts-sync-time}"

SCHEDULED_MODE=false
TIME_SERVICES_RESTORE_PENDING=false
LAST_SYNC_METHOD=""
declare -a ACTIVE_TIME_SERVICES=()

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        echo "请使用: sudo $0"
        return 1
    fi
}

is_nonnegative_decimal() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_runtime_settings() {
    is_nonnegative_decimal "$MAX_CLOCK_OFFSET_SECONDS" || {
        print_error "允许的最大时间偏差无效: $MAX_CLOCK_OFFSET_SECONDS"
        return 1
    }
    is_nonnegative_decimal "$HTTPS_CONSENSUS_SECONDS" || {
        print_error "HTTPS 时间源一致性阈值无效: $HTTPS_CONSENSUS_SECONDS"
        return 1
    }
    [[ "$CHRONY_WAIT_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$SYNC_WAIT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
        print_error "同步重试次数配置无效。"
        return 1
    }
    is_nonnegative_decimal "$SYNC_WAIT_INTERVAL" || {
        print_error "同步等待间隔配置无效。"
        return 1
    }
}

absolute_decimal() {
    awk -v value="$1" 'BEGIN { if (value < 0) value = -value; printf "%.6f\n", value }'
}

decimal_lte() {
    awk -v left="$1" -v right="$2" 'BEGIN { exit !(left <= right) }'
}

show_current_time() {
    local timezone
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Unknown)
    print_info "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    print_info "当前时区: $timezone"
}

set_timezone() {
    local current_tz reply
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ "$current_tz" == Asia/Shanghai || "$current_tz" == Asia/Hong_Kong ]] && return 0
    print_warning "检测到时区不是 Asia/Shanghai 或 Asia/Hong_Kong"
    read -r -p "是否要设置时区为 Asia/Shanghai? (y/n): " -n 1 reply
    echo
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        print_success "时区已设置为 Asia/Shanghai"
    fi
}

duration_to_seconds() {
    local duration="${1#+}" sign=1 value unit
    if [[ "$duration" == -* ]]; then
        sign=-1
        duration="${duration#-}"
    fi
    if [[ "$duration" =~ ^([0-9]+([.][0-9]+)?)(ns|us|µs|ms|s)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    awk -v value="$value" -v unit="$unit" -v sign="$sign" 'BEGIN {
        divisor = 1
        if (unit == "ms") divisor = 1000
        else if (unit == "us" || unit == "µs") divisor = 1000000
        else if (unit == "ns") divisor = 1000000000
        printf "%.9f\n", sign * value / divisor
    }'
}

chrony_tracking_offset() {
    local tracking value stratum
    tracking=$(chronyc tracking 2>/dev/null) || return 1
    grep -Eq '^[[:space:]]*Leap status[[:space:]]*:[[:space:]]*Normal' <<< "$tracking" || return 1
    stratum=$(awk -F: '/^[[:space:]]*Stratum[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "$tracking")
    [[ "$stratum" =~ ^[1-9][0-9]*$ ]] && ((stratum <= 15)) || return 1
    value=$(awk -F: '/^[[:space:]]*System time[[:space:]]*:/ {
        gsub(/^[[:space:]]+/, "", $2); split($2, parts, /[[:space:]]+/); print parts[1]; exit
    }' <<< "$tracking")
    [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1
    printf '%s\n' "$value"
}

ntpd_peer_offset() {
    local peers offset_ms
    peers=$(ntpq -pn 2>/dev/null) || return 1
    offset_ms=$(awk '$1 ~ /^\*/ { print $9; exit }' <<< "$peers")
    [[ "$offset_ms" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v value="$offset_ms" 'BEGIN { printf "%.9f\n", value / 1000 }'
}

timesyncd_status_offset() {
    local status duration synchronized
    synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ "$synchronized" == yes ]] || return 1
    status=$(LC_ALL=C timedatectl timesync-status --no-pager 2>/dev/null) || return 1
    duration=$(sed -n 's/^[[:space:]]*Offset:[[:space:]]*\([^[:space:]]*\).*/\1/p' <<< "$status" | head -n 1)
    [[ -n "$duration" ]] || return 1
    duration_to_seconds "$duration"
}

query_ntp_offset() {
    local server output offset
    command -v ntpdate >/dev/null 2>&1 || return 1
    for server in ntp.aliyun.com time.cloudflare.com time.google.com pool.ntp.org; do
        output=$(timeout 10 ntpdate -q "$server" 2>/dev/null) || continue
        offset=$(sed -n 's/.*offset[[:space:]]\([-+0-9.]*\).*/\1/p' <<< "$output" | tail -n 1)
        if [[ "$offset" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            printf '%s\n' "$offset"
            return 0
        fi
    done
    return 1
}

fetch_https_date_epoch() {
    local url="$1" headers date_header epoch year
    command -v curl >/dev/null 2>&1 || return 1
    headers=$(curl --fail --silent --show-error --location --head \
        --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \
        -A 'AI-Scripts-Time-Sync/1.0' "$url" 2>/dev/null) || return 1
    date_header=$(awk 'tolower(substr($0, 1, 5)) == "date:" {
        sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0
    } END { print value }' <<< "$headers")
    [[ "$date_header" =~ ^[A-Za-z]{3},[[:space:]][0-9]{1,2}[[:space:]][A-Za-z]{3}[[:space:]][0-9]{4}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]GMT$ ]] || return 1
    epoch=$(LC_ALL=C date -u -d "$date_header" +%s 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    year=$(LC_ALL=C date -u -d "@$epoch" +%Y 2>/dev/null) || return 1
    ((year >= 2020 && year <= 2100)) || return 1
    printf '%s\n' "$epoch"
}

trusted_https_epoch() {
    local source epoch first second difference
    local -a epochs=()
    for source in 'https://www.cloudflare.com/' 'https://www.google.com/generate_204' 'https://github.com/'; do
        epoch=$(fetch_https_date_epoch "$source") || continue
        epochs+=("$epoch")
    done
    ((${#epochs[@]} >= 2)) || return 1
    for ((first=0; first<${#epochs[@]}; first++)); do
        for ((second=first+1; second<${#epochs[@]}; second++)); do
            difference=$((epochs[first] - epochs[second]))
            ((difference < 0)) && difference=$((-difference))
            if decimal_lte "$difference" "$HTTPS_CONSENSUS_SECONDS"; then
                if ((epochs[first] > epochs[second])); then
                    printf '%s\n' "${epochs[first]}"
                else
                    printf '%s\n' "${epochs[second]}"
                fi
                return 0
            fi
        done
    done
    return 1
}

https_clock_offset() {
    local network_epoch local_epoch
    network_epoch=$(trusted_https_epoch) || return 1
    local_epoch=$(date -u +%s) || return 1
    printf '%s\n' "$((network_epoch - local_epoch))"
}

measure_clock_offset() {
    local offset
    if offset=$(query_ntp_offset); then
        printf '%s\n' "$offset"
    elif command -v chronyc >/dev/null 2>&1 && offset=$(chrony_tracking_offset); then
        printf '%s\n' "$offset"
    elif command -v ntpq >/dev/null 2>&1 && offset=$(ntpd_peer_offset); then
        printf '%s\n' "$offset"
    elif command -v timedatectl >/dev/null 2>&1 && offset=$(timesyncd_status_offset); then
        printf '%s\n' "$offset"
    else
        https_clock_offset
    fi
}

start_chrony_service() {
    systemctl start chrony.service 2>/dev/null || systemctl start chronyd.service 2>/dev/null \
        || service chrony start 2>/dev/null || service chronyd start 2>/dev/null
}

sync_with_chrony() {
    local tracking stratum offset abs_offset
    command -v chronyc >/dev/null 2>&1 || return 1
    print_info "使用 chrony 同步时间..."
    start_chrony_service || return 1
    chronyc -a makestep >/dev/null 2>&1 || return 1
    chronyc waitsync "$CHRONY_WAIT_ATTEMPTS" "$MAX_CLOCK_OFFSET_SECONDS" >/dev/null 2>&1 || return 1
    tracking=$(chronyc tracking 2>/dev/null) || return 1
    grep -Eq '^[[:space:]]*Leap status[[:space:]]*:[[:space:]]*Normal' <<< "$tracking" || return 1
    stratum=$(awk -F: '/^[[:space:]]*Stratum[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "$tracking")
    [[ "$stratum" =~ ^[1-9][0-9]*$ ]] && ((stratum <= 15)) || return 1
    offset=$(chrony_tracking_offset) || return 1
    abs_offset=$(absolute_decimal "$offset")
    decimal_lte "$abs_offset" "$MAX_CLOCK_OFFSET_SECONDS" || return 1
    LAST_SYNC_METHOD=chrony
    print_success "Chrony 已真实同步，当前偏差约 ${offset} 秒"
}

sync_with_timesyncd() {
    local attempt synchronized offset abs_offset
    command -v timedatectl >/dev/null 2>&1 || return 1
    print_info "使用 systemd-timesyncd 同步时间..."
    timedatectl set-ntp true 2>/dev/null || return 1
    systemctl restart systemd-timesyncd.service 2>/dev/null || true
    for ((attempt=1; attempt<=SYNC_WAIT_ATTEMPTS; attempt++)); do
        synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [[ "$synchronized" == yes ]]; then
            if offset=$(timesyncd_status_offset); then
                abs_offset=$(absolute_decimal "$offset")
                decimal_lte "$abs_offset" "$MAX_CLOCK_OFFSET_SECONDS" || return 1
                print_success "systemd-timesyncd 已真实同步，当前偏差约 ${offset} 秒"
            else
                print_success "systemd-timesyncd 已报告系统时钟同步"
            fi
            LAST_SYNC_METHOD=systemd-timesyncd
            return 0
        fi
        sleep "$SYNC_WAIT_INTERVAL"
    done
    return 1
}

capture_and_stop_time_services() {
    local unit
    ACTIVE_TIME_SERVICES=()
    TIME_SERVICES_RESTORE_PENDING=false
    command -v systemctl >/dev/null 2>&1 || return 0
    for unit in systemd-timesyncd.service chrony.service chronyd.service ntp.service ntpd.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            ACTIVE_TIME_SERVICES+=("$unit")
        fi
    done
    ((${#ACTIVE_TIME_SERVICES[@]} > 0)) || return 0
    TIME_SERVICES_RESTORE_PENDING=true
    for unit in "${ACTIVE_TIME_SERVICES[@]}"; do
        if ! systemctl stop "$unit" 2>/dev/null; then
            print_error "无法暂时停止时间服务 $unit"
            restore_time_services || true
            return 1
        fi
    done
}

restore_time_services() {
    local unit status=0
    [[ "$TIME_SERVICES_RESTORE_PENDING" == true ]] || return 0
    for unit in "${ACTIVE_TIME_SERVICES[@]}"; do
        systemctl start "$unit" 2>/dev/null || status=1
    done
    TIME_SERVICES_RESTORE_PENDING=false
    ACTIVE_TIME_SERVICES=()
    return "$status"
}

sync_with_ntpdate() {
    local server success=false
    command -v ntpdate >/dev/null 2>&1 || return 1
    print_info "使用 ntpdate 同步时间..."
    capture_and_stop_time_services || return 1
    for server in ntp.aliyun.com time.cloudflare.com time.google.com cn.pool.ntp.org asia.pool.ntp.org pool.ntp.org; do
        print_info "尝试连接 NTP 服务器: $server"
        if timeout 10 ntpdate -u "$server" >/dev/null 2>&1; then
            success=true
            print_success "使用 $server 同步时间成功"
            hwclock --systohc 2>/dev/null || true
            break
        fi
    done
    if ! restore_time_services; then
        print_error "NTP 操作完成，但原有时间服务恢复失败。"
        return 1
    fi
    [[ "$success" == true ]] || {
        print_warning "ntpdate 的所有可信 NTP 服务器均同步失败。"
        return 1
    }
    LAST_SYNC_METHOD=ntpdate
}

start_ntp_service() {
    systemctl restart ntp.service 2>/dev/null || systemctl restart ntpd.service 2>/dev/null \
        || service ntp restart 2>/dev/null || service ntpd restart 2>/dev/null
}

sync_with_ntpd() {
    local attempt offset abs_offset
    command -v ntpq >/dev/null 2>&1 || return 1
    print_info "使用 ntpd 同步时间..."
    start_ntp_service || return 1
    for ((attempt=1; attempt<=SYNC_WAIT_ATTEMPTS; attempt++)); do
        if offset=$(ntpd_peer_offset); then
            abs_offset=$(absolute_decimal "$offset")
            if decimal_lte "$abs_offset" "$MAX_CLOCK_OFFSET_SECONDS"; then
                LAST_SYNC_METHOD=ntpd
                print_success "ntpd 已选中可信时间源，当前偏差约 ${offset} 秒"
                return 0
            fi
        fi
        sleep "$SYNC_WAIT_INTERVAL"
    done
    return 1
}

sync_manual_https() {
    local network_epoch
    print_info "尝试通过多个 HTTPS 来源校准时间..."
    network_epoch=$(trusted_https_epoch) || {
        print_warning "HTTPS 时间源未能通过 TLS、格式或多源一致性校验。"
        return 1
    }
    date -u -s "@$network_epoch" >/dev/null 2>&1 || return 1
    hwclock --systohc 2>/dev/null || true
    LAST_SYNC_METHOD=https-consensus
    print_success "已使用两个相互一致的 HTTPS 时间源校准系统时间"
}

install_sync_tools() {
    local reply
    [[ "$SCHEDULED_MODE" == false ]] || return 1
    print_warning "未检测到可正常同步的时间工具"
    read -r -p "是否要安装 chrony? (推荐) (y/n): " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]] || return 1
    print_info "正在安装 chrony..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y chrony
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y chrony
    elif command -v yum >/dev/null 2>&1; then
        yum install -y chrony
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm chrony
    else
        print_error "无法识别包管理器，请手动安装 chrony"
        return 1
    fi
    systemctl enable chrony.service 2>/dev/null || systemctl enable chronyd.service 2>/dev/null || true
}

verify_sync() {
    local offset abs_offset
    print_info "验证真实时钟偏差..."
    offset=$(measure_clock_offset) || {
        print_error "无法从 NTP 状态或严格 HTTPS 多源校验中取得时钟偏差。"
        return 1
    }
    abs_offset=$(absolute_decimal "$offset")
    if decimal_lte "$abs_offset" "$MAX_CLOCK_OFFSET_SECONDS"; then
        print_success "时间同步验证通过，偏差约 ${offset} 秒（允许值 ${MAX_CLOCK_OFFSET_SECONDS} 秒）"
        return 0
    fi
    print_error "时间偏差仍过大: ${offset} 秒（允许值 ${MAX_CLOCK_OFFSET_SECONDS} 秒）"
    return 1
}

restart_services() {
    print_info "检查并重启 ss-rust 和 shadowtls 服务..."
    if systemctl is-active --quiet ss-rust.service; then
        systemctl restart ss-rust.service
        print_success "ss-rust 服务已重启"
    fi
    if systemctl is-active --quiet shadowtls.service; then
        systemctl restart shadowtls.service
        print_success "shadowtls 服务已重启"
    fi
}

is_safe_absolute_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != */../* && "$1" != */.. ]]
}

atomic_install_file() {
    local source_file="$1" target_file="$2" mode="$3" target_dir temp_file
    target_dir=$(dirname -- "$target_file")
    install -d -m 755 "$target_dir" || return 1
    temp_file=$(mktemp "$target_dir/.sync-time.$(basename -- "$target_file").XXXXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

install_scheduled_sync() {
    local source_script="$1" stage_dir cron_stage logrotate_stage path
    for path in "$SYNC_TIME_INSTALL_PATH" "$SYNC_TIME_CRON_FILE" "$SYNC_TIME_LOG_DIR" "$SYNC_TIME_LOG_FILE" "$SYNC_TIME_LOGROTATE_FILE"; do
        is_safe_absolute_path "$path" || {
            print_error "拒绝不安全的定时任务路径: $path"
            return 1
        }
    done
    if [[ ! -r "$source_script" ]] || ! /bin/bash -n "$source_script"; then
        print_error "当前脚本不可读或语法检查失败，未安装定时任务。"
        return 1
    fi
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-scripts-sync-time.XXXXXXXX") || return 1
    cron_stage="$stage_dir/cron"
    logrotate_stage="$stage_dir/logrotate"
    printf '%s\n' \
        'SHELL=/bin/bash' \
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        "17 * * * * root /usr/bin/bash $SYNC_TIME_INSTALL_PATH --scheduled >> $SYNC_TIME_LOG_FILE 2>&1" \
        > "$cron_stage"
    printf '%s\n' \
        "$SYNC_TIME_LOG_FILE {" \
        '    weekly' \
        '    rotate 5' \
        '    size 1M' \
        '    compress' \
        '    delaycompress' \
        '    missingok' \
        '    notifempty' \
        '    create 0640 root root' \
        '}' > "$logrotate_stage"
    if command -v logrotate >/dev/null 2>&1 && ! logrotate -d "$logrotate_stage" >/dev/null 2>&1; then
        print_error "日志轮换配置验证失败，未安装定时任务。"
        rm -rf -- "$stage_dir"
        return 1
    fi
    install -d -m 750 "$SYNC_TIME_LOG_DIR" || { rm -rf -- "$stage_dir"; return 1; }
    if ! touch "$SYNC_TIME_LOG_FILE" || ! chmod 640 "$SYNC_TIME_LOG_FILE"; then
        rm -rf -- "$stage_dir"
        return 1
    fi
    if ! atomic_install_file "$source_script" "$SYNC_TIME_INSTALL_PATH" 755 \
        || ! atomic_install_file "$logrotate_stage" "$SYNC_TIME_LOGROTATE_FILE" 644 \
        || ! atomic_install_file "$cron_stage" "$SYNC_TIME_CRON_FILE" 644; then
        print_error "定时同步文件安装失败。"
        rm -rf -- "$stage_dir"
        return 1
    fi
    rm -rf -- "$stage_dir"
    print_success "定时同步已安装: $SYNC_TIME_CRON_FILE"
    print_info "固定脚本副本: $SYNC_TIME_INSTALL_PATH"
    print_info "日志及轮换配置: $SYNC_TIME_LOG_FILE / $SYNC_TIME_LOGROTATE_FILE"
}

offer_scheduled_sync() {
    local reply source_script
    read -r -p "是否安装每小时自动校时任务? (y/n): " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]] || return 0
    source_script=$(realpath -- "$0" 2>/dev/null || printf '%s' "$0")
    install_scheduled_sync "$source_script"
}

parse_arguments() {
    while (($#)); do
        case "$1" in
            --scheduled) SCHEDULED_MODE=true ;;
            -h|--help)
                echo "用法: $0 [--scheduled]"
                return 2
                ;;
            *)
                print_error "未知参数: $1"
                return 1
                ;;
        esac
        shift
    done
}

cleanup_time_services() {
    restore_time_services >/dev/null 2>&1 || true
}

main() {
    local reply parse_status=0
    parse_arguments "$@" || parse_status=$?
    ((parse_status == 0)) || {
        ((parse_status == 2)) && return 0
        return "$parse_status"
    }
    check_root || return 1
    validate_runtime_settings || return 1
    trap cleanup_time_services EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ "$SCHEDULED_MODE" == false ]]; then
        echo "======================================"
        echo "      时间同步脚本 / Time Sync       "
        echo "======================================"
        echo
        show_current_time
        set_timezone
        echo
    fi
    print_info "开始同步时间..."

    if sync_with_chrony \
        || sync_with_timesyncd \
        || sync_with_ntpdate \
        || sync_with_ntpd \
        || { install_sync_tools && sync_with_chrony; } \
        || sync_manual_https; then
        :
    else
        print_error "所有时间同步方法都失败了"
        print_info "请检查网络连接或手动安装 chrony/ntpdate"
        return 1
    fi

    verify_sync || return 1
    if [[ "$SCHEDULED_MODE" == false ]]; then
        echo
        show_current_time
        echo
        read -r -p "是否要重启 ss-rust 和 shadowtls 服务? (y/n): " -n 1 reply
        echo
        [[ "$reply" =~ ^[Yy]$ ]] && restart_services
        echo
        offer_scheduled_sync || return 1
    fi
    print_success "时间同步完成！使用方式: ${LAST_SYNC_METHOD:-未知}"
}

if [[ ${SYNC_TIME_SOURCE_ONLY:-0} != 1 ]]; then
    main "$@"
fi
