#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

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

cat > "$FAKE_BIN/lsattr" <<'EOF'
#!/usr/bin/env bash
target=''
for target in "$@"; do :; done
case "${target##*/}" in
  passwd) printf '%s %s\n' '----i-----------------' "$target" ;;
  shadow) printf '%s %s\n' '-----a----------------' "$target" ;;
  *) printf '%s %s\n' '----------------------' "$target" ;;
esac
EOF
chmod +x "$FAKE_BIN/lsattr"

cat > "$FAKE_BIN/chattr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CHATTR_LOG:?}"
EOF
chmod +x "$FAKE_BIN/chattr"

export PATH="$FAKE_BIN:$PATH"
export ENABLE_ROOT_LOGIN_SOURCE_ONLY=1
export ROOT_LOGIN_TEST_ROOT="$TEST_ROOT/rootfs"
export ROOT_LOGIN_BACKUP_ROOT="$TEST_ROOT/backups"

# shellcheck source=../enable_root_login.sh
source "$REPO_ROOT/enable_root_login.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ $actual == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local file=$1 expected=$2
  grep -Fq -- "$expected" "$file" || fail "$file 不包含：$expected"
}

check_root_login_root() { :; }
sleep() { :; }
chown() { :; }

SSH_ACTIVE=active
FAIL_RELOADS=0
FAIL_RESTARTS=0
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"

systemctl() {
  local action=${1:-}
  shift || true
  printf '%s %s\n' "$action" "$*" >> "$SYSTEMCTL_LOG"
  case "$action" in
    is-active)
      [[ ${*: -1} == ssh.service && $SSH_ACTIVE == active ]]
      ;;
    show)
      if [[ ${*: -1} == ssh.service ]]; then
        printf 'loaded\n'
      else
        printf 'not-found\n'
      fi
      ;;
    reload)
      if ((FAIL_RELOADS > 0)); then
        FAIL_RELOADS=$((FAIL_RELOADS - 1))
        return 1
      fi
      ;;
    restart)
      if ((FAIL_RESTARTS > 0)); then
        FAIL_RESTARTS=$((FAIL_RESTARTS - 1))
        return 1
      fi
      SSH_ACTIVE=active
      ;;
    stop)
      SSH_ACTIVE=inactive
      ;;
    *)
      fail "unexpected systemctl action: $action $*"
      ;;
  esac
}

FAIL_SSHD_CHECKS=0
SSHD_LOG="$TEST_ROOT/sshd.log"
sshd() {
  printf '%s\n' "$*" >> "$SSHD_LOG"
  [[ ${1:-} == -t && ${2:-} == -f && -n ${3:-} ]] || return 2
  if ((FAIL_SSHD_CHECKS > 0)); then
    FAIL_SSHD_CHECKS=$((FAIL_SSHD_CHECKS - 1))
    return 1
  fi
  grep -Fq 'Port 22' "$3"
}

export CHATTR_LOG="$TEST_ROOT/chattr.log"

FAIL_CHPASSWD=0
CHPASSWD_RECORD="$TEST_ROOT/chpasswd.record"
chpasswd() {
  local input
  printf 'args=%s\n' "$#" > "$CHPASSWD_RECORD"
  IFS= read -r input
  printf 'input=%s\n' "$input" >> "$CHPASSWD_RECORD"
  ((FAIL_CHPASSWD == 0)) || return 1
  printf 'root:new-password-hash\n' > "$ROOT_LOGIN_SHADOW_FILE"
}

INITIAL_CONFIG=$(cat <<'EOF'
# SSH server test configuration
Port 22
# PermitRootLogin prohibit-password
PasswordAuthentication no

Match User ubuntu
    # KbdInteractiveAuthentication no
    PasswordAuthentication no
EOF
)

reset_fixture() {
  rm -rf -- "${ROOT_LOGIN_TEST_ROOT:?}/etc"
  mkdir -p "$ROOT_LOGIN_SSHD_CONFIG_DIR" "$ROOT_LOGIN_SSH_CONFIG_DIR"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$ROOT_LOGIN_PASSWD_FILE"
  printf 'root:old-password-hash\n' > "$ROOT_LOGIN_SHADOW_FILE"
  printf '%s\n' "$INITIAL_CONFIG" > "$ROOT_LOGIN_SSHD_CONFIG"
  printf 'cloud override\n' > "$ROOT_LOGIN_SSHD_CONFIG_DIR/cloud.conf"
  printf 'hidden server override\n' > "$ROOT_LOGIN_SSHD_CONFIG_DIR/.hidden.conf"
  printf 'client override\n' > "$ROOT_LOGIN_SSH_CONFIG_DIR/cloud.conf"
  printf 'hidden client override\n' > "$ROOT_LOGIN_SSH_CONFIG_DIR/.hidden.conf"
  : > "$SYSTEMCTL_LOG"
  : > "$SSHD_LOG"
  : > "$CHATTR_LOG"
  rm -f -- "$CHPASSWD_RECORD"
  SSH_ACTIVE=active
  FAIL_RELOADS=0
  FAIL_RESTARTS=0
  FAIL_SSHD_CHECKS=0
  FAIL_CHPASSWD=0
  ROOT_LOGIN_LAST_BACKUP=''
  export ROOT_LOGIN_STAGE_FILE=''
  export SSH_SERVICE_NAME=''
}

