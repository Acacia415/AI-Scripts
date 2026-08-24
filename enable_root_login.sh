#!/usr/bin/env bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

ROOT_LOGIN_BACKUP_ROOT="${ROOT_LOGIN_BACKUP_ROOT:-/var/backups/ai-scripts/root-login}"
ROOT_LOGIN_LAST_BACKUP=''
ROOT_LOGIN_STAGE_FILE=''
SSH_SERVICE_NAME=''

# 测试模式只在被 source 时允许把固定系统路径映射到沙箱。
if [[ ${ENABLE_ROOT_LOGIN_SOURCE_ONLY:-0} == 1 && -n ${ROOT_LOGIN_TEST_ROOT:-} ]]; then
  ROOT_LOGIN_PASSWD_FILE="${ROOT_LOGIN_TEST_ROOT}/etc/passwd"
  ROOT_LOGIN_SHADOW_FILE="${ROOT_LOGIN_TEST_ROOT}/etc/shadow"
  ROOT_LOGIN_SSHD_CONFIG="${ROOT_LOGIN_TEST_ROOT}/etc/ssh/sshd_config"
  ROOT_LOGIN_SSHD_CONFIG_DIR="${ROOT_LOGIN_TEST_ROOT}/etc/ssh/sshd_config.d"
  ROOT_LOGIN_SSH_CONFIG_DIR="${ROOT_LOGIN_TEST_ROOT}/etc/ssh/ssh_config.d"
else
  ROOT_LOGIN_PASSWD_FILE='/etc/passwd'
  ROOT_LOGIN_SHADOW_FILE='/etc/shadow'
  ROOT_LOGIN_SSHD_CONFIG='/etc/ssh/sshd_config'
  ROOT_LOGIN_SSHD_CONFIG_DIR='/etc/ssh/sshd_config.d'
  ROOT_LOGIN_SSH_CONFIG_DIR='/etc/ssh/ssh_config.d'
fi

check_root_login_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本。${NC}" >&2
    return 1
  fi
}

is_managed_root_login_path() {
  local target=$1
  case "$target" in
    "$ROOT_LOGIN_PASSWD_FILE"|"$ROOT_LOGIN_SHADOW_FILE"|"$ROOT_LOGIN_SSHD_CONFIG"|\
    "$ROOT_LOGIN_SSHD_CONFIG_DIR"|"$ROOT_LOGIN_SSH_CONFIG_DIR")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remove_managed_root_login_path() {
  local target=$1
  if [[ -z $target || $target == / ]] || ! is_managed_root_login_path "$target"; then
    echo -e "${RED}拒绝删除未经验证的路径：${target:-空}${NC}" >&2
    return 1
  fi
  rm -rf -- "$target"
}

backup_root_login_path() {
  local source_path=$1 backup_dir=$2 backup_name=$3
  if [[ -e $source_path || -L $source_path ]]; then
    cp -a -- "$source_path" "$backup_dir/$backup_name"
  else
    : > "$backup_dir/$backup_name.missing"
  fi
}

file_has_attribute() {
  local target=$1 attribute=$2 attributes
  command -v lsattr >/dev/null 2>&1 || return 1
  attributes=$(lsattr -d -- "$target" 2>/dev/null | awk 'NR == 1 {print $1}') || return 1
  [[ $attributes == *"$attribute"* ]]
}

create_root_login_backup() {
  local backup_prefix backup_dir
  umask 077
  backup_prefix="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 700 "$ROOT_LOGIN_BACKUP_ROOT" || return 1
  backup_dir=$(mktemp -d "${ROOT_LOGIN_BACKUP_ROOT}/${backup_prefix}.XXXXXX") || return 1
  chmod 700 "$backup_dir" || return 1

  if ! backup_root_login_path "$ROOT_LOGIN_PASSWD_FILE" "$backup_dir" passwd \
    || ! backup_root_login_path "$ROOT_LOGIN_SHADOW_FILE" "$backup_dir" shadow \
    || ! backup_root_login_path "$ROOT_LOGIN_SSHD_CONFIG" "$backup_dir" sshd_config \
    || ! backup_root_login_path "$ROOT_LOGIN_SSHD_CONFIG_DIR" "$backup_dir" sshd_config.d \
    || ! backup_root_login_path "$ROOT_LOGIN_SSH_CONFIG_DIR" "$backup_dir" ssh_config.d; then
    echo -e "${RED}创建 root 登录配置备份失败：${backup_dir}${NC}" >&2
    return 1
  fi

  file_has_attribute "$ROOT_LOGIN_PASSWD_FILE" i && : > "$backup_dir/passwd.attr-i"
  file_has_attribute "$ROOT_LOGIN_PASSWD_FILE" a && : > "$backup_dir/passwd.attr-a"
  file_has_attribute "$ROOT_LOGIN_SHADOW_FILE" i && : > "$backup_dir/shadow.attr-i"
  file_has_attribute "$ROOT_LOGIN_SHADOW_FILE" a && : > "$backup_dir/shadow.attr-a"
  systemctl is-active --quiet "${SSH_SERVICE_NAME}.service" 2>/dev/null \
    && : > "$backup_dir/service-active"

  # 属性状态已单独记录，备份副本本身必须保持可读取、可恢复。
  if command -v chattr >/dev/null 2>&1; then
    chattr -i "$backup_dir/passwd" "$backup_dir/shadow" 2>/dev/null || true
    chattr -a "$backup_dir/passwd" "$backup_dir/shadow" 2>/dev/null || true
  fi
  ROOT_LOGIN_LAST_BACKUP=$backup_dir
}

