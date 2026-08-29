#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dns-unlock-test.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export DNS_UNLOCK_SOURCE_ONLY=1
export DNS_UNLOCK_GOST_CONFIG_PATH="$TEST_ROOT/etc/gost/dns-unlock-config.yml"
export DNS_UNLOCK_GOST_SERVICE_PATH="$TEST_ROOT/etc/systemd/system/gost-dns.service"
export DNS_UNLOCK_GOST_INSTALL_PATH="$TEST_ROOT/usr/local/bin/gost"
export DNS_UNLOCK_DNSMASQ_CONFIG_FILE="$TEST_ROOT/etc/dnsmasq.d/custom_unlock.conf"
export DNS_UNLOCK_DNSMASQ_MAIN_CONFIG="$TEST_ROOT/etc/dnsmasq.conf"
export DNS_UNLOCK_RESOLV_CONF_PATH="$TEST_ROOT/etc/resolv.conf"
export DNS_UNLOCK_GAI_CONF_PATH="$TEST_ROOT/etc/gai.conf"
export DNS_UNLOCK_STATE_DIR="$TEST_ROOT/var/lib/dns-unlock"
export DNS_UNLOCK_BACKUP_ROOT="$TEST_ROOT/var/backups/dns-unlock"
export DNS_UNLOCK_SERVICE_CHECK_ATTEMPTS=1
export DNS_UNLOCK_SERVICE_CHECK_DELAY=0
export DNS_UNLOCK_GOST_LISTENER_CHECK_ATTEMPTS=1
export DNS_UNLOCK_GOST_LISTENER_CHECK_DELAY=0
export DNS_UNLOCK_END_TO_END_CHECK_ATTEMPTS=1
export DNS_UNLOCK_END_TO_END_CHECK_DELAY=0
export DNS_UNLOCK_PORT_RELEASE_DELAY=0

# shellcheck source=../dns_unlock.sh
. "$REPO_DIR/dns_unlock.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

# Strict IPv4 validation and architecture mapping.
is_valid_ipv4 0.0.0.0
is_valid_ipv4 203.0.113.9
for invalid_ip in 256.1.1.1 1.2.3 '1.2.3.4;reboot' 1.2.3.-1; do
  if is_valid_ipv4 "$invalid_ip"; then fail "invalid IPv4 accepted: $invalid_ip"; fi
done
assert_eq "$(map_gost_arch aarch64)" "arm64"
assert_eq "$(map_gost_arch x86_64)" "amd64"

# Latest release parsing precisely selects the ARM64 asset and never uses a fixed fallback.
mock_release="$TEST_ROOT/release.json"
cat > "$mock_release" <<'JSON'
{
  "tag_name":"v9.8.7",
  "assets":[
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
fetch_latest_gost_release "$TEST_ROOT/fetched.json" arm64
assert_eq "$latest_gost_version" "9.8.7"
assert_eq "$latest_gost_asset" "gost_9.8.7_linux_arm64.tar.gz"
unset -f curl
assert_not_contains "$REPO_DIR/dns_unlock.sh" '3.2.4'
assert_not_contains "$REPO_DIR/dns_unlock.sh" 'armv8'

# Existing GOST must be v3 and must actually parse YAML.
mkdir -p "$TEST_ROOT/bin"
if [[ -n "${DNS_UNLOCK_TEST_REAL_GOST:-}" ]]; then
  cp "$DNS_UNLOCK_TEST_REAL_GOST" "$TEST_ROOT/bin/gost-v3"
else
  cat > "$TEST_ROOT/bin/gost-v3" <<'SH'
#!/bin/sh
if [ "$1" = "-V" ]; then echo 'gost v3.2.6'; exit 0; fi
exit 0
SH
fi
cat > "$TEST_ROOT/bin/gost-v2" <<'SH'
#!/bin/sh
if [ "$1" = "-V" ]; then echo 'gost 2.11.5'; exit 0; fi
exit 0
SH
cat > "$TEST_ROOT/bin/gost-bad-yaml" <<'SH'
#!/bin/sh
if [ "$1" = "-V" ]; then echo 'gost v3.2.6'; exit 0; fi
exit 1
SH
chmod 755 "$TEST_ROOT/bin/"*
gost_supports_v3_yaml "$TEST_ROOT/bin/gost-v3"
if gost_supports_v3_yaml "$TEST_ROOT/bin/gost-v2"; then fail "GOST v2 was accepted"; fi
if gost_supports_v3_yaml "$TEST_ROOT/bin/gost-bad-yaml"; then fail "GOST without YAML support was accepted"; fi

# Port checks cover TCP+UDP 53 and both TCP 80/443 without an early return.
port_log="$TEST_ROOT/ports.log"
port_mode=empty
lsof() {
  printf '%s\n' "$*" >> "$port_log"
  case "$port_mode:$*" in
    dns-conflict:*iUDP:53*) printf '303\n' ;;
    web:*iTCP:80*) printf '101\n' ;;
    web:*iTCP:443*) printf '102\n' ;;
    sniproxy:*iTCP:80*) printf '201\n' ;;
    sniproxy:*iTCP:443*) printf '202\n' ;;
    *) return 1 ;;
  esac
}
ps() {
  case "$*" in
    *303*) printf 'named\n' ;;
    *101*) printf 'nginx\n' ;;
    *102*) printf 'caddy\n' ;;
    *201*|*202*) printf 'sniproxy\n' ;;
  esac
}
systemctl() {
  if [[ "$1" == "show" ]]; then printf '0\n'; fi
  return 0
}
: > "$port_log"
check_port_53
assert_contains "$port_log" 'iTCP:53'
assert_contains "$port_log" 'iUDP:53'
port_mode=dns-conflict
if check_port_53; then fail "UDP/53 conflict was ignored"; fi
port_mode=web
: > "$port_log"
if check_ports_80_443; then fail "non-sniproxy TCP/80 or TCP/443 conflict was accepted"; fi
assert_contains "$port_log" 'iTCP:80'
port_mode=sniproxy
: > "$port_log"
check_ports_80_443 <<< $'y\ny'
assert_contains "$port_log" 'iTCP:80'
assert_contains "$port_log" 'iTCP:443'
[[ "$STOP_SNIPROXY" == true ]] || fail "sniproxy was not scheduled to stop"
unset -f lsof ps systemctl