assert_original_state() {
  assert_eq "$INITIAL_CONFIG" "$(<"$ROOT_LOGIN_SSHD_CONFIG")" 'SSH 主配置回滚'
  assert_contains "$ROOT_LOGIN_SHADOW_FILE" 'root:old-password-hash'
  assert_contains "$ROOT_LOGIN_SSHD_CONFIG_DIR/cloud.conf" 'cloud override'
  assert_contains "$ROOT_LOGIN_SSHD_CONFIG_DIR/.hidden.conf" 'hidden server override'
  assert_contains "$ROOT_LOGIN_SSH_CONFIG_DIR/cloud.conf" 'client override'
  assert_contains "$ROOT_LOGIN_SSH_CONFIG_DIR/.hidden.conf" 'hidden client override'
  assert_eq active "$SSH_ACTIVE" 'SSH 服务状态回滚'
}

# 成功路径：正确调用 chpasswd、清空两个目录、补齐全局配置并保留明文提示。
reset_fixture
if ! enable_root_login <<< 'RootPass123' > "$TEST_ROOT/success.out"; then
  fail 'root 登录配置成功路径返回失败'
fi
success_output=$(<"$TEST_ROOT/success.out")
assert_contains "$CHPASSWD_RECORD" 'args=0'
assert_contains "$CHPASSWD_RECORD" 'input=root:RootPass123'
assert_contains "$ROOT_LOGIN_SSHD_CONFIG" 'PermitRootLogin yes'
assert_contains "$ROOT_LOGIN_SSHD_CONFIG" 'PasswordAuthentication yes'
assert_contains "$ROOT_LOGIN_SSHD_CONFIG" 'KbdInteractiveAuthentication yes'
first_match_line=$(grep -n -m1 '^Match ' "$ROOT_LOGIN_SSHD_CONFIG" | cut -d: -f1)
for directive in PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication; do
  directive_line=$(grep -n -m1 "^${directive} yes$" "$ROOT_LOGIN_SSHD_CONFIG" | cut -d: -f1)
  ((directive_line < first_match_line)) || fail "$directive 未写入全局配置段"
done
[[ -z $(find "$ROOT_LOGIN_SSHD_CONFIG_DIR" -mindepth 1 -print -quit) ]] || fail 'sshd_config.d 未清空'
[[ -z $(find "$ROOT_LOGIN_SSH_CONFIG_DIR" -mindepth 1 -print -quit) ]] || fail 'ssh_config.d 未清空'
[[ $success_output == *'VPS 当前 root 密码：RootPass123'* ]] || fail '未按要求明文显示 root 密码'
[[ -d $ROOT_LOGIN_LAST_BACKUP ]] || fail '修改前备份不存在'
assert_contains "$ROOT_LOGIN_LAST_BACKUP/sshd_config.d/cloud.conf" 'cloud override'
assert_contains "$ROOT_LOGIN_LAST_BACKUP/sshd_config.d/.hidden.conf" 'hidden server override'
assert_contains "$SYSTEMCTL_LOG" 'reload ssh.service'
assert_contains "$CHATTR_LOG" "+i $ROOT_LOGIN_PASSWD_FILE"
assert_contains "$CHATTR_LOG" "+a $ROOT_LOGIN_SHADOW_FILE"

# sshd -t 失败时，密码不得修改，SSH 主配置和两个目录必须全部恢复。
reset_fixture
FAIL_SSHD_CHECKS=1
if enable_root_login <<< 'ValidationFail123' >/dev/null 2>&1; then
  fail 'sshd 配置验证失败时脚本仍返回成功'
fi
assert_original_state
[[ ! -e $CHPASSWD_RECORD ]] || fail 'sshd 验证失败后仍调用了 chpasswd'
[[ -z $(find "$(dirname "$ROOT_LOGIN_SSHD_CONFIG")" -maxdepth 1 -name '.sshd_config.ai-scripts.*' -print -quit) ]] \
  || fail 'sshd 验证失败后遗留暂存文件'

# 服务 reload/restart 都失败时，已修改的密码也必须与所有 SSH 文件一起恢复。
reset_fixture
FAIL_RELOADS=1
FAIL_RESTARTS=1
if enable_root_login <<< 'ServiceFail123' >/dev/null 2>&1; then
  fail 'SSH 服务应用失败时脚本仍返回成功'
fi
assert_contains "$CHPASSWD_RECORD" 'input=root:ServiceFail123'
assert_original_state

# chpasswd 失败同样必须回滚已写入的 SSH 配置和已删除的 include 文件。
reset_fixture
FAIL_CHPASSWD=1
if enable_root_login <<< 'PasswordFail123' >/dev/null 2>&1; then
  fail 'chpasswd 失败时脚本仍返回成功'
fi
assert_original_state

echo 'PASS: enable_root_login A06 tests'