restore_root_login_path() {
  local backup_dir=$1 backup_name=$2 target_path=$3
  if ! is_managed_root_login_path "$target_path"; then
    return 1
  fi
  if [[ -e $backup_dir/$backup_name || -L $backup_dir/$backup_name ]]; then
    remove_managed_root_login_path "$target_path" || return 1
    mkdir -p "$(dirname "$target_path")" || return 1
    cp -a -- "$backup_dir/$backup_name" "$target_path"
  elif [[ -f $backup_dir/$backup_name.missing ]]; then
    remove_managed_root_login_path "$target_path"
  else
    echo -e "${RED}备份缺少 ${backup_name} 状态记录。${NC}" >&2
    return 1
  fi
}

remove_account_file_protection() {
  command -v chattr >/dev/null 2>&1 || return 0
  chattr -i "$ROOT_LOGIN_PASSWD_FILE" "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || true
  chattr -a "$ROOT_LOGIN_PASSWD_FILE" "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || true
}

restore_account_file_protection() {
  local backup_dir=$1 status=0
  command -v chattr >/dev/null 2>&1 || return 0
  chattr -i "$ROOT_LOGIN_PASSWD_FILE" "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || true
  chattr -a "$ROOT_LOGIN_PASSWD_FILE" "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || true

  [[ ! -f $backup_dir/passwd.attr-i ]] \
    || chattr +i "$ROOT_LOGIN_PASSWD_FILE" 2>/dev/null || status=1
  [[ ! -f $backup_dir/passwd.attr-a ]] \
    || chattr +a "$ROOT_LOGIN_PASSWD_FILE" 2>/dev/null || status=1
  [[ ! -f $backup_dir/shadow.attr-i ]] \
    || chattr +i "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || status=1
  [[ ! -f $backup_dir/shadow.attr-a ]] \
    || chattr +a "$ROOT_LOGIN_SHADOW_FILE" 2>/dev/null || status=1
  return "$status"
}

detect_ssh_service() {
  local candidate load_state
  for candidate in ssh sshd; do
    if systemctl is-active --quiet "${candidate}.service" 2>/dev/null; then
      SSH_SERVICE_NAME=$candidate
      return 0
    fi
  done
  for candidate in ssh sshd; do
    load_state=$(systemctl show -p LoadState --value "${candidate}.service" 2>/dev/null || true)
    if [[ -n $load_state && $load_state != not-found ]]; then
      SSH_SERVICE_NAME=$candidate
      return 0
    fi
  done
  echo -e "${RED}未找到 ssh.service 或 sshd.service，未进行任何修改。${NC}" >&2
  return 1
}

