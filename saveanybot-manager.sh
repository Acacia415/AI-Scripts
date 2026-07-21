#!/usr/bin/env bash
# SaveAnyBot + OpenList 交互式部署与存储管理脚本
# 支持 Debian / Ubuntu，支持 amd64 / arm64。

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.2"
SAVEANY_DIR="/opt/telegram"
SAVEANY_BIN="${SAVEANY_DIR}/saveany-bot"
SAVEANY_CONFIG="${SAVEANY_DIR}/config.toml"
SAVEANY_SERVICE="/etc/systemd/system/saveany-bot.service"
OPENLIST_DIR="/opt/openlist"
STATE_FILE="/etc/saveanybot-manager.conf"
OPENLIST_PORT="5244"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${BLUE}[信息]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[成功]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[注意]${NC} %s\n" "$*"; }
error()   { printf "${RED}[错误]${NC} %s\n" "$*" >&2; }

pause() {
  printf "\n"
  read -r -p "按回车键继续..." _
}

confirm() {
  local prompt="${1:-确认继续吗？}"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # 该文件仅保存目录和端口，不保存密码。
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  cat > "${STATE_FILE}" <<EOF
SAVEANY_DIR='${SAVEANY_DIR}'
OPENLIST_DIR='${OPENLIST_DIR}'
OPENLIST_PORT='${OPENLIST_PORT}'
EOF
  chmod 600 "${STATE_FILE}"
}

check_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    error "无法识别操作系统。本脚本仅支持 Debian / Ubuntu。"
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      error "当前系统是 ${PRETTY_NAME:-未知}，本脚本仅支持 Debian / Ubuntu。"
      exit 1
      ;;
  esac
}

install_base_packages() {
  info "检查基础依赖..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl jq tar gzip unzip sed grep coreutils findutils \
    iproute2 procps
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    local backup="${file}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${backup}"
    info "已备份：${backup}"
  fi
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

validate_bot_token() {
  local token="$1"
  local response_file http_code description username
  response_file="$(mktemp)"

  info "正在验证 Telegram Bot Token..."
  if ! http_code="$(curl -sS --connect-timeout 10 --max-time 20 \
      -o "${response_file}" -w '%{http_code}' \
      "https://api.telegram.org/bot${token}/getMe")"; then
    rm -f "${response_file}"
    error "无法连接 Telegram Bot API。请检查服务器网络、DNS或代理配置。"
    return 1
  fi

  if [[ "${http_code}" != "200" ]] || ! jq -e '.ok == true' "${response_file}" >/dev/null 2>&1; then
    description="$(jq -r '.description // "未知错误"' "${response_file}" 2>/dev/null || printf '未知错误')"
    rm -f "${response_file}"
    error "Bot Token 验证失败：HTTP ${http_code}，${description}"
    return 1
  fi

  username="$(jq -r '.result.username // empty' "${response_file}")"
  rm -f "${response_file}"
  success "Bot Token 验证通过：@${username:-未知用户名}"
}

wait_for_saveanybot_ready() {
  local since="$1"
  local timeout="${2:-45}"
  local elapsed=0 logs=""

  while (( elapsed < timeout )); do
    if ! systemctl is-active --quiet saveany-bot; then
      return 1
    fi

    logs="$(journalctl -u saveany-bot --since "${since}" --no-pager -o cat 2>/dev/null || true)"
    if grep -Fq 'Bot initialization completed.' <<<"${logs}"; then
      return 0
    fi
    if grep -Eqi 'unauthorized|invalid token|token.*invalid|initialization failed|panic|fatal' <<<"${logs}"; then
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  return 1
}

get_public_address() {
  local ip=""
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${ip:-服务器IP}"
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    return 127
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    info "安装 Docker..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    info "安装 Docker Compose..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 2>/dev/null \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin 2>/dev/null \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi

  if ! docker info >/dev/null 2>&1; then
    error "Docker 未正常运行。"
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    error "Docker Compose 安装失败。"
    return 1
  fi
}

map_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *)
      error "不支持的架构：$(uname -m)，目前只支持 amd64 和 arm64。"
      return 1
      ;;
  esac
}