# Service activation is not considered ready until the GOST MainPID owns both
# TCP listeners; this prevents the immediate post-restart curl race.
listener_mode=both
systemctl() {
  [[ "$1" != show ]] || printf '4242\n'
  return 0
}
lsof() {
  case "$listener_mode:$*" in
    both:*'-p 4242'*'-iTCP:80'*|both:*'-p 4242'*'-iTCP:443'*) printf '4242\n' ;;
    http-only:*'-p 4242'*'-iTCP:80'*) printf '4242\n' ;;
    *) return 1 ;;
  esac
}
wait_for_gost_listeners
listener_mode=http-only
if wait_for_gost_listeners; then fail "GOST readiness accepted a missing TCP/443 listener"; fi
unset -f lsof systemctl

# Remote client preflight verifies wildcard DNS interception over UDP/TCP and
# both forwarding ports before any local resolver change is attempted.
remote_probe_log="$TEST_ROOT/remote-probe.log"
remote_probe_mode=ok
dig() {
  printf 'dig %s\n' "$*" >> "$remote_probe_log"
  case "$remote_probe_mode:$*" in
    ok:*@203.0.113.53*) printf '198.51.100.8\n' ;;
    bad:*' netflix.com A'*) printf '198.51.100.8\n' ;;
  esac
}
curl() {
  printf 'curl %s\n' "$*" >> "$remote_probe_log"
  [[ "$remote_probe_mode" == ok ]]
}
: > "$remote_probe_log"
validate_remote_dns_unlock_server 203.0.113.53
assert_contains "$remote_probe_log" '+short @203.0.113.53 netflix.com A'
assert_contains "$remote_probe_log" '+tcp +time=3 +tries=1 +short @203.0.113.53'
assert_contains "$remote_probe_log" '@203.0.113.53 disney.api.edge.bamgrid.com A'
assert_contains "$remote_probe_log" '@203.0.113.53 ios.chat.openai.com A'
assert_contains "$remote_probe_log" '--resolve example.com:80:203.0.113.53'
assert_contains "$remote_probe_log" '--resolve www.example.com:443:203.0.113.53'
remote_probe_mode=bad
if bad_probe_output=$(validate_remote_dns_unlock_server 203.0.113.53 2>&1); then
  fail "remote preflight accepted DNS without wildcard interception"
fi
if [[ "$bad_probe_output" != *'远端 DNS 端口可以响应，但当前未加载 DNS 解锁规则'* ]]; then
  printf '%s\n' "$bad_probe_output" >&2
  fail "remote preflight did not distinguish missing unlock rules from a closed DNS port"