write_sshd_directive() {
  local input_file=$1 output_file=$2 directive=$3 value=$4
  awk -v directive="$directive" -v value="$value" '
    BEGIN {
      in_match = 0
      global_written = 0
      directive_lower = tolower(directive)
    }
    {
      original = $0
      trimmed = original
      sub(/^[[:space:]]*/, "", trimmed)
      lower_trimmed = tolower(trimmed)

      if (lower_trimmed ~ /^match([[:space:]]|$)/) {
        if (!global_written) {
          print directive " " value
          global_written = 1
        }
        in_match = 1
        print original
        next
      }

      candidate = trimmed
      sub(/^#[[:space:]]*/, "", candidate)
      split(candidate, fields, /[[:space:]]+/)
      if (tolower(fields[1]) == directive_lower) {
        if (in_match) {
          print directive " " value
        } else if (!global_written) {
          print directive " " value
          global_written = 1
        }
        next
      }
      print original
    }
    END {
      if (!global_written) {
        print directive " " value
      }
    }
  ' "$input_file" > "$output_file"
}

stage_sshd_config() {
  local current_file next_file directive
  if [[ ! -f $ROOT_LOGIN_SSHD_CONFIG || -L $ROOT_LOGIN_SSHD_CONFIG ]]; then
    echo -e "${RED}SSH 主配置不存在、不是普通文件或是符号链接：${ROOT_LOGIN_SSHD_CONFIG}${NC}" >&2
    return 1
  fi
  current_file=$(mktemp "$(dirname "$ROOT_LOGIN_SSHD_CONFIG")/.sshd_config.ai-scripts.XXXXXX") \
    || return 1
  cp -- "$ROOT_LOGIN_SSHD_CONFIG" "$current_file" || {
    rm -f -- "$current_file"
    return 1
  }

  for directive in PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication; do
    next_file=$(mktemp "$(dirname "$ROOT_LOGIN_SSHD_CONFIG")/.sshd_config.ai-scripts.XXXXXX") \
      || { rm -f -- "$current_file"; return 1; }
    if ! write_sshd_directive "$current_file" "$next_file" "$directive" yes; then
      rm -f -- "$current_file" "$next_file"
      return 1
    fi
    rm -f -- "$current_file"
    current_file=$next_file
  done
  chmod 600 "$current_file" || { rm -f -- "$current_file"; return 1; }
  ROOT_LOGIN_STAGE_FILE=$current_file
}

cleanup_sshd_stage() {
  if [[ -n ${ROOT_LOGIN_STAGE_FILE:-} \
    && ${ROOT_LOGIN_STAGE_FILE%/*} == "$(dirname "$ROOT_LOGIN_SSHD_CONFIG")" \
    && ${ROOT_LOGIN_STAGE_FILE##*/} == .sshd_config.ai-scripts.* ]]; then
    rm -f -- "$ROOT_LOGIN_STAGE_FILE"
  fi
  ROOT_LOGIN_STAGE_FILE=''
}

install_staged_sshd_config() {
  local mode owner group target_dir temp_file
  mode=$(stat -c '%a' "$ROOT_LOGIN_SSHD_CONFIG") || return 1
  owner=$(stat -c '%u' "$ROOT_LOGIN_SSHD_CONFIG") || return 1
  group=$(stat -c '%g' "$ROOT_LOGIN_SSHD_CONFIG") || return 1
  target_dir=$(dirname "$ROOT_LOGIN_SSHD_CONFIG")
  temp_file=$(mktemp "$target_dir/.sshd_config.install.XXXXXX") || return 1
  if ! command install -m "$mode" "$ROOT_LOGIN_STAGE_FILE" "$temp_file" \
    || ! chown "$owner:$group" "$temp_file" \
    || ! mv -f -- "$temp_file" "$ROOT_LOGIN_SSHD_CONFIG"; then
    rm -f -- "$temp_file"
    return 1
  fi
  command -v restorecon >/dev/null 2>&1 \
    && restorecon "$ROOT_LOGIN_SSHD_CONFIG" >/dev/null 2>&1 || true
}

clear_ssh_include_directory() {
  local target=$1
  case "$target" in
    "$ROOT_LOGIN_SSHD_CONFIG_DIR"|"$ROOT_LOGIN_SSH_CONFIG_DIR") ;;
    *)
      echo -e "${RED}拒绝清理未经验证的 SSH 配置目录：${target}${NC}" >&2
      return 1
      ;;
  esac
  if [[ -L $target ]]; then
    echo -e "${RED}拒绝清理符号链接目录：${target}${NC}" >&2
    return 1
  fi
  install -d -m 755 "$target" || return 1
  find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

apply_ssh_service() {
  if systemctl is-active --quiet "${SSH_SERVICE_NAME}.service" 2>/dev/null; then
    systemctl reload "${SSH_SERVICE_NAME}.service" \
      || systemctl restart "${SSH_SERVICE_NAME}.service" || return 1
  else
    systemctl restart "${SSH_SERVICE_NAME}.service" || return 1
  fi
  sleep 1
  systemctl is-active --quiet "${SSH_SERVICE_NAME}.service"
}

restore_ssh_service_state() {
  local backup_dir=$1
  if [[ -f $backup_dir/service-active ]]; then
    systemctl reload "${SSH_SERVICE_NAME}.service" 2>/dev/null \
      || systemctl restart "${SSH_SERVICE_NAME}.service" || return 1
    sleep 1
    systemctl is-active --quiet "${SSH_SERVICE_NAME}.service"
  else
    systemctl stop "${SSH_SERVICE_NAME}.service" 2>/dev/null || true
  fi
}

