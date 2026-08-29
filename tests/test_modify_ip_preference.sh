#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ip-preference-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export IP_PREFERENCE_SOURCE_ONLY=1
export IP_PREFERENCE_CONF_FILE="$TEST_ROOT/etc/gai.conf"
export IP_PREFERENCE_STATE_DIR="$TEST_ROOT/state"
export IP_PREFERENCE_SYSCTL_DISABLE_FILE="$TEST_ROOT/etc/sysctl.d/99-ai-scripts-disable-ipv6.conf"
export IP_PREFERENCE_SYSCTL_AUTOCONF_FILE="$TEST_ROOT/etc/sysctl.d/98-ai-scripts-ipv6-autoconf.conf"
export IP_PREFERENCE_LEGACY_DISABLE_FILE="$TEST_ROOT/etc/sysctl.d/99-disable-ipv6.conf"
export IP_PREFERENCE_LEGACY_AUTOCONF_FILE="$TEST_ROOT/etc/sysctl.d/98-ipv6-autoconfig.conf"

# shellcheck source=../modify_ip_preference.sh
. "$REPO_DIR/modify_ip_preference.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        fail "$1 unexpectedly contains: $2"
    fi
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"
}

mkdir -p "$(dirname "$CONF_FILE")"
cat > "$CONF_FILE" <<'EOF'
# cloud vendor policy
label 2001:db8::/32 42
precedence 2001:db8::/32 60
EOF
original_content=$(<"$CONF_FILE")

# Preference changes use one managed block, preserve all user lines, and never
# overwrite the first original backup on later updates.
apply_ipv4_preference
assert_contains "$CONF_FILE" "$GAI_BEGIN"
assert_contains "$CONF_FILE" 'precedence ::ffff:0:0/96 100'
assert_contains "$CONF_FILE" '# cloud vendor policy'
assert_eq "$(<"$GAI_ORIGINAL_BACKUP")" "$original_content"
printf '# user added after first run\n' >> "$CONF_FILE"
apply_ipv6_preference
[[ $(grep -Fxc "$GAI_BEGIN" "$CONF_FILE") == 1 ]] || fail 'managed gai block was duplicated'
assert_contains "$CONF_FILE" 'precedence ::ffff:0:0/96 10'
assert_not_contains "$CONF_FILE" 'precedence ::ffff:0:0/96 100'
assert_contains "$CONF_FILE" '# user added after first run'
assert_eq "$(<"$GAI_ORIGINAL_BACKUP")" "$original_content"
restore_default_preference
assert_not_contains "$CONF_FILE" "$GAI_BEGIN"
assert_contains "$CONF_FILE" '# cloud vendor policy'
assert_contains "$CONF_FILE" '# user added after first run'

# A malformed marker is refused without replacing the user's file.
cat > "$CONF_FILE" <<EOF
user-setting
$GAI_BEGIN
precedence ::ffff:0:0/96 100
EOF
malformed_before=$(<"$CONF_FILE")
if apply_ipv4_preference; then fail 'malformed managed block was accepted'; fi
assert_eq "$(<"$CONF_FILE")" "$malformed_before"

declare -A SYSCTL_VALUES=(
    [net.ipv6.conf.all.disable_ipv6]=0
    [net.ipv6.conf.default.disable_ipv6]=0
    [net.ipv6.conf.lo.disable_ipv6]=0
    [net.ipv6.conf.all.forwarding]=1
    [net.ipv6.conf.eth0.autoconf]=0
    [net.ipv6.conf.eth0.accept_ra]=0
)
sysctl_log="$TEST_ROOT/sysctl.log"
sysctl_mode=ok
sysctl() {
    local key value config line
    printf 'sysctl %s\n' "$*" >> "$sysctl_log"
    case "${1:-}" in
        -n)
            key="$2"
            [[ -n "${SYSCTL_VALUES[$key]+x}" ]] || return 1
            printf '%s\n' "${SYSCTL_VALUES[$key]}"
            ;;
        -w)
            key="${2%%=*}"
            value="${2#*=}"
            SYSCTL_VALUES["$key"]="$value"
            ;;
        -p)
            [[ "$sysctl_mode" == ok ]] || return 1
            config="$2"
            while IFS= read -r line; do
                [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]] && continue
                key="${line%%[[:space:]]*}"
                value="${line##*=[[:space:]]}"
                SYSCTL_VALUES["$key"]="$value"
            done < "$config"
            ;;
        *) return 1 ;;
    esac
}
ip() {
    if [[ "${1:-}" == -4 ]]; then
        printf '8.8.8.8 via 192.0.2.1 dev eth0 src 192.0.2.10\n'
    elif [[ "${1:-}" == -6 ]]; then
        printf '    inet6 2001:db8::10/64 scope global\n'
    fi
}