download_saveanybot() {
  local arch="$1"
  local tmpdir release_json asset_url binary
  tmpdir="$(mktemp -d)"
  release_json="${tmpdir}/release.json"

  info "获取 SaveAnyBot 最新版本信息..."
  curl -fsSL --retry 3 \
    https://api.github.com/repos/krau/SaveAny-Bot/releases/latest \
    -o "${release_json}"

  asset_url="$(jq -r --arg arch "${arch}" '
    .assets[]
    | select(.name | test("linux"; "i"))
    | select(
        if $arch == "amd64"
        then (.name | test("amd64|x86_64"; "i"))
        else (.name | test("arm64|aarch64"; "i"))
        end
      )
    | select(.name | test("\\.(tar\\.gz|tgz|zip)$"; "i"))
    | .browser_download_url
  ' "${release_json}" | head -n 1)"

  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    rm -rf "${tmpdir}"
    error "没有找到与 linux/${arch} 匹配的发布文件。"
    return 1
  fi

  info "下载：$(basename "${asset_url}")"
  curl -fL --retry 3 --progress-bar "${asset_url}" -o "${tmpdir}/package"

  case "${asset_url}" in
    *.tar.gz|*.tgz) tar -xzf "${tmpdir}/package" -C "${tmpdir}" ;;
    *.zip) unzip -q "${tmpdir}/package" -d "${tmpdir}" ;;
    *)
      rm -rf "${tmpdir}"
      error "未知发布文件格式。"
      return 1
      ;;
  esac

  binary="$(find "${tmpdir}" -type f -name 'saveany-bot' -print -quit)"
  if [[ -z "${binary}" ]]; then
    rm -rf "${tmpdir}"
    error "压缩包中没有找到 saveany-bot。"
    return 1
  fi

  install -m 755 "${binary}" "${SAVEANY_BIN}.new"
  rm -rf "${tmpdir}"
}

