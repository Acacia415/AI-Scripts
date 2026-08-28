#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nginx-manager-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export NGINX_MANAGER_SOURCE_ONLY=1
export NGINX_CONF_DIR="$TEST_ROOT/etc/nginx/conf.d"
export NGINX_MAIN_CONFIG="$TEST_ROOT/etc/nginx/nginx.conf"
export NGINX_LOG_DIR="$TEST_ROOT/var/log/nginx"
export NGINX_SERVICE=nginx-test.service
export NGINX_STATE_ROOT="$TEST_ROOT/var/lib/ai-scripts/nginx"
export NGINX_DOMAIN_STATE_DIR="$NGINX_STATE_ROOT/domains"
export NGINX_BACKUP_ROOT="$TEST_ROOT/backups"
export NGINX_BACKUP_KEEP=5
export NGINX_RENEWAL_CRON="$TEST_ROOT/etc/cron.d/ai-scripts-nginx-certbot"
export NGINX_ACME_WEBROOT="$NGINX_STATE_ROOT/acme"
export LETSENCRYPT_LIVE_DIR="$TEST_ROOT/etc/letsencrypt/live"

# shellcheck source=../nginx-manager.sh disable=SC1091
. "$REPO_DIR/nginx-manager.sh"

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

# Git Bash cannot reliably apply every GNU install mode on a Windows mount.
# This wrapper changes only files below the disposable test sandbox.
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

clear() { :; }
check_root() { :; }
sleep() { :; }

SERVICE_ACTIVE=true
FAIL_RELOAD_ONCE=0
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
systemctl() {
    local action="${1:-}"
    shift || true
    printf '%s %s\n' "$action" "$*" >> "$SYSTEMCTL_LOG"
    case "$action" in
        is-active) [[ "$SERVICE_ACTIVE" == true ]] ;;
        stop) SERVICE_ACTIVE=false ;;
        start|restart) SERVICE_ACTIVE=true ;;
        reload)
            if ((FAIL_RELOAD_ONCE > 0)); then
                FAIL_RELOAD_ONCE=$((FAIL_RELOAD_ONCE - 1))
                return 1
            fi
            ;;
        enable|disable|is-enabled) return 0 ;;
        *) return 0 ;;
    esac
}

FAIL_NGINX_TEST_ONCE=0
nginx() {
    if [[ ${1:-} == -t && $FAIL_NGINX_TEST_ONCE -gt 0 ]]; then
        FAIL_NGINX_TEST_ONCE=$((FAIL_NGINX_TEST_ONCE - 1))
        return 1
    fi
    [[ ${1:-} == -v ]] && printf 'nginx version: test\n' >&2
    return 0
}

SS_OUTPUT=''
ss() { printf '%s' "$SS_OUTPUT"; }
FUSER_CALLS=0
fuser() { FUSER_CALLS=$((FUSER_CALLS + 1)); }

