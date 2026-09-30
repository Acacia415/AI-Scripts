#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export AI_SCRIPTS_SOURCE_ONLY=1
# shellcheck source=../tool.sh
source "$REPO_ROOT/tool.sh"

SNELL_URL='https://raw.githubusercontent.com/xOS/Snell/master/Snell.sh'
SS_URL='https://raw.githubusercontent.com/xOS/Shadowsocks-Rust/master/ss-rust.sh'
HY_URL='https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/hysteria.sh'
ACME_URL='https://raw.githubusercontent.com/Acacia415/acme-script/refs/heads/main/acme.sh'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 下载替身只复制沙箱文件；不执行第三方安装操作。
download_shell_script() {
    local path
    path=$(mktemp "$TEST_ROOT/download.XXXXXX.sh") || return 1
    cp -- "$FIXTURE" "$path" || return 1
    printf '%s\n' "$path" > "$TEST_ROOT/last-download"
    printf '%s\n' "$path"
}

check_run() {
    local expected=$1 url=$2 status=0 downloaded
    shift 2
    run_remote_script "$url" '菜单测试' "$@" > "$TEST_ROOT/output" 2>&1 || status=$?
    [[ $status == "$expected" ]] || fail "期望退出码 $expected，实际 $status：$(<"$TEST_ROOT/output")"
    if (( expected == 0 )); then
        if grep -q '执行失败\|忽略上游' "$TEST_ROOT/output"; then
            fail '正常退出仍然显示失败或忽略错误提示'
        fi
    else
        grep -q "退出码：${expected}" "$TEST_ROOT/output" || fail '真正的失败未被报告'
    fi
    downloaded=$(<"$TEST_ROOT/last-download")
    [[ ! -e $downloaded ]] || fail '执行结束后下载临时文件未清理'
}

cat > "$TEST_ROOT/snell.sh" <<'EOF'
#!/bin/bash
checkRoot() { [[ ${TEST_ROOT_FAILURE:-0} != 1 ]] || exit 1; }
installSnell() { exit 1; }
setConfig(){
    modify=${1:-}
    [[ -z "${modify}" ]] && echo "已取消..." && exit 1
    installSnell
}
startMenu(){
    checkRoot
    num=$2
    if [[ $1 == update ]]; then
        case "$num" in
            0) printf 'update-script\n' ;;
            1) installSnell ;;
            config) setConfig "${3:-}" ;;
            42) exit 42 ;;
            130) exit 130 ;;
            00) exit 1 ;;
            *) exit 2 ;;
        esac
    elif [[ $1 == upgrade ]]; then
        case "$num" in
            1) installSnell ;;
            00) exit 1 ;;
            *) exit 2 ;;
        esac
    else
        case "$num" in
            1) installSnell ;;
            00) exit 1 ;;
            *) exit 2 ;;
        esac
    fi
}
otherMenu(){
    case "$num" in
        00) exit 1 ;;
    esac
}
if [[ $1 == other ]]; then num=00; otherMenu; else startMenu "$@"; fi
EOF

FIXTURE="$TEST_ROOT/snell.sh"
for mode in update upgrade new; do
    check_run 0 "$SNELL_URL" "$mode" 00
    check_run 1 "$SNELL_URL" "$mode" 1
done
check_run 0 "$SNELL_URL" update 0
grep -q update-script "$TEST_ROOT/output" || fail '更新脚本选项 0 被改成了退出'
check_run 42 "$SNELL_URL" update 42
check_run 130 "$SNELL_URL" update 130
TEST_ROOT_FAILURE=1 check_run 1 "$SNELL_URL" update 00
check_run 1 "$SNELL_URL" other 00
check_run 0 "$SNELL_URL" update config
check_run 1 "$SNELL_URL" update config 1
# 同名菜单在其他下载地址中不适配。
check_run 1 'https://example.invalid/Snell.sh' new 00

cat > "$TEST_ROOT/ss.sh" <<'EOF'
#!/bin/bash
check_root() { [[ ${TEST_ROOT_FAILURE:-0} != 1 ]] || exit 1; }
install() { exit 1; }
set_config(){
    modify=${1:-}
    [[ -z "${modify}" ]] && echo "已取消..." && exit 1
    install
}
shadowtls_menu(){
    check_root
    stls_num=$1
    case "$stls_num" in
        1)
            install
            ;;
        00)
            exit 1
            ;;
    esac
}
start_menu(){
    check_root
    num=$1
    case "$num" in
        config) set_config "${2:-}" ;;
        1)
            install
            ;;
        00)
            exit 1
            ;;
    esac
}
if [[ $1 == shadowtls ]]; then shadowtls_menu "$2"; else start_menu "$2" "${3:-}"; fi
EOF