write_default_config() {
  local token user_id token_esc

  printf "\n"
  info "创建 SaveAnyBot 初始配置。"
  warn "Bot Token 可在 Telegram 的 @BotFather 中创建机器人后获得。"
  read -r -s -p "请输入 Telegram Bot Token: " token
  printf "\n"
  if [[ -z "${token}" ]]; then
    error "Bot Token 不能为空。"
    return 1
  fi
  if [[ ! "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    error "Bot Token 格式不完整。正确格式类似：1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    error "请确认包含前面的数字机器人 ID、冒号以及后面的密钥。"
    return 1
  fi
  info "已接收 Bot Token（共 ${#token} 个字符；为安全起见，输入过程不会显示明文）。"
  validate_bot_token "${token}" || return 1

  warn "Telegram 数字用户 ID 可通过 @userinfobot 等机器人查询。"
  read -r -p "请输入允许使用机器人的 Telegram 数字用户 ID: " user_id
  if [[ ! "${user_id}" =~ ^-?[0-9]+$ ]]; then
    error "用户 ID 必须是纯数字。"
    return 1
  fi

  token_esc="$(toml_escape "${token}")"
  cat > "${SAVEANY_CONFIG}" <<EOF
lang = "zh-CN"
workers = 3
retry = 3
threads = 4
stream = false

[log]
level = "info"

[telegram]
token = "${token_esc}"

[telegram.proxy]
enable = false
url = "socks5://127.0.0.1:7890"

[[storages]]
name = "本机存储"
type = "local"
enable = true
base_path = "./downloads"

[[users]]
id = ${user_id}
storages = []
blacklist = true
EOF
  chmod 600 "${SAVEANY_CONFIG}"
}

write_systemd_service() {
  cat > "${SAVEANY_SERVICE}" <<EOF
[Unit]
Description=SaveAnyBot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${SAVEANY_DIR}
ExecStart=${SAVEANY_BIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_saveanybot() {
  clear
  printf "${CYAN}=== 安装或更新 SaveAnyBot ===${NC}\n\n"
  install_base_packages

  mkdir -p "${SAVEANY_DIR}/data" "${SAVEANY_DIR}/cache" "${SAVEANY_DIR}/downloads"

  if [[ -x "${SAVEANY_BIN}" ]]; then
    warn "检测到已安装的 SaveAnyBot。此操作会更新程序，但保留配置和数据。"
    confirm "继续更新吗？" || return 0
  fi

  local arch
  arch="$(map_arch)"
  download_saveanybot "${arch}"

  if systemctl is-active --quiet saveany-bot 2>/dev/null; then
    systemctl stop saveany-bot
  fi

  if [[ -f "${SAVEANY_BIN}" ]]; then
    cp -a "${SAVEANY_BIN}" "${SAVEANY_BIN}.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  mv -f "${SAVEANY_BIN}.new" "${SAVEANY_BIN}"
  chmod 755 "${SAVEANY_BIN}"

  if [[ ! -f "${SAVEANY_CONFIG}" ]]; then
    write_default_config
  else
    info "检测到现有配置，已保留：${SAVEANY_CONFIG}"
    chmod 600 "${SAVEANY_CONFIG}"
  fi

  write_systemd_service
  local service_start_time
  service_start_time="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl enable --now saveany-bot

  info "等待机器人完成初始化，最长 45 秒..."
  if wait_for_saveanybot_ready "${service_start_time}" 45; then
    success "SaveAnyBot 已启动并完成机器人初始化。"
    journalctl -u saveany-bot --since "${service_start_time}" --no-pager || true
  else
    error "SaveAnyBot 未完成初始化。systemd 进程可能仍处于运行状态，但机器人尚不可用。"
    journalctl -u saveany-bot --since "${service_start_time}" -n 80 --no-pager || true
    printf "\n"
    warn "常见原因：Bot Token 错误、服务器无法访问 Telegram、DNS异常或需要代理。"
    return 1
  fi

  save_state
  printf "\n"
  info "配置文件：${SAVEANY_CONFIG}"
  info "实时日志：journalctl -u saveany-bot -f -o cat"
  pause
}

install_openlist() {
  clear
  printf "${CYAN}=== 安装或更新 OpenList ===${NC}\n\n"
  install_base_packages
  install_docker

  local input_port
  read -r -p "OpenList 对外端口 [${OPENLIST_PORT}]: " input_port
  OPENLIST_PORT="${input_port:-${OPENLIST_PORT}}"
  if [[ ! "${OPENLIST_PORT}" =~ ^[0-9]+$ ]] || (( OPENLIST_PORT < 1 || OPENLIST_PORT > 65535 )); then
    error "端口无效。"
    return 1
  fi

  mkdir -p "${OPENLIST_DIR}/data"

  if [[ -f "${OPENLIST_DIR}/docker-compose.yml" ]]; then
    warn "检测到现有 OpenList Compose 配置。"
    if confirm "是否用本脚本的配置覆盖？现有 data 目录不会删除。"; then
      backup_file "${OPENLIST_DIR}/docker-compose.yml"
    else
      info "保留现有 Compose 配置，仅执行拉取和启动。"
      (
        cd "${OPENLIST_DIR}"
        compose pull
        compose up -d
      )
      save_state
      pause
      return 0
    fi
  fi

  cat > "${OPENLIST_DIR}/docker-compose.yml" <<EOF
services:
  openlist:
    image: openlistteam/openlist:latest
    container_name: openlist
    user: "0:0"
    volumes:
      - ./data:/opt/openlist/data
    ports:
      - "${OPENLIST_PORT}:5244"
    environment:
      - UMASK=022
      - TZ=Asia/Shanghai
    restart: unless-stopped
EOF

  (
    cd "${OPENLIST_DIR}"
    compose pull
    compose up -d
  )

  sleep 4
  if ! docker ps --format '{{.Names}}' | grep -qx 'openlist'; then
    error "OpenList 容器没有正常运行。"
    docker logs --tail 100 openlist 2>/dev/null || true
    return 1
  fi

  save_state
  local addr
  addr="$(get_public_address)"
  success "OpenList 已启动：http://${addr}:${OPENLIST_PORT}"
  printf "\n"
  info "管理员信息："
  docker exec openlist /opt/openlist/openlist admin 2>/dev/null \
    || docker exec openlist ./openlist admin 2>/dev/null \
    || docker logs --tail 100 openlist 2>/dev/null | grep -Ei 'password|admin' \
    || warn "未能自动读取管理员信息，请执行：docker logs openlist --tail 100"

  printf "\n"
  warn "首次登录后请立即修改管理员密码。"
  info "OpenList 数据目录：${OPENLIST_DIR}/data"
  info "OpenList 日志：docker logs -f --tail 100 openlist"
  pause
}

ensure_components() {
  if [[ ! -f "${SAVEANY_CONFIG}" || ! -x "${SAVEANY_BIN}" ]]; then
    error "尚未安装 SaveAnyBot，请先运行菜单 1。"
    return 1
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'openlist'; then
    error "OpenList 未运行，请先运行菜单 2。"
    return 1
  fi
}

show_common_openlist_steps() {
  local mount_path="$1"
  local folder_path="${mount_path%/}/SaveAnyBot"

  cat <<EOF

${CYAN}完成网盘挂载后，还需要在 OpenList 中进行以下操作：${NC}

1. 打开 OpenList 文件页面，进入：${mount_path}
2. 新建文件夹：SaveAnyBot
   最终路径应为：${folder_path}
3. 进入：后台 → 用户 → 新建用户
4. 用户的“基本路径”填写：${folder_path}
5. 至少启用以下权限：
   - 写入/上传或创建目录
   - 重命名
   - 移动
   - 删除
   - WebDAV 读取
   - WebDAV 管理
6. 用户名区分大小写，请记录用户名和密码。

说明：SaveAnyBot 将通过 OpenList 的 /dav/ 地址写入这个专用目录。
EOF
}

show_driver_guide() {
  local kind="$1"
  case "${kind}" in
    google)
      cat <<'EOF'
=== 在 OpenList 中添加 Google Drive ===

1. 进入 Google Cloud Console，新建或选择项目。
2. 启用 Google Drive API。
3. 配置 OAuth 权限请求页面；外部应用需把自己的 Google 账号加入测试用户。
4. 创建“Web 应用”OAuth 客户端，回调地址填写：
   https://api.oplist.org/googleui/callback
5. 打开 https://api.oplist.org/ ，选择 Google Drive，使用自己的
   Client ID 和 Client Secret 获取 Refresh Token。
6. OpenList 后台 → 存储 → 添加：
   - 驱动：Google Drive
   - 挂载路径：/GoogleDrive
   - 根文件夹 ID：root
   - 刷新令牌：上一步获得的 Refresh Token
   - 使用自己的 OAuth 时关闭“Use online api”
   - 填入自己的 Client ID 和 Client Secret
7. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/google_drive
EOF
      ;;
    115)
      cat <<'EOF'
=== 在 OpenList 中添加 115 网盘 ===

建议使用官方接口驱动“115 开放平台”，不要优先使用旧的 Cookie 逆向驱动。

1. 打开 https://api.oplist.org/ ，选择 115 验证网盘。
2. 没有自己的 115 开放平台应用时，勾选“使用 OpenList 提供的参数”。
3. 登录 115 并授权，保存 Access Token 和 Refresh Token。
4. OpenList 后台 → 存储 → 添加：
   - 驱动：115 开放平台
   - 挂载路径：/115
   - 根文件夹 ID：0（115 根目录）
   - 填入 Access Token 和 Refresh Token
5. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/115_open
EOF
      ;;
    aliyun)
      cat <<'EOF'
=== 在 OpenList 中添加阿里云盘 Open ===

1. 打开 https://api.oplist.org/ ，选择阿里云盘 Open 获取 Refresh Token。
2. OpenList 后台 → 存储 → 添加：
   - 驱动：阿里云盘 Open / AliYun Drive (Oauth2)
   - 挂载路径：/AliyunDrive
   - 根文件夹 ID：root
   - 填入 Refresh Token
3. 使用 OpenList 公共参数时开启“Use online api”；使用自己的 OAuth
   客户端时关闭该选项并填写 Client ID、Client Secret。
4. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/aliyundrive_open
EOF
      ;;
    onedrive)
      cat <<'EOF'
=== 在 OpenList 中添加 OneDrive ===

1. 打开 https://api.oplist.org/ ，按账号地区选择 OneDrive 类型。
2. 可勾选“使用 OpenList 提供的参数”，登录 Microsoft 账号并获取
   Refresh Token；也可使用自己注册的 Azure 应用。
3. OpenList 后台 → 存储 → 添加：
   - 驱动：与你账号类型对应的 OneDrive
   - 挂载路径：/OneDrive
   - 根文件夹路径：/
   - 使用公共参数时开启“Use online api”
   - 填入 Refresh Token
4. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/onedrive
EOF
      ;;
    quark)
      cat <<'EOF'