rollback_root_login() {
  local backup_dir=$1 sshd_bin=$2 status=0
  echo -e "${YELLOW}正在恢复修改前的 root 密码和 SSH 配置……${NC}" >&2
  remove_account_file_protection
  restore_root_login_path "$backup_dir" passwd "$ROOT_LOGIN_PASSWD_FILE" || status=1
  restore_root_login_path "$backup_dir" shadow "$ROOT_LOGIN_SHADOW_FILE" || status=1
  restore_root_login_path "$backup_dir" sshd_config "$ROOT_LOGIN_SSHD_CONFIG" || status=1
  restore_root_login_path "$backup_dir" sshd_config.d "$ROOT_LOGIN_SSHD_CONFIG_DIR" || status=1
  restore_root_login_path "$backup_dir" ssh_config.d "$ROOT_LOGIN_SSH_CONFIG_DIR" || status=1
  restore_account_file_protection "$backup_dir" || status=1

  if ((status == 0)); then
    "$sshd_bin" -t -f "$ROOT_LOGIN_SSHD_CONFIG" || status=1
  fi
  restore_ssh_service_state "$backup_dir" || status=1
  return "$status"
}

fail_and_rollback_root_login() {
  local message=$1 backup_dir=$2 sshd_bin=$3
  echo -e "${RED}${message}${NC}" >&2
  if rollback_root_login "$backup_dir" "$sshd_bin"; then
    echo -e "${YELLOW}已恢复修改前状态，备份保留在：${backup_dir}${NC}" >&2
  else
    echo -e "${RED}自动恢复未完全成功，请从以下目录手动恢复：${backup_dir}${NC}" >&2
  fi
  cleanup_sshd_stage
  return 1
}

# ======================= 开启root登录 =======================
enable_root_login() {
  local mima sshd_bin backup_dir
  check_root_login_root || return 1

  IFS= read -r -p "请输入自定义 root 密码: " mima
  if [[ -z $mima ]]; then
    echo -e "${RED}密码不能为空，设置失败！${NC}" >&2
    return 1
  fi

  sshd_bin=$(command -v sshd) || {
    echo -e "${RED}未找到 sshd，未进行任何修改。${NC}" >&2
    return 1
  }
  detect_ssh_service || return 1
  stage_sshd_config || return 1

  if ! create_root_login_backup; then
    cleanup_sshd_stage
    echo -e "${RED}无法创建修改前备份，已取消操作。${NC}" >&2
    return 1
  fi
  backup_dir=$ROOT_LOGIN_LAST_BACKUP

  remove_account_file_protection
  if ! clear_ssh_include_directory "$ROOT_LOGIN_SSHD_CONFIG_DIR" \
    || ! clear_ssh_include_directory "$ROOT_LOGIN_SSH_CONFIG_DIR" \
    || ! install_staged_sshd_config; then
    fail_and_rollback_root_login "SSH 配置写入失败。" "$backup_dir" "$sshd_bin"
    return 1
  fi
  if ! "$sshd_bin" -t -f "$ROOT_LOGIN_SSHD_CONFIG"; then
    fail_and_rollback_root_login "sshd 配置验证失败。" "$backup_dir" "$sshd_bin"
    return 1
  fi
  if ! printf 'root:%s\n' "$mima" | chpasswd; then
    fail_and_rollback_root_login "root 密码设置失败。" "$backup_dir" "$sshd_bin"
    return 1
  fi
  if ! apply_ssh_service; then
    fail_and_rollback_root_login "SSH 服务加载新配置失败。" "$backup_dir" "$sshd_bin"
    return 1
  fi
  if ! restore_account_file_protection "$backup_dir"; then
    fail_and_rollback_root_login "无法恢复 passwd/shadow 原有文件保护属性。" "$backup_dir" "$sshd_bin"
    return 1
  fi
  cleanup_sshd_stage

  echo -e "\n${GREEN}配置完成！SSH 服务已重新加载。${NC}"
  echo -e "${BLUE}修改前备份：${backup_dir}${NC}"
  echo -e "------------------------------------------"
  echo -e "VPS 当前用户名：root"
  echo -e "VPS 当前 root 密码：$mima"
  echo -e "------------------------------------------"
  echo -e "${YELLOW}请使用以下方式登录："
  echo -e "1. 密码方式登录"
  echo -e "2. keyboard-interactive 验证方式${NC}\n"
}

if [[ ${ENABLE_ROOT_LOGIN_SOURCE_ONLY:-0} != 1 ]]; then
  enable_root_login
  exit $?
fi
