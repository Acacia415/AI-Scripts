#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-time-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export SYNC_TIME_SOURCE_ONLY=1
export SYNC_TIME_MAX_OFFSET_SECONDS=5
export SYNC_TIME_HTTPS_CONSENSUS_SECONDS=10
export SYNC_TIME_CHRONY_WAIT_ATTEMPTS=2
export SYNC_TIME_WAIT_ATTEMPTS=2
export SYNC_TIME_WAIT_INTERVAL=0
export SYNC_TIME_INSTALL_PATH="$TEST_ROOT/usr/local/lib/ai-scripts/sync-time.sh"
export SYNC_TIME_CRON_FILE="$TEST_ROOT/etc/cron.d/ai-scripts-sync-time"
export SYNC_TIME_LOG_DIR="$TEST_ROOT/var/log/ai-scripts"
export SYNC_TIME_LOG_FILE="$TEST_ROOT/var/log/ai-scripts/sync-time.log"
export SYNC_TIME_LOGROTATE_FILE="$TEST_ROOT/etc/logrotate.d/ai-scripts-sync-time"

# shellcheck source=../sync-time.sh disable=SC1091
. "$REPO_DIR/sync-time.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="${3:-values differ}"
    [[ "$actual" == "$expected" ]] || fail "$message: expected [$expected], got [$actual]"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
    if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi
}

sleep() { :; }

# Duration parsing supports the units emitted by timedatectl.
assert_eq 0.250000000 "$(duration_to_seconds +250ms)" "millisecond conversion"
assert_eq -0.000125000 "$(duration_to_seconds -125us)" "microsecond conversion"
if duration_to_seconds 'unknown'; then fail "invalid duration was accepted"; fi

# A successful timesync-status command is not synchronization. Only the
# NTPSynchronized property can establish the daemon's real state.
TIMESYNC_STATE=no
TIMESYNC_OFFSET='+250ms'
timedatectl() {
    case "$*" in
        'set-ntp true') return 0 ;;
        'show -p NTPSynchronized --value') printf '%s\n' "$TIMESYNC_STATE" ;;
        'timesync-status --no-pager') printf 'Server: 192.0.2.1\nOffset: %s\n' "$TIMESYNC_OFFSET" ;;
        *) return 1 ;;
    esac
}
systemctl() { return 0; }
if sync_with_timesyncd >/dev/null; then
    fail "timesyncd command success was mistaken for synchronized state"
fi
TIMESYNC_STATE=yes
sync_with_timesyncd >/dev/null || fail "synchronized timesyncd state was rejected"
assert_eq systemd-timesyncd "$LAST_SYNC_METHOD" "timesyncd method marker"
TIMESYNC_OFFSET='+6s'
if sync_with_timesyncd >/dev/null; then fail "timesyncd offset over limit was accepted"; fi

# Chrony must report a normal leap state, a valid stratum, and a bounded
# correction after waitsync.
CHRONY_LEAP=Normal
chronyc() {
    case "$*" in
        '-a makestep'|'waitsync 2 5') return 0 ;;
        tracking)
            printf 'Reference ID    : C0000201\nStratum         : 3\nSystem time     : 0.125 seconds slow of NTP time\nLeap status     : %s\n' "$CHRONY_LEAP"
            ;;
        *) return 1 ;;
    esac
}
service() { return 1; }
sync_with_chrony >/dev/null || fail "valid Chrony tracking state was rejected"
CHRONY_LEAP='Not synchronised'
if sync_with_chrony >/dev/null; then fail "unsynchronized Chrony state was accepted"; fi

# ntpdate temporarily stops only services that were active and restores the
# exact active/inactive state after both failure and success.
declare -A SERVICE_STATE=(
    [systemd-timesyncd.service]=active
    [chrony.service]=inactive
    [chronyd.service]=inactive
    [ntp.service]=inactive
    [ntpd.service]=active
)
SERVICE_LOG="$TEST_ROOT/services.log"
NTPDATE_MODE=fail
systemctl() {
    local action="$1" unit="${2:-}"
    [[ "$action" == is-active && "$unit" == --quiet ]] && unit="${3:-}"
    case "$action" in
        is-active) [[ "${SERVICE_STATE[$unit]:-inactive}" == active ]] ;;
        stop) SERVICE_STATE["$unit"]=inactive; printf 'stop %s\n' "$unit" >> "$SERVICE_LOG" ;;
        start) SERVICE_STATE["$unit"]=active; printf 'start %s\n' "$unit" >> "$SERVICE_LOG" ;;
        *) return 0 ;;
    esac
}
timeout() { shift; "$@"; }
ntpdate() {
    [[ "$1" == -u ]] || return 1
    [[ "$NTPDATE_MODE" == success ]]
}
hwclock() { :; }
: > "$SERVICE_LOG"
if sync_with_ntpdate >/dev/null; then fail "all-failed ntpdate run reported success"; fi
assert_eq active "${SERVICE_STATE[systemd-timesyncd.service]}" "timesyncd was not restored after failure"
assert_eq active "${SERVICE_STATE[ntpd.service]}" "ntpd was not restored after failure"
assert_eq inactive "${SERVICE_STATE[chrony.service]}" "inactive Chrony was incorrectly started"
assert_file_contains "$SERVICE_LOG" 'stop systemd-timesyncd.service'
assert_file_contains "$SERVICE_LOG" 'start systemd-timesyncd.service'
NTPDATE_MODE=success
: > "$SERVICE_LOG"
sync_with_ntpdate >/dev/null || fail "successful ntpdate run failed"
assert_eq active "${SERVICE_STATE[systemd-timesyncd.service]}" "timesyncd was not restored after success"
assert_eq active "${SERVICE_STATE[ntpd.service]}" "ntpd was not restored after success"
assert_eq ntpdate "$LAST_SYNC_METHOD" "ntpdate method marker"