=== 在 OpenList 中添加夸克网盘 ===

用于 SaveAnyBot 上传时，请选择支持写入的“夸克网盘”驱动，不要选择仅适合
读取的 QuarkTV 驱动。

1. 使用 Chrome 登录 https://pan.quark.cn/ 。
2. 按 F12 → 网络，刷新页面，从请求头中复制 Cookie。
3. OpenList 后台 → 存储 → 添加：
   - 驱动：夸克网盘
   - 挂载路径：/Quark
   - 根文件夹 ID：0
   - Cookie：粘贴刚获取的 Cookie
4. 按驱动提示配置本地代理/中转策略。
5. 保存后，必须先在 OpenList 文件页面测试上传。

官方说明：https://doc.oplist.org/guide/drivers/quark
EOF
      ;;
    pikpak)
      cat <<'EOF'
=== 在 OpenList 中添加 PikPak ===

1. OpenList 后台 → 存储 → 添加：
   - 驱动：PikPak
   - 挂载路径：/PikPak
   - 用户名：PikPak 邮箱或手机号
   - 密码：PikPak 登录密码
   - 根文件夹 ID：留空表示根目录，或填写目标目录 ID
2. 若账号通过 Google/Facebook 第三方登录注册，请先在 PikPak 中绑定邮箱
   并设置独立登录密码。
3. 遇到验证码时，根据驱动页面提示获取 captcha_token。
4. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/pikpak
EOF
      ;;
    baidu)
      cat <<'EOF'
=== 在 OpenList 中添加百度网盘 ===

1. 打开 https://api.oplist.org/ ，选择百度网盘授权方式获取 Refresh Token。
2. 没有开发者应用时可使用 OpenList 在线 API；有自己的百度应用时，回调地址
   按页面要求配置，并使用自己的 Client ID 和 Client Secret。
3. OpenList 后台 → 存储 → 添加：
   - 驱动：百度网盘
   - 挂载路径：/Baidu
   - 填入 Refresh Token
   - 使用公共参数时开启“Use online api”
4. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/baidu
EOF
      ;;
    123pan)
      cat <<'EOF'
=== 在 OpenList 中添加 123 云盘 ===

为了上传稳定，优先选择“123 开放平台”驱动，而不是分享或旧逆向驱动。

1. 在 123 开放平台注册应用，获取 Client ID 和 Client Secret。
2. 在 123 网盘设置中查询账号 ID/云盘 UID。
3. OpenList 后台 → 存储 → 添加：
   - 驱动：123 开放平台
   - 挂载路径：/123
   - 根文件夹 ID：0
   - Refresh Token：按当前驱动说明留空或填写
   - 填入 Client ID、Client Secret 和云盘 UID
4. 保存后，在 OpenList 文件页面测试上传一个小文件。

官方说明：https://doc.oplist.org/guide/drivers/123_open
EOF
      ;;
    generic)
      cat <<'EOF'
=== 添加其他 OpenList 存储 ===