fi
if [[ "$bad_probe_output" != *'DNS解锁服务（22）'* ]]; then
  printf '%s\n' "$bad_probe_output" >&2
  fail "remote preflight did not provide the server repair path"
fi
unset -f dig curl

# The staged server configuration is validated before installation.
mkdir -p "$(dirname "$DNSMASQ_MAIN_CONFIG")"
printf '# original-main\n' > "$DNSMASQ_MAIN_CONFIG"
command_log="$TEST_ROOT/commands.log"
install_dependencies() { :; }
check_port_53() { :; }
check_ports_80_443() { STOP_SNIPROXY=false; }
select_or_stage_gost() {
  selected_gost_binary="$TEST_ROOT/bin/gost-v3"
  install_new_gost=false
}
curl() {
  case "$*" in
    *api.ipify.org*|*ifconfig.me/ip*) printf '203.0.113.20\n' ;;
  esac
}
dig() {
  printf 'dig %s\n' "$*" >> "$command_log"
  printf '203.0.113.20\n'
}
dnsmasq() { printf 'dnsmasq %s\n' "$*" >> "$command_log"; return 0; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$command_log"
  if [[ "$1" == "show" ]]; then printf '4242\n'; fi
  return 0
}
lsof() {
  case "$*" in
    *'-p 4242'*'-iTCP:80'*) printf '4242\n' ;;
    *'-p 4242'*'-iTCP:443'*) printf '4242\n' ;;
    *) return 1 ;;
  esac
}
stage_dir=$(mktemp -d "$TEST_ROOT/stage.XXXXXXXX")
perform_dns_unlock_server_install "$stage_dir" <<< 'n'
assert_contains "$DNS_GOST_CONFIG_PATH" '# Managed by AI-Scripts dns_unlock.sh'
assert_contains "$DNS_GOST_SERVICE_PATH" "ExecStart=$TEST_ROOT/bin/gost-v3 -C $DNS_GOST_CONFIG_PATH"
[[ $(grep -c 'type: "sni"' "$DNS_GOST_CONFIG_PATH") == 2 ]] || fail "HTTP and HTTPS are not both using the GOST v3 SNI handler"
[[ $(grep -c 'resolver: "dns-unlock-upstream"' "$DNS_GOST_CONFIG_PATH") == 2 ]] || fail "GOST services do not both reference the dedicated resolver"
assert_contains "$DNS_GOST_CONFIG_PATH" 'nameservers:'
assert_contains "$DNS_GOST_CONFIG_PATH" 'https://1.1.1.1/dns-query'
assert_contains "$DNS_GOST_CONFIG_PATH" 'addr: "0.0.0.0:80"'
assert_contains "$DNS_GOST_CONFIG_PATH" 'addr: "0.0.0.0:443"'
assert_not_contains "$DNS_GOST_CONFIG_PATH" 'addr: "{host}:80"'
assert_contains "$DNSMASQ_CONFIG_FILE" 'address=/netflix.com/203.0.113.20'
assert_contains "$DNSMASQ_CONFIG_FILE" 'address=/reddit.com/203.0.113.20'
assert_contains "$DNSMASQ_CONFIG_FILE" 'address=/googlevideo.com/203.0.113.20'
for detector_domain in tiktok.com bamgrid.com disneyplus.com youtube.com primevideo.com openai.com chatgpt.com; do
  assert_contains "$DNSMASQ_CONFIG_FILE" "address=/${detector_domain}/203.0.113.20"
done
assert_contains "$command_log" 'dnsmasq --test --conf-file='
assert_contains "$command_log" 'dnsmasq --test'
assert_contains "$command_log" 'dig +time=3 +tries=1 +short @127.0.0.1 netflix.com A'
unset -f lsof

