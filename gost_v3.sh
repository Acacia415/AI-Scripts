#!/bin/bash
# shellcheck disable=SC2154

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
shell_version="2.5.0"
gost_conf_dir="${GOST_CONF_DIR:-/etc/gost}"
gost_conf_path="${GOST_CONF_PATH:-${gost_conf_dir}/config.yml}"
raw_conf_path="${GOST_RAW_CONF_PATH:-${gost_conf_dir}/rawconf}"
gost_binary_path="${GOST_BINARY_PATH:-/usr/bin/gost}"
gost_service_path="${GOST_SERVICE_PATH:-/usr/lib/systemd/system/gost.service}"
gost_journald_path="${GOST_JOURNALD_PATH:-/etc/systemd/journald.conf.d/99-gost-limits.conf}"
install_backup_root="${GOST_INSTALL_BACKUP_ROOT:-/var/backups/ai-scripts/gost-v3}"
crontab_path="${GOST_CRONTAB_PATH:-/etc/crontab}"
backup_path="${GOST_USER_BACKUP_PATH:-/root/gost_backups}"
peer_list_dir="${GOST_PEER_LIST_DIR:-/root}"
release_api_url="${GOST_RELEASE_API_URL:-https://api.github.com/repos/go-gost/gost/releases/latest}"
self_update_url="${GOST_SELF_UPDATE_URL:-https://raw.githubusercontent.com/Acacia415/AI-Scripts/refs/heads/main/gost_v3.sh}"
cron_marker="# AI-Scripts:gost-v3-restart"
transaction_backup=""
config_change_backup=""
pending_peer_list_temp=""
latest_gost_version=""
latest_gost_asset=""
latest_gost_url=""
latest_checksums_url=""

# --- 辅助函数 ---
version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}

function check_sys() {
  local os_id="" os_like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi

  case "${os_id} ${os_like}" in
    *debian*|*ubuntu*) release="debian" ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) release="rhel" ;;
    *)
      echo -e "${Error} 不支持或无法识别当前 Linux 发行版。"
      return 1
      ;;
  esac

  bit=$(uname -m)
  case "$bit" in
    x86_64|amd64) bit="amd64" ;;
    aarch64|arm64) bit="arm64" ;;
    armv7*)  bit="armv7" ;;
    armv6*)  bit="armv6" ;;
    armv5*)  bit="armv5" ;;
    i386|i686) bit="386" ;;
    loongarch64) bit="loong64" ;;
    riscv64|s390x) bit="$bit" ;;
    *)
      echo "未能自动识别芯片架构: $bit"
      echo "请手动输入官方发行包中的架构名称 (例如 amd64/arm64/386/armv7):"
      read -r bit
      ;;
  esac

  if [[ ! "$bit" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo -e "${Error} 架构名称无效。"
    return 1
  fi
}

function Installation_dependency() {
  local dependencies=(ca-certificates curl gzip jq tar)
  local missing=false dependency
  for dependency in curl gzip jq tar; do
    command -v "$dependency" >/dev/null 2>&1 || missing=true
  done
  command -v sha256sum >/dev/null 2>&1 || missing=true
  [[ "$missing" == false ]] && return 0

  if [[ ${release} == "rhel" ]]; then
    local package_manager=""
    if command -v dnf >/dev/null 2>&1; then
      package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
      package_manager="yum"
    else
      echo -e "${Error} 未找到 dnf 或 yum。"
      return 1
    fi
    "$package_manager" install -y "${dependencies[@]}" coreutils
  else
    apt-get update && apt-get install -y "${dependencies[@]}" coreutils
  fi
}

function ensure_runtime_dependencies() {
  if command -v jq >/dev/null 2>&1 && command -v md5sum >/dev/null 2>&1; then
    return 0
  fi
  check_sys && Installation_dependency
}

function setup_journald_log_rotation() {
  echo -e "${Info} 正在配置 journald 日志轮换..."
  mkdir -p "$(dirname "$gost_journald_path")"
  cat >"$gost_journald_path" <<EOF
# Managed by gost_v3.sh - 防止日志无限堆积
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
  systemctl restart systemd-journald 2>/dev/null
  echo -e "${Info} journald 日志轮换已配置 (最大200M / 保留7天)"
}

# --- GOST 服务管理 ---

function check_service_exists() {
  if [[ ! -f "$gost_service_path" ]]; then
    echo -e "${Error} gost 服务文件未找到 (gost.service not found)."
    echo -e "${Info} 请先使用主菜单中的选项 [1] 来安装gost。"
    return 1
  fi
  return 0
}

function restart_gost_safely() {
    if ! check_service_exists; then
        read -n 1 -s -r -p "按任意键返回..."
        return 1
    fi
    if systemctl restart gost; then
        echo -e "${Info} gost 服务已成功重启。"
    else
        echo -e "${Error} gost 服务重启失败。请使用 'systemctl status gost' 或 'journalctl -u gost' 查看日志。"
        return 1
    fi
}

function install_backup_item() {
  local label="$1" source_path="$2"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$transaction_backup/$label" || return 1
    : > "$transaction_backup/$label.present"
  else
    : > "$transaction_backup/$label.absent"
  fi
}

function prune_install_backups() {
  local backups=() index
  mapfile -t backups < <(find "$install_backup_root" -mindepth 1 -maxdepth 1 -type d -name 'transaction.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  for ((index=5; index<${#backups[@]}; index++)); do
    [[ "${backups[$index]}" == "$install_backup_root"/transaction.* ]] && rm -rf -- "${backups[$index]}"
  done
}

function create_install_backup() {
  umask 077
  mkdir -p "$install_backup_root" || return 1
  chmod 700 "$install_backup_root"
  transaction_backup=$(mktemp -d "$install_backup_root/transaction.XXXXXXXX") || return 1
  install_backup_item binary "$gost_binary_path" || return 1
  install_backup_item config "$gost_conf_dir" || return 1
  install_backup_item service "$gost_service_path" || return 1
  install_backup_item journald "$gost_journald_path" || return 1
  systemctl is-enabled --quiet gost 2>/dev/null && : > "$transaction_backup/service.enabled"
  systemctl is-active --quiet gost 2>/dev/null && : > "$transaction_backup/service.active"
  prune_install_backups
}

function restore_install_item() {
  local label="$1" target_path="$2"
  if [[ -f "$transaction_backup/$label.present" ]]; then
    rm -rf -- "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a -- "$transaction_backup/$label" "$target_path"
  elif [[ -f "$transaction_backup/$label.absent" ]]; then
    rm -rf -- "$target_path"
  fi
}

function restore_installation() {
  [[ -n "$transaction_backup" && -d "$transaction_backup" ]] || return 1
  echo -e "${Info} 安装失败，正在恢复二进制、配置和服务文件..."
  systemctl stop gost >/dev/null 2>&1 || true
  restore_install_item binary "$gost_binary_path"
  restore_install_item config "$gost_conf_dir"
  restore_install_item service "$gost_service_path"
  restore_install_item journald "$gost_journald_path"
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -f "$transaction_backup/service.enabled" ]]; then
    systemctl enable gost >/dev/null 2>&1 || true
  else
    systemctl disable gost >/dev/null 2>&1 || true
  fi
  if [[ -f "$transaction_backup/service.active" ]]; then
    systemctl start gost >/dev/null 2>&1 || true
  fi
  echo -e "${Info} 已恢复到本次安装前的状态，备份保留在: $transaction_backup"
}