1. OpenList 后台 → 存储 → 添加。
2. 选择对应网盘驱动，并按驱动页面填写账号、Cookie、Token 或 OAuth 信息。
3. 挂载路径必须填写，例如 /MyDrive。
4. 保存后先在 OpenList 文件页面手动上传一个小文件。
5. 只有支持写入的驱动才能作为 SaveAnyBot 存储；只读分享盘无法使用。

驱动文档入口：https://doc.oplist.org/guide/drivers/common
EOF
      ;;
  esac
}

append_webdav_storage() {
  local storage_name="$1"
  local username="$2"
  local password="$3"
  local webdav_url="$4"
  local name_esc user_esc pass_esc url_esc block_file new_file user_line

  name_esc="$(toml_escape "${storage_name}")"
  user_esc="$(toml_escape "${username}")"
  pass_esc="$(toml_escape "${password}")"
  url_esc="$(toml_escape "${webdav_url}")"

  if grep -Fq "name = \"${name_esc}\"" "${SAVEANY_CONFIG}"; then
    error "配置中已经存在同名存储：${storage_name}"
    return 1
  fi

  block_file="$(mktemp)"
  new_file="$(mktemp)"
  cat > "${block_file}" <<EOF
[[storages]]
name = "${name_esc}"
type = "webdav"
enable = true
base_path = "/"
url = "${url_esc}"
username = "${user_esc}"
password = "${pass_esc}"

EOF

  user_line="$(grep -n -m1 '^\[\[users\]\]' "${SAVEANY_CONFIG}" | cut -d: -f1 || true)"
  if [[ -n "${user_line}" ]]; then
    head -n "$((user_line - 1))" "${SAVEANY_CONFIG}" > "${new_file}"
    cat "${block_file}" >> "${new_file}"
    tail -n "+${user_line}" "${SAVEANY_CONFIG}" >> "${new_file}"
  else
    cat "${SAVEANY_CONFIG}" > "${new_file}"
    printf '\n' >> "${new_file}"
    cat "${block_file}" >> "${new_file}"
  fi

  backup_file "${SAVEANY_CONFIG}"
  install -m 600 "${new_file}" "${SAVEANY_CONFIG}"
  rm -f "${block_file}" "${new_file}"
}

test_webdav() {
  local url="$1"
  local username="$2"
  local password="$3"
  local code test_name tmpfile

  info "测试 WebDAV 读取权限..."
  code="$(curl -sS -o /tmp/saveanybot-propfind.xml -w '%{http_code}' \
    --user "${username}:${password}" \
    -X PROPFIND -H 'Depth: 1' "${url}" || true)"
  if [[ "${code}" != "207" ]]; then
    error "PROPFIND 测试失败，HTTP 状态码：${code:-无响应}"
    warn "请检查用户名大小写、密码、基本路径和 WebDAV 读取权限。"
    return 1
  fi
  success "WebDAV 读取测试通过（207）。"

  info "测试 WebDAV 写入权限..."
  test_name="saveanybot-manager-test-$(date +%s).txt"
  tmpfile="$(mktemp)"
  printf 'SaveAnyBot WebDAV test\n' > "${tmpfile}"
  code="$(curl -sS -o /tmp/saveanybot-put.txt -w '%{http_code}' \
    --user "${username}:${password}" \
    -T "${tmpfile}" "${url}${test_name}" || true)"
  rm -f "${tmpfile}"

  if [[ "${code}" != "201" && "${code}" != "204" ]]; then
    error "PUT 测试失败，HTTP 状态码：${code:-无响应}"
    warn "请确认网盘驱动支持上传，并启用写入、WebDAV 管理等权限。"
    return 1
  fi
  success "WebDAV 写入测试通过（${code}）。"

  curl -sS --user "${username}:${password}" -X DELETE \
    "${url}${test_name}" >/dev/null 2>&1 || true
}

