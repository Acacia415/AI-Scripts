#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/caddy-manager-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export CADDY_MANAGER_SOURCE_ONLY=1
export CADDY_CONFIG_DIR="$TEST_ROOT/etc/caddy"
export CADDYFILE="$CADDY_CONFIG_DIR/Caddyfile"
export CADDY_MANAGED_DIR="$CADDY_CONFIG_DIR/ai-scripts.d"
export CADDY_SERVICE=caddy-test.service
export CADDY_BACKUP_ROOT="$TEST_ROOT/backups"
export CADDY_BACKUP_KEEP=5
export CADDY_APT_KEY="$TEST_ROOT/usr/share/keyrings/caddy.gpg"
export CADDY_APT_SOURCE="$TEST_ROOT/etc/apt/sources.list.d/caddy.list"
export CADDY_SERVICE_FILE="$TEST_ROOT/lib/systemd/system/caddy.service"
export CADDY_DATA_DIR="$TEST_ROOT/var/lib/caddy"
export CADDY_TLS_DIR="$TEST_ROOT/etc/ssl/caddy"
export CADDY_LOG_DIR="$TEST_ROOT/var/log/caddy"

# shellcheck source=../caddy_manager.sh disable=SC1091
. "$REPO_DIR/caddy_manager.sh"

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
    if [[ ${1:-} == -d ]]; then
        shift
        if [[ ${1:-} == -m ]]; then
            mode=$2
            shift 2
        fi
        mkdir -p -- "$@"
        [[ -z ${mode:-} ]] || chmod "$mode" "$@" 2>/dev/null || true
    elif [[ ${1:-} == -m ]]; then
        mode=$2
        cp -- "$3" "$4"
        chmod "$mode" "$4" 2>/dev/null || true
    else
        command install "$@"
    fi
}

check_root() { :; }
clear() { :; }
sleep() { :; }

SERVICE_ACTIVE=true
SERVICE_ENABLED=true
FAIL_ACTIVATIONS=0
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
systemctl() {
    local action="${1:-}"
    shift || true
    printf '%s %s\n' "$action" "$*" >> "$SYSTEMCTL_LOG"
    case "$action" in
        is-active) [[ "$SERVICE_ACTIVE" == true ]] ;;
        is-enabled) [[ "$SERVICE_ENABLED" == true ]] ;;
        enable) SERVICE_ENABLED=true ;;
        disable) SERVICE_ENABLED=false ;;
        stop) SERVICE_ACTIVE=false ;;
        start)
            if ((FAIL_ACTIVATIONS > 0)); then
                FAIL_ACTIVATIONS=$((FAIL_ACTIVATIONS - 1))
                return 1
            fi
            SERVICE_ACTIVE=true
            ;;
        reload|restart)
            if ((FAIL_ACTIVATIONS > 0)); then
                FAIL_ACTIVATIONS=$((FAIL_ACTIVATIONS - 1))
                return 1
            fi
            SERVICE_ACTIVE=true
            ;;
        daemon-reload|status) return 0 ;;
        *) return 0 ;;
    esac
}

