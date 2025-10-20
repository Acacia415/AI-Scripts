#!/bin/bash

# 全局颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# ======================= Sub-Store安装模块 =======================
install_substore() {
    local secret_key
    local compose_file="docker-compose.yml" # 定义 docker-compose 文件名

    # 检查 docker-compose.yml 是否存在，并尝试从中提取 secret_key
    if [ -f "$compose_file" ]; then
        extracted_key=$(sed -n 's|.*SUB_STORE_FRONTEND_BACKEND_PATH=/\([0-9a-fA-F]\{32\}\).*|\1|p' "$compose_file" | head -n 1)
        if [[ -n "$extracted_key" && ${#extracted_key} -eq 32 ]]; then
            secret_key="$extracted_key"
            echo -e "${GREEN}检测到已存在的密钥，将继续使用: ${secret_key}${NC}"
        else
            echo -e "${YELLOW}未能从现有的 ${compose_file} 中提取有效密钥，或文件格式不符。${NC}"
        fi
    fi

    # 如果 secret_key 仍然为空 (文件不存在或提取失败)，则生成一个新的密钥
    if [ -z "$secret_key" ]; then
        secret_key=$(openssl rand -hex 16)
        echo -e "${YELLOW}生成新的密钥: ${secret_key}${NC}"
    fi

    mkdir -p /root/sub-store-data

    echo -e "${YELLOW}清理旧容器和相关配置...${NC}"
    docker rm -f sub-store >/dev/null 2>&1 || true
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    if docker compose -p sub-store down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker compose down' 清理项目。${NC}"
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" down >/dev/null 2>&1; then
        echo -e "${CYAN}使用 'docker-compose down' 清理项目。${NC}"
    else
        echo -e "${YELLOW}未找到 docker-compose.yml 或无法执行 down 命令，可能没有旧项目需要清理。${NC}"
    fi

    echo -e "${YELLOW}创建/更新 ${compose_file} 配置文件...${NC}"
    cat <<EOF > "$compose_file"
version: '3.8' # 建议使用较新的compose版本，例如3.8
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=/$secret_key
    ports:
      - "3001:3001"
    volumes:
      - /root/sub-store-data:/opt/app/data
EOF

    echo -e "${YELLOW}拉取最新镜像 (xream/sub-store:latest)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local pull_cmd_success=false
    if docker compose -p sub-store pull sub-store; then
        pull_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" pull sub-store; then
        pull_cmd_success=true
    fi

    if ! $pull_cmd_success; then
        echo -e "${RED}拉取镜像失败，请检查网络连接或镜像名称 (xream/sub-store:latest)。${NC}"
        # 您可以在这里决定是否退出脚本
        # exit 1
    fi

    echo -e "${YELLOW}启动容器 (项目名: sub-store)...${NC}"
    # 优先使用 docker compose (v2)，如果失败则尝试 docker-compose (v1)
    local up_cmd_success=false
    if docker compose -p sub-store up -d; then
        up_cmd_success=true
    elif command -v docker-compose &>/dev/null && docker-compose -p sub-store -f "$compose_file" up -d; then
        up_cmd_success=true
    fi

    if ! $up_cmd_success; then
        echo -e "${RED}启动容器失败。请检查 Docker 服务状态及 ${compose_file} 文件配置。${NC}"
        echo -e "${RED}可以使用 'docker logs sub-store' 查看容器日志。${NC}"
        # exit 1
    else
        # 可以增加一个短暂的延时，给容器一些启动时间
        echo -e "${YELLOW}等待容器启动 (约5-10秒)...${NC}"
        sleep 10 # 可以根据实际情况调整这个延时

        # 检查容器是否仍在运行
        if docker ps -q -f name=sub-store | grep -q .; then
            echo -e "\n${GREEN}Sub-Store 已启动！${NC}"
            echo -e "Sub-Store 面板访问地址: ${CYAN}http://${public_ip}:3001${NC}"
            echo -e "Sub-Store 后端API地址: ${CYAN}http://${public_ip}:3001/${secret_key}${NC}"
            echo -e "\n${YELLOW}如果服务无法访问，请检查容器日志: ${CYAN}docker logs sub-store${NC}"
            echo -e "${YELLOW}或通过本地验证服务是否监听端口: ${CYAN}curl -I http://127.0.0.1:3001${NC}"

            # ==========================================================
            # ==                  【新增的清理功能】                  ==
            # ==========================================================
            echo -e "\n${YELLOW}清理旧的悬空镜像...${NC}"
            docker image prune -f

        else
            echo -e "\n${RED}Sub-Store 容器未能保持运行状态。${NC}"
            echo -e "${RED}请手动检查容器日志: ${CYAN}docker logs sub-store${NC}"
        fi
    fi

    local compose_cmd_v2="docker compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_v1="docker-compose -p sub-store -f \"$(pwd)/${compose_file}\""
    local compose_cmd_prefix=""

    # 检测使用哪个compose命令
    if docker compose version &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v2"
        echo -e "${CYAN}将使用 'docker compose' (v2) 命令进行管理。${NC}"
    elif command -v docker-compose &>/dev/null; then
        compose_cmd_prefix="$compose_cmd_v1"
        echo -e "${CYAN}将使用 'docker-compose' (v1) 命令进行管理。${NC}"
    else
        echo -e "${RED}未找到 'docker compose' 或 'docker-compose' 命令，管理命令可能无法直接使用。${NC}"
    fi


    echo -e "\n${YELLOW}常用管理命令 (如果 ${compose_file} 不在当前目录，请先 cd 到对应目录):${NC}"
    if [[ -n "$compose_cmd_prefix" ]]; then
        echo -e "启动 Sub-Store: ${CYAN}${compose_cmd_prefix} start sub-store${NC} (如果服务已定义在compose文件中)"
        echo -e "或者: ${CYAN}${compose_cmd_prefix} up -d sub-store${NC}"
        echo -e "停止 Sub-Store: ${CYAN}${compose_cmd_prefix} stop sub-store${NC}"
        echo -e "重启 Sub-Store: ${CYAN}${compose_cmd_prefix} restart sub-store${NC}"
        echo -e "查看 Sub-Store 状态: ${CYAN}${compose_cmd_prefix} ps${NC}"
        echo -e "更新 Sub-Store (重新执行此安装模块即可，或手动):"
        echo -e "  1. 拉取新镜像: ${CYAN}${compose_cmd_prefix} pull sub-store${NC}"
        echo -e "  2. 重启服务:   ${CYAN}${compose_cmd_prefix} up -d --force-recreate sub-store${NC}"
        echo -e "完全卸载 Sub-Store (包括数据):"
        echo -e "  1. 停止并删除容器/网络: ${CYAN}${compose_cmd_prefix} down${NC}"
    else
        echo -e "请根据您安装的 Docker Compose 版本手动执行相应命令。"
    fi
    echo -e "查看 Sub-Store 日志: ${CYAN}docker logs --tail 100 sub-store${NC}"
    echo -e "删除数据目录: ${CYAN}rm -rf /root/sub-store-data${NC}"
    echo -e "删除配置文件: ${CYAN}rm -f \"$(pwd)/${compose_file}\"${NC}"
}

# 执行函数
install_substore
