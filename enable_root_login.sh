#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本。${NC}"
    exit 1
  fi
}

restore_file_attributes() {
  local file flags
  for file in /etc/passwd /etc/shadow; do
    flags=${ORIGINAL_ATTRS[$file]:-}
    [[ $flags == *i* ]] && chattr +i "$file" >/dev/null 2>&1 || true
    [[ $flags == *a* ]] && chattr +a "$file" >/dev/null 2>&1 || true
  done
}

backup_ssh_config() {
  local backup_root=$1
  install -d -m 700 "$backup_root"
  cp -a /etc/ssh/sshd_config "$backup_root/sshd_config"
  [[ -d /etc/ssh/sshd_config.d ]] && cp -a /etc/ssh/sshd_config.d "$backup_root/sshd_config.d"
  [[ -d /etc/ssh/ssh_config.d ]] && cp -a /etc/ssh/ssh_config.d "$backup_root/ssh_config.d"
  getent shadow root > "$backup_root/root.shadow"
  chmod 600 "$backup_root/root.shadow"
}

restore_root_password() {
  local backup_root=$1 old_hash
  [[ -s $backup_root/root.shadow ]] || return 0
  old_hash=$(cut -d: -f2 "$backup_root/root.shadow")
  printf 'root:%s\n' "$old_hash" | chpasswd -e
}

restore_ssh_config() {
  local backup_root=$1
  cp -a "$backup_root/sshd_config" /etc/ssh/sshd_config
  rm -rf -- /etc/ssh/sshd_config.d /etc/ssh/ssh_config.d
  [[ -d $backup_root/sshd_config.d ]] && cp -a "$backup_root/sshd_config.d" /etc/ssh/sshd_config.d
  [[ -d $backup_root/ssh_config.d ]] && cp -a "$backup_root/ssh_config.d" /etc/ssh/ssh_config.d
}

set_sshd_option() {
  local key=$1 value=$2
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" /etc/ssh/sshd_config; then
    sed -Ei "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" /etc/ssh/sshd_config
  else
    printf '\n%s %s\n' "$key" "$value" >> /etc/ssh/sshd_config
  fi
}

restart_ssh_service() {
  local service_name
  for service_name in sshd ssh; do
    if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "${service_name}.service"; then
      systemctl restart "$service_name"
      return
    fi
  done
  echo -e "${RED}错误：未找到 sshd.service 或 ssh.service。${NC}"
  return 1
}

enable_root_login() {
  require_root

  declare -gA ORIGINAL_ATTRS=()
  local file
  for file in /etc/passwd /etc/shadow; do
    ORIGINAL_ATTRS[$file]=$(lsattr -d "$file" 2>/dev/null | awk '{print $1}' || true)
    chattr -i "$file" >/dev/null 2>&1 || true
    chattr -a "$file" >/dev/null 2>&1 || true
  done
  trap restore_file_attributes EXIT

  local mima
  read -r -p "请输入自定义 root 密码: " mima
  if [[ -z $mima ]]; then
    echo -e "${RED}密码不能为空，设置失败！${NC}"
    return 1
  fi

  local timestamp backup_root
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_root="/var/backups/ai-scripts/enable-root/${timestamp}"
  backup_ssh_config "$backup_root"
  echo -e "${YELLOW}SSH 配置备份：${backup_root}${NC}"

  if ! printf 'root:%s\n' "$mima" | chpasswd; then
    echo -e "${RED}root 密码设置失败，SSH 配置未修改。${NC}"
    return 1
  fi

  set_sshd_option PermitRootLogin yes
  set_sshd_option PasswordAuthentication yes
  set_sshd_option KbdInteractiveAuthentication yes

  # 按脚本既定用途清理云厂商配置片段；修改前已完整备份。
  [[ -d /etc/ssh/sshd_config.d ]] && find /etc/ssh/sshd_config.d -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  [[ -d /etc/ssh/ssh_config.d ]] && find /etc/ssh/ssh_config.d -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

  local sshd_bin
  sshd_bin=$(command -v sshd || true)
  if [[ -z $sshd_bin ]] || ! "$sshd_bin" -t; then
    echo -e "${RED}SSH 配置校验失败，正在恢复原配置……${NC}"
    restore_ssh_config "$backup_root"
    restore_root_password "$backup_root" || true
    [[ -z $sshd_bin ]] || "$sshd_bin" -t 2>/dev/null || true
    return 1
  fi

  if ! restart_ssh_service; then
    echo -e "${RED}SSH 重启失败，正在恢复原配置并再次启动……${NC}"
    restore_ssh_config "$backup_root"
    restore_root_password "$backup_root" || true
    restart_ssh_service || true
    return 1
  fi

  echo -e "\n${GREEN}配置完成！SSH 配置已通过语法检查。${NC}"
  echo -e "------------------------------------------"
  echo -e "VPS 当前用户名：root"
  echo -e "VPS 当前 root 密码：$mima"
  echo -e "------------------------------------------"
  echo -e "${YELLOW}请使用以下方式登录："
  echo -e "1. 密码方式登录"
  echo -e "2. keyboard-interactive 验证方式${NC}\n"
}

enable_root_login
