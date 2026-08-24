#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

export ANYTLS_SOURCE_ONLY=1
export ANYTLS_FOLDER="${SANDBOX}/etc/anytls"
export ANYTLS_FILE="${SANDBOX}/usr/local/bin/anytls-server"
export ANYTLS_CONF="${ANYTLS_FOLDER}/config.json"
export ANYTLS_ENV="${ANYTLS_FOLDER}/env"
export ANYTLS_VERSION_FILE="${ANYTLS_FOLDER}/ver.txt"
export ANYTLS_SERVICE_FILE="${SANDBOX}/etc/systemd/system/anytls.service"
export ANYTLS_BACKUP_ROOT="${SANDBOX}/backups"
export ANYTLS_SERVICE_NAME="anytls-test"

# shellcheck source=../anytls.sh
source "${REPO_DIR}/anytls.sh"

arch=""
export skip_cert_verify

if [[ -n "${ANYTLS_TEST_JQ:-}" ]]; then
	jq() { "${ANYTLS_TEST_JQ}" "$@"; }
fi

command -v jq >/dev/null 2>&1 || {
	echo "FAIL: jq is required for test_anytls.sh" >&2
	exit 1
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" message="$3"
	[[ "${actual}" == "${expected}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_file_text() {
	local file="$1" expected="$2" message="$3" actual
	[[ -f "${file}" ]] || fail "${message}: missing ${file}"
	actual="$(<"${file}")"
	assert_eq "${expected}" "${actual}" "${message}"
}

FAKE_ACTIVE="inactive"
FAKE_ENABLED="disabled"
FAIL_RESTARTS=0
STOP_CALLS=0

systemctl() {
	local action="${1:-}"
	shift || true
	case "${action}" in
		is-active)
			[[ "${FAKE_ACTIVE}" == "active" ]]
			;;
		is-enabled)
			[[ "${FAKE_ENABLED}" == "enabled" ]]
			;;
		enable)
			FAKE_ENABLED="enabled"
			;;
		disable)
			FAKE_ENABLED="disabled"
			;;
		start)
			FAKE_ACTIVE="active"
			;;
		stop)
			STOP_CALLS=$((STOP_CALLS + 1))
			FAKE_ACTIVE="inactive"
			;;
		restart)
			if (( FAIL_RESTARTS > 0 )); then
				FAIL_RESTARTS=$((FAIL_RESTARTS - 1))
				FAKE_ACTIVE="inactive"
				return 1
			fi
			FAKE_ACTIVE="active"
			;;
		daemon-reload|status)
			;;
		*)
			fail "unexpected systemctl call: ${action} $*"
			;;
	esac
}

sleep() { :; }
start_menu() { :; }

[[ -n "${Error:-}" ]] || fail "Error color prefix is not initialized"

FAKE_MACHINE="x86_64"
uname() { printf '%s\n' "${FAKE_MACHINE}"; }
sys_arch || fail "x86_64 should be supported"
assert_eq "amd64" "${arch}" "x86_64 mapping"
FAKE_MACHINE="aarch64"
sys_arch || fail "aarch64 should be supported"
assert_eq "arm64" "${arch}" "aarch64 mapping"
for FAKE_MACHINE in i386 i686 armv6l armv7l riscv64; do
	if sys_arch >/dev/null 2>&1; then
		fail "unsupported architecture ${FAKE_MACHINE} was accepted"
	fi
done
unset -f uname

port="8443"
password="SafePassword123"
sni="cdn.example.com"
skip_cert_verify="true"
validate_config_values || fail "valid configuration was rejected"
for port in abc 0 65536 99999999999999999999; do
	if validate_config_values; then
		fail "invalid port ${port} was accepted"
	fi
done
port="8443"
for password in "bad password" 'bad"quote' 'bad\slash' 'bad-command;'; do
	if validate_config_values; then
		fail "unsafe password was accepted: ${password}"
	fi
done
password="SafePassword123"
for sni in '-bad.example.com' 'bad..example.com' 'bad_example.com'; do
	if validate_config_values; then
		fail "invalid SNI was accepted: ${sni}"
	fi
done
sni="cdn.example.com"

GENERATED_DIR="${SANDBOX}/generated"
mkdir -p "${GENERATED_DIR}"
generate_config_file "${GENERATED_DIR}/config.json" || fail "config generation failed"
jq -e '.port == 8443 and .password == "SafePassword123" and .sni == "cdn.example.com" and .skip_cert_verify == true' \
	"${GENERATED_DIR}/config.json" >/dev/null || fail "generated JSON content is invalid"
generate_env_file "${GENERATED_DIR}/env" || fail "environment generation failed"
assert_file_text "${GENERATED_DIR}/env" $'PORT=\'8443\'\nPASSWORD=\'SafePassword123\'' "environment content"
generate_service_file "${GENERATED_DIR}/anytls.service" || fail "service generation failed"
grep -Fq "EnvironmentFile=${ANYTLS_ENV}" "${GENERATED_DIR}/anytls.service" || fail "service EnvironmentFile path is wrong"
grep -Fq ' -l 0.0.0.0:${PORT} -p ${PASSWORD}' "${GENERATED_DIR}/anytls.service" || fail "service environment references are not literal"
grep -Fxq 'LimitNOFILE=51200' "${GENERATED_DIR}/anytls.service" || fail "service file descriptor limit is wrong"
if grep -Fq 'ExecStartPre=' "${GENERATED_DIR}/anytls.service"; then
	fail "service still contains the ineffective ulimit ExecStartPre"
