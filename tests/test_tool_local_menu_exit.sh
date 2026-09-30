#!/usr/bin/env bash
set -Eeuo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 只提取明确命名的函数/菜单，绝不执行源文件的顶层安装/初始化代码。
extract_function() {
    awk -v name="$2" '
        { key = $0; gsub(/[ \t\r]/, "", key) }
        !active && (key == name "(){" || key == "function" name "(){") { active = 1; found++; print; next }
        active && /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{[ \t\r]*$/ { active = 0 }
        active { print }
        END { if (found != 1) exit 1 }
    ' "$1"
}

check_menu() {
    local file=$1 name=$2 variable=$3 choice=$4
    local body="$TEST_ROOT/menu-body" runner="$TEST_ROOT/menu-runner.sh"
    extract_function "$REPO_ROOT/$file" "$name" | awk -v variable="$variable" '
        {
            key = $0; gsub(/[ \t\r]/, "", key)
            if (key == "case$" variable "in" || key == "case\"$" variable "\"in" ||
                key == "case${" variable "}in" || key == "case\"${" variable "}\"in") {
                active = 1; found++
            }
            if (active) print
            if (key == "esac") active = 0
        }
        END { if (found != 1) exit 1 }
    ' > "$body" || fail "$file 菜单结构无法识别"
    {
        printf '#!/bin/bash\nset -e\n'
        printf 'print_info() { :; }; print_success() { :; }; success() { :; }\n'
        printf 'print_error() { exit 98; }; warn() { exit 98; }; sleep() { exit 98; }\n'
        printf '%s=%q\n' "$variable" "$choice"
        printf 'test_menu() { while true; do\n'
        cat "$body"
        printf '\nreturn 97\ndone\n}\ntest_menu\n'
    } > "$runner"
    /bin/bash "$runner" > "$TEST_ROOT/output" 2>&1 || fail "$file 正常退出失败：$(<"$TEST_ROOT/output")"
    printf 'PASS: %s menu exit\n' "$file"
}

check_menu traffic_monitor.sh main_menu choice 0
check_menu iptables.sh main choice 0
check_menu nftables.sh main_menu choice 00
check_menu caddy_manager.sh caddy_main caddy_choice 0
check_menu nginx-manager.sh main_menu choice 0
check_menu modify_ip_preference.sh modify_ip_preference choice 0
check_menu dns_unlock.sh dns_unlock_menu choice 0
check_menu install_fail2ban.sh main choice 0
check_menu gost_v3.sh main_menu num 00
check_menu bbr3_manager.sh interactive_menu choice 0
check_menu anytls.sh start_menu num 00
check_menu saveanybot-manager.sh main choice 0
check_menu Hexo/hexo_manager.sh main choice 0

# AnyTLS 回车取消：只加载配置菜单，所有修改入口都替换为失败哨兵。
(
    eval "$(extract_function "$REPO_ROOT/anytls.sh" set_config)"
    # Referenced by the function loaded through eval.
    # shellcheck disable=SC2034
    Green_font_prefix='' Font_color_suffix=''
    check_installed_status() { :; }
    read_config() { exit 99; }
    apply_config_transaction() { exit 99; }
    start_menu() { exit 99; }
    set_config <<< ''
) > "$TEST_ROOT/output" 2>&1 || fail "AnyTLS 回车取消失败：$(<"$TEST_ROOT/output")"

# Hexo 目录存在而 public 尚未生成，回答 n 应取消向导，不应触发 set -e。
mkdir -p "$TEST_ROOT/blog"
for name in configure_caddy configure_nginx; do
    (
        eval "$(extract_function "$REPO_ROOT/Hexo/hexo_manager.sh" "$name")"
        BLOG_DIR="$TEST_ROOT/blog"
        print_info() { :; }
        print_warning() { :; }
        print_error() { :; }
        generate_static() { exit 99; }
        "$name" <<< n
    ) > "$TEST_ROOT/output" 2>&1 || fail "Hexo $name 取消失败：$(<"$TEST_ROOT/output")"
    status=0
    (
        eval "$(extract_function "$REPO_ROOT/Hexo/hexo_manager.sh" "$name")"
        # Referenced by the function loaded through eval.
        # shellcheck disable=SC2034
        BLOG_DIR="$TEST_ROOT/missing-blog"
        print_info() { :; }
        print_error() { :; }
        "$name"
    ) > "$TEST_ROOT/output" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "Hexo $name 丢失真实前置条件错误"
done
printf 'PASS: local cancellation tests\n'