FIXTURE="$TEST_ROOT/ss.sh"
for mode in main shadowtls; do
    check_run 0 "$SS_URL" "$mode" 00
    check_run 1 "$SS_URL" "$mode" 1
    TEST_ROOT_FAILURE=1 check_run 1 "$SS_URL" "$mode" 00
done
check_run 0 "$SS_URL" main config
check_run 1 "$SS_URL" main config 1

cat > "$TEST_ROOT/hy.sh" <<'EOF'
#!/bin/bash
insthysteria() { exit 1; }
cancel_domain() {
    red "将退出脚本"
    exit 1
}
red() { :; }
hysteriaswitch(){
    case $menuInput in
        * ) exit 1 ;;
    esac
}
menu() {
    menuInput=$1
    case $menuInput in
        1 ) insthysteria ;;
        2 ) cancel_domain ;;
        3 ) hysteriaswitch ;;
        * ) exit 1 ;;
    esac
}
menu "$1"
EOF

FIXTURE="$TEST_ROOT/hy.sh"
check_run 0 "$HY_URL" 0
for choice in 1 3 bad; do check_run 1 "$HY_URL" "$choice"; done
check_run 0 "$HY_URL" 2

cat > "$TEST_ROOT/acme.sh" <<'EOF'
#!/bin/bash
check_80(){
    yn=$1
    if [[ $yn =~ "Y"|"y" ]]; then
        echo terminate-process
    else
        exit 1
    fi
}
inst_acme() { exit 1; }
cancel_domain() {
    red "将退出脚本"
    exit 1
}
red() { :; }
menu() {
    menuInput=$1
    case "$menuInput" in
        1 ) inst_acme ;;
        3 ) check_80 "${2:-n}"; inst_acme ;;
        4 ) cancel_domain ;;
        * ) exit 1 ;;
    esac
}
menu "$@"
EOF
FIXTURE="$TEST_ROOT/acme.sh"
check_run 0 "$ACME_URL" 0
check_run 0 "$ACME_URL" 3 n
if grep -q terminate-process "$TEST_ROOT/output"; then fail '取消后仍然结束占用端口的进程'; fi
check_run 1 "$ACME_URL" 3 y
check_run 1 "$ACME_URL" 1
check_run 0 "$ACME_URL" 4
check_run 1 "$ACME_URL" bad

# 兼容处理可重复应用；上游已修复的 exit 0 不产生重复分支。
for profile in snell ss hy acme; do
    case "$profile" in
        snell) url=$SNELL_URL ;;
        ss) url=$SS_URL ;;
        hy) url=$HY_URL ;;
        acme) url=$ACME_URL ;;
    esac
    cp "$TEST_ROOT/$profile.sh" "$TEST_ROOT/once.sh"
    normalize_remote_menu_exit "$url" "$TEST_ROOT/once.sh" '幂等测试'
    cp "$TEST_ROOT/once.sh" "$TEST_ROOT/twice.sh"
    normalize_remote_menu_exit "$url" "$TEST_ROOT/twice.sh" '幂等测试'
    cmp -s "$TEST_ROOT/once.sh" "$TEST_ROOT/twice.sh" || fail "$profile 重复处理改变内容"
done

# 上游菜单变量变化或分支多出命令：放弃整份候选，绝不部分修改。
sed 's/case "\$num" in/case "${num}" in/g' "$TEST_ROOT/snell.sh" > "$TEST_ROOT/changed.sh"
cp "$TEST_ROOT/changed.sh" "$TEST_ROOT/original.sh"
normalize_remote_menu_exit "$SNELL_URL" "$TEST_ROOT/changed.sh" '结构变化测试' 2> "$TEST_ROOT/warning"
cmp -s "$TEST_ROOT/original.sh" "$TEST_ROOT/changed.sh" || fail '未知结构被修改'
grep -q '退出菜单兼容未应用' "$TEST_ROOT/warning" || fail '未知结构缺少提示'
FIXTURE="$TEST_ROOT/changed.sh"
check_run 1 "$SNELL_URL" new 00

