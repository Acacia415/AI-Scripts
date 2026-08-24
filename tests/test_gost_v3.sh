#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gost-v3-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export GOST_SOURCE_ONLY=1
export GOST_CONF_DIR="$TEST_ROOT/etc/gost"
export GOST_CONF_PATH="$GOST_CONF_DIR/config.yml"
export GOST_RAW_CONF_PATH="$GOST_CONF_DIR/rawconf"
export GOST_BINARY_PATH="$TEST_ROOT/usr/bin/gost"
export GOST_SERVICE_PATH="$TEST_ROOT/usr/lib/systemd/system/gost.service"
export GOST_JOURNALD_PATH="$TEST_ROOT/etc/systemd/journald.conf.d/99-gost-limits.conf"
export GOST_INSTALL_BACKUP_ROOT="$TEST_ROOT/var/backups/gost-v3"
export GOST_CRONTAB_PATH="$TEST_ROOT/etc/crontab"
export GOST_USER_BACKUP_PATH="$TEST_ROOT/root/gost_backups"
export GOST_PEER_LIST_DIR="$TEST_ROOT/root"
export GOST_SERVICE_CHECK_ATTEMPTS=1
export GOST_SERVICE_CHECK_DELAY=0

# shellcheck source=../gost_v3.sh
. "$REPO_DIR/gost_v3.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "$1 unexpectedly contains: $2"
  fi
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

# Input validation keeps ARM64 and all upstream-supported legacy architectures.
validate_port 1
validate_port 65535
if validate_port 0 || validate_port 65536 || validate_port '1 * * * *'; then
  fail "invalid port accepted"