# HTTPS fallback requires strict TLS options, valid RFC 7231 Date headers, and
# agreement between at least two independent origins before setting the clock.
CURL_MODE=consensus
CURL_LOG="$TEST_ROOT/curl.log"
DATE_SET_LOG="$TEST_ROOT/date-set.log"
curl() {
    local url="${*: -1}"
    printf '%s\n' "$*" >> "$CURL_LOG"
    case "$CURL_MODE:$url" in
        consensus:https://www.cloudflare.com/) printf 'HTTP/2 200\r\nDate: Wed, 26 Aug 2026 03:00:00 GMT\r\n\r\n' ;;
        consensus:https://www.google.com/generate_204) printf 'HTTP/2 204\r\nDate: Wed, 26 Aug 2026 03:00:04 GMT\r\n\r\n' ;;
        consensus:https://github.com/) printf 'HTTP/2 200\r\nDate: Wed, 26 Aug 2026 03:02:00 GMT\r\n\r\n' ;;
        *) return 1 ;;
    esac
}
date() {
    if [[ "$*" == '-u -s @'* ]]; then
        printf '%s\n' "$*" >> "$DATE_SET_LOG"
        return 0
    fi
    command date "$@"
}
: > "$CURL_LOG"
: > "$DATE_SET_LOG"
sync_manual_https >/dev/null || fail "valid two-source HTTPS consensus was rejected"
assert_file_contains "$CURL_LOG" '--proto =https'
assert_file_contains "$CURL_LOG" '--tlsv1.2'
assert_file_contains "$DATE_SET_LOG" '-u -s @'
CURL_MODE=no-consensus
: > "$DATE_SET_LOG"
if sync_manual_https >/dev/null; then fail "single/unavailable HTTPS source was accepted"; fi
[[ ! -s "$DATE_SET_LOG" ]] || fail "clock was set without HTTPS source consensus"

# Verification is based on a measured offset and fails closed when it remains
# above the configured threshold.
measure_clock_offset() { printf '6.25\n'; }
if verify_sync >/dev/null; then fail "oversized measured clock offset was accepted"; fi
measure_clock_offset() { printf -- '-0.25\n'; }
verify_sync >/dev/null || fail "small measured clock offset was rejected"

# The cron entry points at an installed fixed copy, never at the temporary file
# that the toolbox deletes. Its dedicated log has bounded rotation.
downloaded_script="$TEST_ROOT/ai-scripts-download.random.sh"
cp "$REPO_DIR/sync-time.sh" "$downloaded_script"
logrotate() { [[ "$1" == -d && -f "$2" ]]; }
install() {
    local mode
    if [[ "$1" == -d && "$2" == -m ]]; then
        mode="$3"
        mkdir -p -- "$4"
        chmod "$mode" "$4"
    elif [[ "$1" == -m ]]; then
        mode="$2"
        cp -- "$3" "$4"
        chmod "$mode" "$4"
    else
        command install "$@"
    fi
}
install_scheduled_sync "$downloaded_script" >/dev/null || fail "scheduled sync installation failed"
[[ -x "$SYNC_TIME_INSTALL_PATH" ]] || fail "fixed script copy is not executable"
assert_file_contains "$SYNC_TIME_CRON_FILE" "$SYNC_TIME_INSTALL_PATH --scheduled"
assert_file_contains "$SYNC_TIME_CRON_FILE" ">> $SYNC_TIME_LOG_FILE 2>&1"
assert_file_not_contains "$SYNC_TIME_CRON_FILE" "$downloaded_script"
assert_file_contains "$SYNC_TIME_LOGROTATE_FILE" 'rotate 5'
assert_file_contains "$SYNC_TIME_LOGROTATE_FILE" 'size 1M'
assert_file_contains "$SYNC_TIME_LOGROTATE_FILE" 'create 0640 root root'
if [[ "$OSTYPE" != msys* ]]; then
    assert_eq 644 "$(stat -c '%a' "$SYNC_TIME_CRON_FILE")" "cron file mode"
    assert_eq 640 "$(stat -c '%a' "$SYNC_TIME_LOG_FILE")" "log file mode"
fi
assert_file_contains "$REPO_DIR/sync-time.sh" "chmod 640 \"\$SYNC_TIME_LOG_FILE\""

# Scheduled mode is non-interactive and legacy insecure/time-limited cron advice
# is gone from the source.
SCHEDULED_MODE=false
parse_arguments --scheduled
assert_eq true "$SCHEDULED_MODE" "scheduled argument"
assert_file_not_contains "$REPO_DIR/sync-time.sh" 'http://'
assert_file_not_contains "$REPO_DIR/sync-time.sh" "realpath \$0"
assert_file_contains "$REPO_DIR/sync-time.sh" 'NTPSynchronized'
assert_file_contains "$REPO_DIR/sync-time.sh" 'SYNC_TIME_SOURCE_ONLY'

printf 'PASS: sync-time.sh A13 regression tests\n'