FAIL_VALIDATE_ONCE=0
CADDY_LOG="$TEST_ROOT/caddy.log"
caddy() {
    local action="${1:-}" config_file='' argument
    shift || true
    printf '%s %s\n' "$action" "$*" >> "$CADDY_LOG"
    case "$action" in
        version) printf 'v9.9.9-test\n' ;;
        fmt) return 0 ;;
        validate)
            while (($#)); do
                argument=$1
                shift
                if [[ "$argument" == --config && $# -gt 0 ]]; then
                    config_file=$1
                    shift
                fi
            done
            if ((FAIL_VALIDATE_ONCE > 0)); then
                FAIL_VALIDATE_ONCE=$((FAIL_VALIDATE_ONCE - 1))
                return 1
            fi
            [[ -f "$config_file" ]] || return 1
            grep -Fq INVALID "$config_file" && return 1
            if grep -Fxq "$CADDY_IMPORT_DIRECTIVE" "$config_file"; then
                local imported_file imported_dir
                imported_dir="$(dirname -- "$config_file")/ai-scripts.d"
                shopt -s nullglob
                for imported_file in "$imported_dir"/*.caddy; do
                    grep -Fq INVALID "$imported_file" && { shopt -u nullglob; return 1; }
                done
                shopt -u nullglob
            fi
            ;;
        *) return 0 ;;
    esac
}

APT_LOG="$TEST_ROOT/apt.log"
APT_PURGE_FAIL=0
apt-get() {
    printf '%s\n' "$*" >> "$APT_LOG"
    if [[ ${1:-} == purge && $APT_PURGE_FAIL -gt 0 ]]; then
        APT_PURGE_FAIL=$((APT_PURGE_FAIL - 1))
        return 1
    fi
}
journalctl() { printf '%s\n' "$*" >> "$TEST_ROOT/journal.log"; }

mkdir -p "$CADDY_CONFIG_DIR" "$CADDY_MANAGED_DIR"
ORIGINAL_MAIN=$'{\n\temail owner@example.net\n}\n\nforeign.example.net {\n\trespond "keep"\n}'
printf '%s\n' "$ORIGINAL_MAIN" > "$CADDYFILE"

# Strict input validation prevents directive, path, and command injection while
# retaining the original hostname, IPv4, and IPv6 upstream support.
for domain in example.com sub-domain.example.com xn--fiqs8s.example; do
    is_valid_domain "$domain" || fail "valid domain rejected: $domain"
done
for domain in localhost bad..example.com '-x.example.com' 'bad;id.example'; do
    if is_valid_domain "$domain"; then fail "invalid domain accepted: $domain"; fi
done
for host in localhost backend.internal 127.0.0.1 255.255.255.255 2001:db8::1 ::1 1:2:3:4:5:6:7:8; do
    is_valid_upstream_host "$host" || fail "valid upstream rejected: $host"
done
for host in 'backend;id' 999.1.1.1 01.2.3.4 1::2::3 '2001:db8:::1' 'http://backend'; do
    if is_valid_upstream_host "$host"; then fail "invalid upstream accepted: $host"; fi
done
assert_eq '[2001:db8::1]:8443' "$(format_upstream 2001:db8::1 8443)" 'IPv6 upstream formatting'
for port in 1 443 65535; do is_valid_port "$port" || fail "valid port rejected: $port"; done
for port in 0 65536 -1 1.5 '443;id'; do
    if is_valid_port "$port"; then fail "invalid port accepted: $port"; fi
done

# A new site is validated in a staged config tree, then atomically installed.
configure_site_transaction app.example.com 127.0.0.1 8080 false >/dev/null || fail 'initial site configuration failed'
assert_file_contains "$CADDYFILE" "$ORIGINAL_MAIN"
assert_file_contains "$CADDYFILE" "$CADDY_IMPORT_MARKER"
assert_file_contains "$CADDYFILE" "$CADDY_IMPORT_DIRECTIVE"
assert_file_contains "$CADDY_MANAGED_DIR/app.example.com.caddy" "$CADDY_SITE_MARKER"
assert_file_contains "$CADDY_MANAGED_DIR/app.example.com.caddy" 'reverse_proxy 127.0.0.1:8080'
EXPECTED_MAIN="$ORIGINAL_MAIN"$'\n\n'"$CADDY_IMPORT_MARKER"$'\n'"$CADDY_IMPORT_DIRECTIVE"
assert_eq "$EXPECTED_MAIN" "$(< "$CADDYFILE")" 'successful setup reformatted user Caddyfile'
import_count=$(grep -Fxc "$CADDY_IMPORT_DIRECTIVE" "$CADDYFILE")
assert_eq 1 "$import_count" 'managed import count'

# Overwrite changes only that domain's managed file and never converts the main
# Caddyfile to JSON or parses it with a brace-counting awk expression.
configure_site_transaction app.example.com backend.internal 9090 true >/dev/null || fail 'managed overwrite failed'
assert_file_contains "$CADDY_MANAGED_DIR/app.example.com.caddy" 'reverse_proxy backend.internal:9090'
assert_file_contains "$CADDYFILE" 'foreign.example.net {'
import_count=$(grep -Fxc "$CADDY_IMPORT_DIRECTIVE" "$CADDYFILE")
assert_eq 1 "$import_count" 'overwrite duplicated managed import'

# Staged validation failure leaves both the main file and old site byte-for-byte.
MAIN_BEFORE=$(< "$CADDYFILE")
SITE_BEFORE=$(< "$CADDY_MANAGED_DIR/app.example.com.caddy")
FAIL_VALIDATE_ONCE=1
if configure_site_transaction app.example.com 127.0.0.1 10000 true >/dev/null; then
    fail 'staged validation failure was ignored'
fi
assert_eq "$MAIN_BEFORE" "$(< "$CADDYFILE")" 'staged failure changed main Caddyfile'
assert_eq "$SITE_BEFORE" "$(< "$CADDY_MANAGED_DIR/app.example.com.caddy")" 'staged failure changed site'

# Reload and restart failure after installation restores exact files and prior
# active/enabled service state from the transaction backup.
FAIL_ACTIVATIONS=1
SERVICE_ACTIVE=true
SERVICE_ENABLED=true
if configure_site_transaction app.example.com 127.0.0.1 11000 true >/dev/null; then
    fail 'activation failure was ignored'
fi
assert_eq "$MAIN_BEFORE" "$(< "$CADDYFILE")" 'activation rollback changed main Caddyfile'
assert_eq "$SITE_BEFORE" "$(< "$CADDY_MANAGED_DIR/app.example.com.caddy")" 'activation rollback changed site'
assert_eq true "$SERVICE_ACTIVE" 'activation rollback changed active state'
assert_eq true "$SERVICE_ENABLED" 'activation rollback changed enabled state'

# An unmarked file at the dedicated domain path is never claimed or overwritten.
printf 'foreign dedicated config\n' > "$CADDY_MANAGED_DIR/blocked.example.com.caddy"
BLOCKED_BEFORE=$(< "$CADDY_MANAGED_DIR/blocked.example.com.caddy")
if configure_site_transaction blocked.example.com localhost 8080 true >/dev/null; then
    fail 'foreign dedicated file was overwritten'
fi
assert_eq "$BLOCKED_BEFORE" "$(< "$CADDY_MANAGED_DIR/blocked.example.com.caddy")" 'foreign dedicated file changed'

# Transaction backups are bounded to five.
for index in 1 2 3 4 5 6 7; do
    create_site_transaction "retention-$index.example.com" retention >/dev/null
done
backup_count=$(find "$CADDY_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' | wc -l | tr -d '[:space:]')
assert_eq 5 "$backup_count" 'transaction backup retention'

# Managed cleanup also rolls back on activation failure.
CLEANUP_MAIN_BEFORE=$(< "$CADDYFILE")
CLEANUP_SITE_BEFORE=$(< "$CADDY_MANAGED_DIR/app.example.com.caddy")
FAIL_ACTIVATIONS=1
if remove_managed_caddy_assets <<< $'y\n' >/dev/null; then
    fail 'cleanup activation failure was ignored'
fi
assert_eq "$CLEANUP_MAIN_BEFORE" "$(< "$CADDYFILE")" 'failed cleanup changed main Caddyfile'
assert_eq "$CLEANUP_SITE_BEFORE" "$(< "$CADDY_MANAGED_DIR/app.example.com.caddy")" 'failed cleanup did not restore site'

# Successful cleanup removes only marked sites. A foreign file in the imported
# directory is preserved, so the import remains to keep that configuration live.
remove_managed_caddy_assets <<< $'y\n' >/dev/null || fail 'managed cleanup failed'
[[ ! -e "$CADDY_MANAGED_DIR/app.example.com.caddy" ]] || fail 'managed site was not removed'
assert_file_contains "$CADDY_MANAGED_DIR/blocked.example.com.caddy" 'foreign dedicated config'
assert_file_contains "$CADDYFILE" "$CADDY_IMPORT_DIRECTIVE"
assert_file_contains "$CADDYFILE" 'foreign.example.net {'

# With no foreign imported file remaining, cleanup removes its own import pair
# while preserving every user-authored byte outside that pair.
rm -f -- "$CADDY_MANAGED_DIR/blocked.example.com.caddy"
configure_site_transaction final.example.com localhost 8081 false >/dev/null || fail 'final managed site setup failed'
remove_managed_caddy_assets <<< $'y\n' >/dev/null || fail 'final managed cleanup failed'
[[ ! -e "$CADDY_MANAGED_DIR/final.example.com.caddy" ]] || fail 'final managed site was not removed'
assert_file_not_contains "$CADDYFILE" "$CADDY_IMPORT_MARKER"
assert_file_not_contains "$CADDYFILE" "$CADDY_IMPORT_DIRECTIVE"
assert_file_contains "$CADDYFILE" 'foreign.example.net {'

# Full uninstall has a separate strong confirmation. Its backup contains Caddy
# data, while deletion remains limited to explicit Caddy paths and logs.
mkdir -p "$CADDY_DATA_DIR" "$CADDY_TLS_DIR" "$CADDY_LOG_DIR" \
    "$(dirname -- "$CADDY_APT_KEY")" "$(dirname -- "$CADDY_APT_SOURCE")" "$(dirname -- "$CADDY_SERVICE_FILE")"
printf 'data\n' > "$CADDY_DATA_DIR/data.txt"
printf 'tls\n' > "$CADDY_TLS_DIR/tls.txt"
printf 'log\n' > "$CADDY_LOG_DIR/access.log"
printf 'key\n' > "$CADDY_APT_KEY"
printf 'deb test\n' > "$CADDY_APT_SOURCE"
printf 'service\n' > "$CADDY_SERVICE_FILE"
printf 'outside\n' > "$TEST_ROOT/outside.txt"
: > "$APT_LOG"
APT_PURGE_FAIL=1
if full_uninstall_caddy <<< $'PURGE-CADDY\ny\n' >/dev/null; then
    fail 'package purge failure was ignored'
fi
[[ -d "$CADDY_CONFIG_DIR" && -d "$CADDY_DATA_DIR" ]] || fail 'purge failure deleted Caddy directories'
assert_file_contains "$CADDYFILE" 'foreign.example.net {'

full_uninstall_caddy <<< $'PURGE-CADDY\ny\n' >/dev/null || fail 'strong-confirmed full uninstall failed'
[[ ! -e "$CADDY_CONFIG_DIR" ]] || fail 'full uninstall left Caddy config directory'
[[ ! -e "$CADDY_DATA_DIR" ]] || fail 'full uninstall left Caddy data directory'
[[ ! -e "$CADDY_LOG_DIR" ]] || fail 'full uninstall left Caddy log directory'
assert_file_contains "$TEST_ROOT/outside.txt" 'outside'
assert_file_contains "$APT_LOG" 'purge -y caddy'
assert_file_not_contains "$APT_LOG" 'autoremove'
full_backup=$(find "$CADDY_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'full-uninstall.*' | head -n 1)
[[ -n "$full_backup" ]] || fail 'full-uninstall backup was not created'
assert_file_contains "$full_backup/config/Caddyfile" 'foreign.example.net {'
assert_file_contains "$full_backup/data/data.txt" 'data'
assert_file_contains "$full_backup/logs/access.log" 'log'

# Menu exit is successful when launched by tool.sh.
caddy_main <<< $'0\n' >/dev/null || fail 'menu option 0 returned failure'

# Static A16 safety boundaries.
assert_file_contains "$REPO_DIR/caddy_manager.sh" 'import ai-scripts.d/*.caddy'
assert_file_contains "$REPO_DIR/caddy_manager.sh" 'caddy validate --config "$stage_root/Caddyfile"'
assert_file_contains "$REPO_DIR/caddy_manager.sh" 'CADDY_MANAGER_SOURCE_ONLY'
assert_file_not_contains "$REPO_DIR/caddy_manager.sh" 'caddy adapt'
assert_file_not_contains "$REPO_DIR/caddy_manager.sh" 'journalctl --vacuum'
assert_file_not_contains "$REPO_DIR/caddy_manager.sh" 'config_apt_source'
assert_file_not_contains "$REPO_DIR/caddy_manager.sh" 'apt-get autoremove'

printf 'PASS: caddy_manager.sh A16 regression tests\n'
