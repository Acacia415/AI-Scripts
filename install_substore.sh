#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
INSTALL_DIR=/opt/sub-store
DEFAULT_DATA_DIR=/var/lib/sub-store
DEFAULT_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LEGACY_COMPOSE_FILE=/root/docker-compose.yml
BACKUP_DIR=/var/backups/ai-scripts/sub-store
ROLLBACK_IMAGE_KEEP=3
DEFAULT_CORS_ALLOWED_ORIGINS='https://sub-store.vercel.app,http://substore.stash,https://substore.stash'
COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
DATA_DIR="$DEFAULT_DATA_DIR"

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -p sub-store -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -p sub-store -f "$COMPOSE_FILE" "$@"
    else
        return 127
    fi
}

install_docker() {
    command -v docker >/dev/null 2>&1 && return 0

    if [[ -f /etc/debian_version ]]; then
        local temp
        temp=$(mktemp /tmp/ai-docker-install.XXXXXX)
        if ! curl -fsSL --connect-timeout 10 --max-time 120 https://get.docker.com -o "$temp"; then
            rm -f -- "$temp"
            return 1
        fi
        if ! sh -n "$temp"; then
            rm -f -- "$temp"
            echo -e "${RED}Docker 最新安装脚本语法检查失败。${NC}"
            return 1
        fi
        sh "$temp"
        rm -f -- "$temp"
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo -e "${RED}无法识别系统，请手动安装 Docker。${NC}"
        return 1
    fi

    systemctl enable --now docker
}

compose_secret() {
    local file=$1
    [[ -f $file ]] || return 1
    sed -n -E 's|^[[:space:]]*-[[:space:]]*SUB_STORE_FRONTEND_BACKEND_PATH[[:space:]]*=[[:space:]]*"?/([^"[:space:]]+)"?[[:space:]]*$|\1|p; s|^[[:space:]]*SUB_STORE_FRONTEND_BACKEND_PATH[[:space:]]*:[[:space:]]*"?/([^"[:space:]]+)"?[[:space:]]*$|\1|p' "$file" | head -n1
}

compose_cors_origins() {
    local file=$1
    [[ -f $file ]] || return 1
    sed -n -E 's|^[[:space:]]*-[[:space:]]*SUB_STORE_CORS_ALLOWED_ORIGINS[[:space:]]*=[[:space:]]*"?([^"]+)"?[[:space:]]*$|\1|p; s|^[[:space:]]*SUB_STORE_CORS_ALLOWED_ORIGINS[[:space:]]*:[[:space:]]*"?([^"]+)"?[[:space:]]*$|\1|p' "$file" | head -n1
}

compose_data_dir() {
    local file=$1
    [[ -f $file ]] || return 1
    sed -n -E 's|^[[:space:]]*-[[:space:]]*"?([^"[:space:]]+):/opt/app/data"?[[:space:]]*$|\1|p' "$file" | head -n1
}

compose_port_value() {
    local file=$1 line
    [[ -f $file ]] || return 1
    line=$(grep -E ':[[:space:]]*3001|:3001' "$file" | head -n1 || true)
    [[ -n $line ]] || return 1
    printf '%s\n' "$line" | sed -E 's|^[[:space:]]*-[[:space:]]*"?||; s|"?[[:space:]]*(#.*)?$||'
}

compose_bind_address() {
    local file=$1 value
    value=$(compose_port_value "$file" 2>/dev/null || true)
    [[ -n $value ]] || return 1
    case "$value" in
        127.0.0.1:*) printf '%s\n' '127.0.0.1' ;;
        0.0.0.0:*) printf '%s\n' '0.0.0.0' ;;
        *) printf '%s\n' '0.0.0.0' ;;
    esac
}

