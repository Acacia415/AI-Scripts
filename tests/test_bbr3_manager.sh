#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$message (expected=$expected actual=$actual)"
}

# shellcheck source=../bbr3_manager.sh
source "$SCRIPT_DIR/bbr3_manager.sh"

valid_backup_id '20260817T120000Z-123' || fail 'valid backup id rejected'
valid_backup_id '20260817T120000Z-123-1' || fail 'valid backup id with counter rejected'
if valid_backup_id '../etc/passwd'; then
    fail 'path traversal accepted as backup id'
fi

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -m) printf '%s\n' "${MOCK_UNAME_M:-x86_64}" ;;
    -r) printf '%s\n' "${MOCK_UNAME_R:-6.18.1-test}" ;;
    -s) printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
    *) printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
esac
EOF

cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TEST_TMP/bin/wget" <<'EOF'
#!/usr/bin/env bash
output="${2:-}"
url="${3:-}"
if [[ "$url" == "https://official.invalid/archive.key" ]]; then
    exit 8
fi
printf 'fallback-key\n' > "$output"
EOF

cat > "$TEST_TMP/bin/gpg" <<'EOF'
#!/usr/bin/env bash
output=""
input="${*: -1}"
while (( $# > 0 )); do
    if [[ "$1" == "-o" ]]; then
        output="$2"
        shift 2
        continue
    fi
    shift
done
cp -- "$input" "$output"
EOF

cat > "$TEST_TMP/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
package="${2:-}"
case "$package" in
    linux-xanmod-lts-x64v2)
        printf '  Candidate: 6.18.1-xanmod1\n'
        ;;
    *)
        printf '  Candidate: (none)\n'
        ;;
esac
EOF

cat > "$TEST_TMP/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_DPKG_EMPTY:-0}" == "1" ]]; then
    exit 1
fi
cat <<'DATA'
rc 	linux-image-old-xanmod1
ii 	linux-headers-6.18.1-xanmod1
ii 	linux-image-6.18.1-xanmod1
DATA
EOF
chmod +x "$TEST_TMP/bin/uname" "$TEST_TMP/bin/curl" "$TEST_TMP/bin/wget" "$TEST_TMP/bin/gpg" \
    "$TEST_TMP/bin/apt-cache" "$TEST_TMP/bin/dpkg-query"
PATH="$TEST_TMP/bin:$PATH"
export MOCK_UNAME_S=MINGW64_NT

export MOCK_UNAME_M=aarch64
host_supported || fail 'ARM64 host was rejected'
assert_eq 'arm64-external' "$HOST_MODE" 'ARM64 did not select external manager'
arm_json=$(status_json)
[[ "$arm_json" == *'"mode":"arm64-external"'* ]] || fail 'ARM64 JSON mode missing'
export MOCK_UNAME_M=x86_64

XANMOD_KEY_URL='https://official.invalid/archive.key'
XANMOD_KEY_FALLBACK_URL='https://fallback.invalid/archive.key'
download_xanmod_key "$TEST_TMP/xanmod.gpg" 2>/dev/null || fail 'key fallback failed'
assert_eq 'fallback-key' "$(<"$TEST_TMP/xanmod.gpg")" 'fallback key content mismatch'

if xanmod_package_available linux-xanmod-x64v3; then
    fail 'Candidate: (none) treated as available'
fi
xanmod_package_available linux-xanmod-lts-x64v2 || fail 'real candidate rejected'

images=$(list_installed_xanmod_images)
assert_eq 'linux-image-6.18.1-xanmod1' "$images" 'dpkg status filtering failed'

CPUINFO_FILE="$TEST_TMP/cpuinfo"
cat > "$CPUINFO_FILE" <<'EOF'
flags : fpu mmx fxsr sse2 cmov cx8 syscall lm cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave
EOF
level=$(detect_psabi_level)
assert_eq '3' "$level" 'x86-64 psABI detection failed'

installed_manager_package() { return 0; }
detect_psabi_level() { printf '2\n'; }
selected=$(select_xanmod_package)
assert_eq 'linux-xanmod-lts-x64v2' "$selected" 'package fallback failed'

escaped=$(json_escape $'a"b\\c\n')
assert_eq 'a\"b\\c\n' "$escaped" 'JSON escaping failed'

assert_eq 'bbr,cubic,reno' "$(safe_token 'bbr,cubic,reno')" 'algorithm list separators removed'

BACKUP_ROOT="$TEST_TMP/backups"
STATE_DIR="$TEST_TMP/state"
SYSCTL_FILE="$TEST_TMP/etc/sysctl.d/99-bbr3.conf"
REPO_FILE="$TEST_TMP/etc/apt/xanmod.list"
KEYRING_FILE="$TEST_TMP/etc/apt/xanmod.gpg"
ARM_SYSCTL_FILE="$TEST_TMP/etc/sysctl.d/99-custom.conf"
MANAGED_SYSCTL_MARKER="$STATE_DIR/managed-sysctl"
MANAGED_REPO_MARKER="$STATE_DIR/managed-repo"
MANAGED_KEY_MARKER="$STATE_DIR/managed-key"
mkdir -p "$(dirname "$SYSCTL_FILE")"
printf 'before\n' > "$SYSCTL_FILE"
printf 'arm-before\n' > "$ARM_SYSCTL_FILE"
export MOCK_DPKG_EMPTY=1
create_backup test >/dev/null
first_backup=$CURRENT_BACKUP_ID
printf 'after\n' > "$SYSCTL_FILE"
printf 'arm-after\n' > "$ARM_SYSCTL_FILE"
restore_backup_files "$first_backup"
assert_eq 'before' "$(<"$SYSCTL_FILE")" 'configuration restore failed'
assert_eq 'arm-before' "$(<"$ARM_SYSCTL_FILE")" 'ARM configuration restore failed'
create_backup test >/dev/null
second_backup=$CURRENT_BACKUP_ID
[[ "$first_backup" != "$second_backup" ]] || fail 'backup id collision was not avoided'
unset MOCK_DPKG_EMPTY

printf 'PASS: bbr3_manager tests\n'
