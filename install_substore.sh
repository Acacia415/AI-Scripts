#!/bin/bash

set -Eeuo pipefail

RED='\033[31m'; GREEN='\033[32m'; CYAN='\033[36m'; NC='\033[0m'
INSTALL_DIR=/opt/sub-store
DATA_DIR=/var/lib/sub-store
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
BACKUP_DIR=/var/backups/ai-scripts/sub-store

compose() {
    if docker compose version >/dev/null 2>&1; then docker compose -p sub-store -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then docker-compose -p sub-store -f "$COMPOSE_FILE" "$@"
    else return 127
    fi
}

install_docker() {
    command -v docker >/dev/null 2>&1 && return
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

restore_previous() {
    local backup=$1
    if [[ -n $backup && -f $backup ]]; then
        cp -a "$backup" "$COMPOSE_FILE"
        compose up -d >/dev/null 2>&1 || true
    else
        compose down >/dev/null 2>&1 || true
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
        echo -e "${RED}Docker Compose 不可用。${NC}"; return 1;
    }

    local timestamp backup='' secret_key bind_address public_ip
    timestamp=$(date +%Y%m%d-%H%M%S)
    install -d -m 700 "$INSTALL_DIR" "$DATA_DIR" "$BACKUP_DIR"
    if [[ -f $COMPOSE_FILE ]]; then
        backup="$BACKUP_DIR/docker-compose.${timestamp}.yml"
        cp -a "$COMPOSE_FILE" "$backup"
        secret_key=$(sed -n 's|.*SUB_STORE_FRONTEND_BACKEND_PATH=/\([0-9a-fA-F]\{32\}\).*|\1|p' "$COMPOSE_FILE" | head -n1)
    fi
    secret_key=${secret_key:-$(openssl rand -hex 16)}

    read -r -p '监听地址 [127.0.0.1，输入 0.0.0.0 可公网访问]: ' bind_address
    bind_address=${bind_address:-127.0.0.1}
    [[ $bind_address == 127.0.0.1 || $bind_address == 0.0.0.0 ]] || {
        echo -e "${RED}只允许 127.0.0.1 或 0.0.0.0。${NC}"; return 1;
    }

    cat > "$COMPOSE_FILE" <<EOF
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: /$secret_key
    ports:
      - "$bind_address:3001:3001"
    volumes:
      - "$DATA_DIR:/opt/app/data"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    chmod 600 "$COMPOSE_FILE"

    if ! compose config >/dev/null || ! compose pull sub-store || ! compose up -d; then
        echo -e "${RED}更新失败，正在恢复修改前 Compose 配置和容器。${NC}"
        restore_previous "$backup"
        return 1
    fi
    sleep 3
    if [[ $(docker inspect -f '{{.State.Running}}' sub-store 2>/dev/null || true) != true ]]; then
        echo -e "${RED}容器没有保持运行，正在回滚。${NC}"
        restore_previous "$backup"
        return 1
    fi

    public_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)
    local display_host=$public_ip
    [[ $bind_address == 127.0.0.1 ]] && display_host=127.0.0.1
    echo -e "${GREEN}Sub-Store 已启动。${NC}"
    echo -e "面板：${CYAN}http://${display_host}:3001${NC}"
    echo -e "API：${CYAN}http://${display_host}:3001/${secret_key}${NC}"
    echo -e "配置：${COMPOSE_FILE}；数据：${DATA_DIR}；日志限制：10MB × 3。"
    [[ -n $backup ]] && echo -e "更新前备份：${backup}"
}

install_substore