function create_service_file() {
  local service_temp
  mkdir -p "$(dirname "$gost_service_path")"
  service_temp=$(mktemp "$(dirname "$gost_service_path")/.gost.service.XXXXXXXX") || return 1
  cat >"$service_temp" <<EOF
[Unit]
Description=GOST Tunnel Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${gost_binary_path} -C ${gost_conf_path}
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gost

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$service_temp"
  mv -f "$service_temp" "$gost_service_path"
}

function fetch_latest_release() {
  local release_json="$1" tag
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 \
    -H 'Accept: application/vnd.github+json' "$release_api_url" -o "$release_json" || return 1
  tag=$(jq -er '.tag_name | select(type == "string" and test("^v[0-9]+([.][0-9]+){2}([-.][0-9A-Za-z.]+)?$"))' "$release_json") || return 1
  latest_gost_version="${tag#v}"
  latest_gost_asset="gost_${latest_gost_version}_linux_${bit}.tar.gz"
  latest_gost_url=$(jq -er --arg name "$latest_gost_asset" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json" | head -n 1) || return 1
  latest_checksums_url=$(jq -er '.assets[] | select(.name == "checksums.txt") | .browser_download_url' "$release_json" | head -n 1) || return 1
  [[ "$latest_gost_url" == https://github.com/go-gost/gost/releases/download/* ]] || return 1
  [[ "$latest_checksums_url" == https://github.com/go-gost/gost/releases/download/* ]] || return 1
}

function download_latest_gost() {
  local stage_dir="$1" archive expected_checksum actual_checksum
  archive="$stage_dir/$latest_gost_asset"
  curl --fail --show-error --location --retry 3 --connect-timeout 10 "$latest_gost_url" -o "$archive" || return 1
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 "$latest_checksums_url" -o "$stage_dir/checksums.txt" || return 1
  expected_checksum=$(awk -v asset="$latest_gost_asset" '$2 == asset {print $1; exit}' "$stage_dir/checksums.txt")
  [[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  actual_checksum=$(sha256sum "$archive" | awk '{print $1}')
  [[ "${actual_checksum,,}" == "${expected_checksum,,}" ]] || return 1
  tar -tzf "$archive" >/dev/null || return 1
  tar -xzf "$archive" -C "$stage_dir" || return 1
  [[ -s "$stage_dir/gost" ]] || return 1
  chmod 755 "$stage_dir/gost"
  "$stage_dir/gost" -V >/dev/null 2>&1 || return 1
}

function validate_gost_config() {
  local binary="$1" config="$2" validation_output
  if ! validation_output=$("$binary" -C "$config" -O yaml 2>&1); then
    [[ -z "$validation_output" ]] || printf '%s\n' "$validation_output" >&2
    return 1
  fi
}

function wait_for_gost_service() {
  local attempts="${GOST_SERVICE_CHECK_ATTEMPTS:-5}" delay="${GOST_SERVICE_CHECK_DELAY:-1}" count
  for ((count=1; count<=attempts; count++)); do
    systemctl is-active --quiet gost && return 0
    sleep "$delay"
  done
  return 1
}

function Install_ct() {
  local stage_dir release_json choice current_version="未安装"

  check_root
  check_sys || return 1
  Installation_dependency || { echo -e "${Error} 依赖安装失败。"; return 1; }

  stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/gost-v3-install.XXXXXXXX") || return 1
  release_json="$stage_dir/release.json"
  if ! fetch_latest_release "$release_json"; then
    echo -e "${Error} 无法取得适用于 linux/${bit} 的 GOST 最新发行包。"
    rm -rf -- "$stage_dir"
    return 1
  fi

  if [[ -x "$gost_binary_path" ]]; then
    current_version=$("$gost_binary_path" -V 2>&1 | head -n 1)
    echo -e "\033[0;33mWARNING: 检测到 GOST 已安装: ${current_version}\033[0m"
    read -r -p "是否继续并覆盖为官方最新版本 v${latest_gost_version}? (y/N): " choice
    if [[ ! "$choice" =~ ^[yY]$ ]]; then
      echo "安装已取消。"
      rm -rf -- "$stage_dir"
      return 1
    fi
  fi

  echo "正在从 GitHub 下载并校验 GOST v${latest_gost_version} (${bit})..."
  if ! download_latest_gost "$stage_dir"; then
    echo -e "${Error} GOST 下载、校验或解压失败。"
    rm -rf -- "$stage_dir"
    return 1
  fi

  if ! create_install_backup; then
    echo -e "${Error} 无法创建安装前备份，已停止安装。"
    rm -rf -- "$stage_dir"
    return 1
  fi

  mkdir -p "$gost_conf_dir" "$(dirname "$gost_binary_path")"
  chmod 700 "$gost_conf_dir"
  install -m 755 "$stage_dir/gost" "$gost_binary_path" || { restore_installation; rm -rf -- "$stage_dir"; return 1; }
  create_service_file || { restore_installation; rm -rf -- "$stage_dir"; return 1; }
  if [[ ! -f "$gost_conf_path" ]]; then
    printf 'services: []\n' > "$gost_conf_path"
  fi
  chmod 600 "$gost_conf_path"
  [[ ! -e "$raw_conf_path" ]] || chmod 600 "$raw_conf_path"

  if ! validate_gost_config "$gost_binary_path" "$gost_conf_path"; then
    echo -e "${Error} 现有 GOST 配置无法通过新版本校验。"
    restore_installation
    rm -rf -- "$stage_dir"
    return 1
  fi

  setup_journald_log_rotation
  systemctl daemon-reload || { restore_installation; rm -rf -- "$stage_dir"; return 1; }
  systemctl enable gost || { restore_installation; rm -rf -- "$stage_dir"; return 1; }
  if ! systemctl restart gost || ! wait_for_gost_service; then
    echo -e "${Error} GOST 服务未能稳定运行，安装未提交。"
    restore_installation
    rm -rf -- "$stage_dir"
    return 1
  fi

  rm -rf -- "$stage_dir"
  echo "------------------------------"
  echo "GOST v${latest_gost_version} 安装成功；安装前备份: ${transaction_backup}"
}

function checknew() {
  if [[ ! -x "$gost_binary_path" ]]; then
    echo -e "${Error} gost未安装，无法检查更新。"
    return
  fi
  check_sys || return 1
  Installation_dependency || return 1
  local stage_dir current_version
  stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/gost-v3-check.XXXXXXXX") || return 1
  if ! fetch_latest_release "$stage_dir/release.json"; then
    echo -e "${Error} 检查最新版本失败。"
    rm -rf -- "$stage_dir"
    return 1
  fi
  current_version=$("$gost_binary_path" -V 2>&1 | awk '{print $2}' | sed 's/^v//')
  echo "当前 GOST 版本: ${current_version:-未知}；官方最新版本: ${latest_gost_version}"
  rm -rf -- "$stage_dir"
  if [[ "$current_version" == "$latest_gost_version" ]]; then
    echo "当前已是最新版本。"
    return 0
  fi
  read -r -p "是否更新到最新版本? (y/N): " checknewnum
  [[ "$checknewnum" =~ ^[yY]$ ]] && Install_ct || echo "已取消更新"
}

function Uninstall_ct() {
  echo -e "${Info} 正在停止并禁用gost后台服务..."
  systemctl stop gost
  systemctl disable gost
  
  echo -e "${Info} 正在删除gost核心程序和服务文件..."
  rm -f "$gost_binary_path"
  rm -f "$gost_service_path"
  systemctl daemon-reload
  
  # 检查配置目录是否存在
  if [[ -d "$gost_conf_dir" ]]; then
    echo -e "${Info} 正在删除由本脚本生成的配置文件..."
    # 精确删除脚本创建的2个文件
    rm -f "$gost_conf_path"
    rm -f "$raw_conf_path"
    echo -e "${Info} 已删除: $gost_conf_path"
    echo -e "${Info} 已删除: $raw_conf_path"
    echo -e "${Info} 保留 $gost_conf_dir 目录下的其他文件。"
  fi
  
  echo -e "\n${Green_font_prefix}[成功]${Font_color_suffix} gost卸载完成。"
}

function Start_ct() { check_service_exists && systemctl start gost && echo "已启动"; }
function Stop_ct() { check_service_exists && systemctl stop gost && echo "已停止"; }
function Restart_ct() { regenerate_yaml_config && restart_gost_safely; }

# --- 配置生成核心逻辑 (YAML Version) ---

function eachconf_retrieve() {
  d_server=${trans_conf#*#}
  d_port=${d_server#*#}
  d_ip=${d_server%#*}
  flag_s_port=${trans_conf%%#*}
  s_port=${flag_s_port#*/}
  is_encrypt=${flag_s_port%/*}
  is_cert="false"
}

function yaml_quote() {
  printf '%s' "$1" | jq -Rs .
}

function validate_plain_value() {
  [[ -n "$1" && ${#1} -le 1024 && ! "$1" =~ [[:cntrl:]] ]]
}

function validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

function validate_host() {
  validate_plain_value "$1" && [[ ! "$1" =~ [[:space:]/] ]]
}

function validate_peer_filename() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$1" != "." && "$1" != ".." ]]
}

function format_host_port() {
  local host="$1" port="$2"
  host="${host#[}"
  host="${host%]}"
  if [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

function parse_raw_record() {
  local record="$1"
  if [[ "$record" == \{* ]]; then
    is_encrypt=$(jq -er '.mode | select(type == "string")' <<<"$record") || return 1
    s_port=$(jq -er '.local | select(type == "string")' <<<"$record") || return 1
    d_ip=$(jq -er '.target | select(type == "string")' <<<"$record") || return 1
    d_port=$(jq -er '.remote | select(type == "string")' <<<"$record") || return 1
    is_cert=$(jq -er '(.tls_verify // false) | if type == "boolean" then tostring else empty end' <<<"$record") || return 1
  else
    trans_conf="$record"
    eachconf_retrieve
  fi

  case "$is_encrypt" in
    nonencrypt|encrypttls|encryptws|encryptwss|decrypttls|decryptws|decryptwss)
      validate_port "$s_port" && validate_host "$d_ip" && validate_port "$d_port"
      ;;
    ss)
      validate_plain_value "$s_port" && [[ "$d_ip" == "aes-256-gcm" || "$d_ip" == "chacha20-ietf-poly1305" ]] && validate_port "$d_port"
      ;;
    socks|http)
      validate_plain_value "$s_port" && validate_plain_value "$d_ip" && validate_port "$d_port"
      ;;
    peerno|peertls|peerws|peerwss)
      validate_port "$s_port" && validate_peer_filename "$d_ip" && [[ "$d_port" =~ ^(round|random|fifo)$ ]]
      ;;
    *) return 1 ;;
  esac
}

function parse_node_endpoint() {
  local endpoint="$1" host port
  if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$endpoint" == *:* ]]; then
    host="${endpoint%:*}"
    port="${endpoint##*:}"
  else
    return 1
  fi
  validate_host "$host" && validate_port "$port" || return 1
  parsed_node_addr=$(format_host_port "$host" "$port")
}

function build_yaml_config() {
    local output_path="$1"
    local chain_definitions=""
    local has_chains=false
    local line_number=0

    if [[ -s "$raw_conf_path" ]]; then
        echo "services:" > "$output_path"
    else
        echo "services: []" > "$output_path"
    fi

    if [[ -s "$raw_conf_path" ]]; then
        while IFS= read -r trans_conf || [[ -n "$trans_conf" ]]; do
            ((line_number++))
            if ! parse_raw_record "$trans_conf"; then
                echo -e "${Error} rawconf 第 ${line_number} 行格式或字段无效。" >&2
                return 1
            fi
            local service_name
            service_name="service_$(echo "${is_encrypt}_${s_port}_${d_ip}_${d_port}" | md5sum | head -c 8)"
            local listen_addr target_addr q_listen q_target q_password q_username
            listen_addr=":${s_port}"
            q_listen=$(yaml_quote "$listen_addr") || return 1

            case "$is_encrypt" in
                nonencrypt)
                    target_addr=$(format_host_port "$d_ip" "$d_port")
                    q_target=$(yaml_quote "$target_addr") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}_tcp"
  addr: ${q_listen}
  listener:
    type: "tcp"
  handler:
    type: "forward"
  forwarder:
    nodes:
    - name: "target"
      addr: ${q_target}
- name: "${service_name}_udp"
  addr: ${q_listen}
  listener:
    type: "udp"
  handler:
    type: "forward"
  forwarder:
    nodes:
    - name: "target"
      addr: ${q_target}
EOF
                    ;;
                encrypt*|peertls|peerws|peerwss)
                    has_chains=true
                    target_addr=$(format_host_port "$d_ip" "$d_port")
                    q_target=$(yaml_quote "$target_addr") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ${q_listen}
  handler:
    type: "forward"
    chain: "chain_${service_name}"
  listener:
    type: "tcp"
  forwarder:
    nodes:
    - name: "target"
      addr: ${q_target}
EOF
                    ;;
                decrypttls|decryptwss)
                    local listener_type=${is_encrypt//decrypt/}
                    target_addr=$(format_host_port "$d_ip" "$d_port")
                    q_target=$(yaml_quote "$target_addr") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ${q_listen}
  handler:
    type: "relay"
  listener:
    type: "${listener_type}"
EOF
                    if [[ "$listener_type" == "wss" ]]; then
                        cat >> "$output_path" <<EOF
    metadata:
      path: "/ws"
EOF
                    fi
                    if [ -f "$HOME/gost_cert/cert.pem" ] && [ -f "$HOME/gost_cert/key.pem" ]; then
                        cat >> "$output_path" <<EOF
    tls:
      certFile: "/root/gost_cert/cert.pem"
      keyFile: "/root/gost_cert/key.pem"
EOF
                    fi
                    cat >> "$output_path" <<EOF
  forwarder:
    nodes:
    - name: "target"
      addr: ${q_target}
EOF
                    ;;
                decryptws)
                    target_addr=$(format_host_port "$d_ip" "$d_port")
                    q_target=$(yaml_quote "$target_addr") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ${q_listen}
  handler:
    type: "relay"
  listener:
    type: "ws"
    metadata:
      path: "/ws"
  forwarder:
    nodes:
    - name: "target"
      addr: ${q_target}
EOF
                    ;;
                ss)
                    q_password=$(yaml_quote "$s_port") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ":${d_port}"
  handler:
    type: "ss"
    auth:
      password: ${q_password}
    metadata:
      method: "${d_ip}"
  listener:
    type: "tcp"
EOF
                    ;;
                socks)
                    q_username=$(yaml_quote "$d_ip") || return 1
                    q_password=$(yaml_quote "$s_port") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ":${d_port}"
  handler:
    type: "socks5"
    auth:
      username: ${q_username}
      password: ${q_password}
  listener:
    type: "tcp"
EOF
                    ;;
                http)
                    q_username=$(yaml_quote "$d_ip") || return 1
                    q_password=$(yaml_quote "$s_port") || return 1
                    cat >> "$output_path" <<EOF
- name: "${service_name}"
  addr: ":${d_port}"
  handler:
    type: "http"
    auth:
      username: ${q_username}
      password: ${q_password}
  listener:
    type: "tcp"
EOF
                    ;;
                peerno)
                    local nodes_yaml=""
                    local node_count=0
                    while IFS= read -r node_addr; do
                        [[ -z "$node_addr" ]] && continue
                        parse_node_endpoint "$node_addr" || { echo -e "${Error} $peer_list_dir/${d_ip}.txt 中存在无效节点: $node_addr" >&2; return 1; }
                        local node_name q_node_addr
                        node_name=$(printf '%s' "$parsed_node_addr" | md5sum | head -c 8)
                        q_node_addr=$(yaml_quote "$parsed_node_addr") || return 1
                        nodes_yaml+=$(printf '\n    - name: "node_%s"\n      addr: %s' "$node_name" "$q_node_addr")
                        ((node_count++))
                    done < "$peer_list_dir/$d_ip.txt"
                    ((node_count > 0)) || { echo -e "${Error} 节点列表 $peer_list_dir/${d_ip}.txt 为空。" >&2; return 1; }

                    cat >> "$output_path" <<EOF
- name: "${service_name}_tcp"
  addr: ${q_listen}
  listener:
    type: "tcp"
  handler:
    type: "forward"
  forwarder:
    selector:
      strategy: "${d_port}"
    nodes:${nodes_yaml}
- name: "${service_name}_udp"
  addr: ${q_listen}
  listener:
    type: "udp"
  handler:
    type: "forward"
  forwarder:
    selector:
      strategy: "${d_port}"
    nodes:${nodes_yaml}
EOF
                    ;;
            esac

            case "$is_encrypt" in
                encrypttls|encryptwss)
                    local dialer_type=${is_encrypt//encrypt/}
                    local tls_dialer_opts=""
                    local ws_path_opts=""
                    if [[ ${is_cert} == "true" ]]; then
                        tls_dialer_opts=$(printf '\n        tls:\n          secure: true\n          serverName: %s' "$(yaml_quote "$d_ip")")
                    fi
                    if [[ "$dialer_type" == "wss" ]]; then
                        ws_path_opts=$(printf '\n        metadata:\n          path: "/ws"')
                    fi
                    chain_definitions+=$'\n'$(cat <<EOF
- name: "chain_${service_name}"
  hops:
  - name: "hop_${service_name}"
    nodes:
    - name: "node_${service_name}"
      addr: ${q_target}
      connector:
        type: "relay"
      dialer:
        type: "${dialer_type}"${ws_path_opts}${tls_dialer_opts}
EOF
)
                    ;;
                encryptws)
                     chain_definitions+=$'\n'$(cat <<EOF
- name: "chain_${service_name}"
  hops:
  - name: "hop_${service_name}"
    nodes:
    - name: "node_${service_name}"
      addr: ${q_target}
      connector:
        type: "relay"
      dialer:
        type: "ws"
        metadata:
          path: "/ws"
EOF
)
                    ;;
                peertls|peerws|peerwss)
                    has_chains=true
                    local dialer_type=${is_encrypt//peer/}
                    local nodes_yaml=""
                    local peer_dialer_meta=""
                    local node_count=0
                    if [[ "$dialer_type" == "ws" || "$dialer_type" == "wss" ]]; then
                        peer_dialer_meta=$(printf '\n        metadata:\n          path: "/ws"')
                    fi
                    while IFS= read -r node_addr; do
                        [[ -z "$node_addr" ]] && continue
                        parse_node_endpoint "$node_addr" || { echo -e "${Error} $peer_list_dir/${d_ip}.txt 中存在无效节点: $node_addr" >&2; return 1; }
                        local node_name q_node_addr
                        node_name=$(printf '%s' "$parsed_node_addr" | md5sum | head -c 8)
                        q_node_addr=$(yaml_quote "$parsed_node_addr") || return 1
                        nodes_yaml+=$(printf '\n    - name: "node_%s"\n      addr: %s\n      connector:\n        type: "relay"\n      dialer:\n        type: "%s"%s' "$node_name" "$q_node_addr" "$dialer_type" "$peer_dialer_meta")
                        ((node_count++))
                    done < "$peer_list_dir/$d_ip.txt"
                    ((node_count > 0)) || { echo -e "${Error} 节点列表 $peer_list_dir/${d_ip}.txt 为空。" >&2; return 1; }

                    chain_definitions+=$'\n'$(cat <<EOF
- name: "chain_${service_name}"
  hops:
  - name: "hop_${service_name}"
    selector:
      strategy: "${d_port}"
    nodes:${nodes_yaml}
EOF
)
                    ;;
            esac
        done < "$raw_conf_path"
    fi

    if [ "$has_chains" = true ]; then
        echo "chains:" >> "$output_path"
        printf '%s\n' "$chain_definitions" >> "$output_path"
    fi
}

function regenerate_yaml_config() {
    local config_temp
    ensure_runtime_dependencies || { echo -e "${Error} 缺少生成配置所需的依赖。"; return 1; }
    mkdir -p "$gost_conf_dir"
    chmod 700 "$gost_conf_dir"
    config_temp=$(mktemp "$gost_conf_dir/.config.XXXXXXXX.yml") || return 1
    if ! build_yaml_config "$config_temp"; then
        rm -f "$config_temp"
        return 1
    fi
    chmod 600 "$config_temp"
    if [[ ! -x "$gost_binary_path" ]] || ! validate_gost_config "$gost_binary_path" "$config_temp"; then
        echo -e "${Error} 新配置未通过 GOST 校验，原配置保持不变。"
        rm -f "$config_temp"
        return 1
    fi
    mv -f "$config_temp" "$gost_conf_path"
    chmod 600 "$gost_conf_path"
}


# --- 规则管理与菜单 ---

function show_all_conf(){
    ensure_runtime_dependencies || { echo -e "${Error} 缺少读取配置所需的依赖。"; return 1; }
    if [[ ! -f ${raw_conf_path} ]] || [[ ! -s ${raw_conf_path} ]]; then
        echo -e "当前没有配置规则。"
    else
        echo -e "当前gost规则:"
        echo -e "--------------------------------------------------------"
        local display_line=0
        while IFS= read -r trans_conf || [[ -n "$trans_conf" ]]; do
          ((display_line++))
          if parse_raw_record "$trans_conf"; then
            printf '%3d. %s/%s#%s#%s\n' "$display_line" "$is_encrypt" "$s_port" "$d_ip" "$d_port"
          else
            printf '%3d. [无效记录] %s\n' "$display_line" "$trans_conf"
          fi
        done < "$raw_conf_path"
        echo -e "--------------------------------------------------------"
    fi
}

function read_protocol() {
  is_cert="n"
  pending_peer_list_temp=""
  while true; do
    echo -e "请问您要设置哪种功能: "
    echo -e "-----------------------------------"
    echo -e "[1] tcp+udp流量转发, 不加密"
    echo -e "[2] 加密隧道流量转发 (中转机)"
    echo -e "[3] 解密隧道流量并转发 (落地机)"
    echo -e "[4] 一键安装ss/socks5/http代理"
    echo -e "[5] 进阶：多落地均衡负载"
    echo -e "-----------------------------------"
    echo -e "[00] 返回主菜单"
    echo -e "-----------------------------------"
    read -p "请选择: " numprotocol

    case "$numprotocol" in
      1) flag_a="nonencrypt"; break ;;
      2) encrypt; break ;;
      3) decrypt; break ;;
      4) proxy; break ;;
      5) enpeer; break ;;
      "00") return ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
}

function encrypt() {
  while true; do
    read -r -p "请选择转发传输类型: [1]tls [2]ws [3]wss: " numencrypt
    case "$numencrypt" in
      1) flag_a="encrypttls"; break ;;
      2) flag_a="encryptws"; break ;;
      3) flag_a="encryptwss"; break ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
  if [[ "$numencrypt" == "1" ]] || [[ "$numencrypt" == "3" ]]; then
    while true; do
      read -e -r -p "落地机是否开启了自定义tls证书？[y/n]:" is_cert
      [[ "$is_cert" =~ ^[YyNn]$ ]] && break
      echo -e "${Error} 请输入 y 或 n。"
    done
  fi
}

function decrypt() {
  while true; do
    read -r -p "请选择解密传输类型: [1]tls [2]ws [3]wss: " numdecrypt
    case "$numdecrypt" in
      1) flag_a="decrypttls"; break ;;
      2) flag_a="decryptws"; break ;;
      3) flag_a="decryptwss"; break ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
}

function proxy() {
  while true; do
    read -r -p "请选择代理类型: [1]shadowsocks [2]socks5 [3]http: " numproxy
    case "$numproxy" in
      1) flag_a="ss"; break ;;
      2) flag_a="socks"; break ;;
      3) flag_a="http"; break ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
}

function enpeer() {
  while true; do
    read -r -p "请选择均衡负载传输类型: [1]不加密 [2]tls [3]ws [4]wss: " numpeer
    case "$numpeer" in
      1) flag_a="peerno"; break ;;
      2) flag_a="peertls"; break ;;
      3) flag_a="peerws"; break ;;
      4) flag_a="peerwss"; break ;;
      *) echo "输入错误，请重新选择" ;;
    esac
  done
}

function read_s_port() {
  while true; do
    case "$flag_a" in
      ss) read -r -p "请输入ss密码: " flag_b ;;
      socks) read -r -p "请输入socks密码: " flag_b ;;
      http) read -r -p "请输入http密码: " flag_b ;;
      *) read -r -p "请输入本机监听端口: " flag_b ;;
    esac
    if [[ "$flag_a" =~ ^(ss|socks|http)$ ]]; then
      validate_plain_value "$flag_b" && return 0
      echo -e "${Error} 密码不能为空，且不能包含控制字符。"
    else
      validate_port "$flag_b" && return 0
      echo -e "${Error} 端口必须是 1-65535 之间的整数。"
    fi
  done
}

function read_d_ip() {
  case "$flag_a" in
    ss)
      while true; do
        read -r -p "请选择ss加密方式 [1]aes-256-gcm [2]chacha20-ietf-poly1305: " ssencrypt
        case "$ssencrypt" in
          1) flag_c="aes-256-gcm"; break ;;
          2) flag_c="chacha20-ietf-poly1305"; break ;;
          *) echo -e "${Error} 只能选择 1 或 2。" ;;
        esac
      done
      ;;
    socks|http)
      while true; do
        read -r -p "请输入代理用户名: " flag_c
        validate_plain_value "$flag_c" && break
        echo -e "${Error} 用户名不能为空，且不能包含控制字符。"
      done
      ;;
    peer*)
      while true; do
        read -e -r -p "请输入落地列表文件名(例如: ips1): " flag_c
        validate_peer_filename "$flag_c" && break
        echo -e "${Error} 文件名只能包含字母、数字、点、下划线和连字符，且不能是 . 或 ..。"
      done
      local ip_list_temp node_count=0
      mkdir -p "$peer_list_dir"
      ip_list_temp=$(mktemp "$peer_list_dir/.${flag_c}.txt.XXXXXXXX") || return 1
      chmod 600 "$ip_list_temp"
      echo -e "请依次输入你要均衡负载的落地ip与端口, 输入 'done' 结束"
      while true; do
        read -r -p "请输入落地IP或域名 (输入 'done' 结束): " peer_ip
        if [[ "$peer_ip" == "done" ]]; then break; fi
        if ! validate_host "$peer_ip"; then
          echo -e "${Error} IP 或域名无效。"
          continue
        fi
        read -r -p "请输入 ${peer_ip} 的端口: " peer_port
        if ! validate_port "$peer_port"; then
          echo -e "${Error} 端口必须是 1-65535 之间的整数。"
          continue
        fi
        format_host_port "$peer_ip" "$peer_port" >> "$ip_list_temp"
        printf '\n' >> "$ip_list_temp"
        ((node_count++))
      done
      if ((node_count == 0)); then
        echo -e "${Error} 至少需要一个有效节点。"
        rm -f "$ip_list_temp"
        return 1
      fi
      pending_peer_list_temp="$ip_list_temp"
      echo -e "节点列表已准备，将与规则一起校验并生效。"
      ;;
    *)
      if [[ ${is_cert} == [Yy] ]]; then echo -e "注意: 落地机开启自定义tls证书，务必填写${Red_font_prefix}域名${Font_color_suffix}"; fi
      while true; do
        read -r -p "请输入目标IP或域名: " flag_c
        validate_host "$flag_c" && break
        echo -e "${Error} IP 或域名无效。"
      done
      ;;
  esac
}

function read_d_port() {
  case "$flag_a" in
    ss|socks|http)
      while true; do
        read -r -p "请输入代理服务端口: " flag_d
        validate_port "$flag_d" && break
        echo -e "${Error} 端口必须是 1-65535 之间的整数。"
      done
      ;;
    peer*)
      while true; do
        read -r -p "请选择均衡负载策略 [1]round(轮询) [2]random(随机) [3]fifo(顺序): " numstra
        case "$numstra" in
          1) flag_d="round"; break ;;
          2) flag_d="random"; break ;;
          3) flag_d="fifo"; break ;;
          *) echo -e "${Error} 只能选择 1、2 或 3。" ;;
        esac
      done
      ;;
    *)
      while true; do
        read -r -p "请输入目标端口: " flag_d
        validate_port "$flag_d" && break
        echo -e "${Error} 端口必须是 1-65535 之间的整数。"
      done
      ;;
  esac
}

function writerawconf() {
  local tls_verify=false record raw_temp
  ensure_runtime_dependencies || return 1
  [[ ${is_cert:-n} == [Yy] ]] && tls_verify=true
  record=$(jq -cn \
    --arg mode "$flag_a" \
    --arg local "$flag_b" \
    --arg target "$flag_c" \
    --arg remote "$flag_d" \
    --argjson tls_verify "$tls_verify" \
    '{mode:$mode, local:$local, target:$target, remote:$remote, tls_verify:$tls_verify}') || return 1

  parse_raw_record "$record" || { echo -e "${Error} 配置字段校验失败。"; return 1; }
  mkdir -p "$gost_conf_dir"
  chmod 700 "$gost_conf_dir"
  raw_temp=$(mktemp "$gost_conf_dir/.rawconf.XXXXXXXX") || return 1
  [[ ! -f "$raw_conf_path" ]] || cat "$raw_conf_path" > "$raw_temp"
  printf '%s\n' "$record" >> "$raw_temp"
  chmod 600 "$raw_temp"
  mv -f "$raw_temp" "$raw_conf_path"
  chmod 600 "$raw_conf_path"
}

function snapshot_config_change() {
  config_change_backup=$(mktemp -d "${TMPDIR:-/tmp}/gost-config-change.XXXXXXXX") || return 1
  chmod 700 "$config_change_backup"
  if [[ -f "$raw_conf_path" ]]; then cp -a "$raw_conf_path" "$config_change_backup/rawconf"; else : > "$config_change_backup/rawconf.absent"; fi
  if [[ -f "$gost_conf_path" ]]; then cp -a "$gost_conf_path" "$config_change_backup/config.yml"; else : > "$config_change_backup/config.absent"; fi
  if [[ "$flag_a" == peer* && -n "$flag_c" ]]; then
    peer_change_target="$peer_list_dir/${flag_c}.txt"
    if [[ -f "$peer_change_target" ]]; then cp -a "$peer_change_target" "$config_change_backup/peer-list"; else : > "$config_change_backup/peer-list.absent"; fi
  else
    peer_change_target=""
  fi
}

function rollback_config_change() {
  if [[ -f "$config_change_backup/rawconf.absent" ]]; then rm -f "$raw_conf_path"; else cp -a "$config_change_backup/rawconf" "$raw_conf_path"; fi
  if [[ -f "$config_change_backup/config.absent" ]]; then rm -f "$gost_conf_path"; else cp -a "$config_change_backup/config.yml" "$gost_conf_path"; fi
  if [[ -n "${peer_change_target:-}" ]]; then
    if [[ -f "$config_change_backup/peer-list.absent" ]]; then rm -f "$peer_change_target"; else cp -a "$config_change_backup/peer-list" "$peer_change_target"; fi
  fi
  [[ -z "$pending_peer_list_temp" ]] || rm -f "$pending_peer_list_temp"
  pending_peer_list_temp=""
  systemctl restart gost >/dev/null 2>&1 || true
  rm -rf -- "$config_change_backup"
}

function commit_new_rule() {
  snapshot_config_change || return 1
  if [[ -n "$pending_peer_list_temp" ]]; then
    mv -f "$pending_peer_list_temp" "$peer_change_target" || { rollback_config_change; return 1; }
    chmod 600 "$peer_change_target"
    pending_peer_list_temp=""
  fi
  if ! writerawconf || ! regenerate_yaml_config || ! systemctl restart gost || ! wait_for_gost_service; then
    echo -e "${Error} 新规则未能生效，正在恢复修改前的配置。"
    rollback_config_change
    return 1
  fi
  rm -rf -- "$config_change_backup"
  echo -e "${Info} 新规则已通过校验并生效。"
}

function rawconf() {
  read_protocol
  if [[ "$numprotocol" == "00" ]]; then return 2; fi
  read_s_port || return 1
  read_d_ip || return 1
  read_d_port || return 1
  commit_new_rule
}

function show_rule_menu() {
    clear
    show_all_conf
    echo -e "--------------------------------------------------------"
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function add_rule_menu() {
  while true; do
    echo -e "当前配置如下"
    show_all_conf
    echo -e "--------------------------------------------------------"
    echo -e "[1] 继续添加新的转发规则"
    echo -e "[00] 返回主菜单"
    echo -e "--------------------------------------------------------"
    read -p "请选择: " add_choice
    if [ "$add_choice" == "1" ]; then
      rawconf || true
    elif [ "$add_choice" == "00" ]; then
      break
    else
      echo "输入错误，请重新选择"
    fi
  done
}

function delete_rule_menu() {
  while true; do
    clear
    show_all_conf
    if [[ ! -f $raw_conf_path ]] || [[ ! -s $raw_conf_path ]]; then
      read -n 1 -s -r -p "按任意键返回主菜单..."
      break
    fi
    echo -e "--------------------------------------------------------"
    read -p "请输入你要删除的配置编号(输入00返回主菜单)：" numdelete
    if [ "$numdelete" == "00" ]; then
      break
    elif echo "$numdelete" | grep -q '^[0-9][0-9]*$'; then
      total_lines=$(sed -n '$=' "$raw_conf_path")
      if [ "$numdelete" -gt 0 ] && [ "$numdelete" -le "$total_lines" ]; then
        snapshot_config_change || { echo -e "${Error} 无法创建配置快照。"; return 1; }
        raw_temp=$(mktemp "$gost_conf_dir/.rawconf.XXXXXXXX") || { rollback_config_change; return 1; }
        awk -v line="$numdelete" 'NR != line' "$raw_conf_path" > "$raw_temp"
        chmod 600 "$raw_temp"
        mv -f "$raw_temp" "$raw_conf_path"
        if regenerate_yaml_config && systemctl restart gost && wait_for_gost_service; then
          rm -rf -- "$config_change_backup"
          echo -e "${Info} 配置已删除并生效。"
        else
          echo -e "${Error} 删除后的配置未能生效，正在恢复。"
          rollback_config_change
        fi
      else
        echo -e "${Error} 输入的编号不在有效范围内"
          sleep 1
      fi
    else
      echo -e "${Error} 请输入正确的数字"
      sleep 1
    fi
  done
}

function update_sh() {
  local update_temp ol_version update_confirm script_backup
  if ! command -v curl >/dev/null 2>&1; then
    check_sys && Installation_dependency || return 1
  fi
  update_temp=$(mktemp "${TMPDIR:-/tmp}/gost-v3-script.XXXXXXXX") || return 1
  if ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 "$self_update_url" -o "$update_temp"; then
    echo -e "${Error} 下载脚本更新失败。"
    rm -f "$update_temp"
    return 1
  fi
  if ! bash -n "$update_temp"; then
    echo -e "${Error} 下载的脚本未通过语法检查。"
    rm -f "$update_temp"
    return 1
  fi
  ol_version=$(awk -F '"' '/^shell_version="[0-9]/{print $2; exit}' "$update_temp")
  if [[ -z "$ol_version" ]]; then
    echo -e "${Error} 无法识别远程脚本版本。"
    rm -f "$update_temp"
    return 1
  fi
  if ! version_gt "$ol_version" "$shell_version"; then
    echo "当前脚本已是最新版本 (v${shell_version})。"
    rm -f "$update_temp"
    return 0
  fi

  read -r -p "存在新版本 v${ol_version}，是否更新? (y/N): " update_confirm
  if [[ ! "$update_confirm" =~ ^[yY]$ ]]; then
    rm -f "$update_temp"
    echo "已取消更新。"
    return 0
  fi

  script_backup="$0.bak.$(date +%Y%m%d_%H%M%S)"
  if ! cp -a -- "$0" "$script_backup" || ! install -m 755 "$update_temp" "$0"; then
    echo -e "${Error} 更新脚本失败；原文件未被删除，备份位置: $script_backup"
    rm -f "$update_temp"
    return 1
  fi
  rm -f "$update_temp"
  echo -e "${Info} 更新完成，原脚本备份: $script_backup"
  exec bash "$0"
}

function replace_gost_cron_entry() {
  local new_entry="${1:-}" cron_temp cron_backup
  mkdir -p "$(dirname "$crontab_path")" "$install_backup_root"
  chmod 700 "$install_backup_root"
  [[ -e "$crontab_path" ]] || : > "$crontab_path"
  cron_backup="$install_backup_root/crontab.$(date +%Y%m%d_%H%M%S).bak"
  cp -a -- "$crontab_path" "$cron_backup" || return 1
  chmod 600 "$cron_backup"
  cron_temp=$(mktemp "$(dirname "$crontab_path")/.crontab.XXXXXXXX") || return 1
  awk -v marker="$cron_marker" 'index($0, marker) == 0' "$crontab_path" > "$cron_temp" || { rm -f "$cron_temp"; return 1; }
  [[ -z "$new_entry" ]] || printf '%s %s\n' "$new_entry" "$cron_marker" >> "$cron_temp"
  chmod --reference="$crontab_path" "$cron_temp" 2>/dev/null || chmod 644 "$cron_temp"
  chown --reference="$crontab_path" "$cron_temp" 2>/dev/null || true
  mv -f "$cron_temp" "$crontab_path"
  local old_cron_backups=() index
  mapfile -t old_cron_backups < <(find "$install_backup_root" -maxdepth 1 -type f -name 'crontab.*.bak' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  for ((index=5; index<${#old_cron_backups[@]}; index++)); do
    [[ "${old_cron_backups[$index]}" == "$install_backup_root"/crontab.*.bak ]] && rm -f -- "${old_cron_backups[$index]}"
  done
}

function cron_restart() {
  echo -e "gost定时重启任务: [1]配置 [2]删除"
  read -r -p "请选择: " numcron
  if [[ "$numcron" == "1" ]]; then
    echo -e "任务类型: [1]每?小时重启 [2]每日?点重启"
    read -r -p "请选择: " numcrontype
    if [[ ! "$numcrontype" =~ ^[12]$ ]]; then
      echo -e "${Error} 任务类型只能是 1 或 2，crontab 未修改。"
      return 1
    fi
    read -r -p "请输入小时数或整点数: " cronhr
    if [[ "$numcrontype" == "1" ]]; then
      if [[ ! "$cronhr" =~ ^[0-9]+$ ]] || ((10#$cronhr < 1 || 10#$cronhr > 23)); then
        echo -e "${Error} 间隔小时必须是 1-23，crontab 未修改。"
        return 1
      fi
      cron_entry="0 */$((10#$cronhr)) * * * root systemctl restart gost"
    else
      if [[ ! "$cronhr" =~ ^[0-9]+$ ]] || ((10#$cronhr < 0 || 10#$cronhr > 23)); then
        echo -e "${Error} 每日整点必须是 0-23，crontab 未修改。"
        return 1
      fi
      cron_entry="0 $((10#$cronhr)) * * * root systemctl restart gost"
    fi
    replace_gost_cron_entry "$cron_entry" || { echo -e "${Error} 写入 crontab 失败。"; return 1; }
    echo -e "定时重启设置成功！仅管理带有 ${cron_marker} 标记的任务。"
  elif [[ "$numcron" == "2" ]]; then
    replace_gost_cron_entry "" || { echo -e "${Error} 删除定时任务失败。"; return 1; }
    echo -e "本脚本创建的定时重启任务已删除。"
  else
    echo -e "${Error} 只能选择 1 或 2，crontab 未修改。"
    return 1
  fi
}

function backup_gost() {
    echo -e "${Info} 开始备份gost配置..."
    mkdir -p "${backup_path}"
    chmod 700 "${backup_path}"
    local backup_file
    backup_file="${backup_path}/gost_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    if tar -zcvf "${backup_file}" -C "$(dirname "$gost_conf_dir")" "$(basename "$gost_conf_dir")"; then
        echo -e "${Info} 备份成功！文件位于: ${Green_font_prefix}${backup_file}${Font_color_suffix}"
    else
        echo -e "${Error} 备份失败。"
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function restore_gost() {
    if [ ! -d "${backup_path}" ] || [ -z "$(ls -A "${backup_path}"/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${Error} 未找到任何备份文件。"
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi
    echo -e "可用备份文件列表:"
    # shellcheck disable=SC2012
    select backup_file in $(ls -r "${backup_path}"/*.tar.gz); do
        [ -n "${backup_file}" ] && break || echo "无效选择"
    done
    read -p "这将覆盖当前所有配置，是否继续? [y/N]: " confirm
    if [[ ! ${confirm} =~ ^[yY]$ ]]; then
        echo -e "已取消恢复操作。"; return
    fi
    tar -zxvf "${backup_file}" -C "$(dirname "$gost_conf_dir")"
    if [ $? -eq 0 ]; then
        echo -e "${Info} 恢复成功！正在重启gost服务..."
        restart_gost_safely
    else
        echo -e "${Error} 恢复失败。"
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

function main_menu() {
  clear
  # update_sh # Temporarily disable auto-update check
  echo && echo -e "gost v3 一键安装配置脚本 ${Red_font_prefix}[v${shell_version}]${Font_color_suffix} (YAML-Fixed)"
  echo -e "
  ${Green_font_prefix}1.${Font_color_suffix} 安装 gost v3
  ${Green_font_prefix}2.${Font_color_suffix} 更新 gost v3
  ${Green_font_prefix}3.${Font_color_suffix} 卸载 gost v3
  ————————————
  ${Green_font_prefix}4.${Font_color_suffix} 启动 gost
  ${Green_font_prefix}5.${Font_color_suffix} 停止 gost
  ${Green_font_prefix}6.${Font_color_suffix} 重启 gost
  ————————————
  ${Green_font_prefix}7.${Font_color_suffix} 新增gost转发配置
  ${Green_font_prefix}8.${Font_color_suffix} 查看现有gost配置
  ${Green_font_prefix}9.${Font_color_suffix} 删除一则gost配置
  ————————————
  ${Green_font_prefix}10.${Font_color_suffix} gost定时重启配置
  ${Green_font_prefix}11.${Font_color_suffix} 备份gost配置
  ${Green_font_prefix}12.${Font_color_suffix} 恢复gost配置
  ${Green_font_prefix}13.${Font_color_suffix} 更新本脚本
  ————————————
  ${Green_font_prefix}00.${Font_color_suffix} 退出脚本
  ————————————" && echo
  read -e -r -p "请输入数字 [1-13,00]: " num
  case "$num" in
    1) Install_ct ;;
    2) checknew ;;
    3) Uninstall_ct ;;
    4) Start_ct ;;
    5) Stop_ct ;;
    6) Restart_ct ;;
    7)
      if rawconf; then
        add_rule_menu
      fi
      ;;
    8) show_rule_menu ;;
    9) delete_rule_menu ;;
    10) cron_restart ;;
    11) backup_gost ;;
    12) restore_gost ;;
    13) update_sh ;;
    00) exit 0 ;;
    *) echo "请输入正确数字" ;;
  esac
}

if [[ "${GOST_SOURCE_ONLY:-0}" != "1" ]]; then
  while true; do
    main_menu
  done
fi