# With an official GOST binary, verify real HTTP Host and HTTPS SNI forwarding.
if [[ -n "${DNS_UNLOCK_TEST_REAL_GOST:-}" ]]; then
  runtime_config="$TEST_ROOT/gost-runtime.yml"
  runtime_log="$TEST_ROOT/gost-runtime.log"
  write_gost_dns_unlock_config "$runtime_config" ':18080' ':18443'
  (
    runtime_pid=""
    cleanup_runtime_gost() {
      [[ -z "$runtime_pid" ]] || ! kill -0 "$runtime_pid" 2>/dev/null || kill "$runtime_pid" 2>/dev/null || true
      [[ -z "$runtime_pid" ]] || wait "$runtime_pid" 2>/dev/null || true
    }
    trap cleanup_runtime_gost EXIT
    "$DNS_UNLOCK_TEST_REAL_GOST" -C "$runtime_config" > "$runtime_log" 2>&1 &
    runtime_pid=$!
    for _ in 1 2 3 4 5; do
      kill -0 "$runtime_pid" 2>/dev/null || fail "real GOST exited before runtime validation"
      grep -Fq '18443' "$runtime_log" && break
      sleep 1
    done
    command curl --fail --silent --show-error --noproxy '*' --max-time 20 \
      -H 'Host: example.com' http://127.0.0.1:18080/ -o /dev/null || fail "real GOST HTTP Host forwarding failed"
    command curl --fail --silent --show-error --noproxy '*' --max-time 20 \
      --resolve 'www.example.com:18443:127.0.0.1' https://www.example.com:18443/ -o /dev/null || fail "real GOST HTTPS SNI forwarding failed"
    assert_contains "$runtime_log" 'example.com:80'
    assert_contains "$runtime_log" 'www.example.com:443'
  )
fi

# A failed install restores every file from the private transaction snapshot.
package_installed() { return 1; }
create_system_snapshot
[[ -d "$transaction_backup" ]] || fail "snapshot failed when optional packages were absent"
package_installed() { return 0; }
clear() { :; }
check_supported_system() { :; }
mkdir -p "$(dirname "$GOST_INSTALL_PATH")"
printf 'old-binary\n' > "$GOST_INSTALL_PATH"
printf 'old-gost-config\n' > "$DNS_GOST_CONFIG_PATH"
printf 'old-service\n' > "$DNS_GOST_SERVICE_PATH"
printf 'old-custom\n' > "$DNSMASQ_CONFIG_FILE"
printf 'old-main\n' > "$DNSMASQ_MAIN_CONFIG"
printf 'old-resolv\n' > "$RESOLV_CONF_PATH"
printf 'old-gai\n' > "$GAI_CONF_PATH"
perform_dns_unlock_server_install() {
  install_new_gost=true
  printf 'new-binary\n' > "$GOST_INSTALL_PATH"
  printf 'new-gost-config\n' > "$DNS_GOST_CONFIG_PATH"
  printf 'new-service\n' > "$DNS_GOST_SERVICE_PATH"
  printf 'new-custom\n' > "$DNSMASQ_CONFIG_FILE"
  printf 'new-main\n' > "$DNSMASQ_MAIN_CONFIG"
  return 1
}
if install_dns_unlock_server; then fail "failed server install was reported successful"; fi
assert_contains "$GOST_INSTALL_PATH" 'old-binary'
assert_contains "$DNS_GOST_CONFIG_PATH" 'old-gost-config'
assert_contains "$DNS_GOST_SERVICE_PATH" 'old-service'
assert_contains "$DNSMASQ_CONFIG_FILE" 'old-custom'
assert_contains "$DNSMASQ_MAIN_CONFIG" 'old-main'
[[ -d "$transaction_backup" ]] || fail "transaction backup was not retained"

# Managed uninstall restores the first-install snapshot instead of deleting blindly.
rm -f "$SERVER_MANAGED_MARKER" "$SERVER_GOST_MANAGED_MARKER"
rm -rf "$SERVER_ORIGINAL_SNAPSHOT"
printf 'managed-original-binary\n' > "$GOST_INSTALL_PATH"
printf 'managed-original-config\n' > "$DNS_GOST_CONFIG_PATH"
printf 'managed-original-service\n' > "$DNS_GOST_SERVICE_PATH"
printf 'managed-original-custom\n' > "$DNSMASQ_CONFIG_FILE"
printf 'managed-original-main\n' > "$DNSMASQ_MAIN_CONFIG"
create_system_snapshot
mkdir -p "$STATE_DIR"
cp -a "$transaction_backup" "$SERVER_ORIGINAL_SNAPSHOT"
: > "$SERVER_MANAGED_MARKER"
: > "$SERVER_GOST_MANAGED_MARKER"
printf 'installed-binary\n' > "$GOST_INSTALL_PATH"
printf 'installed-config\n' > "$DNS_GOST_CONFIG_PATH"
uninstall_dns_unlock_server
assert_contains "$GOST_INSTALL_PATH" 'managed-original-binary'
assert_contains "$DNS_GOST_CONFIG_PATH" 'managed-original-config'
assert_contains "$DNSMASQ_CONFIG_FILE" 'managed-original-custom'