add_cloud_storage() {
  local kind="$1" default_name="$2" default_mount="$3" default_user="$4"
  clear
  printf "${CYAN}=== 添加 ${default_name} 到 SaveAnyBot ===${NC}\n\n"
  ensure_components || { pause; return 1; }

  show_driver_guide "${kind}"

  local mount_path input storage_name username password password2 webdav_url
  read -r -p "OpenList 挂载路径 [${default_mount}]: " input
  mount_path="${input:-${default_mount}}"
  [[ "${mount_path}" == /* ]] || mount_path="/${mount_path}"
  mount_path="${mount_path%/}"

  show_common_openlist_steps "${mount_path}"
  printf "\n"
  read -r -p "请在 OpenList 完成挂载、创建 SaveAnyBot 文件夹和专用用户后，按回车继续..." _

  read -r -p "SaveAnyBot 中显示的存储名称 [${default_name}]: " input
  storage_name="${input:-${default_name}}"
  read -r -p "OpenList 专用 WebDAV 用户名 [${default_user}]: " input
  username="${input:-${default_user}}"

  while true; do
    read -r -s -p "请输入该 OpenList 用户的密码: " password
    printf "\n"
    read -r -s -p "请再次输入密码: " password2
    printf "\n"
    if [[ -n "${password}" && "${password}" == "${password2}" ]]; then
      break
    fi
    warn "两次密码不一致或密码为空，请重新输入。"
  done

  webdav_url="http://127.0.0.1:${OPENLIST_PORT}/dav/"
  test_webdav "${webdav_url}" "${username}" "${password}" || { pause; return 1; }

  append_webdav_storage "${storage_name}" "${username}" "${password}" "${webdav_url}"
  systemctl restart saveany-bot
  sleep 2

  if systemctl is-active --quiet saveany-bot; then
    success "${storage_name} 已加入 SaveAnyBot。"
    journalctl -u saveany-bot -n 12 --no-pager || true
    printf "\n"
    info "现在可在 Telegram 中发送 /storage 并选择：${storage_name}"
    info "文件将写入 OpenList：${mount_path}/SaveAnyBot"
  else
    error "SaveAnyBot 重启失败，正在恢复最近一次配置备份。"
    local latest_backup
    latest_backup="$(ls -1t "${SAVEANY_CONFIG}.bak-"* 2>/dev/null | head -n 1 || true)"
    if [[ -n "${latest_backup}" ]]; then
      cp -a "${latest_backup}" "${SAVEANY_CONFIG}"
      systemctl restart saveany-bot || true
      warn "已恢复：${latest_backup}"
    fi
    journalctl -u saveany-bot -n 50 --no-pager || true
    return 1
  fi
  pause
}

add_generic_storage() {
  clear
  printf "${CYAN}=== 添加其他 OpenList 存储 ===${NC}\n\n"
  ensure_components || { pause; return 1; }
  show_driver_guide generic

  local display_name mount_path default_user
  read -r -p "网盘名称（例如 天翼云盘）: " display_name
  [[ -n "${display_name}" ]] || { error "名称不能为空。"; pause; return 1; }
  read -r -p "OpenList 挂载路径（例如 /189Cloud）: " mount_path
  [[ -n "${mount_path}" ]] || { error "挂载路径不能为空。"; pause; return 1; }
  default_user="SaveAnyBot$(date +%s)"
  add_cloud_storage generic "${display_name}" "${mount_path}" "${default_user}"
}

create_backup_archive() {
  local scope="${1:-all}"
  local output="/root/saveany-openlist-backup-${scope}-$(date +%Y%m%d-%H%M%S).tar.gz"
  local items=()

  case "${scope}" in
    saveany)
      [[ -f "${SAVEANY_CONFIG}" ]] && items+=("${SAVEANY_CONFIG}")
      [[ -d "${SAVEANY_DIR}/data" ]] && items+=("${SAVEANY_DIR}/data")
      ;;
    openlist)
      [[ -d "${OPENLIST_DIR}/data" ]] && items+=("${OPENLIST_DIR}/data")
      [[ -f "${OPENLIST_DIR}/docker-compose.yml" ]] && items+=("${OPENLIST_DIR}/docker-compose.yml")
      ;;
    all)
      [[ -f "${SAVEANY_CONFIG}" ]] && items+=("${SAVEANY_CONFIG}")
      [[ -d "${SAVEANY_DIR}/data" ]] && items+=("${SAVEANY_DIR}/data")
      [[ -d "${OPENLIST_DIR}/data" ]] && items+=("${OPENLIST_DIR}/data")
      [[ -f "${OPENLIST_DIR}/docker-compose.yml" ]] && items+=("${OPENLIST_DIR}/docker-compose.yml")
      ;;
    *)
      error "未知备份范围：${scope}"
      return 1
      ;;
  esac

  if (( ${#items[@]} == 0 )); then
    warn "没有找到可备份的配置。"
    return 1
  fi

  tar -czf "${output}" "${items[@]}"
  chmod 600 "${output}"
  success "备份完成：${output}"
  warn "备份包含 Token、网盘凭据和密码，请勿公开。"
  warn "为避免备份体积过大，downloads 和 cache 目录未包含在配置备份中。"
}

refresh_state_after_uninstall() {
  if [[ ! -x "${SAVEANY_BIN}" && ! -f "${OPENLIST_DIR}/docker-compose.yml" ]]; then
    rm -f "${STATE_FILE}"
  else
    save_state
  fi
}

remove_saveanybot_component() {
  local purge="${1:-false}"

  systemctl disable --now saveany-bot >/dev/null 2>&1 || true
  rm -f "${SAVEANY_SERVICE}"
  systemctl daemon-reload
  systemctl reset-failed saveany-bot >/dev/null 2>&1 || true

  if [[ "${purge}" == "true" ]]; then
    rm -rf "${SAVEANY_DIR}"
  else
    rm -f "${SAVEANY_BIN}" "${SAVEANY_BIN}.new"
    find "${SAVEANY_DIR}" -maxdepth 1 -type f -name 'saveany-bot.bak-*' -delete 2>/dev/null || true
  fi
}

remove_openlist_component() {
  local purge="${1:-false}"

  if [[ -f "${OPENLIST_DIR}/docker-compose.yml" ]]; then
    (
      cd "${OPENLIST_DIR}"
      compose down --remove-orphans
    ) >/dev/null 2>&1 || true
  fi
  docker rm -f openlist >/dev/null 2>&1 || true

  if [[ "${purge}" == "true" ]]; then
    rm -rf "${OPENLIST_DIR}"
  else
    rm -f "${OPENLIST_DIR}/docker-compose.yml"
  fi
}

uninstall_saveanybot() {
  clear
  printf "${CYAN}=== 卸载 SaveAnyBot ===${NC}\n\n"

  if [[ ! -x "${SAVEANY_BIN}" && ! -f "${SAVEANY_SERVICE}" && ! -d "${SAVEANY_DIR}" ]]; then
    warn "未检测到 SaveAnyBot。"
    pause
    return 0
  fi

  warn "卸载会停止机器人并删除 systemd 服务。"
  printf "\n请选择卸载方式：\n"
  printf "  1. 仅卸载程序，保留 config.toml、数据库和下载目录\n"
  printf "  2. 完全卸载，删除整个 ${SAVEANY_DIR}\n"
  printf "  0. 返回\n\n"

  local mode confirm_text
  read -r -p "请输入选项: " mode
  case "${mode}" in
    1) ;;
    2) ;;
    0) return 0 ;;
    *) warn "无效选项。"; pause; return 1 ;;
  esac

  if confirm "卸载前是否创建 SaveAnyBot 配置备份？"; then
    create_backup_archive saveany || true
  fi

  if [[ "${mode}" == "2" ]]; then
    warn "此操作将永久删除 ${SAVEANY_DIR}，包括配置、数据库和本地下载文件。"
    read -r -p "请输入 DELETE-SAVEANYBOT 确认完全卸载: " confirm_text
    if [[ "${confirm_text}" != "DELETE-SAVEANYBOT" ]]; then
      warn "确认文字不匹配，已取消。"
      pause
      return 0
    fi
    remove_saveanybot_component true
    success "SaveAnyBot 已完全卸载。"
  else
    confirm "确认仅卸载 SaveAnyBot 程序并保留数据吗？" || { warn "已取消。"; pause; return 0; }
    remove_saveanybot_component false
    success "SaveAnyBot 程序已卸载，数据保留在：${SAVEANY_DIR}"
  fi

  refresh_state_after_uninstall
  pause
}

uninstall_openlist() {
  clear
  printf "${CYAN}=== 卸载 OpenList ===${NC}\n\n"

  if [[ ! -d "${OPENLIST_DIR}" ]] && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'openlist'; then
    warn "未检测到 OpenList。"
    pause
    return 0
  fi

  warn "卸载会停止并删除 OpenList 容器，但默认不会卸载 Docker。"
  printf "\n请选择卸载方式：\n"
  printf "  1. 删除容器和 Compose 配置，保留 ${OPENLIST_DIR}/data\n"
  printf "  2. 完全卸载，删除整个 ${OPENLIST_DIR}\n"
  printf "  0. 返回\n\n"

  local mode confirm_text
  read -r -p "请输入选项: " mode
  case "${mode}" in
    1) ;;
    2) ;;
    0) return 0 ;;
    *) warn "无效选项。"; pause; return 1 ;;
  esac

  if confirm "卸载前是否创建 OpenList 配置备份？"; then
    create_backup_archive openlist || true
  fi

  if [[ "${mode}" == "2" ]]; then
    warn "此操作将永久删除 ${OPENLIST_DIR}，包括数据库、用户和全部网盘配置。"
    read -r -p "请输入 DELETE-OPENLIST 确认完全卸载: " confirm_text
    if [[ "${confirm_text}" != "DELETE-OPENLIST" ]]; then
      warn "确认文字不匹配，已取消。"
      pause
      return 0
    fi
    remove_openlist_component true
    success "OpenList 已完全卸载。"
  else
    confirm "确认删除 OpenList 容器和 Compose 配置并保留 data 吗？" || { warn "已取消。"; pause; return 0; }
    remove_openlist_component false
    success "OpenList 容器已卸载，数据保留在：${OPENLIST_DIR}/data"
  fi

  if command -v docker >/dev/null 2>&1 && confirm "是否同时删除 OpenList Docker 镜像？"; then
    docker image rm openlistteam/openlist:latest >/dev/null 2>&1 \
      && success "OpenList Docker 镜像已删除。" \
      || warn "镜像未删除，可能仍被其他容器占用或已经不存在。"
  fi
  warn "Docker 本身未卸载，以免影响服务器上的其他容器。"

  refresh_state_after_uninstall
  pause
}

uninstall_all() {
  clear
  printf "${CYAN}=== 完整卸载 SaveAnyBot + OpenList ===${NC}\n\n"
  warn "此功能可以同时停止并卸载两个组件。"
  printf "\n请选择卸载方式：\n"
  printf "  1. 卸载程序和服务，但保留配置与数据目录\n"
  printf "  2. 完全删除 SaveAnyBot 与 OpenList 的配置和数据\n"
  printf "  0. 返回\n\n"

  local mode confirm_text
  read -r -p "请输入选项: " mode
  case "${mode}" in
    1) ;;
    2) ;;
    0) return 0 ;;
    *) warn "无效选项。"; pause; return 1 ;;
  esac

  if confirm "卸载前是否创建完整配置备份？"; then
    create_backup_archive all || true
  fi

  if [[ "${mode}" == "2" ]]; then
    warn "将永久删除 ${SAVEANY_DIR} 和 ${OPENLIST_DIR}。"
    warn "OpenList 中的全部用户、网盘挂载、OAuth Token 以及 SaveAnyBot 配置都会被删除。"
    read -r -p "请输入 DELETE-ALL 确认完全卸载: " confirm_text
    if [[ "${confirm_text}" != "DELETE-ALL" ]]; then
      warn "确认文字不匹配，已取消。"
      pause
      return 0
    fi
    remove_saveanybot_component true
    remove_openlist_component true
    success "SaveAnyBot 与 OpenList 已完全卸载。"
  else
    confirm "确认卸载两个程序并保留数据吗？" || { warn "已取消。"; pause; return 0; }
    remove_saveanybot_component false
    remove_openlist_component false
    success "两个程序均已卸载，配置和数据目录已保留。"
  fi

  rm -f "${STATE_FILE}"
  if command -v docker >/dev/null 2>&1 && confirm "是否同时删除 OpenList Docker 镜像？"; then
    docker image rm openlistteam/openlist:latest >/dev/null 2>&1 \
      && success "OpenList Docker 镜像已删除。" \
      || warn "镜像未删除，可能仍被其他容器占用或已经不存在。"
  fi
  warn "Docker 和系统依赖不会被自动卸载，以免影响其他服务。"
  pause
}

show_status() {
  clear
  printf "${CYAN}=== 服务状态 ===${NC}\n\n"
  printf "SaveAnyBot:\n"
  systemctl status saveany-bot --no-pager -l 2>/dev/null || true
  printf "\nOpenList:\n"
  docker ps --filter name=openlist 2>/dev/null || true
  printf "\nSaveAnyBot 最近日志：\n"
  journalctl -u saveany-bot -n 20 --no-pager 2>/dev/null || true
  printf "\nOpenList 最近日志：\n"
  docker logs --tail 20 openlist 2>/dev/null || true
  pause
}

backup_all() {
  clear
  printf "${CYAN}=== 备份配置 ===${NC}\n\n"
  create_backup_archive all || true
  pause
}

show_menu() {
  clear
  cat <<EOF
${CYAN}SaveAnyBot + OpenList 管理脚本 v${SCRIPT_VERSION}${NC}

基础部署：
  1. 安装 / 更新 SaveAnyBot
  2. 安装 / 更新 OpenList

添加网盘到 SaveAnyBot：
  3. 添加 Google Drive
  4. 添加 115 网盘
  5. 添加阿里云盘 Open
  6. 添加 OneDrive
  7. 添加夸克网盘
  8. 添加 PikPak
  9. 添加百度网盘
 10. 添加 123 云盘
 11. 添加其他 OpenList 网盘

维护：
 12. 查看服务状态和日志
 13. 备份 SaveAnyBot 与 OpenList 配置

卸载：
 14. 卸载 SaveAnyBot
 15. 卸载 OpenList
 16. 完整卸载 SaveAnyBot + OpenList
  0. 退出
EOF
}

main() {
  require_root
  check_supported_os
  load_state

  while true; do
    show_menu
    printf "\n"
    read -r -p "请输入选项: " choice
    case "${choice}" in
      1) install_saveanybot ;;
      2) install_openlist ;;
      3) add_cloud_storage google "GoogleDrive" "/GoogleDrive" "SaveAnyBotGoogle" ;;
      4) add_cloud_storage 115 "115网盘" "/115" "SaveAnyBot115" ;;
      5) add_cloud_storage aliyun "阿里云盘" "/AliyunDrive" "SaveAnyBotAliyun" ;;
      6) add_cloud_storage onedrive "OneDrive" "/OneDrive" "SaveAnyBotOneDrive" ;;
      7) add_cloud_storage quark "夸克网盘" "/Quark" "SaveAnyBotQuark" ;;
      8) add_cloud_storage pikpak "PikPak" "/PikPak" "SaveAnyBotPikPak" ;;
      9) add_cloud_storage baidu "百度网盘" "/Baidu" "SaveAnyBotBaidu" ;;
      10) add_cloud_storage 123pan "123云盘" "/123" "SaveAnyBot123" ;;
      11) add_generic_storage ;;
      12) show_status ;;
      13) backup_all ;;
      14) uninstall_saveanybot ;;
      15) uninstall_openlist ;;
      16) uninstall_all ;;
      0) success "已退出。"; exit 0 ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

main "$@"
