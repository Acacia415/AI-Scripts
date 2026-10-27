#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export AI_SCRIPTS_SOURCE_ONLY=1
# shellcheck source=../tool.sh
source "$REPO_ROOT/tool.sh"
IPQUALITY_URL=https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
clear() { :; }

# 仅运行受控替身，包管理操作用标记代替；不执行真实上游或安装命令。
cat > "$TEST_ROOT/ipquality.sh" <<'EOF'
#!/bin/bash
install_packages(){
    prompt='Continue? (y/n): '
    read -p "$prompt" choice
    case "$choice" in
        y|Y|yes|Yes|YES) echo dependency-install ;;
        n|N|no|No|NO) echo cancelled; exit 0 ;;
        *) echo invalid-input; exit 1 ;;
    esac
    [[ ${FAIL_DEPENDENCY:-0} == 0 ]] || exit 1
}
check_IP(){
    echo "report-ipv$2"
    return "${REPORT_STATUS:-0}"
}
[[ ${NEED_DEPENDENCY:-0} == 0 ]] || install_packages
[[ ${EARLY_FAILURE:-0} == 0 ]] || exit "$EARLY_FAILURE"
IPV4=192.0.2.1 IPV6=2001:db8::1
IPV4work=${TEST_IPV4:-1} IPV4check=1
IPV6work=${TEST_IPV6:-0} IPV6check=${TEST_IPV6_CHECK:-1}
[[ $IPV4work -ne 0 && $IPV4check -ne 0 ]]&&check_IP "$IPV4" 4
[[ $IPV6work -ne 0 && $IPV6check -ne 0 ]]&&check_IP "$IPV6" 6
EOF
FIXTURE="$TEST_ROOT/ipquality.sh"
download_shell_script() {
    local path
    path=$(mktemp "$TEST_ROOT/download.XXXXXX.sh") || return 1
    cp -- "$FIXTURE" "$path" || return 1
    printf '%s\n' "$path" > "$TEST_ROOT/last-download"
    printf '%s\n' "$path"
}
check_run() {
    local expected=$1 input=${2:-} status=0 downloaded
    install_media_check <<< "$input" > "$TEST_ROOT/output" 2>&1 || status=$?
    [[ $status == "$expected" ]] || fail "expected $expected, got $status: $(<"$TEST_ROOT/output")"
    if (( expected == 0 )); then
        if grep -Eq '执行失败|退出码|兼容未应用' "$TEST_ROOT/output"; then
            fail "successful run printed an error: $(<"$TEST_ROOT/output")"
        fi
    else
        grep -q '执行失败' "$TEST_ROOT/output" || fail 'real failure was not reported'
    fi
    downloaded=$(<"$TEST_ROOT/last-download")
    [[ ! -e $downloaded ]] || fail 'download was not cleaned up'
}

check_run 0
grep -q report-ipv4 "$TEST_ROOT/output" || fail 'IPv4 report missing'
TEST_IPV6=1 check_run 0
grep -q report-ipv6 "$TEST_ROOT/output" || fail 'IPv6 report missing'
TEST_IPV4=0 TEST_IPV6=1 check_run 0
TEST_IPV6=1 TEST_IPV6_CHECK=0 check_run 0
if grep -q report-ipv6 "$TEST_ROOT/output"; then fail 'disabled IPv6 test ran'; fi
TEST_IPV4=0 TEST_IPV6=0 check_run 1
EARLY_FAILURE=1 check_run 1
REPORT_STATUS=42 check_run 1
grep -q '退出码：42' "$TEST_ROOT/output" || fail 'original report error code was lost'

NEED_DEPENDENCY=1 check_run 0 ''
grep -q dependency-install "$TEST_ROOT/output" || fail 'Enter did not select default installation'
grep -q report-ipv4 "$TEST_ROOT/output" || fail 'Enter did not continue testing'
NEED_DEPENDENCY=1 check_run 0 n
if grep -q 'dependency-install\|report-ipv' "$TEST_ROOT/output"; then fail 'cancel still ran work'; fi
NEED_DEPENDENCY=1 check_run 1 invalid
NEED_DEPENDENCY=1 FAIL_DEPENDENCY=1 check_run 1 y
status=0
NEED_DEPENDENCY=1 run_remote_script "$IPQUALITY_URL" test </dev/null > "$TEST_ROOT/output" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'EOF was mistaken for Enter'
if grep -q dependency-install "$TEST_ROOT/output"; then fail 'EOF installed dependencies'; fi

# 同样的脚本从其他地址运行时不做适配。
status=0
run_remote_script 'https://example.invalid/ip.sh' test > "$TEST_ROOT/output" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'unrelated URL received IPQuality compatibility changes'

# 未知末尾结构时弃用全部改写，保留原始失败，而不是追加 exit 0。
cp "$FIXTURE" "$TEST_ROOT/changed.sh"
printf '\nexit 42\n' >> "$TEST_ROOT/changed.sh"
cp "$TEST_ROOT/changed.sh" "$TEST_ROOT/original.sh"
normalize_remote_menu_exit "$IPQUALITY_URL" "$TEST_ROOT/changed.sh" test 2> "$TEST_ROOT/warning"
cmp -s "$TEST_ROOT/original.sh" "$TEST_ROOT/changed.sh" || fail 'unknown tail was modified'
grep -q '兼容未应用' "$TEST_ROOT/warning" || fail 'unknown structure did not warn'

# 可选联网验证仅比较源码补丁和语法，绝不执行下载的上游程序。
if [[ ${1:-} == --upstream ]]; then
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$IPQUALITY_URL" -o "$TEST_ROOT/upstream-original.sh"
    sed -i 's/\r$//' "$TEST_ROOT/upstream-original.sh"
    cp "$TEST_ROOT/upstream-original.sh" "$TEST_ROOT/upstream.sh"
    normalize_remote_menu_exit "$IPQUALITY_URL" "$TEST_ROOT/upstream.sh" test 2> "$TEST_ROOT/warning"
    [[ ! -s $TEST_ROOT/warning ]] || fail 'current upstream no longer matches compatibility rules'
    /bin/bash -n "$TEST_ROOT/upstream.sh"
    diff -u "$TEST_ROOT/upstream-original.sh" "$TEST_ROOT/upstream.sh" || [[ $? == 1 ]]
fi
printf 'PASS: IPQuality completion, input defaults and real failures\n'
