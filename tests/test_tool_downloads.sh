#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u

output=''
while (($#)); do
    case "$1" in
        -o|--output)
            output=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n $output ]] || exit 2
printf '%s\n' "$output" > "$FAKE_CURL_OUTPUT_RECORD"

case "${FAKE_CURL_MODE:-valid}" in
    http_error)
        exit 22
        ;;
    invalid)
        printf '#!/bin/bash\nif then\n' > "$output"
        ;;
    valid)
        cp "$FAKE_CURL_SOURCE" "$output"
        ;;
    *)
        exit 3
        ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

# Git Bash 在 Windows 文件系统上无法执行 GNU install 的部分 chmod 操作；
# 这里仅替代测试沙箱内的 install，生产脚本仍使用系统 install。
cat > "$FAKE_BIN/install" <<'EOF'
#!/usr/bin/env bash
set -e

if [[ ${1:-} == -d ]]; then
    shift
    [[ ${1:-} == -m ]] && shift 2
    mkdir -p -- "$@"
    exit 0
fi

[[ ${1:-} == -m ]] && shift 2
cp -- "$1" "$2"
EOF
chmod +x "$FAKE_BIN/install"

export PATH="$FAKE_BIN:$PATH"
export AI_SCRIPTS_SOURCE_ONLY=1
export AI_SCRIPTS_NO_EXEC=1
export AI_SCRIPTS_LOCAL_SCRIPT="$TEST_ROOT/install/tool.sh"
export AI_SCRIPTS_COMMAND_PATH="$TEST_ROOT/bin-install/p"
export AI_SCRIPTS_BACKUP_ROOT="$TEST_ROOT/backups"
export FAKE_CURL_OUTPUT_RECORD="$TEST_ROOT/curl-output"

# shellcheck source=../tool.sh
source "$REPO_ROOT/tool.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file=$1 expected=$2
    grep -Fq "$expected" "$file" || fail "$file 不包含预期内容：$expected"
}

# HTTP 错误不能留下可执行临时文件。
export FAKE_CURL_MODE=http_error
if download_shell_script 'https://example.invalid/not-found.sh' 'HTTP 错误测试' >/dev/null; then
    fail 'HTTP 错误被当成下载成功'
fi
failed_temp=$(<"$FAKE_CURL_OUTPUT_RECORD")
[[ ! -e $failed_temp ]] || fail 'HTTP 错误后临时文件未清理'

# 非法 Shell 内容不能执行，也不能遗留临时文件。
export FAKE_CURL_MODE=invalid
if download_shell_script 'https://example.invalid/invalid.sh' '语法错误测试' >/dev/null 2>&1; then
    fail '语法错误脚本通过了检查'
fi
invalid_temp=$(<"$FAKE_CURL_OUTPUT_RECORD")
[[ ! -e $invalid_temp ]] || fail '语法错误后临时文件未清理'

# 合法脚本可以接收参数执行，执行完成后自动清理。
cat > "$TEST_ROOT/remote-valid.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$TEST_REMOTE_RESULT"
EOF
export FAKE_CURL_MODE=valid
export FAKE_CURL_SOURCE="$TEST_ROOT/remote-valid.sh"
export TEST_REMOTE_RESULT="$TEST_ROOT/remote-result"
run_remote_script 'https://example.invalid/valid.sh' '合法脚本测试' 'argument-ok'
assert_file_contains "$TEST_REMOTE_RESULT" 'argument-ok'
executed_temp=$(<"$FAKE_CURL_OUTPUT_RECORD")
[[ ! -e $executed_temp ]] || fail '执行完成后临时脚本未清理'

# 两次下载必须使用不同的随机临时路径。
first_temp=$(download_shell_script 'https://example.invalid/one.sh' '随机路径测试一')
first_record=$(<"$FAKE_CURL_OUTPUT_RECORD")
second_temp=$(download_shell_script 'https://example.invalid/two.sh' '随机路径测试二')
second_record=$(<"$FAKE_CURL_OUTPUT_RECORD")
[[ $first_record != "$second_record" ]] || fail '两次下载复用了同一临时路径'
rm -f -- "$first_temp" "$second_temp"

# 更新成功时同时替换两个入口，并保留可恢复的旧版本备份。
mkdir -p "$(dirname "$AI_SCRIPTS_LOCAL_SCRIPT")" "$(dirname "$AI_SCRIPTS_COMMAND_PATH")"
printf '#!/bin/bash\necho old-local\n' > "$AI_SCRIPTS_LOCAL_SCRIPT"
printf '#!/bin/bash\necho old-command\n' > "$AI_SCRIPTS_COMMAND_PATH"
cat > "$TEST_ROOT/new-tool.sh" <<'EOF'
#!/usr/bin/env bash
if [[ ${AI_SCRIPTS_SOURCE_ONLY:-0} == 1 ]]; then
    exit 0
fi
echo new-tool
EOF
export FAKE_CURL_SOURCE="$TEST_ROOT/new-tool.sh"
update_script
assert_file_contains "$AI_SCRIPTS_LOCAL_SCRIPT" 'echo new-tool'
assert_file_contains "$AI_SCRIPTS_COMMAND_PATH" 'echo new-tool'

backup_dir=$(find "$AI_SCRIPTS_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n $backup_dir ]] || fail '更新前备份未创建'
assert_file_contains "$backup_dir/tool.sh" 'echo old-local'
assert_file_contains "$backup_dir/p" 'echo old-command'

restore_toolbox_backup "$backup_dir"
assert_file_contains "$AI_SCRIPTS_LOCAL_SCRIPT" 'echo old-local'
assert_file_contains "$AI_SCRIPTS_COMMAND_PATH" 'echo old-command'

# 下载失败时不得修改现有工具箱。
export FAKE_CURL_MODE=http_error
if update_script >/dev/null 2>&1; then
    fail '下载失败的更新返回成功'
fi
assert_file_contains "$AI_SCRIPTS_LOCAL_SCRIPT" 'echo old-local'
assert_file_contains "$AI_SCRIPTS_COMMAND_PATH" 'echo old-command'

# 快捷命令双目标安装的第二步失败时，第一步也必须回滚。
eval "$(declare -f atomic_install_file | sed '1s/atomic_install_file/real_atomic_install_file/')"
fail_command_install=1
atomic_install_file() {
    if [[ $2 == "$AI_SCRIPTS_COMMAND_PATH" && $fail_command_install == 1 ]]; then
        fail_command_install=0
        return 1
    fi
    real_atomic_install_file "$@"
}
export FAKE_CURL_MODE=valid
if install_toolbox_copies "$TEST_ROOT/new-tool.sh" >/dev/null 2>&1; then
    fail '第二个工具箱入口安装失败时事务仍返回成功'
fi
assert_file_contains "$AI_SCRIPTS_LOCAL_SCRIPT" 'echo old-local'
assert_file_contains "$AI_SCRIPTS_COMMAND_PATH" 'echo old-command'

printf 'PASS: tool download and update tests\n'