fi
bit=arm64
mock_release="$TEST_ROOT/release.json"
cat > "$mock_release" <<'JSON'
{
  "tag_name": "v9.8.7",
  "assets": [
    {"name":"gost_9.8.7_linux_arm64.tar.gz","browser_download_url":"https://github.com/go-gost/gost/releases/download/v9.8.7/gost_9.8.7_linux_arm64.tar.gz"},
    {"name":"checksums.txt","browser_download_url":"https://github.com/go-gost/gost/releases/download/v9.8.7/checksums.txt"}
  ]
}
JSON
curl() {
  local output=""
  while (($#)); do
    if [[ "$1" == "-o" ]]; then output="$2"; shift 2; else shift; fi
  done
  cp "$mock_release" "$output"
}
fetch_latest_release "$TEST_ROOT/fetched.json"
assert_eq "$latest_gost_version" "9.8.7"
assert_eq "$latest_gost_asset" "gost_9.8.7_linux_arm64.tar.gz"
unset -f curl

# JSON raw records and JSON-quoted YAML preserve shell/YAML metacharacters.
mkdir -p "$GOST_CONF_DIR" "$(dirname "$GOST_BINARY_PATH")"
if [[ -n "${GOST_TEST_REAL_BINARY:-}" ]]; then
  cp "$GOST_TEST_REAL_BINARY" "$GOST_BINARY_PATH"
else
  cat > "$GOST_BINARY_PATH" <<'SH'
#!/bin/sh
if [ "$1" = "-V" ]; then echo "gost 9.8.7"; fi
exit 0
SH
fi
chmod 755 "$GOST_BINARY_PATH"
flag_a=socks
flag_b='pa"ss#word\tail'
flag_c='user: #name'
flag_d=1080
is_cert=n
writerawconf
assert_eq "$(jq -r '.local' "$GOST_RAW_CONF_PATH")" "$flag_b"
assert_eq "$(jq -r '.target' "$GOST_RAW_CONF_PATH")" "$flag_c"
regenerate_yaml_config
quoted_password=$(yaml_quote "$flag_b")
quoted_username=$(yaml_quote "$flag_c")
assert_file_contains "$GOST_CONF_PATH" "password: $quoted_password"
assert_file_contains "$GOST_CONF_PATH" "username: $quoted_username"
if [[ "$(uname -s)" == "Linux" ]]; then
  assert_eq "$(stat -c '%a' "$GOST_CONF_DIR")" "700"
  assert_eq "$(stat -c '%a' "$GOST_CONF_PATH")" "600"
  assert_eq "$(stat -c '%a' "$GOST_RAW_CONF_PATH")" "600"
fi

# Legacy records remain readable and IPv6 destinations are bracketed correctly.
printf 'nonencrypt/10001#2001:db8::1#443\n' > "$GOST_RAW_CONF_PATH"
regenerate_yaml_config
assert_file_contains "$GOST_CONF_PATH" 'addr: "[2001:db8::1]:443"'

# Every menu mode produces a config accepted by the real GOST binary when supplied.
mkdir -p "$GOST_PEER_LIST_DIR"
printf '203.0.113.10:443\n[2001:db8::10]:8443\n' > "$GOST_PEER_LIST_DIR/peers.txt"
chmod 600 "$GOST_PEER_LIST_DIR/peers.txt"
: > "$GOST_RAW_CONF_PATH"
add_record() {
  jq -cn --arg mode "$1" --arg local "$2" --arg target "$3" --arg remote "$4" --argjson tls_verify "${5:-false}" \
    '{mode:$mode, local:$local, target:$target, remote:$remote, tls_verify:$tls_verify}' >> "$GOST_RAW_CONF_PATH"
}
add_record nonencrypt 11001 example.com 80
add_record encrypttls 11002 example.com 443 true
add_record encryptws 11003 example.com 443
add_record encryptwss 11004 example.com 443 true
add_record decrypttls 11005 127.0.0.1 8080
add_record decryptws 11006 127.0.0.1 8080
add_record decryptwss 11007 127.0.0.1 8080
add_record ss 'ss"pass#word' aes-256-gcm 11008
add_record socks 'socks"pass#word' 'socks: #user' 11009
add_record http 'http"pass#word' 'http: #user' 11010
add_record peerno 11011 peers round
add_record peertls 11012 peers random
add_record peerws 11013 peers fifo
add_record peerwss 11014 peers round
chmod 600 "$GOST_RAW_CONF_PATH"
regenerate_yaml_config
assert_file_contains "$GOST_CONF_PATH" 'chains:'

# Cron changes only touch the unique marker and invalid input leaves the file intact.
mkdir -p "$(dirname "$GOST_CRONTAB_PATH")"
cat > "$GOST_CRONTAB_PATH" <<'CRON'
15 2 * * * root /usr/local/bin/gost-healthcheck
0 3 * * * root systemctl restart gost # AI-Scripts:gost-v3-restart
CRON
replace_gost_cron_entry '0 */6 * * * root systemctl restart gost'
assert_file_contains "$GOST_CRONTAB_PATH" '/usr/local/bin/gost-healthcheck'
assert_file_contains "$GOST_CRONTAB_PATH" '0 */6 * * * root systemctl restart gost # AI-Scripts:gost-v3-restart'
assert_file_not_contains "$GOST_CRONTAB_PATH" '0 3 * * *'
cp "$GOST_CRONTAB_PATH" "$TEST_ROOT/crontab.before"
if cron_restart <<< $'1\n1\n0'; then
  fail "invalid cron interval was accepted"
fi
cmp -s "$TEST_ROOT/crontab.before" "$GOST_CRONTAB_PATH" || fail "invalid cron input changed crontab"

# A failed install restores binary, config, service, journald config, and service state.
printf 'old-binary\n' > "$GOST_BINARY_PATH"
chmod 755 "$GOST_BINARY_PATH"
printf 'services: []\n# old-config\n' > "$GOST_CONF_PATH"
mkdir -p "$(dirname "$GOST_SERVICE_PATH")" "$(dirname "$GOST_JOURNALD_PATH")"
printf 'old-service\n' > "$GOST_SERVICE_PATH"
printf 'old-journald\n' > "$GOST_JOURNALD_PATH"

check_root() { :; }
check_sys() { release=debian; bit=arm64; }
Installation_dependency() { :; }
fetch_latest_release() {
  latest_gost_version=9.8.7
  latest_gost_asset=gost_9.8.7_linux_arm64.tar.gz
  latest_gost_url=https://github.com/go-gost/gost/releases/download/v9.8.7/gost_9.8.7_linux_arm64.tar.gz
  latest_checksums_url=https://github.com/go-gost/gost/releases/download/v9.8.7/checksums.txt
}
download_latest_gost() {
  cat > "$1/gost" <<'SH'
#!/bin/sh
if [ "$1" = "-V" ]; then echo "gost 9.8.7"; fi
exit 0
SH
  chmod 755 "$1/gost"
}
setup_journald_log_rotation() { printf 'new-journald\n' > "$GOST_JOURNALD_PATH"; }
systemctl() {
  case "$1" in
    is-enabled|is-active) return 0 ;;
    restart) return 1 ;;
    *) return 0 ;;
  esac
}
if Install_ct <<< 'y'; then
  fail "install succeeded despite a failed service restart"
fi
assert_file_contains "$GOST_BINARY_PATH" 'old-binary'
assert_file_contains "$GOST_CONF_PATH" '# old-config'
assert_file_contains "$GOST_SERVICE_PATH" 'old-service'
assert_file_contains "$GOST_JOURNALD_PATH" 'old-journald'

# The self-update source and retained manual journald limits must stay in this repository.
assert_eq "$self_update_url" 'https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/gost_v3.sh'
assert_file_contains "$REPO_DIR/gost_v3.sh" 'SystemMaxUse=200M'
assert_file_contains "$REPO_DIR/gost_v3.sh" 'MaxRetentionSec=7day'
assert_file_not_contains "$REPO_DIR/gost_v3.sh" 'sed -i "/gost/d"'
assert_file_not_contains "$REPO_DIR/gost_v3.sh" 'ct_new_ver='

printf 'PASS: gost_v3.sh A07/A08 regression tests\n'