CERTBOT_LOG="$TEST_ROOT/certbot.log"
CERTBOT_WEBROOT_FAIL=0
CERTBOT_CREATE_FILES=false
certbot() {
    local cert_name='' argument command_name="${1:-}" original_args="$*"
    printf '%s\n' "$*" >> "$CERTBOT_LOG"
    while (($#)); do
        argument=$1
        shift
        if [[ "$argument" == --cert-name && $# -gt 0 ]]; then
            cert_name=$1
            shift
        fi
    done
    if [[ " $original_args " == *' --webroot '* && $CERTBOT_WEBROOT_FAIL -gt 0 ]]; then
        CERTBOT_WEBROOT_FAIL=$((CERTBOT_WEBROOT_FAIL - 1))
        return 1
    fi
    if [[ "$command_name" == delete && -n "$cert_name" ]]; then
        rm -rf -- "$LETSENCRYPT_LIVE_DIR/${cert_name:?}"
    elif [[ "$CERTBOT_CREATE_FILES" == true && -n "$cert_name" ]]; then
        mkdir -p "$LETSENCRYPT_LIVE_DIR/$cert_name"
        printf 'certificate\n' > "$LETSENCRYPT_LIVE_DIR/$cert_name/fullchain.pem"
        printf 'private key\n' > "$LETSENCRYPT_LIVE_DIR/$cert_name/privkey.pem"
    fi
    return 0
}

dig() { printf '203.0.113.10\n'; }

mkdir -p "$NGINX_CONF_DIR" "$(dirname -- "$NGINX_MAIN_CONFIG")" "$NGINX_DOMAIN_STATE_DIR" \
    "$(dirname -- "$NGINX_RENEWAL_CRON")" "$LETSENCRYPT_LIVE_DIR" "$NGINX_ACME_WEBROOT"
printf 'user nginx;\n' > "$NGINX_MAIN_CONFIG"

# Inputs used in file names, Nginx directives, cron, and command arguments are
# strictly validated before use.
for valid_domain in example.com sub-domain.example.com a.b.example.com; do
    is_valid_domain "$valid_domain" || fail "valid domain rejected: $valid_domain"
done
for invalid_domain in example localhost .example.com example.com. bad..example.com '-x.example.com' 'bad;id.example'; do
    if is_valid_domain "$invalid_domain"; then fail "invalid domain accepted: $invalid_domain"; fi
done
for valid_ip in 0.0.0.0 127.0.0.1 255.255.255.255; do
    is_valid_ipv4 "$valid_ip" || fail "valid IPv4 rejected: $valid_ip"
done
for invalid_ip in 01.2.3.4 256.1.1.1 127.0.0.1:80 '127.0.0.1;id'; do
    if is_valid_ipv4 "$invalid_ip"; then fail "invalid IPv4 accepted: $invalid_ip"; fi
done
is_valid_port 1 || fail 'port 1 rejected'
is_valid_port 65535 || fail 'port 65535 rejected'
for invalid_port in 0 65536 -1 1.5 '80;id'; do
    if is_valid_port "$invalid_port"; then fail "invalid port accepted: $invalid_port"; fi
done

# Both webroot and standalone Certbot paths retain an explicit, validated -d
# argument. The standalone fallback restores the prior Nginx active state.
: > "$CERTBOT_LOG"
CERTBOT_WEBROOT_FAIL=1
SS_OUTPUT=''
SERVICE_ACTIVE=true
request_certificate example.com >/dev/null || fail 'standalone certificate fallback failed'
assert_file_contains "$CERTBOT_LOG" 'certonly --webroot -w'
assert_file_contains "$CERTBOT_LOG" '-d example.com --cert-name example.com'
assert_file_contains "$CERTBOT_LOG" 'certonly --standalone -d example.com --cert-name example.com'
assert_eq true "$SERVICE_ACTIVE" 'standalone fallback did not restore Nginx'

# Refusing the port-release prompt is final: no later repair path may call fuser.
SS_OUTPUT=$'LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(("other",pid=42,fd=3))\n'
FUSER_CALLS=0
if authorize_and_release_ports <<< $'n\n' >/dev/null; then
    fail 'port conflict refusal was ignored'
fi
assert_eq 0 "$FUSER_CALLS" 'a process was killed after port-release refusal'
SS_OUTPUT=''

# Candidate configuration activation is transactional. A failed nginx -t
# restores the prior site byte-for-byte instead of deleting it.
OLD_SITE=$'# Managed by AI-Scripts nginx-manager.sh\nold-site-content'
printf '%s\n' "$OLD_SITE" > "$NGINX_CONF_DIR/rollback.example.com.conf"
candidate="$TEST_ROOT/candidate.conf"
printf '%s\nnew-site-content\n' "$SITE_MARKER" > "$candidate"
backup_dir=$(create_site_transaction rollback.example.com apply-failure)
FAIL_NGINX_TEST_ONCE=1
if apply_site_candidate rollback.example.com "$candidate" "$backup_dir" >/dev/null; then
    fail 'invalid Nginx candidate was accepted'
fi
assert_eq "$OLD_SITE" "$(< "$NGINX_CONF_DIR/rollback.example.com.conf")" 'failed candidate did not restore old site'

# Managed-site selection returns only through internal state; menu text cannot
# be captured into a domain/configuration path.
select_managed_domain 'select: ' <<< $'1\n' >/dev/null || fail 'managed-site selection failed'
assert_eq rollback.example.com "$SELECTED_DOMAIN" 'managed-site selection returned polluted text'

# Transaction backups are private and bounded to the configured five copies.
for backup_index in 1 2 3 4 5 6 7; do
    create_site_transaction "retention-${backup_index}.example.com" retention >/dev/null
done
backup_count=$(find "$NGINX_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' | wc -l | tr -d '[:space:]')
assert_eq 5 "$backup_count" 'transaction backup retention'

# The complete setup path stages HTTP validation first, requests the certificate
# with -d, then commits HTTPS, state, and its dedicated renewal task.
: > "$CERTBOT_LOG"
CERTBOT_WEBROOT_FAIL=0
CERTBOT_CREATE_FILES=true
setup_reverse_proxy <<< $'app.example.com\ny\n8080\n' >/dev/null || fail 'complete reverse-proxy setup failed'
assert_file_contains "$NGINX_CONF_DIR/app.example.com.conf" "$SITE_MARKER"
assert_file_contains "$NGINX_CONF_DIR/app.example.com.conf" 'proxy_pass http://127.0.0.1:8080;'
assert_file_contains "$NGINX_CONF_DIR/app.example.com.conf" 'listen 443 ssl;'
assert_file_contains "$CERTBOT_LOG" '-d app.example.com --cert-name app.example.com'
assert_file_contains "$NGINX_DOMAIN_STATE_DIR/app.example.com.state" 'certificate_owned=true'
assert_file_contains "$NGINX_RENEWAL_CRON" 'renew --cert-name app.example.com'
assert_file_contains "$NGINX_MAIN_CONFIG" 'user nginx;'
CERTBOT_CREATE_FILES=false

# A foreign file occupying the dedicated cron path blocks cleanup before any
# site is changed.
printf 'foreign cron\n' > "$NGINX_RENEWAL_CRON"
if uninstall_nginx <<< $'y\n' >/dev/null; then
    fail 'uninstall accepted a foreign dedicated cron file'
fi
[[ -f "$NGINX_CONF_DIR/rollback.example.com.conf" ]] || fail 'site changed before cron ownership refusal'

# Cleanup removes only marked sites, marked state, owned certs, and its own cron.
# Global config, foreign sites/certs, logs, and Web assets remain byte-for-byte.
printf '%s\n' "$CRON_MARKER" > "$NGINX_RENEWAL_CRON"
printf 'foreign site\n' > "$NGINX_CONF_DIR/foreign.example.com.conf"
mkdir -p "$TEST_ROOT/var/www/html" "$LETSENCRYPT_LIVE_DIR/owned.example.com" "$LETSENCRYPT_LIVE_DIR/foreign.example.com"
printf 'keep web asset\n' > "$TEST_ROOT/var/www/html/index.html"
printf 'owned cert\n' > "$LETSENCRYPT_LIVE_DIR/owned.example.com/fullchain.pem"
printf 'owned key\n' > "$LETSENCRYPT_LIVE_DIR/owned.example.com/privkey.pem"
printf 'foreign cert\n' > "$LETSENCRYPT_LIVE_DIR/foreign.example.com/fullchain.pem"
printf 'foreign key\n' > "$LETSENCRYPT_LIVE_DIR/foreign.example.com/privkey.pem"
printf '%s\nserver {}\n' "$SITE_MARKER" > "$NGINX_CONF_DIR/owned.example.com.conf"
write_domain_state owned.example.com true true || fail 'unable to write owned certificate state'
write_domain_state rollback.example.com false true || fail 'unable to write managed site state'
refresh_renewal_cron || fail 'unable to generate owned renewal cron'
: > "$CERTBOT_LOG"
uninstall_nginx <<< $'y\n' >/dev/null || fail 'managed-only cleanup failed'
[[ ! -e "$NGINX_CONF_DIR/owned.example.com.conf" ]] || fail 'owned site was not removed'
[[ ! -e "$NGINX_CONF_DIR/rollback.example.com.conf" ]] || fail 'managed site was not removed'
[[ ! -e "$NGINX_CONF_DIR/app.example.com.conf" ]] || fail 'configured site was not removed'
[[ ! -e "$NGINX_DOMAIN_STATE_DIR/owned.example.com.state" ]] || fail 'owned state was not removed'
[[ ! -e "$NGINX_RENEWAL_CRON" ]] || fail 'owned cron was not removed'
assert_file_contains "$CERTBOT_LOG" 'delete --cert-name owned.example.com --non-interactive'
assert_file_contains "$NGINX_CONF_DIR/foreign.example.com.conf" 'foreign site'
assert_file_contains "$NGINX_MAIN_CONFIG" 'user nginx;'
assert_file_contains "$TEST_ROOT/var/www/html/index.html" 'keep web asset'
assert_file_contains "$LETSENCRYPT_LIVE_DIR/foreign.example.com/fullchain.pem" 'foreign cert'

# Static safety boundaries for A15: no global reset, broad Web deletion, raw
# Let's Encrypt tree deletion, or Certbot invocation without a domain array.
assert_file_not_contains "$REPO_DIR/nginx-manager.sh" 'rm -rf /var/www/html'
assert_file_not_contains "$REPO_DIR/nginx-manager.sh" 'rm -rf /etc/letsencrypt'
assert_file_not_contains "$REPO_DIR/nginx-manager.sh" 'rm -rf "$LETSENCRYPT_LIVE_DIR"'
assert_file_not_contains "$REPO_DIR/nginx-manager.sh" 'cat > /etc/nginx/nginx.conf'
assert_file_contains "$REPO_DIR/nginx-manager.sh" 'certbot_domains+=(-d "$valid_domain")'
assert_file_contains "$REPO_DIR/nginx-manager.sh" 'NGINX_MANAGER_SOURCE_ONLY'

printf 'PASS: nginx-manager.sh A15 regression tests\n'
