#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fail2ban-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export FAIL2BAN_SOURCE_ONLY=1
export FAIL2BAN_CONFIG_DIR="$TEST_ROOT/etc/fail2ban"
export FAIL2BAN_MANAGED_FILE="$TEST_ROOT/etc/fail2ban/jail.d/ai-scripts-sshd.local"
export FAIL2BAN_BACKUP_ROOT="$TEST_ROOT/backups"
export FAIL2BAN_BACKUP_KEEP=5
export FAIL2BAN_SERVICE=fail2ban-test.service
export FAIL2BAN_STABLE_ATTEMPTS=2
export FAIL2BAN_STABLE_INTERVAL=0
export FAIL2BAN_PYTHON_BIN="${FAIL2BAN_TEST_PYTHON:-python3}"

# shellcheck source=../install_fail2ban.sh disable=SC1091
. "$REPO_DIR/install_fail2ban.sh"

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

sleep() { :; }

SERVICE_ACTIVE=true
SERVICE_ENABLED=true
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
systemctl() {
    local action="$1" unit="${2:-}"
    [[ "$action" =~ ^is-(active|enabled)$ && "$unit" == --quiet ]] && unit="${3:-}"
    printf '%s %s\n' "$action" "$unit" >> "$SYSTEMCTL_LOG"
    case "$action" in
        is-active) [[ "$SERVICE_ACTIVE" == true ]] ;;
        is-enabled) [[ "$SERVICE_ENABLED" == true ]] ;;
        enable) SERVICE_ENABLED=true ;;
        disable) SERVICE_ENABLED=false ;;
        start|restart) SERVICE_ACTIVE=true ;;
        stop) SERVICE_ACTIVE=false ;;
        *) return 0 ;;
    esac
}

FAIL_TEST_ONCE=0
PING_OK=true
CLIENT_LOG="$TEST_ROOT/client.log"
fail2ban-client() {
    printf '%s\n' "$*" >> "$CLIENT_LOG"
    case "${1:-}" in
        -t)
            if ((FAIL_TEST_ONCE > 0)); then
                FAIL_TEST_ONCE=$((FAIL_TEST_ONCE - 1))
                return 1
            fi
            ;;
        ping)
            [[ "$PING_OK" == true ]] || return 1
            printf 'Server replied: pong\n'
            ;;
        status) return 0 ;;
        set) return 0 ;;
    esac
}

# Numeric and IP inputs are strictly bounded and canonicalized.
validate_integer_range 1 1 100
validate_integer_range 100 1 100
for invalid in 0 -1 1.5 '5;reboot' 999999999999999999999; do
    if validate_integer_range "$invalid" 1 1000; then fail "invalid integer accepted: $invalid"; fi
done
assert_eq '192.0.2.1' "$(normalize_ip_token 192.0.2.1)" "IPv4 normalization"
assert_eq '192.0.2.0/24' "$(normalize_ip_token 192.0.2.9/24)" "IPv4 CIDR normalization"
assert_eq '2001:db8::1' "$(normalize_ip_token 2001:db8::1)" "IPv6 normalization"
assert_eq '127.0.0.0/8 ::1 192.0.2.1' "$(normalize_ip_list '127.0.0.1/8 ::1 192.0.2.1 192.0.2.1')" "IP list normalization and deduplication"
for invalid_ip in 999.1.1.1 '192.0.2.1;reboot' '2001:::1' 'example.com'; do
    if normalize_ip_token "$invalid_ip" >/dev/null; then fail "invalid IP accepted: $invalid_ip"; fi
done
if validate_single_ip 192.0.2.0/24 >/dev/null; then fail "CIDR accepted for ban/unban operation"; fi

# The generated configuration owns only the sshd jail and never writes global
# DEFAULT values that would change unrelated jails.
mkdir -p "$FAIL2BAN_CONFIG_DIR/jail.d"
printf '[custom-app]\nenabled = true\n' > "$FAIL2BAN_CONFIG_DIR/jail.local"
USER_JAIL_BEFORE=$(< "$FAIL2BAN_CONFIG_DIR/jail.local")
stage_one="$TEST_ROOT/stage-one.local"
write_managed_config "$stage_one" 600 600 5 '127.0.0.0/8 ::1'
assert_file_contains "$stage_one" "$MANAGED_MARKER"
assert_file_contains "$stage_one" '[sshd]'
assert_file_not_contains "$stage_one" '[DEFAULT]'
assert_file_not_contains "$stage_one" '[custom-app]'

# Successful apply tests the complete configuration and waits for both daemon
# ping and sshd jail status, while preserving the user's jail.local byte-for-byte.
: > "$CLIENT_LOG"
: > "$SYSTEMCTL_LOG"
backup_dir=$(create_transaction_backup apply-success)
apply_managed_config "$stage_one" "$backup_dir" >/dev/null || fail "valid managed config failed to apply"
is_owned_managed_file || fail "installed managed file is missing ownership marker"
assert_eq "$USER_JAIL_BEFORE" "$(< "$FAIL2BAN_CONFIG_DIR/jail.local")" "user jail.local was modified"
assert_file_contains "$CLIENT_LOG" '-t'
assert_file_contains "$CLIENT_LOG" 'ping'
assert_file_contains "$CLIENT_LOG" 'status sshd'

# Whitelist changes rewrite only the owned file and use the same tested,
# transactional activation path.
add_whitelist_ips <<< $'198.51.100.7 2001:db8::7\n' >/dev/null || fail "valid whitelist update failed"
assert_file_contains "$FAIL2BAN_MANAGED_FILE" 'ignoreip = 127.0.0.0/8 ::1 198.51.100.7 2001:db8::7'
assert_eq "$USER_JAIL_BEFORE" "$(< "$FAIL2BAN_CONFIG_DIR/jail.local")" "whitelist update changed user jail.local"
before_invalid_whitelist=$(< "$FAIL2BAN_MANAGED_FILE")
if add_whitelist_ips <<< $'198.51.100.7;reboot\n' >/dev/null; then
    fail "invalid whitelist update was accepted"
