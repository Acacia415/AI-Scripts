#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX:?}"' EXIT

export ANYTLS_SOURCE_ONLY=1
# shellcheck source=../anytls.sh
source "${REPO_DIR}/anytls.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
	[[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

# Redirect the legacy timezone paths into the sandbox. This makes the test
# reproduce the old same-file failure without ever touching the host timezone.
dependency_definition="$(declare -f installation_dependency)"
dependency_definition="${dependency_definition//\/usr\/share\/zoneinfo\/Asia\/Shanghai/${SANDBOX}/Shanghai}"
dependency_definition="${dependency_definition//\/etc\/localtime/${SANDBOX}/localtime}"
eval "${dependency_definition}"

APT_UPDATE_STATUS=0
APT_INSTALL_STATUS=0
YUM_STATUS=0
CALLS=""
apt-get() {
	CALLS+="apt-get $*;"
	case "$1" in
		update) return "${APT_UPDATE_STATUS}" ;;
		install) return "${APT_INSTALL_STATUS}" ;;
		*) fail "unexpected apt-get call: $*" ;;
	esac
}
yum() {
	CALLS+="yum $*;"
	return "${YUM_STATUS}"
}

printf 'Shanghai fixture\n' > "${SANDBOX}/Shanghai"
for release in debian centos; do
	# A hard link reproduces the identical-file condition of a timezone symlink
	# while also working in Git Bash without Windows symlink privileges.
	for timezone_state in same_file different_file absent; do
		rm -f "${SANDBOX}/localtime"
		case "${timezone_state}" in
			same_file) ln "${SANDBOX}/Shanghai" "${SANDBOX}/localtime" ;;
			different_file) printf 'Existing timezone\n' > "${SANDBOX}/localtime" ;;
		esac
		CALLS=""
		installation_dependency || fail "${release}: dependencies failed with ${timezone_state} timezone"
		case "${timezone_state}" in
			same_file)
				[[ "${SANDBOX}/Shanghai" -ef "${SANDBOX}/localtime" ]] || fail "timezone link was replaced"
				assert_eq 'Shanghai fixture' "$(<"${SANDBOX}/localtime")" 'same-file timezone preserved'
				;;
			different_file) assert_eq 'Existing timezone' "$(<"${SANDBOX}/localtime")" 'custom timezone preserved' ;;
			absent) [[ ! -e "${SANDBOX}/localtime" ]] || fail "unexpected timezone file created" ;;
		esac
		if [[ "${release}" == centos ]]; then
			assert_eq 'yum install jq gzip wget curl unzip -y;' "${CALLS}" 'yum dependency command'
		else
			assert_eq 'apt-get update;apt-get install jq gzip wget curl unzip -y;' "${CALLS}" 'apt dependency commands'
		fi
	done
done

release=debian
CALLS=""
APT_UPDATE_STATUS=100
status=0
installation_dependency || status=$?
assert_eq 1 "${status}" 'apt update failure propagated'
assert_eq 'apt-get update;' "${CALLS}" 'failed update must not install packages'

CALLS=""
APT_UPDATE_STATUS=0
APT_INSTALL_STATUS=100
status=0
installation_dependency || status=$?
assert_eq 1 "${status}" 'apt install failure propagated'
assert_eq 'apt-get update;apt-get install jq gzip wget curl unzip -y;' "${CALLS}" 'apt install attempted'

release=centos
CALLS=""
YUM_STATUS=1
status=0
installation_dependency || status=$?
assert_eq 1 "${status}" 'yum failure propagated'
assert_eq 'yum install jq gzip wget curl unzip -y;' "${CALLS}" 'yum install attempted'

echo 'PASS: AnyTLS dependency failures and timezone preservation'