fi

make_stage() {
	local stage_dir="$1" binary_text="$2" version_text="$3"
	mkdir -p "${stage_dir}"
	printf '%s\n' "${binary_text}" > "${stage_dir}/anytls-server"
	printf '%s\n' "${version_text}" > "${stage_dir}/ver.txt"
	generate_config_file "${stage_dir}/config.json"
	generate_env_file "${stage_dir}/env"
	generate_service_file "${stage_dir}/anytls.service"
}

INSTALL_STAGE="${SANDBOX}/install-stage"
make_stage "${INSTALL_STAGE}" "new-binary" "v9.9.9"
FAKE_ACTIVE="inactive"
FAKE_ENABLED="disabled"
FAIL_RESTARTS=1
if install_release_transaction "${INSTALL_STAGE}"; then
	fail "failed first install unexpectedly succeeded"
fi
[[ ! -e "${ANYTLS_FILE}" ]] || fail "failed install left the new binary behind"
[[ ! -e "${ANYTLS_CONF}" ]] || fail "failed install left the new config behind"
[[ ! -e "${ANYTLS_ENV}" ]] || fail "failed install left the new env behind"
[[ ! -e "${ANYTLS_SERVICE_FILE}" ]] || fail "failed install left the new service behind"
assert_eq "inactive" "${FAKE_ACTIVE}" "failed install active state rollback"
assert_eq "disabled" "${FAKE_ENABLED}" "failed install enabled state rollback"

mkdir -p "$(dirname "${ANYTLS_FILE}")" "${ANYTLS_FOLDER}" "$(dirname "${ANYTLS_SERVICE_FILE}")"
port="443"
password="OldPassword123"
sni="old.example.com"
skip_cert_verify="false"
printf '%s\n' "old-binary" > "${ANYTLS_FILE}"
printf '%s\n' "v0.0.1" > "${ANYTLS_VERSION_FILE}"
generate_config_file "${ANYTLS_CONF}"
generate_env_file "${ANYTLS_ENV}"
generate_service_file "${ANYTLS_SERVICE_FILE}"
FAKE_ACTIVE="active"
FAKE_ENABLED="enabled"

port="9443"
password="NewPassword456"
sni="new.example.com"
skip_cert_verify="true"
FAIL_RESTARTS=0
apply_config_transaction yes || fail "valid config transaction failed"
jq -e '.port == 9443 and .password == "NewPassword456" and .sni == "new.example.com" and .skip_cert_verify == true' \
	"${ANYTLS_CONF}" >/dev/null || fail "new config was not installed"
assert_file_text "${ANYTLS_ENV}" $'PORT=\'9443\'\nPASSWORD=\'NewPassword456\'' "new environment content"
[[ -f "${ANYTLS_LAST_BACKUP}/config.json" ]] || fail "config backup was not created"
jq -e '.port == 443 and .password == "OldPassword123"' "${ANYTLS_LAST_BACKUP}/config.json" >/dev/null \
	|| fail "config backup does not contain the old values"

port="10443"
password="BrokenPassword789"
sni="broken.example.com"
skip_cert_verify="false"
FAIL_RESTARTS=1
if apply_config_transaction yes; then
	fail "config transaction with failed restart unexpectedly succeeded"
fi
jq -e '.port == 9443 and .password == "NewPassword456" and .sni == "new.example.com" and .skip_cert_verify == true' \
	"${ANYTLS_CONF}" >/dev/null || fail "failed config transaction did not restore config"
assert_file_text "${ANYTLS_ENV}" $'PORT=\'9443\'\nPASSWORD=\'NewPassword456\'' "failed config environment rollback"
assert_eq "active" "${FAKE_ACTIVE}" "failed config active state rollback"

stage_release() {
	local stage_dir="$1"
	printf '%s\n' "updated-binary" > "${stage_dir}/anytls-server"
	printf '%s\n' "${new_ver}" > "${stage_dir}/ver.txt"
}

new_ver="v0.0.2"
FAIL_RESTARTS=1
if update_release_transaction; then
	fail "update with failed restart unexpectedly succeeded"
fi
assert_file_text "${ANYTLS_FILE}" "old-binary" "failed update binary rollback"
assert_file_text "${ANYTLS_VERSION_FILE}" "v0.0.1" "failed update version rollback"
assert_eq "active" "${FAKE_ACTIVE}" "failed update active state rollback"

FAIL_RESTARTS=0
update_release_transaction || fail "successful update transaction failed"
assert_file_text "${ANYTLS_FILE}" "updated-binary" "successful update binary"
assert_file_text "${ANYTLS_VERSION_FILE}" "v0.0.2" "successful update version"

FAKE_ACTIVE="inactive"
STOP_CALLS=0
if stop >/dev/null 2>&1; then
	fail "stop should fail when service is inactive"
fi
assert_eq "0" "${STOP_CALLS}" "inactive stop call count"
FAKE_ACTIVE="active"
stop >/dev/null || fail "stop failed for active service"
assert_eq "inactive" "${FAKE_ACTIVE}" "active service stop state"
assert_eq "1" "${STOP_CALLS}" "active stop call count"

echo "PASS: AnyTLS A04/A05 tests"