fi
assert_eq "$before_invalid_whitelist" "$(< "$FAIL2BAN_MANAGED_FILE")" "invalid whitelist input changed managed config"

# A configuration-test failure restores the previous managed file and exact
# service active/enabled state.
OLD_MANAGED=$(< "$FAIL2BAN_MANAGED_FILE")
stage_two="$TEST_ROOT/stage-two.local"
write_managed_config "$stage_two" 1200 300 8 '127.0.0.0/8 ::1 192.0.2.1'
SERVICE_ACTIVE=false
SERVICE_ENABLED=false
backup_dir=$(create_transaction_backup apply-test-failure)
FAIL_TEST_ONCE=1
if apply_managed_config "$stage_two" "$backup_dir" >/dev/null; then
    fail "injected fail2ban-client -t failure was ignored"
fi
assert_eq "$OLD_MANAGED" "$(< "$FAIL2BAN_MANAGED_FILE")" "config-test failure did not restore managed file"
assert_eq false "$SERVICE_ACTIVE" "rollback changed prior inactive service state"
assert_eq false "$SERVICE_ENABLED" "rollback changed prior disabled service state"

# A daemon that restarts but never becomes stable is also rolled back.
SERVICE_ACTIVE=true
SERVICE_ENABLED=true
backup_dir=$(create_transaction_backup apply-stability-failure)
PING_OK=false
if apply_managed_config "$stage_two" "$backup_dir" >/dev/null; then
    fail "unstable Fail2Ban service was accepted"
fi
PING_OK=true
assert_eq "$OLD_MANAGED" "$(< "$FAIL2BAN_MANAGED_FILE")" "stability failure did not restore managed file"

# Default removal deletes only the owned file, validates the remaining global
# configuration, and leaves software/other jails untouched.
: > "$CLIENT_LOG"
remove_managed_config <<< $'y\n\n' >/dev/null || fail "managed-only removal failed"
[[ ! -e "$FAIL2BAN_MANAGED_FILE" ]] || fail "managed file was not removed"
assert_eq "$USER_JAIL_BEFORE" "$(< "$FAIL2BAN_CONFIG_DIR/jail.local")" "managed removal changed user jail.local"
assert_file_contains "$CLIENT_LOG" '-t'

# A file at the dedicated path without the ownership marker is never claimed.
mkdir -p "$(dirname -- "$FAIL2BAN_MANAGED_FILE")"
printf '[sshd]\nenabled = false\n' > "$FAIL2BAN_MANAGED_FILE"
if is_owned_managed_file; then fail "unmarked dedicated file was claimed as owned"; fi

# Transaction backups are private and bounded.
rm -f "$FAIL2BAN_MANAGED_FILE"
for backup_index in 1 2 3 4 5 6 7; do
    create_transaction_backup "retention-$backup_index" >/dev/null
done
backup_count=$(find "$FAIL2BAN_BACKUP_ROOT" -maxdepth 1 -type d -name 'transaction.*' | wc -l | tr -d '[:space:]')
assert_eq 5 "$backup_count" "transaction backup retention"

# Full uninstall is a separate strong-confirmation path. It backs up every jail,
# purges only Fail2Ban (no autoremove), and then removes the sandbox config tree.
mkdir -p "$FAIL2BAN_CONFIG_DIR/jail.d"
printf '[custom-app]\nenabled = true\n' > "$FAIL2BAN_CONFIG_DIR/jail.d/custom.local"
APT_LOG="$TEST_ROOT/apt.log"
apt-get() { printf '%s\n' "$*" >> "$APT_LOG"; return 0; }
dpkg-query() { printf 'install ok installed 9.9.9\n'; }
: > "$APT_LOG"
full_uninstall_fail2ban <<< $'PURGE-FAIL2BAN\n\n' >/dev/null || fail "confirmed full uninstall failed"
[[ ! -e "$FAIL2BAN_CONFIG_DIR" ]] || fail "confirmed full uninstall left config directory"
assert_file_contains "$APT_LOG" 'purge -y fail2ban'
assert_file_not_contains "$APT_LOG" 'autoremove'
full_backup=$(find "$FAIL2BAN_BACKUP_ROOT" -maxdepth 1 -type d -name 'full-uninstall.*' | head -n 1)
[[ -n "$full_backup" ]] || fail "full uninstall backup was not created"
assert_file_contains "$full_backup/fail2ban/jail.d/custom.local" '[custom-app]'

# Static regression checks for A14 ownership and safety boundaries.
assert_file_contains "$REPO_DIR/install_fail2ban.sh" 'jail.d/ai-scripts-sshd.local'
assert_file_contains "$REPO_DIR/install_fail2ban.sh" 'fail2ban-client -t'
assert_file_contains "$REPO_DIR/install_fail2ban.sh" 'PURGE-FAIL2BAN'
assert_file_contains "$REPO_DIR/install_fail2ban.sh" 'FAIL2BAN_SOURCE_ONLY'
assert_file_not_contains "$REPO_DIR/install_fail2ban.sh" 'apt-get autoremove'
assert_file_not_contains "$REPO_DIR/install_fail2ban.sh" 'tee /etc/fail2ban/jail.local'
assert_file_not_contains "$REPO_DIR/install_fail2ban.sh" 'sudo rm -rf /etc/fail2ban'

printf 'PASS: install_fail2ban.sh A14 regression tests\n'