# Disabling IPv6 records the original values once, writes only an owned file,
# and restores those values without deleting an unrelated legacy file.
mkdir -p "$(dirname "$LEGACY_DISABLE_FILE")"
printf 'vendor-setting=keep\n' > "$LEGACY_DISABLE_FILE"
disable_ipv6
assert_contains "$SYSCTL_DISABLE_FILE" "$OWNED_SYSCTL_MARKER"
assert_contains "$DISABLE_STATE_FILE" 'net.ipv6.conf.all.disable_ipv6=0'
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.all.disable_ipv6]}" 1
disable_ipv6
assert_contains "$DISABLE_STATE_FILE" 'net.ipv6.conf.all.disable_ipv6=0'
restore_ipv6_changes
[[ ! -e "$SYSCTL_DISABLE_FILE" ]] || fail 'owned IPv6 disable file was not removed'
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.all.disable_ipv6]}" 0
assert_contains "$LEGACY_DISABLE_FILE" 'vendor-setting=keep'

# A foreign file at the new owned path is never overwritten or deleted.
printf 'foreign-setting=1\n' > "$SYSCTL_DISABLE_FILE"
if disable_ipv6; then fail 'foreign sysctl file was overwritten'; fi
assert_contains "$SYSCTL_DISABLE_FILE" 'foreign-setting=1'
rm -f "$SYSCTL_DISABLE_FILE" "$DISABLE_STATE_FILE"

# SLAAC keeps forwarding enabled, uses accept_ra=2 for a router, does not write
# forwarding=0, and can restore every captured value.
auto_config_ipv6
assert_contains "$SYSCTL_AUTOCONF_FILE" 'net.ipv6.conf.eth0.autoconf = 1'
assert_contains "$SYSCTL_AUTOCONF_FILE" 'net.ipv6.conf.eth0.accept_ra = 2'
assert_not_contains "$SYSCTL_AUTOCONF_FILE" 'net.ipv6.conf.all.forwarding ='
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.all.forwarding]}" 1
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.eth0.autoconf]}" 1
restore_ipv6_changes
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.all.forwarding]}" 1
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.eth0.autoconf]}" 0
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.eth0.accept_ra]}" 0
[[ ! -e "$SYSCTL_AUTOCONF_FILE" ]] || fail 'owned IPv6 autoconf file was not removed'

# Failed sysctl application restores runtime values and does not commit a file.
sysctl_mode=fail
if disable_ipv6; then fail 'failed sysctl application was reported successful'; fi
assert_eq "${SYSCTL_VALUES[net.ipv6.conf.all.disable_ipv6]}" 0
[[ ! -e "$SYSCTL_DISABLE_FILE" ]] || fail 'failed sysctl configuration was committed'
sysctl_mode=ok

# Connectivity reporting distinguishes resolver order from the actual remote IP.
getent() { printf '2001:db8::20 STREAM www.cloudflare.com\n'; }
curl() { printf '198.51.100.20'; }
connectivity_output=$(test_connectivity)
grep -Fq 'getent 首选地址：2001:db8::20 (IPv6)' <<< "$connectivity_output" || fail 'resolver family not reported'
grep -Fq '实际 HTTPS 连接：198.51.100.20 (IPv4)' <<< "$connectivity_output" || fail 'actual connection family not reported'

assert_not_contains "$REPO_DIR/modify_ip_preference.sh" 'systemctl restart NetworkManager'
assert_not_contains "$REPO_DIR/modify_ip_preference.sh" 'systemctl restart networking'
assert_not_contains "$REPO_DIR/modify_ip_preference.sh" 'net.ipv6.conf.all.forwarding = 0'
assert_not_contains "$REPO_DIR/modify_ip_preference.sh" 'rm -f /etc/sysctl.d/99-disable-ipv6.conf'

printf 'PASS: modify_ip_preference.sh A20 regression tests\n'