compose_host_port() {
    local file=$1 value host_port
    value=$(compose_port_value "$file" 2>/dev/null || true)
    [[ -n $value ]] || return 1

    case "$value" in
        127.0.0.1:*:3001)
            host_port=${value#127.0.0.1:}
            host_port=${host_port%:3001}
            ;;
        0.0.0.0:*:3001)
            host_port=${value#0.0.0.0:}
            host_port=${host_port%:3001}
            ;;
        *:3001)
            host_port=${value%:3001}
            ;;
        *) return 1 ;;
    esac

    [[ $host_port =~ ^[0-9]{1,5}$ ]] || return 1
    printf '%s\n' "$host_port"
}

compose_matches_runtime() {
    local file=$1 expected_secret=$2 expected_data=$3
    local file_secret='' file_data=''
    [[ -f $file ]] || return 1
    file_secret=$(compose_secret "$file" 2>/dev/null || true)
    file_data=$(compose_data_dir "$file" 2>/dev/null || true)
    [[ -n $file_secret && -n $file_data && $file_secret == "$expected_secret" && $file_data == "$expected_data" ]]
}

safe_data_dir() {
    local dir=$1
    [[ -n $dir && $dir == /* && $dir != / && $dir != /root && $dir != /var && $dir != /opt ]]
}

valid_origin() {
    local origin=$1
    [[ $origin =~ ^https?://[^/]+$ ]]
}

append_origin() {
    local list=$1 origin=$2
    if [[ ,$list, == *,$origin,* ]]; then
        printf '%s\n' "$list"
    elif [[ -n $list ]]; then
        printf '%s,%s\n' "$list" "$origin"
    else
        printf '%s\n' "$origin"
    fi
}

prompt_custom_origin() {
    local current=$1 origin=''
    read -r -p '浏览器访问 Origin [可留空；例如 https://sub-store.example.com]: ' origin
    origin=${origin%/}
    if [[ -z $origin ]]; then
        printf '%s\n' "$current"
        return 0
    fi
    if ! valid_origin "$origin"; then
        echo -e "${RED}Origin 格式无效，只填写协议 + 域名/IP + 可选端口，不要带路径。${NC}" >&2
        return 1
    fi
    append_origin "$current" "$origin"
}

cleanup_old_rollback_images() {
    local keep=${1:-$ROLLBACK_IMAGE_KEEP}
    local -a rollback_tags=()
    local tag i

    [[ $keep =~ ^[0-9]+$ ]] || keep=3

    mapfile -t rollback_tags < <(
        docker images xream/sub-store --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E '^xream/sub-store:rollback-[0-9]{8}-[0-9]{6}$' \
            | sort -r || true
    )

    if (( ${#rollback_tags[@]} <= keep )); then
        return 0
    fi

    echo -e "${YELLOW}清理旧的 Sub-Store 回滚镜像，仅保留最近 ${keep} 个。${NC}"
    for ((i=keep; i<${#rollback_tags[@]}; i++)); do
        tag=${rollback_tags[$i]}
        if docker image rm "$tag" >/dev/null 2>&1; then
            echo -e "已删除旧回滚镜像：${CYAN}${tag}${NC}"
        else
            echo -e "${YELLOW}无法删除 ${tag}，可能仍被容器引用，已跳过。${NC}"
        fi
    done
}

backend_health_check() {
    local host_port=$1 secret_key=$2 cors_origins=$3
    local url="http://127.0.0.1:${host_port}/${secret_key}/api/utils/env"
    local origin

    curl -fsS --connect-timeout 3 --max-time 10 "http://127.0.0.1:${host_port}/" >/dev/null 2>&1 || return 1
    curl -fsS --connect-timeout 3 --max-time 10 "$url" >/dev/null 2>&1 || return 1

    if [[ $cors_origins == '*' ]]; then
        curl -fsS --connect-timeout 3 --max-time 10 \
            -H 'Origin: https://sub-store-health.invalid' "$url" >/dev/null 2>&1 || return 1
        return 0
    fi

    IFS=',' read -r -a origins <<< "$cors_origins"
    for origin in "${origins[@]}"; do
        origin=$(printf '%s' "$origin" | xargs)
        [[ -n $origin ]] || continue
        curl -fsS --connect-timeout 3 --max-time 10 \
            -H "Origin: $origin" "$url" >/dev/null 2>&1 || return 1
    done
}

restore_previous() {
    local compose_backup=${1:-}
    local data_backup=${2:-}
    local rollback_tag=${3:-}

    echo -e "${YELLOW}正在恢复更新前的 Sub-Store。${NC}"
    compose down >/dev/null 2>&1 || docker rm -f sub-store >/dev/null 2>&1 || true

    if [[ -n $data_backup && -f $data_backup ]]; then
        if safe_data_dir "$DATA_DIR"; then
            rm -rf -- "$DATA_DIR"
            mkdir -p -- "$(dirname "$DATA_DIR")"
            tar -C "$(dirname "$DATA_DIR")" -xzf "$data_backup"
        else
            echo -e "${RED}数据目录安全检查失败，未自动恢复数据：${DATA_DIR}${NC}"
        fi
    fi

    if [[ -n $compose_backup && -f $compose_backup ]]; then
        cp -a "$compose_backup" "$COMPOSE_FILE"
        if [[ -n $rollback_tag ]] && docker image inspect "$rollback_tag" >/dev/null 2>&1; then
            sed -i -E "s|^([[:space:]]*)image:[[:space:]].*|\\1image: $rollback_tag|" "$COMPOSE_FILE"
        fi
        compose up -d >/dev/null 2>&1 || true
    else
        rm -f -- "$COMPOSE_FILE"
    fi
}

install_substore() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行。${NC}"; return 1; }

    install_docker
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        [[ -f /etc/debian_version ]] && apt-get update && apt-get install -y docker-compose-plugin || true
    fi
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || {
        echo -e "${RED}Docker Compose 不可用。${NC}"
        return 1
    }

    local timestamp secret_key='' cors_allowed_origins='' bind_address='' host_port='3001' public_ip display_host
    local existing_install=false container_exists=false source_compose='' compose_label=''
    local previous_image_id='' rollback_tag='' compose_backup='' data_backup=''

    timestamp=$(date +%Y%m%d-%H%M%S)
    install -d -m 700 "$INSTALL_DIR" "$BACKUP_DIR"

    if docker inspect sub-store >/dev/null 2>&1; then
        container_exists=true
        existing_install=true

        local current_image_name
        current_image_name=$(docker inspect -f '{{.Config.Image}}' sub-store 2>/dev/null || true)
        if [[ $current_image_name != xream/sub-store* ]]; then
            echo -e "${RED}发现名为 sub-store 的容器，但镜像不是 xream/sub-store，已停止操作以避免覆盖其他服务。${NC}"
            return 1
        fi

        secret_key=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store 2>/dev/null \
            | sed -n 's|^SUB_STORE_FRONTEND_BACKEND_PATH=/\(.*\)$|\1|p' | head -n1 || true)
        cors_allowed_origins=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store 2>/dev/null \
            | sed -n 's|^SUB_STORE_CORS_ALLOWED_ORIGINS=\(.*\)$|\1|p' | head -n1 || true)
        DATA_DIR=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/app/data"}}{{println .Source}}{{end}}{{end}}' sub-store 2>/dev/null | head -n1 || true)
        bind_address=$(docker inspect -f '{{with (index .HostConfig.PortBindings "3001/tcp")}}{{(index . 0).HostIp}}{{end}}' sub-store 2>/dev/null || true)
        host_port=$(docker inspect -f '{{with (index .HostConfig.PortBindings "3001/tcp")}}{{(index . 0).HostPort}}{{end}}' sub-store 2>/dev/null || true)
        previous_image_id=$(docker inspect -f '{{.Image}}' sub-store 2>/dev/null || true)
        compose_label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' sub-store 2>/dev/null || true)

        bind_address=${bind_address:-0.0.0.0}
        host_port=${host_port:-3001}

        if compose_matches_runtime "$DEFAULT_COMPOSE_FILE" "$secret_key" "$DATA_DIR"; then
            source_compose="$DEFAULT_COMPOSE_FILE"
        elif compose_matches_runtime "$LEGACY_COMPOSE_FILE" "$secret_key" "$DATA_DIR"; then
            source_compose="$LEGACY_COMPOSE_FILE"
        elif [[ -n $compose_label && -f $compose_label ]] && compose_matches_runtime "$compose_label" "$secret_key" "$DATA_DIR"; then
            source_compose="$compose_label"
        fi
    fi

    if ! $container_exists; then
        local default_exists=false legacy_exists=false
        local default_secret='' default_data='' legacy_secret='' legacy_data=''

        if [[ -f $DEFAULT_COMPOSE_FILE ]] && grep -q 'xream/sub-store' "$DEFAULT_COMPOSE_FILE"; then
            default_exists=true
            default_secret=$(compose_secret "$DEFAULT_COMPOSE_FILE" 2>/dev/null || true)
            default_data=$(compose_data_dir "$DEFAULT_COMPOSE_FILE" 2>/dev/null || true)
        fi
        if [[ -f $LEGACY_COMPOSE_FILE ]] && grep -q 'xream/sub-store' "$LEGACY_COMPOSE_FILE"; then
            legacy_exists=true
            legacy_secret=$(compose_secret "$LEGACY_COMPOSE_FILE" 2>/dev/null || true)
            legacy_data=$(compose_data_dir "$LEGACY_COMPOSE_FILE" 2>/dev/null || true)
        fi

        if $default_exists && $legacy_exists && [[ $default_secret != "$legacy_secret" || $default_data != "$legacy_data" ]]; then
            echo -e "${RED}同时发现新旧两套 Sub-Store 配置且 API/数据目录不同，但当前没有容器可判断哪套正在使用。${NC}"
            echo -e "${YELLOW}为避免切错 API 或数据，脚本不会自动选择，请先恢复/启动正确的现有容器后再更新。${NC}"
            return 1
        elif $default_exists; then
            existing_install=true
            source_compose="$DEFAULT_COMPOSE_FILE"
        elif $legacy_exists; then
            existing_install=true
            source_compose="$LEGACY_COMPOSE_FILE"
        fi

        if $existing_install; then
            secret_key=$(compose_secret "$source_compose" 2>/dev/null || true)
            cors_allowed_origins=$(compose_cors_origins "$source_compose" 2>/dev/null || true)
            DATA_DIR=$(compose_data_dir "$source_compose" 2>/dev/null || true)
            bind_address=$(compose_bind_address "$source_compose" 2>/dev/null || true)
            host_port=$(compose_host_port "$source_compose" 2>/dev/null || true)
            previous_image_id=$(docker image inspect -f '{{.Id}}' xream/sub-store:latest 2>/dev/null || true)
            bind_address=${bind_address:-0.0.0.0}
            host_port=${host_port:-3001}
        fi
    fi

    if $existing_install; then
        [[ -n $secret_key ]] || {
            echo -e "${RED}检测到已有 Sub-Store，但无法读取现有 API 路径。为避免修改现有 API，已停止更新。${NC}"
            return 1
        }
        [[ -n $DATA_DIR ]] || {
            echo -e "${RED}检测到已有 Sub-Store，但无法读取现有数据目录。为避免切换数据目录，已停止更新。${NC}"
            return 1
        }
        safe_data_dir "$DATA_DIR" || {
            echo -e "${RED}检测到的数据目录不安全：${DATA_DIR}${NC}"
            return 1
        }

        if [[ -n $source_compose ]]; then
            COMPOSE_FILE="$source_compose"
        else
            COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
        fi

        if [[ -z $cors_allowed_origins ]]; then
            echo -e "${YELLOW}现有安装没有 CORS allowlist。Sub-Store 2.38+ 已收紧浏览器 Origin。${NC}"
            cors_allowed_origins=$(prompt_custom_origin "$DEFAULT_CORS_ALLOWED_ORIGINS") || return 1
        fi

        echo -e "${GREEN}检测到已有 Sub-Store，将保持现有 API、数据目录、监听方式和 CORS 设置。${NC}"
        echo -e "API 路径：${CYAN}/${secret_key}${NC}"
        echo -e "数据目录：${CYAN}${DATA_DIR}${NC}"
        echo -e "CORS：${CYAN}${cors_allowed_origins}${NC}"
        echo -e "配置文件：${CYAN}${COMPOSE_FILE}${NC}"
    else
        COMPOSE_FILE="$DEFAULT_COMPOSE_FILE"
        DATA_DIR="$DEFAULT_DATA_DIR"
        secret_key=$(openssl rand -hex 16)

        read -r -p '监听地址 [127.0.0.1，输入 0.0.0.0 可公网访问]: ' bind_address
        bind_address=${bind_address:-127.0.0.1}
        [[ $bind_address == 127.0.0.1 || $bind_address == 0.0.0.0 ]] || {
            echo -e "${RED}只允许 127.0.0.1 或 0.0.0.0。${NC}"
            return 1
        }

        cors_allowed_origins=$(prompt_custom_origin "$DEFAULT_CORS_ALLOWED_ORIGINS") || return 1
        install -d -m 700 "$DATA_DIR"
    fi

    mkdir -p -- "$(dirname "$COMPOSE_FILE")" "$DATA_DIR"

    if [[ -f $COMPOSE_FILE ]]; then
        compose_backup="$BACKUP_DIR/docker-compose.${timestamp}.yml"
        cp -a "$COMPOSE_FILE" "$compose_backup"
    fi

    if $existing_install && [[ -d $DATA_DIR ]]; then
        data_backup="$BACKUP_DIR/data.${timestamp}.tar.gz"
        tar -C "$(dirname "$DATA_DIR")" -czf "$data_backup" "$(basename "$DATA_DIR")"
    fi

    if [[ -n $previous_image_id ]] && docker image inspect "$previous_image_id" >/dev/null 2>&1; then
        rollback_tag="xream/sub-store:rollback-${timestamp}"
        docker tag "$previous_image_id" "$rollback_tag"
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: /$secret_key
      SUB_STORE_CORS_ALLOWED_ORIGINS: "$cors_allowed_origins"
    ports:
      - "$bind_address:$host_port:3001"
    volumes:
      - "$DATA_DIR:/opt/app/data"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    chmod 600 "$COMPOSE_FILE"

    if ! compose config >/dev/null; then
        echo -e "${RED}生成的 Compose 配置校验失败，正在恢复。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    if ! compose pull sub-store || ! compose up -d; then
        echo -e "${RED}更新失败，正在恢复更新前配置、数据和镜像。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    sleep 3
    if [[ $(docker inspect -f '{{.State.Running}}' sub-store 2>/dev/null || true) != true ]] \
        || ! backend_health_check "$host_port" "$secret_key" "$cors_allowed_origins"; then
        echo -e "${RED}容器未通过前端、后端 API 或 CORS 健康检查，正在回滚。${NC}"
        restore_previous "$compose_backup" "$data_backup" "$rollback_tag"
        return 1
    fi

    cleanup_old_rollback_images "$ROLLBACK_IMAGE_KEEP"

    public_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)
    display_host=$public_ip
    [[ $bind_address == 127.0.0.1 ]] && display_host=127.0.0.1

    echo -e "${GREEN}Sub-Store 已启动。${NC}"
    echo -e "面板：${CYAN}http://${display_host}:${host_port}${NC}"
    echo -e "API：${CYAN}http://${display_host}:${host_port}/${secret_key}${NC}"
    echo -e "配置：${COMPOSE_FILE}；数据：${DATA_DIR}；日志限制：10MB × 3。"
    echo -e "CORS：${cors_allowed_origins}"
    echo -e "自动回滚镜像：最多保留最近 ${ROLLBACK_IMAGE_KEEP} 个。"
    [[ -n $compose_backup ]] && echo -e "更新前配置备份：${compose_backup}"
    [[ -n $data_backup ]] && echo -e "更新前数据备份：${data_backup}"
    [[ -n $rollback_tag ]] && echo -e "本次更新前镜像：${rollback_tag}"

    return 0
}

install_substore