sed 's/exit 1$/exit 1; echo unexpected/' "$TEST_ROOT/ss.sh" > "$TEST_ROOT/changed.sh"
cp "$TEST_ROOT/changed.sh" "$TEST_ROOT/original.sh"
normalize_remote_menu_exit "$SS_URL" "$TEST_ROOT/changed.sh" '分支变化测试' 2>/dev/null
cmp -s "$TEST_ROOT/original.sh" "$TEST_ROOT/changed.sh" || fail '额外退出操作被意外修改'

# 候选文件语法无效时使用原件；无法安装候选文件时不得执行。
cp "$TEST_ROOT/snell.sh" "$TEST_ROOT/unchanged.sh"
(
    awk() { printf 'if then\n'; }
    normalize_remote_menu_exit "$SNELL_URL" "$TEST_ROOT/unchanged.sh" '语法保护测试' 2>/dev/null
)
cmp -s "$TEST_ROOT/snell.sh" "$TEST_ROOT/unchanged.sh" || fail '语法检查失败后原件被修改'
(
    mv() { return 1; }
    if normalize_remote_menu_exit "$SNELL_URL" "$TEST_ROOT/unchanged.sh" '文件失败测试' 2>/dev/null; then
        fail '候选文件安装失败却返回成功'
    fi
)
cmp -s "$TEST_ROOT/snell.sh" "$TEST_ROOT/unchanged.sh" || fail '文件安装失败后原件被修改'

printf 'PASS: remote menu exit compatibility tests\n'

# 可选联网检查：只运行从上游提取的 case 语句，并固定选择退出项。
# 不 source/执行完整上游脚本，也不调用其安装、系统检测或网络操作。
if [[ ${1:-} == --upstream ]]; then
    for profile in snell ss hy acme; do
        case "$profile" in
            snell) url=$SNELL_URL; expected_cases=3 ;;
            ss) url=$SS_URL; expected_cases=2 ;;
            hy) url=$HY_URL; expected_cases=1 ;;
            acme) url=$ACME_URL; expected_cases=1 ;;
        esac
        original="$TEST_ROOT/live-$profile-original.sh"
        normalized="$TEST_ROOT/live-$profile-normalized.sh"
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$url" -o "$original"
        sed -i 's/\r$//' "$original"
        /bin/bash -n "$original"
        cp "$original" "$normalized"
        normalize_remote_menu_exit "$url" "$normalized" "$profile" 2> "$TEST_ROOT/warning"
        [[ ! -s $TEST_ROOT/warning ]] || fail "$profile 上游结构无法匹配"
        /bin/bash -n "$normalized"
        # 展示实际补丁，便于检查是否仅改变正常退出分支。
        diff -u "$original" "$normalized" || [[ $? == 1 ]]
        for state in original normalized; do
            awk -v profile="$profile" -v base="$TEST_ROOT/case-$profile-$state-" '
                function compact(line) { gsub(/[ \t]/, "", line); return line }
                {
                    key = compact($0)
                    if (profile == "snell" && key == "startMenu(){") menu = 1
                    if (profile == "ss" && (key == "start_menu(){" || key == "shadowtls_menu(){")) menu = 1
                    if ((profile == "hy" || profile == "acme") && key == "menu(){") menu = 1
                    if (menu && (key == "case\"$num\"in" || key == "case\"$stls_num\"in" || key == "case$menuInputin" || key == "case\"$menuInput\"in")) {
                        active = 1
                        count++
                        file = base count ".sh"
                    }
                    if (active) print > file
                    if (key == "esac" && active) { close(file); active = 0 }
                    if ($0 ~ /^}[ \t]*$/) menu = 0
                }
            ' "$TEST_ROOT/live-$profile-$state.sh"
            cases=("$TEST_ROOT/case-$profile-$state-"*.sh)
            [[ ${#cases[@]} == "$expected_cases" ]] || fail "$profile 上游菜单数量异常"
            for menu_case in "${cases[@]}"; do
                status=0
                num=00 stls_num=00 menuInput=0 /bin/bash "$menu_case" || status=$?
                if [[ $state == normalized ]]; then
                    [[ $status == 0 ]] || fail "$profile 上游正常退出仍返回 $status"
                else
                    [[ $status == 0 || $status == 1 ]] || fail "$profile 上游退出行为已变化：$status"
                fi
            done
        done
        printf 'PASS: latest upstream %s (%s exit branches)\n' "$profile" "$expected_cases"
    done
fi