# Client uninstall restores its own DNS-only snapshot without touching server components.
printf 'client-original-resolv\n' > "$RESOLV_CONF_PATH"
printf 'client-original-gai\n' > "$GAI_CONF_PATH"
create_client_snapshot
cp -a "$transaction_backup" "$CLIENT_ORIGINAL_SNAPSHOT"
: > "$CLIENT_MANAGED_MARKER"
printf 'client-new-resolv\n' > "$RESOLV_CONF_PATH"
printf 'client-new-gai\n' > "$GAI_CONF_PATH"
uninstall_dns_client
assert_contains "$RESOLV_CONF_PATH" 'client-original-resolv'
assert_contains "$GAI_CONF_PATH" 'client-original-gai'

# Legacy uninstall does not delete unowned GOST or dnsmasq resources.
rm -f "$SERVER_MANAGED_MARKER" "$SERVER_GOST_MANAGED_MARKER"
rm -rf "$SERVER_ORIGINAL_SNAPSHOT"
printf 'user-service\n' > "$DNS_GOST_SERVICE_PATH"
printf 'user-gost-config\n' > "$DNS_GOST_CONFIG_PATH"
printf 'user-dnsmasq-config\n' > "$DNSMASQ_CONFIG_FILE"
uninstall_dns_unlock_server
assert_contains "$DNS_GOST_SERVICE_PATH" 'user-service'
assert_contains "$DNS_GOST_CONFIG_PATH" 'user-gost-config'
assert_contains "$DNSMASQ_CONFIG_FILE" 'user-dnsmasq-config'

# Mock netfilter to verify owned chains, dual stack DNS, and UDP/443 QUIC blocking.
declare -A mock_chains=()
firewall_log="$TEST_ROOT/firewall.log"
firewall_mock() {
  local tool="$1" action key
  shift
  printf '%s %s\n' "$tool" "$*" >> "$firewall_log"
  action="${1:-}"
  case "$action" in
    -nL)
      key="$tool:${2:-}"
      [[ -n "${mock_chains[$key]:-}" ]]
      ;;
    -N) mock_chains["$tool:${2}"]=1 ;;
    -F) [[ -n "${mock_chains[$tool:${2}]:-}" ]] ;;
    -X) unset 'mock_chains['"$tool:${2}"']' ;;
    -C) return 1 ;;
    -L) return 0 ;;
    *) return 0 ;;
  esac
}
iptables() { firewall_mock iptables "$@"; }
ip6tables() { firewall_mock ip6tables "$@"; }
check_and_install_iptables() { :; }
persist_firewall_rules() { :; }
: > "$firewall_log"
block_ipv6_ports
assert_contains "$firewall_log" "ip6tables -I OUTPUT -p udp --dport 443"
assert_contains "$firewall_log" "-j $IPV6_BLOCK_CHAIN"
unblock_ipv6_ports
assert_contains "$firewall_log" "ip6tables -X $IPV6_BLOCK_CHAIN"
: > "$firewall_log"
enforce_dns_only_to_server 203.0.113.53
assert_contains "$firewall_log" "iptables -I OUTPUT -p udp --dport 53"
assert_contains "$firewall_log" "iptables -I OUTPUT -p tcp --dport 53"
assert_contains "$firewall_log" "ip6tables -I OUTPUT -p udp --dport 53"
assert_contains "$firewall_log" "ip6tables -I OUTPUT -p tcp --dport 53"
assert_contains "$firewall_log" "iptables -A $DNS_V4_CHAIN -d 203.0.113.53"
assert_contains "$firewall_log" "ip6tables -A $DNS_V6_CHAIN"
revert_dns_enforcement_rules

# A failed remote preflight must happen before resolv.conf or resolved is touched.
client_mutation_log="$TEST_ROOT/client-mutation.log"
validate_remote_dns_unlock_server() { return 1; }
disable_systemd_resolved_if_running() { printf 'disable-resolved\n' >> "$client_mutation_log"; }
set_resolv_conf() { printf 'write-resolv\n' >> "$client_mutation_log"; }
if perform_setup_dns_client 203.0.113.53; then
  fail "client setup continued after a failed remote preflight"
fi
[[ ! -e "$client_mutation_log" ]] || fail "client DNS was modified before remote preflight passed"

assert_not_contains "$REPO_DIR/dns_unlock.sh" 'rm -f "$(command -v gost)"'
assert_not_contains "$REPO_DIR/dns_unlock.sh" 'apt-get purge -y sniproxy'

printf 'PASS: dns_unlock.sh A09/A10 regression tests\n'
